import hashlib
import logging
import json
import os
import re
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import quote

from fastapi import APIRouter, Depends, Header, HTTPException, Request
from starlette.datastructures import UploadFile
from starlette.concurrency import run_in_threadpool
from fastapi.responses import Response, JSONResponse
from sqlalchemy import delete, select, update
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from .auth import current_customer, db_session
from .assistant_model import enhance_advice
from .graph import history_question, retrieve_history, history_answer
from .graph_models import KnowledgeRecord
from .notifications import unread_count
from .models import Customer, Estimate, EstimateOutbox, Outbox, Photo, Provider, RateBucket, Reminder, Repair, RequestEvent, RequestRejection, ServiceRequest, Vehicle, now, uid
from .postal import canonical_zip
from .schemas import AssistantInput, EstimateCreate, EstimateSubmit, ProfileWrite, ReminderCreate, ReminderUpdate, EstimateUpdate, RequestCreate, VehicleCreate, VehicleUpdate
from .workflow import bridge_details, creation_payload, payload_hash, queue_cancellation

from .calendar_scheduling import check_slots, legacy_payload, sync_view, preferred_times, lock_customer
from .capture_contract import DOCUMENT_KEYS, allowed_keys, PDR_PANELS

router = APIRouter(prefix="/v1")
log = logging.getLogger(__name__)
ESTIMATE_PHOTO_KEYS = DOCUMENT_KEYS
PDR_PANEL_TYPES = ("hood", "fender_left", "front_door_left", "rear_door_left", "quarter_left", "trunk",
                   "quarter_right", "rear_door_right", "front_door_right", "fender_right", "roof")
MAX_PHOTOS_PER_ESTIMATE = 40
# Generous per-account ceilings so a runaway client cannot grow a garage without bound.
MAX_VEHICLES_PER_CUSTOMER = 50
MAX_ESTIMATES_PER_CUSTOMER = 500
MAX_REMINDERS_PER_CUSTOMER = 500
MAX_CUSTOMER_PHOTO_BYTES = 250 * 1024 * 1024
MAX_PHOTO_UPLOADS_PER_HOUR = 100
MAX_ESTIMATE_SUBMITS_PER_HOUR = 20
MAX_SERVICE_REQUESTS_PER_HOUR = 20
UNMATCHED_REPLY = "I can't answer that one yet. I can explain an estimate, plan routine maintenance, or find a technician near you."


def consume_rate(db, customer_id, action, limit):
    bucket = int(now().timestamp() // 3600)
    row = db.get(RateBucket, (customer_id, action, bucket))
    if row and row.count >= limit:
        raise HTTPException(429, "Too many attempts. Please try again later.")
    if row:
        row.count += 1
    else:
        db.add(RateBucket(customer_id=customer_id, action=action, hour_bucket=bucket, count=1))


def iso(value):
    if value is None:
        return None
    return value.isoformat() if hasattr(value, "isoformat") else value


def enforce_cap(db, model, customer_id, limit, noun):
    from sqlalchemy import func
    if db.scalar(select(func.count(model.id)).where(model.customer_id == customer_id)) >= limit:
        raise HTTPException(409, {"detail": f"You have reached the limit of {limit} {noun}. Remove one to add another.",
                                  "code": "limit_reached"})


def profile(c):
    return {**{k: getattr(c, k) for k in ("id", "email", "name", "phone", "postal_code", "contact_preference")},
            "email_updates": bool(c.notification_emails)}


def vehicle(v):
    return {k: getattr(v, k) for k in ("id", "nickname", "year", "make", "model", "vin", "mileage", "insurer", "policy_number", "image_version")}


def provider(p):
    return {k: getattr(p, k) for k in ("id", "source_id", "name", "kind", "specialties", "postal_codes", "city", "address", "phone", "mobile_service", "accepting_requests", "description", "media")}


def request_view(db, r):
    events = db.scalars(select(RequestEvent).where(RequestEvent.request_id == r.id).order_by(RequestEvent.created_at, RequestEvent.id)).all()
    return {"id": r.id, "vehicle_id": r.vehicle_id, "provider_id": r.provider_id, "specialty": r.specialty, "service_mode": r.service_mode,
            "description": r.description, "preferred_time": r.preferred_time, "status": r.status,
            "delivery_status": r.delivery_status, "created_at": iso(r.created_at), "updated_at": iso(r.updated_at),
            "scheduled_at": iso(r.scheduled_at), "proposed_slots": r.proposed_slots, **sync_view(r), "events": [{"status": e.status, "message": e.message, "created_at": iso(e.created_at)} for e in events]}


def estimate_view(db, e):
    photos = db.scalars(select(Photo).where(Photo.estimate_id == e.id)).all()
    return {"id": e.id, "vehicle_id": e.vehicle_id, "discipline": e.discipline, "description": e.description, "service_mode": e.service_mode,
            "claim_number": e.claim_number, "date_of_loss": e.date_of_loss, "status": e.status,
            "amount_cents": e.amount_cents, "provider_name": e.provider_name, "provider_id": e.provider_id,
            "delivery_status": e.delivery_status, "processing_state": e.processing_state,
            "processing_error": e.processing_error, "updated_at": iso(e.updated_at),
            "photos": [{"id": p.id, "label": p.label} for p in photos]}


def repair_view(r):
    return {"id": r.id, "vehicle_id": r.vehicle_id, "provider_name": r.provider_name, "title": r.title,
            "status": r.status, "updated_at": iso(r.updated_at), "estimated_completion": r.estimated_completion, "stages": r.stages}


def reminder_view(r):
    return {k: getattr(r, k) for k in ("id", "vehicle_id", "title", "due_date", "due_mileage", "completed")}


def owned(db, model, identifier, customer):
    obj = db.get(model, identifier)
    if obj is None or obj.customer_id != customer.id:
        raise HTTPException(404, "Not found.")
    return obj


def editable_estimate(db, estimate_id, customer):
    # Use the same lock order as submission and guided capture.
    db.execute(update(Customer).where(Customer.id == customer.id).values(id=Customer.id))
    db.execute(update(Estimate).where(Estimate.id == estimate_id, Estimate.customer_id == customer.id)
               .values(updated_at=Estimate.updated_at))
    db.expire_all()
    e = owned(db, Estimate, estimate_id, customer)
    if e.delivery_status != "draft" or e.status != "draft" or e.processing_state != "not_started":
        raise HTTPException(409, {"detail": "This estimate has been shared and can no longer be changed.", "code": "estimate_locked"})
    return e


def remove_photo_file(settings, storage_name):
    try:
        (Path(settings.photo_dir) / storage_name).unlink(missing_ok=True)
    except OSError:
        # The row is gone and the file has no route; the volume cleanup job retries.
        log.warning("Private estimate photo cleanup failed")


def matching_providers(db, specialty=None, postal_code=None, mobile_only=False, demo=False):
    candidates = db.scalars(select(Provider).where(Provider.public_visible.is_(True), Provider.demo_only.is_(demo)).order_by(Provider.name)).all()
    return [p for p in candidates if (not specialty or specialty in p.specialties)
            and (not postal_code or postal_code in p.postal_codes)
            and (not mobile_only or p.mobile_service)]


@router.get("/bootstrap")
def bootstrap(request: Request, c: Customer = Depends(current_customer), db: Session = Depends(db_session)):
    ids = c.id
    return {"profile": profile(c), "vehicles": [vehicle(v) for v in db.scalars(select(Vehicle).where(Vehicle.customer_id == ids)).all()],
            "providers": [provider(p) for p in matching_providers(db, demo=c.demo)],
            "estimates": [estimate_view(db, e) for e in db.scalars(select(Estimate).where(Estimate.customer_id == ids)).all()],
            "repairs": [repair_view(r) for r in db.scalars(select(Repair).where(Repair.customer_id == ids)).all()],
            "requests": [request_view(db, r) for r in db.scalars(select(ServiceRequest).where(ServiceRequest.customer_id == ids)).all()],
            "reminders": [reminder_view(r) for r in db.scalars(select(Reminder).where(Reminder.customer_id == ids)).all()],
            "unread_notifications": unread_count(db, ids),
            "capabilities": {"live_requests": bool(request.app.state.settings.bridge_url and request.app.state.settings.bridge_key and not c.demo),
                             "live_discovery": bool(request.app.state.settings.discovery_enabled and not c.demo),
                             "live_estimates": bool(request.app.state.settings.estimate_bridge_url and request.app.state.settings.bridge_key and not c.demo),
                             "required_estimate_photo_keys": list(ESTIMATE_PHOTO_KEYS),
                             "pdr_damage_panel_types": list(PDR_PANEL_TYPES),
                             "carfax": False, "youtube_search": False, "demo": c.demo}}


@router.put("/profile")
def update_profile(body: ProfileWrite, c: Customer = Depends(current_customer), db: Session = Depends(db_session)):
    for k, v in body.model_dump().items():
        setattr(c, k, v)
    db.add(c)
    db.commit()
    return profile(c)


@router.post("/vehicles", status_code=201)
def create_vehicle(body: VehicleCreate, c: Customer = Depends(current_customer), db: Session = Depends(db_session)):
    enforce_cap(db, Vehicle, c.id, MAX_VEHICLES_PER_CUSTOMER, "vehicles")
    v = Vehicle(customer_id=c.id, **body.model_dump())
    db.add(v)
    db.commit()
    return vehicle(v)


@router.put("/vehicles/{vehicle_id}")
def update_vehicle(vehicle_id: str, body: VehicleUpdate, c: Customer = Depends(current_customer), db: Session = Depends(db_session)):
    v = owned(db, Vehicle, vehicle_id, c)
    for k, val in body.model_dump(exclude_unset=True).items():
        setattr(v, k, val)
    db.commit()
    return vehicle(v)


@router.delete("/vehicles/{vehicle_id}", status_code=204)
def delete_vehicle(vehicle_id: str, request: Request, c: Customer = Depends(current_customer), db: Session = Depends(db_session)):
    db.execute(update(Customer).where(Customer.id == c.id).values(id=Customer.id))
    db.expire_all()
    v = owned(db, Vehicle, vehicle_id, c)
    if any(db.scalar(select(m.id).where(m.vehicle_id == v.id)) for m in (ServiceRequest, Estimate, Repair, Reminder, KnowledgeRecord)):
        raise HTTPException(409, "Vehicle is in use.")
    image_name = v.image_storage_name
    db.delete(v)
    db.commit()
    if image_name:
        from .vehicle_images import remove_upload_file
        remove_upload_file(request.app.state.settings, image_name)


@router.get("/providers")
def providers(specialty: str | None = None, postal_code: str | None = None, mobile_only: bool = False,
              c: Customer = Depends(current_customer), db: Session = Depends(db_session)):
    if specialty and specialty not in {"pdr", "collision", "maintenance", "mechanical"}:
        raise HTTPException(422, "Unknown specialty.")
    return [provider(p) for p in matching_providers(db, specialty, postal_code, mobile_only, c.demo)]


@router.get("/requests")
def requests(c: Customer = Depends(current_customer), db: Session = Depends(db_session)):
    return [request_view(db, r) for r in db.scalars(select(ServiceRequest).where(ServiceRequest.customer_id == c.id).order_by(ServiceRequest.created_at.desc())).all()]


@router.post("/requests", status_code=201)
def create_request(body: RequestCreate, request: Request, idempotency_key: str | None = Header(default=None),
                   c: Customer = Depends(current_customer), db: Session = Depends(db_session)):
    if not idempotency_key or len(idempotency_key) > 200:
        raise HTTPException(422, "Idempotency-Key is required.")
    payload = legacy_payload(body, directory=True)
    if 'service_mode' not in body.model_fields_set:
        payload.pop('service_mode', None)
    digest = hashlib.sha256(json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
    from .discovery import admission, valid_admission
    distance_proof = {}
    if body.service_mode == 'shop_visit':
        # Replays do not depend on current geography/provider availability.
        prior = db.scalar(select(ServiceRequest).where(ServiceRequest.customer_id == c.id, ServiceRequest.idempotency_key == idempotency_key))
        rejected = db.get(RequestRejection, (c.id, idempotency_key))
        if prior or rejected:
            result = prior or rejected
            if result.payload_hash != digest:
                raise HTTPException(409, 'Idempotency key was used for another request.')
            return request_view(db, prior) if prior else JSONResponse(status_code=rejected.status_code, content={'detail': rejected.detail, 'code': rejected.code})
        preliminary = db.get(Provider, body.provider_id)
        car = db.get(Vehicle, body.vehicle_id)
        initial_zip = canonical_zip(c.postal_code)
        if preliminary and preliminary.public_visible and preliminary.accepting_requests and car and car.customer_id == c.id and initial_zip:
            # Cache/provider I/O precedes the source transaction. Its frozen proof
            # is checked again after taking the customer lock below.
            distance_proof = admission(request, preliminary, initial_zip, body.service_mode)
    # Serialize request outcomes across API workers before reading either outcome
    # table. A no-op UPDATE takes a PostgreSQL row lock and a SQLite write lock;
    # SELECT FOR UPDATE alone would not protect the local SQLite deployment.
    db.execute(update(Customer).where(Customer.id == c.id).values(id=Customer.id))
    db.refresh(c)
    db.expire_all()
    existing = db.scalar(select(ServiceRequest).where(ServiceRequest.customer_id == c.id, ServiceRequest.idempotency_key == idempotency_key))
    if existing:
        if existing.payload_hash != digest:
            raise HTTPException(409, "Idempotency key was used for another request.")
        return request_view(db, existing)
    rejected = db.get(RequestRejection, (c.id, idempotency_key))
    if rejected:
        if rejected.payload_hash != digest:
            raise HTTPException(409, "Idempotency key was used for another request.")
        return JSONResponse(status_code=rejected.status_code, content={"detail": rejected.detail, "code": rejected.code})

    def reject(status_code, detail):
        # Once reported as not created, this operation can never be created by
        # a delayed retry, even if the provider or profile subsequently changes.
        db.add(RequestRejection(customer_id=c.id, idempotency_key=idempotency_key,
                                payload_hash=digest, status_code=status_code, detail=detail))
        db.commit()
        return JSONResponse(status_code=status_code, content={"detail": detail, "code": "request_not_created"})

    v = db.get(Vehicle, body.vehicle_id)
    if not v or v.customer_id != c.id:
        return reject(404, "Not found.")
    service_zip = canonical_zip(c.postal_code)
    if not service_zip:
        return reject(422, "Save a valid ZIP code before requesting service.")
    p = db.get(Provider, body.provider_id)
    if not p or not p.public_visible or p.demo_only != c.demo or not p.accepting_requests or body.specialty not in p.specialties:
        return reject(409, "Provider is not accepting this request.")
    if not valid_admission(p, service_zip, body.service_mode, distance_proof):
        return reject(422 if body.service_mode else 409, 'Provider does not support this location and service mode.')
    if not c.demo and not (request.app.state.settings.bridge_url and request.app.state.settings.bridge_key):
        raise HTTPException(503, "Requests are unavailable right now. Please try again later.")
    if not body.description.strip():
        return reject(422, "Describe the help you need before requesting service.")
    if not c.demo:
        try:
            bridge_details(c, v)
        except ValueError as exc:
            return reject(422, str(exc))
        consume_rate(db, c.id, "service_request", MAX_SERVICE_REQUESTS_PER_HOUR)
    calendar_data = {}
    if body.calendar_check:
        try:
            calendar_data = check_slots(db, request.app.state.settings, request.app.state.calendar_transport,
                                        c.id, body.proposed_slots, body.duration_minutes, body.calendar_generation)
        except HTTPException as exc:
            if exc.status_code == 422:
                return reject(422, exc.detail)
            raise
    elif body.calendar_generation is not None or body.proposed_slots:
        return reject(422, "Choose and check Calendar times before including structured slots.")
    status = "local_preview" if c.demo else "queued"
    r = ServiceRequest(id=uid(), customer_id=c.id, vehicle_id=body.vehicle_id, provider_id=body.provider_id,
                       service_mode=body.service_mode, discovery_admission=distance_proof or {},
                       specialty=body.specialty, description=body.description.strip(), preferred_time=body.preferred_time.strip(),
                       idempotency_key=idempotency_key, payload_hash=digest, service_postal_code=service_zip,
                       delivery_status=status, created_at=now(), updated_at=now(),
                       proposed_slots=[v.isoformat() for v in body.proposed_slots], duration_minutes=body.duration_minutes,
                       calendar_sync_status="pending" if calendar_data.get("calendar_sync_enabled") else "not_enabled", **calendar_data)
    if body.calendar_check:
        r.preferred_time = preferred_times(body.proposed_slots, body.duration_minutes, r.calendar_time_zone)
    db.add(r)
    try:
        db.flush()
        db.add(RequestEvent(request_id=r.id, status="requested", message="Request created."))
        if not c.demo:
            snapshot = creation_payload(r, c, v, p)
            db.add(Outbox(request_id=r.id, payload=snapshot, payload_hash=payload_hash(snapshot)))
        db.commit()
    except IntegrityError:
        db.rollback()
        existing = db.scalar(select(ServiceRequest).where(ServiceRequest.customer_id == c.id, ServiceRequest.idempotency_key == idempotency_key))
        if existing and existing.payload_hash == digest:
            return request_view(db, existing)
        raise HTTPException(409, "Idempotency key was used for another request.")
    return request_view(db, r)


@router.post("/requests/{request_id}/cancel")
def cancel_request(request_id: str, c: Customer = Depends(current_customer), db: Session = Depends(db_session)):
    db.execute(update(Customer).where(Customer.id == c.id).values(id=Customer.id))
    db.expire_all()
    owned(db, ServiceRequest, request_id, c)
    stamp = now()
    changed = db.execute(update(ServiceRequest).where(
        ServiceRequest.id == request_id,
        ServiceRequest.customer_id == c.id,
        ServiceRequest.status.in_(("requested", "accepted", "scheduled")),
    ).values(status="cancelled", updated_at=stamp).returning(ServiceRequest.id)).first()
    if not changed:
        db.rollback()
        raise HTTPException(409, "This request can no longer be cancelled.")
    db.expire_all()
    r = db.get(ServiceRequest, request_id)
    creation = db.scalar(select(Outbox).where(Outbox.request_id == r.id, Outbox.kind == "create").with_for_update())
    if creation and (creation.attempts > 0 or creation.receipt_id):
        creation.suppressed = True
        queue_cancellation(db, r, creation)
    elif creation:
        creation.suppressed = True
    r.delivery_status = "cancelled"
    db.add(RequestEvent(request_id=r.id, status="cancelled", message="Cancelled by customer."))
    db.commit()
    db.refresh(r)
    return request_view(db, r)


@router.post("/estimates", status_code=201)
def create_estimate(body: EstimateCreate, c: Customer = Depends(current_customer), db: Session = Depends(db_session)):
    owned(db, Vehicle, body.vehicle_id, c)
    enforce_cap(db, Estimate, c.id, MAX_ESTIMATES_PER_CUSTOMER, "estimates")
    e = Estimate(customer_id=c.id, vehicle_id=body.vehicle_id, discipline=body.discipline,
                 description=body.description, claim_number=body.claim_number, date_of_loss=iso(body.date_of_loss))
    db.add(e)
    db.commit()
    return estimate_view(db, e)


@router.put("/estimates/{estimate_id}")
def update_estimate(estimate_id: str, body: EstimateUpdate, c: Customer = Depends(current_customer), db: Session = Depends(db_session)):
    e = editable_estimate(db, estimate_id, c)
    changes = body.model_dump(exclude_unset=True)
    if "date_of_loss" in changes:
        changes["date_of_loss"] = iso(changes["date_of_loss"])
    for k, val in changes.items():
        setattr(e, k, val)
    e.updated_at = now()
    db.commit()
    return estimate_view(db, e)


@router.delete("/estimates/{estimate_id}", status_code=204)
def delete_estimate(estimate_id: str, request: Request, c: Customer = Depends(current_customer), db: Session = Depends(db_session)):
    e = editable_estimate(db, estimate_id, c)
    from .capture_models import CaptureReceipt, CaptureVinSuggestion
    photos = db.scalars(select(Photo).where(Photo.estimate_id == e.id)).all()
    names = [p.storage_name for p in photos]
    for p in photos:
        db.delete(p)
    db.execute(delete(CaptureReceipt).where(CaptureReceipt.estimate_id == e.id))
    db.execute(delete(CaptureVinSuggestion).where(CaptureVinSuggestion.estimate_id == e.id))
    db.delete(e)
    db.commit()
    for name in names:
        remove_photo_file(request.app.state.settings, name)


@router.post("/estimates/{estimate_id}/submit")
def submit_estimate(estimate_id: str, body: EstimateSubmit, request: Request,
                    idempotency_key: str | None = Header(default=None),
                    c: Customer = Depends(current_customer), db: Session = Depends(db_session)):
    if not idempotency_key or len(idempotency_key) > 200:
        raise HTTPException(422, "Idempotency-Key is required.")
    submitted = body.model_dump()
    if 'service_mode' not in body.model_fields_set:
        submitted.pop('service_mode', None)
    input_hash = payload_hash(submitted)
    preliminary_estimate = owned(db, Estimate, estimate_id, c)
    from .discovery import admission, valid_admission
    distance_proof = {}
    if body.service_mode == 'shop_visit' and preliminary_estimate.status == 'draft':
        preliminary = db.get(Provider, body.provider_id)
        initial_zip = canonical_zip(c.postal_code)
        if preliminary and preliminary.public_visible and preliminary.accepting_requests and initial_zip:
            distance_proof = admission(request, preliminary, initial_zip, body.service_mode)
    db.execute(update(Customer).where(Customer.id == c.id).values(id=Customer.id))
    db.refresh(c)
    db.execute(update(Estimate).where(Estimate.id == estimate_id, Estimate.customer_id == c.id)
               .values(updated_at=Estimate.updated_at).returning(Estimate.id))
    db.expire_all()
    e = owned(db, Estimate, estimate_id, c)
    if e.status != "draft":
        if e.submission_key == idempotency_key and e.submission_request_hash == input_hash:
            return estimate_view(db, e)
        raise HTTPException(409, "Estimate was already submitted with another operation.")
    settings = request.app.state.settings
    if c.demo or not (settings.estimate_bridge_url and settings.bridge_key):
        raise HTTPException(503, "Estimate submission is unavailable right now.")
    e.description, e.claim_number = e.description.strip(), e.claim_number.strip()
    if not 1 <= len(e.description) <= 2000 or len(e.claim_number) > 60:
        raise HTTPException(422, "Review the estimate description and claim number before submitting.")
    service_zip = canonical_zip(c.postal_code)
    if not service_zip:
        raise HTTPException(422, "Save a valid ZIP code before submitting.")
    v = owned(db, Vehicle, e.vehicle_id, c)
    try:
        contact, car = bridge_details(c, v, estimate=True)
    except ValueError as exc:
        raise HTTPException(422, str(exc))
    p = db.get(Provider, body.provider_id)
    if not p or p.demo_only or not p.public_visible or not p.accepting_requests or p.kind != "shop" or e.discipline not in p.specialties:
        raise HTTPException(409, "Provider is not accepting this estimate.")
    if not valid_admission(p, service_zip, body.service_mode, distance_proof):
        raise HTTPException(422 if body.service_mode else 409, 'Provider does not support this location and service mode.')
    photos = db.scalars(select(Photo).where(Photo.estimate_id == e.id).order_by(Photo.label, Photo.id)).all()
    by_label = {photo.label: photo for photo in photos}
    missing = [key for key in ESTIMATE_PHOTO_KEYS if key not in by_label]
    if missing:
        raise HTTPException(422, "Add required photos: " + ", ".join(missing) + ".")
    if e.discipline == "pdr":
        close = {label.removeprefix('hail_close_') for label in by_label if label.startswith('hail_close_')}
        raking = {label.removeprefix('hail_raking_') for label in by_label if label.startswith('hail_raking_')}
        if close != raking or not raking <= set(PDR_PANELS):
            raise HTTPException(422, "Add both close-up and raking-angle photos for each selected PDR area.")
        if not any("panel_" + panel in by_label for panel in PDR_PANEL_TYPES) and not raking:
            raise HTTPException(422, "Add a damage photo or complete angle pair for a selected PDR panel.")
    if len(photos) > MAX_PHOTOS_PER_ESTIMATE or len(by_label) != len(photos):
        raise HTTPException(422, "Resolve duplicate or excess photos before submitting.")
    if e.discipline == "pdr":
        # Existing drafts can contain the former single-photo intake. A full
        # guided angle pair supersedes that view; never price the area twice.
        for panel in raking:
            by_label.pop('panel_' + panel, None)
    evidence = []
    for label in (*ESTIMATE_PHOTO_KEYS, *sorted(set(by_label) - set(ESTIMATE_PHOTO_KEYS))):
        photo = by_label[label]
        if photo.label not in allowed_keys(e.discipline):
            raise HTTPException(422, "Unsupported photo label: " + photo.label)
        photo_path = Path(settings.photo_dir) / photo.storage_name
        if not photo_path.is_file():
            raise HTTPException(422, "A required photo is unavailable. Please contact support.")
        digest = hashlib.sha256()
        size = 0
        with photo_path.open("rb") as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                size += len(chunk)
                digest.update(chunk)
        if size == 0 or size > 10 * 1024 * 1024 or (photo.sha256 and photo.sha256 != digest.hexdigest()):
            raise HTTPException(422, "A photo is unavailable or changed. Please contact support.")
        photo.sha256 = digest.hexdigest()
        photo.byte_size = size
        evidence.append({"id": photo.id, "label": photo.label, "sha256": photo.sha256,
                         "byte_size": photo.byte_size, "mime_type": photo.mime_type})
    payload = {"event": "submitted", "estimate_id": e.id, "customer_id": c.id, "vehicle_id": v.id,
               "provider_source_id": p.source_id, "service_postal_code": service_zip,
               "discipline": e.discipline, "description": e.description, "capture_version": 2,
               "claim_number": e.claim_number, "date_of_loss": e.date_of_loss,
               "contact": contact, "vehicle": car, "photos": evidence}
    if body.service_mode is not None:
        payload['service_mode'] = body.service_mode
    e.service_mode, e.discovery_admission = body.service_mode, distance_proof or {}
    e.provider_id = p.id
    e.provider_name = p.name
    e.status = "submitted"
    e.delivery_status = "queued"
    e.processing_state = "pending"
    e.submission_key = idempotency_key
    e.submission_request_hash = input_hash
    e.updated_at = now()
    consume_rate(db, c.id, "estimate_submit", MAX_ESTIMATE_SUBMITS_PER_HOUR)
    db.add(EstimateOutbox(estimate_id=e.id, payload=payload, payload_hash=payload_hash(payload)))
    db.commit()
    return estimate_view(db, e)


@router.post("/estimates/{estimate_id}/photos", status_code=201)
async def upload_photo(estimate_id: str, request: Request,
                       c: Customer = Depends(current_customer), db: Session = Depends(db_session)):
    e = owned(db, Estimate, estimate_id, c)
    if e.status != "draft":
        raise HTTPException(409, "Photos can only be added to drafts.")
    async with request.form(max_files=1, max_fields=1, max_part_size=1024) as form:
        file = form.get("file")
        label = form.get("label")
        if not isinstance(file, UploadFile) or not isinstance(label, str):
            raise HTTPException(422, "Photo and label are required.")
        if not label.strip() or len(label) > 100:
            raise HTTPException(422, "Photo label is required.")
        data = await file.read(10 * 1024 * 1024 + 1)
        mime = file.content_type
    # Older app builds use the same private storage transaction, quotas and
    # uncertainty recovery as the guided host. Preserve their 10 MB contract
    # and do not make a new automated framing claim on this legacy route.
    from .capture_routes import save_photo, validate_image
    await run_in_threadpool(validate_image, data, mime, 10 * 1024 * 1024)
    saved = await run_in_threadpool(save_photo, estimate_id, request, c, db, data, mime,
        {'capture_key': label.strip(), 'body_style': 'sedan', 'operation_id': uid()},
        verify_framing=False, validate_capture_key=False, max_bytes=MAX_CUSTOMER_PHOTO_BYTES, max_photos=MAX_PHOTOS_PER_ESTIMATE,
        max_uploads=MAX_PHOTO_UPLOADS_PER_HOUR)
    return {'id': saved['id'], 'label': saved['label']}


@router.get("/estimates/{estimate_id}/photos/{photo_id}")
def get_photo(estimate_id: str, photo_id: str, request: Request, c: Customer = Depends(current_customer), db: Session = Depends(db_session)):
    owned(db, Estimate, estimate_id, c)
    p = db.get(Photo, photo_id)
    if not p or p.estimate_id != estimate_id:
        raise HTTPException(404, "Not found.")
    path = Path(request.app.state.settings.photo_dir) / p.storage_name
    if not path.is_file():
        raise HTTPException(404, "Not found.")
    return Response(path.read_bytes(), media_type=p.mime_type, headers={"Cache-Control": "private, no-store", "X-Content-Type-Options": "nosniff"})


@router.delete("/estimates/{estimate_id}/photos/{photo_id}", status_code=204)
def delete_photo(estimate_id: str, photo_id: str, request: Request, c: Customer = Depends(current_customer), db: Session = Depends(db_session)):
    editable_estimate(db, estimate_id, c)
    p = db.get(Photo, photo_id)
    if not p or p.estimate_id != estimate_id:
        raise HTTPException(404, "Not found.")
    name = p.storage_name
    db.delete(p)
    db.commit()
    remove_photo_file(request.app.state.settings, name)


@router.post("/reminders", status_code=201)
def create_reminder(body: ReminderCreate, c: Customer = Depends(current_customer), db: Session = Depends(db_session)):
    owned(db, Vehicle, body.vehicle_id, c)
    enforce_cap(db, Reminder, c.id, MAX_REMINDERS_PER_CUSTOMER, "reminders")
    r = Reminder(customer_id=c.id, vehicle_id=body.vehicle_id, title=body.title,
                 due_date=iso(body.due_date), due_mileage=body.due_mileage)
    db.add(r)
    db.commit()
    return reminder_view(r)


@router.post("/reminders/{reminder_id}/complete")
def complete_reminder(reminder_id: str, c: Customer = Depends(current_customer), db: Session = Depends(db_session)):
    r = owned(db, Reminder, reminder_id, c)
    r.completed = True
    db.commit()
    return reminder_view(r)


@router.put("/reminders/{reminder_id}")
def update_reminder(reminder_id: str, body: ReminderUpdate, c: Customer = Depends(current_customer), db: Session = Depends(db_session)):
    r = owned(db, Reminder, reminder_id, c)
    changes = body.model_dump(exclude_unset=True)
    if "vehicle_id" in changes:
        owned(db, Vehicle, changes["vehicle_id"], c)
    if "due_date" in changes:
        changes["due_date"] = iso(changes["due_date"])
    if changes.get("due_date", r.due_date) is None and changes.get("due_mileage", r.due_mileage) is None:
        raise HTTPException(422, "A date or mileage is required.")
    for k, val in changes.items():
        setattr(r, k, val)
    db.commit()
    return reminder_view(r)


@router.delete("/reminders/{reminder_id}", status_code=204)
def delete_reminder(reminder_id: str, c: Customer = Depends(current_customer), db: Session = Depends(db_session)):
    db.delete(owned(db, Reminder, reminder_id, c))
    db.commit()


@router.post("/reminders/{reminder_id}/reopen")
def reopen_reminder(reminder_id: str, c: Customer = Depends(current_customer), db: Session = Depends(db_session)):
    r = owned(db, Reminder, reminder_id, c)
    r.completed = False
    db.commit()
    return reminder_view(r)


@router.post("/assistant")
def assistant(body: AssistantInput, request: Request, c: Customer = Depends(current_customer), db: Session = Depends(db_session)):
    car = owned(db, Vehicle, body.vehicle_id, c) if body.vehicle_id else None
    message = body.message.lower()
    specialty = body.specialty
    if specialty is None:
        for category, pattern in (
            ("pdr", r"\b(hail|dents?|dings?|pdr)\b"),
            ("collision", r"\b(crash|collision|accident|bumper|bodywork|paint)\b|body damage"),
            ("mechanical", r"\b(brakes?|engine|mechanic|mechanical|battery|noise)\b|won.t start|warning light"),
            ("maintenance", r"\b(oil|tires?|tyres?|pressure|filter|maintenance|service)\b"),
        ):
            if re.search(pattern, message):
                specialty = category
                break
    postal = canonical_zip(body.postal_code or c.postal_code)
    wants_provider = bool(re.search(r"\b(find|connect|someone|technician|tech|shop|book|request|repair|fix)\b|come to", message))
    mobile = body.mobile_only or bool(re.search(r"\bmobile\b|at (my )?(home|house|work)|driveway|come to", message))
    urgent = bool(re.search(r"brakes? (fail(ed|ure)?|not working)|smoke|overheat|fuel leak|burning smell|airbag|high voltage|unsafe|oil pressure", message))
    intent = "find_provider" if wants_provider and specialty and postal and car else ("clarify" if wants_provider else "advice")
    directory_result = None
    if intent == 'find_provider' and request.app.state.settings.discovery_enabled and not c.demo:
        from .discovery import search
        from .discovery_models import DedicatedShop
        from .shop_models import MyShop
        favorite = db.get(DedicatedShop, (c.id, car.id, specialty))
        if favorite and favorite.source == 'my_shop' and not urgent:
            saved = db.get(MyShop, favorite.source_id)
            if saved and saved.customer_id == c.id and not saved.deleted:
                return {'reply': f'Your dedicated shop for this work is {saved.name}. Open My shops to review a contact request and confirm services with them.',
                        'intent': 'shop_outreach', 'specialty': specialty, 'providers': [], 'videos': [], 'dedicated_shop_id': saved.id}
        lock_customer(db, c.id)
        consume_rate(db, c.id, 'directory_search', 120)
        db.commit()
        directory_result = search(db, request, c, postal, car, specialty, mobile)
    matches = [p for p in matching_providers(db, specialty, postal, mobile, c.demo) if p.accepting_requests] if intent == "find_provider" else []
    if intent == "clarify":
        missing = [name for name, value in (("repair type", specialty), ("vehicle", car), ("postal code", postal)) if not value]
        reply = "To find a provider, please share your " + " and ".join(missing or ["repair details"]) + "."
    elif intent == "find_provider":
        reply = (f"These {'mobile ' if mobile else ''}providers list your service area and specialty. Choose one to review your request; they will confirm availability and pricing."
                 if matches else "I couldn't find an opted-in provider matching those details. Try another service or a shop instead of mobile help.")
        if directory_result:
            reply = directory_result['message']
            if mobile and not directory_result['providers']:
                nearest = next((p for p in directory_result['shop_visit_alternatives'] if p['source'] == 'estimoto' and specialty in p['specialties']), None)
                if nearest:
                    reply = f"{nearest['name']} is a nearby participating shop for this work. It requires a shop visit; mobile coverage is not listed for your ZIP. Review the request with the shop to confirm availability and pricing."
    elif re.search(r"tire|tyre|pressure", message):
        reply = "Use the cold tire pressure on the driver-door placard or in your owner's manual. Check with a gauge when the tires are cold. If a tire keeps losing pressure or has visible damage, have a technician inspect it."
    elif "oil" in message:
        reply = "Your owner's manual gives the correct oil specification and service interval for your engine. Check the date and mileage of your last service, then save a reminder in your garage."
    elif re.search(r"estimate|cost|price", message):
        reply = "An estimate separates the work, parts and labor needed for your repair. Your Estimates tab holds the shop's figures and review status. I can help you find a PDR technician or collision shop for a specific concern."
    elif "filter" in message:
        reply = "Your owner's manual identifies the correct filter and replacement interval. Cabin and engine air filters serve different purposes; check the procedure for your vehicle before replacing either. A technician can help if access requires removing other components."
    else:
        reply = UNMATCHED_REPLY
    if urgent:
        # Safety guidance precedes matching, even when the user requests a shop.
        reply = "Avoid driving if the vehicle may be unsafe. Stop somewhere safe and arrange professional help; contact emergency services when appropriate. " + (reply if wants_provider else "I can help you find a qualified repair provider.")
    videos = []
    if not urgent and not wants_provider and re.search(r"how|video|tutorial", message) and re.search(r"oil|tire|tyre|pressure|filter", message):
        topic = "check tire pressure" if re.search(r"tire|tyre|pressure", message) else ("oil service" if "oil" in message else "air filter replacement")
        vehicle_title = f"{car.year} {car.make} {car.model}" if car else "car"
        search = quote(f"{vehicle_title} {topic}", safe="")
        videos = [{"title": "Search YouTube for this maintenance topic", "url": f"https://www.youtube.com/results?search_query={search}", "source": "YouTube search · review vehicle compatibility"}]
    result = {"reply": reply, "intent": intent, "specialty": specialty,
              "providers": [provider(p) for p in matches], "videos": videos}
    if directory_result:
        result['providers'] = directory_result['providers'] + directory_result['shop_visit_alternatives']
        result['discovery'] = {key: value for key, value in directory_result.items() if key not in ('providers', 'shop_visit_alternatives')}
    evidence = []
    if not urgent and re.search(r"\b(schedule|book|contact|reach out|appointment)\b", message) and re.search(r"\b(my|saved|usual|own|previous)\b.*\b(shop|mechanic|garage)\b", message):
        return {"reply": "Open My shops to choose your shop and preferred times. I'll prepare the request for you to review and authorize. Your shop confirms the appointment.",
                "intent": "shop_outreach", "specialty": specialty, "providers": [], "videos": []}
    if not urgent and history_question(message):
        evidence = retrieve_history(db, c.id, car.id if car else None, body.message)
        result = {"reply": history_answer(evidence), "intent": "advice", "specialty": None,
                  "providers": [], "videos": [], "answer_source": "Your saved history",
                  "sources": [{"id": e["source_id"], "type": e["source"],
                               "title": e["service_date"] + " · " + e["service_type"].replace("_", " ")} for e in evidence]}
        if not evidence:
            return result
        intent = "advice"
    if intent != "advice" or urgent or c.demo:
        return result
    if os.getenv("OPENAI_API_KEY") and os.getenv("ASSISTANT_ENABLED", "true").lower() == "true":
        db.execute(update(Customer).where(Customer.id == c.id).values(id=Customer.id))
        db.expire_all()
        try:
            consume_rate(db, c.id, "assistant_model", 30)
            db.commit()
        except HTTPException as exc:
            db.rollback()
            if exc.status_code == 429:
                return result
            raise
    result = enhance_advice(result, message=body.message,
                            vehicle={k: getattr(car, k) for k in ("year", "make", "model", "mileage")} if car else None,
                            settings=request.app.state.settings, evidence=evidence,
                            transport=getattr(request.app.state, "assistant_transport", None))
    if result.get("reply") == UNMATCHED_REPLY:
        # Nothing deterministic or model-backed answered: say so and hand the
        # customer the technician search for their saved area.
        result["intent"] = "unmatched"
        result.setdefault("discovery", {"postal_code": postal or None, "specialty": specialty})
    return result

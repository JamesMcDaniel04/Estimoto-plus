import hashlib
from datetime import timezone
from pathlib import Path

from fastapi import APIRouter, Depends, HTTPException, Request
from fastapi.responses import Response
from sqlalchemy import select, update
from sqlalchemy.orm import Session
from sqlalchemy.exc import IntegrityError

from .auth import bridge_authorized, db_session
from .bridge_sync import sync_bridge
from .customer_routes import estimate_view, provider, repair_view, request_view
from .delivery import deliver_batch
from .estimate_delivery import deliver_estimate_batch
from .estimate_workflow import apply_submitted_snapshot
from .models import Customer, Estimate, EstimateOutbox, Outbox, Photo, Provider, Repair, RequestEvent, ServiceRequest, Vehicle, now
from .schemas import EstimateSnapshot, ProviderPublish, RepairSnapshot, RequestInboundEvent
from .partner_media import valid_partner_media

router = APIRouter(prefix="/v1/bridge", dependencies=[Depends(bridge_authorized)])


@router.post("/providers")
def upsert_provider(body: ProviderPublish, request: Request, db: Session = Depends(db_session)):
    if not valid_partner_media(body.media, source_id=body.source_id, name=body.name,
                               bridge_url=request.app.state.settings.bridge_url):
        raise HTTPException(422, "Invalid provider media.")
    p = db.scalar(select(Provider).where(Provider.source_id == body.source_id))
    if p is None:
        p = Provider(source_id=body.source_id)
        db.add(p)
    for k, value in body.model_dump().items():
        setattr(p, k, value)
    db.commit()
    return provider(p)


TRANSITIONS = {
    "requested": {"accepted", "declined", "cancelled"},
    "accepted": {"scheduled", "declined", "cancelled"},
    "scheduled": {"scheduled", "completed", "cancelled"},
    "declined": set(), "cancelled": set(), "completed": set(),
}


def _same_event(previous, request_id, body, scheduled_at_text):
    return (previous is not None and previous.request_id == request_id and
            previous.status == body.status and previous.message == body.message and
            previous.scheduled_at == scheduled_at_text)


@router.post("/requests/{request_id}/events")
def inbound_event(request_id: str, body: RequestInboundEvent, db: Session = Depends(db_session)):
    r = db.get(ServiceRequest, request_id)
    if not r or r.provider_id != body.provider_id:
        raise HTTPException(404, "Request not found.")
    scheduled_at_text = body.scheduled_at.astimezone(timezone.utc).isoformat() if body.scheduled_at else None
    previous = db.scalar(select(RequestEvent).where(RequestEvent.event_id == body.event_id))
    if previous:
        if _same_event(previous, request_id, body, scheduled_at_text):
            return request_view(db, r)
        raise HTTPException(409, "Event ID was already used.")
    if r.delivery_status != "delivered":
        raise HTTPException(404, "Request not found.")
    if body.status == "scheduled" and body.scheduled_at is None:
        raise HTTPException(422, "Scheduled time is required.")
    if body.status != "scheduled" and body.scheduled_at is not None:
        raise HTTPException(422, "Scheduled time is only valid for scheduling.")
    predecessors = tuple(status for status, targets in TRANSITIONS.items() if body.status in targets)
    stamp = now()
    customer_id = r.customer_id
    db.rollback()  # End preliminary read transaction; the conditional write is authoritative.
    # Serialize appointment changes with checked admission and Calendar writes.
    from .calendar_scheduling import lock_customer
    lock_customer(db, customer_id)
    changed = db.execute(update(ServiceRequest).where(
        ServiceRequest.id == request_id,
        ServiceRequest.provider_id == body.provider_id,
        ServiceRequest.delivery_status == "delivered",
        ServiceRequest.status.in_(predecessors),
    ).values(status=body.status, updated_at=stamp,
             **({"scheduled_at": body.scheduled_at} if body.status == "scheduled" else {}))
        .returning(ServiceRequest.id)).first()
    if not changed:
        db.rollback()
        previous = db.scalar(select(RequestEvent).where(RequestEvent.event_id == body.event_id))
        if _same_event(previous, request_id, body, scheduled_at_text):
            db.expire_all()
            return request_view(db, db.get(ServiceRequest, request_id))
        raise HTTPException(409, "Invalid status transition.")
    db.add(RequestEvent(request_id=request_id, event_id=body.event_id, status=body.status,
                        message=body.message, scheduled_at=scheduled_at_text))
    from .notifications import notify_request_event
    notify_request_event(db, r, body.status, body.message, scheduled_at_text, body.event_id)
    try:
        db.commit()
    except IntegrityError:
        db.rollback()
        previous = db.scalar(select(RequestEvent).where(RequestEvent.event_id == body.event_id))
        if _same_event(previous, request_id, body, scheduled_at_text):
            db.expire_all()
            return request_view(db, db.get(ServiceRequest, request_id))
        raise HTTPException(409, "Event ID was already used.")
    db.expire_all()
    return request_view(db, db.get(ServiceRequest, request_id))


@router.post("/outbox/deliver")
def deliver_outbox(request: Request):
    settings = request.app.state.settings
    if not settings.bridge_url or not settings.bridge_key:
        raise HTTPException(503, "Bridge is unavailable.")
    results = deliver_batch(settings, request.app.state.bridge_transport, request.app.state.session_factory)
    if settings.estimate_bridge_url:
        estimates = deliver_estimate_batch(settings, request.app.state.bridge_transport, request.app.state.session_factory)
        results = {key: results[key] + estimates[key] for key in results}
    return results


@router.post("/sync")
def sync_from_bridge(request: Request):
    settings = request.app.state.settings
    if not settings.bridge_url or not settings.bridge_key:
        raise HTTPException(503, "Bridge is unavailable.")
    return sync_bridge(settings, request.app.state.bridge_transport, request.app.state.session_factory)


def existing_binding(db, customer_id, vehicle_id):
    customer = db.get(Customer, customer_id)
    vehicle = db.get(Vehicle, vehicle_id)
    if not customer or not vehicle or vehicle.customer_id != customer_id or customer.demo:
        raise HTTPException(404, "Customer or vehicle relationship not found.")


@router.post("/estimates/snapshots")
def estimate_snapshot(body: EstimateSnapshot, db: Session = Depends(db_session)):
    existing_binding(db, body.customer_id, body.vehicle_id)
    if body.estimate_id:
        db.execute(update(Estimate).where(Estimate.id == body.estimate_id)
                   .values(updated_at=Estimate.updated_at).returning(Estimate.id))
        db.expire_all()
        existing = db.get(Estimate, body.estimate_id)
        outbox = db.scalar(select(EstimateOutbox).where(EstimateOutbox.estimate_id == body.estimate_id))
        if not existing or not outbox or existing.customer_id != body.customer_id or existing.vehicle_id != body.vehicle_id:
            raise HTTPException(404, "Estimate binding not found.")
        previous_status, previous_amount = existing.status, existing.amount_cents
        try:
            apply_submitted_snapshot(db, existing, body, outbox.payload)
        except ValueError:
            raise HTTPException(409, "Estimate snapshot conflicts with submitted estimate.")
        existing.updated_at = now()
        from .notifications import notify_estimate_change
        notify_estimate_change(db, existing, previous_status, previous_amount)
        db.commit()
        return estimate_view(db, existing)
    e = db.scalar(select(Estimate).where(Estimate.source_id == body.source_id))
    if e and (e.customer_id != body.customer_id or e.vehicle_id != body.vehicle_id):
        raise HTTPException(409, "Snapshot binding cannot change.")
    if not e:
        e = Estimate(source_id=body.source_id, customer_id=body.customer_id, vehicle_id=body.vehicle_id)
        db.add(e)
    previous_status, previous_amount = e.status, e.amount_cents
    for k, val in body.model_dump(exclude={"customer_id", "vehicle_id", "source_id"}).items():
        if k == "processing_state" and val is None:
            continue  # A snapshot without processing detail keeps the recorded state.
        setattr(e, k, val.isoformat() if hasattr(val, "isoformat") else val)
    e.updated_at = now()
    from .notifications import notify_estimate_change
    notify_estimate_change(db, e, previous_status, previous_amount)
    db.commit()
    return estimate_view(db, e)


@router.get("/estimates/{estimate_id}/photos/{photo_id}")
def import_estimate_photo(estimate_id: str, photo_id: str, request: Request, db: Session = Depends(db_session)):
    estimate = db.get(Estimate, estimate_id)
    outbox = db.scalar(select(EstimateOutbox).where(EstimateOutbox.estimate_id == estimate_id))
    photo = db.get(Photo, photo_id)
    if (not estimate or estimate.status == "draft" or not outbox or not photo or photo.estimate_id != estimate_id or
            not isinstance(outbox.payload, dict)):
        raise HTTPException(404, "Photo not found.")
    evidence = next((item for item in outbox.payload.get("photos", []) if isinstance(item, dict) and item.get("id") == photo_id), None)
    path = Path(request.app.state.settings.photo_dir) / photo.storage_name
    if not evidence or not path.is_file() or path.stat().st_size > 10 * 1024 * 1024:
        raise HTTPException(404, "Photo not found.")
    data = path.read_bytes()
    if hashlib.sha256(data).hexdigest() != evidence.get("sha256"):
        raise HTTPException(409, "Photo evidence changed.")
    return Response(data, media_type=photo.mime_type,
                    headers={"Cache-Control": "private, no-store", "X-Content-Type-Options": "nosniff"})


@router.post("/repairs/snapshots")
def repair_snapshot(body: RepairSnapshot, db: Session = Depends(db_session)):
    existing_binding(db, body.customer_id, body.vehicle_id)
    r = db.scalar(select(Repair).where(Repair.source_id == body.source_id))
    if r and (r.customer_id != body.customer_id or r.vehicle_id != body.vehicle_id):
        raise HTTPException(409, "Snapshot binding cannot change.")
    if not r:
        r = Repair(source_id=body.source_id, customer_id=body.customer_id, vehicle_id=body.vehicle_id)
        db.add(r)
    for k, val in body.model_dump(mode="json", exclude={"customer_id", "vehicle_id", "source_id"}).items():
        setattr(r, k, val)
    r.updated_at = now()
    db.commit()
    return repair_view(r)

"""Customer-initiated account export and permanent account deletion.

Deletion is complete and synchronous: every row and private file the customer
owns is erased in one transaction, the verified sign-in cache is invalidated,
and the Supabase Auth identity is removed when the service role key is
configured. Open shop requests are cancelled and the cancellation is delivered
before erasure so a shop is never left waiting on a customer who no longer
exists; when a shop cannot be reached the deletion is refused with a retryable
error instead of silently dropping the notice.
"""
import logging
from urllib.parse import quote

import httpx
from fastapi import APIRouter, Depends, HTTPException, Request
from fastapi.responses import JSONResponse
from sqlalchemy import delete, select, update
from sqlalchemy.orm import Session

from . import delivery
from .auth import create_auth_client, current_customer, db_session
from .calendar_models import CalendarAttempt, CalendarConnection, CalendarOperation, CalendarProvision
from .calendar_provider import CalendarProvider, CalendarUnavailable
from .capture_models import CaptureReceipt, CaptureVinSuggestion
from .discovery_models import DedicatedShop
from .graph_models import (GraphEdge, GraphEntity, KnowledgeConsentEvent, KnowledgeDeletion, KnowledgePreference,
                           KnowledgeReceipt, KnowledgeRecord)
from .notification_models import Notification
from .models import (Customer, Estimate, EstimateOutbox, Outbox, Photo, RateBucket, Reminder, Repair, RequestEvent,
                     RequestRejection, ServiceRequest, Vehicle, now)
from .shop_models import MyShop, ShopOutbox, ShopOutreach
from .valuation_models import VehicleValuationCache, VehicleValuationHistory
from .workflow import queue_cancellation

router = APIRouter(prefix="/v1/account", tags=["customer account"])
log = logging.getLogger(__name__)
EXPORT_FORMAT = "estimoto-plus/1"
MAX_EXPORTS_PER_HOUR = 10
MAX_DELETE_ATTEMPTS_PER_HOUR = 5
OPEN_REQUEST_STATUSES = ("requested", "accepted", "scheduled")


def _lock(db, customer_id):
    db.execute(update(Customer).where(Customer.id == customer_id).values(id=Customer.id))
    db.expire_all()


@router.get("/export")
def export_account(c: Customer = Depends(current_customer), db: Session = Depends(db_session)):
    """Everything the customer can see in the app, as one private JSON document."""
    from .customer_routes import consume_rate, estimate_view, profile, reminder_view, repair_view, request_view, vehicle
    from .discovery import favorite_view
    from .graph import POLICY_VERSION, record_view
    from .saved_shops import _outreach_view, _shop_view
    from .vehicle_valuation import history_view
    from .notifications import notification_view
    consume_rate(db, c.id, "account_export", MAX_EXPORTS_PER_HOUR)
    db.commit()
    ids = c.id

    def rows(model, *order):
        return db.scalars(select(model).where(model.customer_id == ids).order_by(*order)).all()

    receipts = {}
    for receipt in db.scalars(select(KnowledgeReceipt).where(KnowledgeReceipt.customer_id == ids,
                                                             KnowledgeReceipt.status == "saved")
                              .order_by(KnowledgeReceipt.created_at)):
        receipts.setdefault(receipt.record_id, []).append(receipt)
    preference = db.get(KnowledgePreference, ids)
    calendar = db.get(CalendarConnection, ids)
    body = {
        "format": EXPORT_FORMAT,
        "exported_at": now().isoformat(),
        "notes": ("Photos and receipts are not embedded. Their identifiers are listed so each file can be "
                  "downloaded from the app while the account exists. Deleting the account removes them."),
        "profile": profile(c),
        "vehicles": [{**vehicle(v), "has_private_photo": bool(v.image_storage_name)}
                     for v in rows(Vehicle, Vehicle.year, Vehicle.id)],
        "reminders": [reminder_view(r) for r in rows(Reminder, Reminder.id)],
        "estimates": [estimate_view(db, e) for e in rows(Estimate, Estimate.updated_at, Estimate.id)],
        "requests": [request_view(db, r) for r in rows(ServiceRequest, ServiceRequest.created_at, ServiceRequest.id)],
        "repairs": [repair_view(r) for r in rows(Repair, Repair.updated_at, Repair.id)],
        "service_history": {
            "records": [record_view(r, receipts.get(r.id, [])) for r in
                        rows(KnowledgeRecord, KnowledgeRecord.service_date, KnowledgeRecord.created_at)],
            "preferences": {"share_aggregate_insights": bool(preference and preference.share_aggregate_insights)},
            "policy_version": POLICY_VERSION,
            "consent_events": [{"share_aggregate_insights": e.share_aggregate_insights, "policy_version": e.policy_version,
                                "created_at": e.created_at.isoformat()}
                               for e in rows(KnowledgeConsentEvent, KnowledgeConsentEvent.created_at)],
        },
        "my_shops": [_shop_view(s) for s in rows(MyShop, MyShop.created_at, MyShop.id) if not s.deleted],
        "shop_requests": [_outreach_view(o) for o in rows(ShopOutreach, ShopOutreach.created_at, ShopOutreach.id)],
        "dedicated_shops": [favorite_view(f) for f in rows(DedicatedShop, DedicatedShop.vehicle_id, DedicatedShop.specialty)],
        "vehicle_valuations": [{"vehicle_id": h.vehicle_id, **history_view(h)}
                               for h in rows(VehicleValuationHistory, VehicleValuationHistory.created_at)],
        "notifications": {"email_updates": bool(c.notification_emails),
                          "items": [notification_view(n) for n in rows(Notification, Notification.created_at, Notification.id)]},
        "calendar": {"status": calendar.status if calendar else "disconnected",
                     "selected_calendar_ids": calendar.selected_calendar_ids if calendar else [],
                     "time_zone": calendar.time_zone if calendar else ""},
    }
    return JSONResponse(body, headers={"Content-Disposition": 'attachment; filename="estimoto-plus-export.json"'})


def cancel_open_requests(db, customer_id):
    """Mirror customer cancellation for every open request; returns their ids."""
    stamp = now()
    open_ids = db.scalars(select(ServiceRequest.id).where(
        ServiceRequest.customer_id == customer_id, ServiceRequest.status.in_(OPEN_REQUEST_STATUSES))).all()
    for request_id in open_ids:
        r = db.get(ServiceRequest, request_id)
        r.status, r.delivery_status, r.updated_at = "cancelled", "cancelled", stamp
        creation = db.scalar(select(Outbox).where(Outbox.request_id == r.id, Outbox.kind == "create").with_for_update())
        if creation:
            creation.suppressed = True
            if creation.attempts > 0 or creation.receipt_id:
                queue_cancellation(db, r, creation)
        db.add(RequestEvent(request_id=r.id, status="cancelled", message="Cancelled because the account was deleted."))
    return open_ids


def _undelivered_cancellations(db, customer_id):
    request_ids = select(ServiceRequest.id).where(ServiceRequest.customer_id == customer_id)
    return db.scalars(select(Outbox.id).where(
        Outbox.request_id.in_(request_ids), Outbox.kind == "cancel",
        Outbox.receipt_id.is_(None), Outbox.suppressed.is_(False)).order_by(Outbox.id)).all()


def notify_shops(settings, transport, session_factory, outbox_ids):
    """Deliver this customer's cancellations now, using the same claim/lease pipeline as the worker."""
    with session_factory() as db:
        db.execute(update(Outbox).where(Outbox.id.in_(outbox_ids)).values(next_attempt_at=now())
                   .execution_options(synchronize_session=False))
        db.commit()
    for outbox_id in outbox_ids:
        claimed = delivery.claim(session_factory, outbox_id)
        if claimed is None or claimed == "rejected":
            continue
        token, request_id, kind, payload = claimed
        receipt = delivery.send(settings, transport, request_id, kind, payload)
        delivery.finalize(session_factory, outbox_id, token, request_id, kind, receipt)


def _disconnect_calendar(db, request, customer_id):
    from .calendar_routes import invalidate
    row = db.get(CalendarConnection, customer_id)
    if row is None:
        return
    attempt = db.get(CalendarAttempt, row.attempt_id) if row.attempt_id else None
    invalidate(db, row)
    db.flush()
    if attempt and attempt.nango_connection_id:
        # Best effort: the Nango connection rows are erased below, so a failed
        # revoke cannot be retried by the worker. Google's grant can still be
        # removed by the customer from their Google account.
        try:
            CalendarProvider(request.app.state.settings, request.app.state.calendar_transport).revoke(
                attempt.nango_connection_id, customer_id, attempt.id)
        except CalendarUnavailable:
            log.warning("Calendar revoke deferred to the customer during account deletion")


def erase_customer(db, customer_id):
    """Delete every row the customer owns; returns the private file names to remove afterwards."""
    vehicle_ids = select(Vehicle.id).where(Vehicle.customer_id == customer_id)
    estimate_ids = select(Estimate.id).where(Estimate.customer_id == customer_id)
    request_ids = select(ServiceRequest.id).where(ServiceRequest.customer_id == customer_id)
    outreach_ids = select(ShopOutreach.id).where(ShopOutreach.customer_id == customer_id)
    files = {
        "photos": db.scalars(select(Photo.storage_name).where(Photo.estimate_id.in_(estimate_ids))).all(),
        "vehicle_images": [n for n in db.scalars(select(Vehicle.image_storage_name).where(Vehicle.customer_id == customer_id)) if n],
        "receipts": [n for n in db.scalars(select(KnowledgeReceipt.storage_name).where(KnowledgeReceipt.customer_id == customer_id)) if n],
    }
    statements = (
        delete(CaptureVinSuggestion).where(CaptureVinSuggestion.customer_id == customer_id),
        delete(CaptureReceipt).where(CaptureReceipt.customer_id == customer_id),
        delete(Photo).where(Photo.estimate_id.in_(estimate_ids)),
        delete(EstimateOutbox).where(EstimateOutbox.estimate_id.in_(estimate_ids)),
        delete(Estimate).where(Estimate.customer_id == customer_id),
        delete(Outbox).where(Outbox.request_id.in_(request_ids)),
        delete(RequestEvent).where(RequestEvent.request_id.in_(request_ids)),
        delete(CalendarOperation).where(CalendarOperation.customer_id == customer_id),
        delete(ServiceRequest).where(ServiceRequest.customer_id == customer_id),
        delete(RequestRejection).where(RequestRejection.customer_id == customer_id),
        delete(Repair).where(Repair.customer_id == customer_id),
        delete(Notification).where(Notification.customer_id == customer_id),
        delete(Reminder).where(Reminder.customer_id == customer_id),
        delete(GraphEdge).where(GraphEdge.customer_id == customer_id),
        delete(GraphEntity).where(GraphEntity.customer_id == customer_id),
        delete(KnowledgeReceipt).where(KnowledgeReceipt.customer_id == customer_id),
        delete(KnowledgeRecord).where(KnowledgeRecord.customer_id == customer_id),
        delete(KnowledgeDeletion).where(KnowledgeDeletion.customer_id == customer_id),
        delete(KnowledgeConsentEvent).where(KnowledgeConsentEvent.customer_id == customer_id),
        delete(KnowledgePreference).where(KnowledgePreference.customer_id == customer_id),
        delete(ShopOutbox).where(ShopOutbox.outreach_id.in_(outreach_ids)),
        delete(ShopOutreach).where(ShopOutreach.customer_id == customer_id),
        delete(MyShop).where(MyShop.customer_id == customer_id),
        delete(CalendarProvision).where(CalendarProvision.customer_id == customer_id),
        delete(CalendarAttempt).where(CalendarAttempt.customer_id == customer_id),
        delete(CalendarConnection).where(CalendarConnection.customer_id == customer_id),
        delete(DedicatedShop).where(DedicatedShop.customer_id == customer_id),
        delete(VehicleValuationHistory).where(VehicleValuationHistory.customer_id == customer_id),
        delete(VehicleValuationCache).where(VehicleValuationCache.vehicle_id.in_(vehicle_ids)),
        delete(Vehicle).where(Vehicle.customer_id == customer_id),
        delete(RateBucket).where(RateBucket.customer_id == customer_id),
        delete(Customer).where(Customer.id == customer_id),
    )
    for statement in statements:
        db.execute(statement.execution_options(synchronize_session=False))
    return files


def remove_files(settings, files):
    from .customer_routes import remove_photo_file
    from .receipts import _path as receipt_path
    from .vehicle_images import remove_upload_file
    removed = 0
    for name in files["photos"]:
        remove_photo_file(settings, name)
        removed += 1
    for name in files["vehicle_images"]:
        remove_upload_file(settings, name)
        removed += 1
    for name in files["receipts"]:
        try:
            path = receipt_path(settings, name)
            path.unlink(missing_ok=True)
            path.with_suffix(".pending").unlink(missing_ok=True)
            removed += 1
        except (OSError, ValueError):
            log.warning("Private receipt cleanup failed during account deletion")
    return removed


def remove_sign_in(settings, client, customer_id):
    """Remove the Supabase Auth user so the deleted account cannot be signed into again."""
    key = settings.supabase_service_role_key
    if not settings.supabase_url or not key:
        return False
    url = settings.supabase_url.rstrip("/") + "/auth/v1/admin/users/" + quote(customer_id, safe="")
    headers = {"apikey": key, "Authorization": f"Bearer {key}"}
    try:
        if client is None:
            with create_auth_client() as local:
                response = local.delete(url, headers=headers)
        else:
            response = client.delete(url, headers=headers)
    except httpx.HTTPError:
        log.warning("Auth identity removal failed during account deletion")
        return False
    if response.status_code not in {200, 204, 404}:
        log.warning("Auth identity removal returned %s during account deletion", response.status_code)
        return False
    return True


@router.delete("")
def delete_account(request: Request, c: Customer = Depends(current_customer), db: Session = Depends(db_session)):
    from .customer_routes import consume_rate
    settings = request.app.state.settings
    if c.demo:
        raise HTTPException(403, "The demo account cannot be deleted. Leave the demo instead.")
    customer_id = c.id
    _lock(db, customer_id)
    consume_rate(db, customer_id, "account_delete", MAX_DELETE_ATTEMPTS_PER_HOUR)
    cancelled = cancel_open_requests(db, customer_id)
    db.commit()
    pending = _undelivered_cancellations(db, customer_id)
    db.rollback()
    if pending and settings.bridge_url and settings.bridge_key:
        notify_shops(settings, request.app.state.bridge_transport, request.app.state.session_factory, pending)
        still_pending = _undelivered_cancellations(db, customer_id)
        db.rollback()
        if still_pending:
            raise HTTPException(409, {
                "detail": "Your open shop requests were cancelled, but a shop could not be notified yet. "
                          "Please try again in a few minutes.",
                "code": "open_requests"})
    _lock(db, customer_id)
    _disconnect_calendar(db, request, customer_id)
    files = erase_customer(db, customer_id)
    db.commit()
    removed = remove_files(settings, files)
    authorization = request.headers.get("authorization") or ""
    if authorization.startswith("Bearer "):
        request.app.state.auth_cache.invalidate(authorization[7:])
    sign_in_removed = remove_sign_in(settings, request.app.state.auth_client, customer_id)
    log.info("Customer account deleted: %s files removed, %s open requests cancelled, sign-in removed=%s",
             removed, len(cancelled), sign_in_removed)
    return {"deleted": True, "sign_in_removed": sign_in_removed, "requests_cancelled": len(cancelled),
            "files_removed": removed}

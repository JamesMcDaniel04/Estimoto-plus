"""Customer notifications: an in-app activity feed plus email delivery.

Notices are written by the code paths that already change customer-visible
state (shop request events, estimate snapshots, confirmed shop times and due
reminders). Each carries a dedupe key so replayed events and repeated worker
scans never produce a second notice. Email goes out through the same Resend
account the shop outreach uses, one message per notice, and only while the
customer keeps email updates on.
"""
import json
import logging
import os
from datetime import date, timedelta

import httpx
from fastapi import APIRouter, Depends, Request
from pydantic import BaseModel, ConfigDict, Field
from sqlalchemy import func, or_, select, update
from sqlalchemy.orm import Session

from .auth import current_customer, db_session
from .models import Customer, Provider, Reminder, Vehicle, now
from .notification_models import Notification

router = APIRouter(prefix="/v1/notifications", tags=["customer notifications"])
log = logging.getLogger(__name__)
MAIL_ENDPOINT = "https://api.resend.com/emails"
MAX_MAIL_RESPONSE = 4096
MAX_EMAIL_ATTEMPTS = 8
FEED_LIMIT = 50
REQUEST_TITLES = {
    "accepted": "{provider} accepted your request",
    "declined": "{provider} can't take this request",
    "scheduled": "{provider} scheduled your appointment",
    "completed": "{provider} marked your work complete",
    "cancelled": "{provider} cancelled your request",
}


def notify(db, customer_id, *, kind, title, body, source_kind, source_id, dedupe_key):
    """Insert one notice; a repeated dedupe key is a no-op. The caller commits."""
    if db.get_bind().dialect.name == "postgresql":
        from sqlalchemy.dialects.postgresql import insert
    else:
        from sqlalchemy.dialects.sqlite import insert
    db.execute(insert(Notification).values(
        customer_id=customer_id, kind=kind, title=title[:200], body=body, source_kind=source_kind,
        source_id=source_id, dedupe_key=dedupe_key[:200], created_at=now(), next_email_at=now(),
    ).on_conflict_do_nothing(index_elements=[Notification.customer_id, Notification.dedupe_key]))


def notify_request_event(db, request_row, status, message, scheduled_at, event_id):
    """Called after a provider event is committed for a delivered request."""
    template = REQUEST_TITLES.get(status)
    if template is None:
        return
    provider = db.get(Provider, request_row.provider_id)
    name = provider.name if provider else "Your shop"
    lines = []
    if scheduled_at:
        lines.append(f"Scheduled for {scheduled_at}.")
    if message:
        lines.append(message[:1000])
    notify(db, request_row.customer_id, kind=f"request_{status}", title=template.format(provider=name),
           body="\n".join(lines), source_kind="request", source_id=request_row.id,
           dedupe_key=f"request-event:{event_id or status + ':' + request_row.id}")


def notify_estimate_change(db, estimate, previous_status, previous_amount):
    """Called after a trusted snapshot moved an estimate forward."""
    if estimate.status in {"ready", "approved"} and estimate.amount_cents is not None and (
            previous_status not in {"ready", "approved"} or previous_amount != estimate.amount_cents):
        dollars = f"${estimate.amount_cents / 100:,.2f}"
        shop = estimate.provider_name or "Your shop"
        notify(db, estimate.customer_id, kind="estimate_ready", title=f"{shop} sent your estimate: {dollars}",
               body=f"The {estimate.discipline.upper()} estimate for your vehicle is ready to review in Estimates.",
               source_kind="estimate", source_id=estimate.id,
               dedupe_key=f"estimate:{estimate.id}:ready:{estimate.amount_cents}")
    elif estimate.processing_state == "failed" and previous_status != "failed":
        notify(db, estimate.customer_id, kind="estimate_failed", title="Your estimate needs attention",
               body=estimate.processing_error or "The shop could not process this estimate. Open it for details.",
               source_kind="estimate", source_id=estimate.id, dedupe_key=f"estimate:{estimate.id}:failed")


def notify_shop_confirmed(db, outreach):
    notify(db, outreach.customer_id, kind="shop_confirmed", title=f"{outreach.shop_name} confirmed your time",
           body=f"Confirmed for {outreach.confirmed_slot}. Open My shops for the details.",
           source_kind="outreach", source_id=outreach.id, dedupe_key=f"outreach:{outreach.id}:confirmed")


def scan_due_reminders(session_factory, today: date | None = None):
    """Turn reminders that came due into notices, once per due date or mileage."""
    today = today or now().date()
    created = 0
    with session_factory() as db:
        rows = db.execute(select(Reminder, Vehicle).join(Vehicle, Vehicle.id == Reminder.vehicle_id)
                          .where(Reminder.completed.is_(False),
                                 or_(Reminder.due_date <= today.isoformat(),
                                     Reminder.due_mileage.is_not(None)))
                          .order_by(Reminder.id).limit(500)).all()
        for reminder, vehicle in rows:
            label = vehicle.nickname or f"{vehicle.year} {vehicle.make} {vehicle.model}"
            if reminder.due_date and reminder.due_date <= today.isoformat():
                notify(db, reminder.customer_id, kind="reminder_due", title=f"{reminder.title} is due for {label}",
                       body=f"Due {reminder.due_date}. Mark it complete in Garage once it's done.",
                       source_kind="reminder", source_id=reminder.id,
                       dedupe_key=f"reminder:{reminder.id}:date:{reminder.due_date}")
                created += 1
            elif reminder.due_mileage is not None and vehicle.mileage >= reminder.due_mileage:
                notify(db, reminder.customer_id, kind="reminder_due", title=f"{reminder.title} is due for {label}",
                       body=f"Due at {reminder.due_mileage:,} miles; the vehicle is at {vehicle.mileage:,}.",
                       source_kind="reminder", source_id=reminder.id,
                       dedupe_key=f"reminder:{reminder.id}:mileage:{reminder.due_mileage}")
                created += 1
        db.commit()
    return created


def _mail_config():
    from .saved_shops import _mail_config as shop_mail_config
    return shop_mail_config()


def _post_mail(transport, api_url, key, payload, idempotency_key):
    try:
        with httpx.Client(timeout=10, transport=transport, follow_redirects=False) as client:
            with client.stream("POST", api_url, json=payload, headers={
                    "Authorization": f"Bearer {key}", "Idempotency-Key": idempotency_key}) as response:
                raw = bytearray()
                for chunk in response.iter_bytes(chunk_size=1024):
                    raw.extend(chunk)
                    if len(raw) > MAX_MAIL_RESPONSE:
                        return "retry", None
                status = response.status_code
        decoded = json.loads(raw) if raw else {}
    except (httpx.HTTPError, ValueError, UnicodeDecodeError):
        return "retry", None
    if status in {200, 201, 202} and isinstance(decoded, dict):
        receipt = decoded.get("id")
        if isinstance(receipt, str) and 0 < len(receipt) <= 200:
            return "sent", receipt
    if status in {400, 401, 403, 404, 422} or (
            status == 409 and isinstance(decoded, dict) and decoded.get("name") == "invalid_idempotent_request"):
        return "failed", None
    return "retry", None


def deliver_notification_emails(session_factory, transport=None, *, api_url=MAIL_ENDPOINT):
    """Bounded at-least-once email delivery; Resend's idempotency key prevents duplicates."""
    sent = skipped = failed = 0
    with session_factory() as db:
        ids = db.scalars(select(Notification.id).where(
            Notification.email_status == "pending", Notification.next_email_at <= now())
            .order_by(Notification.next_email_at, Notification.id).limit(20)).all()
    for notification_id in ids:
        with session_factory() as db:
            row = db.get(Notification, notification_id)
            customer = db.get(Customer, row.customer_id) if row else None
            if row is None or row.email_status != "pending":
                continue
            if customer is None or customer.demo or not customer.notification_emails:
                row.email_status = "skipped"
                db.commit()
                skipped += 1
                continue
            mail = _mail_config()
            if mail is None:
                # Email is not configured; keep the notice in the app and look again later.
                row.next_email_at = now() + timedelta(minutes=15)
                db.commit()
                continue
            key, sender, _ = mail
            payload = {"from": sender, "to": [customer.email], "subject": row.title,
                       "text": f"{row.title}\n\n{row.body}\n\nOpen Estimoto + to see the details. "
                               "You can turn these emails off in Settings."}
            row.email_attempts += 1
            attempts = row.email_attempts
            db.commit()
        outcome, receipt = _post_mail(transport, api_url, key, payload, f"customer-notification:{notification_id}")
        with session_factory() as db:
            row = db.get(Notification, notification_id)
            if outcome == "sent":
                row.email_status, row.email_receipt = "sent", receipt
                sent += 1
            elif outcome == "failed" or attempts >= MAX_EMAIL_ATTEMPTS:
                row.email_status = "failed"
                failed += 1
            else:
                row.next_email_at = now() + timedelta(seconds=min(3600, 30 * 2 ** min(attempts, 7)))
            db.commit()
    return {"sent": sent, "skipped": skipped, "failed": failed}


def unread_count(db, customer_id):
    return db.scalar(select(func.count(Notification.id)).where(
        Notification.customer_id == customer_id, Notification.read_at.is_(None))) or 0


def notification_view(row):
    return {"id": row.id, "kind": row.kind, "title": row.title, "body": row.body,
            "source_kind": row.source_kind, "source_id": row.source_id,
            "created_at": row.created_at.isoformat(), "read_at": row.read_at.isoformat() if row.read_at else None}


class ReadWrite(BaseModel):
    model_config = ConfigDict(extra="forbid")
    ids: list[str] = Field(default_factory=list, max_length=200)
    all: bool = False


class PreferenceWrite(BaseModel):
    model_config = ConfigDict(extra="forbid")
    email_updates: bool


@router.get("")
def feed(c: Customer = Depends(current_customer), db: Session = Depends(db_session)):
    rows = db.scalars(select(Notification).where(Notification.customer_id == c.id)
                      .order_by(Notification.created_at.desc(), Notification.id.desc()).limit(FEED_LIMIT)).all()
    return {"notifications": [notification_view(r) for r in rows], "unread": unread_count(db, c.id),
            "email_updates": bool(c.notification_emails)}


@router.post("/read")
def mark_read(body: ReadWrite, c: Customer = Depends(current_customer), db: Session = Depends(db_session)):
    statement = update(Notification).where(Notification.customer_id == c.id, Notification.read_at.is_(None))
    if not body.all:
        statement = statement.where(Notification.id.in_([i[:36] for i in body.ids]))
    db.execute(statement.values(read_at=now()).execution_options(synchronize_session=False))
    db.commit()
    return {"unread": unread_count(db, c.id)}


@router.put("/preferences")
def preferences(body: PreferenceWrite, c: Customer = Depends(current_customer), db: Session = Depends(db_session)):
    c.notification_emails = body.email_updates
    db.add(c)
    db.commit()
    return {"email_updates": bool(c.notification_emails)}


def mail_api_url(request: Request):
    settings = request.app.state.settings
    return os.getenv("RESEND_API_URL", MAIL_ENDPOINT) if settings.environment != "production" else MAIL_ENDPOINT

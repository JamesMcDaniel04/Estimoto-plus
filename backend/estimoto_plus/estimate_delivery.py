"""Durable creation, processing, and status polling for submitted estimates."""
import json
from datetime import timedelta
from uuid import uuid4

import httpx
from pydantic import ValidationError
from sqlalchemy import or_, select, update

from .estimate_workflow import apply_submitted_snapshot
from .bridge_sync import sync_providers
from .models import Estimate, EstimateOutbox, Provider, now
from .schemas import EstimateSnapshot
from .workflow import payload_hash

LEASE_SECONDS = 120
MAX_BRIDGE_RESPONSE = 64 * 1024


def due_estimate_ids(session_factory):
    with session_factory() as db:
        current = now()
        return db.scalars(select(EstimateOutbox.id).where(
            EstimateOutbox.finished_at.is_(None), EstimateOutbox.next_attempt_at <= current,
            or_(EstimateOutbox.claim_token.is_(None), EstimateOutbox.lease_until <= current),
        ).order_by(EstimateOutbox.next_attempt_at, EstimateOutbox.id).limit(20)).all()


def claim_estimate(session_factory, outbox_id):
    from .discovery import valid_admission
    with session_factory() as db:
        estimate_id = db.scalar(select(EstimateOutbox.estimate_id).where(EstimateOutbox.id == outbox_id))
        db.rollback()
        if not estimate_id:
            return None
        changed = db.execute(update(Estimate).where(Estimate.id == estimate_id)
                             .values(updated_at=Estimate.updated_at).returning(Estimate.id)).first()
        if not changed:
            db.rollback()
            return None
        db.expire_all()
        estimate = db.get(Estimate, estimate_id)
        item = db.get(EstimateOutbox, outbox_id)
        if not item or item.finished_at:
            db.rollback()
            return None
        payload = item.payload
        valid = (isinstance(payload, dict) and payload_hash(payload) == item.payload_hash and
                 payload.get("estimate_id") == estimate_id and payload.get("customer_id") == estimate.customer_id and
                 payload.get("vehicle_id") == estimate.vehicle_id and estimate.status != "draft")
        if not valid:
            estimate.delivery_status = "failed"
            estimate.processing_state = "failed"
            estimate.processing_error = "Submitted estimate data could not be verified. Contact support."
            item.next_attempt_at = now() + timedelta(hours=1)
            db.commit()
            return "failed"
        if item.receipt_id is None:
            provider = db.scalar(select(Provider).where(Provider.id == estimate.provider_id).with_for_update())
            if (not provider or not provider.public_visible or not provider.accepting_requests or provider.demo_only or
                    provider.kind != "shop" or estimate.discipline not in provider.specialties or
                    payload.get('service_mode') != estimate.service_mode or
                    not valid_admission(
                        provider, payload.get('service_postal_code'), estimate.service_mode, estimate.discovery_admission) or
                    payload.get("provider_source_id") != provider.source_id):
                estimate.delivery_status = "failed"
                estimate.processing_state = "failed"
                estimate.processing_error = "Selected provider is no longer accepting this estimate. Contact support."
                item.next_attempt_at = now() + timedelta(hours=1)
                db.commit()
                return "failed"
            phase = "create"
        else:
            phase = "poll" if estimate.processing_state == "complete" else "process"
        current = now()
        token = str(uuid4())
        claimed = db.execute(update(EstimateOutbox).where(
            EstimateOutbox.id == outbox_id, EstimateOutbox.finished_at.is_(None),
            EstimateOutbox.next_attempt_at <= current,
            or_(EstimateOutbox.claim_token.is_(None), EstimateOutbox.lease_until <= current),
        ).values(claim_token=token, lease_until=current + timedelta(seconds=LEASE_SECONDS),
                 attempts=EstimateOutbox.attempts + 1).returning(EstimateOutbox.id)
            .execution_options(synchronize_session=False)).first()
        if not claimed:
            db.rollback()
            return None
        db.commit()
        return token, estimate_id, phase, payload


def send_phase(settings, transport, estimate_id, phase, payload):
    url = settings.estimate_bridge_url.rstrip("/")
    if phase != "create":
        url += f"/{estimate_id}" + ("/process" if phase == "process" else "")
    headers = {"X-Bridge-Key": settings.bridge_key,
               "Idempotency-Key": f"estimate:{estimate_id}" if phase == "create" else f"process:{estimate_id}"}
    try:
        with httpx.Client(timeout=65 if phase == "process" else 10, transport=transport) as client:
            with client.stream("GET" if phase == "poll" else "POST", url,
                               **({"json": payload} if phase == "create" else {}), headers=headers) as response:
                if response.status_code not in {200, 201, 202}:
                    return None
                raw = bytearray()
                for chunk in response.iter_bytes(chunk_size=4096):
                    raw.extend(chunk)
                    if len(raw) > MAX_BRIDGE_RESPONSE:
                        return None
        decoded = json.loads(raw)
    except (httpx.HTTPError, ValueError, UnicodeDecodeError):
        return None
    if not isinstance(decoded, dict):
        return None
    if phase == "create":
        receipt = decoded.get("receipt_id")
        return receipt if isinstance(receipt, str) and receipt.strip() and len(receipt) <= 200 else None
    try:
        return EstimateSnapshot.model_validate(decoded)
    except ValidationError:
        return None


def finalize_estimate(session_factory, outbox_id, token, estimate_id, phase, result):
    with session_factory() as db:
        changed = db.execute(update(Estimate).where(Estimate.id == estimate_id)
                             .values(updated_at=Estimate.updated_at).returning(Estimate.id)).first()
        if not changed:
            db.rollback()
            return None
        db.expire_all()
        estimate = db.get(Estimate, estimate_id)
        item = db.get(EstimateOutbox, outbox_id)
        if not item or item.claim_token != token or item.finished_at:
            db.rollback()
            return None
        current = now()
        success = result is not None
        if phase == "create" and success:
            item.receipt_id = result
            estimate.delivery_status = "delivered"
            estimate.processing_state = "pending"
            estimate.processing_error = None
            item.next_attempt_at = current
        elif phase != "create" and success:
            previous_status, previous_amount = estimate.status, estimate.amount_cents
            try:
                apply_submitted_snapshot(db, estimate, result, item.payload)
            except ValueError:
                success = False
            else:
                estimate.updated_at = current
                from .notifications import notify_estimate_change
                notify_estimate_change(db, estimate, previous_status, previous_amount)
                item.next_attempt_at = current + timedelta(seconds=300 if estimate.processing_state == "complete" else 15)
                if estimate.status == "approved" or estimate.processing_state == "failed":
                    item.finished_at = current
        if not success:
            if phase == "create":
                estimate.delivery_status = "failed"
            else:
                if phase == "process":
                    estimate.processing_state = "pending"
                estimate.processing_error = "Estimate processing or status sync is unavailable. Retrying."
            item.next_attempt_at = current + timedelta(seconds=min(3600, 2 ** min(item.attempts, 10)))
        updated = db.execute(update(EstimateOutbox).where(
            EstimateOutbox.id == outbox_id, EstimateOutbox.claim_token == token,
        ).values(claim_token=None, lease_until=None,
                 receipt_id=item.receipt_id, next_attempt_at=item.next_attempt_at,
                 finished_at=item.finished_at).returning(EstimateOutbox.id)
            .execution_options(synchronize_session=False)).first()
        if not updated:
            db.rollback()
            return None
        db.commit()
        return success


def deliver_estimate_batch(settings, transport, session_factory):
    delivered = failed = 0
    ids = due_estimate_ids(session_factory)
    pending_create = set()
    if ids and settings.environment == "production":
        with session_factory() as db:
            pending_create = set(db.scalars(select(EstimateOutbox.id).where(
                EstimateOutbox.id.in_(ids), EstimateOutbox.receipt_id.is_(None))).all())
    catalog_ok = sync_providers(settings, transport, session_factory) if pending_create else True
    for outbox_id in ids:
        if outbox_id in pending_create and not catalog_ok:
            continue
        claimed = claim_estimate(session_factory, outbox_id)
        if claimed is None:
            continue
        if claimed == "failed":
            failed += 1
            continue
        token, estimate_id, phase, payload = claimed
        result = send_phase(settings, transport, estimate_id, phase, payload)
        outcome = finalize_estimate(session_factory, outbox_id, token, estimate_id, phase, result)
        if outcome is True:
            delivered += 1
        elif outcome is False:
            failed += 1
    return {"delivered": delivered, "failed": failed}

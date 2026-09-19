"""First-party crash and error reports from the app.

Reports are anonymous by construction: no customer id, token, IP or device
identifier is stored, and obvious personal data (email addresses, phone
numbers) is redacted before storage. Identical errors on the same day fold
into one row, so a crash loop cannot grow the table, and rows older than 30
days are pruned by the worker. Operators read them through the bridge key.
"""
import hashlib
import re
from datetime import timedelta
from typing import Literal

from fastapi import APIRouter, Depends, Request
from pydantic import BaseModel, ConfigDict, Field
from sqlalchemy import delete, select
from sqlalchemy.orm import Session

from .auth import bridge_authorized, db_session
from .models import now
from .notification_models import ClientError

router = APIRouter(tags=["client errors"])
RETENTION_DAYS = 30
_EMAIL = re.compile(r"[^\s@<>]+@[^\s@<>]+\.[^\s@<>]+")
_PHONE = re.compile(r"(?<!\d)(?:\+?\d[\s().-]*){7,15}(?!\d)")
_TOKEN = re.compile(r"\b(?:ey[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}|sb_[a-z]+_[A-Za-z0-9_-]{10,})")


def scrub(text: str) -> str:
    text = _TOKEN.sub("[redacted]", text)
    text = _EMAIL.sub("[email]", text)
    return _PHONE.sub("[number]", text)


class ClientErrorReport(BaseModel):
    model_config = ConfigDict(extra="forbid", str_strip_whitespace=True)
    platform: Literal["ios", "android", "web", "other"]
    app_version: str = Field(default="", max_length=40)
    build_number: str = Field(default="", max_length=20)
    source_sha: str = Field(default="", max_length=40)
    kind: str = Field(min_length=1, max_length=100)
    message: str = Field(default="", max_length=500)
    stack: str = Field(default="", max_length=4000)


def fingerprint(report: ClientErrorReport, kind: str, message: str, stack: str) -> str:
    frames = "\n".join(line for line in stack.splitlines() if line.strip())[:600]
    digest = hashlib.sha256("\n".join((report.platform, report.app_version, kind, message[:120], frames)).encode())
    return digest.hexdigest()


@router.post("/v1/client-errors", status_code=202)
def report_client_error(body: ClientErrorReport, db: Session = Depends(db_session)):
    kind, message, stack = scrub(body.kind), scrub(body.message), scrub(body.stack)
    stamp = now()
    day = stamp.date().isoformat()
    key = fingerprint(body, kind, message, stack)
    existing = db.scalar(select(ClientError).where(ClientError.fingerprint == key, ClientError.day == day))
    if existing:
        existing.occurrences += 1
        existing.last_seen_at = stamp
    else:
        if db.get_bind().dialect.name == "postgresql":
            from sqlalchemy.dialects.postgresql import insert
        else:
            from sqlalchemy.dialects.sqlite import insert
        db.execute(insert(ClientError).values(
            fingerprint=key, day=day, platform=body.platform, app_version=body.app_version,
            build_number=body.build_number, source_sha=body.source_sha, kind=kind[:100], message=message[:500],
            stack=stack[:4000], occurrences=1, first_seen_at=stamp, last_seen_at=stamp,
        ).on_conflict_do_nothing(index_elements=[ClientError.fingerprint, ClientError.day]))
    db.commit()
    return {"accepted": True}


def prune_client_errors(session_factory):
    cutoff = now() - timedelta(days=RETENTION_DAYS)
    with session_factory() as db:
        removed = db.execute(delete(ClientError).where(ClientError.last_seen_at < cutoff)).rowcount
        db.commit()
    return removed


@router.get("/v1/bridge/client-errors", dependencies=[Depends(bridge_authorized)])
def list_client_errors(request: Request, db: Session = Depends(db_session)):
    rows = db.scalars(select(ClientError).order_by(ClientError.last_seen_at.desc()).limit(100)).all()
    return {"errors": [{"fingerprint": r.fingerprint, "day": r.day, "platform": r.platform, "app_version": r.app_version,
                        "build_number": r.build_number, "source_sha": r.source_sha, "kind": r.kind, "message": r.message,
                        "stack": r.stack, "occurrences": r.occurrences, "first_seen_at": r.first_seen_at.isoformat(),
                        "last_seen_at": r.last_seen_at.isoformat()} for r in rows]}

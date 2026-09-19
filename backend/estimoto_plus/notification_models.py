"""Customer-facing activity: durable per-customer notices with optional email delivery."""
from datetime import datetime

from sqlalchemy import DateTime, ForeignKey, Index, Integer, String, Text, UniqueConstraint
from sqlalchemy.orm import Mapped, mapped_column

from .models import Base, now, uid


class Notification(Base):
    __tablename__ = "customer_notifications"
    __table_args__ = (UniqueConstraint("customer_id", "dedupe_key"),
                      Index("ix_customer_notifications_email_due", "email_status", "next_email_at"))
    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=uid)
    customer_id: Mapped[str] = mapped_column(ForeignKey("customers.id"), index=True)
    kind: Mapped[str] = mapped_column(String(40))
    title: Mapped[str] = mapped_column(String(200))
    body: Mapped[str] = mapped_column(Text, default="")
    source_kind: Mapped[str] = mapped_column(String(20))
    source_id: Mapped[str | None] = mapped_column(String(36), nullable=True)
    dedupe_key: Mapped[str] = mapped_column(String(200))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=now)
    read_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    # pending -> sent | skipped | failed. Skipped means the customer turned emails off.
    email_status: Mapped[str] = mapped_column(String(20), default="pending")
    email_attempts: Mapped[int] = mapped_column(Integer, default=0)
    next_email_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=now)
    email_receipt: Mapped[str | None] = mapped_column(String(200), nullable=True)


class ClientError(Base):
    """Anonymous diagnostic reports from the app; never linked to a customer."""
    __tablename__ = "client_errors"
    __table_args__ = (UniqueConstraint("fingerprint", "day"),)
    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=uid)
    fingerprint: Mapped[str] = mapped_column(String(64))
    day: Mapped[str] = mapped_column(String(10))
    platform: Mapped[str] = mapped_column(String(20))
    app_version: Mapped[str] = mapped_column(String(40), default="")
    build_number: Mapped[str] = mapped_column(String(20), default="")
    source_sha: Mapped[str] = mapped_column(String(40), default="")
    kind: Mapped[str] = mapped_column(String(100))
    message: Mapped[str] = mapped_column(String(500), default="")
    stack: Mapped[str] = mapped_column(Text, default="")
    occurrences: Mapped[int] = mapped_column(Integer, default=1)
    first_seen_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=now)
    last_seen_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=now)

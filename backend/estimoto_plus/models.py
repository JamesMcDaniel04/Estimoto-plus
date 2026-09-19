from datetime import datetime, timezone
from uuid import uuid4

from sqlalchemy import Boolean, DateTime, ForeignKey, Index, Integer, JSON, LargeBinary, String, Text, UniqueConstraint
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column


def uid():
    return str(uuid4())


def now():
    return datetime.now(timezone.utc)


class Base(DeclarativeBase):
    pass


class Customer(Base):
    __tablename__ = "customers"
    id: Mapped[str] = mapped_column(String(100), primary_key=True)
    email: Mapped[str] = mapped_column(String(320))
    name: Mapped[str] = mapped_column(String(200), default="")
    phone: Mapped[str] = mapped_column(String(50), default="")
    postal_code: Mapped[str] = mapped_column(String(30), default="")
    contact_preference: Mapped[str] = mapped_column(String(10), default="email")
    demo: Mapped[bool] = mapped_column(Boolean, default=False)
    notification_emails: Mapped[bool] = mapped_column(Boolean, default=True)


class RateBucket(Base):
    __tablename__ = "rate_buckets"
    customer_id: Mapped[str] = mapped_column(ForeignKey("customers.id"), primary_key=True)
    action: Mapped[str] = mapped_column(String(30), primary_key=True)
    hour_bucket: Mapped[int] = mapped_column(Integer, primary_key=True)
    count: Mapped[int] = mapped_column(Integer, default=0)


class Vehicle(Base):
    __tablename__ = "vehicles"
    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=uid)
    customer_id: Mapped[str] = mapped_column(ForeignKey("customers.id"), index=True)
    nickname: Mapped[str] = mapped_column(String(100), default="")
    year: Mapped[int] = mapped_column(Integer)
    make: Mapped[str] = mapped_column(String(100))
    model: Mapped[str] = mapped_column(String(100))
    vin: Mapped[str] = mapped_column(String(40), default="")
    mileage: Mapped[int] = mapped_column(Integer, default=0)
    insurer: Mapped[str] = mapped_column(String(100), default="")
    policy_number: Mapped[str] = mapped_column(String(100), default="")
    image_storage_name: Mapped[str | None] = mapped_column(String(36), nullable=True)
    image_version: Mapped[str | None] = mapped_column(String(64), nullable=True)
    image_byte_size: Mapped[int | None] = mapped_column(Integer, nullable=True)


class VehicleImageCache(Base):
    """Representative stock bytes only; never contains customer uploads or VINs."""
    __tablename__ = "vehicle_image_cache"
    cache_key: Mapped[str] = mapped_column(String(64), primary_key=True)
    image_data: Mapped[bytes | None] = mapped_column(LargeBinary, nullable=True)
    retry_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    lease_token: Mapped[str | None] = mapped_column(String(36), nullable=True)
    lease_until: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)


class VehicleImageProviderState(Base):
    __tablename__ = "vehicle_image_provider_state"
    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    day_bucket: Mapped[int] = mapped_column(Integer, default=0)
    count: Mapped[int] = mapped_column(Integer, default=0)
    blocked_until: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)


class Provider(Base):
    __tablename__ = "providers"
    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=uid)
    source_id: Mapped[str] = mapped_column(String(100), unique=True)
    name: Mapped[str] = mapped_column(String(200))
    kind: Mapped[str] = mapped_column(String(20))
    specialties: Mapped[list] = mapped_column(JSON)
    postal_codes: Mapped[list] = mapped_column(JSON)
    city: Mapped[str] = mapped_column(String(120), default="")
    address: Mapped[str] = mapped_column(String(300), default="")
    phone: Mapped[str] = mapped_column(String(50), default="")
    mobile_service: Mapped[bool] = mapped_column(Boolean, default=False)
    accepting_requests: Mapped[bool] = mapped_column(Boolean, default=False)
    public_visible: Mapped[bool] = mapped_column(Boolean, default=False)
    demo_only: Mapped[bool] = mapped_column(Boolean, default=False)
    description: Mapped[str] = mapped_column(Text, default="")
    media: Mapped[dict | None] = mapped_column(JSON, nullable=True)


class CalendarSourceMixin:
    calendar_last_scan_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True, index=True)
    calendar_check: Mapped[bool] = mapped_column(Boolean, default=False)
    duration_minutes: Mapped[int] = mapped_column(Integer, default=60)
    calendar_generation: Mapped[int | None] = mapped_column(Integer, nullable=True)
    calendar_selected_ids: Mapped[list] = mapped_column(JSON, default=list)
    calendar_time_zone: Mapped[str | None] = mapped_column(String(100), nullable=True)
    calendar_sync_enabled: Mapped[bool] = mapped_column(Boolean, default=False)
    calendar_sync_status: Mapped[str] = mapped_column(String(30), default="not_enabled")
    calendar_sync_message: Mapped[str | None] = mapped_column(String(300), nullable=True)


class DiscoverySourceMixin:
    service_mode: Mapped[str | None] = mapped_column(String(20), nullable=True)
    discovery_admission: Mapped[dict] = mapped_column(JSON, default=dict)


class ServiceRequest(CalendarSourceMixin, DiscoverySourceMixin, Base):
    __tablename__ = "service_requests"
    __table_args__ = (UniqueConstraint("customer_id", "idempotency_key"),)
    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=uid)
    customer_id: Mapped[str] = mapped_column(ForeignKey("customers.id"), index=True)
    vehicle_id: Mapped[str] = mapped_column(ForeignKey("vehicles.id"))
    provider_id: Mapped[str] = mapped_column(ForeignKey("providers.id"))
    specialty: Mapped[str] = mapped_column(String(30))
    description: Mapped[str] = mapped_column(Text)
    preferred_time: Mapped[str] = mapped_column(String(200), default="")
    proposed_slots: Mapped[list] = mapped_column(JSON, default=list)
    status: Mapped[str] = mapped_column(String(20), default="requested")
    delivery_status: Mapped[str] = mapped_column(String(20), default="queued")
    idempotency_key: Mapped[str] = mapped_column(String(200))
    payload_hash: Mapped[str] = mapped_column(String(64))
    service_postal_code: Mapped[str] = mapped_column(String(5), default="")
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=now)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=now)
    scheduled_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    last_status_poll_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)


class RequestRejection(Base):
    __tablename__ = "request_rejections"
    customer_id: Mapped[str] = mapped_column(ForeignKey("customers.id"), primary_key=True)
    idempotency_key: Mapped[str] = mapped_column(String(200), primary_key=True)
    payload_hash: Mapped[str] = mapped_column(String(64))
    status_code: Mapped[int] = mapped_column(Integer)
    detail: Mapped[str] = mapped_column(String(200))
    code: Mapped[str] = mapped_column(String(40), default="request_not_created")


class RequestEvent(Base):
    __tablename__ = "request_events"
    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=uid)
    request_id: Mapped[str] = mapped_column(ForeignKey("service_requests.id"), index=True)
    event_id: Mapped[str | None] = mapped_column(String(100), unique=True, nullable=True)
    status: Mapped[str] = mapped_column(String(20))
    message: Mapped[str] = mapped_column(Text, default="")
    scheduled_at: Mapped[str | None] = mapped_column(String(40), nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=now)


class Outbox(Base):
    __tablename__ = "outbox"
    __table_args__ = (UniqueConstraint("request_id", "kind"),)
    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=uid)
    request_id: Mapped[str] = mapped_column(ForeignKey("service_requests.id"))
    kind: Mapped[str] = mapped_column(String(20), default="create")
    attempts: Mapped[int] = mapped_column(Integer, default=0)
    next_attempt_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=now)
    receipt_id: Mapped[str | None] = mapped_column(String(200), nullable=True)
    payload: Mapped[dict | None] = mapped_column(JSON, nullable=True)
    payload_hash: Mapped[str | None] = mapped_column(String(64), nullable=True)
    claim_token: Mapped[str | None] = mapped_column(String(36), nullable=True)
    lease_until: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    suppressed: Mapped[bool] = mapped_column(Boolean, default=False)


class Estimate(DiscoverySourceMixin, Base):
    __tablename__ = "estimates"
    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=uid)
    customer_id: Mapped[str] = mapped_column(ForeignKey("customers.id"), index=True)
    vehicle_id: Mapped[str] = mapped_column(ForeignKey("vehicles.id"))
    source_id: Mapped[str | None] = mapped_column(String(100), unique=True, nullable=True)
    provider_id: Mapped[str | None] = mapped_column(ForeignKey("providers.id"), nullable=True)
    submission_key: Mapped[str | None] = mapped_column(String(200), nullable=True)
    submission_request_hash: Mapped[str | None] = mapped_column(String(64), nullable=True)
    delivery_status: Mapped[str] = mapped_column(String(20), default="draft")
    processing_state: Mapped[str] = mapped_column(String(20), default="not_started")
    processing_error: Mapped[str | None] = mapped_column(String(500), nullable=True)
    discipline: Mapped[str] = mapped_column(String(20))
    description: Mapped[str] = mapped_column(Text)
    claim_number: Mapped[str] = mapped_column(String(100), default="")
    date_of_loss: Mapped[str | None] = mapped_column(String(10), nullable=True)
    status: Mapped[str] = mapped_column(String(20), default="draft")
    amount_cents: Mapped[int | None] = mapped_column(Integer, nullable=True)
    provider_name: Mapped[str] = mapped_column(String(200), default="")
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=now)


class Photo(Base):
    __tablename__ = "photos"
    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=uid)
    estimate_id: Mapped[str] = mapped_column(ForeignKey("estimates.id"), index=True)
    label: Mapped[str] = mapped_column(String(100))
    mime_type: Mapped[str] = mapped_column(String(50))
    storage_name: Mapped[str] = mapped_column(String(36), unique=True)
    sha256: Mapped[str | None] = mapped_column(String(64), nullable=True)
    byte_size: Mapped[int | None] = mapped_column(Integer, nullable=True)


class EstimateOutbox(Base):
    __tablename__ = "estimate_outbox"
    __table_args__ = (Index("ix_estimate_outbox_due", "next_attempt_at"),)
    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=uid)
    estimate_id: Mapped[str] = mapped_column(ForeignKey("estimates.id"), unique=True)
    payload: Mapped[dict] = mapped_column(JSON)
    payload_hash: Mapped[str] = mapped_column(String(64))
    attempts: Mapped[int] = mapped_column(Integer, default=0)
    next_attempt_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=now)
    claim_token: Mapped[str | None] = mapped_column(String(36), nullable=True)
    lease_until: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    receipt_id: Mapped[str | None] = mapped_column(String(200), nullable=True)
    finished_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)


class Repair(Base):
    __tablename__ = "repairs"
    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=uid)
    customer_id: Mapped[str] = mapped_column(ForeignKey("customers.id"), index=True)
    vehicle_id: Mapped[str] = mapped_column(ForeignKey("vehicles.id"))
    source_id: Mapped[str] = mapped_column(String(100), unique=True)
    provider_name: Mapped[str] = mapped_column(String(200))
    title: Mapped[str] = mapped_column(String(200))
    status: Mapped[str] = mapped_column(String(50))
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=now)
    estimated_completion: Mapped[str | None] = mapped_column(String(10), nullable=True)
    stages: Mapped[list] = mapped_column(JSON)


class Reminder(Base):
    __tablename__ = "reminders"
    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=uid)
    customer_id: Mapped[str] = mapped_column(ForeignKey("customers.id"), index=True)
    vehicle_id: Mapped[str] = mapped_column(ForeignKey("vehicles.id"))
    title: Mapped[str] = mapped_column(String(200))
    due_date: Mapped[str | None] = mapped_column(String(10), nullable=True)
    due_mileage: Mapped[int | None] = mapped_column(Integer, nullable=True)
    completed: Mapped[bool] = mapped_column(Boolean, default=False)

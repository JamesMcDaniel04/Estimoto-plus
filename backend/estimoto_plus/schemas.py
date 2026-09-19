from __future__ import annotations
from .calendar_scheduling import CalendarChecked

from datetime import date as Date, datetime
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator

from .postal import canonical_zip


class Strict(BaseModel):
    model_config = ConfigDict(extra="forbid")


class ProfileWrite(Strict):
    name: str = Field(default="", max_length=200)
    phone: str = Field(default="", max_length=50)
    postal_code: str = Field(default="", max_length=30)
    contact_preference: Literal["email", "phone"] = "email"

    @field_validator("postal_code")
    @classmethod
    def valid_postal(cls, value):
        if not value.strip():
            return ""
        result = canonical_zip(value)
        if result is None:
            raise ValueError("Enter a valid ZIP code")
        return result


class VehicleCreate(Strict):
    year: int = Field(ge=1886, le=2100)
    make: str = Field(min_length=1, max_length=100)
    model: str = Field(min_length=1, max_length=100)
    nickname: str = Field(default="", max_length=100)
    vin: str = Field(default="", max_length=40)
    mileage: int = Field(default=0, ge=0, le=5_000_000)
    insurer: str = Field(default="", max_length=100)
    policy_number: str = Field(default="", max_length=100)


class VehicleUpdate(Strict):
    year: int | None = Field(default=None, ge=1886, le=2100)
    make: str | None = Field(default=None, min_length=1, max_length=100)
    model: str | None = Field(default=None, min_length=1, max_length=100)
    nickname: str | None = Field(default=None, max_length=100)
    vin: str | None = Field(default=None, max_length=40)
    mileage: int | None = Field(default=None, ge=0, le=5_000_000)
    insurer: str | None = Field(default=None, max_length=100)
    policy_number: str | None = Field(default=None, max_length=100)

    @model_validator(mode="after")
    def reject_supplied_nulls(self):
        if any(getattr(self, name) is None for name in self.model_fields_set):
            raise ValueError("Vehicle fields cannot be null")
        return self


class EstimateCreate(Strict):
    vehicle_id: str = Field(max_length=36)
    discipline: Literal["pdr", "collision"]
    description: str = Field(min_length=1, max_length=2000)
    claim_number: str = Field(default="", max_length=100)
    date_of_loss: Date | None = None


class EstimateSubmit(Strict):
    service_mode: Literal['shop_visit', 'mobile'] | None = None
    provider_id: str = Field(min_length=1, max_length=36)
    share_contact: Literal[True]


class ReminderCreate(Strict):
    vehicle_id: str = Field(max_length=36)
    title: str = Field(min_length=1, max_length=200)
    due_date: Date | None = None
    due_mileage: int | None = Field(default=None, ge=0, le=5_000_000)

    @model_validator(mode="after")
    def due_required(self):
        if self.due_date is None and self.due_mileage is None:
            raise ValueError("A date or mileage is required")
        return self


class ReminderUpdate(Strict):
    @field_validator('vehicle_id', 'title')
    @classmethod
    def nonempty(cls, value):
        if value is None or not value.strip():
            raise ValueError('This field cannot be empty')
        return value.strip()

    vehicle_id: str | None = Field(default=None, max_length=36)
    title: str | None = Field(default=None, min_length=1, max_length=200)
    due_date: Date | None = None
    due_mileage: int | None = Field(default=None, ge=0, le=5_000_000)


class EstimateUpdate(Strict):
    @field_validator('description', 'claim_number')
    @classmethod
    def not_null(cls, value, info):
        if value is None or (info.field_name == 'description' and not value.strip()):
            raise ValueError('This field cannot be empty')
        return value.strip()

    description: str | None = Field(default=None, min_length=1, max_length=2000)
    claim_number: str | None = Field(default=None, max_length=100)
    date_of_loss: Date | None = None


class RequestCreate(Strict, CalendarChecked):
    service_mode: Literal['shop_visit', 'mobile'] | None = None
    vehicle_id: str = Field(max_length=36)
    provider_id: str = Field(max_length=36)
    specialty: Literal["pdr", "collision", "maintenance", "mechanical"]
    description: str = Field(min_length=1, max_length=5000)
    preferred_time: str = Field(default="", max_length=200)
    proposed_slots: list[datetime] = Field(default_factory=list, max_length=3)

    @field_validator('proposed_slots', mode='before')
    @classmethod
    def slot_strings(cls, values):
        if not isinstance(values, list) or any(not isinstance(v, str) for v in values):
            raise ValueError('Slots require ISO timestamps.')
        return values

    @field_validator('proposed_slots')
    @classmethod
    def aware_slots(cls, values):
        from datetime import timezone
        if any(v.tzinfo is None or v.utcoffset() is None for v in values) or len(set(values)) != len(values):
            raise ValueError('Choose distinct offset-aware times.')
        try:
            return [v.astimezone(timezone.utc) for v in values]
        except OverflowError:
            raise ValueError('Choose a valid appointment date.') from None

    share_contact: Literal[True]


class AssistantInput(Strict):
    message: str = Field(min_length=1, max_length=2000)
    vehicle_id: str | None = Field(default=None, max_length=36)
    postal_code: str | None = Field(default=None, max_length=30)
    specialty: Literal["pdr", "collision", "maintenance", "mechanical"] | None = None
    mobile_only: bool = False

    @field_validator("postal_code")
    @classmethod
    def assistant_postal(cls, value):
        if value is None or not value.strip():
            return None
        result = canonical_zip(value)
        if result is None:
            raise ValueError("Enter a valid ZIP code")
        return result


class PublishedMedia(Strict):
    url: str = Field(min_length=1, max_length=500)
    kind: Literal['logo', 'photo']
    attribution: str = Field(min_length=1, max_length=250)
    source_url: str = Field(min_length=1, max_length=500)


class ProviderPublish(Strict):
    source_id: str = Field(min_length=1, max_length=100)
    name: str = Field(min_length=1, max_length=200)
    kind: Literal["shop", "technician"]
    specialties: list[Literal["pdr", "collision", "maintenance", "mechanical"]] = Field(max_length=4)
    postal_codes: list[str] = Field(max_length=2000)
    city: str = Field(default="", max_length=120)
    address: str = Field(default="", max_length=300)
    phone: str = Field(default="", max_length=50)
    mobile_service: bool = False
    accepting_requests: bool = False
    public_visible: bool = False
    description: str = Field(default="", max_length=5000)
    media: PublishedMedia | None = None

    @field_validator("postal_codes")
    @classmethod
    def provider_postal_codes(cls, values):
        codes = []
        for value in values:
            code = canonical_zip(value)
            if code is None:
                raise ValueError("Provider ZIP codes must be valid")
            if code not in codes:
                codes.append(code)
        return codes


class RequestInboundEvent(Strict):
    event_id: str = Field(min_length=1, max_length=100)
    provider_id: str = Field(max_length=36)
    status: Literal["accepted", "scheduled", "declined", "cancelled", "completed"]
    message: str = Field(default="", max_length=2000)
    scheduled_at: datetime | None = None

    @field_validator("scheduled_at")
    @classmethod
    def scheduled_time_zone(cls, value):
        if value is not None and (value.tzinfo is None or value.utcoffset() is None):
            raise ValueError("Scheduled time must include a time zone")
        return value


class EstimateSnapshot(Strict):
    source_id: str = Field(min_length=1, max_length=100)
    estimate_id: str | None = Field(default=None, max_length=36)
    customer_id: str = Field(min_length=1, max_length=100)
    vehicle_id: str = Field(max_length=36)
    discipline: Literal["pdr", "collision"]
    description: str = Field(max_length=5000)
    claim_number: str = Field(default="", max_length=100)
    date_of_loss: Date | None = None
    status: Literal["submitted", "reviewing", "ready", "approved"]
    amount_cents: int | None = Field(default=None, ge=0, le=2_147_483_647)
    provider_name: str = Field(default="", max_length=200)
    provider_source_id: str | None = Field(default=None, max_length=100)
    processing_state: Literal["pending", "processing", "failed", "complete"] | None = None
    processing_error: str | None = Field(default=None, max_length=500)
    updated_at: datetime | None = None


class RepairStage(Strict):
    title: str = Field(min_length=1, max_length=200)
    status: Literal["completed", "current", "upcoming"]
    date: Date | None = None


class RepairSnapshot(Strict):
    source_id: str = Field(min_length=1, max_length=100)
    customer_id: str = Field(min_length=1, max_length=100)
    vehicle_id: str = Field(max_length=36)
    provider_name: str = Field(max_length=200)
    title: str = Field(max_length=200)
    status: str = Field(max_length=50)
    estimated_completion: Date | None = None
    stages: list[RepairStage] = Field(max_length=100)

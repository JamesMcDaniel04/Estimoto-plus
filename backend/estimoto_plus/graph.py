"""Source-linked graph retrieval, with tenant isolation before retrieval.

Operational records remain the source of truth. This is a typed automotive
graph and local GraphRAG implementation, not a claim that a model is trained
on customer data or that a cross-industry corpus already exists.
"""
import hashlib
import json
import re
from collections import defaultdict
from datetime import date, datetime, timedelta, timezone
from typing import Literal

from fastapi import APIRouter, Depends, Header, HTTPException, Request
from pydantic import BaseModel, ConfigDict, Field, field_validator
from sqlalchemy import case, delete, func, or_, select, update
from sqlalchemy.orm import Session, object_session

from .auth import bridge_authorized, current_customer, db_session
from .models import Customer, ServiceRequest, Vehicle, now, uid
from .graph_models import GraphEdge, GraphEntity, KnowledgePreference, KnowledgeRecord, KnowledgeDeletion, KnowledgeConsentEvent, KnowledgeReceipt

router = APIRouter()
POLICY_VERSION = "2026-09-13"
MIN_CONTRIBUTORS = 10
ServiceType = Literal["oil_change", "tires", "brakes", "battery", "maintenance", "diagnostics", "collision", "pdr", "other", "repair", "modification"]


class RecordInput(BaseModel):
    model_config = ConfigDict(extra="forbid", str_strip_whitespace=True)
    vehicle_id: str = Field(min_length=1, max_length=36)
    service_type: ServiceType
    service_date: str
    mileage: int | None = Field(default=None, ge=0, le=9999999, strict=True)
    cost_cents: int | None = Field(default=None, ge=0, le=100_000_000, strict=True)
    shop_name: str = Field(default="", max_length=200)
    parts_source: str = Field(default="", max_length=200)
    parts_description: str = Field(default="", max_length=200)
    notes: str = Field(default="", max_length=1000)

    @field_validator("service_date")
    @classmethod
    def past_date(cls, value):
        parsed = date.fromisoformat(value)
        # UTC+14 gives the latest possible local date without trusting a client
        # timezone. A scheduled future appointment is not a repair-history fact.
        latest_today = (datetime.now(timezone.utc) + timedelta(hours=14)).date()
        if parsed < date(1950, 1, 1) or parsed > latest_today:
            raise ValueError("Enter a past or current service date")
        return parsed.isoformat()


class RecordUpdate(BaseModel):
    @field_validator('service_type', 'service_date', 'shop_name', 'parts_source', 'parts_description', 'notes', mode='before')
    @classmethod
    def not_null(cls, value):
        if value is None:
            raise ValueError('This field cannot be null')
        return value

    model_config = ConfigDict(extra="forbid", str_strip_whitespace=True)
    service_type: ServiceType | None = None
    service_date: str | None = None
    mileage: int | None = Field(default=None, ge=0, le=9999999, strict=True)
    cost_cents: int | None = Field(default=None, ge=0, le=100_000_000, strict=True)
    shop_name: str | None = Field(default=None, max_length=200)
    parts_source: str | None = Field(default=None, max_length=200)
    parts_description: str | None = Field(default=None, max_length=200)
    notes: str | None = Field(default=None, max_length=1000)

    @field_validator("service_date")
    @classmethod
    def past_date(cls, value):
        return value if value is None else RecordInput.past_date(value)


class PreferenceInput(BaseModel):
    model_config = ConfigDict(extra="forbid")
    share_aggregate_insights: bool = Field(strict=True)


def record_view(record, receipts=None):
    result = {k: getattr(record, k) for k in (
        "id", "vehicle_id", "service_type", "service_date", "mileage", "shop_name",
        "parts_source", "parts_description", "notes", "source", "cost_cents")}
    result["created_at"] = record.created_at.isoformat()
    result["currency"] = "USD"
    from .receipts import receipt_view
    db = object_session(record)
    if receipts is None:
        receipts = db.scalars(select(KnowledgeReceipt).where(
            KnowledgeReceipt.customer_id == record.customer_id, KnowledgeReceipt.record_id == record.id,
            KnowledgeReceipt.status == "saved").order_by(KnowledgeReceipt.created_at)) if db else []
    result["receipts"] = [receipt_view(r) for r in receipts]
    return result


def lock_customer(db, customer_id):
    # Protect writes and deletion against concurrent replay on PostgreSQL and
    # the SQLite local harness, using the same discipline as service requests.
    db.execute(update(Customer).where(Customer.id == customer_id).values(id=Customer.id))


@router.get("/v1/knowledge")
def knowledge(c: Customer = Depends(current_customer), db: Session = Depends(db_session)):
    records = db.scalars(select(KnowledgeRecord).where(KnowledgeRecord.customer_id == c.id)
                         .order_by(KnowledgeRecord.service_date.desc(), KnowledgeRecord.created_at.desc()).limit(1000)).all()
    preference = db.get(KnowledgePreference, c.id)
    receipts = defaultdict(list)
    for receipt in db.scalars(select(KnowledgeReceipt).where(KnowledgeReceipt.customer_id == c.id,
            KnowledgeReceipt.status == "saved").order_by(KnowledgeReceipt.created_at)):
        receipts[receipt.record_id].append(receipt)
    return {"records": [record_view(r, receipts[r.id]) for r in records],
            "preferences": {"share_aggregate_insights": bool(preference and preference.share_aggregate_insights)},
            "policy_version": POLICY_VERSION}


@router.get("/v1/knowledge/preferences")
def get_preference(c: Customer = Depends(current_customer), db: Session = Depends(db_session)):
    preference = db.get(KnowledgePreference, c.id)
    return {"share_aggregate_insights": bool(preference and preference.share_aggregate_insights),
            "policy_version": POLICY_VERSION}


@router.put("/v1/knowledge/preferences")
def save_preference(body: PreferenceInput, c: Customer = Depends(current_customer), db: Session = Depends(db_session)):
    lock_customer(db, c.id)
    preference = db.get(KnowledgePreference, c.id)
    changed = preference is None or preference.share_aggregate_insights != body.share_aggregate_insights or preference.policy_version != POLICY_VERSION
    if changed:
        from .customer_routes import consume_rate
        consume_rate(db, c.id, "knowledge_consent", 20)
    if preference is None:
        preference = KnowledgePreference(customer_id=c.id)
        db.add(preference)
    preference.share_aggregate_insights = body.share_aggregate_insights
    preference.policy_version = POLICY_VERSION
    preference.updated_at = now()
    if changed:
        db.add(KnowledgeConsentEvent(customer_id=c.id, share_aggregate_insights=body.share_aggregate_insights,
                                     policy_version=POLICY_VERSION))
    db.commit()
    return {"share_aggregate_insights": preference.share_aggregate_insights, "policy_version": POLICY_VERSION}


def graph_entity(db, customer_id, kind, source_key, label, attributes=None):
    row = db.scalar(select(GraphEntity).where(GraphEntity.customer_id == customer_id,
                                             GraphEntity.kind == kind, GraphEntity.source_key == source_key))
    if row is None:
        row = GraphEntity(id=uid(), customer_id=customer_id, kind=kind, source_key=source_key,
                          label=label[:200], attributes=attributes or {})
        db.add(row)
        db.flush()
    return row


def project_record(db, record, vehicle):
    car = graph_entity(db, record.customer_id, "vehicle", vehicle.id,
                       f"{vehicle.year} {vehicle.make} {vehicle.model}")
    service = graph_entity(db, record.customer_id, "service", record.id,
                           record.service_type.replace("_", " "),
                           {"service_date": record.service_date, "mileage": record.mileage})

    def edge(origin, relation, target):
        db.add(GraphEdge(customer_id=record.customer_id, record_id=record.id,
                         from_id=origin.id, to_id=target.id, relation=relation))

    edge(car, "HAS_REPORTED_SERVICE", service)
    for kind, label, relation in (("shop", record.shop_name, "REPORTED_PERFORMED_AT"),
                                   ("parts_supplier", record.parts_source, "REPORTED_PARTS_FROM"),
                                   ("part", record.parts_description, "REPORTED_USED_PART")):
        if label:
            key = hashlib.sha256(label.casefold().strip().encode()).hexdigest()
            target = graph_entity(db, record.customer_id, kind, key, label)
            edge(service, relation, target)


@router.post("/v1/knowledge/records", status_code=201)
def create_record(body: RecordInput, idempotency_key: str | None = Header(default=None),
                  c: Customer = Depends(current_customer), db: Session = Depends(db_session)):
    if not idempotency_key or len(idempotency_key) > 200:
        raise HTTPException(422, "Idempotency-Key is required.")
    payload = body.model_dump()
    # Keep replay compatibility with history saved by app versions before costs.
    if payload["cost_cents"] is None:
        payload.pop("cost_cents")
    digest = hashlib.sha256(json.dumps(payload, sort_keys=True).encode()).hexdigest()
    lock_customer(db, c.id)
    if db.get(KnowledgeDeletion, (c.id, idempotency_key)):
        raise HTTPException(410, "This history entry was deleted. Start a new entry to save it again.")
    existing = db.scalar(select(KnowledgeRecord).where(KnowledgeRecord.customer_id == c.id,
                                                       KnowledgeRecord.idempotency_key == idempotency_key))
    if existing:
        if existing.payload_hash != digest:
            raise HTTPException(409, "This save was already used for different history.")
        return record_view(existing)
    vehicle = db.get(Vehicle, body.vehicle_id)
    if vehicle is None or vehicle.customer_id != c.id:
        raise HTTPException(404, "Vehicle not found.")
    if db.scalar(select(func.count()).select_from(KnowledgeRecord).where(KnowledgeRecord.customer_id == c.id)) >= 1000:
        raise HTTPException(409, "Your saved history is full. Remove an entry before adding another.")
    from .customer_routes import consume_rate
    consume_rate(db, c.id, "knowledge_create", 30)
    record = KnowledgeRecord(id=uid(), customer_id=c.id, idempotency_key=idempotency_key,
                             payload_hash=digest, **body.model_dump())
    db.add(record)
    db.flush()
    project_record(db, record, vehicle)
    db.commit()
    return record_view(record)


@router.put("/v1/knowledge/records/{record_id}")
def update_record(record_id: str, body: RecordUpdate, c: Customer = Depends(current_customer), db: Session = Depends(db_session)):
    lock_customer(db, c.id)
    record = db.get(KnowledgeRecord, record_id)
    if record is None or record.customer_id != c.id:
        raise HTTPException(404, "History not found.")
    from .customer_routes import consume_rate
    consume_rate(db, c.id, "knowledge_update", 60)
    for k, val in body.model_dump(exclude_unset=True).items():
        setattr(record, k, val)
    db.flush()
    # Rebuild the derived graph from the edited source: drop this record's
    # edges, remove nodes nothing else references (including the stale
    # service node), then project exactly as creation does.
    db.execute(delete(GraphEdge).where(GraphEdge.customer_id == c.id, GraphEdge.record_id == record.id))
    db.flush()
    linked = select(GraphEdge.id).where(GraphEdge.customer_id == c.id,
                                      or_(GraphEdge.from_id == GraphEntity.id, GraphEdge.to_id == GraphEntity.id)).exists()
    db.execute(delete(GraphEntity).where(GraphEntity.customer_id == c.id, ~linked))
    db.flush()
    project_record(db, record, db.get(Vehicle, record.vehicle_id))
    db.commit()
    return record_view(record)


@router.delete("/v1/knowledge/records/{record_id}", status_code=204)
def delete_record(record_id: str, request: Request, c: Customer = Depends(current_customer), db: Session = Depends(db_session)):
    lock_customer(db, c.id)
    record = db.get(KnowledgeRecord, record_id)
    if record is None or record.customer_id != c.id:
        raise HTTPException(404, "History not found.")
    from .customer_routes import consume_rate
    consume_rate(db, c.id, "knowledge_delete", 60)
    from .receipts import erase_receipt, recover_deletions
    for receipt in db.scalars(select(KnowledgeReceipt).where(KnowledgeReceipt.customer_id == c.id,
                                                            KnowledgeReceipt.record_id == record.id)):
        erase_receipt(receipt)
    db.flush()
    db.execute(delete(GraphEdge).where(GraphEdge.customer_id == c.id, GraphEdge.record_id == record.id))
    db.add(KnowledgeDeletion(customer_id=c.id, idempotency_key=record.idempotency_key))
    db.delete(record)
    db.flush()
    # Erase the derived graph together with the source. Shared nodes remain
    # only while another retained record still points to them.
    linked = select(GraphEdge.id).where(GraphEdge.customer_id == c.id,
                                      or_(GraphEdge.from_id == GraphEntity.id, GraphEdge.to_id == GraphEntity.id)).exists()
    db.execute(delete(GraphEntity).where(GraphEntity.customer_id == c.id, ~linked))
    db.commit()
    recover_deletions(db, c.id, request.app.state.settings)


@router.get("/v1/knowledge/graph")
def own_graph(c: Customer = Depends(current_customer), db: Session = Depends(db_session)):
    entities = db.scalars(select(GraphEntity).where(GraphEntity.customer_id == c.id)).all()
    relationships = db.scalars(select(GraphEdge).where(GraphEdge.customer_id == c.id)).all()
    return {"entities": [{"id": e.id, "kind": e.kind, "title": e.label, "attributes": e.attributes} for e in entities],
            "relationships": [{"id": e.id, "source": e.from_id, "target": e.to_id,
                               "relation": e.relation, "record_id": e.record_id,
                               "evidence_type": e.source, "observed_at": e.observed_at.isoformat()} for e in relationships]}


def retrieve_history(db, customer_id, vehicle_id, question, limit=6):
    """Traverse vehicle -> services -> shop/part/supplier, then rank evidence.

    Filtering occurs at every graph hop, never after a global semantic query.
    Free-text notes, VIN, contact and insurance never enter model context.
    """
    if not vehicle_id:
        return []
    root = db.scalar(select(GraphEntity).where(GraphEntity.customer_id == customer_id,
                                              GraphEntity.kind == "vehicle", GraphEntity.source_key == vehicle_id))
    if root is None:
        return []
    record_ids = select(GraphEdge.record_id).where(GraphEdge.customer_id == customer_id,
                                                  GraphEdge.from_id == root.id,
                                                  GraphEdge.relation == "HAS_REPORTED_SERVICE")
    records = db.scalars(select(KnowledgeRecord).where(KnowledgeRecord.customer_id == customer_id,
                                                      KnowledgeRecord.vehicle_id == vehicle_id,
                                                      KnowledgeRecord.id.in_(record_ids))
                         .order_by(KnowledgeRecord.service_date.desc(), KnowledgeRecord.created_at.desc()).limit(1000)).all()
    tokens = set(re.findall(r"[a-z0-9]{3,}", question.casefold())) - {"the", "car", "what", "where", "when", "have", "was", "did", "from", "history"}
    wanted_type = {"oil": "oil_change", "tire": "tires", "tyre": "tires", "brake": "brakes",
                   "battery": "battery", "dent": "pdr", "collision": "collision"}
    types = {kind for keyword, kind in wanted_type.items() if keyword in question.casefold()}
    if types:
        records = [r for r in records if r.service_type in types]
    def score(record):
        text = " ".join((record.service_type.replace("_", " "), record.shop_name,
                          record.parts_source, record.parts_description)).casefold()
        return len(tokens & set(re.findall(r"[a-z0-9]{3,}", text)))
    records.sort(key=score, reverse=True)  # stable ties retain most recent first
    evidence = []
    for record in records[:limit]:
        links = db.execute(select(GraphEdge.relation, GraphEntity.label).join(GraphEntity, GraphEdge.to_id == GraphEntity.id)
                           .where(GraphEdge.customer_id == customer_id, GraphEntity.customer_id == customer_id,
                                  GraphEdge.record_id == record.id)).all()
        evidence.append({"source_id": record.id, "source": record.source,
                         "service_type": record.service_type, "service_date": record.service_date,
                         "mileage": record.mileage, "relations": [{"relation": rel, "value": label} for rel, label in links]})
    return evidence


def history_question(message):
    text = message.casefold()
    return bool(re.search(r"\b(my|our|i|me)\b", text) and re.search(
        r"history|last |previous|used to|usually|normally|where.*(?:parts|repair|service)|which.*shop|what.*shop|who.*(?:repair|service)|sourc.*parts", text))


def history_answer(evidence):
    if not evidence:
        return "I don't have a matching service record for this vehicle yet. Add a past repair in Garage → Service history so I can use your saved details."
    lines = ["From your saved history (reported by you):"]
    for item in evidence[:4]:
        relations = {r["relation"]: r["value"] for r in item["relations"]}
        text = f"{item['service_date']}: {item['service_type'].replace('_', ' ')}"
        if item["mileage"] is not None:
            text += f" at {item['mileage']:,} miles"
        if relations.get("REPORTED_PERFORMED_AT"):
            text += f" at {relations['REPORTED_PERFORMED_AT']}"
        if relations.get("REPORTED_PARTS_FROM"):
            text += f"; parts from {relations['REPORTED_PARTS_FROM']}"
        if relations.get("REPORTED_USED_PART"):
            text += f" ({relations['REPORTED_USED_PART']})"
        lines.append(text + ".")
    return "\n".join(lines)


def aggregate_insights(db):
    # Only enumerated/coarse dimensions leave the customer context. Arbitrary
    # shop/supplier names and notes can contain PII and stay private.
    known_sources = {"autozone": "AutoZone", "napa": "NAPA", "napa auto parts": "NAPA",
                     "o'reilly": "O'Reilly Auto Parts", "o'reilly auto parts": "O'Reilly Auto Parts",
                     "rockauto": "RockAuto", "advance auto parts": "Advance Auto Parts", "dealer": "Dealer"}
    supplier_category = case(known_sources, value=func.lower(func.trim(KnowledgeRecord.parts_source)), else_="Other supplier")
    def counts(model, category, predicate):
        count = func.count(func.distinct(model.customer_id))
        statement = (select(category.label("category"), count.label("count"))
                     .join(KnowledgePreference, KnowledgePreference.customer_id == model.customer_id)
                     .join(Customer, Customer.id == model.customer_id)
                     .where(KnowledgePreference.share_aggregate_insights.is_(True),
                            KnowledgePreference.policy_version == POLICY_VERSION, Customer.demo.is_(False), predicate)
                     .group_by(category).having(count >= MIN_CONTRIBUTORS).order_by(category))
        # Database-side distinct aggregation keeps memory bounded by the fixed
        # category vocabulary, even as the underlying source corpus grows.
        return [{"category": row.category, "contributors_rounded": row.count // 5 * 5} for row in db.execute(statement)]
    # Preserve the existing bridge vocabulary until staff supports new categories.
    return {"service_types": counts(KnowledgeRecord, KnowledgeRecord.service_type, KnowledgeRecord.service_type.in_([v for v in ServiceType.__args__ if v not in {"repair", "modification"}])),
            "parts_sources": counts(KnowledgeRecord, supplier_category, KnowledgeRecord.parts_source != ""),
            "request_types": counts(ServiceRequest, ServiceRequest.specialty, ServiceRequest.specialty.in_(["pdr", "collision", "maintenance", "mechanical"])),
            "minimum_contributors": MIN_CONTRIBUTORS, "source": "opted_in_customer_reports",
            "counts_rounded_to": 5, "includes_contacts": False}


@router.get("/v1/bridge/knowledge/insights", dependencies=[Depends(bridge_authorized)])
def insights(db: Session = Depends(db_session)):
    return aggregate_insights(db)

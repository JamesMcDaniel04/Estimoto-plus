"""Run the real Plus producer against the original Estimoto source contract.

Run with ESTIMOTO_BRIDGE_BACKEND=/path/to/Estimoto/backend and optionally
ESTIMOTO_BRIDGE_PYTHON=/path/to/Estimoto/backend/.venv/bin/python. The separate
process needs the original backend dependencies but never connects to a DB,
imports the application, or sends a request to an external service.
"""
import json
import os
from pathlib import Path
import subprocess
import sys

import pytest

from estimoto_plus.models import Estimate, EstimateOutbox
from estimoto_plus.schemas import EstimateSnapshot, ProviderPublish
from estimoto_plus.estimate_workflow import apply_submitted_snapshot
from test_estimate_delivery import plus, setup_draft, upload_keys, submit, auth, KEYS, BRIDGE


def original(operation, payload):
    root = os.environ.get("ESTIMOTO_BRIDGE_BACKEND")
    if not root:
        pytest.skip("Set ESTIMOTO_BRIDGE_BACKEND for the actual interservice contract check")
    assert (Path(root) / "app/routers/plus_bridge.py").is_file()
    script = '''
import asyncio, json, sys
from datetime import datetime, timezone
from types import SimpleNamespace
sys.path.insert(0, sys.argv[1])
from app.routers.plus_bridge import EstimateSubmitted, RequestCreated, ProviderIn, estimate_view
from app.models import IntakeLink
operation, body = json.load(sys.stdin)
if operation == "estimate":
    model = EstimateSubmitted.model_validate(body)
    class DB:
        async def get(self, table, key):
            return None if table is IntakeLink else SimpleNamespace(public_fields={"name":"Shop"})
    row = SimpleNamespace(payload=model.model_dump(mode="json"), intake_link_id="intake-42",
        provider_source_id=model.provider_source_id, processing_state="pending", processing_error=None,
        updated_at=datetime.now(timezone.utc))
    result = asyncio.run(estimate_view(DB(), row))
elif operation == "request":
    result = RequestCreated.model_validate(body).model_dump(mode="json")
else:
    result = {"source_id":"shop-1", **ProviderIn.model_validate(body).model_dump(mode="json")}
print(json.dumps(result, default=str))
'''
    env = dict(os.environ, DATABASE_URL="sqlite+aiosqlite:///:memory:",
               DETECTOR="mock", ANTHROPIC_API_KEY="", OPENAI_API_KEY="", NANGO_API_KEY="",
               REDIS_URL="", NEO4J_URI="", AUTO_RETRAIN="false", JOB_WARMUP="false")
    result = subprocess.run([os.environ.get("ESTIMOTO_BRIDGE_PYTHON", sys.executable), "-c", script, root],
                            input=json.dumps([operation, payload]), text=True, capture_output=True,
                            timeout=45, env=env, check=False)
    assert result.returncode == 0, result.stderr
    return json.loads(result.stdout)


@pytest.mark.parametrize("discipline", ["pdr", "collision"])
def test_real_submission_and_status_contract_round_trip(plus, discipline):
    client, app, _, _ = plus
    _, provider, estimate_id = setup_draft(client)
    client.post("/v1/bridge/providers", headers=BRIDGE, json={
        "source_id":"shop-1", "name":"Shop", "kind":"shop", "specialties":[discipline],
        "postal_codes":["80202"], "public_visible":True, "accepting_requests":True})
    with app.state.session_factory() as db:
        estimate = db.get(Estimate, estimate_id)
        estimate.discipline = discipline
        estimate.description = "  Customer damage description  "
        estimate.claim_number = " claim-42 "
        db.commit()
    upload_keys(client, estimate_id, (*KEYS, "panel_hood") if discipline == "pdr" else (*KEYS, "corner_fl", "roof"))
    response = submit(client, estimate_id, provider)
    assert response.status_code == 200, response.text
    with app.state.session_factory() as db:
        outbox = db.query(EstimateOutbox).filter_by(estimate_id=estimate_id).one()
        snapshot = EstimateSnapshot.model_validate(original("estimate", outbox.payload))
        estimate = db.get(Estimate, estimate_id)
        apply_submitted_snapshot(db, estimate, snapshot, outbox.payload)
        assert estimate.source_id == "intake-42"


def test_every_valid_original_provider_can_sync():
    public = original("provider", {"name":"Shop", "specialties":["pdr"],
        "postal_codes":[f"{i:05}" for i in range(700)], "city":"C" * 120,
        "public_visible":True, "accepting_requests":True})
    assert len(ProviderPublish.model_validate(public).postal_codes) == 700


def test_real_request_payload_contract(plus):
    client, _, sent, _ = plus
    vehicle_id, provider_id, _ = setup_draft(client)
    response = client.post("/v1/requests", headers={**auth(), "Idempotency-Key":"request-contract"},
                           json={"vehicle_id":vehicle_id, "provider_id":provider_id, "specialty":"pdr",
                                 "description":"Please review the damage", "share_contact":True})
    assert response.status_code == 201, response.text
    client.post("/v1/bridge/outbox/deliver", headers=BRIDGE)
    request = next(item for item in sent if item.url.path == "/bridge/plus/requests")
    assert original("request", json.loads(request.content))["request_id"] == response.json()["id"]


@pytest.mark.parametrize("kind,changes", [
    ("profile", {"name":""}), ("profile", {"name":"Alice", "phone":"1" * 41}),
    ("vehicle", {"year":1900}), ("vehicle", {"make":"M" * 61}),
    ("vehicle", {"model":"M" * 61}), ("vehicle", {"vin":"V" * 33}),
])
def test_request_invalid_saved_details_do_not_create_immutable_outbox(plus, kind, changes):
    client, app, _, _ = plus
    vehicle_id, provider_id, _ = setup_draft(client)
    route = "/v1/profile" if kind == "profile" else f"/v1/vehicles/{vehicle_id}"
    data = {"postal_code":"80202", **changes} if kind == "profile" else changes
    if kind == "profile" and "phone" in changes:
        assert client.put(route, headers=auth(), json=data).status_code == 422
        # Retain the downstream guard for legacy malformed profiles even though
        # new profile writes reject them before they reach the database.
        from estimoto_plus.models import Customer
        with app.state.session_factory() as db:
            customer = db.get(Customer, "alice")
            for key, value in changes.items():
                setattr(customer, key, value)
            db.commit()
    else:
        assert client.put(route, headers=auth(), json=data).status_code == 200
    body = {"vehicle_id":vehicle_id, "provider_id":provider_id, "specialty":"pdr",
            "description":"Please help", "share_contact":True}
    headers = {**auth(), "Idempotency-Key":"invalid-saved-details"}
    result = client.post("/v1/requests", headers=headers, json=body)
    assert result.status_code == 422 and result.json()["code"] == "request_not_created"
    assert client.get("/v1/requests", headers=auth()).json() == []
    from estimoto_plus.models import Outbox
    with app.state.session_factory() as db:
        assert db.query(Outbox).count() == 0
    # A definitive rejection stays rejected if profile/vehicle eligibility changes.
    client.put("/v1/profile", headers=auth(), json={"name":"Alice", "phone":"3035550100", "postal_code":"80202"})
    client.put(f"/v1/vehicles/{vehicle_id}", headers=auth(), json={"year":2020, "make":"Ford", "model":"Truck", "vin":""})
    assert client.post("/v1/requests", headers=headers, json=body).json() == result.json()


def test_collision_unsupported_extra_stays_editable(plus):
    client, app, _, _ = plus
    _, provider, estimate_id = setup_draft(client)
    client.post("/v1/bridge/providers", headers=BRIDGE, json={
        "source_id":"shop-1", "name":"Shop", "kind":"shop", "specialties":["collision"],
        "postal_codes":["80202"], "public_visible":True, "accepting_requests":True})
    with app.state.session_factory() as db:
        db.get(Estimate, estimate_id).discipline = "collision"
        db.commit()
    upload_keys(client, estimate_id, (*KEYS, "damage_close"))
    assert submit(client, estimate_id, provider).status_code == 422
    with app.state.session_factory() as db:
        assert db.get(Estimate, estimate_id).status == "draft"
        assert db.query(EstimateOutbox).count() == 0


def test_service_request_quota_persists_and_replays_do_not_consume(plus):
    client, app, _, _ = plus
    vehicle_id, provider_id, _ = setup_draft(client)
    body = {"vehicle_id":vehicle_id, "provider_id":provider_id, "specialty":"pdr",
            "description":"Please help", "share_contact":True}
    for index in range(20):
        headers = {**auth(), "Idempotency-Key":f"quota-{index}"}
        created = client.post("/v1/requests", headers=headers, json=body)
        assert created.status_code == 201
        assert client.post("/v1/requests", headers=headers, json=body).json()["id"] == created.json()["id"]
    app.state.engine.dispose()
    assert client.post("/v1/requests", headers={**auth(), "Idempotency-Key":"quota-21"}, json=body).status_code == 429
    assert len(client.get("/v1/requests", headers=auth()).json()) == 20
    assert client.post("/v1/requests", headers={**auth(), "Idempotency-Key":"quota-0"}, json=body).status_code == 201

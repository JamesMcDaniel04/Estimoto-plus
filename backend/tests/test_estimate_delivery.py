"""Customer estimate submission remains private, durable, and upstream-authoritative."""
import hashlib
import json
from io import BytesIO
from concurrent.futures import ThreadPoolExecutor

import httpx
import pytest
from fastapi.testclient import TestClient
from PIL import Image

from estimoto_plus.app import create_app
from estimoto_plus.config import Settings


KEYS = ("vin", "odometer", "engine_bay", "interior", "tire_tread", "front", "driver", "rear", "passenger")
BRIDGE = {"X-Bridge-Key": "test-bridge-key"}


def auth(who="alice"):
    return {"Authorization": f"Bearer {who}"}


@pytest.fixture
def plus(tmp_path):
    sent = []
    state = {"status": "reviewing", "processing_state": "complete", "amount_cents": None,
             "source_id": "intake-42", "override_customer": None, "create_fails": False,
             "process_fails": False,
             "processing_error": None}
    def receiver(req):
        sent.append(req)
        if req.method == "POST" and req.url.path == "/bridge/plus/estimates":
            if state["create_fails"]:
                return httpx.Response(503)
            return httpx.Response(202, json={"receipt_id": "intake-42"})
        if req.url.path.endswith("/process") or req.method == "GET":
            if state["process_fails"]:
                return httpx.Response(503)
            creation = json.loads(next(item.content for item in sent if item.url.path == "/bridge/plus/estimates"))
            return httpx.Response(200, json={"source_id": state["source_id"],
                                               "estimate_id": creation["estimate_id"],
                                               "customer_id": state["override_customer"] or creation["customer_id"],
                                               "vehicle_id": creation["vehicle_id"],
                                               "provider_source_id": creation["provider_source_id"],
                                               "discipline": creation["discipline"],
                                               "description": creation["description"],
                                               "claim_number": creation["claim_number"],
                                               "date_of_loss": creation["date_of_loss"],
                                               "provider_name": "Shop", "status": state["status"],
                                               "amount_cents": state["amount_cents"],
                                               "processing_state": state["processing_state"],
                                               "processing_error": state["processing_error"]})
        return httpx.Response(503)
    settings = Settings(database_url=f"sqlite:///{tmp_path / 'plus.sqlite'}", environment="test",
                        bridge_url="https://receiver.example/bridge/plus/requests",
                        estimate_bridge_url="https://receiver.example/bridge/plus/estimates",
                        bridge_key="test-bridge-key", photo_dir=str(tmp_path / "photos"))
    app = create_app(settings, auth_verifier=lambda token: {"id": token, "email": f"{token}@example.test", "confirmed_at": "ok"},
                     bridge_transport=httpx.MockTransport(receiver))
    with TestClient(app) as client:
        yield client, app, sent, state


def setup_draft(client):
    assert client.put("/v1/profile", headers=auth(), json={"name": "Alice", "phone": "3035550100", "postal_code": "80202"}).status_code == 200
    vehicle = client.post("/v1/vehicles", headers=auth(), json={"year": 2020, "make": "Ford", "model": "Truck"}).json()["id"]
    provider = client.post("/v1/bridge/providers", headers=BRIDGE, json={
        "source_id": "shop-1", "name": "Shop", "kind": "shop", "specialties": ["pdr"],
        "postal_codes": ["80202"], "accepting_requests": True, "public_visible": True}).json()["id"]
    estimate = client.post("/v1/estimates", headers=auth(), json={"vehicle_id": vehicle, "discipline": "pdr", "description": "Hail"}).json()["id"]
    return vehicle, provider, estimate


def png():
    buffer = BytesIO()
    Image.new("RGB", (2, 2), "blue").save(buffer, format="PNG")
    return buffer.getvalue()


def upload_keys(client, estimate, keys=KEYS):
    for key in keys:
        result = client.post(f"/v1/estimates/{estimate}/photos", headers=auth(),
                             files={"file": (f"{key}.png", png(), "image/png")}, data={"label": key})
        assert result.status_code == 201, result.text


def submit(client, estimate, provider, *, body=None, key=None):
    return client.post(f"/v1/estimates/{estimate}/submit",
                       headers={**auth(), "Idempotency-Key": key or f"estimate:{estimate}"},
                       json=body or {"provider_id": provider, "share_contact": True})


def test_submit_requires_owned_nine_photos_provider_consent_and_contact(plus):
    client, _, _, _ = plus
    _, provider, estimate = setup_draft(client)
    assert client.get("/v1/bootstrap", headers=auth()).json()["capabilities"]["required_estimate_photo_keys"] == list(KEYS)
    assert submit(client, estimate, provider).status_code == 422
    upload_keys(client, estimate, KEYS[:-1])
    assert submit(client, estimate, provider).status_code == 422
    upload_keys(client, estimate, KEYS[-1:])
    assert submit(client, estimate, provider).status_code == 422
    upload_keys(client, estimate, ("panel_hood",))
    assert submit(client, estimate, provider, body={"provider_id": provider, "share_contact": False}).status_code == 422
    assert submit(client, estimate, provider, key="different", body={"provider_id": "foreign", "share_contact": True}).status_code == 409
    assert submit(client, estimate, provider).status_code == 200
    assert submit(client, estimate, provider).status_code == 200
    assert submit(client, estimate, provider, key="different").status_code == 409
    assert client.post(f"/v1/estimates/{estimate}/photos", headers=auth(), files={"file": ("x.png", png(), "image/png")}, data={"label": "front"}).status_code == 409
    assert client.post(f"/v1/estimates/{estimate}/submit", headers={**auth("bob"), "Idempotency-Key": f"estimate:{estimate}"},
                       json={"provider_id": provider, "share_contact": True}).status_code == 404


def test_estimate_payload_private_import_and_authoritative_status(plus):
    client, app, sent, state = plus
    vehicle, provider, estimate = setup_draft(client)
    upload_keys(client, estimate)
    upload_keys(client, estimate, ("panel_hood",))
    submitted = submit(client, estimate, provider)
    assert submitted.status_code == 200, submitted.text
    assert submitted.json()["status"] == "submitted"
    assert submitted.json()["delivery_status"] == "queued"
    assert submitted.json()["amount_cents"] is None
    photos = submitted.json()["photos"]
    photo = photos[0]
    private = f"/v1/bridge/estimates/{estimate}/photos/{photo['id']}"
    assert client.get(private).status_code == 401
    assert client.get(private, headers=BRIDGE).content == png()
    assert client.get(f"/v1/bridge/estimates/{estimate}/photos/not-a-photo", headers=BRIDGE).status_code == 404
    assert client.post("/v1/bridge/outbox/deliver", headers=BRIDGE).json()["delivered"] == 1
    outbound = sent[0]
    assert outbound.headers["Idempotency-Key"] == f"estimate:{estimate}"
    payload = json.loads(outbound.content)
    assert payload["estimate_id"] == estimate and payload["customer_id"] == "alice"
    assert payload["vehicle_id"] == vehicle and payload["provider_source_id"] == "shop-1"
    assert payload["contact"]["phone"] == "3035550100"
    assert "policy_number" not in payload["vehicle"]
    assert payload["event"] == "submitted"
    assert [p["label"] for p in payload["photos"]] == [*KEYS, "panel_hood"]
    assert all(p["byte_size"] == len(png()) and p["mime_type"] == "image/png" for p in payload["photos"])
    assert payload["photos"][0]["sha256"] == hashlib.sha256(png()).hexdigest()
    assert client.get("/v1/bootstrap", headers=auth()).json()["estimates"][0]["delivery_status"] == "delivered"
    assert client.post("/v1/bridge/outbox/deliver", headers=BRIDGE).json()["delivered"] == 1
    reviewing = client.get("/v1/bootstrap", headers=auth()).json()["estimates"][0]
    assert reviewing["status"] == "reviewing" and reviewing["processing_state"] == "complete"
    assert reviewing["amount_cents"] is None
    assert client.get("/v1/bootstrap", headers=auth("bob")).json()["estimates"] == []
    state["status"], state["amount_cents"] = "ready", 12345
    with app.state.session_factory() as db:
        from estimoto_plus.models import EstimateOutbox, now
        row = db.query(EstimateOutbox).filter(EstimateOutbox.estimate_id == estimate).one()
        row.next_attempt_at = now()
        db.commit()
    assert client.post("/v1/bridge/outbox/deliver", headers=BRIDGE).json()["delivered"] == 1
    ready = client.get("/v1/bootstrap", headers=auth()).json()["estimates"][0]
    assert ready["status"] == "ready" and ready["amount_cents"] == 12345
    state["status"], state["amount_cents"] = "reviewing", None
    with app.state.session_factory() as db:
        row = db.query(EstimateOutbox).filter(EstimateOutbox.estimate_id == estimate).one()
        row.next_attempt_at = now()
        db.commit()
    assert client.post("/v1/bridge/outbox/deliver", headers=BRIDGE).json()["failed"] == 1
    assert client.get("/v1/bootstrap", headers=auth()).json()["estimates"][0]["amount_cents"] == 12345


def test_guided_pdr_pair_supersedes_legacy_photo_for_same_area(plus):
    client, app, sent, state = plus
    _, provider, estimate = setup_draft(client)
    upload_keys(client, estimate, (*KEYS, 'panel_hood', 'hail_close_hood'))
    assert submit(client, estimate, provider).status_code == 422
    upload_keys(client, estimate, ('hail_raking_hood',))
    assert submit(client, estimate, provider).status_code == 200
    assert client.post('/v1/bridge/outbox/deliver', headers=BRIDGE).json()['delivered'] == 1
    payload = json.loads(sent[0].content)
    assert payload['capture_version'] == 2
    assert {p['label'] for p in payload['photos']} == {*KEYS, 'hail_close_hood', 'hail_raking_hood'}


def test_health_readiness_and_production_configuration_fail_closed(tmp_path):
    with pytest.raises(ValueError):
        create_app(Settings(database_url=f"sqlite:///{tmp_path / 'prod.sqlite'}", environment="production",
                            photo_dir=str(tmp_path / "photos")))
    settings = Settings(database_url=f"sqlite:///{tmp_path / 'health.sqlite'}", environment="test",
                        photo_dir=str(tmp_path / "photos"), source_sha="test-sha")
    with TestClient(create_app(settings)) as client:
        assert client.get("/health/live").json()["status"] == "alive"
        assert client.get("/version").json()["source_sha"] == "test-sha"
        assert client.get("/ready").status_code == 503  # no migrated version or private photo volume


def test_photo_replacement_and_persistent_customer_limits(plus, monkeypatch):
    from estimoto_plus import customer_routes
    client, app, _, _ = plus
    _, _, estimate = setup_draft(client)
    first = client.post(f"/v1/estimates/{estimate}/photos", headers=auth(),
                        files={"file": ("front.png", png(), "image/png")}, data={"label": "front"})
    assert first.status_code == 201
    second = client.post(f"/v1/estimates/{estimate}/photos", headers=auth(),
                         files={"file": ("front2.png", png(), "image/png")}, data={"label": "front"})
    assert second.status_code == 201
    assert second.json()["id"] == first.json()["id"]
    assert len(client.get("/v1/bootstrap", headers=auth()).json()["estimates"][0]["photos"]) == 1
    monkeypatch.setattr(customer_routes, "MAX_CUSTOMER_PHOTO_BYTES", len(png()))
    assert client.post(f"/v1/estimates/{estimate}/photos", headers=auth(),
                       files={"file": ("rear.png", png(), "image/png")}, data={"label": "rear"}).status_code == 413
    monkeypatch.setattr(customer_routes, "MAX_CUSTOMER_PHOTO_BYTES", 250 * 1024 * 1024)
    monkeypatch.setattr(customer_routes, "MAX_PHOTO_UPLOADS_PER_HOUR", 2)
    assert client.post(f"/v1/estimates/{estimate}/photos", headers=auth(),
                       files={"file": ("rear.png", png(), "image/png")}, data={"label": "rear"}).status_code == 429


def test_concurrent_estimate_submit_creates_one_immutable_operation(plus):
    client, app, _, _ = plus
    _, provider, estimate = setup_draft(client)
    upload_keys(client, estimate, (*KEYS, "panel_hood"))
    with ThreadPoolExecutor(max_workers=2) as pool:
        results = list(pool.map(lambda _: submit(client, estimate, provider), range(2)))
    assert [result.status_code for result in results] == [200, 200]
    from estimoto_plus.models import EstimateOutbox
    with app.state.session_factory() as db:
        assert db.query(EstimateOutbox).filter(EstimateOutbox.estimate_id == estimate).count() == 1


def test_transient_create_retry_keeps_reviewed_payload(plus):
    client, app, sent, state = plus
    vehicle, provider, estimate = setup_draft(client)
    upload_keys(client, estimate, (*KEYS, "panel_hood"))
    assert submit(client, estimate, provider).status_code == 200
    state["create_fails"] = True
    assert client.post("/v1/bridge/outbox/deliver", headers=BRIDGE).json()["failed"] == 1
    assert client.get("/v1/bootstrap", headers=auth()).json()["estimates"][0]["delivery_status"] == "failed"
    assert client.put("/v1/profile", headers=auth(), json={"name": "Changed", "phone": "3035559999", "postal_code": "80202"}).status_code == 200
    assert client.put(f"/v1/vehicles/{vehicle}", headers=auth(), json={"vin": "CHANGED"}).status_code == 200
    state["create_fails"] = False
    from estimoto_plus.models import EstimateOutbox, now
    with app.state.session_factory() as db:
        row = db.query(EstimateOutbox).filter(EstimateOutbox.estimate_id == estimate).one()
        row.next_attempt_at = now()
        db.commit()
    assert client.post("/v1/bridge/outbox/deliver", headers=BRIDGE).json()["delivered"] == 1
    assert sent[0].headers["Idempotency-Key"] == sent[1].headers["Idempotency-Key"]
    assert sent[0].content == sent[1].content


def test_cross_binding_rejected_and_authoritative_failure_is_terminal(plus):
    client, app, sent, state = plus
    _, provider, estimate = setup_draft(client)
    upload_keys(client, estimate, (*KEYS, "panel_hood"))
    assert submit(client, estimate, provider).status_code == 200
    assert client.post("/v1/bridge/outbox/deliver", headers=BRIDGE).json()["delivered"] == 1
    state["override_customer"] = "bob"
    assert client.post("/v1/bridge/outbox/deliver", headers=BRIDGE).json()["failed"] == 1
    current = client.get("/v1/bootstrap", headers=auth()).json()["estimates"][0]
    assert current["status"] == "submitted" and current["amount_cents"] is None
    from estimoto_plus.models import EstimateOutbox, now
    state["override_customer"] = None
    state["processing_state"] = "failed"
    state["processing_error"] = "The photos could not be verified. Contact support."
    with app.state.session_factory() as db:
        row = db.query(EstimateOutbox).filter(EstimateOutbox.estimate_id == estimate).one()
        row.next_attempt_at = now()
        db.commit()
    assert client.post("/v1/bridge/outbox/deliver", headers=BRIDGE).json()["delivered"] == 1
    failed = client.get("/v1/bootstrap", headers=auth()).json()["estimates"][0]
    assert failed["processing_state"] == "failed" and failed["processing_error"] == state["processing_error"]
    before = len(sent)
    assert client.post("/v1/bridge/outbox/deliver", headers=BRIDGE).json() == {"delivered": 0, "failed": 0}
    assert len(sent) == before


def test_transient_process_error_stays_retryable_not_terminal(plus):
    client, app, _, state = plus
    _, provider, estimate = setup_draft(client)
    upload_keys(client, estimate, (*KEYS, "panel_hood"))
    assert submit(client, estimate, provider).status_code == 200
    assert client.post("/v1/bridge/outbox/deliver", headers=BRIDGE).json()["delivered"] == 1
    state["process_fails"] = True
    assert client.post("/v1/bridge/outbox/deliver", headers=BRIDGE).json()["failed"] == 1
    pending = client.get("/v1/bootstrap", headers=auth()).json()["estimates"][0]
    assert pending["processing_state"] == "pending"
    assert "Retrying" in pending["processing_error"]
    state["process_fails"] = False
    from estimoto_plus.models import EstimateOutbox, now
    with app.state.session_factory() as db:
        row = db.query(EstimateOutbox).filter(EstimateOutbox.estimate_id == estimate).one()
        assert row.finished_at is None
        row.next_attempt_at = now()
        db.commit()
    assert client.post("/v1/bridge/outbox/deliver", headers=BRIDGE).json()["delivered"] == 1
    assert client.get("/v1/bootstrap", headers=auth()).json()["estimates"][0]["processing_state"] == "complete"


def test_receiver_incompatible_garage_fields_rejected_before_queue(plus):
    client, app, _, _ = plus
    vehicle, provider, estimate = setup_draft(client)
    upload_keys(client, estimate, (*KEYS, "panel_hood"))
    assert client.put(f"/v1/vehicles/{vehicle}", headers=auth(), json={"year": 1940}).status_code == 200
    assert submit(client, estimate, provider).status_code == 422
    assert client.put(f"/v1/vehicles/{vehicle}", headers=auth(), json={"year": 2020, "vin": "INVALID"}).status_code == 200
    assert submit(client, estimate, provider).status_code == 422
    assert client.put(f"/v1/vehicles/{vehicle}", headers=auth(), json={"vin": ""}).status_code == 200
    assert client.put("/v1/profile", headers=auth(), json={"name": "Alice", "phone": "1" * 41, "postal_code": "80202"}).status_code == 422
    # A stricter editor cannot repair malformed details saved by an older build.
    # Submission must still independently reject those historical rows.
    from estimoto_plus.models import Customer
    with app.state.session_factory() as db:
        db.get(Customer, "alice").phone = "1" * 41
        db.commit()
    assert submit(client, estimate, provider).status_code == 422
    from estimoto_plus.models import EstimateOutbox
    with app.state.session_factory() as db:
        assert db.query(EstimateOutbox).filter(EstimateOutbox.estimate_id == estimate).count() == 0


def test_live_creation_requires_current_provider_catalog(plus, monkeypatch):
    from estimoto_plus import estimate_delivery
    client, app, sent, _ = plus
    _, provider, estimate = setup_draft(client)
    upload_keys(client, estimate, (*KEYS, "panel_hood"))
    assert submit(client, estimate, provider).status_code == 200
    app.state.settings.environment = "production"
    monkeypatch.setattr(estimate_delivery, "sync_providers", lambda *_: False, raising=False)
    assert client.post("/v1/bridge/outbox/deliver", headers=BRIDGE).json() == {"delivered": 0, "failed": 0}
    assert sent == []
    monkeypatch.setattr(estimate_delivery, "sync_providers", lambda *_: True)
    assert client.post("/v1/bridge/outbox/deliver", headers=BRIDGE).json()["delivered"] == 1
    assert len(sent) == 1


def test_concurrent_delivery_claim_sends_one_estimate_creation(plus):
    client, _, sent, _ = plus
    _, provider, estimate = setup_draft(client)
    upload_keys(client, estimate, (*KEYS, "panel_hood"))
    assert submit(client, estimate, provider).status_code == 200
    with ThreadPoolExecutor(max_workers=2) as pool:
        results = list(pool.map(lambda _: client.post("/v1/bridge/outbox/deliver", headers=BRIDGE).json(), range(2)))
    assert sum(item["delivered"] for item in results) in {1, 2}  # creation and process are separate valid phases
    assert len([req for req in sent if req.method == "POST" and req.url.path == "/bridge/plus/estimates"]) == 1

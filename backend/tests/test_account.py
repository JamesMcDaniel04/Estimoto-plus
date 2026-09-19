"""Customer account export and permanent deletion."""
from pathlib import Path

import httpx
import pytest
from fastapi.testclient import TestClient
from sqlalchemy import select

from estimoto_plus.app import create_app
from estimoto_plus.calendar_models import CalendarConnection
from estimoto_plus.config import Settings
from estimoto_plus.models import Base, Customer, Outbox, RateBucket, ServiceRequest, now
from test_api import VALID_PNG, create_vehicle, h, publish
from test_knowledge import add as add_record
from test_receipts import upload as upload_receipt

IDENTITIES = {
    "alice": {"id": "alice-id", "email": "alice@example.test", "email_confirmed_at": "2026-01-01T00:00:00Z"},
    "bob": {"id": "bob-id", "email": "bob@example.test", "email_confirmed_at": "2026-01-01T00:00:00Z"},
}


@pytest.fixture
def harness(tmp_path):
    """Live-shaped app: mocked shop bridge, mocked Supabase admin API, both switchable per test."""
    state = {"bridge_ok": True, "admin_status": 204, "bridge": [], "admin": []}
    settings = Settings(database_url=f"sqlite:///{tmp_path / 'db.sqlite'}", environment="test",
                        bridge_url="https://bridge.example/requests", bridge_key="bridge-secret",
                        supabase_url="https://auth.example", supabase_publishable_key="public-fixture",
                        supabase_service_role_key="service-fixture", photo_dir=str(tmp_path / "photos"))

    def bridge(request):
        state["bridge"].append(request)
        if not state["bridge_ok"]:
            return httpx.Response(503)
        return httpx.Response(202, json={"receipt_id": f"upstream-{len(state['bridge'])}"})

    def admin(request):
        state["admin"].append(request)
        return httpx.Response(state["admin_status"])

    app = create_app(settings, auth_verifier=lambda token: IDENTITIES.get(token),
                     auth_client=httpx.Client(transport=httpx.MockTransport(admin)),
                     bridge_transport=httpx.MockTransport(bridge))
    with TestClient(app) as client:
        yield client, state, app, settings
    app.state.auth_client.close()


def populate(client, who="alice"):
    """A garage with every kind of private data, including files on disk."""
    vehicle = create_vehicle(client, who)
    estimate = client.post("/v1/estimates", headers=h(who), json={"vehicle_id": vehicle, "discipline": "pdr", "description": "Hail"})
    assert estimate.status_code == 201, estimate.text
    eid = estimate.json()["id"]
    photo = client.post(f"/v1/estimates/{eid}/photos", headers=h(who), files={"file": ("a.png", VALID_PNG, "image/png")}, data={"label": "hood"})
    assert photo.status_code == 201, photo.text
    reminder = client.post("/v1/reminders", headers=h(who), json={"vehicle_id": vehicle, "title": "Oil change", "due_mileage": 70000})
    assert reminder.status_code == 201, reminder.text
    record = add_record(client, vehicle, who=who, key=f"history-{who}")
    assert record.status_code == 201, record.text
    receipt = upload_receipt(client, record.json()["id"], who=who)
    assert receipt.status_code == 201, receipt.text
    shop = client.post("/v1/my-shops", headers=h(who), json={"name": "Neighborhood Garage", "email": "service@example.test",
                                                            "phone": "3035550100", "address": "", "website": "", "notes": "", "vehicle_id": vehicle})
    assert shop.status_code == 201, shop.text
    return {"vehicle": vehicle, "estimate": eid, "record": record.json()["id"], "shop": shop.json()["id"]}


def customer_rows(app, customer_id):
    counts = {}
    with app.state.session_factory() as db:
        for table in Base.metadata.sorted_tables:
            if "customer_id" in table.c:
                counts[table.name] = db.scalar(select(table.c.customer_id).where(table.c.customer_id == customer_id).limit(1)) is not None
        counts["customers"] = db.get(Customer, customer_id) is not None
    return {name for name, present in counts.items() if present}


def private_files(settings):
    root = Path(settings.photo_dir)
    return sorted(str(p.relative_to(root)) for p in root.rglob("*") if p.is_file())


def test_export_is_complete_private_and_downloadable(harness):
    client, _, _, _ = harness
    ids = populate(client)
    create_vehicle(client, "bob")
    assert client.get("/v1/account/export").status_code == 401
    response = client.get("/v1/account/export", headers=h("alice"))
    assert response.status_code == 200, response.text
    assert response.headers["content-disposition"] == 'attachment; filename="estimoto-plus-export.json"'
    assert response.headers["cache-control"] == "private, no-store"
    data = response.json()
    assert data["format"] == "estimoto-plus/1"
    assert data["profile"] == {"id": "alice-id", "email": "alice@example.test", "name": "Alice", "phone": "", "postal_code": "80202", "contact_preference": "email"}
    assert [v["id"] for v in data["vehicles"]] == [ids["vehicle"]]
    assert data["estimates"][0]["id"] == ids["estimate"] and data["estimates"][0]["photos"][0]["label"] == "hood"
    assert data["reminders"][0]["title"] == "Oil change"
    record = data["service_history"]["records"][0]
    assert record["id"] == ids["record"] and record["notes"] == "Private note with policy SECRET"
    assert record["receipts"][0]["filename"] == "receipt.png"
    assert data["service_history"]["preferences"] == {"share_aggregate_insights": False}
    assert data["my_shops"][0]["id"] == ids["shop"]
    assert data["calendar"] == {"status": "disconnected", "selected_calendar_ids": [], "time_zone": ""}
    for key in ("requests", "repairs", "shop_requests", "dedicated_shops", "vehicle_valuations"):
        assert data[key] == []
    other = client.get("/v1/account/export", headers=h("bob")).json()
    assert other["profile"]["id"] == "bob-id" and other["estimates"] == [] and other["service_history"]["records"] == []


def test_export_is_rate_limited(harness):
    client, _, _, _ = harness
    create_vehicle(client)
    statuses = [client.get("/v1/account/export", headers=h("alice")).status_code for _ in range(11)]
    assert statuses == [200] * 10 + [429]


def test_delete_erases_every_row_and_file_and_removes_the_sign_in(harness):
    client, state, app, settings = harness
    populate(client)
    bob = populate(client, "bob")
    with app.state.session_factory() as db:
        db.add(CalendarConnection(customer_id="alice-id", status="connected", integration_id="estimoto-plus-google-calendar",
                                  environment="production", nango_connection_id="conn-1", time_zone="America/Denver"))
        db.commit()
    before = private_files(settings)
    assert len(before) == 4, before  # alice: photo + receipt; bob: photo + receipt
    assert customer_rows(app, "alice-id") >= {"customers", "vehicles", "estimates", "reminders", "knowledge_records",
                                             "knowledge_receipts", "my_shops", "customer_calendar_connections", "rate_buckets"}
    assert client.delete("/v1/account").status_code == 401
    response = client.delete("/v1/account", headers=h("alice"))
    assert response.status_code == 200, response.text
    assert response.json() == {"deleted": True, "sign_in_removed": True, "requests_cancelled": 0, "files_removed": 2}
    assert customer_rows(app, "alice-id") == set()
    assert len(private_files(settings)) == 2
    with app.state.session_factory() as db:
        assert db.scalar(select(Outbox.id)) is None
    admin_call = state["admin"][-1]
    assert admin_call.method == "DELETE" and str(admin_call.url) == "https://auth.example/auth/v1/admin/users/alice-id"
    assert admin_call.headers["apikey"] == "service-fixture" and admin_call.headers["authorization"] == "Bearer service-fixture"
    # Bob is untouched, and can still see everything.
    assert customer_rows(app, "bob-id") >= {"customers", "vehicles", "estimates", "knowledge_records"}
    assert client.get("/v1/bootstrap", headers=h("bob")).json()["vehicles"][0]["id"] == bob["vehicle"]
    # Until the identity provider drops the token, the same identity only ever sees a fresh, empty account.
    fresh = client.get("/v1/bootstrap", headers=h("alice")).json()
    assert fresh["vehicles"] == [] and fresh["estimates"] == [] and fresh["profile"]["name"] == ""
    assert client.get("/v1/knowledge", headers=h("alice")).json()["records"] == []


def test_delete_cancels_open_requests_and_tells_the_shop_first(harness):
    client, state, app, _ = harness
    vehicle = create_vehicle(client)
    provider = publish(client)
    body = {"vehicle_id": vehicle, "provider_id": provider, "specialty": "pdr", "description": "Hail dents",
            "preferred_time": "Weekday", "share_contact": True}
    created = client.post("/v1/requests", headers={**h("alice"), "Idempotency-Key": "open-1"}, json=body)
    assert created.status_code == 201, created.text
    assert client.post("/v1/bridge/outbox/deliver", headers={"X-Bridge-Key": "bridge-secret"}).status_code == 200
    assert client.get("/v1/requests", headers=h("alice")).json()[0]["delivery_status"] == "delivered"
    assert len(state["bridge"]) == 1
    # A request the shop never received needs no notice; it is simply suppressed and erased.
    queued = client.post("/v1/requests", headers={**h("alice"), "Idempotency-Key": "open-2"}, json=body)
    assert queued.status_code == 201, queued.text

    state["bridge_ok"] = False
    refused = client.delete("/v1/account", headers=h("alice"))
    assert refused.status_code == 409, refused.text
    assert refused.json()["code"] == "open_requests"
    assert customer_rows(app, "alice-id") >= {"customers", "vehicles", "service_requests"}
    statuses = {r["id"]: r for r in client.get("/v1/requests", headers=h("alice")).json()}
    assert {r["status"] for r in statuses.values()} == {"cancelled"}
    assert statuses[created.json()["id"]]["events"][-1]["message"] == "Cancelled because the account was deleted."
    with app.state.session_factory() as db:
        pending = db.scalars(select(Outbox).where(Outbox.kind == "cancel")).all()
        assert len(pending) == 1 and pending[0].receipt_id is None and pending[0].attempts >= 1

    state["bridge_ok"] = True
    response = client.delete("/v1/account", headers=h("alice"))
    assert response.status_code == 200, response.text
    assert response.json()["requests_cancelled"] == 0  # already cancelled by the refused attempt
    cancel_events = [r for r in state["bridge"] if b'"cancelled"' in r.content]
    assert len(cancel_events) >= 1
    assert cancel_events[-1].headers["Idempotency-Key"] == f"cancel:{created.json()['id']}"
    assert customer_rows(app, "alice-id") == set()
    with app.state.session_factory() as db:
        assert db.scalar(select(ServiceRequest.id)) is None and db.scalar(select(Outbox.id)) is None


def test_delete_reports_when_the_sign_in_cannot_be_removed(harness):
    client, state, app, _ = harness
    create_vehicle(client)
    state["admin_status"] = 500
    response = client.delete("/v1/account", headers=h("alice"))
    assert response.status_code == 200, response.text
    assert response.json()["sign_in_removed"] is False
    assert customer_rows(app, "alice-id") == set()


def test_delete_without_service_key_keeps_the_identity_but_erases_the_data(tmp_path):
    settings = Settings(database_url=f"sqlite:///{tmp_path / 'db.sqlite'}", environment="test",
                        photo_dir=str(tmp_path / "photos"))
    app = create_app(settings, auth_verifier=lambda token: IDENTITIES.get(token))
    with TestClient(app) as client:
        create_vehicle(client)
        response = client.delete("/v1/account", headers=h("alice"))
        assert response.status_code == 200, response.text
        assert response.json()["sign_in_removed"] is False
        assert customer_rows(app, "alice-id") == set()


def test_delete_is_rate_limited_and_refused_for_demo_sessions(tmp_path):
    settings = Settings(database_url=f"sqlite:///{tmp_path / 'db.sqlite'}", environment="demo",
                        dev_sessions_enabled=True, dev_token_secret="x" * 32, photo_dir=str(tmp_path / "photos"))
    app = create_app(settings, auth_verifier=lambda token: IDENTITIES.get(token))
    Base.metadata.create_all(app.state.engine)
    with TestClient(app) as client:
        demo = client.post("/v1/dev/session").json()["access_token"]
        assert client.delete("/v1/account", headers={"Authorization": f"Bearer {demo}"}).status_code == 403
        assert client.get("/v1/bootstrap", headers={"Authorization": f"Bearer {demo}"}).json()["vehicles"] != []
        create_vehicle(client)
        with app.state.session_factory() as db:
            db.add(RateBucket(customer_id="alice-id", action="account_delete",
                              hour_bucket=int(now().timestamp() // 3600), count=5))
            db.commit()
        assert client.delete("/v1/account", headers=h("alice")).status_code == 429
        assert customer_rows(app, "alice-id") >= {"customers", "vehicles"}

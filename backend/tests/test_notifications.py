"""Customer activity feed, email delivery and anonymous client error reports."""
from datetime import date, timedelta, timezone

import httpx
from sqlalchemy import select

from estimoto_plus.client_errors import prune_client_errors
from estimoto_plus.models import Customer, Vehicle, now
from estimoto_plus.notification_models import ClientError, Notification
from estimoto_plus.notifications import deliver_notification_emails, scan_due_reminders
from test_api import clients, create_vehicle, h, publish  # noqa: F401  fixture re-export

BRIDGE = {"X-Bridge-Key": "bridge-secret"}


def delivered_request(client, description="Hail dents", key="req-1"):
    vehicle = create_vehicle(client)
    provider = publish(client)
    body = {"vehicle_id": vehicle, "provider_id": provider, "specialty": "pdr", "description": description,
            "preferred_time": "Weekday", "share_contact": True}
    created = client.post("/v1/requests", headers={**h("alice"), "Idempotency-Key": key}, json=body)
    assert created.status_code == 201, created.text
    assert client.post("/v1/bridge/outbox/deliver", headers=BRIDGE).status_code == 200
    return created.json()["id"], provider, vehicle


def test_provider_events_become_notices_once_and_stay_private(clients):
    client, _ = clients
    request_id, provider, _ = delivered_request(client)
    event = {"event_id": "evt-1", "provider_id": provider, "status": "accepted", "message": "See you Tuesday"}
    assert client.post(f"/v1/bridge/requests/{request_id}/events", headers=BRIDGE, json=event).status_code == 200
    # Replayed event: same request view, no second notice.
    assert client.post(f"/v1/bridge/requests/{request_id}/events", headers=BRIDGE, json=event).status_code == 200
    assert client.get("/v1/notifications").status_code == 401
    feed = client.get("/v1/notifications", headers=h("alice")).json()
    assert feed["unread"] == 1 and feed["email_updates"] is True
    [notice] = feed["notifications"]
    assert notice["kind"] == "request_accepted" and notice["title"] == "PDR Shop accepted your request"
    assert notice["body"] == "See you Tuesday" and notice["source_id"] == request_id and notice["read_at"] is None
    assert client.get("/v1/notifications", headers=h("bob")).json() == {"notifications": [], "unread": 0, "email_updates": True}
    assert client.get("/v1/bootstrap", headers=h("alice")).json()["unread_notifications"] == 1

    scheduled = {"event_id": "evt-2", "provider_id": provider, "status": "scheduled", "message": "",
                 "scheduled_at": "2026-10-01T15:00:00+00:00"}
    assert client.post(f"/v1/bridge/requests/{request_id}/events", headers=BRIDGE, json=scheduled).status_code == 200
    feed = client.get("/v1/notifications", headers=h("alice")).json()
    assert [n["kind"] for n in feed["notifications"]] == ["request_scheduled", "request_accepted"]
    assert "2026-10-01T15:00:00+00:00" in feed["notifications"][0]["body"]

    marked = client.post("/v1/notifications/read", headers=h("alice"), json={"ids": [notice["id"]]})
    assert marked.json() == {"unread": 1}
    assert client.post("/v1/notifications/read", headers=h("bob"), json={"all": True}).json() == {"unread": 0}
    assert client.get("/v1/bootstrap", headers=h("alice")).json()["unread_notifications"] == 1
    assert client.post("/v1/notifications/read", headers=h("alice"), json={"all": True}).json() == {"unread": 0}
    assert all(n["read_at"] for n in client.get("/v1/notifications", headers=h("alice")).json()["notifications"])


def test_estimate_ready_and_shop_confirmation_notices(clients):
    client, _ = clients
    vehicle = create_vehicle(client)
    snapshot = {"source_id": "est-1", "customer_id": "alice-id", "vehicle_id": vehicle, "discipline": "pdr",
                "description": "Hail", "status": "reviewing", "provider_name": "Demolition Dent"}
    assert client.post("/v1/bridge/estimates/snapshots", headers=BRIDGE, json=snapshot).status_code == 200, "reviewing"
    assert client.get("/v1/notifications", headers=h("alice")).json()["unread"] == 0
    ready = {**snapshot, "status": "ready", "amount_cents": 42500}
    assert client.post("/v1/bridge/estimates/snapshots", headers=BRIDGE, json=ready).status_code == 200
    assert client.post("/v1/bridge/estimates/snapshots", headers=BRIDGE, json=ready).status_code == 200
    feed = client.get("/v1/notifications", headers=h("alice")).json()
    assert feed["unread"] == 1
    assert feed["notifications"][0]["title"] == "Demolition Dent sent your estimate: $425.00"
    assert feed["notifications"][0]["source_kind"] == "estimate"


def test_due_reminders_notify_once_per_due_date_or_mileage(clients):
    client, _ = clients
    vehicle = create_vehicle(client)
    assert client.put(f"/v1/vehicles/{vehicle}", headers=h("alice"), json={"mileage": 61000, "nickname": "Blue truck"}).status_code == 200
    due = client.post("/v1/reminders", headers=h("alice"), json={"vehicle_id": vehicle, "title": "Oil change", "due_date": "2026-09-01"})
    later = client.post("/v1/reminders", headers=h("alice"), json={"vehicle_id": vehicle, "title": "Registration", "due_date": "2026-12-01"})
    mileage = client.post("/v1/reminders", headers=h("alice"), json={"vehicle_id": vehicle, "title": "Tire rotation", "due_mileage": 60000})
    far = client.post("/v1/reminders", headers=h("alice"), json={"vehicle_id": vehicle, "title": "Brakes", "due_mileage": 90000})
    assert all(r.status_code == 201 for r in (due, later, mileage, far))
    factory = client.app.state.session_factory
    assert scan_due_reminders(factory, today=date(2026, 9, 19)) == 2
    assert scan_due_reminders(factory, today=date(2026, 9, 20)) == 2  # same due dates: no duplicate notices
    feed = client.get("/v1/notifications", headers=h("alice")).json()
    titles = sorted(n["title"] for n in feed["notifications"])
    assert titles == ["Oil change is due for Blue truck", "Tire rotation is due for Blue truck"]
    assert feed["unread"] == 2
    assert client.post(f"/v1/reminders/{due.json()['id']}/complete", headers=h("alice")).status_code == 200
    assert scan_due_reminders(factory, today=date(2026, 12, 1)) == 2  # Registration now due; Oil change completed
    assert len(client.get("/v1/notifications", headers=h("alice")).json()["notifications"]) == 3


def test_emails_follow_the_customer_preference_and_resend_outcomes(clients, monkeypatch):
    client, _ = clients
    request_id, provider, _ = delivered_request(client)
    monkeypatch.setenv("RESEND_API_KEY", "resend-fixture")
    monkeypatch.setenv("EMAIL_FROM", "Estimoto Plus <hello@example.test>")
    monkeypatch.setenv("SHOP_ACTION_BASE_URL", "https://plus.example.test")
    mails, outcome = [], {"status": 200}

    def resend(request):
        mails.append(request)
        return httpx.Response(outcome["status"], json={"id": f"email-{len(mails)}", "name": "validation_error"})

    transport = httpx.MockTransport(resend)
    factory = client.app.state.session_factory
    event = {"event_id": "evt-mail-1", "provider_id": provider, "status": "accepted", "message": "Bring the keys"}
    assert client.post(f"/v1/bridge/requests/{request_id}/events", headers=BRIDGE, json=event).status_code == 200
    assert deliver_notification_emails(factory, transport, api_url="https://mail.example/emails") == {"sent": 1, "skipped": 0, "failed": 0}
    [mail] = mails
    assert mail.headers["Authorization"] == "Bearer resend-fixture"
    assert mail.headers["Idempotency-Key"].startswith("customer-notification:")
    import json
    payload = json.loads(mail.content)
    assert payload["to"] == ["alice@example.test"] and payload["subject"] == "PDR Shop accepted your request"
    assert "Bring the keys" in payload["text"] and "turn these emails off in Settings" in payload["text"]
    assert deliver_notification_emails(factory, transport) == {"sent": 0, "skipped": 0, "failed": 0}

    # Turning email updates off skips new notices without touching the feed.
    assert client.put("/v1/notifications/preferences", headers=h("alice"), json={"email_updates": False}).json() == {"email_updates": False}
    assert client.get("/v1/bootstrap", headers=h("alice")).status_code == 200
    scheduled = {"event_id": "evt-mail-3", "provider_id": provider, "status": "scheduled", "message": "", "scheduled_at": "2026-10-01T15:00:00+00:00"}
    assert client.post(f"/v1/bridge/requests/{request_id}/events", headers=BRIDGE, json=scheduled).status_code == 200
    assert deliver_notification_emails(factory, transport) == {"sent": 0, "skipped": 1, "failed": 0}
    assert len(mails) == 1
    assert client.get("/v1/notifications", headers=h("alice")).json()["unread"] == 2

    # A permanent provider rejection marks the email failed; the notice remains in the app.
    assert client.put("/v1/notifications/preferences", headers=h("alice"), json={"email_updates": True}).status_code == 200
    completed = {"event_id": "evt-mail-4", "provider_id": provider, "status": "completed", "message": "Done"}
    assert client.post(f"/v1/bridge/requests/{request_id}/events", headers=BRIDGE, json=completed).status_code == 200
    outcome["status"] = 422
    assert deliver_notification_emails(factory, transport) == {"sent": 0, "skipped": 0, "failed": 1}
    with factory() as db:
        statuses = sorted(db.scalars(select(Notification.email_status)).all())
    assert statuses == ["failed", "sent", "skipped"]
    assert client.get("/v1/account/export", headers=h("alice")).json()["notifications"]["email_updates"] is True
    assert len(client.get("/v1/account/export", headers=h("alice")).json()["notifications"]["items"]) == 3


def test_unconfigured_mail_keeps_notices_pending_and_demo_customers_are_skipped(clients, monkeypatch):
    client, _ = clients
    monkeypatch.delenv("RESEND_API_KEY", raising=False)
    request_id, provider, _ = delivered_request(client)
    event = {"event_id": "evt-cfg", "provider_id": provider, "status": "accepted", "message": ""}
    assert client.post(f"/v1/bridge/requests/{request_id}/events", headers=BRIDGE, json=event).status_code == 200
    factory = client.app.state.session_factory
    assert deliver_notification_emails(factory, httpx.MockTransport(lambda r: httpx.Response(500))) == {"sent": 0, "skipped": 0, "failed": 0}
    with factory() as db:
        row = db.scalar(select(Notification))
        pending_until = row.next_email_at if row.next_email_at.tzinfo else row.next_email_at.replace(tzinfo=timezone.utc)
        assert row.email_status == "pending" and pending_until > now() + timedelta(minutes=10)
        db.get(Customer, "alice-id").demo = True
        row.next_email_at = now()
        db.commit()
    assert deliver_notification_emails(factory, None) == {"sent": 0, "skipped": 1, "failed": 0}


def test_client_error_reports_are_anonymous_deduplicated_and_pruned(clients):
    client, _ = clients
    report = {"platform": "ios", "app_version": "0.1.0", "build_number": "16", "source_sha": "abc1234",
              "kind": "StateError", "message": "Bad state for alice@example.test call 303-555-0100",
              "stack": "#0 main (package:estimoto_plus/main.dart:12)\n#1 token eyJabcdefghijklmnop.qrstuvwxyz0123456789"}
    assert client.post("/v1/client-errors", json=report).status_code == 202
    assert client.post("/v1/client-errors", json=report).status_code == 202
    assert client.post("/v1/client-errors", json={**report, "extra": 1}).status_code == 422
    assert client.get("/v1/bridge/client-errors").status_code == 401
    listing = client.get("/v1/bridge/client-errors", headers=BRIDGE).json()["errors"]
    assert len(listing) == 1 and listing[0]["occurrences"] == 2
    assert listing[0]["message"] == "Bad state for [email] call [number]"
    assert "[redacted]" in listing[0]["stack"] and "eyJ" not in listing[0]["stack"]
    assert "customer" not in listing[0]
    factory = client.app.state.session_factory
    with factory() as db:
        row = db.scalar(select(ClientError))
        row.last_seen_at = now() - timedelta(days=31)
        db.commit()
    assert prune_client_errors(factory) == 1
    assert client.get("/v1/bridge/client-errors", headers=BRIDGE).json() == {"errors": []}

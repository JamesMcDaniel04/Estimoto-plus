"""Per-IP abuse guard: 401 sprays and public routes are throttled, health never is."""
import pytest
from fastapi import FastAPI, HTTPException, Request
from fastapi.testclient import TestClient
from starlette.responses import PlainTextResponse

from estimoto_plus import abuse_guard
from estimoto_plus.abuse_guard import AbuseGuard

BODY = {"detail": "Too many attempts. Please try again later."}


def make_client(**limits):
    app = FastAPI()

    @app.get("/v1/private")
    def private(request: Request):
        if request.headers.get("authorization") != "Bearer ok":
            raise HTTPException(401, "Sign in to continue.")
        return {"ok": True}

    @app.get("/v1/shop-actions/{token}")
    def shop_action(token: str):
        return PlainTextResponse("shop")

    @app.post("/v1/client-errors")
    def client_errors():
        return {"received": True}

    @app.get("/android/current")
    def android_current():
        return {"version_name": "0.1.0"}

    @app.get("/health/live")
    def live():
        return {"status": "alive"}

    @app.get("/ready")
    def ready():
        return {"status": "ready"}

    @app.get("/version")
    def version():
        return {"source_sha": "x"}

    @app.get("/static.js")
    def static_file():
        return PlainTextResponse("console.log(1)")

    app.add_middleware(AbuseGuard, **limits)
    return TestClient(app)


def ip(address):
    return {"Fly-Client-IP": address}


@pytest.fixture
def frozen_clock(monkeypatch):
    now = [1_000.0]
    monkeypatch.setattr(abuse_guard, "clock", lambda: now[0])
    return now


def test_401_spray_is_throttled_per_ip_and_other_ips_unaffected(frozen_clock):
    with make_client(auth_failure_limit=3, public_limit=30) as client:
        for _ in range(4):  # limit is "more than 3" failures
            assert client.get("/v1/private", headers=ip("203.0.113.9")).status_code == 401
        blocked = client.get("/v1/private", headers=ip("203.0.113.9"))
        assert blocked.status_code == 429
        assert blocked.json() == BODY
        assert blocked.headers["Cache-Control"] == "private, no-store"
        assert 1 <= int(blocked.headers["Retry-After"]) <= 60
        # A valid session from the throttled address is also refused until the window resets.
        assert client.get("/v1/private", headers={**ip("203.0.113.9"), "Authorization": "Bearer ok"}).status_code == 429
        # Even a public /v1/ route is refused for the throttled address.
        assert client.get("/v1/shop-actions/abc", headers=ip("203.0.113.9")).status_code == 429
        # Other addresses are untouched.
        assert client.get("/v1/private", headers=ip("198.51.100.4")).status_code == 401
        assert client.get("/v1/private", headers={**ip("198.51.100.4"), "Authorization": "Bearer ok"}).status_code == 200


def test_successful_requests_are_not_counted(frozen_clock):
    with make_client(auth_failure_limit=2, public_limit=30) as client:
        for _ in range(50):
            assert client.get("/v1/private", headers={**ip("203.0.113.1"), "Authorization": "Bearer ok"}).status_code == 200
        assert client.get("/v1/private", headers=ip("203.0.113.1")).status_code == 401


def test_public_routes_throttle_at_their_own_limit(frozen_clock):
    with make_client(auth_failure_limit=60, public_limit=2) as client:
        assert client.get("/android/current", headers=ip("203.0.113.5")).status_code == 200
        assert client.get("/v1/shop-actions/t", headers=ip("203.0.113.5")).status_code == 200
        third = client.post("/v1/client-errors", headers=ip("203.0.113.5"), json={})
        assert third.status_code == 429
        assert third.json() == BODY
        assert third.headers["Cache-Control"] == "private, no-store"
        assert "Retry-After" in third.headers
        assert client.get("/android/current", headers=ip("203.0.113.5")).status_code == 429
        # The public counter does not bleed into other addresses or authenticated routes.
        assert client.get("/android/current", headers=ip("203.0.113.6")).status_code == 200
        assert client.get("/v1/private", headers={**ip("203.0.113.5"), "Authorization": "Bearer ok"}).status_code == 200


def test_health_and_static_routes_are_never_limited(frozen_clock):
    with make_client(auth_failure_limit=1, public_limit=1) as client:
        for _ in range(3):
            client.get("/v1/private", headers=ip("203.0.113.7"))
            client.get("/android/current", headers=ip("203.0.113.7"))
        assert client.get("/v1/private", headers=ip("203.0.113.7")).status_code == 429
        for _ in range(20):
            assert client.get("/health/live", headers=ip("203.0.113.7")).status_code == 200
            assert client.get("/ready", headers=ip("203.0.113.7")).status_code == 200
            assert client.get("/version", headers=ip("203.0.113.7")).status_code == 200
            assert client.get("/static.js", headers=ip("203.0.113.7")).status_code == 200


def test_window_expiry_clears_counters(frozen_clock):
    with make_client(auth_failure_limit=1, public_limit=1, window_seconds=60) as client:
        client.get("/v1/private", headers=ip("203.0.113.8"))
        client.get("/v1/private", headers=ip("203.0.113.8"))
        client.get("/android/current", headers=ip("203.0.113.8"))
        assert client.get("/v1/private", headers=ip("203.0.113.8")).status_code == 429
        assert client.get("/android/current", headers=ip("203.0.113.8")).status_code == 429
        frozen_clock[0] += 60
        assert client.get("/v1/private", headers=ip("203.0.113.8")).status_code == 401
        assert client.get("/android/current", headers=ip("203.0.113.8")).status_code == 200


def test_client_ip_prefers_fly_header_then_forwarded_for_then_socket(frozen_clock):
    with make_client(auth_failure_limit=0, public_limit=30) as client:
        assert client.get("/v1/private", headers={"Fly-Client-IP": "203.0.113.20, 10.0.0.1",
                                                  "X-Forwarded-For": "198.51.100.1"}).status_code == 401
        assert client.get("/v1/private", headers={"Fly-Client-IP": "203.0.113.20"}).status_code == 429
        assert client.get("/v1/private", headers={"X-Forwarded-For": "198.51.100.1, 10.0.0.2"}).status_code == 401
        assert client.get("/v1/private", headers={"X-Forwarded-For": "198.51.100.1"}).status_code == 429
        assert client.get("/v1/private").status_code == 401  # ASGI client host ("testclient")
        assert client.get("/v1/private").status_code == 429


def test_counters_are_bounded_with_lru_eviction(frozen_clock):
    with make_client(auth_failure_limit=0, public_limit=30, max_entries=2) as client:
        assert client.get("/v1/private", headers=ip("203.0.113.30")).status_code == 401
        assert client.get("/v1/private", headers=ip("203.0.113.31")).status_code == 401
        assert client.get("/v1/private", headers=ip("203.0.113.32")).status_code == 401
        guard = client.app.middleware_stack
        while not isinstance(guard, AbuseGuard):
            guard = guard.app
        assert set(guard._counters) == {"203.0.113.31", "203.0.113.32"}
        assert all(len(key) <= 64 for key in guard._counters)


def test_create_app_registers_guard_outside_body_limit(tmp_path):
    from estimoto_plus.app import create_app
    from estimoto_plus.config import Settings
    from estimoto_plus.upload_limit import PhotoBodyLimit
    app = create_app(Settings(environment="test", database_url=f"sqlite:///{tmp_path / 'db.sqlite'}",
                              worker_enabled=False, photo_dir=str(tmp_path / "photos"),
                              bridge_url="https://bridge.example/requests", bridge_key="bridge-secret"),
                     auth_verifier=lambda token: None)
    classes = [m.cls for m in app.user_middleware]
    assert classes.index(AbuseGuard) < classes.index(PhotoBodyLimit)
    with TestClient(app) as client:
        assert client.get("/v1/requests", headers={"Authorization": "Bearer nope"}).status_code == 401
        assert client.get("/health/live").status_code == 200

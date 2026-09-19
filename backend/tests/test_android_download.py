"""The emailed Android URL remains public and resolves a verified release pointer."""

import httpx
import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

from estimoto_plus import android_download
from estimoto_plus.android_download import router, clear_current_cache
from scripts.publish_android_current import publish_pointer, verify_remote_apk


SHA = "fcdccd1ac2ca87a31b63f6716058378b94dbecb9e367eaac0a1eeb56ee643934"
CERT = "e6d106fccc6c0e77e04a46c64f8edffdafb11b502d4857e51606c725086581dd"
MANIFEST = {
    "package": "io.estimoto.plus",
    "version_name": "0.1.0",
    "version_code": 5,
    "sha256": SHA,
    "byte_size": 58234758,
    "certificate_sha256": CERT,
    "asset_url": "https://github.com/JamesMcDaniel04/Estimoto-/releases/download/v0.1.0-beta.5/estimoto-plus-0.1.0-5.apk",
}


@pytest.fixture(autouse=True)
def fresh_pointer_cache():
    clear_current_cache()
    yield
    clear_current_cache()


def client_for(responder):
    app = FastAPI()
    app.state.settings = type("Settings", (), {"supabase_url": "https://plus.example.supabase.co"})()
    app.state.android_transport = httpx.MockTransport(responder)
    app.include_router(router)
    return TestClient(app)


def test_public_download_uses_fresh_remote_pointer_without_login():
    seen = []

    def respond(request):
        seen.append(request)
        return httpx.Response(200, json=MANIFEST)

    with client_for(respond) as client:
        one = client.get("/android/download", follow_redirects=False)
        clear_current_cache()
        two = client.get("/android/download", follow_redirects=False)
        clear_current_cache()
        current = client.get("/android/current")
    assert one.status_code == two.status_code == 307
    assert one.headers["location"] == MANIFEST["asset_url"]
    assert one.headers["cache-control"] == "no-store"
    assert current.status_code == 200
    assert current.json()["download_url"] == "/android/download"
    assert current.json()["sha256"] == SHA
    assert len({str(request.url) for request in seen}) == 3, "each lookup bypasses CDN cache"
    assert all("cacheNonce=" in str(request.url) for request in seen)


def test_repeated_anonymous_lookups_reuse_cached_pointer_until_ttl(monkeypatch):
    seen = []
    now = [1_000.0]
    monkeypatch.setattr(android_download, "clock", lambda: now[0])

    def respond(request):
        seen.append(request)
        return httpx.Response(200, json=MANIFEST)

    with client_for(respond) as client:
        first = client.get("/android/current")
        now[0] += 59
        second = client.get("/android/download", follow_redirects=False)
        assert first.status_code == 200 and second.status_code == 307
        assert len(seen) == 1, "second hit inside the TTL is served from the cache"
        assert second.headers["location"] == MANIFEST["asset_url"]
        now[0] += 2  # past the 60 second TTL
        third = client.get("/android/current")
        assert third.status_code == 200 and third.json()["sha256"] == SHA
        assert len(seen) == 2, "expired cache triggers a fresh outbound fetch"
        fourth = client.get("/android/current")
        assert fourth.status_code == 200
        assert len(seen) == 2


def test_failed_pointer_lookup_is_not_cached():
    responses = [httpx.Response(404), httpx.Response(200, json=MANIFEST)]

    def respond(_request):
        return responses.pop(0)

    with client_for(respond) as client:
        assert client.get("/android/download", follow_redirects=False).status_code == 503
        recovered = client.get("/android/download", follow_redirects=False)
    assert recovered.status_code == 307
    assert responses == []


def test_missing_or_bad_pointer_fails_closed_without_redirect():
    bad = dict(MANIFEST, package="io.estimoto", asset_url="https://evil.example/a.apk")
    responses = [httpx.Response(404), httpx.Response(200, json=bad)]

    def respond(_request):
        return responses.pop(0)

    with client_for(respond) as client:
        missing = client.get("/android/download", follow_redirects=False)
        invalid = client.get("/android/download", follow_redirects=False)
    assert missing.status_code == invalid.status_code == 503
    assert "location" not in missing.headers
    assert "location" not in invalid.headers


def test_publisher_switches_pointer_only_after_verified_release_and_replay_is_noop():
    posted = []
    current = None

    def respond(request):
        nonlocal current
        if request.method == "GET" and "current.json" in str(request.url):
            return httpx.Response(200, json=current) if current else httpx.Response(400, json={"code": "NoSuchKey"})
        assert request.method == "POST" and "current.json" in str(request.url)
        assert request.headers["x-upsert"] == "true"
        assert request.headers["cache-control"] == "0"
        posted.append(1)
        current = __import__("json").loads(request.content)
        return httpx.Response(200, json={"Key": "android-releases/current.json"})

    with httpx.Client(transport=httpx.MockTransport(respond)) as client:
        assert publish_pointer(client, "https://plus.example.supabase.co", "private-key", MANIFEST) == "published"
        assert publish_pointer(client, "https://plus.example.supabase.co", "private-key", MANIFEST) == "already-current"
    assert len(posted) == 1


def test_publisher_rejects_public_apk_that_differs_from_local_hash():
    with httpx.Client(transport=httpx.MockTransport(lambda _: httpx.Response(200, content=b"wrong"))) as client:
        with pytest.raises(ValueError, match="differs"):
            verify_remote_apk(client, MANIFEST)

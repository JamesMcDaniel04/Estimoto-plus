"""Public, stable Android entry point backed by one remote release pointer.

Only the publisher can replace current.json. Versioned GitHub release assets
remain immutable; a stale CDN pointer still resolves the build it describes.
"""

import json
import re
import threading
import time
from uuid import uuid4

import httpx
from fastapi import APIRouter, HTTPException, Request
from fastapi.responses import JSONResponse, RedirectResponse


router = APIRouter(tags=["Android download"])
BUCKET = "android-releases"
CERTIFICATE_SHA256 = "e6d106fccc6c0e77e04a46c64f8edffdafb11b502d4857e51606c725086581dd"
_SHA = re.compile(r"[0-9a-f]{64}\Z")
_VERSION = re.compile(r"[0-9]+\.[0-9]+\.[0-9]+\Z")
_MAX_MANIFEST_BYTES = 4096
CURRENT_CACHE_SECONDS = 60
# Single-entry cache of the last *successful* pointer lookup so anonymous
# hits do not amplify egress: (url, expires_at, manifest). Failures never land here.
_cache_lock = threading.Lock()
_cache: tuple[str, float, dict] | None = None


def clock() -> float:
    return time.monotonic()


def clear_current_cache() -> None:
    global _cache
    with _cache_lock:
        _cache = None


def validate_manifest(value: object) -> dict:
    if not isinstance(value, dict) or set(value) != {
        "package", "version_name", "version_code", "sha256", "byte_size",
        "certificate_sha256", "asset_url",
    }:
        raise ValueError("Invalid Android release pointer")
    code, version, digest = value["version_code"], value["version_name"], value["sha256"]
    if (
        value["package"] != "io.estimoto.plus"
        or type(code) is not int or code < 1
        or not isinstance(version, str) or not _VERSION.fullmatch(version)
        or not isinstance(digest, str) or not _SHA.fullmatch(digest)
        or type(value["byte_size"]) is not int or not 1_000_000 <= value["byte_size"] <= 200_000_000
        or value["certificate_sha256"] != CERTIFICATE_SHA256
        or value["asset_url"] != (
            f"https://github.com/JamesMcDaniel04/Estimoto-/releases/download/"
            f"v{version}-beta.{code}/estimoto-plus-{version}-{code}.apk"
        )
    ):
        raise ValueError("Invalid Android release pointer")
    return value


def public_object_url(supabase_url: str, path: str) -> str:
    origin = supabase_url.rstrip("/")
    if not origin.startswith("https://") or "/" in origin.removeprefix("https://"):
        raise ValueError("Invalid Storage origin")
    return f"{origin}/storage/v1/object/public/{BUCKET}/{path}"


def current_manifest(request: Request) -> dict:
    global _cache
    settings = request.app.state.settings
    try:
        url = public_object_url(settings.supabase_url, "current.json")
        with _cache_lock:
            cached = _cache
        if cached and cached[0] == url and clock() < cached[1]:
            return dict(cached[2])
        transport = getattr(request.app.state, "android_transport", None)
        with httpx.Client(transport=transport, timeout=5, follow_redirects=False) as client:
            with client.stream("GET", url, params={"cacheNonce": uuid4().hex},
                               headers={"Accept": "application/json", "Cache-Control": "no-cache"}) as response:
                response.raise_for_status()
                chunks, size = [], 0
                for chunk in response.iter_bytes():
                    size += len(chunk)
                    if size > _MAX_MANIFEST_BYTES:
                        raise ValueError("Android release pointer too large")
                    chunks.append(chunk)
        manifest = validate_manifest(json.loads(b"".join(chunks)))
    except (httpx.HTTPError, ValueError, json.JSONDecodeError, KeyError) as exc:
        raise HTTPException(503, "Android download is temporarily unavailable.") from exc
    with _cache_lock:
        _cache = (url, clock() + CURRENT_CACHE_SECONDS, manifest)
    return dict(manifest)


@router.get("/android/current")
def android_current(request: Request):
    pointer = current_manifest(request)
    return JSONResponse({**pointer, "download_url": "/android/download"},
                        headers={"Cache-Control": "no-store"})


@router.get("/android/download")
def android_download(request: Request):
    pointer = current_manifest(request)
    return RedirectResponse(pointer["asset_url"], status_code=307,
                            headers={"Cache-Control": "no-store"})

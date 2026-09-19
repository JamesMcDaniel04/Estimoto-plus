"""Per-IP abuse guard: throttle 401 sprays and unauthenticated public routes.

Pure ASGI middleware. Counters are keyed on the client IP only, live in a
bounded in-memory LRU map with fixed windows, and are never logged.
"""
import math
import threading
import time
from collections import OrderedDict

from starlette.responses import JSONResponse

RETRY_DETAIL = {"detail": "Too many attempts. Please try again later."}
HEALTH_PATHS = frozenset({"/health/live", "/ready", "/version"})
PUBLIC_EXACT = frozenset({"/android/current", "/android/download"})
PUBLIC_PREFIXES = ("/v1/shop-actions/", "/v1/client-errors")
_MAX_KEY = 64


def clock() -> float:
    """Wall clock in seconds; tests monkeypatch this to move windows along."""
    return time.time()


def client_ip(scope) -> str:
    headers = {}
    for name, value in scope.get("headers", ()):
        if name in (b"fly-client-ip", b"x-forwarded-for") and name not in headers:
            headers[name] = value
    for name in (b"fly-client-ip", b"x-forwarded-for"):
        raw = headers.get(name)
        if raw:
            first = raw.decode("latin-1").split(",", 1)[0].strip()
            if first:
                return first[:_MAX_KEY]
    client = scope.get("client")
    if client and client[0]:
        return str(client[0])[:_MAX_KEY]
    return "unknown"


def is_public(path: str) -> bool:
    return path in PUBLIC_EXACT or path.startswith(PUBLIC_PREFIXES)


class _Counter:
    __slots__ = ("window", "auth_failures", "public_hits")

    def __init__(self, window: int):
        self.window = window
        self.auth_failures = 0
        self.public_hits = 0


class AbuseGuard:
    def __init__(self, app, *, auth_failure_limit: int = 60, public_limit: int = 30,
                 window_seconds: int = 60, max_entries: int = 10_000):
        self.app = app
        self.auth_failure_limit = auth_failure_limit
        self.public_limit = public_limit
        self.window_seconds = window_seconds
        self.max_entries = max_entries
        self._lock = threading.Lock()
        self._counters: "OrderedDict[str, _Counter]" = OrderedDict()

    # -- bookkeeping -------------------------------------------------------
    def _counter(self, ip: str, now: float) -> _Counter:
        """Return the live counter for ``ip`` (caller holds the lock)."""
        window = int(now // self.window_seconds)
        entry = self._counters.get(ip)
        if entry is None:
            entry = _Counter(window)
            self._counters[ip] = entry
            while len(self._counters) > self.max_entries:
                self._counters.popitem(last=False)
        else:
            self._counters.move_to_end(ip)
            if entry.window != window:
                entry.window = window
                entry.auth_failures = 0
                entry.public_hits = 0
        return entry

    def _retry_after(self, now: float) -> int:
        reset = (int(now // self.window_seconds) + 1) * self.window_seconds
        return max(1, math.ceil(reset - now))

    def record_auth_failure(self, ip: str) -> None:
        with self._lock:
            self._counter(ip, clock()).auth_failures += 1

    def _reject(self, now: float):
        return JSONResponse(RETRY_DETAIL, status_code=429, headers={
            "Retry-After": str(self._retry_after(now)),
            "Cache-Control": "private, no-store",
            "Referrer-Policy": "no-referrer",
            "X-Content-Type-Options": "nosniff",
        })

    # -- ASGI --------------------------------------------------------------
    async def __call__(self, scope, receive, send):
        path = scope.get("path", "") if scope["type"] == "http" else ""
        guarded = path.startswith("/v1/")
        public = is_public(path)
        if scope["type"] != "http" or path in HEALTH_PATHS or not (guarded or public):
            await self.app(scope, receive, send)
            return
        ip = client_ip(scope)
        now = clock()
        with self._lock:
            entry = self._counter(ip, now)
            blocked = guarded and entry.auth_failures > self.auth_failure_limit
            if not blocked and public:
                entry.public_hits += 1
                blocked = entry.public_hits > self.public_limit
        if blocked:
            await self._reject(now)(scope, receive, send)
            return
        if not guarded:
            await self.app(scope, receive, send)
            return

        async def counting_send(message):
            if message["type"] == "http.response.start" and message.get("status") == 401:
                self.record_auth_failure(ip)
            await send(message)

        await self.app(scope, receive, counting_send)

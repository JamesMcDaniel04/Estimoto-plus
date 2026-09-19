import asyncio
import logging
import os
from contextlib import asynccontextmanager, suppress
from pathlib import Path
from fastapi import FastAPI, HTTPException
from fastapi.exception_handlers import http_exception_handler
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles
from urllib.parse import urlparse
from sqlalchemy import create_engine, delete, event, text as sql_text
from sqlalchemy.orm import sessionmaker

from .account import router as account_router
from .auth import create_auth_client, dev_allowed, make_dev_token
from .auth_cache import VerifiedAuthCache
from .bridge import router as bridge_router
from .bridge_sync import sync_providers, sync_request_statuses
from .config import Settings
from .customer_routes import router as customer_router
from .delivery import deliver_batch
from .estimate_delivery import deliver_estimate_batch
from .models import Base, Customer, Provider, RateBucket, Vehicle, now
from . import shop_models  # register private saved-shop tables before test metadata creation
from .saved_shops import router as saved_shops_router, deliver_shop_batch
from .graph import router as graph_router
from .upload_limit import PhotoBodyLimit
from .vehicle_images import router as vehicle_images_router
from .android_download import router as android_download_router
from .calendar_routes import router as calendar_router
from .calendar_sync import sync_calendar_batch
from .capture_routes import router as capture_router
from .discovery import router as discovery_router
from .receipts import router as receipts_router, reconcile_receipts
from .vehicle_valuation import router as valuation_router
from .shop_media_catalog import router as shop_media_router


# Readiness fails closed until the database carries exactly this migration.
# tests/test_readiness.py keeps it equal to the Alembic head.
EXPECTED_SCHEMA_REVISION = "d9e4b82013c7"
RATE_BUCKET_RETENTION_HOURS = 48


def prune_rate_buckets(session_factory):
    """Hourly rate counters only matter for the current hour; drop the rest so the table stays bounded."""
    cutoff = int(now().timestamp() // 3600) - RATE_BUCKET_RETENTION_HOURS
    with session_factory() as db:
        removed = db.execute(delete(RateBucket).where(RateBucket.hour_bucket < cutoff)).rowcount
        db.commit()
    return removed


def create_app(settings: Settings | None = None, *, auth_verifier=None, auth_client=None, bridge_transport=None):
    settings = settings or Settings()
    if not settings.database_url:
        raise ValueError("DATABASE_URL is required")
    if settings.places_enabled and not settings.google_places_api_key:
        raise ValueError('PLACES_ENABLED requires GOOGLE_PLACES_API_KEY on the backend')
    if settings.environment == "production":
        required = (settings.supabase_url, settings.supabase_publishable_key, settings.bridge_url,
                    settings.estimate_bridge_url, settings.bridge_key, settings.source_sha)
        if not all(required) or not settings.database_url.startswith("postgresql+psycopg://"):
            raise ValueError("Production database, Auth, bridge, and source revision configuration is required")
        for url in (settings.supabase_url, settings.bridge_url, settings.estimate_bridge_url):
            parsed = urlparse(url)
            if parsed.scheme != "https" or not parsed.netloc or parsed.username or parsed.password or parsed.query or parsed.fragment:
                raise ValueError("Production upstream URLs must be fixed HTTPS URLs")
        if settings.dev_sessions_enabled or not Path(settings.photo_dir).is_absolute():
            raise ValueError("Production demo sessions are disabled and PHOTO_DIR must be absolute")
        photo_path = Path(settings.photo_dir)
        if not (os.path.ismount(photo_path) or os.path.ismount(photo_path.parent)):
            raise ValueError("Production photos require a mounted private volume")
        photo_path.mkdir(parents=True, exist_ok=True)
    if not 5 <= settings.worker_interval_seconds <= 300:
        raise ValueError("WORKER_INTERVAL_SECONDS must be between 5 and 300")
    origins = [origin.strip() for origin in settings.cors_origins.split(",") if origin.strip()]
    for origin in origins:
        parsed = urlparse(origin)
        if origin == "*" or parsed.scheme not in {"http", "https"} or not parsed.netloc or parsed.path or parsed.query or parsed.fragment:
            raise ValueError("CORS_ORIGINS must contain explicit HTTP origins")
    @asynccontextmanager
    async def lifespan(app):
        async def run_worker():
            provider_ticks = 300
            while True:
                await asyncio.sleep(settings.worker_interval_seconds)
                try:
                    await asyncio.to_thread(reconcile_receipts, app.state.session_factory, settings)
                    provider_ticks += settings.worker_interval_seconds
                    if provider_ticks >= 300:
                        await asyncio.to_thread(sync_providers, settings, app.state.bridge_transport, app.state.session_factory)
                        await asyncio.to_thread(prune_rate_buckets, app.state.session_factory)
                        provider_ticks = 0
                    await asyncio.to_thread(deliver_batch, settings, app.state.bridge_transport, app.state.session_factory)
                    await asyncio.to_thread(sync_request_statuses, settings, app.state.bridge_transport, app.state.session_factory)
                    if settings.estimate_bridge_url:
                        await asyncio.to_thread(deliver_estimate_batch, settings, app.state.bridge_transport, app.state.session_factory)
                    await asyncio.to_thread(deliver_shop_batch, app.state.session_factory,
                                            getattr(app.state, "shop_mail_transport", None),
                                            calendar_settings=settings, calendar_transport=app.state.calendar_transport)
                    await asyncio.to_thread(sync_calendar_batch, settings, app.state.session_factory, app.state.calendar_transport)
                except Exception as exc:
                    logging.getLogger(__name__).error("Plus background worker cycle failed: %s", type(exc).__name__)
        enabled = settings.worker_enabled if settings.worker_enabled is not None else settings.environment == "production"
        task = asyncio.create_task(run_worker()) if enabled else None
        try:
            yield
        finally:
            if task:
                task.cancel()
                with suppress(asyncio.CancelledError):
                    await task
            app.state.auth_cache.clear()
            if app.state.owns_auth_client:
                app.state.auth_client.close()

    production = settings.environment == 'production'
    app = FastAPI(title="Estimoto + API", version="1.0", lifespan=lifespan,
                  docs_url=None if production else '/docs',
                  redoc_url=None if production else '/redoc',
                  openapi_url=None if production else '/openapi.json')
    @app.middleware("http")
    async def privacy_headers(request, call_next):
        response = await call_next(request)
        response.headers["Referrer-Policy"] = "no-referrer"
        response.headers["X-Content-Type-Options"] = "nosniff"
        if production:
            response.headers['Strict-Transport-Security'] = 'max-age=31536000; includeSubDomains'
            response.headers['Content-Security-Policy'] = "frame-ancestors 'none'; base-uri 'self'; object-src 'none'"
            response.headers['X-Frame-Options'] = 'DENY'
        if request.url.path in ('/', '/index.html', '/flutter_bootstrap.js',
                                '/flutter_service_worker.js', '/main.dart.js', '/version.json', '/manifest.json'):
            response.headers['Cache-Control'] = 'no-cache, max-age=0, must-revalidate'
        if request.url.path.startswith("/v1/"):
            response.headers["Cache-Control"] = "private, no-store"
        if request.url.path.startswith('/capture/'):
            response.headers['X-Frame-Options'] = 'SAMEORIGIN'
            response.headers['Content-Security-Policy'] = (
                "default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'; "
                "img-src 'self' data: blob:; font-src 'self'; media-src 'self' blob:; "
                "worker-src 'self' blob:; connect-src 'none'; frame-ancestors 'self'; "
                "base-uri 'none'; form-action 'none'")
            response.headers['Permissions-Policy'] = 'camera=(self), microphone=()'
        return response

    app.add_middleware(PhotoBodyLimit)
    if origins:
        app.add_middleware(CORSMiddleware, allow_origins=origins, allow_credentials=False,
                           allow_methods=["GET", "POST", "PUT", "DELETE"],
                           allow_headers=["Authorization", "Content-Type", "Idempotency-Key"],
                           expose_headers=["X-Vehicle-Image-Source", "ETag", "Retry-After"])

    @app.exception_handler(HTTPException)
    async def coded_http_exception(request, exc):
        # Routes may raise a dict detail with a stable "code" for the app.
        if isinstance(exc.detail, dict) and "detail" in exc.detail:
            return JSONResponse(status_code=exc.status_code, content=exc.detail, headers=exc.headers)
        return await http_exception_handler(request, exc)

    @app.exception_handler(RequestValidationError)
    def validation_error(_request, _exc):
        return JSONResponse(status_code=422, content={"detail": "Invalid request fields."})

    @app.exception_handler(Exception)
    async def unexpected_error(request, exc):
        # Starlette's server-error path runs outside the privacy middleware, so
        # the response carries the same headers here and never a stack trace.
        logging.getLogger(__name__).exception("Unhandled error on %s %s", request.method, request.url.path)
        headers = {"Cache-Control": "private, no-store", "Referrer-Policy": "no-referrer",
                   "X-Content-Type-Options": "nosniff"}
        if production:
            headers["Strict-Transport-Security"] = "max-age=31536000; includeSubDomains"
            headers["X-Frame-Options"] = "DENY"
        return JSONResponse(status_code=500, content={"detail": "Something went wrong. Please try again."}, headers=headers)
    engine_kwargs = ({"connect_args": {"check_same_thread": False}} if settings.database_url.startswith("sqlite") else
                     {"connect_args": {"sslmode": "require"} if settings.environment == "production" else {},
                      "pool_pre_ping": True, "pool_size": 5, "max_overflow": 5,
                      "pool_timeout": 10, "pool_recycle": 1800})
    engine = create_engine(settings.database_url, **engine_kwargs)
    if settings.database_url.startswith("sqlite"):
        @event.listens_for(engine, "connect")
        def sqlite_pragmas(connection, _):
            connection.execute("PRAGMA foreign_keys=ON")
            connection.execute("PRAGMA busy_timeout=5000")
    if settings.environment == "test":
        Base.metadata.create_all(engine)
    app.state.engine = engine
    app.state.settings = settings
    app.state.session_factory = sessionmaker(engine, expire_on_commit=False)
    app.state.auth_verifier = auth_verifier
    app.state.auth_cache = VerifiedAuthCache()
    app.state.owns_auth_client = auth_client is None and auth_verifier is None
    app.state.auth_client = create_auth_client() if app.state.owns_auth_client else auth_client
    app.state.bridge_transport = bridge_transport
    app.state.calendar_transport = None
    app.state.capture_transport = None
    app.state.discovery_transport = None
    app.include_router(customer_router)
    app.include_router(account_router)
    app.include_router(bridge_router)
    app.include_router(saved_shops_router)
    app.include_router(graph_router)
    app.include_router(vehicle_images_router)
    app.include_router(android_download_router)
    app.include_router(calendar_router)
    app.include_router(capture_router)
    app.include_router(discovery_router)
    app.include_router(receipts_router)
    app.include_router(valuation_router)
    app.include_router(shop_media_router)

    @app.get("/health/live")
    def health_live():
        return {"status": "alive"}

    @app.get("/version")
    def version():
        return {"source_sha": settings.source_sha or "unknown"}

    @app.get("/ready")
    def ready():
        try:
            with engine.connect() as connection:
                revision = connection.scalar(sql_text("SELECT version_num FROM alembic_version"))
                connection.execute(sql_text("SELECT 1"))
            photo_path = Path(settings.photo_dir)
            if revision != EXPECTED_SCHEMA_REVISION or not photo_path.is_dir() or not os.access(photo_path, os.W_OK):
                raise RuntimeError("not ready")
            if settings.environment == "production" and not (os.path.ismount(photo_path) or os.path.ismount(photo_path.parent)):
                raise RuntimeError("not ready")
        except Exception:
            raise HTTPException(503, "Service is not ready.")
        return {"status": "ready", "schema_revision": revision}

    @app.post("/v1/dev/session")
    def dev_session():
        if not dev_allowed(settings):
            raise HTTPException(404, "Not found.")
        with app.state.session_factory() as db:
            c = db.get(Customer, "demo-customer")
            if c is None:
                c = Customer(id="demo-customer", email="demo@example.test", name="Alex Demo", postal_code="80202", demo=True)
                db.add(c)
                db.add(Vehicle(customer_id=c.id, year=2020, make="Demo", model="Sedan", nickname="My demo car"))
            if db.get(Provider, "demo-provider") is None:
                db.add(Provider(id="demo-provider", source_id="fictional-demo", name="Demo Dent Care", kind="shop",
                                specialties=["pdr"], postal_codes=["80202"], city="Denver", address="", phone="",
                                mobile_service=False, accepting_requests=True, public_visible=True, demo_only=True, description="Fictional demo provider"))
            db.commit()
        return {"access_token": make_dev_token(settings), "demo": True}

    if settings.web_dir:
        app.mount("/", StaticFiles(directory=settings.web_dir, html=True), name="web")

    return app

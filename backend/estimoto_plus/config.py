from dataclasses import dataclass, field
import os
from pathlib import Path


@dataclass
class Settings:
    places_enabled: bool = field(default_factory=lambda: os.getenv('PLACES_ENABLED', 'false').lower() == 'true')
    google_places_api_key: str = field(default_factory=lambda: os.getenv('GOOGLE_PLACES_API_KEY', ''), repr=False)
    places_daily_requests: int = field(default_factory=lambda: int(os.getenv('PLACES_DAILY_REQUESTS', '100')))
    discovery_enabled: bool = field(default_factory=lambda: os.getenv('DISCOVERY_ENABLED', 'false').lower() == 'true')
    discovery_daily_requests: int = field(default_factory=lambda: int(os.getenv('DISCOVERY_DAILY_REQUESTS', '30')))
    discovery_daily_bytes: int = field(default_factory=lambda: int(os.getenv('DISCOVERY_DAILY_BYTES', str(8 * 1024 * 1024))))
    calendar_enabled: bool = field(default_factory=lambda: os.getenv("GOOGLE_CALENDAR_ENABLED", "false").lower() == "true")
    nango_api_key: str = field(default_factory=lambda: os.getenv("NANGO_API_KEY", ""), repr=False)
    nango_environment: str = field(default_factory=lambda: os.getenv("NANGO_ENVIRONMENT", "production"))
    nango_allowed_key_fingerprints: str = field(default_factory=lambda: os.getenv("NANGO_ALLOWED_KEY_FINGERPRINTS", ""))
    nango_calendar_integration_id: str = field(default_factory=lambda: os.getenv("NANGO_CALENDAR_INTEGRATION_ID", "estimoto-plus-google-calendar"))
    valuation_enabled: bool = field(default_factory=lambda: os.getenv("VALUATION_ENABLED", "false").lower() == "true")
    valuation_daily_requests: int = field(default_factory=lambda: int(os.getenv("VALUATION_DAILY_REQUESTS", "20")))
    carsxe_api_key: str = field(default_factory=lambda: os.getenv("CARSXE_API_KEY", ""), repr=False)
    database_url: str = field(default_factory=lambda: os.getenv("DATABASE_URL", ""))
    environment: str = field(default_factory=lambda: os.getenv("ENVIRONMENT", "production"))
    supabase_url: str = field(default_factory=lambda: os.getenv("SUPABASE_URL", ""))
    supabase_publishable_key: str = field(default_factory=lambda: os.getenv("SUPABASE_PUBLISHABLE_KEY", ""))
    # Server-only. Lets account deletion remove the Auth identity as well as the customer's data.
    supabase_service_role_key: str = field(default_factory=lambda: os.getenv("SUPABASE_SERVICE_ROLE_KEY", ""), repr=False)
    bridge_url: str = field(default_factory=lambda: os.getenv("BRIDGE_REQUEST_URL", ""))
    estimate_bridge_url: str = field(default_factory=lambda: os.getenv("BRIDGE_ESTIMATE_URL", ""))
    bridge_key: str = field(default_factory=lambda: os.getenv("BRIDGE_KEY", ""))
    dev_sessions_enabled: bool = field(default_factory=lambda: os.getenv("DEV_SESSIONS_ENABLED", "false").lower() == "true")
    dev_token_secret: str = field(default_factory=lambda: os.getenv("DEV_TOKEN_SECRET", ""))
    photo_dir: str = field(default_factory=lambda: os.getenv("PHOTO_DIR", str(Path.home() / ".local/share/estimoto-plus/photos")))
    cors_origins: str = field(default_factory=lambda: os.getenv("CORS_ORIGINS", ""))
    source_sha: str = field(default_factory=lambda: os.getenv("SOURCE_SHA", ""))
    web_dir: str = field(default_factory=lambda: os.getenv("WEB_DIR", ""))
    worker_enabled: bool | None = field(default_factory=lambda: None if os.getenv("WORKER_ENABLED") is None else os.getenv("WORKER_ENABLED", "").lower() == "true")
    worker_interval_seconds: int = field(default_factory=lambda: int(os.getenv("WORKER_INTERVAL_SECONDS", "15")))

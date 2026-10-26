"""Settings, read from environment variables (or a local .env file that is never committed)."""
import os
from dataclasses import dataclass

try:  # python-dotenv is optional; hosted schedulers set real environment variables
    from dotenv import load_dotenv

    load_dotenv()
except ImportError:
    pass


def _int(name: str, default: int) -> int:
    value = os.environ.get(name, "").strip()
    if not value:
        return default
    try:
        return int(value)
    except ValueError:
        raise SystemExit(f"{name} must be a whole number, got {value!r}")


def _url(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value or value == "replace_me":
        raise SystemExit(f"{name} is not set. Copy .env.example to .env and fill it in, "
                         f"or set it as a secret in your scheduler.")
    return value


def _optional_url(name: str) -> str | None:
    value = os.environ.get(name, "").strip()
    return None if not value or value == "replace_me" else value


@dataclass(frozen=True)
class Settings:
    source_url: str
    warehouse_url: str
    batch_size: int
    lookback_minutes: int
    max_retries: int
    statement_timeout_s: int
    max_delete_fraction_pct: int
    crm_url: str | None = None          # optional second source; skipped when not set
    pipeline_name: str = "supply_chain_etl"
    source_system: str = "supabase_transactional"   # the ERP
    crm_source_system: str = "aiven_crm"


def load_settings() -> Settings:
    return Settings(
        source_url=_url("SOURCE_DATABASE_URL"),
        warehouse_url=_url("WAREHOUSE_DATABASE_URL"),
        batch_size=max(1, _int("ETL_BATCH_SIZE", 1000)),
        lookback_minutes=max(0, _int("ETL_LOOKBACK_MINUTES", 5)),
        max_retries=max(1, _int("ETL_MAX_RETRIES", 3)),
        statement_timeout_s=max(5, _int("ETL_STATEMENT_TIMEOUT_SECONDS", 45)),
        max_delete_fraction_pct=min(100, max(0, _int("ETL_MAX_DELETE_PERCENT", 20))),
        crm_url=_optional_url("CRM_DATABASE_URL"),
    )

"""M0 entrypoint: wait for Postgres, apply migrations, then idle.

No jobs, no FastAPI routes, no Kalshi client yet — those land in later
milestones. This container's only job right now is proving the stack comes
up clean and the schema lands.
"""

import json
import logging
import os
import signal
import sys
import time
from types import FrameType

import psycopg

logger = logging.getLogger("gamblobot")


class JsonFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        payload = {
            "level": record.levelname,
            "event": record.getMessage(),
            "logger": record.name,
        }
        for key, value in record.__dict__.items():
            if key not in logging.LogRecord("", 0, "", 0, "", (), None).__dict__:
                payload[key] = value
        return json.dumps(payload)


def configure_logging() -> None:
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(JsonFormatter())
    root = logging.getLogger()
    root.handlers = [handler]
    root.setLevel(logging.INFO)


def wait_for_db(database_url: str, timeout_seconds: int = 30) -> None:
    deadline = time.monotonic() + timeout_seconds
    last_error: Exception | None = None
    while time.monotonic() < deadline:
        try:
            with psycopg.connect(database_url, connect_timeout=3):
                return
        except psycopg.OperationalError as exc:
            last_error = exc
            time.sleep(1)
    raise RuntimeError(f"database not reachable after {timeout_seconds}s") from last_error


def main() -> None:
    configure_logging()

    database_url = os.environ["DATABASE_URL"]

    logger.info("waiting for database")
    wait_for_db(database_url)

    from gamblobot.db.migrate import apply_migrations

    applied = apply_migrations(database_url)
    logger.info(
        "migrations applied, tables ready",
        extra={"applied_count": len(applied), "applied_files": applied},
    )

    def handle_term(signum: int, frame: FrameType | None) -> None:
        logger.info("shutting down")
        sys.exit(0)

    signal.signal(signal.SIGTERM, handle_term)
    signal.signal(signal.SIGINT, handle_term)
    signal.pause()


if __name__ == "__main__":
    main()

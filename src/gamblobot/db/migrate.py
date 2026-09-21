"""Applies plain SQL migration files from migrations/ in filename order.

Tracks applied migrations in a schema_migrations table so re-running on an
already-migrated database is a no-op.
"""

import logging
from pathlib import Path

import psycopg

logger = logging.getLogger("gamblobot.migrate")

MIGRATIONS_DIR = Path(__file__).resolve().parents[3] / "migrations"

_CREATE_TRACKING_TABLE = """
create table if not exists schema_migrations (
    filename    text primary key,
    applied_at  timestamptz not null default now()
);
"""


def apply_migrations(database_url: str, migrations_dir: Path = MIGRATIONS_DIR) -> list[str]:
    """Applies any migration files not yet recorded. Returns filenames applied."""
    applied: list[str] = []
    migration_files = sorted(migrations_dir.glob("*.sql"))

    with psycopg.connect(database_url, autocommit=True) as conn:
        with conn.cursor() as cur:
            cur.execute(_CREATE_TRACKING_TABLE)
            cur.execute("select filename from schema_migrations")
            already_applied = {row[0] for row in cur.fetchall()}

        for path in migration_files:
            if path.name in already_applied:
                continue
            sql = path.read_text()
            with conn.transaction():
                with conn.cursor() as cur:
                    cur.execute(sql)
                    cur.execute(
                        "insert into schema_migrations (filename) values (%s)",
                        (path.name,),
                    )
            applied.append(path.name)
            logger.info("migration applied", extra={"file": path.name})

    return applied

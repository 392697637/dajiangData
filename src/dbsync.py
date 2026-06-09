# -*- coding: utf-8 -*-
"""PostgreSQL structure and data synchronization helpers."""

import os
import subprocess
import time
from dataclasses import dataclass
from typing import Iterable, List, Sequence

import psycopg2


def log_message(logger, message: str, level: str = "info") -> None:
    """Print transfer progress and write it to the logger when configured."""
    print(message)
    if logger is None:
        return
    log_func = getattr(logger, level, logger.info)
    log_func(message)


@dataclass(frozen=True)
class DbConfig:
    host: str
    port: int
    database: str
    user: str
    password: str

    @classmethod
    def from_dict(cls, data):
        return cls(
            host=data["host"],
            port=int(data.get("port", 5432)),
            database=data["database"],
            user=data["user"],
            password=data["password"],
        )

    def dsn_parts(self) -> List[str]:
        """Build connection arguments shared by pg_dump and psql."""
        return [
            "--host",
            self.host,
            "--port",
            str(self.port),
            "--username",
            self.user,
            "--dbname",
            self.database,
        ]


def connect_db(db: DbConfig):
    """Open a PostgreSQL connection from DbConfig."""
    return psycopg2.connect(
        host=db.host,
        port=db.port,
        dbname=db.database,
        user=db.user,
        password=db.password,
    )


def quote_table_name(table_name: str) -> str:
    """Quote the table part for pg_dump while keeping the schema readable."""
    parts = table_name.split(".")
    if len(parts) == 1:
        return table_name
    if len(parts) == 2:
        schema, table = parts
        return f'{schema}."{table}"'
    raise ValueError(f"Invalid table name: {table_name}")


def normalize_table_name(schema: str, table: str) -> str:
    """Return a schema-qualified object name."""
    return f"{schema}.{table}"


def split_object_name(object_name: str):
    """Split schema-qualified names, defaulting to public when omitted."""
    parts = object_name.split(".", 1)
    if len(parts) == 1:
        return "public", parts[0]
    return parts[0], parts[1]


def parse_function_config(function_name: str):
    """Parse function config into schema, name, and optional identity arguments."""
    schema, raw_name = split_object_name(function_name)
    if "(" not in raw_name:
        return schema, raw_name, None
    name, args = raw_name.split("(", 1)
    return schema, name, args.rstrip(")")


def quote_ident(value: str) -> str:
    """Quote a PostgreSQL identifier for generated SQL."""
    return '"' + value.replace('"', '""') + '"'


def qualify_name(schema: str, name: str) -> str:
    """Build a safely quoted schema-qualified SQL identifier."""
    return f"{quote_ident(schema)}.{quote_ident(name)}"


def table_exists(db: DbConfig, table_name: str) -> bool:
    """Check whether a base table exists in the target database."""
    schema, table = split_object_name(table_name)
    query = """
        SELECT EXISTS (
            SELECT 1
            FROM information_schema.tables
            WHERE table_schema = %s
              AND table_name = %s
              AND table_type = 'BASE TABLE'
        )
    """
    with connect_db(db) as conn:
        with conn.cursor() as cur:
            cur.execute(query, (schema, table))
            return bool(cur.fetchone()[0])


def view_exists(db: DbConfig, view_name: str) -> bool:
    """Check whether an ordinary view exists in the target database."""
    schema, view = split_object_name(view_name)
    query = """
        SELECT EXISTS (
            SELECT 1
            FROM information_schema.views
            WHERE table_schema = %s
              AND table_name = %s
        )
    """
    with connect_db(db) as conn:
        with conn.cursor() as cur:
            cur.execute(query, (schema, view))
            return bool(cur.fetchone()[0])


def function_exists(db: DbConfig, schema: str, name: str, args: str) -> bool:
    """Check whether a function with the exact identity arguments exists."""
    query = """
        SELECT EXISTS (
            SELECT 1
            FROM pg_proc p
            JOIN pg_namespace n ON n.oid = p.pronamespace
            WHERE n.nspname = %s
              AND p.proname = %s
              AND pg_get_function_identity_arguments(p.oid) = %s
              AND p.prokind = 'f'
        )
    """
    with connect_db(db) as conn:
        with conn.cursor() as cur:
            cur.execute(query, (schema, name, args))
            return bool(cur.fetchone()[0])


def drop_target_table_if_exists(db: DbConfig, table_name: str, logger=None) -> None:
    """Drop a target table only when it exists."""
    if not table_exists(db, table_name):
        log_message(logger, f"Target table does not exist, skip drop: {table_name}")
        return

    schema, table = split_object_name(table_name)
    statement = f"DROP TABLE {qualify_name(schema, table)} CASCADE"
    log_message(logger, f"Drop existing target table: {table_name}")
    execute_sql(db, [statement])


def drop_target_view_if_exists(db: DbConfig, view_name: str, logger=None) -> None:
    """Drop a target view only when it exists."""
    if not view_exists(db, view_name):
        log_message(logger, f"Target view does not exist, skip drop: {view_name}")
        return

    schema, view = split_object_name(view_name)
    statement = f"DROP VIEW {qualify_name(schema, view)} CASCADE"
    log_message(logger, f"Drop existing target view: {view_name}")
    execute_sql(db, [statement])


def drop_target_function_if_exists(
    db: DbConfig, schema: str, name: str, args: str, logger=None
) -> None:
    """Drop a target function only when the exact signature exists."""
    function_label = f"{schema}.{name}({args})"
    if not function_exists(db, schema, name, args):
        log_message(logger, f"Target function does not exist, skip drop: {function_label}")
        return

    statement = f"DROP FUNCTION {qualify_name(schema, name)}({args}) CASCADE"
    log_message(logger, f"Drop existing target function: {function_label}")
    execute_sql(db, [statement])


def fetch_tables(db: DbConfig, schemas: Sequence[str]) -> List[str]:
    """Fetch all ordinary table names from the configured schemas."""
    if not schemas:
        raise ValueError("At least one schema is required when no table list is set.")

    query = """
        SELECT table_schema, table_name
        FROM information_schema.tables
        WHERE table_type = 'BASE TABLE'
          AND table_schema = ANY(%s)
        ORDER BY table_schema, table_name
    """
    with connect_db(db) as conn:
        with conn.cursor() as cur:
            cur.execute(query, (list(schemas),))
            return [normalize_table_name(schema, table) for schema, table in cur.fetchall()]


def fetch_functions(db: DbConfig, schemas: Sequence[str]) -> List[str]:
    """Fetch functions as schema.name(identity_args), including overloads."""
    if not schemas:
        raise ValueError("At least one schema is required when no function list is set.")

    query = """
        SELECT n.nspname, p.proname, pg_get_function_identity_arguments(p.oid)
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = ANY(%s)
          AND p.prokind = 'f'
        ORDER BY n.nspname, p.proname, pg_get_function_identity_arguments(p.oid)
    """
    with connect_db(db) as conn:
        with conn.cursor() as cur:
            cur.execute(query, (list(schemas),))
            return [
                f"{schema}.{name}({args})" for schema, name, args in cur.fetchall()
            ]


def fetch_views(db: DbConfig, schemas: Sequence[str]) -> List[str]:
    """Fetch all ordinary views from the configured schemas."""
    if not schemas:
        raise ValueError("At least one schema is required when no view list is set.")

    query = """
        SELECT table_schema, table_name
        FROM information_schema.views
        WHERE table_schema = ANY(%s)
        ORDER BY table_schema, table_name
    """
    with connect_db(db) as conn:
        with conn.cursor() as cur:
            cur.execute(query, (list(schemas),))
            return [normalize_table_name(schema, view) for schema, view in cur.fetchall()]


def ensure_target_database(db: DbConfig) -> None:
    """Fail early when the target database is not reachable."""
    try:
        with connect_db(db):
            return
    except psycopg2.OperationalError as exc:
        raise RuntimeError(
            f"Cannot connect to target database {db.database} at {db.host}:{db.port}: {exc}"
        ) from exc


def run_pipeline(
    dump_cmd: Sequence[str],
    restore_cmd: Sequence[str],
    source_password: str,
    target_password: str,
) -> None:
    """Pipe pg_dump output directly into psql without creating a dump file."""
    dump_env = os.environ.copy()
    dump_env["PGPASSWORD"] = source_password
    restore_env = os.environ.copy()
    restore_env["PGPASSWORD"] = target_password

    dump_proc = subprocess.Popen(
        dump_cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=dump_env,
        text=False,
    )
    restore_proc = subprocess.Popen(
        restore_cmd,
        stdin=dump_proc.stdout,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=restore_env,
        text=False,
    )
    if dump_proc.stdout is not None:
        dump_proc.stdout.close()

    restore_stdout, restore_stderr = restore_proc.communicate()
    dump_stderr = dump_proc.stderr.read() if dump_proc.stderr is not None else b""
    dump_return = dump_proc.wait()

    if dump_return != 0:
        raise RuntimeError(
            "pg_dump failed:\n{}".format(dump_stderr.decode("utf-8", errors="replace"))
        )
    if restore_proc.returncode != 0:
        output = restore_stdout.decode("utf-8", errors="replace")
        error = restore_stderr.decode("utf-8", errors="replace")
        raise RuntimeError(f"psql restore failed:\n{output}\n{error}")


def sync_tables(
    source,
    target,
    tables: Iterable[str],
    *,
    pg_dump_bin: str = "pg_dump",
    psql_bin: str = "psql",
    extra_dump_args: Sequence[str] = (),
    clean: bool = True,
    logger=None,
) -> int:
    """
    同步表结构和数据。

    这里使用 pg_dump --table，不手写 CREATE TABLE，所以会完整保留：
    主键、唯一约束、外键、普通索引、PostGIS 空间索引、触发器、
    默认值、表注释、字段注释等。clean=True 时会先删除目标表再重建。
    """
    source_db = DbConfig.from_dict(source)
    target_db = DbConfig.from_dict(target)
    ensure_target_database(target_db)

    synced = 0
    for table_name in tables:
        started_at = time.perf_counter()
        table_arg = quote_table_name(table_name)
        log_message(logger, f"[TABLE] Start sync: {table_name}")
        try:
            if clean:
                drop_target_table_if_exists(target_db, table_name, logger=logger)

            dump_cmd = [
                pg_dump_bin,
                *source_db.dsn_parts(),
                "--format",
                "plain",
                "--table",
                table_arg,
                *extra_dump_args,
            ]

            restore_cmd = [
                psql_bin,
                *target_db.dsn_parts(),
                "--set",
                "ON_ERROR_STOP=1",
            ]

            run_pipeline(dump_cmd, restore_cmd, source_db.password, target_db.password)
            synced += 1
            elapsed = time.perf_counter() - started_at
            log_message(logger, f"[TABLE] Success: {table_name}, elapsed={elapsed:.2f}s")
        except Exception as exc:
            elapsed = time.perf_counter() - started_at
            log_message(
                logger,
                f"[TABLE] Failed: {table_name}, elapsed={elapsed:.2f}s, error={exc}",
                level="error",
            )
            raise

    return synced


def fetch_function_definitions(db: DbConfig, configured_functions: Sequence[str]):
    """Load CREATE OR REPLACE FUNCTION statements from the source database."""
    rows = []
    with connect_db(db) as conn:
        with conn.cursor() as cur:
            for configured in configured_functions:
                schema, name, args = parse_function_config(configured)
                if args is None:
                    cur.execute(
                        """
                        SELECT n.nspname, p.proname,
                               pg_get_function_identity_arguments(p.oid),
                               pg_get_functiondef(p.oid)
                        FROM pg_proc p
                        JOIN pg_namespace n ON n.oid = p.pronamespace
                        WHERE n.nspname = %s
                          AND p.proname = %s
                          AND p.prokind = 'f'
                        ORDER BY pg_get_function_identity_arguments(p.oid)
                        """,
                        (schema, name),
                    )
                else:
                    cur.execute(
                        """
                        SELECT n.nspname, p.proname,
                               pg_get_function_identity_arguments(p.oid),
                               pg_get_functiondef(p.oid)
                        FROM pg_proc p
                        JOIN pg_namespace n ON n.oid = p.pronamespace
                        WHERE n.nspname = %s
                          AND p.proname = %s
                          AND pg_get_function_identity_arguments(p.oid) = %s
                          AND p.prokind = 'f'
                        ORDER BY pg_get_function_identity_arguments(p.oid)
                        """,
                        (schema, name, args),
                    )
                rows.extend(cur.fetchall())
    return rows


def execute_sql(target_db: DbConfig, statements: Sequence[str]) -> None:
    """Execute generated DDL on the target database in one transaction."""
    if not statements:
        return
    with connect_db(target_db) as conn:
        with conn.cursor() as cur:
            for statement in statements:
                cur.execute(statement)
        conn.commit()


def sync_functions(source, target, functions: Iterable[str], logger=None) -> int:
    """单独同步函数定义，不依赖表数据同步入口。"""
    source_db = DbConfig.from_dict(source)
    target_db = DbConfig.from_dict(target)
    ensure_target_database(target_db)

    definitions = fetch_function_definitions(source_db, list(functions))
    statements = []
    for schema, name, args, definition in definitions:
        function_label = f"{schema}.{name}({args})"
        started_at = time.perf_counter()
        log_message(logger, f"[FUNCTION] Start sync: {function_label}")
        try:
            drop_target_function_if_exists(target_db, schema, name, args, logger=logger)
            execute_sql(target_db, [definition])
            elapsed = time.perf_counter() - started_at
            log_message(
                logger, f"[FUNCTION] Success: {function_label}, elapsed={elapsed:.2f}s"
            )
        except Exception as exc:
            elapsed = time.perf_counter() - started_at
            log_message(
                logger,
                f"[FUNCTION] Failed: {function_label}, elapsed={elapsed:.2f}s, error={exc}",
                level="error",
            )
            raise

    return len(definitions)


def fetch_view_definitions(db: DbConfig, configured_views: Sequence[str]):
    """Load CREATE VIEW definitions from the source database."""
    rows = []
    with connect_db(db) as conn:
        with conn.cursor() as cur:
            for configured in configured_views:
                schema, view = split_object_name(configured)
                cur.execute(
                    """
                    SELECT table_schema, table_name, view_definition
                    FROM information_schema.views
                    WHERE table_schema = %s
                      AND table_name = %s
                    """,
                    (schema, view),
                )
                row = cur.fetchone()
                if row is None:
                    raise RuntimeError(f"View not found in source database: {configured}")
                rows.append(row)
    return rows


def sync_views(source, target, views: Iterable[str], logger=None) -> int:
    """单独同步普通视图定义，不依赖表数据同步入口。"""
    source_db = DbConfig.from_dict(source)
    target_db = DbConfig.from_dict(target)
    ensure_target_database(target_db)

    definitions = fetch_view_definitions(source_db, list(views))
    for schema, view, definition in definitions:
        view_name = qualify_name(schema, view)
        view_label = f"{schema}.{view}"
        started_at = time.perf_counter()
        log_message(logger, f"[VIEW] Start sync: {view_label}")
        try:
            drop_target_view_if_exists(target_db, view_label, logger=logger)
            execute_sql(target_db, [f"CREATE VIEW {view_name} AS\n{definition}"])
            elapsed = time.perf_counter() - started_at
            log_message(logger, f"[VIEW] Success: {view_label}, elapsed={elapsed:.2f}s")
        except Exception as exc:
            elapsed = time.perf_counter() - started_at
            log_message(
                logger,
                f"[VIEW] Failed: {view_label}, elapsed={elapsed:.2f}s, error={exc}",
                level="error",
            )
            raise

    return len(definitions)


def resolve_tables(source, configured_tables, schemas):
    """Resolve configured table list, or discover all tables from schemas."""
    if configured_tables:
        return list(configured_tables)
    return fetch_tables(DbConfig.from_dict(source), schemas)


def resolve_functions(source, configured_functions, schemas):
    """Resolve configured function list, or discover all functions from schemas."""
    if configured_functions:
        return list(configured_functions)
    return fetch_functions(DbConfig.from_dict(source), schemas)


def resolve_views(source, configured_views, schemas):
    """Resolve configured view list, or discover all views from schemas."""
    if configured_views:
        return list(configured_views)
    return fetch_views(DbConfig.from_dict(source), schemas)

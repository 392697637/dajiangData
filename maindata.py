# -*- coding: utf-8 -*-
"""Database synchronization entry point."""

import argparse
import logging
import os
from datetime import datetime
from time import perf_counter

from datasettings import (
    PG_DUMP_BIN,
    PG_DUMP_EXTRA_ARGS,
    PSQL_BIN,
    SOURCE_DB,
    SYNC_FUNCTIONS,
    SYNC_SCHEMAS,
    SYNC_TABLES,
    SYNC_VIEWS,
    TARGET_DB,
)
from src.dbsync import (
    resolve_functions,
    resolve_tables,
    resolve_views,
    sync_functions,
    sync_tables,
    sync_views,
)


def setup_logging():
    os.makedirs("logs", exist_ok=True)
    log_file = os.path.join(
        "logs", "dbsync_{}.log".format(datetime.now().strftime("%Y%m%d"))
    )
    logger = logging.getLogger("dbsync")
    logger.setLevel(logging.INFO)
    logger.handlers.clear()

    file_handler = logging.FileHandler(log_file, encoding="utf-8")
    file_handler.setFormatter(
        logging.Formatter("%(asctime)s - %(levelname)s - %(message)s")
    )
    logger.addHandler(file_handler)
    return logger, log_file


def parse_args():
    parser = argparse.ArgumentParser(
        description="Sync PostgreSQL table structure and data from source to target."
    )
    parser.add_argument(
        "--list-tables",
        action="store_true",
        help="Only print the tables that would be synchronized.",
    )
    parser.add_argument(
        "--list-functions",
        action="store_true",
        help="Only print the functions that would be synchronized.",
    )
    parser.add_argument(
        "--list-views",
        action="store_true",
        help="Only print the views that would be synchronized.",
    )
    parser.add_argument(
        "--only",
        choices=["all", "tables", "functions", "views"],
        default="all",
        help="Choose which object type to sync.",
    )
    parser.add_argument(
        "--tables",
        nargs="+",
        help="Override datasettings.SYNC_TABLES, for example: public.jc_sheng public.jc_shi",
    )
    parser.add_argument(
        "--functions",
        nargs="+",
        help="Override datasettings.SYNC_FUNCTIONS, for example: public.fn_name(integer)",
    )
    parser.add_argument(
        "--views",
        nargs="+",
        help="Override datasettings.SYNC_VIEWS, for example: public.vw_name",
    )
    parser.add_argument(
        "--schemas",
        nargs="+",
        default=SYNC_SCHEMAS,
        help="Schemas to scan when no table list is configured.",
    )
    parser.add_argument(
        "--no-clean",
        action="store_true",
        help="Do not drop existing target tables before restore.",
    )
    return parser.parse_args()


def main():
    args = parse_args()
    logger, log_file = setup_logging()
    started_at = perf_counter()

    sync_all = args.only == "all"
    should_handle_tables = sync_all or args.only == "tables" or args.list_tables
    should_handle_functions = sync_all or args.only == "functions" or args.list_functions
    should_handle_views = sync_all or args.only == "views" or args.list_views

    tables = []
    functions = []
    views = []

    if should_handle_tables:
        configured_tables = args.tables if args.tables is not None else SYNC_TABLES
        tables = resolve_tables(SOURCE_DB, configured_tables, args.schemas)

    if should_handle_functions:
        configured_functions = (
            args.functions if args.functions is not None else SYNC_FUNCTIONS
        )
        functions = resolve_functions(SOURCE_DB, configured_functions, args.schemas)

    if should_handle_views:
        configured_views = args.views if args.views is not None else SYNC_VIEWS
        views = resolve_views(SOURCE_DB, configured_views, args.schemas)

    print("Source: {host}:{port}/{database}".format(**SOURCE_DB))
    print("Target: {host}:{port}/{database}".format(**TARGET_DB))
    print(f"Transfer log: {log_file}")
    logger.info("=" * 80)
    logger.info("Database sync started")
    logger.info("Source: {host}:{port}/{database}".format(**SOURCE_DB))
    logger.info("Target: {host}:{port}/{database}".format(**TARGET_DB))
    logger.info("Mode: %s", args.only)
    logger.info("Clean target tables: %s", not args.no_clean)

    if should_handle_tables:
        print(f"Tables: {len(tables)}")
        logger.info("Tables: %s", len(tables))
    if should_handle_functions:
        print(f"Functions: {len(functions)}")
        logger.info("Functions: %s", len(functions))
    if should_handle_views:
        print(f"Views: {len(views)}")
        logger.info("Views: %s", len(views))

    if args.list_tables or args.list_functions or args.list_views:
        message = "List mode only: no objects will be synced to target database."
        print(message)
        logger.info(message)
        if args.list_tables:
            print("Table list:")
            for table in tables:
                print(f"  - {table}")
                logger.info("Table list item: %s", table)
        if args.list_functions:
            print("Function list:")
            for function in functions:
                print(f"  - {function}")
                logger.info("Function list item: %s", function)
        if args.list_views:
            print("View list:")
            for view in views:
                print(f"  - {view}")
                logger.info("View list item: %s", view)
        logger.info("Database sync list command finished without transfer")
        return

    try:
        if should_handle_tables and tables:
            for table in tables:
                print(f"Will sync table: {table}")
                logger.info("Will sync table: %s", table)
            synced_tables = sync_tables(
                SOURCE_DB,
                TARGET_DB,
                tables,
                pg_dump_bin=PG_DUMP_BIN,
                psql_bin=PSQL_BIN,
                extra_dump_args=PG_DUMP_EXTRA_ARGS,
                clean=not args.no_clean,
                logger=logger,
            )
        else:
            synced_tables = 0

        if should_handle_functions and functions:
            synced_functions = sync_functions(SOURCE_DB, TARGET_DB, functions, logger=logger)
        else:
            synced_functions = 0

        if should_handle_views and views:
            synced_views = sync_views(SOURCE_DB, TARGET_DB, views, logger=logger)
        else:
            synced_views = 0

        elapsed = perf_counter() - started_at
        summary = "Done. Synced {} table(s), {} function(s), {} view(s). elapsed={:.2f}s".format(
            synced_tables, synced_functions, synced_views, elapsed
        )
        print(summary)
        logger.info(summary)
        logger.info("Database sync finished")
    except Exception:
        elapsed = perf_counter() - started_at
        logger.exception("Database sync failed, elapsed=%.2fs", elapsed)
        raise


if __name__ == "__main__":
    main()

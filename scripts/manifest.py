#!/usr/bin/env python3
"""Write the manifest that travels with a dump.

The row counts are the reason this file exists. The consumer compares them with
what actually landed in its database before it starts serving the data, so an
interrupted COPY stops being invisible — an incomplete restore otherwise looks
exactly like a smaller city.

The extract name and the import date are also what ODbL §4.6 asks to be published
alongside the transformation scripts.
"""

import argparse
import datetime
import json
import os
import subprocess
from typing import Dict

TABLES = ("poi", "pt_stop", "pt_line", "pt_line_stop", "coverage")


def psql_scalar(sql: str) -> str:
    return subprocess.run(
        ["psql", "-v", "ON_ERROR_STOP=1", "-X", "-q", "-t", "-A", "-c", sql],
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()


def row_counts(schema: str) -> Dict[str, int]:
    return {table: int(psql_scalar(f"SELECT count(*) FROM {schema}.{table}")) for table in TABLES}


def table_bytes(schema: str) -> Dict[str, int]:
    return {
        table: int(psql_scalar(f"SELECT pg_total_relation_size('{schema}.{table}')"))
        for table in TABLES
    }


def osm2pgsql_version() -> str:
    output = subprocess.run(
        ["osm2pgsql", "--version"], check=True, capture_output=True, text=True
    )
    return (output.stdout or output.stderr).splitlines()[0].strip()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--extract", required=True)
    parser.add_argument("--imported-on", required=True)
    parser.add_argument("--source-pbf", required=True)
    parser.add_argument("--schema", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    source_mtime = datetime.datetime.fromtimestamp(
        os.path.getmtime(args.source_pbf), datetime.timezone.utc
    )

    manifest = {
        "extract_name": args.extract,
        "imported_on": args.imported_on,
        "source_pbf": {
            "file": os.path.basename(args.source_pbf),
            "bytes": os.path.getsize(args.source_pbf),
            "downloaded_at": source_mtime.date().isoformat(),
        },
        "osm2pgsql_version": osm2pgsql_version(),
        "schema": args.schema,
        "row_counts": row_counts(args.schema),
        "table_bytes": table_bytes(args.schema),
    }

    with open(args.output, "w", encoding="utf-8") as handle:
        json.dump(manifest, handle, indent=2, sort_keys=True)
        handle.write("\n")

    print(f">> manifest: {json.dumps(manifest['row_counts'])}")


if __name__ == "__main__":
    main()

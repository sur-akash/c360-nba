"""Load c360_export.json.gz (the Snowflake export) into Postgres.

The export is one JSON object per line: {"t": "SCHEMA.TABLE", "r": {COLUMN: value, ...}}.
Rows are streamed into a staging table with COPY, then cast into the typed tables
with jsonb_populate_record, so every type conversion happens in Postgres.

Usage:
    python load_extract.py --dsn "postgresql://..." --file c360_export.json.gz

Run 01_tables.sql first. The script refuses to load into a table that already
has rows, so it cannot double-load.
"""
import argparse
import gzip
import json
import sys
import time

import psycopg


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dsn", required=True)
    ap.add_argument("--file", required=True)
    args = ap.parse_args()

    t0 = time.time()
    with psycopg.connect(args.dsn, autocommit=False) as conn, conn.cursor() as cur:
        cur.execute("create temp table _stage (t text not null, r jsonb not null) on commit drop")
        n = 0
        with cur.copy("copy _stage (t, r) from stdin") as cp, gzip.open(args.file, "rt") as f:
            for line in f:
                o = json.loads(line)
                row = {k.lower(): v for k, v in o["r"].items()}
                cp.write_row((o["t"].lower(), json.dumps(row)))
                n += 1
                if n % 200000 == 0:
                    print(f"  staged {n:,} rows", flush=True)
        print(f"staged {n:,} rows in {time.time()-t0:.0f}s", flush=True)

        cur.execute("select t, count(*) from _stage group by t order by t")
        tables = cur.fetchall()
        total = 0
        for t, cnt in tables:
            sch, name = t.split(".")
            cur.execute(
                "select 1 from information_schema.tables where table_schema=%s and table_name=%s",
                (sch, name))
            if not cur.fetchone():
                sys.exit(f"table {t} is missing -- run 01_tables.sql first")
            cur.execute(f"select exists (select 1 from {t})")
            if cur.fetchone()[0]:
                sys.exit(f"table {t} already has rows -- refusing to double-load")
            cur.execute(
                f"insert into {t} overriding system value "
                f"select (jsonb_populate_record(null::{t}, r)).* from _stage where t = %s",
                (t,))
            if cur.rowcount != cnt:
                sys.exit(f"{t}: staged {cnt} but inserted {cur.rowcount}")
            total += cnt
        conn.commit()
    print(f"loaded {total:,} rows into {len(tables)} tables in {time.time()-t0:.0f}s")
    if total != n:
        sys.exit(f"row mismatch: {n} staged, {total} loaded")


if __name__ == "__main__":
    main()

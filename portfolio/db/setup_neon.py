"""Build the Compass360 database in Postgres (Neon) from the Snowflake export.

One command, run once from your laptop:

    pip install "psycopg[binary]"
    python portfolio/db/setup_neon.py \\
        --dsn "postgresql://neondb_owner:...@ep-xxx.aws.neon.tech/neondb?sslmode=require" \\
        --file ~/Downloads/c360_export.json.gz

It does five things, in order, and stops at the first failure:

  1. creates the helper functions and the 48 tables     (00_helpers.sql, 01_tables.sql)
  2. loads all 1,580,976 rows from the export            (load_extract.py)
  3. creates the ported views and materialized views     (02_views.sql)
  4. checks the portfolio KPI row against the numbers Snowflake produced
  5. creates a least-privilege login for the app, c360_app: it can read
     everything and insert into APP.ACTION_FEEDBACK, and nothing else -- so the
     public app never holds the owner's password. Its connection string is
     printed at the end; that is the one that goes into Streamlit secrets.

--reset drops the four schemas first, for a clean rebuild.
"""
import argparse
import secrets
import subprocess
import sys
from pathlib import Path
from urllib.parse import urlsplit, urlunsplit

import psycopg

HERE = Path(__file__).resolve().parent
SCHEMAS = ("app", "gold", "curated", "raw")


def run_sql_file(conn, name):
    sql = (HERE / name).read_text()
    with conn.cursor() as cur:
        cur.execute(sql)
    conn.commit()
    print(f"  ran {name}")


def app_dsn(owner_dsn, password):
    u = urlsplit(owner_dsn)
    host = u.hostname + (f":{u.port}" if u.port else "")
    return urlunsplit((u.scheme, f"c360_app:{password}@{host}", u.path, u.query, ""))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dsn", required=True, help="owner connection string from the Neon console")
    ap.add_argument("--file", required=True, help="path to c360_export.json.gz")
    ap.add_argument("--reset", action="store_true", help="drop and rebuild the schemas first")
    args = ap.parse_args()
    if not Path(args.file).expanduser().exists():
        sys.exit(f"export not found: {args.file}")

    with psycopg.connect(args.dsn) as conn:
        exists = conn.execute(
            "select count(*) from information_schema.schemata where schema_name = any(%s)",
            (list(SCHEMAS),)).fetchone()[0]
        if exists and not args.reset:
            sys.exit("the schemas already exist -- rerun with --reset to rebuild from scratch")
        if args.reset:
            for s in SCHEMAS:
                conn.execute(f"drop schema if exists {s} cascade")
            conn.commit()
            print("  dropped existing schemas")

        print("1/5 tables")
        run_sql_file(conn, "00_helpers.sql")
        run_sql_file(conn, "01_tables.sql")

    print("2/5 data")
    subprocess.run([sys.executable, str(HERE / "load_extract.py"), "--dsn", args.dsn,
                    "--file", str(Path(args.file).expanduser())], check=True)

    with psycopg.connect(args.dsn) as conn:
        print("3/5 views")
        run_sql_file(conn, "02_views.sql")
        conn.autocommit = True
        conn.execute("analyze")

    print("4/5 check against Snowflake")
    subprocess.run([sys.executable, str(HERE / "validate.py"), args.dsn], check=True)

    print("5/5 app login")
    password = secrets.token_urlsafe(24)
    with psycopg.connect(args.dsn, autocommit=True) as conn:
        db = conn.execute("select current_database()").fetchone()[0]
        role_exists = conn.execute("select 1 from pg_roles where rolname = 'c360_app'").fetchone()
        verb = "alter" if role_exists else "create"
        conn.execute(f"{verb} role c360_app with login password '{password}'")
        conn.execute(f'grant connect on database "{db}" to c360_app')
        for s in SCHEMAS:
            conn.execute(f"grant usage on schema {s} to c360_app")
            conn.execute(f"grant select on all tables in schema {s} to c360_app")
        conn.execute("grant insert on app.action_feedback to c360_app")
        conn.execute("grant usage on all sequences in schema app to c360_app")
        conn.execute("grant execute on all functions in schema public, curated to c360_app")

    print("\nDone. Paste this into Streamlit Community Cloud -> app -> Settings -> Secrets:\n")
    print("[connections.neon]")
    print(f'url = "{app_dsn(args.dsn, password)}"')
    print("\nThat login can read the data and record Accept/Reject decisions, nothing more.")


if __name__ == "__main__":
    main()

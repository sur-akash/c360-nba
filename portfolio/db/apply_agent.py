"""Add the live-Ask tools to a Compass360 database that is already built.

setup_neon.py now does this as part of a fresh build. For a database built
before the live Ask screen existed, run this once with the OWNER connection
string (not the c360_app one -- that login cannot create functions):

    python portfolio/db/apply_agent.py --dsn "postgresql://neondb_owner:...@ep-xxx.aws.neon.tech/neondb?sslmode=require"

It creates the tool functions, the full-text indexes and the APP.LLM_USAGE
counter, and grants the c360_app login what it needs to use them. It is safe
to run more than once.
"""
import argparse
from pathlib import Path

import psycopg

HERE = Path(__file__).resolve().parent


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dsn", required=True, help="owner connection string from the Neon console")
    args = ap.parse_args()
    with psycopg.connect(args.dsn, autocommit=True) as conn:
        if not conn.execute("select to_regclass('gold.customer_360')").fetchone()[0]:
            raise SystemExit("gold.customer_360 not found -- build the database with setup_neon.py first")
        conn.execute((HERE / "03_agent.sql").read_text())
        print("  ran 03_agent.sql")
        conn.execute("analyze raw.interaction")
        conn.execute("analyze app.product_doc_chunk")
        r = conn.execute("select app.get_next_best_actions('3925') ->> 'status'").fetchone()[0]
        n = conn.execute("select count(*) from app.search_interactions('business closed EMI', 3925)").fetchone()[0]
        ok = conn.execute("""select has_table_privilege('c360_app', 'app.llm_usage', 'insert, update')
                                and has_function_privilege('c360_app', 'app.get_next_best_actions(text)', 'execute')"""
                          ).fetchone()[0] if conn.execute(
                          "select 1 from pg_roles where rolname = 'c360_app'").fetchone() else None
    print(f"  next_best_actions(3925): {r}   search hits: {n}   c360_app grants: {ok}")
    if r != "OK" or not n or ok is False:
        raise SystemExit("something is off -- see above")
    print("Done. Add the [gemini] secret in Streamlit and reboot the app.")


if __name__ == "__main__":
    main()

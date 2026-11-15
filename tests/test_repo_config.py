"""
test_repo_config.py -- static checks that the repo agrees with itself.

No app run and no connection: these read files. They exist because the deploy
path has seams that fail silently -- a view the app reads but sql/20 does not
count, a stage copy that skips the theme, a contract entry nobody updated -- and
each is cheaper to catch by reading than by clicking.
"""

import ast
import re

import pytest

from conftest import APP, ROOT
from contract import APP_READS, FEEDBACK_INSERT_COLUMNS, REJECT_REASONS

SRC = APP.read_text(encoding="utf-8")
SQL = {p.name: p.read_text(encoding="utf-8") for p in sorted((ROOT / "sql").glob("*.sql"))}
ALL_SQL = "\n".join(SQL.values())
OBJECT = r"(?:APP|GOLD|CURATED|RAW)\.[A-Z_0-9]+"


def strings_in_app():
    """Every string literal in the app, with f-string holes replaced by {}."""
    out = []

    class V(ast.NodeVisitor):
        def visit_JoinedStr(self, node):               # do not descend: one string
            out.append("".join(v.value if isinstance(v, ast.Constant) else "{}"
                               for v in node.values))

        def visit_Constant(self, node):
            if isinstance(node.value, str):
                out.append(node.value)

    V().visit(ast.parse(SRC))
    return out


# A string is SQL the app sends if it starts with a statement keyword. Docstrings
# and comments that merely mention a table start with prose and are excluded.
SQL_STRINGS = [s for s in strings_in_app()
               if re.match(r"\s*(SELECT|INSERT|UPDATE|DELETE|MERGE|TRUNCATE|WITH)\b", s)]


# -- the contract covers the app, and the app stays inside it -----------------------

def test_every_object_the_app_queries_is_in_the_contract():
    used = set()
    for s in SQL_STRINGS:
        used |= set(re.findall(rf"\b(?:FROM|JOIN|INTO)\s+({OBJECT})", s))
    assert used, "found no SQL in the app -- the scanner is broken, not the app"
    assert used == set(APP_READS), (
        f"app queries {sorted(used - set(APP_READS))} with no entry in tests/contract.py; "
        f"contract lists {sorted(set(APP_READS) - used)} the app no longer queries")


def test_every_explicitly_selected_column_is_in_the_contract():
    checked = 0
    for s in SQL_STRINGS:
        flat = " ".join(s.split())
        m = re.match(rf"SELECT (.*?) FROM ({OBJECT})\b", flat)
        if not m:
            continue
        cols = [c.strip() for c in m.group(1).split(",")]
        if not all(re.fullmatch(r"[A-Z_0-9]+", c) for c in cols):
            continue                                   # SELECT *, aliases, aggregates
        missing = [c for c in cols if c not in APP_READS[m.group(2)]]
        assert not missing, f"{m.group(2)}: app selects {missing}, contract does not list them"
        checked += 1
    assert checked >= 6


def test_the_app_writes_to_exactly_one_table():
    writes = [" ".join(s.split())[:60] for s in SQL_STRINGS
              if re.search(r"\b(INSERT|UPDATE|DELETE|MERGE|TRUNCATE|DROP|ALTER|CREATE)\b", s)]
    assert len(writes) == 1 and writes[0].startswith("INSERT INTO APP.ACTION_FEEDBACK"), writes


def test_insert_names_the_contracted_columns_in_order():
    stmt = next(" ".join(s.split()) for s in SQL_STRINGS if "INSERT INTO" in s)
    cols = re.search(r"\((.*?)\)", stmt).group(1)
    assert [c.strip() for c in cols.split(",")] == FEEDBACK_INSERT_COLUMNS


def test_actor_and_timestamp_are_server_side():
    stmt = next(" ".join(s.split()) for s in SQL_STRINGS if "INSERT INTO" in s)
    assert stmt.endswith("CURRENT_USER(), CURRENT_TIMESTAMP()")


# -- AGENTS.md invariants, checked on the app source ---------------------------------

def test_the_app_cannot_see_the_answer_key():
    assert "CUSTOMER_SEGMENT_TRUTH" not in SRC.upper()
    for s in SQL_STRINGS:
        assert not re.search(r"\b(?:FROM|JOIN)\s+RAW\.", s), "the app must not read RAW directly"


def test_the_app_does_not_read_the_quarantined_sentiment_slope():
    assert "SENTIMENT_SLOPE_PER_30D" not in SRC.upper()          # PROJECT_BRIEF D6


def test_only_the_agent_call_can_spend_ai_credits():
    spenders = re.findall(r"SNOWFLAKE\.CORTEX\.\w+|\bAI_[A-Z_]+\s*\(", " ".join(SQL_STRINGS))
    assert spenders == ["SNOWFLAKE.CORTEX.DATA_AGENT_RUN"], spenders


# -- the contract against the SQL that builds the objects ------------------------------

@pytest.mark.parametrize("obj", sorted(APP_READS))
def test_object_is_created_by_a_numbered_script(obj):
    schema, name = obj.split(".")
    pat = rf"CREATE\s+(?:OR\s+REPLACE\s+)?(?:DYNAMIC\s+)?(?:TABLE|VIEW)\s+(?:IF\s+NOT\s+EXISTS\s+)?(?:{schema}\.)?{name}\b"
    assert re.search(pat, ALL_SQL, re.I), f"no CREATE statement for {obj} anywhere in sql/"


@pytest.mark.parametrize("obj", sorted(o for o in APP_READS if o.startswith("APP.")))
def test_contracted_columns_appear_in_the_objects_ddl(obj):
    name = obj.split(".")[1]
    m = re.search(rf"CREATE\s+(?:OR\s+REPLACE\s+)?(?:TABLE|VIEW)\s+(?:IF\s+NOT\s+EXISTS\s+)?APP\.{name}\b",
                  ALL_SQL, re.I)
    tail = ALL_SQL[m.end():]
    nxt = re.search(r"\n(?:CREATE|/\* =====)", tail)
    ddl = tail[:nxt.start()] if nxt else tail
    missing = [c for c in APP_READS[obj] if not re.search(rf"\b{c}\b", ddl, re.I)]
    assert not missing, f"{obj}: columns {missing} are read by the app but not defined in its DDL"


def test_feedback_table_ddl_has_exactly_the_contracted_columns():
    ddl = re.search(r"CREATE TABLE IF NOT EXISTS APP\.ACTION_FEEDBACK \((.*?)\n\)", ALL_SQL, re.S).group(1)
    cols = [ln.split()[0] for ln in ddl.splitlines()
            if ln.strip() and not ln.strip().startswith("CONSTRAINT")]
    assert cols == APP_READS["APP.ACTION_FEEDBACK"]
    assert "CHECK (DECISION IN ('ACCEPTED','REJECTED'))" in ddl


def test_feedback_table_is_never_replaced_or_dropped_by_the_build():
    """sql/19 PART 2: decisions cannot be recomputed, so no script may rebuild the table."""
    assert not re.search(r"CREATE\s+OR\s+REPLACE\s+TABLE\s+(?:APP\.)?ACTION_FEEDBACK", ALL_SQL, re.I)
    assert not re.search(r"(?:DROP|TRUNCATE)\s+TABLE\s+(?:IF\s+EXISTS\s+)?(?:APP\.)?ACTION_FEEDBACK", ALL_SQL, re.I)


def test_reject_reasons_match_the_list_documented_beside_the_table():
    m = re.search(r"The app's list is:(.*?)\*/", SQL["19_app_objects.sql"], re.S)
    documented = re.findall(r"[A-Z_]{4,}", m.group(1))
    assert documented == REJECT_REASONS


def test_deploy_assertions_count_every_app_view_the_app_reads():
    views = sorted(o.split(".")[1] for o in APP_READS if o.startswith("APP.V_"))
    a2 = re.search(r"TABLE_NAME IN \((.*?)\);", SQL["20_streamlit.sql"], re.S).group(1)
    a8 = re.search(r"A8 every app view is readable.*?\n\);", SQL["19_app_objects.sql"], re.S).group(0)
    # Both lists may hold more (V_RM_BOOK feeds V_WORKLIST), never less.
    assert set(views) <= set(re.findall(r"'(V_[A-Z_]+)'", a2)), "sql/20 A2 misses a view the app reads"
    assert set(views) <= set(re.findall(r"FROM APP\.(V_[A-Z_]+)", a8)), "sql/19 A8 misses a view the app reads"


def test_deploy_assertion_expects_the_feedback_tables_real_column_count():
    a3 = re.search(r"A3 feedback table writable.*?TABLE_NAME = 'ACTION_FEEDBACK'",
                   SQL["20_streamlit.sql"], re.S).group(0)
    assert f"COUNT(*) = {len(APP_READS['APP.ACTION_FEEDBACK'])}" in a3


# -- deployment configuration -----------------------------------------------------------

def test_streamlit_object_points_at_the_file_under_test():
    s = SQL["20_streamlit.sql"]
    assert re.search(r"MAIN_FILE\s*=\s*'streamlit_app\.py'", s)
    assert (ROOT / "app" / "streamlit_app.py").exists()
    assert re.search(r"CREATE OR REPLACE STREAMLIT APP\.C360_APP", s)
    assert "ALTER STREAMLIT APP.C360_APP ADD LIVE VERSION FROM LAST" in s


def test_environment_declares_every_third_party_import_from_the_snowflake_channel():
    env = (ROOT / "app" / "environment.yml").read_text()
    channels = re.search(r"channels:\n((?:\s+- .*\n)+)", env).group(1)
    assert re.findall(r"- (\S+)", channels) == ["snowflake"], "Anaconda Snowflake channel only"
    assert "pip:" not in env
    deps = set(re.findall(r"^\s+- ([a-z0-9\-]+)", env.split("dependencies:")[1], re.M))
    package = {"streamlit": "streamlit", "pandas": "pandas", "altair": "altair",
               "snowflake": "snowflake-snowpark-python"}
    stdlib = {"html", "json"}
    imported = set()
    for node in ast.parse(SRC).body:
        if isinstance(node, ast.Import):
            imported |= {a.name.split(".")[0] for a in node.names}
        elif isinstance(node, ast.ImportFrom):
            imported.add(node.module.split(".")[0])
    third_party = imported - stdlib
    assert third_party <= set(package), f"new import {third_party - set(package)}: add it to environment.yml"
    assert {package[m] for m in third_party} <= deps


def test_theme_matches_the_apps_own_colour_tokens():
    """config.toml exists for primaryColor; it must equal --ac or the one accent drifts."""
    toml = (ROOT / "app" / ".streamlit" / "config.toml").read_text()
    theme = dict(re.findall(r'^(\w+)\s*=\s*"(.*?)"', toml, re.M))
    token = dict(re.findall(r"--([\w-]+):(#[0-9A-Fa-f]{6})", SRC))
    assert theme["primaryColor"].upper() == token["ac"].upper()
    assert theme["textColor"].upper() == token["ink"].upper()
    assert theme["backgroundColor"].upper() == token["surf"].upper()
    assert theme["base"] == "light"


def test_rebuild_stages_the_app_and_the_theme_before_creating_the_streamlit_object():
    run = (ROOT / "run.sh").read_text()
    i19 = run.index("sql/19_app_objects.sql")
    icopy = run.index("snow stage copy app/ @C360_NBA.APP.APP_STAGE")
    itheme = run.index("snow stage copy app/.streamlit/config.toml @C360_NBA.APP.APP_STAGE/.streamlit/")
    i20 = run.index("sql/20_streamlit.sql")
    assert i19 < icopy < itheme < i20


def test_reset_script_clears_only_the_feedback_table():
    reset = (ROOT / "tools" / "reset_demo.sh").read_text()
    assert re.findall(r"TRUNCATE TABLE (\S+?);", reset) == ["APP.ACTION_FEEDBACK"]
    assert "DROP " not in reset.upper().replace("DROP AND", "")


def test_tests_are_not_staged_with_the_app():
    """Everything under app/ is copied to the stage; test code must not live there."""
    stray = [p.name for p in (ROOT / "app").rglob("*")
             if p.is_file() and (p.name.startswith("test_") or p.name == "conftest.py")]
    assert not stray

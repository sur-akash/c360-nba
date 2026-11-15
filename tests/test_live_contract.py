"""
test_live_contract.py -- what the app needs from the warehouse, checked there.

    pytest --live                     # read-only; warehouse compute only

Nothing here writes, and nothing calls an AI function. Every check is a SELECT
(or SHOW/DESCRIBE) against objects that were already paid for, so a full run
costs a few seconds of COCO_WH.

Three groups:
  CONTRACT        every object and column in tests/contract.py exists and can
                  actually be read -- CREATE VIEW succeeding is not the same thing
                  (sql/19 A8 records the time it was not).
  RECONCILIATION  figures the app shows in two places agree, and the numbers the
                  app has typed into its own prose are still true.
  DEPLOYMENT      the Streamlit object, its staged source, and the grant the
                  Accept/Reject write-back depends on.
"""

import re

import pytest

from conftest import APP, ROOT, one, rows, scalar
from contract import APP_READS, FEEDBACK_NOT_NULL

pytestmark = pytest.mark.live

PAST_DUE = "('CURRENT', 'NO_CREDIT_OBLIGATION')"       # DPD_BUCKET NOT IN -> past due


# =============================================================================
# CONTRACT
# =============================================================================

def test_connection_is_pointed_at_the_project(live_session):
    ctx = one(live_session, "SELECT CURRENT_ACCOUNT() ACCT, CURRENT_ROLE() ROLE, "
                            "CURRENT_WAREHOUSE() WH, CURRENT_DATABASE() DB")
    print(f"\n  account={ctx['ACCT']} role={ctx['ROLE']} warehouse={ctx['WH']}")
    assert ctx["DB"] == "C360_NBA"
    assert ctx["WH"], "connection has no warehouse; the app's queries would not run"


@pytest.mark.parametrize("obj", sorted(APP_READS))
def test_object_is_readable_with_every_column_the_app_uses(live_session, obj):
    cols = ", ".join(APP_READS[obj])
    live_session.sql(f"SELECT {cols} FROM C360_NBA.{obj} LIMIT 1").collect()


def test_feedback_table_has_exactly_the_columns_the_app_inserts_and_reads(live_session):
    cols = rows(live_session, """
        SELECT COLUMN_NAME, IS_NULLABLE FROM C360_NBA.INFORMATION_SCHEMA.COLUMNS
        WHERE TABLE_SCHEMA = 'APP' AND TABLE_NAME = 'ACTION_FEEDBACK'
        ORDER BY ORDINAL_POSITION""")
    assert [c["COLUMN_NAME"] for c in cols] == APP_READS["APP.ACTION_FEEDBACK"]
    not_null = {c["COLUMN_NAME"] for c in cols if c["IS_NULLABLE"] == "NO"}
    assert set(FEEDBACK_NOT_NULL) <= not_null


def test_kpi_view_returns_exactly_one_complete_row(live_session):
    k = one(live_session, "SELECT * FROM APP.V_PORTFOLIO_KPI")
    empty = [c for c in APP_READS["APP.V_PORTFOLIO_KPI"] if k[c] is None]
    assert not empty, f"KPI columns are NULL: {empty} -- the cockpit would show dashes"


def test_worklist_rows_carry_everything_a_card_and_the_insert_need(live_session):
    """A NULL in any of these is a crash on a card (.title() on None) or a broken
    INSERT (float(nan) -> the literal nan)."""
    need = ["CUSTOMER_ID", "CUSTOMER_NAME", "ACTION_CODE", "ACTION_NAME", "ACTION_RANK",
            "CATEGORY", "CHANNEL", "PROPENSITY", "EXPECTED_VALUE_INR", "RATIONALE",
            "PRIORITY_TIER", "EVIDENCE_COUNT"]
    # Aliases are prefixed: an alias equal to a column name is ambiguous to read.
    counts = one(live_session, "SELECT " + ", ".join(
        f"COUNT_IF({c} IS NULL) AS NULLS_{c}" for c in need) + " FROM APP.V_WORKLIST")
    nulls = {c.removeprefix("NULLS_"): int(n) for c, n in counts.items() if int(n)}
    assert not nulls, f"NULLs in V_WORKLIST: {nulls}"


def test_one_card_per_customer_and_action(live_session):
    """Widget keys are acc_<customer>_<action>. A duplicate pair is a
    DuplicateWidgetID crash on Customer 360."""
    dupes = scalar(live_session, """
        SELECT COUNT(*) FROM (SELECT CUSTOMER_ID, ACTION_CODE FROM APP.V_WORKLIST
                              GROUP BY 1, 2 HAVING COUNT(*) > 1)""")
    assert int(dupes) == 0


def test_no_customer_has_more_than_three_published_actions(live_session):
    assert int(scalar(live_session, """
        SELECT COALESCE(MAX(n), 0) FROM (SELECT COUNT(*) n FROM APP.V_WORKLIST GROUP BY CUSTOMER_ID)
        """)) <= 3


def test_default_customer_exists_and_has_an_action_to_show(live_session, appns):
    cid = appns["DEFAULT_CUSTOMER"]
    assert int(scalar(live_session,
                      f"SELECT COUNT(*) FROM GOLD.CUSTOMER_360 WHERE CUSTOMER_ID = {cid}")) == 1
    assert int(scalar(live_session,
                      f"SELECT COUNT(*) FROM APP.V_WORKLIST WHERE CUSTOMER_ID = {cid}")) >= 1, (
        f"DEFAULT_CUSTOMER {cid} has no published action: Customer 360 opens on an empty panel")


@pytest.mark.parametrize("sql, tone_map", [
    ("SELECT DISTINCT DPD_BUCKET V FROM GOLD.CUSTOMER_360", "DPD_TONE"),
    ("SELECT DISTINCT SENTIMENT_TREND V FROM GOLD.CUSTOMER_360", "TREND_TONE"),
    ("SELECT DISTINCT SENTIMENT_NOW V FROM GOLD.CUSTOMER_360", "SENT_TONE"),
    ("SELECT DISTINCT RELATIONSHIP_VALUE_BAND V FROM GOLD.CUSTOMER_360", "BAND_TONE"),
    ("SELECT DISTINCT CATEGORY V FROM APP.V_WORKLIST", "CAT_TONE"),
    ("SELECT DISTINCT EVENT_TYPE V FROM APP.V_TIMELINE_DETAIL", "TL_TONE"),
], ids=["dpd", "trend", "sentiment", "value-band", "category", "event-type"])
def test_every_value_in_the_data_has_a_severity_encoding(live_session, appns, sql, tone_map):
    """An unmapped value does not crash -- it renders in the neutral tone, which
    for a state like a DPD bucket is a wrong answer that looks like a right one."""
    seen = {r["V"] for r in rows(live_session, sql) if r["V"] is not None}
    unmapped = seen - set(appns[tone_map])
    assert not unmapped, f"values with no entry in {tone_map}: {sorted(unmapped)}"


def test_channels_are_the_three_the_impact_screen_prices(live_session):
    seen = {r["CHANNEL"] for r in rows(live_session, "SELECT DISTINCT CHANNEL FROM APP.V_IMPACT_BASE")}
    assert seen <= {"CALL", "EMAIL", "SMS"}, (
        f"channel(s) {seen - {'CALL', 'EMAIL', 'SMS'}} have no cost input: priced at zero")


# =============================================================================
# RECONCILIATION -- one figure, shown in two places, must be one figure
# =============================================================================

@pytest.fixture(scope="module")
def kpi(live_session):
    return one(live_session, "SELECT * FROM APP.V_PORTFOLIO_KPI")


def test_published_count_agrees_across_kpi_worklist_engine_and_impact(live_session, kpi):
    got = one(live_session, """
        SELECT (SELECT COUNT(*) FROM GOLD.NEXT_BEST_ACTION)                       AS ENGINE,
               (SELECT COUNT(*) FROM APP.V_WORKLIST)                              AS WORKLIST,
               (SELECT SUM(CONTACTS) FROM APP.V_IMPACT_BASE WHERE ARM='PUBLISHED') AS IMPACT""")
    assert {int(v) for v in got.values()} == {int(kpi["ACTIONS_PUBLISHED"])}, got


def test_expected_value_tile_is_the_sum_of_the_worklist(live_session, kpi):
    total = float(scalar(live_session, "SELECT SUM(EXPECTED_VALUE_INR) FROM APP.V_WORKLIST"))
    assert float(kpi["TOTAL_EXPECTED_VALUE_INR"]) == pytest.approx(total, rel=1e-9)


def test_suppressed_count_agrees_across_kpi_summary_customer_panel_and_impact(live_session, kpi):
    got = one(live_session, """
        SELECT (SELECT SUM(ACTIONS_SUPPRESSED) FROM APP.V_SUPPRESSION_SUMMARY)     AS SUMMARY,
               (SELECT COUNT(*) FROM APP.V_CUSTOMER_SUPPRESSED)                    AS PANEL,
               (SELECT SUM(CONTACTS) FROM APP.V_IMPACT_BASE WHERE ARM='SUPPRESSED') AS IMPACT""")
    assert {int(v) for v in got.values()} == {int(kpi["ACTIONS_SUPPRESSED"])}, got


def test_suppression_summary_agrees_with_the_kpi_row(live_session, kpi):
    s = rows(live_session, """SELECT SUPPRESSION_REASON, ACTIONS_SUPPRESSED, GROSS_MARGIN_INR,
                                     VIA_CALL + VIA_EMAIL + VIA_SMS AS VIA
                              FROM APP.V_SUPPRESSION_SUMMARY ORDER BY ACTIONS_SUPPRESSED DESC""")
    assert len(s) == int(kpi["SUPPRESSION_RULES_FIRED"])
    assert s[0]["ACTIONS_SUPPRESSED"] == kpi["TOP_SUPPRESSION_COUNT"]
    assert kpi["TOP_SUPPRESSION_REASON"] in {r["SUPPRESSION_REASON"] for r in s
                                             if r["ACTIONS_SUPPRESSED"] == s[0]["ACTIONS_SUPPRESSED"]}
    assert float(kpi["SUPPRESSED_GROSS_MARGIN_INR"]) == pytest.approx(
        sum(float(r["GROSS_MARGIN_INR"] or 0) for r in s), rel=1e-9)
    off = [r["SUPPRESSION_REASON"] for r in s if int(r["VIA"]) != int(r["ACTIONS_SUPPRESSED"])]
    assert not off, f"per-channel counts do not add up to the rule total for {off}"


def test_customer_and_decision_counts_agree_with_their_tables(live_session, kpi):
    got = one(live_session, """
        SELECT (SELECT COUNT(*) FROM GOLD.CUSTOMER_360)                 AS CUSTOMERS,
               (SELECT COUNT(DISTINCT CUSTOMER_ID) FROM APP.V_WORKLIST) AS WITH_ACTION,
               (SELECT COUNT(*) FROM APP.ACTION_FEEDBACK)               AS DECISIONS""")
    assert int(got["CUSTOMERS"]) == int(kpi["CUSTOMERS_TOTAL"])
    assert int(got["WITH_ACTION"]) == int(kpi["CUSTOMERS_WITH_ACTION"])
    assert int(got["DECISIONS"]) == int(kpi["DECISIONS_RECORDED"])


def test_every_suppressed_row_names_the_rule_that_blocked_it(live_session):
    assert int(scalar(live_session, """
        SELECT COUNT(*) FROM APP.V_CUSTOMER_SUPPRESSED
        WHERE ARRAY_SIZE(BLOCKING_RULES) = 0 OR SUPPRESSION_REASON IS NULL""")) == 0


def test_every_interaction_on_the_timeline_opens_to_a_transcript(live_session):
    assert int(scalar(live_session, """
        SELECT COUNT(*) FROM APP.V_TIMELINE_DETAIL
        WHERE EVENT_TYPE = 'INTERACTION' AND INTERACTION_BODY IS NULL""")) == 0


def test_figures_typed_into_the_apps_prose_are_still_true(live_session, kpi):
    """The app says '5,000 customers', 'all 16,475 needs' and '123 actions' in
    plain text. They were true when written; this is what notices if a rebuild
    changes them and the prose is not updated."""
    src = APP.read_text(encoding="utf-8")
    arms = {r["ARM"]: int(r["N"]) for r in rows(
        live_session, "SELECT ARM, SUM(CONTACTS) N FROM APP.V_IMPACT_BASE GROUP BY 1")}
    for literal, actual, what in [
        ("5,000 customers", int(kpi["CUSTOMERS_TOTAL"]), "customers in the book"),
        ("16,475", sum(arms.values()), "need-eligible baseline (all three arms)"),
        ("123 actions", arms.get("ELIGIBLE_NOT_PUBLISHED", 0), "held back by the top-3 cap"),
    ]:
        assert literal in src, f"'{literal}' is no longer in the app; update this test"
        typed = int(re.sub(r"[^\d]", "", literal))
        assert typed == actual, f"app text says {literal} but {what} is now {actual:,}"


# -- guardrails, as an RM would see them ---------------------------------------------

def test_no_sales_action_is_published_for_a_vulnerable_customer(live_session):
    bad = rows(live_session, """SELECT CUSTOMER_ID, ACTION_CODE FROM APP.V_WORKLIST
                                WHERE VULNERABILITY_FLAG AND IS_SALES_ACTION LIMIT 5""")
    assert not bad, f"sales action shown for vulnerable customer(s): {bad}"


def test_no_cross_sell_is_published_for_a_customer_in_arrears(live_session):
    bad = rows(live_session, f"""SELECT CUSTOMER_ID, ACTION_CODE, DPD_BUCKET FROM APP.V_WORKLIST
                                 WHERE CATEGORY = 'CROSS_SELL'
                                   AND DPD_BUCKET NOT IN {PAST_DUE} LIMIT 5""")
    assert not bad, f"cross-sell shown for customer(s) past due: {bad}"


def test_care_actions_rank_ahead_of_everything_else_for_every_customer(live_session):
    """The care boundary as the app itself draws it: PRIORITY_TIER <= 20 gets the
    care card, and the cockpit says a care action outranks any sales action."""
    bad = rows(live_session, """
        SELECT DISTINCT a.CUSTOMER_ID FROM APP.V_WORKLIST a JOIN APP.V_WORKLIST b
          ON a.CUSTOMER_ID = b.CUSTOMER_ID
        WHERE a.PRIORITY_TIER > 20 AND b.PRIORITY_TIER <= 20
          AND a.ACTION_RANK < b.ACTION_RANK LIMIT 5""")
    assert not bad, f"a non-care action is ranked above a care action for: {bad}"


# =============================================================================
# DEPLOYMENT
# =============================================================================

@pytest.fixture(scope="module")
def streamlit_object(live_session):
    found = rows(live_session, "SHOW STREAMLITS LIKE 'C360_APP' IN SCHEMA C360_NBA.APP")
    assert len(found) == 1, "APP.C360_APP does not exist -- run sql/20_streamlit.sql"
    return found[0]


def test_streamlit_object_is_deployed_with_a_live_version(live_session, streamlit_object):
    d = one(live_session, "DESCRIBE STREAMLIT C360_NBA.APP.C360_APP")
    assert d["MAIN_FILE"] == "streamlit_app.py"
    assert d.get("LIVE_VERSION_LOCATION_URI"), (
        "no live version: run ALTER STREAMLIT APP.C360_APP ADD LIVE VERSION FROM LAST")
    assert streamlit_object["QUERY_WAREHOUSE"] == "COCO_WH"


def test_stage_holds_the_app_its_environment_and_its_theme(live_session):
    names = [r["NAME"] for r in rows(live_session, "LS @C360_NBA.APP.APP_STAGE")]
    for needed in ("streamlit_app.py", "environment.yml", ".streamlit/config.toml"):
        assert any(n.endswith(needed) for n in names), (
            f"{needed} is not on APP.APP_STAGE -- see the stage-copy steps in run.sh")


@pytest.mark.parametrize("rel", ["streamlit_app.py", "environment.yml", ".streamlit/config.toml"])
def test_staged_copy_is_identical_to_the_file_in_this_checkout(live_session, rel):
    """If this fails the app on the stage is not the app these tests ran:
    re-copy app/ to the stage and re-run sql/20_streamlit.sql."""
    try:
        staged = live_session.file.get_stream(f"@C360_NBA.APP.APP_STAGE/{rel}").read()
    except Exception as e:  # noqa: BLE001 - reading a stage file is best-effort
        pytest.skip(f"could not read the staged file to compare ({type(e).__name__}: {e})")
    local = (ROOT / "app" / rel).read_bytes()
    assert staged.replace(b"\r\n", b"\n") == local.replace(b"\r\n", b"\n"), (
        f"app/{rel} differs from the staged copy")


def test_app_owner_role_holds_read_session(live_session, streamlit_object):
    """The INSERT stamps DECIDED_BY with CURRENT_USER(), and DECIDED_BY is NOT NULL.
    Snowflake's Streamlit docs require READ SESSION on the app owner role for any
    context function. Locally (tools/preview.py, these tests) the session is your
    own and it works regardless -- which is exactly why this needs its own check."""
    owner = streamlit_object["OWNER"]
    try:
        grants = rows(live_session, f"SHOW GRANTS TO ROLE {owner}")
    except Exception as e:  # noqa: BLE001
        pytest.skip(f"cannot list grants of {owner} from this role ({e})")
    held = any(g["PRIVILEGE"] == "READ SESSION" and g["GRANTED_ON"] == "ACCOUNT" for g in grants)
    assert held, (
        f"{owner} does not hold READ SESSION. Run once as ACCOUNTADMIN:\n"
        f"    GRANT READ SESSION ON ACCOUNT TO ROLE {owner};\n"
        "then click Accept once in the deployed app to confirm the write-back works there.")


def test_agent_exists_for_the_ask_screen(live_session):
    assert len(rows(live_session, "SHOW AGENTS LIKE 'RM_COPILOT' IN SCHEMA C360_NBA.APP")) == 1

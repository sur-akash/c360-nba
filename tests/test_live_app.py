"""
test_live_app.py -- the real app file, on the real data.

    pytest --live                     # screens 1, 2, 4 + idle Ask: no AI credits
    pytest --live --with-agent        # also asks APP.RM_COPILOT one question

The offline suite proves the app handles the shapes in the fixture book. This
proves it handles the shapes that are actually in the warehouse: 5,000 customers
with real NULL patterns, long transcripts, and whatever the last rebuild left.
Supersedes tools/verify_app.py, which stops at "did it raise".
"""

import re

import pytest

from conftest import _bind, assert_clean, expander, goto, launch, one, page, rows, scalar
from contract import SCREENS

pytestmark = pytest.mark.live
TIMEOUT = 300

# One customer per state the Customer 360 screen has a branch for.
PROFILES = {
    "default": None,                                   # filled from the app constant
    "no-action-all-suppressed": """
        SELECT s.CUSTOMER_ID FROM APP.V_CUSTOMER_SUPPRESSED s
        WHERE NOT EXISTS (SELECT 1 FROM APP.V_WORKLIST w WHERE w.CUSTOMER_ID = s.CUSTOMER_ID)
        ORDER BY 1 LIMIT 1""",
    "nothing-suppressed": """
        SELECT w.CUSTOMER_ID FROM APP.V_WORKLIST w
        WHERE NOT EXISTS (SELECT 1 FROM APP.V_CUSTOMER_SUPPRESSED s WHERE s.CUSTOMER_ID = w.CUSTOMER_ID)
        ORDER BY 1 LIMIT 1""",
    "vulnerable": "SELECT CUSTOMER_ID FROM GOLD.CUSTOMER_360 WHERE VULNERABILITY_FLAG ORDER BY 1 LIMIT 1",
    "past-due": """SELECT CUSTOMER_ID FROM GOLD.CUSTOMER_360
                   WHERE DPD_BUCKET NOT IN ('CURRENT','NO_CREDIT_OBLIGATION') ORDER BY 1 LIMIT 1""",
    "never-contacted": "SELECT CUSTOMER_ID FROM GOLD.CUSTOMER_360 WHERE LAST_CONTACT_DAYS IS NULL ORDER BY 1 LIMIT 1",
    "no-holdings": "SELECT CUSTOMER_ID FROM GOLD.CUSTOMER_360 WHERE PRODUCT_COUNT = 0 ORDER BY 1 LIMIT 1",
    "audio-transcript": "SELECT CUSTOMER_ID FROM APP.V_TIMELINE_DETAIL WHERE FROM_AUDIO ORDER BY 1 LIMIT 1",
    "busiest-timeline": """SELECT CUSTOMER_ID FROM APP.V_TIMELINE_DETAIL
                           GROUP BY 1 ORDER BY COUNT(*) DESC, 1 LIMIT 1""",
    "waived-rule": """SELECT CUSTOMER_ID FROM APP.V_CUSTOMER_SUPPRESSED
                      WHERE ARRAY_SIZE(EXEMPT_RULES) > 0 ORDER BY 1 LIMIT 1""",
    "unresolved-citation": "SELECT CUSTOMER_ID FROM APP.V_NBA_EVIDENCE_RESOLVED WHERE NOT RESOLVED ORDER BY 1 LIMIT 1",
}


@pytest.fixture
def live_app(live):
    return launch(timeout=TIMEOUT)


# -- every screen ----------------------------------------------------------------

@pytest.mark.parametrize("screen", SCREENS)
def test_screen_renders_on_live_data(live_app, screen):
    if screen != SCREENS[0]:
        goto(live_app, screen)
    assert len(live_app.markdown) > 5


def test_cockpit_tiles_show_the_kpi_views_numbers(live_app, live, appns):
    k = one(live, "SELECT * FROM APP.V_PORTFOLIO_KPI")
    html, num, inr = page(live_app), appns["num"], appns["inr"]
    assert f"Book of <b>{num(k['CUSTOMERS_TOTAL'])}</b> customers" in html
    assert f'<div class="kpi-v">{inr(k["TOTAL_EXPECTED_VALUE_INR"], True)}</div>' in html
    assert f'<div class="kpi-v">{num(k["ACTIONS_SUPPRESSED"])}</div>' in html
    assert f'<div class="kpi-v">{num(k["RENEWALS_AT_RISK_30D"])}</div>' in html
    assert f'<div class="kpi-v sm">{inr(k["ARREARS_EXPOSURE_INR"], True)}</div>' in html
    side = "\n".join(m.value for m in live_app.sidebar.markdown)
    assert f"<b>{num(k['ACTIONS_PUBLISHED'])}</b> actions published" in side
    assert f"<b>{num(k['DECISIONS_RECORDED'])}</b> RM decisions recorded" in side


def test_cockpit_worklist_shows_fifty_rows_care_first(live_app, live):
    labels = [e.label for e in live_app.expander if e.label.startswith("Reasoning · ")]
    assert len(labels) == min(50, int(scalar(live, "SELECT COUNT(*) FROM APP.V_WORKLIST")))
    tiers = [int(t) for t in re.findall(r"· tier (\d+)</span>", page(live_app))]
    assert tiers == sorted(tiers), "worklist is not ordered by priority tier first"


def test_cockpit_filters_run_on_live_data(live_app, live):
    cat = scalar(live, "SELECT CATEGORY FROM APP.V_WORKLIST GROUP BY 1 ORDER BY COUNT(*) LIMIT 1")
    n = int(scalar(live, f"SELECT COUNT(*) FROM APP.V_WORKLIST WHERE CATEGORY = '{cat}'"))
    box = next(m for m in live_app.multiselect if m.label == "Category")
    box.set_value([cat]).run()
    assert_clean(live_app)
    shown = [e for e in live_app.expander if e.label.startswith("Reasoning · ")]
    assert len(shown) == min(50, n)


# -- Customer 360 across the states that exist in the data ---------------------------

@pytest.mark.parametrize("profile", sorted(PROFILES))
def test_customer_360_renders_for(live, appns, profile):
    sql = PROFILES[profile]
    if sql is None:
        cid = appns["DEFAULT_CUSTOMER"]
    else:
        found = rows(live, sql)
        if not found:
            pytest.skip(f"no customer in the data matches profile '{profile}'")
        cid = int(found[0]["CUSTOMER_ID"])

    at = goto(launch(timeout=TIMEOUT), "Customer 360")
    at.selectbox(key="cust_sel").set_value(cid).run()
    assert_clean(at, f"Customer 360 for #{cid} ({profile})")

    published = int(scalar(live, f"SELECT COUNT(*) FROM APP.V_WORKLIST WHERE CUSTOMER_ID = {cid}"))
    blocked = int(scalar(live, f"SELECT COUNT(*) FROM APP.V_CUSTOMER_SUPPRESSED WHERE CUSTOMER_ID = {cid}"))
    assert len([b for b in at.button if (b.key or "").startswith("acc_")]) == published
    assert len([b for b in at.button if (b.key or "").startswith("rej_")]) == published
    assert ("No action recommended" in page(at)) == (published == 0)
    if blocked:
        assert expander(at, f"Show {blocked} suppressed actions").proto.expanded is True
    else:
        assert "Nothing suppressed." in page(at)
    assert f"Customer <b>#{cid}</b>" in page(at)


def test_cockpit_deep_link_opens_the_right_customer(live_app):
    link = next(b for b in live_app.button if (b.key or "").startswith("goto_"))
    cid = int(link.key.split("_")[1])
    link.click().run()
    assert_clean(live_app)
    assert live_app.session_state["nav"] == "Customer 360"
    assert live_app.selectbox(key="cust_sel").value == cid


# -- Impact ------------------------------------------------------------------------------

def test_impact_baseline_is_the_three_arms_from_the_view(live_app, live, appns):
    goto(live_app, "Impact")
    arms = {r["ARM"]: int(r["N"]) for r in rows(
        live, "SELECT ARM, SUM(CONTACTS) N FROM APP.V_IMPACT_BASE GROUP BY 1")}
    html, num = page(live_app), appns["num"]
    assert f'<td class="n tot">{num(sum(arms.values()))}</td>' in html
    assert f"<b>{num(arms['PUBLISHED'])}</b> contacts" in html
    assert f"<b>{num(arms.get('SUPPRESSED', 0))}</b> solicitations never made" in html


def test_impact_inputs_recalculate_without_error(live_app):
    goto(live_app, "Impact")
    next(s for s in live_app.slider if s.label == "Acceptance rate").set_value(20.0).run()
    assert_clean(live_app)
    next(n for n in live_app.number_input if n.label.startswith("Penalty")).set_value(5000.0).run()
    assert_clean(live_app)
    assert any(c.value.startswith("At 20.0% acceptance") for c in live_app.caption)


# -- Ask -------------------------------------------------------------------------------------

def test_idle_ask_screen_offers_suggestions(live_app):
    goto(live_app, "Ask")
    assert len([b for b in live_app.button if (b.key or "").startswith("sug_")]) == 4
    assert len(live_app.chat_input) == 1 and len(live_app.chat_message) == 0


QUESTION = "How many actions did compliance block, and which rule blocked the most?"


@pytest.fixture(scope="module")
def answered(live_session):
    """One real agent call, shared by the tests below. ~0.12 credits of
    orchestration plus 0.067 if it routes to Cortex Analyst."""
    with pytest.MonkeyPatch.context() as mp:
        _bind(mp, live_session)
        at = goto(launch(timeout=TIMEOUT), "Ask")
        at.chat_input[0].set_value(QUESTION).run()
        assert_clean(at, "asking the live agent")
        yield at


@pytest.mark.agent
def test_live_agent_answers(answered):
    reply = answered.chat_message[1].markdown[0].value
    assert not reply.startswith("The agent call failed"), reply
    assert reply != "_No text returned._" and len(reply) > 40


@pytest.mark.agent
def test_live_agent_trace_parses_and_shows_its_tools(answered):
    e = expander(answered, "Reasoning")
    assert re.match(r"Reasoning · [1-9]\d* tool call", e.label), e.label
    assert not any("could not be read" in c.value for c in e.caption)
    assert any(c.value.startswith("Orchestrated by") for c in e.caption)


@pytest.mark.agent
def test_live_agent_sql_goes_through_the_semantic_view(answered):
    """The governance invariant from the Analyst evals: a right number reached by
    bypassing the semantic view is still a failure."""
    sql = [c.value for c in expander(answered, "Reasoning").code if c.language == "sql"]
    if not sql:
        pytest.skip("the agent generated no SQL for this question")
    assert all("SEMANTIC_VIEW(" in s.upper() for s in sql), sql

"""
test_live_action_flow.py -- Accept / Reject against the real APP.ACTION_FEEDBACK.

    pytest --live-write

THIS WRITES. Each test clicks real buttons in the app, which INSERTs into
APP.ACTION_FEEDBACK, then deletes exactly the rows it added (matched by
FEEDBACK_ID, customer and CURRENT_USER). Zero AI credits.

Do not run it while someone is recording decisions in the deployed app with the
same Snowflake user: a decision made on the test customer during the run would be
indistinguishable from a test row and would be deleted with them.

What this adds over the offline suite is the part the fake cannot stand in for:
Snowflake parsing the literal lit() built, the NOT NULL and CHECK constraints,
CURRENT_USER()/CURRENT_TIMESTAMP() resolving, and the QUALIFY read-back.
"""

import pytest
import streamlit as st

from conftest import (assert_clean, button, click_through_disabled, goto, launch, page,
                      rows, scalar)

pytestmark = [pytest.mark.live, pytest.mark.live_write]
TIMEOUT = 300
HOSTILE_NOTE = "[pytest] it's a 'test' \\ \"quoted\"; DROP TABLE x; -- ₹45 कॉल\nsecond line"


@pytest.fixture(scope="module")
def baseline(live_session):
    return int(scalar(live_session, "SELECT COUNT(*) FROM APP.ACTION_FEEDBACK"))


@pytest.fixture(scope="module")
def target(live_session, appns):
    """A customer with at least two cards, the demo customer if she qualifies."""
    cid = int(scalar(live_session, f"""
        SELECT CUSTOMER_ID FROM APP.V_WORKLIST GROUP BY 1 HAVING COUNT(*) >= 2
        ORDER BY IFF(CUSTOMER_ID = {int(appns['DEFAULT_CUSTOMER'])}, 0, 1), CUSTOMER_ID LIMIT 1"""))
    cards = rows(live_session, f"""
        SELECT ACTION_CODE, ACTION_RANK, EXPECTED_VALUE_INR FROM APP.V_WORKLIST
        WHERE CUSTOMER_ID = {cid} ORDER BY ACTION_RANK""")
    return cid, cards


@pytest.fixture
def ledger(live, baseline, target):
    """Tracks the rows this test adds and removes them afterwards."""
    cid, _ = target
    me = scalar(live, "SELECT CURRENT_USER()")
    before = {r["FEEDBACK_ID"] for r in rows(live, "SELECT FEEDBACK_ID FROM APP.ACTION_FEEDBACK")}

    def added():
        return [r for r in rows(live, f"""
                    SELECT * FROM APP.ACTION_FEEDBACK
                    WHERE CUSTOMER_ID = {cid} AND DECIDED_BY = CURRENT_USER()
                    ORDER BY DECIDED_AT, FEEDBACK_ID""")
                if r["FEEDBACK_ID"] not in before]

    added.me = me
    try:
        yield added
    finally:
        ids = [str(int(r["FEEDBACK_ID"])) for r in added()]
        if ids:
            live.sql(f"DELETE FROM APP.ACTION_FEEDBACK WHERE FEEDBACK_ID IN ({', '.join(ids)})").collect()
        st.cache_data.clear()
        left = int(scalar(live, "SELECT COUNT(*) FROM APP.ACTION_FEEDBACK"))
        assert left == len(before), (
            f"cleanup left {left} rows in APP.ACTION_FEEDBACK, expected {len(before)}")


@pytest.fixture
def screen(live, target):
    cid, _ = target
    at = goto(launch(timeout=TIMEOUT), "Customer 360")
    at.selectbox(key="cust_sel").set_value(cid).run()
    assert_clean(at, f"opening customer {cid}")
    return at


def make_acceptable(screen, cid, code):
    """Accept is disabled on a card whose latest decision is already ACCEPTED
    (say, from a rehearsal). Record a rejection first so it can be accepted; the
    ledger tracks that row and removes it with the rest."""
    if screen.button(key=f"acc_{cid}_{code}").disabled:
        screen.button(key=f"rej_{cid}_{code}").click().run()
        button(screen, "Record rejection").click().run()
        assert_clean(screen, "clearing an earlier acceptance")
        assert not screen.button(key=f"acc_{cid}_{code}").disabled


def test_accept_writes_the_published_recommendation_stamped_by_the_server(screen, ledger, live, target):
    cid, cards = target
    card = cards[0]
    make_acceptable(screen, cid, card["ACTION_CODE"])
    already = len(ledger())
    recorded = int(scalar(live, "SELECT DECISIONS_RECORDED FROM APP.V_PORTFOLIO_KPI"))

    screen.button(key=f"acc_{cid}_{card['ACTION_CODE']}").click().run()
    assert_clean(screen, "accepting on the live table")

    assert len(ledger()) == already + 1
    row = ledger()[-1]
    assert row["ACTION_CODE"] == card["ACTION_CODE"]
    assert int(row["ACTION_RANK"]) == int(card["ACTION_RANK"])
    assert row["DECISION"] == "ACCEPTED"
    assert row["REJECT_REASON"] is None and row["NOTE"] is None
    assert float(row["EXPECTED_VALUE_INR"]) == pytest.approx(float(card["EXPECTED_VALUE_INR"]))
    assert row["DECIDED_BY"] == ledger.me
    age = int(scalar(live, f"""SELECT DATEDIFF('second', DECIDED_AT, CURRENT_TIMESTAMP())
                               FROM APP.ACTION_FEEDBACK WHERE FEEDBACK_ID = {int(row['FEEDBACK_ID'])}"""))
    assert 0 <= age < 600, f"DECIDED_AT is {age}s from the server clock"

    # The screen reflects it at once (cache cleared) and so does the KPI view.
    assert ">Accepted</span>" in page(screen) and f"by {ledger.me} on" in page(screen)
    assert int(scalar(live, "SELECT DECISIONS_RECORDED FROM APP.V_PORTFOLIO_KPI")) == recorded + 1
    side = "\n".join(m.value for m in screen.sidebar.markdown)
    assert f"<b>{recorded + 1}</b> RM decisions recorded" in side.replace(",", "")


def test_an_accepted_card_cannot_be_accepted_twice(screen, ledger, target):
    cid, cards = target
    code = cards[0]["ACTION_CODE"]
    make_acceptable(screen, cid, code)
    screen.button(key=f"acc_{cid}_{code}").click().run()
    assert_clean(screen)
    written = len(ledger())

    assert screen.button(key=f"acc_{cid}_{code}").disabled
    assert not screen.button(key=f"rej_{cid}_{code}").disabled
    click_through_disabled(screen, f"acc_{cid}_{code}")
    assert len(ledger()) == written, "a repeated Accept wrote a duplicate row"


def test_reject_stores_reason_and_free_text_exactly_as_typed(screen, ledger, target):
    cid, cards = target
    code = cards[0]["ACTION_CODE"]
    screen.button(key=f"rej_{cid}_{code}").click().run()
    assert_clean(screen)
    assert ledger() == [], "opening the reject form must not write"

    screen.selectbox(key=f"rr_{cid}_{code}").set_value("DATA_LOOKS_WRONG")
    screen.text_area(key=f"rn_{cid}_{code}").set_value(HOSTILE_NOTE)
    button(screen, "Record rejection").click().run()
    assert_clean(screen, "recording a rejection on the live table")

    assert len(ledger()) == 1
    row = ledger()[-1]
    assert row["DECISION"] == "REJECTED" and row["REJECT_REASON"] == "DATA_LOOKS_WRONG"
    assert row["NOTE"] == HOSTILE_NOTE
    assert row["DECIDED_BY"] == ledger.me
    assert "Rejected · Data looks wrong" in page(screen)
    assert "Reject with reason" not in page(screen)         # the form closed


def test_change_of_mind_keeps_both_rows_and_the_card_shows_the_latest(screen, ledger, live, target):
    cid, cards = target
    code = cards[1]["ACTION_CODE"]
    screen.button(key=f"rej_{cid}_{code}").click().run()
    button(screen, "Record rejection").click().run()
    assert_clean(screen)
    screen.button(key=f"acc_{cid}_{code}").click().run()
    assert_clean(screen)

    assert [r["DECISION"] for r in ledger()] == ["REJECTED", "ACCEPTED"]
    assert screen.button(key=f"acc_{cid}_{code}").disabled
    # What the cards should now show, derived from the table rather than assumed:
    # other cards may carry decisions from before this test.
    latest = rows(live, f"""
        SELECT ACTION_CODE, DECISION FROM APP.ACTION_FEEDBACK WHERE CUSTOMER_ID = {cid}
        QUALIFY ROW_NUMBER() OVER (PARTITION BY ACTION_CODE ORDER BY DECIDED_AT DESC) = 1""")
    shown = {c["ACTION_CODE"] for c in cards}
    want = [r["DECISION"] for r in latest if r["ACTION_CODE"] in shown]
    assert dict((r["ACTION_CODE"], r["DECISION"]) for r in latest)[code] == "ACCEPTED"
    assert page(screen).count(">Accepted</span>") == want.count("ACCEPTED")
    assert page(screen).count('c-risk">Rejected') == want.count("REJECTED")


def test_recorded_decisions_reach_the_impact_screen(screen, ledger, target):
    cid, cards = target
    make_acceptable(screen, cid, cards[0]["ACTION_CODE"])
    screen.button(key=f"acc_{cid}_{cards[0]['ACTION_CODE']}").click().run()
    assert_clean(screen)
    goto(screen, "Impact")
    assert "Recorded so far" in page(screen)
    assert "decisions recorded by RMs" in page(screen)


def test_the_table_is_left_exactly_as_it_was_found(live_session, baseline):
    assert int(scalar(live_session, "SELECT COUNT(*) FROM APP.ACTION_FEEDBACK")) == baseline

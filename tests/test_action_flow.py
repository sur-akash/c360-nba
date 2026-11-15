"""
test_action_flow.py -- the Accept / Reject write-back on Customer 360.

This is the only place the app changes state, so it gets the closest reading.
Every recommendation card carries two buttons; a decision is appended to
APP.ACTION_FEEDBACK, the read cache is cleared, and the card re-renders with the
decision it now carries. The table is an append-only log (sql/19 PART 2): a
change of mind leaves both rows and the card shows the latest.

Offline: runs against tests/fake_snowflake.py, which parses the INSERT with
Snowflake's literal rules and enforces the table's NOT NULL and CHECK
constraints. The same flow is repeated against the real table in
tests/test_live_action_flow.py (--live-write).
"""

import re

import pytest

from conftest import assert_clean, button, expander, goto, launch, page
from contract import REJECT_REASONS
from fake_snowflake import (BLOCKED_CUSTOMER, CLEAN_CUSTOMER, DEFAULT_CUSTOMER,
                            VULNERABLE_CUSTOMER, SQLError)

CID = DEFAULT_CUSTOMER
FIRST = "HARDSHIP_REVIEW"          # rank 1 for the default customer
SECOND = "RENEWAL_SAVE"            # rank 2


def accept(at, code=FIRST, cid=CID):
    at.button(key=f"acc_{cid}_{code}").click().run()
    assert_clean(at, f"accepting {code}")
    return at


def open_reject(at, code=FIRST, cid=CID):
    at.button(key=f"rej_{cid}_{code}").click().run()
    assert_clean(at, f"opening reject form for {code}")
    return at


def reject(at, code=FIRST, reason="WRONG_TIMING", note="", cid=CID):
    open_reject(at, code, cid)
    at.selectbox(key=f"rr_{cid}_{code}").set_value(reason)
    if note:
        at.text_area(key=f"rn_{cid}_{code}").set_value(note)
    button(at, "Record rejection").click().run()
    assert_clean(at, f"rejecting {code}")
    return at


def pick_customer(at, cid):
    at.selectbox(key="cust_sel").set_value(cid).run()
    assert_clean(at, f"selecting customer {cid}")
    return at


def form_open(at, code=FIRST, cid=CID):
    return any(s.key == f"rr_{cid}_{code}" for s in at.selectbox)


def decision_chips(at):
    """[(decision text, tone)] for every recorded-decision chip on the page."""
    return re.findall(
        r'<span class="chip c-(ok|risk)">((?:Accepted|Rejected)[^<]*)</span>'
        r'<span style="font-size:.7rem', page(at))


# =============================================================================
# The cards themselves
# =============================================================================

class TestActionCards:
    def test_one_accept_and_one_reject_per_published_action_in_rank_order(self, customer, fake):
        want = fake.book["worklist"].query("CUSTOMER_ID == @CID").sort_values("ACTION_RANK")
        acc = [b.key for b in customer.button if (b.key or "").startswith("acc_")]
        rej = [b.key for b in customer.button if (b.key or "").startswith("rej_")]
        assert acc == [f"acc_{CID}_{c}" for c in want.ACTION_CODE]
        assert rej == [f"rej_{CID}_{c}" for c in want.ACTION_CODE]

    def test_card_shows_value_propensity_rationale_and_disclosure(self, customer):
        html = page(customer)
        assert "Hardship review call" in html
        assert '<div class="card-ev">₹18,450</div>' in html          # Indian grouping
        assert "Expected value · 41.23% propensity" in html
        assert "Two missed EMIs and a call mentioning a job loss" in html
        assert "<b>Required disclosure</b>Restructuring may affect the credit bureau" in html
        assert ">Servicing obligation</span>" in html

    def test_card_without_disclosure_omits_the_disclosure_block(self, customer):
        card = page(customer).split("Complaint callback")[1].split("</div></div>")[0]
        assert "Required disclosure" not in card

    def test_care_tier_cards_are_styled_apart_from_sales_cards(self, customer):
        assert page(customer).count('<div class="card card-care">') == 3   # tiers 10, 20, 20
        pick_customer(customer, CLEAN_CUSTOMER)
        assert '<div class="card card-top">' in page(customer)             # tier 50
        assert '<div class="card card-care">' not in page(customer)

    def test_markup_in_a_rationale_is_rendered_as_text_not_html(self, customer):
        pick_customer(customer, CLEAN_CUSTOMER)
        html = page(customer)
        assert "&lt;script&gt;alert(1)&lt;/script&gt;" in html
        assert "<script>" not in html
        assert "&amp; no cover &lt;b&gt;gap&lt;/b&gt;" in html

    def test_no_decision_is_shown_before_one_is_recorded(self, customer, fake):
        assert decision_chips(customer) == []
        assert fake.inserts == []

    def test_loading_the_screen_writes_nothing(self, customer, fake):
        pick_customer(customer, VULNERABLE_CUSTOMER)
        pick_customer(customer, CID)
        assert fake.inserts == [] and fake.feedback == []

    def test_evidence_expander_counts_and_lists_the_cited_interactions(self, customer):
        labels = [e.label for e in customer.expander if e.label.startswith("Evidence")]
        assert labels == ["Evidence · 2 interactions cited", "Evidence · 0 interactions cited",
                          "Evidence · 1 interactions cited"]
        cited = "\n".join(m.value for m in expander(customer, "Evidence · 2").markdown)
        assert "Call: job loss, EMI relief" in cited and "Email: claim pending" in cited

    def test_rationale_with_no_citation_says_so(self, customer):
        caps = [c.value for c in expander(customer, "Evidence · 0").caption]
        assert any("cites no interaction" in c for c in caps)
        assert any("No model wrote this sentence" in c for c in caps)       # TEMPLATE source

    def test_model_written_rationale_is_labelled_as_model_written(self, customer):
        caps = [c.value for c in expander(customer, "Evidence · 2").caption]
        assert any("Rationale written by" in c and "never model-generated" in c for c in caps)

    def test_an_unresolved_citation_is_kept_visible_not_dropped(self, customer):
        pick_customer(customer, VULNERABLE_CUSTOMER)
        cited = "\n".join(m.value for m in expander(customer, "Evidence · 2").markdown)
        assert "Unresolved citation" in cited and "<code>INT-MISSING</code>" in cited
        assert "Call: confused about EMI" in cited

    def test_customer_with_no_published_action_has_no_buttons_and_says_why(self, customer):
        pick_customer(customer, BLOCKED_CUSTOMER)
        assert "No action recommended" in page(customer)
        assert not [b for b in customer.button if (b.key or "").startswith(("acc_", "rej_"))]
        assert "Suppressed by compliance" in page(customer)       # the panel still renders
        expander(customer, "Show 2 suppressed actions")


# =============================================================================
# Accept
# =============================================================================

class TestAccept:
    def test_accept_appends_exactly_one_row_carrying_the_card_it_was_clicked_on(self, customer, fake):
        accept(customer)
        assert len(fake.inserts) == 1
        (row,) = fake.feedback
        card = fake.book["worklist"].query("CUSTOMER_ID == @CID and ACTION_CODE == @FIRST").iloc[0]
        assert row["CUSTOMER_ID"] == CID
        assert row["ACTION_CODE"] == FIRST
        assert row["ACTION_RANK"] == card.ACTION_RANK == 1
        assert row["DECISION"] == "ACCEPTED"
        assert row["REJECT_REASON"] is None and row["NOTE"] is None
        assert row["EXPECTED_VALUE_INR"] == pytest.approx(card.EXPECTED_VALUE_INR)

    def test_expected_value_is_stored_to_the_paisa(self, customer, fake):
        accept(customer, SECOND)
        assert fake.feedback[0]["EXPECTED_VALUE_INR"] == 42300.5

    def test_actor_and_time_are_resolved_by_the_server_not_sent_by_the_app(self, customer, fake):
        accept(customer)
        sql = " ".join(fake.inserts[0].split())
        assert sql.endswith("CURRENT_USER(), CURRENT_TIMESTAMP()")
        assert "TEST_RM" not in sql                    # no client-supplied identity
        assert fake.feedback[0]["DECIDED_BY"] == "TEST_RM"

    def test_card_shows_the_decision_immediately(self, customer):
        """Fails if the read cache is not cleared after the write: the feedback
        query was cached as empty when the screen first rendered."""
        accept(customer)
        assert decision_chips(customer) == [("ok", "Accepted")]
        assert "by TEST_RM on 15 Nov 2026" in page(customer)

    def test_only_the_clicked_card_is_marked(self, customer, fake):
        accept(customer, SECOND)
        assert [f["ACTION_CODE"] for f in fake.feedback] == [SECOND]
        html = page(customer)
        marked = html.index(">Accepted</span>")
        assert html.index("Renewal save call") < marked < html.index("Complaint callback")

    def test_accept_does_not_open_the_reject_form(self, customer):
        accept(customer)
        assert not form_open(customer)

    def test_sidebar_counter_goes_up_with_each_decision(self, customer):
        def recorded():
            m = re.search(r"<b>(\d+)</b> RM decisions recorded",
                          "\n".join(x.value for x in customer.sidebar.markdown))
            return int(m.group(1))
        assert recorded() == 0
        accept(customer)
        assert recorded() == 1
        reject(customer, SECOND)
        assert recorded() == 2

    def test_accepting_every_card_records_each_once(self, customer, fake):
        for code in ("HARDSHIP_REVIEW", "RENEWAL_SAVE", "SERVICE_RECOVERY_CALLBACK"):
            accept(customer, code)
        assert [(f["ACTION_CODE"], f["ACTION_RANK"]) for f in fake.feedback] == [
            ("HARDSHIP_REVIEW", 1), ("RENEWAL_SAVE", 2), ("SERVICE_RECOVERY_CALLBACK", 3)]
        assert decision_chips(customer) == [("ok", "Accepted")] * 3


# =============================================================================
# Reject with reason
# =============================================================================

class TestReject:
    def test_reject_opens_a_form_and_writes_nothing_yet(self, customer, fake):
        open_reject(customer)
        assert form_open(customer)
        assert "Reject with reason" in page(customer)
        assert fake.inserts == []

    def test_only_the_clicked_cards_form_opens(self, customer):
        open_reject(customer, SECOND)
        assert form_open(customer, SECOND) and not form_open(customer, FIRST)

    def test_reason_list_matches_the_documented_list_and_is_humanised(self, customer):
        open_reject(customer)
        box = customer.selectbox(key=f"rr_{CID}_{FIRST}")
        assert box.options == ["Not relevant", "Already contacted", "Customer declined",
                               "Wrong timing", "Wrong channel", "Data looks wrong", "Other"]
        assert len(box.options) == len(REJECT_REASONS)
        assert box.value == REJECT_REASONS[0]          # stored as the code, shown as words

    def test_rejection_stores_reason_code_and_note(self, customer, fake):
        reject(customer, reason="CUSTOMER_DECLINED", note="Said she has cover elsewhere.")
        (row,) = fake.feedback
        assert (row["CUSTOMER_ID"], row["ACTION_CODE"], row["ACTION_RANK"]) == (CID, FIRST, 1)
        assert row["DECISION"] == "REJECTED"
        assert row["REJECT_REASON"] == "CUSTOMER_DECLINED"
        assert row["NOTE"] == "Said she has cover elsewhere."
        assert row["EXPECTED_VALUE_INR"] == 18450.0
        assert row["DECIDED_BY"] == "TEST_RM"

    @pytest.mark.parametrize("reason", REJECT_REASONS)
    def test_every_reason_can_be_recorded(self, customer, fake, reason):
        reject(customer, reason=reason)
        assert fake.feedback[0]["REJECT_REASON"] == reason

    def test_blank_note_is_stored_as_null_not_empty_string(self, customer, fake):
        reject(customer, note="")
        assert fake.feedback[0]["NOTE"] is None
        assert "NULL, NULL" not in " ".join(fake.inserts[0].split())   # reason is set
        assert re.search(r"'WRONG_TIMING', NULL,", " ".join(fake.inserts[0].split()))

    def test_form_closes_and_card_shows_reason_after_recording(self, customer):
        reject(customer, reason="WRONG_TIMING")
        assert not form_open(customer)
        assert decision_chips(customer) == [("risk", "Rejected · Wrong timing")]

    def test_cancel_closes_the_form_and_writes_nothing(self, customer, fake):
        open_reject(customer)
        customer.text_area(key=f"rn_{CID}_{FIRST}").set_value("changed my mind")
        button(customer, "Cancel").click().run()
        assert_clean(customer)
        assert not form_open(customer)
        assert fake.inserts == [] and decision_chips(customer) == []

    def test_two_forms_can_be_open_and_each_submits_its_own_card(self, customer, fake):
        open_reject(customer, FIRST)
        open_reject(customer, SECOND)
        assert form_open(customer, FIRST) and form_open(customer, SECOND)
        customer.selectbox(key=f"rr_{CID}_{SECOND}").set_value("WRONG_CHANNEL")
        [b for b in customer.button if b.label == "Record rejection"][1].click().run()
        assert_clean(customer)
        assert [(f["ACTION_CODE"], f["REJECT_REASON"]) for f in fake.feedback] == [
            (SECOND, "WRONG_CHANNEL")]
        assert form_open(customer, FIRST) and not form_open(customer, SECOND)

    @pytest.mark.parametrize("note", [
        "It's the customer's call",
        "'; DROP TABLE APP.ACTION_FEEDBACK; --",
        "x', 'REJECTED', NULL, NULL, 0, 'FORGED_USER', CURRENT_TIMESTAMP() --",
        'back\\slash and "double quotes"',
        "ends with a backslash\\",
        "two\nlines\tand a tab",
        "₹45 की कॉल — ग्राहक ने मना किया",
        "100% {braces} $dollar ''doubled''",
        "   padded   ",
    ], ids=["apostrophe", "drop-table", "forge-actor", "backslash", "trailing-backslash",
            "newline-tab", "unicode", "format-chars", "whitespace"])
    def test_note_text_round_trips_exactly_and_cannot_alter_the_statement(self, customer, fake, note):
        """The note is the one free-text value the app writes. Whatever is typed
        must arrive as one NOTE value in one row, with the actor still resolved
        by the server."""
        reject(customer, reason="OTHER", note=note)
        assert len(fake.feedback) == 1
        row = fake.feedback[0]
        assert row["NOTE"] == note
        assert row["DECISION"] == "REJECTED" and row["REJECT_REASON"] == "OTHER"
        assert row["DECIDED_BY"] == "TEST_RM"
        assert decision_chips(customer) == [("risk", "Rejected · Other")]


# =============================================================================
# History: the table is an append-only log and the card shows the latest row
# =============================================================================

class TestDecisionHistory:
    def test_change_of_mind_keeps_both_rows_and_shows_the_latest(self, customer, fake):
        reject(customer, reason="WRONG_TIMING")
        accept(customer)
        assert [f["DECISION"] for f in fake.feedback] == ["REJECTED", "ACCEPTED"]
        assert decision_chips(customer) == [("ok", "Accepted")]
        reject(customer, reason="NOT_RELEVANT")
        assert len(fake.feedback) == 3
        assert decision_chips(customer) == [("risk", "Rejected · Not relevant")]

    def test_decisions_from_an_earlier_session_are_shown_with_who_made_them(self, fake):
        fake.seed_feedback(CID, FIRST, "REJECTED", reason="WRONG_CHANNEL", by="PRIYA_V")
        fake.seed_feedback(CID, FIRST, "ACCEPTED", by="ROHIT_D")           # later row wins
        fake.seed_feedback(CID, SECOND, "REJECTED", reason="ALREADY_CONTACTED", by="PRIYA_V")
        at = goto(launch(), "Customer 360")
        assert decision_chips(at) == [("ok", "Accepted"),
                                      ("risk", "Rejected · Already contacted")]
        assert "by ROHIT_D on" in page(at) and "by PRIYA_V on" in page(at)

    def test_a_decision_belongs_to_one_customer(self, customer, fake):
        accept(customer)
        pick_customer(customer, VULNERABLE_CUSTOMER)
        assert decision_chips(customer) == []
        accept(customer, "VULNERABLE_CARE_CHECKIN", cid=VULNERABLE_CUSTOMER)
        assert [(f["CUSTOMER_ID"], f["ACTION_CODE"]) for f in fake.feedback] == [
            (CID, FIRST), (VULNERABLE_CUSTOMER, "VULNERABLE_CARE_CHECKIN")]
        pick_customer(customer, CID)
        assert decision_chips(customer) == [("ok", "Accepted")]

    def test_an_open_reject_form_does_not_follow_you_to_another_customer(self, customer):
        open_reject(customer)
        pick_customer(customer, VULNERABLE_CUSTOMER)
        assert "Reject with reason" not in page(customer)

    def test_decision_for_an_action_no_longer_published_does_not_break_the_screen(self, fake):
        fake.seed_feedback(CID, "RETIRED_ACTION_CODE", "ACCEPTED")
        at = goto(launch(), "Customer 360")
        assert decision_chips(at) == []


# =============================================================================
# Where decisions surface elsewhere
# =============================================================================

class TestDecisionsDownstream:
    def test_impact_screen_has_no_recorded_panel_before_any_decision(self, app):
        goto(app, "Impact")
        assert "Recorded so far" not in page(app)

    def test_impact_screen_reports_recorded_decisions(self, customer):
        accept(customer, SECOND)                       # ₹42,300.50
        reject(customer, FIRST)
        goto(customer, "Impact")
        html = page(customer)
        assert "Recorded so far" in html
        assert "2 decisions recorded by RMs, 1 accepted" in html
        assert "₹42,300 of expected value accepted" in html      # banker's rounding of .5
        assert "Observed acceptance 50.0%" in html

    def test_all_rejections_still_render_the_recorded_panel(self, customer):
        reject(customer, FIRST)
        goto(customer, "Impact")
        assert "1 decisions recorded by RMs, 0 accepted" in page(customer)
        assert "Observed acceptance 0.0%" in page(customer)


# =============================================================================
# Known gaps. Each test states the behaviour the app SHOULD have and is marked
# xfail(strict) because the app does not have it yet -- the suite stays green,
# the gap stays visible, and the marker has to come off the day it is fixed.
# =============================================================================

class TestKnownGaps:
    @pytest.mark.xfail(strict=True, reason=(
        "Accept on a card already accepted appends a second identical row, so "
        "'RM decisions recorded' and 'expected value accepted' count it twice."))
    def test_repeating_the_same_decision_does_not_write_a_duplicate(self, customer, fake):
        accept(customer)
        accept(customer)
        assert len(fake.feedback) == 1

    @pytest.mark.xfail(strict=True, reason=(
        "write_feedback() has no error handling: a failed INSERT surfaces as a "
        "raw traceback on the Customer 360 screen."))
    def test_a_failed_write_is_reported_without_a_stack_trace(self, customer, fake):
        fake.fail_matching[r"INSERT INTO APP\.ACTION_FEEDBACK"] = SQLError("warehouse suspended")
        customer.button(key=f"acc_{CID}_{FIRST}").click().run()
        assert not customer.exception
        assert customer.error and decision_chips(customer) == []

    @pytest.mark.xfail(strict=True, reason=(
        "DECIDED_BY is CURRENT_USER() and NOT NULL. Snowflake requires READ SESSION "
        "on the app owner role for context functions and no script grants it; if "
        "CURRENT_USER() comes back NULL the INSERT fails. See tests/README.md."))
    def test_missing_read_session_grant_does_not_crash_the_screen(self, monkeypatch):
        from conftest import _bind
        from fake_snowflake import FakeSession
        session = FakeSession(current_user=None)
        _bind(monkeypatch, session)
        at = goto(launch(), "Customer 360")
        at.button(key=f"acc_{CID}_{FIRST}").click().run()
        assert not at.exception

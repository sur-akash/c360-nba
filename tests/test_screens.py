"""
test_screens.py -- the cockpit, Customer 360, Ask and Impact screens, offline.

Each test drives the real app file through Streamlit's AppTest against the
fixture book in tests/fake_snowflake.py and reads back what was rendered. Where a
figure is asserted it is re-derived here from the fixture frames, not copied from
the app, so an arithmetic slip on a screen cannot agree with itself.
"""

import json
import re

import pandas as pd
import pytest

from conftest import _bind, assert_clean, button, expander, goto, launch, page
from contract import AGENT, SCREENS
from fake_snowflake import (AGENT_ANSWER, AGENT_SQL, BLOCKED_CUSTOMER, CLEAN_CUSTOMER,
                            DEFAULT_CUSTOMER, VULNERABLE_CUSTOMER, FakeSession, SQLError,
                            agent_response, build_book)


def widget(elements, label):
    hits = [w for w in elements if w.label == label]
    assert hits, f"no widget labelled {label!r}; have {[w.label for w in elements]}"
    return hits[0]


def reasoning_rows(at):
    """Worklist rows in display order, as 'Customer · Action'."""
    return [e.label.removeprefix("Reasoning · ") for e in at.expander
            if e.label.startswith("Reasoning · ")]


def pick_customer(at, cid):
    at.selectbox(key="cust_sel").set_value(cid).run()
    assert_clean(at, f"selecting customer {cid}")
    return at


# =============================================================================
# Shell: navigation and the sidebar
# =============================================================================

class TestShell:
    def test_lands_on_the_cockpit(self, app):
        assert app.session_state["nav"] == "Portfolio cockpit"
        assert '<p class="h-title">Portfolio cockpit</p>' in page(app)

    @pytest.mark.parametrize("screen, title", [
        ("Portfolio cockpit", "Portfolio cockpit"), ("Customer 360", "Anjali D&#x27;Souza"),
        ("Ask", "Ask"), ("Impact", "Impact simulator")])
    def test_every_screen_renders_its_header(self, app, screen, title):
        goto(app, screen)
        assert f'<p class="h-title">{title}</p>' in page(app)

    def test_there_is_one_nav_button_per_screen(self, app):
        assert [b.label for b in app.sidebar.button] == SCREENS

    def test_sidebar_reports_the_book_from_the_kpi_view(self, app, fake):
        side = "\n".join(m.value for m in app.sidebar.markdown)
        assert "Positions as of <b>10 Nov 2026</b>" in side
        assert f"<b>{len(fake.book['worklist'])}</b> actions published" in side
        assert f"<b>{len(fake.book['suppressed'])}</b> suppressed by rule" in side
        assert "<b>0</b> RM decisions recorded" in side

    def test_round_trip_through_every_screen_leaves_no_error(self, app):
        for screen in SCREENS + SCREENS[::-1]:
            goto(app, screen)

    def test_only_the_ask_screen_can_spend_cortex_credits(self, app, fake):
        for screen in SCREENS:
            goto(app, screen)
        assert fake.agent_calls == []
        assert not fake.statements(r"CORTEX|AI_COMPLETE|AI_CLASSIFY|AI_SENTIMENT")

    def test_reads_are_cached_between_reruns(self, app, fake):
        before = len(fake.executed)
        goto(app, "Portfolio cockpit")
        goto(app, "Portfolio cockpit")
        assert len(fake.executed) == before


# =============================================================================
# Screen 1 -- Portfolio cockpit
# =============================================================================

class TestCockpit:
    def test_header_carries_book_size_and_both_dates(self, app):
        html = page(app)
        assert "Book of <b>4</b> customers" in html
        assert "positions as of <b>10 Nov 2026</b>" in html
        assert "actions published <b>12 Nov 2026</b>" in html

    def test_kpi_strip_matches_the_kpi_view(self, app, fake):
        k = fake.book["kpi"]
        html = page(app)
        assert html.count('<div class="kpi">') == 5
        assert f"<b>{k['CUSTOMERS_WITH_ACTION']}</b> have at least one action" in html
        assert '<div class="kpi-v">₹1.72 L</div>' in html              # 1,72,450.50
        assert f"across <b>{k['ACTIONS_PUBLISHED']}</b> actions" in html
        assert "<b>4</b> rules fired · most often <b>No channel consent</b> (3)" in html
        assert "<b>₹84,250</b> premium on 1 policies" in html
        assert '<div class="kpi-v sm">₹34.90 L</div>' in html           # arrears exposure
        assert "<b>2</b> customers past due on a loan" in html

    def test_fully_suppressed_caption(self, app):
        caps = [c.value for c in app.caption]
        assert any(c.startswith("1 customers had a genuine need identified")
                   and "₹2.00 L of gross margin" in c for c in caps)

    def test_suppression_table_lists_every_rule_and_totals_them(self, app, fake, appns):
        s = fake.book["summary"]
        html = next(m.value for m in app.markdown if '<table class="t">' in m.value)
        for r in s.itertuples():
            assert (f"<tr><td>{appns['words'](r.SUPPRESSION_REASON)}</td>"
                    f'<td class="n">{r.ACTIONS_SUPPRESSED}</td>'
                    f'<td class="n">{r.CUSTOMERS_AFFECTED}</td>') in html
        assert html.count("<tr><td>") == len(s)                        # one row per rule
        assert f'<td class="tot">Total</td><td class="n tot">{int(s.ACTIONS_SUPPRESSED.sum())}</td>' in html
        assert '<td class="n tot">₹2.00 L</td>' in html                 # 96k+9k+0+40k+0+55k

    def test_suppression_total_equals_the_kpi_tile(self, app, fake):
        assert int(fake.book["summary"].ACTIONS_SUPPRESSED.sum()) == fake.book["kpi"]["ACTIONS_SUPPRESSED"]
        assert '<div class="kpi-v">6</div>' in page(app)

    def test_category_mix_strip_shows_the_whole_book(self, app):
        html = page(app)
        for chip in ("Service recovery 2 (33%)", "Retention 2 (33%)",
                     "Collections 1 (17%)", "Cross sell 1 (17%)"):
            assert chip in html

    def test_worklist_puts_care_before_sales_whatever_the_value(self, app):
        """Product principle 3. The cross-sell is worth more than everything
        above it combined and must still be last."""
        assert reasoning_rows(app) == [
            "Anjali D'Souza · Hardship review call",      # tier 10, ₹18,450
            "Vikram Rao · Care check-in call",            # tier 10, ₹3,100
            "Anjali D'Souza · Renewal save call",         # tier 20, ₹42,300
            "Vikram Rao · Renewal reminder",              # tier 20, ₹7,400
            "Anjali D'Souza · Complaint callback",        # tier 20, ₹5,200
            "Rahul Mehta · Home insurance offer",         # tier 50, ₹96,000
        ]

    def test_worklist_caption_counts_and_sums_what_is_shown(self, app):
        assert any(c.value.startswith("6 of 6 actions · ₹1.72 L expected value shown")
                   for c in app.caption)

    def test_worklist_row_carries_state_chips(self, app):
        rows = [m.value for m in app.markdown if m.value.startswith('<div class="wl-row">')]
        assert len(rows) == 6
        hardship, care = rows[0], rows[1]
        assert "31-60 DPD" in hardship and ">Complaint<" in hardship and "Vulnerable" not in hardship
        assert ">Vulnerable<" in care and "1-30 DPD" in care
        assert "Pune · Sneha Kulkarni" in hardship
        assert '<div class="wl-ev">₹18,450</div>' in hardship and "41.2%" in hardship

    def test_filter_by_category(self, app):
        widget(app.multiselect, "Category").set_value(["CROSS_SELL"]).run()
        assert_clean(app)
        assert reasoning_rows(app) == ["Rahul Mehta · Home insurance offer"]
        assert any(c.value.startswith("1 of 6 actions · ₹96,000") for c in app.caption)

    def test_filter_by_channel(self, app):
        widget(app.multiselect, "Channel").set_value(["CALL"]).run()
        assert reasoning_rows(app) == ["Anjali D'Souza · Hardship review call",
                                       "Vikram Rao · Care check-in call",
                                       "Anjali D'Souza · Renewal save call"]

    def test_filter_by_relationship_manager(self, app):
        box = widget(app.selectbox, "Relationship manager")
        assert box.options == ["All relationship managers", "Rohit Deshpande", "Sneha Kulkarni"]
        box.set_value("Rohit Deshpande").run()
        assert_clean(app)
        assert all(r.startswith(("Vikram Rao", "Rahul Mehta")) for r in reasoning_rows(app))
        assert len(reasoning_rows(app)) == 3

    def test_filters_combine_and_an_empty_result_does_not_crash(self, app):
        widget(app.multiselect, "Category").set_value(["CROSS_SELL"])
        widget(app.multiselect, "Channel").set_value(["SMS"]).run()
        assert_clean(app)
        assert reasoning_rows(app) == []
        assert any(c.value.startswith("0 of 6 actions · ₹0 expected value shown")
                   for c in app.caption)

    def test_show_limits_the_rows(self, monkeypatch):
        book = build_book()
        wl = book["worklist"]
        book["worklist"] = pd.concat(
            [wl.assign(CUSTOMER_ID=wl.CUSTOMER_ID + 10000 * i,
                       CUSTOMER_NAME=wl.CUSTOMER_NAME + f" {i}") for i in range(20)],
            ignore_index=True)                                         # 120 rows
        _bind(monkeypatch, FakeSession(book))
        at = launch()
        assert len(reasoning_rows(at)) == 50
        widget(at.selectbox, "Show").set_value(100).run()
        assert len(reasoning_rows(at)) == 100
        widget(at.selectbox, "Show").set_value(250).run()
        assert len(reasoning_rows(at)) == 120
        assert any(c.value.startswith("120 of 120 actions") for c in at.caption)

    def test_reasoning_names_who_wrote_the_rationale_and_any_reordering(self, app):
        body = "\n".join(m.value for m in expander(app, "Reasoning · Anjali D'Souza · Hardship").markdown)
        assert ">Model-written<" in body and ">Servicing obligation<" in body
        assert "Reordered from #2 by care boundary" in body and ">Not a sales action<" in body
        assert "Restructuring may affect the credit bureau record." in body
        caps = [c.value for c in expander(app, "Reasoning · Anjali D'Souza · Hardship").caption]
        assert caps == ["Regulatory basis — RBI Fair Practices Code"]

        tmpl = "\n".join(m.value for m in expander(app, "Reasoning · Anjali D'Souza · Renewal").markdown)
        assert ">Template<" in tmpl and "Reordered" not in tmpl

        sales = "\n".join(m.value for m in expander(app, "Reasoning · Rahul Mehta").markdown)
        assert "Not a sales action" not in sales
        assert "&lt;script&gt;" in sales and "<script>" not in sales

    def test_open_full_customer_record_jumps_to_that_customer(self, app):
        app.button(key=f"goto_{VULNERABLE_CUSTOMER}_VULNERABLE_CARE_CHECKIN").click().run()
        assert_clean(app)
        assert app.session_state["nav"] == "Customer 360"
        assert app.selectbox(key="cust_sel").value == VULNERABLE_CUSTOMER
        assert '<p class="h-title">Vikram Rao</p>' in page(app)

    def test_deep_link_works_after_customer_360_was_already_visited(self, app):
        goto(app, "Customer 360")                      # cust_sel now exists = default
        goto(app, "Portfolio cockpit")
        app.button(key=f"goto_{CLEAN_CUSTOMER}_HOME_INSURANCE_CROSS_SELL").click().run()
        assert_clean(app)
        assert app.selectbox(key="cust_sel").value == CLEAN_CUSTOMER


# =============================================================================
# Screen 2 -- Customer 360 (the action cards are in test_action_flow.py)
# =============================================================================

class TestCustomer360:
    def test_opens_on_the_default_customer(self, customer):
        assert customer.selectbox(key="cust_sel").value == DEFAULT_CUSTOMER
        html = page(customer)
        assert "Customer <b>#2397</b> · Pune · Mass affluent · 9 years with the group" in html

    def test_picker_lists_everyone_most_actions_first_and_flags_no_action(self, customer):
        assert customer.selectbox(key="cust_sel").options == [
            "Anjali D'Souza · Pune · #2397", "Vikram Rao · Mumbai · #103",
            "Rahul Mehta · Mumbai · #101", "Meera Iyer · Chennai · #102  (no action)"]

    def test_falls_back_to_the_first_customer_when_the_default_is_not_in_the_book(self, monkeypatch):
        book = build_book()
        for name in ("c360", "worklist", "suppressed", "timeline", "sentiment", "evidence"):
            book[name] = book[name][book[name].CUSTOMER_ID != DEFAULT_CUSTOMER]
        _bind(monkeypatch, FakeSession(book))
        at = goto(launch(), "Customer 360")
        assert at.selectbox(key="cust_sel").value == VULNERABLE_CUSTOMER

    def test_identity_badges_encode_state(self, customer):
        html = page(customer)
        assert "Pune · age 41 · household of 4" in html
        for badge in ("31-60 DPD", "Open complaint", "Hardship signal", ">Gold<"):
            assert badge in html
        assert "KYC lapsed" not in html and ">Vulnerable<" not in html
        pick_customer(customer, BLOCKED_CUSTOMER)
        assert "KYC lapsed" in page(customer) and "No credit" in page(customer)
        pick_customer(customer, VULNERABLE_CUSTOMER)
        assert ">Vulnerable<" in page(customer)

    def test_value_and_holdings_panels(self, customer):
        html = page(customer)
        assert '<span class="kv-k">Annual premium</span><span class="kv-v n">₹84,250</span>' in html
        assert '<span class="kv-k">Outstanding credit</span><span class="kv-v n">₹32,75,000</span>' in html
        assert '<span class="kv-k">Products held</span><span class="kv-v n">3</span>' in html
        for held in (">Home loan<", ">Health insurance<", ">Credit card<"):
            assert held in html
        assert "Gaps (1)" in html and ">Home insurance<" in html

    def test_no_gap_section_when_there_is_no_gap(self, customer):
        pick_customer(customer, BLOCKED_CUSTOMER)
        assert "Gaps (" not in page(customer)

    def test_missing_denominators_render_as_a_dash_not_zero(self, customer):
        pick_customer(customer, CLEAN_CUSTOMER)
        html = page(customer)
        assert '<span class="kv-k">Claim ratio</span><span class="kv-v n">—</span>' in html
        assert '<span class="kv-k">Credit utilisation</span><span class="kv-v n">—</span>' in html
        pick_customer(customer, DEFAULT_CUSTOMER)
        assert '<span class="kv-k">Claim ratio</span><span class="kv-v n">0.42</span>' in page(customer)
        assert '<span class="kv-k">Credit utilisation</span><span class="kv-v n">81.0%</span>' in page(customer)

    def test_consent_is_shown_as_green_and_red_chips(self, customer):
        html = page(customer)
        assert '<span class="chip c-ok">Call</span><span class="chip c-ok">Email</span>' \
               '<span class="chip c-risk">SMS</span>' in html
        assert '<span class="chip c-ok">Not on DNC</span>' in html and "Prefers Call" in html
        assert "6 days ago" in html
        pick_customer(customer, BLOCKED_CUSTOMER)
        html = page(customer)
        assert '<span class="chip c-risk">On DNC registry</span>' in html
        assert '<span class="chip c-risk">Call</span><span class="chip c-risk">Email</span>' \
               '<span class="chip c-risk">SMS</span>' in html
        assert '<span class="kv-v n">never</span>' in html

    def test_sentiment_is_plotted_only_with_two_or_more_readings(self, customer):
        caps = [c.value for c in customer.caption]
        assert any(c.startswith("4 readings, 02 Aug 2026 to 04 Nov 2026") for c in caps)
        assert ">Deteriorating<" in page(customer)
        for cid, chip in ((CLEAN_CUSTOMER, "Trend unknown"), (BLOCKED_CUSTOMER, "Never contacted")):
            pick_customer(customer, cid)
            assert any(c.value.startswith("Too few readings to plot") for c in customer.caption)
            assert chip in page(customer) and ">Stable<" not in page(customer)

    def test_timeline_hides_routine_events_by_default_and_says_how_many(self, customer):
        assert any(c.value == "6 events on record · showing the most recent 4 · 2 hidden by filter"
                   for c in customer.caption)
        html = page(customer)
        assert "Home loan EMI of ₹28,500 missed" in html and "Claim settlement delay" in html
        assert "Home loan EMI paid on time" not in html and "Festive card offer SMS" not in html

    def test_timeline_filter_can_show_everything(self, customer):
        box = customer.multiselect(key=f"tlf_{DEFAULT_CUSTOMER}")
        assert sorted(box.value) == ["COMPLAINT_RAISED", "INTERACTION", "PAYMENT_MISSED"]
        box.set_value(["CAMPAIGN_CONTACT", "COMPLAINT_RAISED", "INTERACTION",
                       "PAYMENT_MISSED", "PAYMENT_ON_TIME"]).run()
        assert_clean(customer)
        assert "Festive card offer SMS" in page(customer)
        assert any(c.value == "6 events on record · showing the most recent 6" for c in customer.caption)

    def test_customer_with_no_events_gets_a_message_not_an_empty_column(self, customer):
        pick_customer(customer, BLOCKED_CUSTOMER)
        assert [i.value for i in customer.info] == ["No events recorded for this customer."]

    def test_interaction_expands_into_transcript_and_extracted_signals(self, customer):
        e = expander(customer, "04 Nov 2026")
        assert "EMI difficulty after job loss" in e.label
        body = "\n".join(m.value for m in e.markdown)
        assert "Meri job chali gayi &lt;urgent&gt; &amp; EMI" in body and "<urgent>" not in body
        for chip in (">Call<", ">Inbound<", "Transcribed from audio", "Language hi",
                     ">Negative<", ">Hardship request<", "Financial hardship", "Life event",
                     "Competitor: unnamed", "Pricing: Negative"):
            assert chip in body, chip
        assert "Churn risk voiced" not in body and ">Complaint<" not in body
        for k, v in (("Product mentioned", "Home loan"), ("Amount discussed", "₹28,500"),
                     ("Callback promised", "08 Nov 2026"), ("Sentiment score", "-0.72"),
                     ("Intent confidence", "93.0%")):
            assert f'<span class="kv-k">{k}</span><span class="kv-v n">{v}</span>' in body

    def test_signals_withheld_by_the_confidence_gate_are_shown_as_withheld(self, customer):
        e = expander(customer, "28 Oct 2026")
        assert e.label.endswith("Email")               # no subject: falls back to the title
        body = "\n".join(m.value for m in e.markdown)
        assert "Sentiment withheld by confidence gate" in body
        assert "Intent withheld by confidence gate" in body
        assert ">Complaint<" in body and "Transcribed from audio" not in body
        assert "Sentiment score" not in body and "Language" not in body

    def test_suppressed_panel_is_open_by_default_and_names_every_blocking_rule(self, customer):
        e = expander(customer, "Show 3 suppressed actions and the rule that blocked each")
        assert e.proto.expanded is True
        body = "\n".join(m.value for m in e.markdown)
        assert body.index("Home insurance offer") < body.index("Card limit increase") \
            < body.index("EMI payment reminder")                        # by value at stake
        assert "Cross sell via Call · ₹6,40,000 at stake · 2 rules blocked" in body
        assert "Upsell via Sms · ₹1,50,000 at stake · 1 rule blocked" in body
        for rule, seen in (("Global arrears", "dpd_bucket=31-60"),
                           ("Global open complaint", "open_complaint=true"),
                           ("Global channel consent", "consent_sms=false")):
            assert f">{rule}</span>" in body and seen in body
        assert any(c.value.startswith("3 actions this customer had a genuine need for")
                   and "₹8.38 L of exposure withheld" in c.value and "₹1.05 L of gross margin" in c.value
                   for c in customer.caption)

    def test_a_waived_rule_is_shown_as_waived_with_its_regulatory_basis(self, customer):
        body = "\n".join(m.value for m in expander(customer, "Show 3 suppressed").markdown)
        waived = body.split("EMI payment reminder")[1]
        assert "Global open complaint — waived" in waived
        assert "Servicing communications are exempt from the complaint hold." in waived
        not_waived = body.split("Home insurance offer")[1].split("Card limit increase")[0]
        assert "waived" not in not_waived

    def test_nothing_suppressed_says_so(self, customer):
        pick_customer(customer, CLEAN_CUSTOMER)
        assert "Nothing suppressed. Every action this customer had a need for passed all rules." \
            in page(customer)
        assert not [e for e in customer.expander if e.label.startswith("Show ")]

    @pytest.mark.parametrize("cid", [DEFAULT_CUSTOMER, CLEAN_CUSTOMER, BLOCKED_CUSTOMER,
                                     VULNERABLE_CUSTOMER])
    def test_every_fixture_customer_renders(self, customer, cid):
        pick_customer(customer, cid)

    def test_vulnerable_customer_is_offered_no_sales_action(self, customer, fake):
        """Guardrail, checked on what the screen shows rather than on the data:
        a vulnerable customer's cards must all be care or servicing actions."""
        pick_customer(customer, VULNERABLE_CUSTOMER)
        html = page(customer)
        assert html.count('<div class="card card-care">') == 2
        assert '<div class="card card-top">' not in html
        assert ">Cross sell<" not in html.split("Suppressed by compliance")[0]


# =============================================================================
# Screen 3 -- Ask (agent mocked; the real one is behind --with-agent)
# =============================================================================

QUESTION = "How many actions did compliance block, and which rule blocked the most?"


def ask(at, text):
    at.chat_input[0].set_value(text).run()
    assert_clean(at, "asking the agent")
    return at


class TestAsk:
    @pytest.fixture
    def ask_screen(self, app):
        return goto(app, "Ask")

    def test_idle_screen_offers_suggestions_and_sends_nothing(self, ask_screen, fake, appns):
        assert sorted(b.label for b in ask_screen.button if (b.key or "").startswith("sug_")) \
            == sorted(appns["SUGGESTED"])
        assert any("Nothing is sent until you ask" in c.value for c in ask_screen.caption)
        assert "What each tool answers" in page(ask_screen)
        assert fake.agent_calls == []

    def test_question_goes_to_rm_copilot_once_as_a_single_user_turn(self, ask_screen, fake):
        ask(ask_screen, QUESTION)
        assert fake.agent_calls == [(AGENT, {"messages": [
            {"role": "user", "content": [{"type": "text", "text": QUESTION}]}]})]

    def test_answer_and_question_are_both_in_the_transcript(self, ask_screen):
        ask(ask_screen, QUESTION)
        assert [m.name for m in ask_screen.chat_message] == ["user", "assistant"]
        assert ask_screen.chat_message[0].markdown[0].value == QUESTION
        assert ask_screen.chat_message[1].markdown[0].value == AGENT_ANSWER
        assert not [b for b in ask_screen.button if (b.key or "").startswith("sug_")]

    def test_reasoning_trace_exposes_plan_tool_sql_result_followups_and_tokens(self, ask_screen):
        ask(ask_screen, QUESTION)
        e = expander(ask_screen, "Reasoning · 1 tool call · 1 generated query")
        md = "\n".join(m.value for m in e.markdown)
        assert "Portfolio question: route to Analyst." in md
        assert ">portfolio_analyst<" in md and ">cortex_analyst_text_to_sql<" in md
        assert "· Which customers were fully suppressed?" in md
        assert [c.value for c in e.code if c.language == "sql"] == [AGENT_SQL]
        tool_input = json.loads(next(c.value for c in e.code if c.language == "json"))
        assert tool_input == {"query": "suppression by rule"}           # sql shown once, below
        assert e.dataframe[0].value.values.tolist() == [["NO_CHANNEL_CONSENT", "3"],
                                                        ["DNC_REGISTRY", "1"]]
        assert [c.value for c in e.caption] == [
            "Orchestrated by claude-test · 12,345 input tokens, 678 output tokens"]

    def test_generated_sql_goes_through_the_semantic_view(self, ask_screen):
        ask(ask_screen, QUESTION)
        assert "SEMANTIC_VIEW(" in expander(ask_screen, "Reasoning").code[1].value

    def test_suggestion_button_sends_exactly_that_question(self, ask_screen, fake, appns):
        ask_screen.button(key="sug_1").click().run()
        assert_clean(ask_screen)
        assert fake.agent_calls[0][1]["messages"][0]["content"][0]["text"] == appns["SUGGESTED"][1]
        assert len(fake.agent_calls) == 1

    def test_follow_up_sends_history_as_text_only_turns(self, ask_screen, fake):
        ask(ask_screen, QUESTION)
        ask(ask_screen, "And for customer 2397?")
        _, body = fake.agent_calls[1]
        assert [m["role"] for m in body["messages"]] == ["user", "assistant", "user"]
        assert body["messages"][1]["content"] == [{"type": "text", "text": AGENT_ANSWER}]
        assert body["messages"][2]["content"][0]["text"] == "And for customer 2397?"
        assert "tool_use" not in json.dumps(body) and "tool_result" not in json.dumps(body)
        assert len(ask_screen.chat_message) == 4

    @pytest.mark.parametrize("text", [
        "What did D'Souza say about the 'renewal'?",
        'Show "arrears" \\ overdue; DROP TABLE x; --',
        "line one\nline two",
        "₹ में बताओ — कितने ग्राहक?",
    ], ids=["apostrophe", "backslash-semicolon", "newline", "unicode"])
    def test_question_text_survives_the_sql_literal(self, ask_screen, fake, text):
        ask(ask_screen, text)
        assert fake.agent_calls[0][1]["messages"][-1]["content"][0]["text"] == text

    def test_agent_failure_is_explained_in_the_chat_not_raised(self, ask_screen, fake):
        fake.agent = SQLError("Insufficient privileges to operate on agent RM_COPILOT")
        ask(ask_screen, QUESTION)
        reply = ask_screen.chat_message[1].markdown[0].value
        assert reply.startswith("The agent call failed.")
        assert "Insufficient privileges" in reply and "sql/18b_agent_grants_admin.sql" in reply
        assert not [e for e in ask_screen.expander if e.label.startswith("Reasoning")]

    def test_conversation_continues_after_a_failure(self, ask_screen, fake):
        fake.agent = SQLError("timeout")
        ask(ask_screen, QUESTION)
        fake.agent = agent_response()
        ask(ask_screen, "try again")
        assert ask_screen.chat_message[3].markdown[0].value == AGENT_ANSWER

    def test_non_json_response_is_shown_verbatim(self, ask_screen, fake):
        fake.agent = "plain text, not json"
        ask(ask_screen, QUESTION)
        assert ask_screen.chat_message[1].markdown[0].value == "plain text, not json"

    def test_response_with_no_text_block_says_so(self, ask_screen, fake):
        fake.agent = {"content": [], "metadata": {}}
        ask(ask_screen, QUESTION)
        assert ask_screen.chat_message[1].markdown[0].value == "_No text returned._"

    @pytest.mark.parametrize("broken", [
        {"type": "tool_use", "tool_use": ["not", "an", "object"]},
        {"type": "tool_result", "tool_result": {"content": ["not an object"]}},
        {"type": "thinking", "thinking": "a bare string"},
    ], ids=["tool_use-list", "tool_result-strings", "thinking-string"])
    def test_a_surprise_in_the_trace_cannot_take_the_answer_down(self, ask_screen, fake, broken):
        resp = agent_response()
        resp["content"].insert(0, broken)
        fake.agent = resp
        ask(ask_screen, QUESTION)
        assert ask_screen.chat_message[1].markdown[0].value == AGENT_ANSWER
        caps = [c.value for c in expander(ask_screen, "Reasoning").caption]
        assert any(c.startswith("The answer above is complete, but part of the reasoning trace")
                   for c in caps)

    def test_suggested_queries_as_a_bare_list_parse_cleanly(self, ask_screen):
        """Regression: this block once raised "'list' object has no attribute 'get'"."""
        ask(ask_screen, QUESTION)
        caps = [c.value for c in expander(ask_screen, "Reasoning").caption]
        assert not any("could not be read" in c for c in caps)

    def test_clear_conversation_resets_and_sends_nothing(self, ask_screen, fake):
        ask(ask_screen, QUESTION)
        button(ask_screen, "Clear conversation").click().run()
        assert_clean(ask_screen)
        assert len(ask_screen.chat_message) == 0 and ask_screen.session_state["chat"] == []
        assert len([b for b in ask_screen.button if (b.key or "").startswith("sug_")]) == 4
        assert len(fake.agent_calls) == 1

    def test_chat_survives_a_visit_to_another_screen(self, ask_screen, fake):
        ask(ask_screen, QUESTION)
        goto(ask_screen, "Impact")
        goto(ask_screen, "Ask")
        assert len(ask_screen.chat_message) == 2 and len(fake.agent_calls) == 1


# =============================================================================
# Screen 4 -- Impact
# =============================================================================

COST = {"CALL": 45.0, "EMAIL": 0.20, "SMS": 0.15}


def model(book, acc=0.08, cost=COST, penalty=0.0):
    """The simulator's arithmetic, restated independently of the app."""
    b = book["impact"]
    rev = lambda d: float(d.GROSS_MARGIN_AT_FULL_ACCEPTANCE.sum()) * acc          # noqa: E731
    spend = lambda d: float(sum(r.CONTACTS * cost[r.CHANNEL] for r in d.itertuples()))  # noqa: E731
    pub, sup = b[b.ARM == "PUBLISHED"], b[b.ARM == "SUPPRESSED"]
    s_n = int(sup.CONTACTS.sum())
    t_net = rev(pub) - spend(pub)
    e_gross = rev(b) - spend(b)
    return dict(t_n=int(pub.CONTACTS.sum()), e_n=int(b.CONTACTS.sum()), s_n=s_n, t_net=t_net,
                e_net=e_gross - penalty * s_n, s_cost=spend(sup),
                breakeven=(e_gross - t_net) / s_n if s_n else 0.0)


def kpis(at):
    html = next(m.value for m in at.markdown if m.value.startswith('<div class="kpis">'))
    return dict(re.findall(r'<div class="kpi-l">(.*?)</div><div class="kpi-v sm">(.*?)</div>', html))


class TestImpact:
    @pytest.fixture
    def impact(self, app):
        return goto(app, "Impact")

    def test_default_assumptions(self, impact):
        assert widget(impact.slider, "Acceptance rate").value == 8.0
        assert widget(impact.number_input, "Cost per call (₹)").value == 45.0
        assert widget(impact.number_input, "Cost per email (₹)").value == pytest.approx(0.20)
        assert widget(impact.number_input, "Cost per SMS (₹)").value == pytest.approx(0.15)
        assert widget(impact.number_input, "Penalty per breach (₹)").value == 0.0   # never invented

    def test_headline_tiles_match_an_independent_calculation(self, impact, fake, appns):
        m, inr = model(fake.book), appns["inr"]
        k = kpis(impact)
        assert k["Targeted book, net"] == inr(m["t_net"], True)
        assert k["Contact everyone, net"] == inr(m["e_net"], True)
        assert k["What compliance costs"] == inr(m["e_net"] - m["t_net"], True)
        assert k["Contact cost avoided"] == inr(m["s_cost"], True)
        assert k["Breakeven penalty"] == inr(m["breakeven"])
        html = page(impact)
        assert f"<b>{m['t_n']}</b> contacts" in html and f"<b>{m['e_n']}</b> contacts" in html
        assert "no penalty assumed" in html

    def test_compliance_is_reported_as_a_cost_when_it_is_one(self, impact, fake):
        m = model(fake.book)
        assert m["e_net"] > m["t_net"]                 # the fixture, like the real book
        assert f"forgone net contribution from <b>{m['s_n']}</b> blocked solicitations" in page(impact)
        assert "uplift" not in page(impact).lower()

    def test_three_arms_table_reconciles_to_the_baseline(self, impact, fake):
        b = fake.book["impact"]
        html = next(m.value for m in impact.markdown if "<th>Outcome</th>" in m.value)
        contacts = [int(x) for x in re.findall(r'</span></td><td class="n">(\d+)</td>', html)]
        want = [int(b[b.ARM == a].CONTACTS.sum())
                for a in ("PUBLISHED", "ELIGIBLE_NOT_PUBLISHED", "SUPPRESSED")]
        assert contacts == want == [6, 1, 6]
        assert f'<td class="n tot">{sum(want)}</td>' in html

    def test_acceptance_slider_rescales_revenue_but_not_cost(self, impact, fake, appns):
        widget(impact.slider, "Acceptance rate").set_value(20.0).run()
        assert_clean(impact)
        m, k = model(fake.book, acc=0.20), kpis(impact)
        assert k["Targeted book, net"] == appns["inr"](m["t_net"], True)
        assert k["Contact cost avoided"] == appns["inr"](model(fake.book)["s_cost"], True)
        assert any(c.value.startswith("At 20.0% acceptance") for c in impact.caption)

    def test_channel_costs_feed_the_cost_avoided_tile(self, impact, fake, appns):
        widget(impact.number_input, "Cost per call (₹)").set_value(100.0).run()
        assert_clean(impact)
        m = model(fake.book, cost={**COST, "CALL": 100.0})
        assert kpis(impact)["Contact cost avoided"] == appns["inr"](m["s_cost"], True)
        assert kpis(impact)["Targeted book, net"] == appns["inr"](m["t_net"], True)

    def test_a_penalty_above_breakeven_puts_targeting_ahead(self, impact, fake, appns):
        m0 = model(fake.book)
        above = float(int(m0["breakeven"]) + 1000)
        widget(impact.number_input, "Penalty per breach (₹)").set_value(above).run()
        assert_clean(impact)
        m = model(fake.book, penalty=above)
        assert m["t_net"] > m["e_net"]
        html = page(impact)
        assert "targeting is <b>ahead</b> at this penalty" in html
        assert f"less {appns['inr'](above * m['s_n'], True)} in penalties" in html
        assert kpis(impact)["Breakeven penalty"] == appns["inr"](m0["breakeven"])   # unchanged

    def test_a_penalty_below_breakeven_still_shows_a_cost(self, impact, fake):
        below = float(max(int(model(fake.book)["breakeven"]) - 1000, 1))
        widget(impact.number_input, "Penalty per breach (₹)").set_value(below).run()
        assert "forgone net contribution" in page(impact)

    def test_no_suppressed_arm_does_not_divide_by_zero(self, monkeypatch, appns):
        book = build_book()
        book["impact"] = book["impact"][book["impact"].ARM != "SUPPRESSED"]
        _bind(monkeypatch, FakeSession(book))
        at = goto(launch(), "Impact")
        assert kpis(at)["Breakeven penalty"] == "₹0"
        assert kpis(at)["Contact cost avoided"] == "₹0"

    def test_both_charts_render(self, impact):
        # The element is "vega_lite_chart" or "arrow_vega_lite_chart" by Streamlit version.
        charts = [e for e in impact.main if "vega_lite_chart" in getattr(e, "type", "")]
        assert len(charts) == 2

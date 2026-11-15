"""
fake_snowflake.py -- a stand-in Snowpark session, and a small fixture book.

The app talks to Snowflake through exactly two calls: session.sql(text).to_pandas()
for reads and session.sql(text).collect() for the one INSERT and the agent call.
FakeSession implements those two and nothing else, which is why the whole app can
be executed under Streamlit's AppTest with no account, no warehouse and no
credits.

What it deliberately does NOT do is run SQL. The views are tested where they live
(the assertions in sql/19 and tests/test_live_*.py). This file answers each query
the app is known to send with a frame of the same shape, and it is strict in
three ways so a green offline run means something:

  1. An unrecognised query raises UnroutedSQL instead of returning an empty
     frame. A query added to the app without a fixture fails loudly.
  2. Every frame is checked against tests/contract.py before it is served.
  3. The INSERT is parsed with Snowflake's string-literal rules ('' and
     backslash escapes) and held to the table's NOT NULL and CHECK constraints,
     so an unescaped quote in a rejection note fails here the way it would fail
     -- or worse, succeed -- in the warehouse.

Types mirror what to_pandas() returns: ARRAY/VARIANT columns arrive as JSON
text, DATE as datetime.date, TIMESTAMP as pandas Timestamps, NULL as None/NaN.
"""

from __future__ import annotations

import copy
import datetime as dt
import json
import re

import pandas as pd

from contract import APP_READS, DECISIONS, FEEDBACK_INSERT_COLUMNS, FEEDBACK_NOT_NULL

NAN = float("nan")
DEFAULT_CUSTOMER = 2397          # must match DEFAULT_CUSTOMER in the app
CLEAN_CUSTOMER = 101             # one action, nothing suppressed, one reading
BLOCKED_CUSTOMER = 102           # no action at all: everything suppressed, on DNC
VULNERABLE_CUSTOMER = 103        # care actions only, one unresolved citation


class UnroutedSQL(AssertionError):
    """The app sent a query this fake has no fixture for."""


class SQLError(Exception):
    """Stands in for snowflake.snowpark.exceptions.SnowparkSQLException."""


# =============================================================================
# The fixture book -- four customers chosen to hit every branch of the screens
# =============================================================================

def _ts(s):
    return pd.Timestamp(s)


def _j(v):
    return json.dumps(v)


def build_book() -> dict:
    as_of = dt.date(2026, 11, 10)
    published = _ts("2026-11-12 06:30:00")

    c360 = pd.DataFrame([
        dict(CUSTOMER_ID=DEFAULT_CUSTOMER, CUSTOMER_NAME="Anjali D'Souza", CITY="Pune",
             SEGMENT="MASS_AFFLUENT", TENURE_YEARS=9, AGE=41, HOUSEHOLD_SIZE=4,
             RELATIONSHIP_VALUE_BAND="GOLD", DPD_BUCKET="31-60", VULNERABILITY_FLAG=False,
             OPEN_COMPLAINT=True, HARDSHIP_SIGNAL=True, KYC_CURRENT=True,
             ANNUAL_PREMIUM_INR=84250.0, OUTSTANDING_CREDIT_INR=3275000.0,
             EST_ANNUAL_MARGIN_INR=61200.0, PRODUCT_COUNT=3,
             PRODUCTS_HELD=_j(["HOME_LOAN", "HEALTH_INSURANCE", "CREDIT_CARD"]),
             PRODUCT_GAP=_j(["HOME_INSURANCE"]), MISSED_PAYMENTS_12M=2, LAPSE_HISTORY=0,
             CLAIM_RATIO=0.42, CREDIT_UTILISATION=0.81, CONSENT_CALL=True,
             CONSENT_EMAIL=True, CONSENT_SMS=False, DNC_FLAG=False,
             PREFERRED_CHANNEL="CALL", LAST_CONTACT_DAYS=6.0,
             SENTIMENT_TREND="DETERIORATING", SENTIMENT_NOW="negative", AS_OF_DATE=as_of),
        dict(CUSTOMER_ID=CLEAN_CUSTOMER, CUSTOMER_NAME="Rahul Mehta", CITY="Mumbai",
             SEGMENT="AFFLUENT", TENURE_YEARS=4, AGE=35, HOUSEHOLD_SIZE=2,
             RELATIONSHIP_VALUE_BAND="PLATINUM", DPD_BUCKET="CURRENT",
             VULNERABILITY_FLAG=False, OPEN_COMPLAINT=False, HARDSHIP_SIGNAL=False,
             KYC_CURRENT=True, ANNUAL_PREMIUM_INR=0.0, OUTSTANDING_CREDIT_INR=7800000.0,
             EST_ANNUAL_MARGIN_INR=142000.0, PRODUCT_COUNT=1,
             PRODUCTS_HELD=_j(["HOME_LOAN"]), PRODUCT_GAP=_j(["HOME_INSURANCE", "TERM_LIFE"]),
             MISSED_PAYMENTS_12M=0, LAPSE_HISTORY=0, CLAIM_RATIO=NAN,
             CREDIT_UTILISATION=NAN, CONSENT_CALL=True, CONSENT_EMAIL=True,
             CONSENT_SMS=True, DNC_FLAG=False, PREFERRED_CHANNEL="EMAIL",
             LAST_CONTACT_DAYS=12.0, SENTIMENT_TREND="INSUFFICIENT_DATA",
             SENTIMENT_NOW="positive", AS_OF_DATE=as_of),
        dict(CUSTOMER_ID=BLOCKED_CUSTOMER, CUSTOMER_NAME="Meera Iyer", CITY="Chennai",
             SEGMENT="MASS", TENURE_YEARS=1, AGE=58, HOUSEHOLD_SIZE=1,
             RELATIONSHIP_VALUE_BAND="BRONZE", DPD_BUCKET="NO_CREDIT_OBLIGATION",
             VULNERABILITY_FLAG=False, OPEN_COMPLAINT=False, HARDSHIP_SIGNAL=False,
             KYC_CURRENT=False, ANNUAL_PREMIUM_INR=18000.0, OUTSTANDING_CREDIT_INR=0.0,
             EST_ANNUAL_MARGIN_INR=2100.0, PRODUCT_COUNT=1,
             PRODUCTS_HELD=_j(["TERM_LIFE"]), PRODUCT_GAP=_j([]),
             MISSED_PAYMENTS_12M=0, LAPSE_HISTORY=1, CLAIM_RATIO=NAN,
             CREDIT_UTILISATION=NAN, CONSENT_CALL=False, CONSENT_EMAIL=False,
             CONSENT_SMS=False, DNC_FLAG=True, PREFERRED_CHANNEL="SMS",
             LAST_CONTACT_DAYS=NAN, SENTIMENT_TREND="NO_CONTACT_HISTORY",
             SENTIMENT_NOW=None, AS_OF_DATE=as_of),
        dict(CUSTOMER_ID=VULNERABLE_CUSTOMER, CUSTOMER_NAME="Vikram Rao", CITY="Mumbai",
             SEGMENT="MASS", TENURE_YEARS=12, AGE=67, HOUSEHOLD_SIZE=2,
             RELATIONSHIP_VALUE_BAND="SILVER", DPD_BUCKET="1-30", VULNERABILITY_FLAG=True,
             OPEN_COMPLAINT=False, HARDSHIP_SIGNAL=False, KYC_CURRENT=True,
             ANNUAL_PREMIUM_INR=36500.0, OUTSTANDING_CREDIT_INR=215000.0,
             EST_ANNUAL_MARGIN_INR=9800.0, PRODUCT_COUNT=2,
             PRODUCTS_HELD=_j(["HEALTH_INSURANCE", "PERSONAL_LOAN"]),
             PRODUCT_GAP=_j(["TERM_LIFE"]), MISSED_PAYMENTS_12M=1, LAPSE_HISTORY=0,
             CLAIM_RATIO=1.3, CREDIT_UTILISATION=NAN, CONSENT_CALL=True,
             CONSENT_EMAIL=False, CONSENT_SMS=True, DNC_FLAG=False,
             PREFERRED_CHANNEL="CALL", LAST_CONTACT_DAYS=40.0,
             SENTIMENT_TREND="STABLE", SENTIMENT_NOW="neutral", AS_OF_DATE=as_of),
    ])
    rm = {"Pune": "Sneha Kulkarni", "Mumbai": "Rohit Deshpande", "Chennai": "Kavita Iyer"}

    def action(cid, rank, code, name, cat, chan, prop, ev, rationale, *, tier, sales,
               source="LLM", moved=False, source_rank=None, servicing=False,
               disclosure=None, reg=None, evidence=()):
        c = c360[c360.CUSTOMER_ID == cid].iloc[0]
        return dict(
            CUSTOMER_ID=cid, CUSTOMER_NAME=c.CUSTOMER_NAME, CITY=c.CITY, RM_NAME=rm[c.CITY],
            SEGMENT=c.SEGMENT, RELATIONSHIP_VALUE_BAND=c.RELATIONSHIP_VALUE_BAND,
            ACTION_RANK=rank, ACTION_CODE=code, ACTION_NAME=name, CATEGORY=cat,
            CHANNEL=chan, PROPENSITY=prop, EXPECTED_VALUE_INR=ev, RATIONALE=rationale,
            DISCLOSURE=disclosure, EVIDENCE_IDS=_j(list(evidence)),
            ELIGIBILITY_TRACE=_j([{"rule": "NEED", "verdict": "PASS"}]),
            EVIDENCE_COUNT=len(evidence), RATIONALE_SOURCE=source, PRIORITY_TIER=tier,
            IS_SALES_ACTION=sales, RANK_MOVED=moved,
            SOURCE_RANK=source_rank if source_rank is not None else rank,
            IS_SERVICING_OBLIGATION=servicing, REGULATORY_NOTE=reg,
            DPD_BUCKET=c.DPD_BUCKET, VULNERABILITY_FLAG=c.VULNERABILITY_FLAG,
            OPEN_COMPLAINT=c.OPEN_COMPLAINT, SENTIMENT_NOW=c.SENTIMENT_NOW,
            SENTIMENT_TREND=c.SENTIMENT_TREND, DAYS_TO_RENEWAL=NAN,
            OUTSTANDING_CREDIT_INR=c.OUTSTANDING_CREDIT_INR,
            EST_ANNUAL_MARGIN_INR=c.EST_ANNUAL_MARGIN_INR,
            PREFERRED_CHANNEL=c.PREFERRED_CHANNEL, CONSENT_CALL=c.CONSENT_CALL,
            CONSENT_EMAIL=c.CONSENT_EMAIL, CONSENT_SMS=c.CONSENT_SMS,
            GENERATED_AT=published,
        )

    worklist = pd.DataFrame([
        action(DEFAULT_CUSTOMER, 1, "HARDSHIP_REVIEW", "Hardship review call", "COLLECTIONS",
               "CALL", 0.4123, 18450.0,
               "Two missed EMIs and a call mentioning a job loss; offer a restructure review.",
               tier=10, sales=False, moved=True, source_rank=2, servicing=True,
               disclosure="Restructuring may affect the credit bureau record.",
               reg="RBI Fair Practices Code", evidence=("INT-9001", "INT-9002")),
        action(DEFAULT_CUSTOMER, 2, "RENEWAL_SAVE", "Renewal save call", "RETENTION",
               "CALL", 0.3050, 42300.5,
               "Health policy renews in 21 days and a competitor quote was mentioned.",
               tier=20, sales=False, source="TEMPLATE", source_rank=1,
               disclosure="Premium revision is subject to IRDAI filing."),
        action(DEFAULT_CUSTOMER, 3, "SERVICE_RECOVERY_CALLBACK", "Complaint callback",
               "SERVICE_RECOVERY", "EMAIL", 0.6200, 5200.0,
               "Open complaint about a claim delay has had no response in 9 days.",
               tier=20, sales=False, evidence=("INT-9002",)),
        action(CLEAN_CUSTOMER, 1, "HOME_INSURANCE_CROSS_SELL", "Home insurance offer",
               "CROSS_SELL", "EMAIL", 0.1875, 96000.0,
               # Markup in the data must render as text, never as HTML.
               "Holds a home loan & no cover <b>gap</b> <script>alert(1)</script>.",
               tier=50, sales=True, disclosure="Insurance is the subject matter of solicitation.",
               evidence=("INT-9101",)),
        action(VULNERABLE_CUSTOMER, 1, "VULNERABLE_CARE_CHECKIN", "Care check-in call",
               "SERVICE_RECOVERY", "CALL", 0.5000, 3100.0,
               "Flagged vulnerable; one late EMI. A care check-in, not a sales call.",
               tier=10, sales=False, servicing=True, evidence=("INT-9301", "INT-MISSING")),
        action(VULNERABLE_CUSTOMER, 2, "POLICY_RENEWAL_REMINDER", "Renewal reminder",
               "RETENTION", "SMS", 0.7000, 7400.0,
               "Health policy renewal due; statutory reminder.",
               tier=20, sales=False, source="TEMPLATE", servicing=True),
    ])

    def blocked(cid, code, name, cat, chan, reason, value, margin, blocking, exempt=(),
                reg=None, servicing=False):
        return dict(
            CUSTOMER_ID=cid, ACTION_CODE=code, ACTION_NAME=name, CATEGORY=cat, CHANNEL=chan,
            SUPPRESSION_REASON=reason, SUPPRESSION_REASONS=_j([reason]),
            VALUE_AT_STAKE_INR=value, GROSS_MARGIN_INR=margin,
            BLOCKING_RULES=_j(list(blocking)), EXEMPT_RULES=_j(list(exempt)),
            REGULATORY_NOTE=reg, IS_SERVICING_OBLIGATION=servicing,
        )

    def rule(name, observed, verdict="BLOCK"):
        return {"rule": name, "verdict": verdict, "observed": observed}

    suppressed = pd.DataFrame([
        blocked(DEFAULT_CUSTOMER, "HOME_INSURANCE_CROSS_SELL", "Home insurance offer",
                "CROSS_SELL", "CALL", "ARREARS_CROSS_SELL", 640000.0, 96000.0,
                [rule("GLOBAL_ARREARS", "dpd_bucket=31-60"),
                 rule("GLOBAL_OPEN_COMPLAINT", "open_complaint=true")]),
        blocked(DEFAULT_CUSTOMER, "CARD_LIMIT_INCREASE", "Card limit increase",
                "UPSELL", "SMS", "NO_CHANNEL_CONSENT", 150000.0, 9000.0,
                [rule("GLOBAL_CHANNEL_CONSENT", "consent_sms=false")]),
        blocked(DEFAULT_CUSTOMER, "PAYMENT_REMINDER", "EMI payment reminder",
                "COLLECTIONS", "SMS", "NO_CHANNEL_CONSENT", 48000.0, 0.0,
                [rule("GLOBAL_CHANNEL_CONSENT", "consent_sms=false")],
                exempt=[rule("GLOBAL_OPEN_COMPLAINT", "open_complaint=true", "EXEMPT")],
                reg="Servicing communications are exempt from the complaint hold.",
                servicing=True),
        blocked(BLOCKED_CUSTOMER, "TERM_TOPUP_OFFER", "Term cover top-up", "UPSELL", "CALL",
                "DNC_REGISTRY", 500000.0, 40000.0,
                [rule("GLOBAL_DNC", "dnc_flag=true"),
                 rule("GLOBAL_CHANNEL_CONSENT", "consent_call=false")]),
        blocked(BLOCKED_CUSTOMER, "KYC_REFRESH", "KYC refresh request", "SERVICE_RECOVERY",
                "EMAIL", "NO_CHANNEL_CONSENT", 0.0, 0.0,
                [rule("GLOBAL_CHANNEL_CONSENT", "consent_email=false")]),
        blocked(VULNERABLE_CUSTOMER, "TERM_LIFE_CROSS_SELL", "Term life offer", "CROSS_SELL",
                "CALL", "VULNERABLE_SALES", 1000000.0, 55000.0,
                [rule("GLOBAL_VULNERABILITY", "vulnerability_flag=true")]),
    ])

    def event(cid, eid, etype, when, title, detail=None, **inter):
        base = dict(
            CUSTOMER_ID=cid, EVENT_ID=eid, EVENT_TYPE=etype, OCCURRED_AT=_ts(when),
            TITLE=title, DETAIL=detail,
            SOURCE_TABLE="RAW.INTERACTION" if etype == "INTERACTION" else "RAW.REPAYMENT",
            INTERACTION_SUBJECT=None, INTERACTION_BODY=None, INTERACTION_CHANNEL=None,
            INTERACTION_DIRECTION=None, INTERACTION_LANGUAGE=None, FROM_AUDIO=None,
            SENTIMENT_OVERALL=None, SENTIMENT_SCORE=NAN, SENTIMENT_PRICING=None,
            SENTIMENT_SERVICE=None, SENTIMENT_CLAIMS=None, INTENT=None, INTENT_CONF=NAN,
            SUMMARY_25W=None, CHURN_RISK_MENTIONED=None, COMPETITOR_MENTIONED=None,
            COMPETITOR_NAME=None, COMPLAINT=None, LIFE_EVENT=None, HARDSHIP_SIGNAL=None,
            CONSENT_WITHDRAWAL=None, PRODUCT_MENTIONED=None, AMOUNT_DISCUSSED_INR=NAN,
            PROMISED_CALLBACK_DATE=None,
        )
        base.update(inter)
        return base

    timeline = pd.DataFrame([
        event(DEFAULT_CUSTOMER, "E1", "INTERACTION", "2026-11-04 11:20", "Inbound call",
              INTERACTION_SUBJECT="EMI difficulty after job loss",
              INTERACTION_BODY="Agent: Namaste.\nCustomer: Meri job chali gayi <urgent> & EMI...",
              INTERACTION_CHANNEL="CALL", INTERACTION_DIRECTION="INBOUND",
              INTERACTION_LANGUAGE="hi", FROM_AUDIO=True, SENTIMENT_OVERALL="negative",
              SENTIMENT_SCORE=-0.72, SENTIMENT_PRICING="negative", INTENT="HARDSHIP_REQUEST",
              INTENT_CONF=0.93, SUMMARY_25W="Customer lost job; asks for EMI relief.",
              CHURN_RISK_MENTIONED=False, COMPETITOR_MENTIONED=True, COMPETITOR_NAME=None,
              COMPLAINT=False, LIFE_EVENT=True, HARDSHIP_SIGNAL=True,
              CONSENT_WITHDRAWAL=False, PRODUCT_MENTIONED="HOME_LOAN",
              AMOUNT_DISCUSSED_INR=28500.0, PROMISED_CALLBACK_DATE=dt.date(2026, 11, 8)),
        # Confidence gate withheld sentiment and intent: must render as withheld.
        event(DEFAULT_CUSTOMER, "E2", "INTERACTION", "2026-10-28 09:05", "Email",
              INTERACTION_SUBJECT=None, INTERACTION_BODY="Claim still pending.",
              INTERACTION_CHANNEL="EMAIL", INTERACTION_DIRECTION="INBOUND",
              INTERACTION_LANGUAGE="en", FROM_AUDIO=False, COMPLAINT=True),
        event(DEFAULT_CUSTOMER, "E3", "PAYMENT_MISSED", "2026-10-05", "EMI missed",
              "Home loan EMI of ₹28,500 missed"),
        event(DEFAULT_CUSTOMER, "E4", "COMPLAINT_RAISED", "2026-10-20", "Complaint",
              "Claim settlement delay"),
        event(DEFAULT_CUSTOMER, "E5", "PAYMENT_ON_TIME", "2026-09-05", "EMI paid",
              "Home loan EMI paid on time"),
        event(DEFAULT_CUSTOMER, "E6", "CAMPAIGN_CONTACT", "2026-08-11", "Campaign",
              "Festive card offer SMS"),
        event(CLEAN_CUSTOMER, "E7", "LOAN_DISBURSED", "2022-12-01", "Home loan disbursed",
              "₹85,00,000 home loan"),
        event(CLEAN_CUSTOMER, "E8", "PAYMENT_ON_TIME", "2026-11-01", "EMI paid", None),
        event(VULNERABLE_CUSTOMER, "E9", "PAYMENT_LATE", "2026-10-15", "EMI late",
              "Personal loan EMI 6 days late"),
    ])

    sentiment = pd.DataFrame([
        dict(CUSTOMER_ID=DEFAULT_CUSTOMER, OCCURRED_AT=_ts("2026-08-02"), SENTIMENT_SCORE=0.35,
             SENTIMENT_OVERALL="positive", INTENT="GENERAL_QUERY"),
        dict(CUSTOMER_ID=DEFAULT_CUSTOMER, OCCURRED_AT=_ts("2026-09-19"), SENTIMENT_SCORE=-0.10,
             SENTIMENT_OVERALL="neutral", INTENT="CLAIM_STATUS"),
        dict(CUSTOMER_ID=DEFAULT_CUSTOMER, OCCURRED_AT=_ts("2026-10-20"), SENTIMENT_SCORE=-0.55,
             SENTIMENT_OVERALL="negative", INTENT="COMPLAINT"),
        dict(CUSTOMER_ID=DEFAULT_CUSTOMER, OCCURRED_AT=_ts("2026-11-04"), SENTIMENT_SCORE=-0.72,
             SENTIMENT_OVERALL="negative", INTENT="HARDSHIP_REQUEST"),
        dict(CUSTOMER_ID=CLEAN_CUSTOMER, OCCURRED_AT=_ts("2026-10-30"), SENTIMENT_SCORE=0.60,
             SENTIMENT_OVERALL="positive", INTENT="GENERAL_QUERY"),
    ])

    def cite(cid, code, pos, eid, resolved=True, etype="INTERACTION", detail="Inbound call"):
        return dict(CUSTOMER_ID=cid, ACTION_CODE=code, EVIDENCE_POSITION=pos, EVIDENCE_ID=eid,
                    EVENT_TYPE=etype if resolved else None,
                    OCCURRED_AT=_ts("2026-11-04") if resolved else pd.NaT,
                    TITLE="Interaction" if resolved else None,
                    DETAIL=detail if resolved else None,
                    SOURCE_TABLE="RAW.INTERACTION" if resolved else None, RESOLVED=resolved)

    evidence = pd.DataFrame([
        cite(DEFAULT_CUSTOMER, "HARDSHIP_REVIEW", 1, "INT-9001", detail="Call: job loss, EMI relief"),
        cite(DEFAULT_CUSTOMER, "HARDSHIP_REVIEW", 2, "INT-9002", detail="Email: claim pending"),
        cite(DEFAULT_CUSTOMER, "SERVICE_RECOVERY_CALLBACK", 1, "INT-9002", detail="Email: claim pending"),
        cite(CLEAN_CUSTOMER, "HOME_INSURANCE_CROSS_SELL", 1, "INT-9101", detail="Chat: asked about cover"),
        cite(VULNERABLE_CUSTOMER, "VULNERABLE_CARE_CHECKIN", 1, "INT-9301", detail="Call: confused about EMI"),
        cite(VULNERABLE_CUSTOMER, "VULNERABLE_CARE_CHECKIN", 2, "INT-MISSING", resolved=False),
    ])

    # Margin at full acceptance, per published action -- kept beside the code so
    # the three impact arms below can be derived rather than typed twice.
    margin = {"HARDSHIP_REVIEW": 0.0, "RENEWAL_SAVE": 12600.0,
              "SERVICE_RECOVERY_CALLBACK": 0.0, "HOME_INSURANCE_CROSS_SELL": 96000.0,
              "VULNERABLE_CARE_CHECKIN": 0.0, "POLICY_RENEWAL_REMINDER": 5475.0}
    arms = [dict(ARM="PUBLISHED", CHANNEL=r.CHANNEL, CATEGORY=r.CATEGORY,
                 IS_SALES_ACTION=r.IS_SALES_ACTION, CONTACTS=1, CUSTOMERS=1,
                 VALUE_AT_STAKE_INR=r.EXPECTED_VALUE_INR * 4,
                 GROSS_MARGIN_AT_FULL_ACCEPTANCE=margin[r.ACTION_CODE])
            for r in worklist.itertuples()]
    arms += [dict(ARM="SUPPRESSED", CHANNEL=r.CHANNEL, CATEGORY=r.CATEGORY,
                  IS_SALES_ACTION=r.CATEGORY in ("CROSS_SELL", "UPSELL"), CONTACTS=1,
                  CUSTOMERS=1, VALUE_AT_STAKE_INR=r.VALUE_AT_STAKE_INR,
                  GROSS_MARGIN_AT_FULL_ACCEPTANCE=r.GROSS_MARGIN_INR)
             for r in suppressed.itertuples()]
    arms.append(dict(ARM="ELIGIBLE_NOT_PUBLISHED", CHANNEL="EMAIL", CATEGORY="CROSS_SELL",
                     IS_SALES_ACTION=True, CONTACTS=1, CUSTOMERS=1,
                     VALUE_AT_STAKE_INR=120000.0, GROSS_MARGIN_AT_FULL_ACCEPTANCE=7200.0))
    impact = (pd.DataFrame(arms)
              .groupby(["ARM", "CHANNEL", "CATEGORY", "IS_SALES_ACTION"], as_index=False)
              .sum(numeric_only=True))

    summary = (suppressed.assign(
                   VIA_CALL=(suppressed.CHANNEL == "CALL").astype(int),
                   VIA_EMAIL=(suppressed.CHANNEL == "EMAIL").astype(int),
                   VIA_SMS=(suppressed.CHANNEL == "SMS").astype(int),
                   SERV=suppressed.IS_SERVICING_OBLIGATION.astype(int))
               .groupby("SUPPRESSION_REASON", as_index=False)
               .agg(ACTIONS_SUPPRESSED=("ACTION_CODE", "size"),
                    CUSTOMERS_AFFECTED=("CUSTOMER_ID", "nunique"),
                    ACTIONS_DISTINCT=("ACTION_CODE", "nunique"),
                    VALUE_AT_STAKE_INR=("VALUE_AT_STAKE_INR", "sum"),
                    GROSS_MARGIN_INR=("GROSS_MARGIN_INR", "sum"),
                    VIA_CALL=("VIA_CALL", "sum"), VIA_EMAIL=("VIA_EMAIL", "sum"),
                    VIA_SMS=("VIA_SMS", "sum"), ON_SERVICING_OBLIGATIONS=("SERV", "sum")))
    summary["SHARE_OF_SUPPRESSIONS"] = summary.ACTIONS_SUPPRESSED / summary.ACTIONS_SUPPRESSED.sum()

    top = summary.sort_values("ACTIONS_SUPPRESSED", ascending=False).iloc[0]
    kpi = dict(
        CUSTOMERS_TOTAL=len(c360), CUSTOMERS_WITH_ACTION=worklist.CUSTOMER_ID.nunique(),
        ACTIONS_PUBLISHED=len(worklist),
        TOTAL_EXPECTED_VALUE_INR=float(worklist.EXPECTED_VALUE_INR.sum()),
        ACTIONS_SUPPRESSED=len(suppressed), SUPPRESSION_RULES_FIRED=len(summary),
        CUSTOMERS_TOUCHED_BY_SUPPRESSION=suppressed.CUSTOMER_ID.nunique(),
        CUSTOMERS_FULLY_SUPPRESSED=1,
        SUPPRESSED_VALUE_AT_STAKE_INR=float(suppressed.VALUE_AT_STAKE_INR.sum()),
        SUPPRESSED_GROSS_MARGIN_INR=float(suppressed.GROSS_MARGIN_INR.sum()),
        TOP_SUPPRESSION_REASON=top.SUPPRESSION_REASON,
        TOP_SUPPRESSION_COUNT=int(top.ACTIONS_SUPPRESSED),
        RENEWALS_AT_RISK_30D=1, POLICIES_AT_RISK_30D=1, PREMIUM_AT_RISK_INR=84250.0,
        CUSTOMERS_IN_ARREARS=2, ARREARS_EXPOSURE_INR=3490000.0, CUSTOMERS_VULNERABLE=1,
        PUBLISHED_AT=published, AS_OF_DATE=as_of,
    )

    return {"c360": c360, "worklist": worklist, "suppressed": suppressed,
            "timeline": timeline, "sentiment": sentiment, "evidence": evidence,
            "impact": impact, "summary": summary, "kpi": kpi}


# =============================================================================
# A canned APP.RM_COPILOT response, in the shape ask_agent() parses
# =============================================================================

AGENT_ANSWER = "Compliance blocked 6 actions. NO_CHANNEL_CONSENT blocked the most (3)."
AGENT_SQL = ("SELECT suppression_reason, COUNT(*) n FROM SEMANTIC_VIEW("
             "GOLD.SV_CUSTOMER_360 ...) GROUP BY 1")


def agent_response(answer=AGENT_ANSWER) -> dict:
    return {
        "role": "assistant",
        "content": [
            {"type": "thinking", "thinking": {"text": "Portfolio question: route to Analyst."}},
            {"type": "tool_use", "tool_use": {
                "name": "portfolio_analyst", "type": "cortex_analyst_text_to_sql",
                "input": {"query": "suppression by rule", "sql": AGENT_SQL}}},
            {"type": "tool_result", "tool_result": {"content": [{"type": "json", "json": {
                "result_set": {
                    "resultSetMetaData": {"rowType": [{"name": "SUPPRESSION_REASON"},
                                                      {"name": "N"}]},
                    "data": [["NO_CHANNEL_CONSENT", "3"], ["DNC_REGISTRY", "1"]]}}}]}},
            {"type": "text", "text": answer},
            # A LIST under the key, not an object -- the shape that once broke the
            # parser with "'list' object has no attribute 'get'".
            {"type": "suggested_queries", "suggested_queries": [
                {"query": "Which customers were fully suppressed?"}]},
        ],
        "metadata": {"usage": {"tokens_consumed": [{
            "model_name": "claude-test", "input_tokens": {"total": 12345},
            "output_tokens": {"total": 678}}]}},
    }


# =============================================================================
# SQL literal handling -- Snowflake's rules, so escaping is tested for real
# =============================================================================

def split_top_level(expr: str) -> list:
    """Split on commas that are outside quotes and parentheses."""
    parts, buf, depth, i, n = [], [], 0, 0, len(expr)
    while i < n:
        ch = expr[i]
        if ch == "'":
            j = i + 1
            while True:
                if j >= n:
                    raise SQLError("unterminated string literal -- quote not escaped")
                if expr[j] == "\\":
                    j += 2
                    continue
                if expr[j] == "'":
                    if j + 1 < n and expr[j + 1] == "'":
                        j += 2
                        continue
                    break
                j += 1
            buf.append(expr[i:j + 1])
            i = j + 1
            continue
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
            if depth < 0:
                raise SQLError("unbalanced parenthesis")
        elif ch == "," and depth == 0:
            parts.append("".join(buf).strip())
            buf, i = [], i + 1
            continue
        buf.append(ch)
        i += 1
    if depth:
        raise SQLError("unbalanced parenthesis")
    parts.append("".join(buf).strip())
    return parts


_ESCAPES = {"n": "\n", "t": "\t", "r": "\r", "0": "\0", "b": "\b", "f": "\f"}


def unquote(token: str) -> str:
    """'it''s' -> it's ; 'a\\\\b' -> a\\b . Single-quoted Snowflake literal."""
    assert token.startswith("'") and token.endswith("'"), token
    body, out, i = token[1:-1], [], 0
    while i < len(body):
        ch = body[i]
        if ch == "\\" and i + 1 < len(body):
            nxt = body[i + 1]
            out.append(_ESCAPES.get(nxt, nxt))
            i += 2
        elif ch == "'":
            if body[i + 1:i + 2] != "'":
                raise SQLError("bare quote inside string literal")
            out.append("'")
            i += 2
        else:
            out.append(ch)
            i += 1
    return "".join(out)


# =============================================================================
# The session
# =============================================================================

class _Result:
    def __init__(self, session, text):
        self._s, self._t = session, text

    def to_pandas(self):
        return self._s._read(self._t)

    def collect(self):
        return self._s._collect(self._t)


class FakeSession:
    """Answers the queries app/streamlit_app.py sends. See the module docstring."""

    def __init__(self, book=None, *, agent=None, current_user="TEST_RM"):
        self.book = copy.deepcopy(book) if book is not None else build_book()
        self.current_user = current_user      # None models SiS without READ SESSION
        self.agent = agent if agent is not None else agent_response()
        self.fail_matching = {}               # regex -> exception, for error paths
        self.executed = []                    # every statement, in order
        self.feedback = []                    # rows INSERTed into APP.ACTION_FEEDBACK
        self.agent_calls = []                 # [(agent_name, request_body_dict)]
        self._clock = pd.Timestamp("2026-11-15 10:00:00")

    # -- entry point -----------------------------------------------------------
    def sql(self, text, *_, **__):
        self.executed.append(text)
        for pattern, exc in self.fail_matching.items():
            if re.search(pattern, text, re.I | re.S):
                raise exc
        return _Result(self, text)

    # -- inspection helpers used by the tests ---------------------------------
    def statements(self, pattern):
        return [t for t in self.executed if re.search(pattern, t, re.I | re.S)]

    @property
    def inserts(self):
        return self.statements(r"^\s*INSERT\b")

    def seed_feedback(self, customer_id, action_code, decision, *, reason=None, note=None,
                      rank=1, ev=0.0, by="EARLIER_RM"):
        self._clock += pd.Timedelta(seconds=1)
        self.feedback.append(dict(
            FEEDBACK_ID=len(self.feedback) + 1, CUSTOMER_ID=customer_id,
            ACTION_CODE=action_code, ACTION_RANK=rank, DECISION=decision,
            REJECT_REASON=reason, NOTE=note, EXPECTED_VALUE_INR=ev, DECIDED_BY=by,
            DECIDED_AT=self._clock))

    # -- writes and the agent --------------------------------------------------
    def _collect(self, text):
        # Not whitespace-flattened: a rejection note may contain newlines and
        # runs of spaces, and those must survive to the stored row.
        if re.match(r"\s*INSERT INTO APP\.ACTION_FEEDBACK\b", text, re.I):
            self._insert_feedback(text)
            return []
        if "DATA_AGENT_RUN" in text.upper():
            return self._agent_run(text)
        raise UnroutedSQL(f"collect() on a statement the fake does not know:\n{text}")

    def _insert_feedback(self, text):
        m = re.match(r"\s*INSERT INTO APP\.ACTION_FEEDBACK\s*\((.*?)\)\s*SELECT\s+(.*)$",
                     text, re.I | re.S)
        if not m:
            raise SQLError(f"INSERT is not in the expected column-list + SELECT form:\n{text}")
        cols = [c.strip().upper() for c in m.group(1).split(",")]
        if cols != FEEDBACK_INSERT_COLUMNS:
            raise SQLError(f"INSERT column list changed: {cols}")
        vals = split_top_level(m.group(2).strip().rstrip(";"))
        if len(vals) != len(cols):
            raise SQLError(f"{len(cols)} columns but {len(vals)} values -- "
                           f"a literal was not escaped: {vals}")
        self._clock += pd.Timedelta(seconds=1)
        row = {"FEEDBACK_ID": len(self.feedback) + 1}
        for col, tok in zip(cols, vals):
            up = tok.upper()
            if up == "NULL":
                row[col] = None
            elif up == "CURRENT_USER()":
                row[col] = self.current_user
            elif up == "CURRENT_TIMESTAMP()":
                row[col] = self._clock
            elif tok.startswith("'"):
                row[col] = unquote(tok)
            else:
                try:
                    row[col] = int(tok) if re.fullmatch(r"-?\d+", tok) else float(tok)
                except ValueError:
                    raise SQLError(f"invalid expression for {col}: {tok!r}") from None
                if row[col] != row[col]:
                    raise SQLError(f"invalid identifier 'NAN' for {col}")
        for col in FEEDBACK_NOT_NULL:
            if row.get(col) is None:
                raise SQLError(f"NULL result in a non-nullable column: {col}")
        if row["DECISION"] not in DECISIONS:
            raise SQLError(f"CHECK constraint CHK_DECISION violated: {row['DECISION']!r}")
        self.feedback.append(row)

    def _agent_run(self, text):
        m = re.search(r"DATA_AGENT_RUN\((.*)\)\s*AS\s+R\s*;?\s*$", text, re.I | re.S)
        if not m:
            raise SQLError(f"agent call is not in the expected form:\n{text}")
        name, body = (unquote(t) for t in split_top_level(m.group(1)))
        self.agent_calls.append((name, json.loads(body)))
        if isinstance(self.agent, Exception):
            raise self.agent
        raw = self.agent if isinstance(self.agent, str) else json.dumps(self.agent)
        return [{"R": raw}]

    # -- reads -----------------------------------------------------------------
    def _read(self, text):
        flat = " ".join(text.split())
        up = flat.upper()
        b = self.book

        def cid():
            m = re.search(r"CUSTOMER_ID\s*=\s*(\d+)", up)
            if not m:
                raise UnroutedSQL(f"expected a CUSTOMER_ID filter:\n{text}")
            return int(m.group(1))

        def serve(obj, df):
            missing = [c for c in APP_READS[obj] if c not in df.columns]
            if missing:
                raise AssertionError(f"fixture for {obj} lacks contracted columns {missing}")
            cols = self._plain_select_list(flat)
            if cols:
                absent = [c for c in cols if c not in df.columns]
                if absent:
                    raise SQLError(f"invalid identifier {absent} selecting from {obj}")
                df = df[cols]
            return df.reset_index(drop=True).copy()

        if "FROM APP.V_PORTFOLIO_KPI" in up:
            k = dict(b["kpi"])
            k["DECISIONS_RECORDED"] = len(self.feedback)
            k["DECISIONS_ACCEPTED"] = sum(f["DECISION"] == "ACCEPTED" for f in self.feedback)
            return serve("APP.V_PORTFOLIO_KPI", pd.DataFrame([k]))

        if "FROM APP.V_SUPPRESSION_SUMMARY" in up:
            return serve("APP.V_SUPPRESSION_SUMMARY", b["summary"])

        if "FROM APP.V_WORKLIST" in up:
            df = b["worklist"]
            if "WHERE" in up:
                df = df[df.CUSTOMER_ID == cid()].sort_values("ACTION_RANK")
            return serve("APP.V_WORKLIST", df)

        if "FROM GOLD.CUSTOMER_360 C" in up and "GOLD.NEXT_BEST_ACTION" in up:
            acts = b["worklist"].groupby("CUSTOMER_ID").size()
            df = b["c360"][["CUSTOMER_ID", "CUSTOMER_NAME", "CITY"]].copy()
            df["ACTS"] = df.CUSTOMER_ID.map(acts).fillna(0).astype(int)
            return df.sort_values(["ACTS", "CUSTOMER_ID"],
                                  ascending=[False, True]).reset_index(drop=True)

        if "FROM GOLD.CUSTOMER_360" in up:
            return serve("GOLD.CUSTOMER_360", b["c360"][b["c360"].CUSTOMER_ID == cid()])

        if "FROM APP.V_SENTIMENT_SERIES" in up:
            df = b["sentiment"]
            return serve("APP.V_SENTIMENT_SERIES",
                         df[df.CUSTOMER_ID == cid()].sort_values("OCCURRED_AT"))

        if "FROM APP.V_TIMELINE_DETAIL" in up:
            df = b["timeline"]
            return serve("APP.V_TIMELINE_DETAIL",
                         df[df.CUSTOMER_ID == cid()].sort_values("OCCURRED_AT", ascending=False))

        if "FROM APP.V_NBA_EVIDENCE_RESOLVED" in up:
            m = re.search(r"ACTION_CODE\s*=\s*('(?:[^'\\]|''|\\.)*')", flat)
            if not m:
                raise UnroutedSQL(f"expected an ACTION_CODE filter:\n{text}")
            df = b["evidence"]
            df = df[(df.CUSTOMER_ID == cid()) & (df.ACTION_CODE == unquote(m.group(1)))]
            return serve("APP.V_NBA_EVIDENCE_RESOLVED", df.sort_values("EVIDENCE_POSITION"))

        if "FROM APP.V_CUSTOMER_SUPPRESSED" in up:
            df = b["suppressed"]
            return serve("APP.V_CUSTOMER_SUPPRESSED",
                         df[df.CUSTOMER_ID == cid()].sort_values("VALUE_AT_STAKE_INR",
                                                                 ascending=False))

        if "FROM APP.V_IMPACT_BASE" in up:
            return serve("APP.V_IMPACT_BASE", b["impact"])

        if "FROM APP.ACTION_FEEDBACK" in up:
            fb = pd.DataFrame(self.feedback, columns=APP_READS["APP.ACTION_FEEDBACK"])
            if "QUALIFY" in up:                       # latest decision per action
                df = (fb[fb.CUSTOMER_ID == cid()].sort_values("DECIDED_AT")
                      .groupby("ACTION_CODE", as_index=False).tail(1))
                return df[["ACTION_CODE", "DECISION", "REJECT_REASON", "DECIDED_BY",
                           "DECIDED_AT"]].reset_index(drop=True)
            if "COUNT(*) N" in up:                    # the Impact screen aggregate
                acc = fb[fb.DECISION == "ACCEPTED"]
                # SUM over zero rows is NULL in Snowflake, not 0.
                ev = float(acc.EXPECTED_VALUE_INR.sum()) if len(fb) else None
                return pd.DataFrame([{"N": len(fb), "ACC": len(acc), "EV": ev}])

        raise UnroutedSQL(
            "The app sent a query tests/fake_snowflake.py has no fixture for. Add a "
            f"route (and a tests/contract.py entry) for:\n{text}")

    @staticmethod
    def _plain_select_list(flat):
        """Column names when the select list is bare identifiers, else None."""
        m = re.match(r"SELECT\s+(.*?)\s+FROM\s", flat, re.I)
        if not m:
            return None
        cols = [c.strip() for c in m.group(1).split(",")]
        if all(re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", c) for c in cols):
            return [c.upper() for c in cols]
        return None

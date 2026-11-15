"""
contract.py -- every object the Streamlit app reads, and the columns it uses.

This is the one place the app's dependency on the warehouse is written down as
data. Two suites read it, for opposite reasons:

  offline   tests/fake_snowflake.py refuses to serve a frame that is missing a
            contracted column, so the fixture book cannot drift from the app.
  live      tests/test_live_contract.py checks every column below exists on the
            real object, so a view rebuilt with a renamed column fails here with
            the column's name instead of as a stack trace on a screen.

tests/test_contract_sync.py keeps this file honest in the other direction: it
scans app/streamlit_app.py for every object named after FROM / JOIN / INTO and
fails if one is missing here, so a query added to the app without a contract
entry cannot ship untested.
"""

APP_READS = {
    "APP.V_PORTFOLIO_KPI": [
        "CUSTOMERS_TOTAL", "CUSTOMERS_WITH_ACTION", "ACTIONS_PUBLISHED",
        "TOTAL_EXPECTED_VALUE_INR", "ACTIONS_SUPPRESSED", "SUPPRESSION_RULES_FIRED",
        "CUSTOMERS_FULLY_SUPPRESSED", "SUPPRESSED_GROSS_MARGIN_INR",
        "TOP_SUPPRESSION_REASON", "TOP_SUPPRESSION_COUNT", "RENEWALS_AT_RISK_30D",
        "POLICIES_AT_RISK_30D", "PREMIUM_AT_RISK_INR", "CUSTOMERS_IN_ARREARS",
        "ARREARS_EXPOSURE_INR", "DECISIONS_RECORDED", "PUBLISHED_AT", "AS_OF_DATE",
    ],
    "APP.V_SUPPRESSION_SUMMARY": [
        "SUPPRESSION_REASON", "ACTIONS_SUPPRESSED", "CUSTOMERS_AFFECTED",
        "VALUE_AT_STAKE_INR", "GROSS_MARGIN_INR", "ON_SERVICING_OBLIGATIONS",
        "VIA_CALL", "VIA_EMAIL", "VIA_SMS",
    ],
    "APP.V_WORKLIST": [
        "CUSTOMER_ID", "CUSTOMER_NAME", "CITY", "RM_NAME", "ACTION_RANK",
        "ACTION_CODE", "ACTION_NAME", "CATEGORY", "CHANNEL", "PROPENSITY",
        "EXPECTED_VALUE_INR", "RATIONALE", "DISCLOSURE", "RATIONALE_SOURCE",
        "PRIORITY_TIER", "IS_SALES_ACTION", "RANK_MOVED", "SOURCE_RANK",
        "EVIDENCE_COUNT", "IS_SERVICING_OBLIGATION", "REGULATORY_NOTE",
        "DPD_BUCKET", "VULNERABILITY_FLAG", "OPEN_COMPLAINT", "SENTIMENT_NOW",
        "SENTIMENT_TREND", "RELATIONSHIP_VALUE_BAND", "DAYS_TO_RENEWAL",
    ],
    "GOLD.CUSTOMER_360": [
        "CUSTOMER_ID", "CUSTOMER_NAME", "CITY", "SEGMENT", "TENURE_YEARS", "AGE",
        "HOUSEHOLD_SIZE", "RELATIONSHIP_VALUE_BAND", "DPD_BUCKET",
        "VULNERABILITY_FLAG", "OPEN_COMPLAINT", "HARDSHIP_SIGNAL", "KYC_CURRENT",
        "ANNUAL_PREMIUM_INR", "OUTSTANDING_CREDIT_INR", "EST_ANNUAL_MARGIN_INR",
        "PRODUCT_COUNT", "PRODUCTS_HELD", "PRODUCT_GAP", "MISSED_PAYMENTS_12M",
        "LAPSE_HISTORY", "CLAIM_RATIO", "CREDIT_UTILISATION", "CONSENT_CALL",
        "CONSENT_EMAIL", "CONSENT_SMS", "DNC_FLAG", "PREFERRED_CHANNEL",
        "LAST_CONTACT_DAYS", "SENTIMENT_TREND", "SENTIMENT_NOW",
    ],
    "GOLD.NEXT_BEST_ACTION": ["CUSTOMER_ID"],
    "APP.V_SENTIMENT_SERIES": [
        "CUSTOMER_ID", "OCCURRED_AT", "SENTIMENT_SCORE", "SENTIMENT_OVERALL", "INTENT",
    ],
    "APP.V_TIMELINE_DETAIL": [
        "CUSTOMER_ID", "EVENT_ID", "EVENT_TYPE", "OCCURRED_AT", "TITLE", "DETAIL",
        "SOURCE_TABLE", "INTERACTION_SUBJECT", "INTERACTION_BODY",
        "INTERACTION_CHANNEL", "INTERACTION_DIRECTION", "INTERACTION_LANGUAGE",
        "FROM_AUDIO", "SENTIMENT_OVERALL", "SENTIMENT_SCORE", "SENTIMENT_PRICING",
        "SENTIMENT_SERVICE", "SENTIMENT_CLAIMS", "INTENT", "INTENT_CONF",
        "SUMMARY_25W", "CHURN_RISK_MENTIONED", "COMPETITOR_MENTIONED",
        "COMPETITOR_NAME", "COMPLAINT", "LIFE_EVENT", "HARDSHIP_SIGNAL",
        "CONSENT_WITHDRAWAL", "PRODUCT_MENTIONED", "AMOUNT_DISCUSSED_INR",
        "PROMISED_CALLBACK_DATE",
    ],
    "APP.V_NBA_EVIDENCE_RESOLVED": [
        "CUSTOMER_ID", "ACTION_CODE", "EVIDENCE_POSITION", "EVIDENCE_ID",
        "EVENT_TYPE", "OCCURRED_AT", "TITLE", "DETAIL", "SOURCE_TABLE", "RESOLVED",
    ],
    "APP.V_CUSTOMER_SUPPRESSED": [
        "CUSTOMER_ID", "ACTION_CODE", "ACTION_NAME", "CATEGORY", "CHANNEL",
        "SUPPRESSION_REASON", "SUPPRESSION_REASONS", "VALUE_AT_STAKE_INR",
        "GROSS_MARGIN_INR", "BLOCKING_RULES", "EXEMPT_RULES", "REGULATORY_NOTE",
        "IS_SERVICING_OBLIGATION",
    ],
    "APP.V_IMPACT_BASE": [
        "ARM", "CHANNEL", "CATEGORY", "IS_SALES_ACTION", "CONTACTS", "CUSTOMERS",
        "VALUE_AT_STAKE_INR", "GROSS_MARGIN_AT_FULL_ACCEPTANCE",
    ],
    # The one table the app writes. Read back on Customer 360 and Impact.
    "APP.ACTION_FEEDBACK": [
        "FEEDBACK_ID", "CUSTOMER_ID", "ACTION_CODE", "ACTION_RANK", "DECISION",
        "REJECT_REASON", "NOTE", "EXPECTED_VALUE_INR", "DECIDED_BY", "DECIDED_AT",
    ],
}

# Columns the app INSERTs, in the order write_feedback() names them.
FEEDBACK_INSERT_COLUMNS = [
    "CUSTOMER_ID", "ACTION_CODE", "ACTION_RANK", "DECISION", "REJECT_REASON",
    "NOTE", "EXPECTED_VALUE_INR", "DECIDED_BY", "DECIDED_AT",
]
FEEDBACK_NOT_NULL = ["CUSTOMER_ID", "ACTION_CODE", "DECISION", "DECIDED_BY", "DECIDED_AT"]
DECISIONS = ("ACCEPTED", "REJECTED")

# Must equal REJECT_REASONS in the app and the list in sql/19's PART 2 comment.
REJECT_REASONS = [
    "NOT_RELEVANT", "ALREADY_CONTACTED", "CUSTOMER_DECLINED", "WRONG_TIMING",
    "WRONG_CHANNEL", "DATA_LOOKS_WRONG", "OTHER",
]

SCREENS = ["Portfolio cockpit", "Customer 360", "Ask", "Impact"]
AGENT = "C360_NBA.APP.RM_COPILOT"

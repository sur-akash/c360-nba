/* ============================================================================
   09_semantic_view.sql  —  GOLD.SV_CUSTOMER_360 and its five feeder views
   ----------------------------------------------------------------------------
   The analytical layer. A semantic view over the customer spine and the four
   book-of-business facts, so Cortex Analyst answers portfolio questions in
   natural language without anybody writing SQL.

   This is M8 in PROJECT_BRIEF §10. It was scoped there as 30_semantic_view.sql
   creating APP.C360_SV; it lands at 09 creating GOLD.SV_CUSTOMER_360 because
   the numbering drifted at 04 (see the header of 08_gold_c360.sql) and because
   the view sits on GOLD tables with no APP-layer dependency of its own. When
   the agent in M9 wires up cortex_analyst_text_to_sql, it points here.

   Cost: ZERO CREDITS. No AI function is called anywhere in this file, so it
   satisfies the AGENTS.md re-runnability invariant trivially rather than by
   the IF NOT EXISTS mechanism 04-07 need.

   ----------------------------------------------------------------------------
   WHAT IS IN SCOPE, AND THE ONE THING DELIBERATELY LEFT OUT
   ----------------------------------------------------------------------------
   Covered: GOLD.CUSTOMER_360 as the spine, plus RAW.POLICY, RAW.LOAN,
   RAW.CLAIM and RAW.CAMPAIGN_HISTORY as facts hanging off it.

   NOT covered: GOLD.NEXT_BEST_ACTION, and therefore no nba_expected_value_inr
   metric. That table currently holds PLACEHOLDER CONTENTS -- its PROPENSITY is
   a seeded hash of (customer, action) and its RATIONALE is prefixed
   [PLACEHOLDER]. Exposing an expected-value metric over it would let Analyst
   report confident rupee totals derived from a non-model propensity, which is
   the one thing product principle 1 exists to prevent. M5/M6 (sql/21-24)
   replace the contents against a fixed twelve-column contract; the metric
   lands then, and the only change needed here is one TABLES entry, one
   RELATIONSHIPS entry and one METRICS entry.

   ----------------------------------------------------------------------------
   WHY THERE ARE FIVE VIEWS AND NOT JUST A SEMANTIC VIEW
   ----------------------------------------------------------------------------
   Three reasons, in descending order of how load-bearing they are.

   1. THE AS-OF ANCHOR IS UNREACHABLE FROM A SEMANTIC VIEW EXPRESSION.
      policies_at_risk_30d needs "renewal date inside 30 days of the as-of
      date". A semantic view FACT or DIMENSION expression is evaluated against
      the columns of ONE logical table -- it cannot CROSS JOIN GOLD.C360_ASOF
      to get the anchor, and it must not call CURRENT_DATE, because then the
      metric would silently disagree with every day-count in CUSTOMER_360 the
      moment the anchor went stale (see 08's header on why the anchor exists at
      all). The anchor join therefore has to happen one layer down. This is not
      a style preference; without the views the metric cannot be defined
      correctly.

   2. ARRAYS CANNOT BE DIMENSIONED ON. CUSTOMER_360.PRODUCT_GAP and
      PRODUCTS_HELD are ARRAYs. cross_sell_gap_count is ARRAY_SIZE(PRODUCT_GAP)
      summed, and Analyst also wants to filter on "customers with a health
      insurance gap". Both need the array flattened or reduced to scalars
      first.

   3. DENORMALISATION KILLS THE FAN TRAPS. RAW.CLAIM carries POLICY_ID as well
      as CUSTOMER_ID, so a claims fact could reach the customer spine by two
      routes -- directly, or through RAW.POLICY. Declared both ways the engine
      raises "Multi-path relationship between dimension entity and base metric
      entity"; declared one way the other route's attributes become
      unreachable. So V_SV_CLAIM joins the two policy attributes worth slicing
      claims by (POLICY_TYPE, PRODUCT_FAMILY) into the claim row itself, and
      the semantic view then declares exactly one relationship per fact,
      straight to the spine. A flat star, four facts, no ambiguity. Same
      treatment for the PRODUCT_CATALOG lookups on policies, loans and
      campaigns: folded into the views rather than declared as a shared
      dimension that three facts point at.

   The views are named V_SV_* to mark them as presentation-layer shims for this
   semantic view specifically. Nothing else should read them; downstream code
   wanting these facts should read RAW or CURATED.

   ----------------------------------------------------------------------------
   HOW policies_at_risk_30d IS DEFINED, AND WHY THAT DEFINITION
   ----------------------------------------------------------------------------
   An ACTIVE policy whose RENEWAL_DATE falls inside 30 days of the as-of
   anchor, held by a customer who raised a complaint in the last 60 days.

   That is deliberately the S1 RETENTION_SAVE predicate from
   docs/DATA_SEGMENTS.md verbatim, not a looser "renewal is near" count. Two
   reasons. First, renewals inside 30 days happen naturally to roughly one
   policy in twelve, so a timing-only metric measures the calendar, not risk.
   Second, S1 is a planted segment with a known population (400 customers) and
   documented near-misses -- customers renewing soon with an OLDER complaint,
   who a wrong rule fires on. Defining the metric on the same predicate means
   evals/ can score Analyst's answers against a number that is already known to
   be exactly right, instead of against a second definition invented here.

   Measured: 420 policies across those 400 customers. The gap is customers
   holding more than one policy renewing in the window, which is correct at
   policy grain and is why the metric is named policies_ and not customers_.

   ----------------------------------------------------------------------------
   REFERENCE VALUES AT BUILD TIME (anchor 2026-08-28)
   ----------------------------------------------------------------------------
     total_customers         5,000
     avg_relationship_value  56,574.36 INR
     policies_at_risk_30d    420
     lapse_rate              0.083169  (675 lapsed of 8,116 policies)
     cross_sell_gap_count    7,855
     arrears_exposure_inr    521,397,600 INR

   The verification block at the foot of this file re-derives all six through
   SEMANTIC_VIEW() and asserts they match these figures computed in plain SQL.
   If the anchor moves, policies_at_risk_30d moves with it; the other five are
   anchor-independent.

   ----------------------------------------------------------------------------
   THE QUARANTINE HOLDS
   ----------------------------------------------------------------------------
   Nothing here reads RAW.CUSTOMER_SEGMENT_TRUTH. The five views read
   GOLD.CUSTOMER_360, GOLD.C360_ASOF, RAW.POLICY, RAW.LOAN, RAW.CLAIM,
   RAW.CAMPAIGN_HISTORY, RAW.SERVICE_TICKET and RAW.PRODUCT_CATALOG, and the
   assertion at the foot of this file proves it from the dependency graph
   rather than from a promise in a comment.
   ============================================================================ */

USE ROLE COCO_BUILDER;
USE WAREHOUSE COCO_WH;
USE DATABASE C360_NBA;
USE SCHEMA GOLD;


/* ============================================================================
   PART 1 — FEEDER VIEWS
   ============================================================================ */

/* ----------------------------------------------------------------------------
   1.1  GOLD.V_SV_CUSTOMER — the spine, scalarised
   ----------------------------------------------------------------------------
   CUSTOMER_360 passed through almost unchanged. The work done here is:
     - ARRAY columns reduced to a scalar count and to per-product gap booleans,
       because a semantic view cannot dimension on an ARRAY.
     - AGE and TENURE_YEARS additionally banded, because "how many customers
       are under 30" is a question Analyst gets asked and a band answers it
       without the model having to invent boundaries.
   No filtering. One row per customer, 5,000 rows, same as the source.
---------------------------------------------------------------------------- */
CREATE OR REPLACE VIEW GOLD.V_SV_CUSTOMER
  COMMENT = 'Feeder view for GOLD.SV_CUSTOMER_360. GOLD.CUSTOMER_360 with its two ARRAY columns reduced to scalars (a gap count plus per-product gap booleans) and AGE / TENURE_YEARS banded. One row per customer, no filtering. Presentation shim only -- read GOLD.CUSTOMER_360 directly for any other purpose.'
AS
SELECT
    c.CUSTOMER_ID,
    c.AS_OF_DATE,
    c.CUSTOMER_NAME,
    c.AGE,
    CASE
      WHEN c.AGE < 30 THEN 'UNDER_30'
      WHEN c.AGE < 40 THEN '30_TO_39'
      WHEN c.AGE < 50 THEN '40_TO_49'
      WHEN c.AGE < 60 THEN '50_TO_59'
      ELSE '60_PLUS'
    END                                                    AS AGE_BAND,
    c.CITY,
    c.SEGMENT,
    c.HOUSEHOLD_SIZE,
    c.TENURE_YEARS,
    CASE
      WHEN c.TENURE_YEARS < 1  THEN 'UNDER_1_YEAR'
      WHEN c.TENURE_YEARS < 3  THEN '1_TO_3_YEARS'
      WHEN c.TENURE_YEARS < 7  THEN '3_TO_7_YEARS'
      ELSE '7_YEARS_PLUS'
    END                                                    AS TENURE_BAND,

    -- Holdings. PRODUCT_COUNT is families, not contracts (source comment).
    c.PRODUCT_COUNT,
    ARRAY_TO_STRING(c.PRODUCTS_HELD, ', ')                 AS PRODUCTS_HELD_LIST,
    c.HAS_HOME_LOAN,
    c.HAS_HOME_INSURANCE,
    c.HAS_HEALTH,
    c.HAS_CARD,
    c.HAS_INVESTMENT,

    -- Value.
    c.ANNUAL_PREMIUM_INR,
    c.OUTSTANDING_CREDIT_INR,
    c.EST_ANNUAL_MARGIN_INR,
    c.RELATIONSHIP_VALUE_BAND,

    -- Risk.
    c.DPD_BUCKET                                           AS WORST_DPD_BUCKET,
    c.MISSED_PAYMENTS_12M,
    c.LAPSE_HISTORY,
    c.CLAIM_RATIO,
    c.CREDIT_UTILISATION,
    c.HARDSHIP_SIGNAL,

    -- Engagement.
    c.INTERACTIONS_90D,
    c.SENTIMENT_NOW,
    c.SENTIMENT_TREND,
    c.OPEN_COMPLAINT,
    c.LAST_CONTACT_DAYS,
    c.PREFERRED_CHANNEL,

    -- Eligibility. Never NULL, all three (source comment on CONSENT_CALL).
    c.CONSENT_CALL,
    c.CONSENT_EMAIL,
    c.CONSENT_SMS,
    c.DNC_FLAG,
    c.VULNERABILITY_FLAG,
    c.KYC_CURRENT,

    /* Cross-sell gaps, scalarised. ARRAY_SIZE is the metric grain;
       the booleans let Analyst filter "customers with a health gap"
       without needing ARRAY_CONTAINS in generated SQL. The nine labels
       are the PRODUCT_GAP / PRODUCTS_HELD shared vocabulary. */
    ARRAY_SIZE(c.PRODUCT_GAP)                              AS PRODUCT_GAP_COUNT,
    ARRAY_TO_STRING(c.PRODUCT_GAP, ', ')                   AS PRODUCT_GAP_LIST,
    ARRAY_CONTAINS('HEALTH'::VARIANT,     c.PRODUCT_GAP)   AS HAS_HEALTH_GAP,
    ARRAY_CONTAINS('TERM_LIFE'::VARIANT,  c.PRODUCT_GAP)   AS HAS_TERM_LIFE_GAP,
    ARRAY_CONTAINS('HOME_INSURANCE'::VARIANT, c.PRODUCT_GAP) AS HAS_HOME_INSURANCE_GAP,
    ARRAY_CONTAINS('INVESTMENT'::VARIANT, c.PRODUCT_GAP)   AS HAS_INVESTMENT_GAP,

    -- Timing.
    c.NEXT_RENEWAL_DATE,
    c.DAYS_TO_RENEWAL,
    c.NEXT_EMI_DATE,

    /* Convenience roll-up of the three consent columns. An OR, not an AND:
       reachable on ANY permitted channel. Kept here rather than in the
       semantic view so the definition is inspectable in DESCRIBE. */
    (c.CONSENT_CALL OR c.CONSENT_EMAIL OR c.CONSENT_SMS)   AS IS_REACHABLE_ANY_CHANNEL,

    /* Customer-level arrears boolean. Added after the eval run in
       evals/analyst_questions.md: asked for "top customers in arrears",
       Analyst had to reconstruct the predicate as
       WORST_DPD_BUCKET NOT IN ('CURRENT', 'NO_CREDIT_OBLIGATION'). It got
       that right, but the reconstruction is the exact place the
       NO_CREDIT_OBLIGATION-is-not-CURRENT trap bites, and asking a model to
       re-derive it on every arrears question is asking to be unlucky once.
       Stated once here instead. */
    (c.DPD_BUCKET NOT IN ('CURRENT', 'NO_CREDIT_OBLIGATION')) AS IS_IN_ARREARS_CUSTOMER
FROM GOLD.CUSTOMER_360 c;


/* ----------------------------------------------------------------------------
   1.2  GOLD.V_SV_POLICY — the insurance book, with the at-risk predicate
   ----------------------------------------------------------------------------
   RAW.POLICY plus product-catalogue attributes, the as-of anchor, and the two
   flags that make S1 RETENTION_SAVE expressible as a metric. The complaint
   half of the predicate is a customer-grain EXISTS, evaluated once in a CTE
   rather than as a correlated subquery per row.
---------------------------------------------------------------------------- */
CREATE OR REPLACE VIEW GOLD.V_SV_POLICY
  COMMENT = 'Feeder view for GOLD.SV_CUSTOMER_360. RAW.POLICY joined to RAW.PRODUCT_CATALOG for product family and line of business, anchored on GOLD.C360_ASOF, carrying the renewal-window and recent-complaint flags that compose the at-risk predicate. One row per policy, all statuses. Presentation shim only.'
AS
WITH anchor AS (
    SELECT AS_OF_DATE FROM GOLD.C360_ASOF
),
recent_complaint AS (
    /* Customers with a complaint raised in the last 60 days. The complaint
       half of the S1 RETENTION_SAVE predicate in docs/DATA_SEGMENTS.md.
       IS_COMPLAINT, not any ticket: requests and queries are not grievances. */
    SELECT DISTINCT t.CUSTOMER_ID
    FROM RAW.SERVICE_TICKET t
    CROSS JOIN anchor a
    WHERE t.IS_COMPLAINT
      AND t.OPENED_AT >= DATEADD(day, -60, a.AS_OF_DATE)
)
SELECT
    p.POLICY_ID,
    p.CUSTOMER_ID,
    a.AS_OF_DATE,
    p.POLICY_NUMBER,
    p.PRODUCT_CODE,
    p.POLICY_TYPE,
    pc.PRODUCT_NAME                                        AS POLICY_PRODUCT_NAME,
    pc.PRODUCT_FAMILY                                      AS POLICY_PRODUCT_FAMILY,
    pc.LINE_OF_BUSINESS                                    AS POLICY_LINE_OF_BUSINESS,
    p.STATUS                                               AS POLICY_STATUS,
    p.PREMIUM_FREQUENCY,
    p.CHANNEL_SOLD,
    p.AGENT_ID,

    p.PREMIUM_INR,
    /* Annualised so premiums across frequencies are summable. Same
       normalisation 08_gold_c360.sql applies for ANNUAL_PREMIUM_INR. */
    p.PREMIUM_INR * CASE p.PREMIUM_FREQUENCY
                      WHEN 'MONTHLY'   THEN 12
                      WHEN 'QUARTERLY' THEN 4
                      WHEN 'HALF_YEARLY' THEN 2
                      ELSE 1
                    END                                    AS ANNUALISED_PREMIUM_INR,
    p.SUM_ASSURED_INR,

    p.START_DATE,
    p.RENEWAL_DATE,
    DATEDIFF(day, a.AS_OF_DATE, p.RENEWAL_DATE)            AS POLICY_DAYS_TO_RENEWAL,
    DATEDIFF(year, p.START_DATE, a.AS_OF_DATE)             AS POLICY_AGE_YEARS,

    (p.STATUS = 'ACTIVE')                                  AS IS_ACTIVE_POLICY,
    /* LAPSE_FLAG, not STATUS = 'LAPSED'. Kept as the source column so the
       churn / attrition / lapse synonym set binds to the recorded event
       rather than to a status string that also carries MATURED and
       SURRENDERED -- neither of which is attrition. */
    p.LAPSE_FLAG                                           AS IS_LAPSED_POLICY,

    (    p.STATUS = 'ACTIVE'
     AND p.RENEWAL_DATE BETWEEN a.AS_OF_DATE
                           AND DATEADD(day, 30, a.AS_OF_DATE)
    )                                                      AS RENEWS_WITHIN_30D,
    (rc.CUSTOMER_ID IS NOT NULL)                           AS HAS_COMPLAINT_LAST_60D,

    /* The S1 RETENTION_SAVE predicate, at policy grain. Both halves, ANDed.
       Measured 420 policies at anchor 2026-08-28. */
    (    p.STATUS = 'ACTIVE'
     AND p.RENEWAL_DATE BETWEEN a.AS_OF_DATE
                           AND DATEADD(day, 30, a.AS_OF_DATE)
     AND rc.CUSTOMER_ID IS NOT NULL
    )                                                      AS IS_AT_RISK_30D
FROM RAW.POLICY p
CROSS JOIN anchor a
LEFT JOIN RAW.PRODUCT_CATALOG pc ON pc.PRODUCT_CODE = p.PRODUCT_CODE
LEFT JOIN recent_complaint rc    ON rc.CUSTOMER_ID  = p.CUSTOMER_ID;


/* ----------------------------------------------------------------------------
   1.3  GOLD.V_SV_LOAN — the lending book and its arrears
   ----------------------------------------------------------------------------
   RAW.LOAN plus catalogue attributes and the anchor. Two things are
   normalised here rather than left to the semantic view:

     - DPD_BUCKET. RAW.LOAN stores the current bucket as '0', but
       CUSTOMER_360 maps that to 'CURRENT'. Two vocabularies for one concept
       would let Analyst filter loans on 'CURRENT' and silently get nothing.
       Mapped to the CUSTOMER_360 vocabulary here so the two agree.
     - ARREARS_OUTSTANDING_INR. Outstanding balance where DPD > 0, else 0, so
       arrears_exposure_inr is a plain SUM and Analyst does not have to
       reconstruct the filter. Measured 521,397,600 INR.
---------------------------------------------------------------------------- */
CREATE OR REPLACE VIEW GOLD.V_SV_LOAN
  COMMENT = 'Feeder view for GOLD.SV_CUSTOMER_360. RAW.LOAN joined to RAW.PRODUCT_CATALOG, anchored on GOLD.C360_ASOF, with DPD_BUCKET remapped from the RAW vocabulary (which stores current as the string 0) to the GOLD.CUSTOMER_360 vocabulary (CURRENT), and a pre-filtered arrears exposure column. One row per loan. Presentation shim only.'
AS
WITH anchor AS (
    SELECT AS_OF_DATE FROM GOLD.C360_ASOF
)
SELECT
    l.LOAN_ID,
    l.CUSTOMER_ID,
    a.AS_OF_DATE,
    l.LOAN_ACCOUNT_NO,
    l.PRODUCT_CODE,
    l.LOAN_TYPE,
    pc.PRODUCT_NAME                                        AS LOAN_PRODUCT_NAME,
    pc.PRODUCT_FAMILY                                      AS LOAN_PRODUCT_FAMILY,
    l.STATUS                                               AS LOAN_STATUS,

    l.PRINCIPAL_INR,
    l.OUTSTANDING_INR,
    l.EMI_INR,
    l.INTEREST_RATE_PCT,
    l.TENURE_MONTHS,
    l.MONTHS_ELAPSED,
    l.DISBURSAL_DATE,
    l.FIRST_EMI_DATE,

    l.DPD_DAYS,
    l.DPD_DAYS_M1,
    l.DPD_DAYS_M2,
    /* RAW '0' -> GOLD 'CURRENT'. See view comment. */
    CASE WHEN l.DPD_BUCKET = '0' THEN 'CURRENT' ELSE l.DPD_BUCKET END AS DPD_BUCKET,
    l.RESTRUCTURE_FLAG                                     AS IS_RESTRUCTURED,

    (l.DPD_DAYS > 0)                                       AS IS_IN_ARREARS,
    /* Exposure at risk: the whole outstanding balance on any loan that is
       even one day late, not the overdue instalment. That is the collections
       reading -- a loan 45 days down puts its full balance in question, not
       one EMI. Named _EXPOSURE for that reason. */
    CASE WHEN l.DPD_DAYS > 0 THEN l.OUTSTANDING_INR ELSE 0 END AS ARREARS_OUTSTANDING_INR,

    /* Rising across three consecutive readings. The S4 COLLECTIONS_HARDSHIP
       DPD half from docs/DATA_SEGMENTS.md; outside that segment the chain is
       non-increasing by construction and cannot fire. */
    (    l.DPD_DAYS_M2 < l.DPD_DAYS_M1
     AND l.DPD_DAYS_M1 < l.DPD_DAYS
    )                                                      AS IS_DPD_RISING
FROM RAW.LOAN l
CROSS JOIN anchor a
LEFT JOIN RAW.PRODUCT_CATALOG pc ON pc.PRODUCT_CODE = l.PRODUCT_CODE;


/* ----------------------------------------------------------------------------
   1.4  GOLD.V_SV_CLAIM — claims, with policy attributes folded in
   ----------------------------------------------------------------------------
   RAW.CLAIM plus the two policy attributes worth slicing claims by. Folded in
   rather than reached by a second relationship, because RAW.CLAIM carries both
   POLICY_ID and CUSTOMER_ID and declaring both routes to the spine is the
   multi-path error described in this file's header.
---------------------------------------------------------------------------- */
CREATE OR REPLACE VIEW GOLD.V_SV_CLAIM
  COMMENT = 'Feeder view for GOLD.SV_CUSTOMER_360. RAW.CLAIM with POLICY_TYPE and PRODUCT_FAMILY denormalised in from RAW.POLICY and RAW.PRODUCT_CATALOG, so claims can be sliced by policy attributes without declaring a second relationship path to the customer spine. One row per claim. Presentation shim only.'
AS
WITH anchor AS (
    SELECT AS_OF_DATE FROM GOLD.C360_ASOF
)
SELECT
    cl.CLAIM_ID,
    cl.CUSTOMER_ID,
    cl.POLICY_ID,
    a.AS_OF_DATE,
    cl.CLAIM_NUMBER,
    cl.CLAIM_TYPE,
    cl.STATUS                                              AS CLAIM_STATUS,

    /* Denormalised from the policy. See view comment. */
    p.POLICY_TYPE                                          AS CLAIM_POLICY_TYPE,
    pc.PRODUCT_FAMILY                                      AS CLAIM_PRODUCT_FAMILY,

    cl.CLAIM_AMOUNT_INR,
    /* NULL on unsettled and rejected claims, which is why the settlement
       ratio metric coalesces rather than assuming zero -- consistent with
       the CLAIM_RATIO comment on GOLD.CUSTOMER_360. */
    cl.APPROVED_AMOUNT_INR,
    COALESCE(cl.APPROVED_AMOUNT_INR, 0)                    AS APPROVED_AMOUNT_INR_ZEROED,

    cl.FILED_AT,
    cl.SETTLED_AT,
    cl.SETTLEMENT_DAYS,
    DATEDIFF(day, cl.FILED_AT::DATE, a.AS_OF_DATE)         AS CLAIM_AGE_DAYS,

    (cl.STATUS = 'SETTLED')                                AS IS_SETTLED_CLAIM,
    (cl.STATUS = 'REJECTED')                               AS IS_REJECTED_CLAIM,
    (cl.STATUS IN ('OPEN', 'IN_REVIEW'))                   AS IS_OPEN_CLAIM
FROM RAW.CLAIM cl
CROSS JOIN anchor a
LEFT JOIN RAW.POLICY p           ON p.POLICY_ID    = cl.POLICY_ID
LEFT JOIN RAW.PRODUCT_CATALOG pc ON pc.PRODUCT_CODE = p.PRODUCT_CODE;


/* ----------------------------------------------------------------------------
   1.5  GOLD.V_SV_CAMPAIGN — the outbound contact log
   ----------------------------------------------------------------------------
   RAW.CAMPAIGN_HISTORY plus catalogue attributes, the anchor, and a month
   bucket. This is the fact that answers "which channel converts" and, more
   importantly for a portfolio owner, "which channel is generating opt-outs and
   complaints" -- OPT_OUT and COMPLAINED are outcomes in this log, and they are
   the cost side of any campaign.
---------------------------------------------------------------------------- */
CREATE OR REPLACE VIEW GOLD.V_SV_CAMPAIGN
  COMMENT = 'Feeder view for GOLD.SV_CUSTOMER_360. RAW.CAMPAIGN_HISTORY joined to RAW.PRODUCT_CATALOG, anchored on GOLD.C360_ASOF, with a contact-month bucket and outcome booleans including the two adverse outcomes (opt-out, complaint). One row per outbound contact. Presentation shim only.'
AS
WITH anchor AS (
    SELECT AS_OF_DATE FROM GOLD.C360_ASOF
)
SELECT
    ch.CAMPAIGN_CONTACT_ID,
    ch.CUSTOMER_ID,
    a.AS_OF_DATE,
    ch.CAMPAIGN_ID,
    ch.CAMPAIGN_NAME,
    ch.PRODUCT_CODE,
    pc.PRODUCT_NAME                                        AS CAMPAIGN_PRODUCT_NAME,
    pc.PRODUCT_FAMILY                                      AS CAMPAIGN_PRODUCT_FAMILY,
    ch.CHANNEL                                             AS CAMPAIGN_CHANNEL,
    ch.OUTCOME                                             AS CAMPAIGN_OUTCOME,
    ch.CONTACTED_AT,
    DATE_TRUNC('month', ch.CONTACTED_AT)::DATE             AS CONTACTED_MONTH,
    DATEDIFF(day, ch.CONTACTED_AT::DATE, a.AS_OF_DATE)     AS DAYS_SINCE_CONTACT,

    ch.CONVERTED_FLAG                                      AS IS_CONVERTED,
    ch.REVENUE_INR,
    (ch.OUTCOME = 'OPT_OUT')                               AS IS_OPT_OUT,
    (ch.OUTCOME = 'COMPLAINED')                            AS IS_COMPLAINT_OUTCOME,
    (ch.OUTCOME = 'NO_RESPONSE')                           AS IS_NO_RESPONSE,
    (ch.OUTCOME IN ('CONVERTED', 'INTERESTED'))            AS IS_ENGAGED
FROM RAW.CAMPAIGN_HISTORY ch
CROSS JOIN anchor a
LEFT JOIN RAW.PRODUCT_CATALOG pc ON pc.PRODUCT_CODE = ch.PRODUCT_CODE;


/* ============================================================================
   PART 2 — THE SEMANTIC VIEW
   ----------------------------------------------------------------------------
   Shape: a flat star. GOLD.V_SV_CUSTOMER is the spine and the only table with
   a declared primary key that anything references; the four facts each declare
   exactly one relationship to it.

   Every object below carries a COMMENT written for a new analyst rather than
   for a maintainer, because Cortex Analyst reads these comments and its answer
   quality is mostly a function of their quality. Where a column has a trap in
   it -- NULL meaning "never happened" rather than zero, a permission that is
   not a preference, an UNKNOWN that must not be read as "stable" -- the
   comment says so in the same words the source column comment uses.
   ============================================================================ */

CREATE OR REPLACE SEMANTIC VIEW GOLD.SV_CUSTOMER_360

  TABLES (
    customers AS GOLD.V_SV_CUSTOMER
      PRIMARY KEY (CUSTOMER_ID)
      WITH SYNONYMS ('customer', 'customers', 'client', 'clients', 'customer 360',
                     'policyholder', 'borrower', 'book of customers', 'people')
      COMMENT = 'The customer spine: one row per customer, 5,000 rows, every customer the group has. Wide by design -- identity, holdings, value, risk, engagement and contact permissions all on one row, so a question about any of them needs no join. Day-counts on this row (days to renewal, last contact days, tenure) were computed against AS_OF_DATE, which is a stored anchor date and not necessarily today; see the as_of_date dimension before quoting them as current.',

    policies AS GOLD.V_SV_POLICY
      PRIMARY KEY (POLICY_ID)
      WITH SYNONYMS ('policy', 'policies', 'insurance policy', 'insurance policies',
                     'cover', 'insurance book', 'insurance contracts', 'contracts')
      COMMENT = 'The insurance book: one row per policy, 8,116 rows, ALL statuses including lapsed, matured and surrendered. Filter on is_active_policy for the live book. A customer may hold several policies, so counts here are policy counts and not customer counts -- use total_customers from the customers table when the question asks how many people.',

    loans AS GOLD.V_SV_LOAN
      PRIMARY KEY (LOAN_ID)
      WITH SYNONYMS ('loan', 'loans', 'lending', 'lending book', 'credit',
                     'borrowing', 'advances', 'loan account', 'loan accounts', 'EMI')
      COMMENT = 'The lending book: one row per loan, 3,219 rows, all currently ACTIVE. Carries arrears state as both a day count (dpd_days) and a bucket (dpd_bucket), plus the two prior monthly readings so a deteriorating trend is a predicate rather than something to reconstruct. A customer may hold several loans.',

    claims AS GOLD.V_SV_CLAIM
      PRIMARY KEY (CLAIM_ID)
      WITH SYNONYMS ('claim', 'claims', 'insurance claim', 'insurance claims',
                     'claim history', 'settlements', 'payouts')
      COMMENT = 'Insurance claims ever filed: one row per claim, 1,621 rows, across open, in-review, settled and rejected. Every claim belongs to a policy, and that policy type and product family are carried on the claim row so claims can be sliced by product without a second join. Approved amount is NULL on anything not yet settled and on rejections.',

    campaigns AS GOLD.V_SV_CAMPAIGN
      PRIMARY KEY (CAMPAIGN_CONTACT_ID)
      WITH SYNONYMS ('campaign', 'campaigns', 'campaign history', 'outbound contact',
                     'outreach', 'contact history', 'marketing', 'marketing history',
                     'contacts made', 'contact log')
      COMMENT = 'The outbound contact log: one row per contact attempt, 24,918 rows, 12 rolling months. Records what was offered, on which channel, and how the customer responded. Outcomes include two adverse ones -- OPT_OUT and COMPLAINED -- which are the cost of contacting, and any read of campaign effectiveness that only counts conversions is incomplete without them.'
  )

  RELATIONSHIPS (
    /* One relationship per fact, all to the spine, no chains. Each fact
       carries CUSTOMER_ID natively. Claims also carry POLICY_ID but a second
       route to the spine through policies would be a multi-path error, so the
       policy attributes claims needs are denormalised into V_SV_CLAIM
       instead -- see this file's header. */
    policies_to_customer  AS policies(CUSTOMER_ID)  REFERENCES customers,
    loans_to_customer     AS loans(CUSTOMER_ID)     REFERENCES customers,
    claims_to_customer    AS claims(CUSTOMER_ID)    REFERENCES customers,
    campaigns_to_customer AS campaigns(CUSTOMER_ID) REFERENCES customers
  )

  FACTS (
    /* ---- customers: row-level numerics on the spine ---- */
    customers.customer_age AS AGE
      WITH SYNONYMS ('age', 'age in years', 'how old')
      COMMENT = 'Customer age in years.',
    customers.household_size AS HOUSEHOLD_SIZE
      WITH SYNONYMS ('household size', 'family size', 'people in household')
      COMMENT = 'Number of people in the customer household.',
    customers.tenure_years AS TENURE_YEARS
      WITH SYNONYMS ('tenure', 'years as a customer', 'relationship length', 'how long a customer')
      COMMENT = 'Years since the customer relationship began, measured to as_of_date.',
    customers.annual_premium_inr AS ANNUAL_PREMIUM_INR
      WITH SYNONYMS ('annual premium', 'premium', 'yearly premium', 'premium paid')
      COMMENT = 'Total annualised premium across the customer active policies, in INR. Premiums on monthly, quarterly and half-yearly policies are annualised first so the figure is comparable across frequencies.',
    customers.outstanding_credit_inr AS OUTSTANDING_CREDIT_INR
      WITH SYNONYMS ('outstanding credit', 'outstanding balance', 'credit outstanding',
                     'debt', 'amount owed', 'balance owed')
      COMMENT = 'Total outstanding balance across the customer active loans and cards, in INR. This is a stock at as_of_date, not a flow.',
    customers.est_annual_margin_inr AS EST_ANNUAL_MARGIN_INR
      WITH SYNONYMS ('relationship value', 'customer value', 'annual margin', 'margin',
                     'estimated margin', 'value of the relationship', 'profitability',
                     'how valuable', 'worth')
      COMMENT = 'Modelled annual margin from the customer, in INR: annualised premium times the product margin rate for active policies, plus outstanding balance times the margin rate for active loans and cards. IMPORTANT -- the credit half is a spread proxy on a stock rather than a measured flow, so this is a quantity for RANKING customers against each other, not a profit-and-loss figure to report as revenue.',
    customers.missed_payments_12m AS MISSED_PAYMENTS_12M
      WITH SYNONYMS ('missed payments', 'missed instalments', 'payments missed',
                     'defaults', 'missed EMIs')
      COMMENT = 'Count of missed instalments, premium or EMI, in the last 12 months.',
    customers.lapse_history AS LAPSE_HISTORY
      WITH SYNONYMS ('lapse history', 'past lapses', 'policies lapsed before',
                     'prior lapses', 'previous churn')
      COMMENT = 'Number of policies this customer has allowed to lapse in the past. A behavioural churn indicator: a customer who has lapsed before is more likely to lapse again.',
    customers.claim_ratio AS CLAIM_RATIO
      WITH SYNONYMS ('claim ratio', 'claims ratio', 'loss ratio', 'recovery ratio')
      COMMENT = 'Approved claim amount over claimed amount, across all claims ever. NULL means the customer has NEVER CLAIMED, which is not the same as 0 -- zero means they claimed and recovered nothing. Do not coalesce NULL to zero when averaging; it would drag the average down with customers who simply never filed.',
    customers.credit_utilisation AS CREDIT_UTILISATION
      WITH SYNONYMS ('credit utilisation', 'credit utilization', 'utilisation',
                     'limit usage', 'card usage', 'how much of the limit is used')
      COMMENT = 'Card balance as a fraction of card limit, 0 to 1. High and rising utilisation is a stress signal.',
    customers.interactions_90d AS INTERACTIONS_90D
      WITH SYNONYMS ('interactions', 'recent interactions', 'contacts in 90 days',
                     'conversations', 'touches')
      COMMENT = 'Number of inbound interactions -- calls and service tickets -- in the 90 days before as_of_date.',
    customers.last_contact_days AS LAST_CONTACT_DAYS
      WITH SYNONYMS ('days since last contact', 'last contact', 'recency',
                     'how long since we spoke', 'days since we spoke')
      COMMENT = 'Days from the customer last interaction to as_of_date. NULL means NEVER CONTACTED -- treat that as unknown recency, not as a very recent or very old contact.',
    customers.product_count AS PRODUCT_COUNT
      WITH SYNONYMS ('products held', 'number of products', 'product count',
                     'how many products', 'holdings')
      COMMENT = 'Number of distinct product FAMILIES the customer holds, not the number of contracts. A customer with three motor policies counts as one.',
    customers.product_gap_count AS PRODUCT_GAP_COUNT
      WITH SYNONYMS ('product gaps', 'gaps', 'cross sell gaps', 'cross-sell gaps',
                     'missing products', 'unmet needs', 'white space', 'opportunities')
      COMMENT = 'Number of products the customer plausibly needs and does not hold. Derived from current holdings, life stage and transaction behaviour, and every entry is gated on not already holding the product. IMPORTANT -- this is a statement about the customer, NOT an eligibility verdict. Income-band and KYC gates are deliberately absent, so a gap here does not mean the customer can lawfully be sold the product.',
    customers.customer_days_to_renewal AS DAYS_TO_RENEWAL
      WITH SYNONYMS ('days to renewal', 'days until renewal', 'renewal in how many days',
                     'time to renewal')
      COMMENT = 'Days from as_of_date to the customer earliest upcoming policy renewal. NULL where the customer holds no policy with a future renewal.',

    /* ---- policies ---- */
    policies.premium_inr AS PREMIUM_INR
      WITH SYNONYMS ('premium', 'policy premium', 'premium amount', 'premium billed')
      COMMENT = 'Premium billed per payment period for this policy, in INR. NOT comparable across policies on its own because the period differs -- a monthly and an annual premium are both stored here. Use annualised_premium_inr to compare or to sum.',
    policies.annualised_premium_inr AS ANNUALISED_PREMIUM_INR
      WITH SYNONYMS ('annualised premium', 'annualized premium', 'annual premium',
                     'yearly premium', 'premium per year')
      COMMENT = 'Premium restated to a full year using the payment frequency, in INR. This is the column to sum or average when comparing premium across the book.',
    policies.sum_assured_inr AS SUM_ASSURED_INR
      WITH SYNONYMS ('sum assured', 'cover', 'coverage', 'cover amount',
                     'sum insured', 'face value', 'how much cover')
      COMMENT = 'The amount the policy would pay out, in INR. The exposure the group carries on this policy.',
    policies.policy_days_to_renewal AS POLICY_DAYS_TO_RENEWAL
      WITH SYNONYMS ('days to renewal', 'days until this policy renews',
                     'renewal in how many days', 'time to renewal')
      COMMENT = 'Days from as_of_date to this policy renewal date. Negative where the renewal date has already passed, which on an ACTIVE policy means the renewal is overdue.',
    policies.policy_age_years AS POLICY_AGE_YEARS
      WITH SYNONYMS ('policy age', 'how old is the policy', 'years since inception',
                     'vintage')
      COMMENT = 'Years from policy start date to as_of_date.',

    /* ---- loans ---- */
    loans.principal_inr AS PRINCIPAL_INR
      WITH SYNONYMS ('principal', 'loan amount', 'amount borrowed', 'original amount',
                     'sanctioned amount', 'disbursed amount')
      COMMENT = 'Amount originally lent, in INR.',
    loans.outstanding_inr AS OUTSTANDING_INR
      WITH SYNONYMS ('outstanding', 'outstanding balance', 'balance', 'amount owed',
                     'remaining balance', 'exposure')
      COMMENT = 'Amount still owed on this loan at as_of_date, in INR. This is total exposure regardless of whether the loan is up to date -- for the overdue subset use arrears_outstanding_inr.',
    loans.arrears_outstanding_inr AS ARREARS_OUTSTANDING_INR
      WITH SYNONYMS ('arrears exposure', 'overdue exposure', 'exposure in arrears',
                     'balance in arrears', 'balance overdue', 'delinquent balance',
                     'money at risk', 'exposure at risk')
      COMMENT = 'Outstanding balance on this loan if it is even one day past due, otherwise zero, in INR. The WHOLE balance, not the overdue instalment -- a loan 45 days down puts its full balance in question, which is the collections reading of exposure. Sum this for portfolio arrears exposure.',
    loans.emi_inr AS EMI_INR
      WITH SYNONYMS ('EMI', 'instalment', 'installment', 'monthly payment',
                     'monthly instalment', 'repayment amount')
      COMMENT = 'Equated monthly instalment due on this loan, in INR.',
    loans.dpd_days AS DPD_DAYS
      WITH SYNONYMS ('DPD', 'days past due', 'days overdue', 'days late',
                     'days in arrears', 'how overdue', 'delinquency days')
      COMMENT = 'Days past due on this loan at as_of_date. Zero means up to date. This is the current reading; dpd_days_previous_month and dpd_days_two_months_ago give the trend.',
    loans.dpd_days_previous_month AS DPD_DAYS_M1
      WITH SYNONYMS ('DPD last month', 'days past due last month', 'previous month DPD',
                     'DPD one month ago')
      COMMENT = 'Days past due one month before as_of_date. Compare with dpd_days to see whether arrears are worsening.',
    loans.dpd_days_two_months_ago AS DPD_DAYS_M2
      WITH SYNONYMS ('DPD two months ago', 'days past due two months ago',
                     'DPD two months back')
      COMMENT = 'Days past due two months before as_of_date. Together with the other two readings this makes a rising-arrears trend a simple comparison.',
    loans.interest_rate_pct AS INTEREST_RATE_PCT
      WITH SYNONYMS ('interest rate', 'rate', 'rate of interest', 'APR')
      COMMENT = 'Annual interest rate on this loan, as a percentage.',
    loans.tenure_months AS TENURE_MONTHS
      WITH SYNONYMS ('tenure', 'loan term', 'term', 'term in months', 'loan tenure')
      COMMENT = 'Full loan term in months.',
    loans.months_elapsed AS MONTHS_ELAPSED
      WITH SYNONYMS ('months elapsed', 'months paid', 'months into the loan',
                     'instalments paid')
      COMMENT = 'Months of the term already elapsed at as_of_date.',

    /* ---- claims ---- */
    claims.claim_amount_inr AS CLAIM_AMOUNT_INR
      WITH SYNONYMS ('claim amount', 'amount claimed', 'claimed', 'claim value',
                     'how much was claimed')
      COMMENT = 'Amount the customer claimed, in INR. Always populated.',
    claims.approved_amount_inr AS APPROVED_AMOUNT_INR
      WITH SYNONYMS ('approved amount', 'amount approved', 'amount paid',
                     'settled amount', 'payout')
      COMMENT = 'Amount approved and paid, in INR. NULL on anything not yet settled and on rejections -- NULL means no decision or no payout, not a zero payout. Use total_approved_inr, which zeroes these, when computing a settlement ratio across the book.',
    claims.settlement_days AS SETTLEMENT_DAYS
      WITH SYNONYMS ('settlement days', 'days to settle', 'settlement time',
                     'turnaround', 'how long to settle', 'TAT')
      COMMENT = 'Days from filing to settlement. NULL while the claim is still open or in review, and on rejections.',
    claims.claim_age_days AS CLAIM_AGE_DAYS
      WITH SYNONYMS ('claim age', 'days since filed', 'how old is the claim',
                     'age of claim')
      COMMENT = 'Days from filing to as_of_date. On an open claim this is how long the customer has been waiting.',

    /* ---- campaigns ---- */
    campaigns.revenue_inr AS REVENUE_INR
      WITH SYNONYMS ('revenue', 'campaign revenue', 'revenue generated',
                     'income', 'sales value')
      COMMENT = 'Revenue attributed to this contact, in INR. Zero on every outcome except a conversion.',
    campaigns.days_since_contact AS DAYS_SINCE_CONTACT
      WITH SYNONYMS ('days since contact', 'how long ago was the contact',
                     'contact recency', 'days ago')
      COMMENT = 'Days from this contact attempt to as_of_date.'
  )

  DIMENSIONS (
    /* ---- customers: identity ---- */
    customers.as_of_date AS AS_OF_DATE
      WITH SYNONYMS ('as of date', 'as-of date', 'data date', 'snapshot date',
                     'reporting date', 'anchor date', 'current as of')
      COMMENT = 'The calendar anchor every day-count in this model was computed against. READ THIS BEFORE TREATING ANY DAY-COUNT AS CURRENT. It is a stored date, refreshed daily in normal operation, but a long gap with no data movement leaves it behind today rather than tracking it. Every "days to", "days since" and "within 30 days" figure in this model is measured from here, not from today.',
    customers.customer_id AS CUSTOMER_ID
      WITH SYNONYMS ('customer id', 'customer number', 'client id', 'id')
      COMMENT = 'Unique customer identifier. The join key every fact in this model shares.',
    customers.customer_name AS CUSTOMER_NAME
      WITH SYNONYMS ('name', 'customer name', 'client name', 'who')
      COMMENT = 'Customer full name. Synthetic data -- Indian names throughout.',
    customers.city AS CITY
      WITH SYNONYMS ('city', 'location', 'where', 'town', 'geography', 'branch city')
      COMMENT = 'City the customer is resident in. 20 Indian cities.',
    customers.segment AS SEGMENT
      WITH SYNONYMS ('segment', 'customer segment', 'wealth segment', 'tier',
                     'customer tier', 'banding')
      COMMENT = 'Wealth segment assigned by the bank: MASS, MASS_AFFLUENT, AFFLUENT, PRIORITY, HNI. An input to the relationship, not an output of it -- for value delivered use relationship_value_band, which is computed from actual margin.',
    customers.age_band AS AGE_BAND
      WITH SYNONYMS ('age band', 'age group', 'age bracket', 'age range', 'generation')
      COMMENT = 'Age bucketed: UNDER_30, 30_TO_39, 40_TO_49, 50_TO_59, 60_PLUS.',
    customers.tenure_band AS TENURE_BAND
      WITH SYNONYMS ('tenure band', 'tenure group', 'tenure bracket',
                     'how long a customer band', 'relationship length band')
      COMMENT = 'Tenure bucketed: UNDER_1_YEAR, 1_TO_3_YEARS, 3_TO_7_YEARS, 7_YEARS_PLUS.',

    /* ---- customers: value ---- */
    customers.relationship_value_band AS RELATIONSHIP_VALUE_BAND
      WITH SYNONYMS ('relationship value band', 'value band', 'value tier',
                     'customer value band', 'platinum gold silver bronze',
                     'how valuable a customer', 'value segment')
      COMMENT = 'Fixed INR thresholds on estimated annual margin: PLATINUM at or above 150,000, GOLD at or above 75,000, SILVER at or above 25,000, BRONZE above zero, NO_ACTIVE_HOLDINGS otherwise. Calibrated on the measured distribution so PLATINUM is roughly the top decile. Distinct from segment, which is an assigned wealth tier rather than a measured one.',

    /* ---- customers: holdings and gaps ---- */
    customers.products_held_list AS PRODUCTS_HELD_LIST
      WITH SYNONYMS ('products held', 'what they hold', 'holdings',
                     'products owned', 'current products')
      COMMENT = 'Comma-separated list of product families currently held, active contracts only.',
    customers.product_gap_list AS PRODUCT_GAP_LIST
      WITH SYNONYMS ('product gaps', 'gap list', 'missing products',
                     'what they are missing', 'cross sell opportunities')
      COMMENT = 'Comma-separated list of products the customer plausibly needs and does not hold. A need statement, not an eligibility verdict -- see the product_gap_count fact.',
    customers.has_home_loan AS HAS_HOME_LOAN
      WITH SYNONYMS ('has a home loan', 'has mortgage', 'holds a home loan',
                     'home loan customer', 'mortgage holder')
      COMMENT = 'True if the customer holds an active home loan.',
    customers.has_home_insurance AS HAS_HOME_INSURANCE
      WITH SYNONYMS ('has home insurance', 'holds home insurance',
                     'home cover', 'property insurance')
      COMMENT = 'True if the customer holds an active home insurance policy.',
    customers.has_health_cover AS HAS_HEALTH
      WITH SYNONYMS ('has health insurance', 'holds health cover', 'health cover',
                     'medical insurance', 'health insured')
      COMMENT = 'True if the customer holds an active health insurance policy.',
    customers.has_card AS HAS_CARD
      WITH SYNONYMS ('has a credit card', 'holds a card', 'card holder', 'cardholder')
      COMMENT = 'True if the customer holds an active credit card.',
    customers.has_investment AS HAS_INVESTMENT
      WITH SYNONYMS ('has investments', 'holds investments', 'investment customer',
                     'wealth customer', 'invested')
      COMMENT = 'True if the customer holds an active investment or ULIP product.',
    customers.has_health_gap AS HAS_HEALTH_GAP
      WITH SYNONYMS ('health gap', 'needs health insurance', 'missing health cover',
                     'health insurance opportunity', 'uninsured for health')
      COMMENT = 'True if health insurance is a plausible unmet need for this customer. A need, not an eligibility verdict.',
    customers.has_term_life_gap AS HAS_TERM_LIFE_GAP
      WITH SYNONYMS ('term life gap', 'needs term life', 'missing life cover',
                     'protection gap', 'life insurance opportunity')
      COMMENT = 'True if term life cover is a plausible unmet need for this customer. A need, not an eligibility verdict.',
    customers.has_home_insurance_gap AS HAS_HOME_INSURANCE_GAP
      WITH SYNONYMS ('home insurance gap', 'needs home insurance',
                     'missing home cover', 'unprotected property')
      COMMENT = 'True if home insurance is a plausible unmet need -- typically a customer with a home loan and no cover on the property. A need, not an eligibility verdict.',
    customers.has_investment_gap AS HAS_INVESTMENT_GAP
      WITH SYNONYMS ('investment gap', 'needs investments', 'wealth opportunity',
                     'wealth referral candidate', 'missing investments')
      COMMENT = 'True if an investment product is a plausible unmet need for this customer. A need, not an eligibility verdict.',

    /* ---- customers: risk ---- */
    customers.worst_dpd_bucket AS WORST_DPD_BUCKET
      WITH SYNONYMS ('worst arrears bucket', 'worst DPD bucket', 'customer arrears status',
                     'worst overdue bucket', 'customer DPD', 'arrears status',
                     'worst delinquency bucket')
      COMMENT = 'Worst arrears bucket across all the customer active loans: CURRENT, 1-30, 31-60, 61-90, or NO_CREDIT_OBLIGATION. NO_CREDIT_OBLIGATION IS NOT THE SAME AS CURRENT -- one customer has no borrowing at all, the other has borrowing and is up to date. Do not group them. For per-loan arrears use dpd_bucket on the loans table.',
    customers.is_in_arrears_customer AS IS_IN_ARREARS_CUSTOMER
      WITH SYNONYMS ('customer in arrears', 'customers in arrears', 'in arrears',
                     'overdue customer', 'customer is overdue', 'behind on payments',
                     'delinquent customer', 'customer is late', 'customer past due')
      COMMENT = 'True if ANY of the customer active loans is at least one day past due. The customer-level arrears filter -- use this rather than reconstructing a predicate on worst_dpd_bucket, because it already handles the trap that NO_CREDIT_OBLIGATION (no borrowing at all) must not be grouped with CURRENT (borrowing, up to date). False for customers with no borrowing.',
    customers.has_hardship_signal AS HARDSHIP_SIGNAL
      WITH SYNONYMS ('hardship', 'financial hardship', 'hardship signal', 'in difficulty',
                     'financial stress', 'struggling', 'distress', 'vulnerable to hardship')
      COMMENT = 'True on any of four arms: arrears rising across three consecutive monthly readings, two or more missed instalments in six months, a restructured loan, or hardship raised in conversation in the last 90 days. Deliberately broad, because it routes a customer to service instead of sales -- a false positive costs one cross-sell, a false negative means marketing to somebody in difficulty. Treat this as a stop signal for any sales action.',
    customers.is_vulnerable AS VULNERABILITY_FLAG
      WITH SYNONYMS ('vulnerable', 'vulnerable customer', 'vulnerability',
                     'flagged vulnerable', 'at-risk customer', 'needs extra care')
      COMMENT = 'True if the customer is on the vulnerability register -- age, health, capacity or circumstance. A conduct constraint: vulnerable customers must not be marketed products flagged as unsuitable for them.',

    /* ---- customers: engagement and churn ---- */
    customers.sentiment_now AS SENTIMENT_NOW
      WITH SYNONYMS ('sentiment', 'current sentiment', 'mood', 'how they feel',
                     'tone', 'customer sentiment', 'happy or unhappy')
      COMMENT = 'Sentiment of the customer most recent interaction: positive, neutral, negative or mixed. Derived from what they actually said, in calls and tickets. NULL where the customer has never been in contact.',
    customers.sentiment_trend AS SENTIMENT_TREND
      WITH SYNONYMS ('sentiment trend', 'trend', 'getting better or worse',
                     'relationship trajectory', 'direction of travel', 'souring',
                     'deteriorating relationship', 'churn signal', 'attrition signal')
      COMMENT = 'Direction of travel in the customer sentiment: DETERIORATING, STABLE, IMPROVING, INSUFFICIENT_DATA or NO_CONTACT_HISTORY. CRITICAL -- INSUFFICIENT_DATA and NO_CONTACT_HISTORY both mean UNKNOWN and MUST NOT be counted as STABLE. A customer with one angry interaction has no trend, and reporting that as stable reads a deteriorating relationship as a calm one. When asked how many customers are stable, count STABLE only; when asked how many are not deteriorating, say explicitly how many are unknown.',
    customers.has_open_complaint AS OPEN_COMPLAINT
      WITH SYNONYMS ('open complaint', 'has a complaint', 'complaining',
                     'unresolved complaint', 'live grievance', 'grievance',
                     'outstanding complaint')
      COMMENT = 'True if the customer has a service complaint still open. A complaint plus an approaching renewal is the classic retention risk -- see the policies_at_risk_30d metric.',
    customers.preferred_channel AS PREFERRED_CHANNEL
      WITH SYNONYMS ('preferred channel', 'best channel', 'channel preference',
                     'how to reach them', 'which channel works')
      COMMENT = 'The channel that has historically produced engagement from this customer -- a conversion or an expression of interest. A BEHAVIOURAL PREFERENCE AND NOT A PERMISSION. Always check the matching consent dimension before acting on it; the customer preferred channel may be one they have since withdrawn consent for.',

    /* ---- customers: permission ---- */
    customers.has_consent_call AS CONSENT_CALL
      WITH SYNONYMS ('consent to call', 'can we call', 'call consent',
                     'phone consent', 'allowed to call', 'call permission')
      COMMENT = 'Permission to contact by call at as_of_date: opted in AND not on the do-not-call registry AND inside the consent validity window, all three together. Never NULL. This is the authoritative answer to "can we call this customer".',
    customers.has_consent_email AS CONSENT_EMAIL
      WITH SYNONYMS ('consent to email', 'can we email', 'email consent',
                     'allowed to email', 'email permission')
      COMMENT = 'Permission to contact by email at as_of_date, folding opt-in, registry status and validity window together. Never NULL.',
    customers.has_consent_sms AS CONSENT_SMS
      WITH SYNONYMS ('consent to SMS', 'can we text', 'SMS consent', 'text consent',
                     'allowed to text', 'SMS permission')
      COMMENT = 'Permission to contact by SMS at as_of_date, folding opt-in, registry status and validity window together. Never NULL.',
    customers.is_on_dnc_registry AS DNC_FLAG
      WITH SYNONYMS ('DNC', 'do not contact', 'do-not-contact', 'do not call',
                     'on the DNC list', 'opted out', 'suppressed')
      COMMENT = 'Do-not-contact registry marker on the call or SMS channel -- the channels a registry governs in this market. 1,330 customers, 27 percent. NOT an any-channel reading, which would flag 46 percent and stop discriminating. For a specific channel the authoritative columns are the three consent dimensions, which already fold this in.',
    customers.is_reachable_any_channel AS IS_REACHABLE_ANY_CHANNEL
      WITH SYNONYMS ('reachable', 'contactable', 'can we contact them',
                     'permitted to contact', 'any channel available')
      COMMENT = 'True if the customer can lawfully be contacted on AT LEAST ONE of call, email or SMS. An OR across the three consent dimensions. The right filter for "how much of the book can we actually talk to".',
    customers.is_kyc_current AS KYC_CURRENT
      WITH SYNONYMS ('KYC current', 'KYC valid', 'KYC done', 'KYC status',
                     'identity verified', 'KYC compliant', 'KYC up to date')
      COMMENT = 'True if the customer identity documentation is current. Stale KYC blocks new product sales regardless of any other signal.',

    /* ---- customers: timing ---- */
    customers.next_renewal_date AS NEXT_RENEWAL_DATE
      WITH SYNONYMS ('next renewal date', 'renewal date', 'when do they renew',
                     'upcoming renewal')
      COMMENT = 'Date of the customer earliest upcoming policy renewal. NULL where they hold no policy with a future renewal.',
    customers.next_emi_date AS NEXT_EMI_DATE
      WITH SYNONYMS ('next EMI date', 'next instalment date', 'next payment due',
                     'when is the next EMI')
      COMMENT = 'Projected date of the customer next loan instalment, from the loan schedule. NULL past the final instalment or where they hold no loan.',

    /* ---- policies ---- */
    policies.policy_number AS POLICY_NUMBER
      WITH SYNONYMS ('policy number', 'policy reference', 'policy no')
      COMMENT = 'Human-readable policy reference.',
    policies.policy_type AS POLICY_TYPE
      WITH SYNONYMS ('policy type', 'type of policy', 'type of insurance',
                     'kind of cover', 'insurance type', 'motor health term home ULIP')
      COMMENT = 'What the policy covers: motor, health, term life, home or ULIP.',
    policies.policy_product_family AS POLICY_PRODUCT_FAMILY
      WITH SYNONYMS ('product family', 'policy product family', 'product group',
                     'family of product')
      COMMENT = 'Product family the policy belongs to, from the product catalogue.',
    policies.policy_line_of_business AS POLICY_LINE_OF_BUSINESS
      WITH SYNONYMS ('line of business', 'LOB', 'business line', 'division',
                     'insurance or banking', 'which side of the group')
      COMMENT = 'Which side of the group the policy sits on -- insurance or banking. The group is a bank and an insurer, and this separates the two books.',
    policies.policy_status AS POLICY_STATUS
      WITH SYNONYMS ('policy status', 'status', 'state of the policy',
                     'active or lapsed', 'is it in force')
      COMMENT = 'ACTIVE, LAPSED, MATURED or SURRENDERED. Only ACTIVE is in force. Note that all four appear in this table -- an unfiltered policy count includes policies that ended.',
    policies.is_active_policy AS IS_ACTIVE_POLICY
      WITH SYNONYMS ('active policy', 'in force', 'live policy', 'current policy',
                     'still active')
      COMMENT = 'True if the policy is in force. The filter for any question about the live book.',
    policies.is_lapsed_policy AS IS_LAPSED_POLICY
      WITH SYNONYMS ('lapse', 'lapsed', 'lapsed policy', 'churn', 'churned',
                     'attrition', 'attrited', 'not renewed', 'failed to renew',
                     'let it lapse', 'dropped out', 'left us', 'cancelled')
      COMMENT = 'True if the policy lapsed -- the customer stopped paying and cover ended. THIS IS WHAT CHURN AND ATTRITION MEAN IN THIS MODEL. Deliberately taken from the recorded lapse event rather than from policy status, because status also carries MATURED and SURRENDERED, and neither of those is churn: a matured policy ran its full term successfully, and a surrender is a deliberate exit on the customer terms. Counting either as churn overstates attrition.',
    policies.renews_within_30d AS RENEWS_WITHIN_30D
      WITH SYNONYMS ('renewing soon', 'renews within 30 days', 'renewal coming up',
                     'due for renewal', 'renewal window', 'upcoming renewal')
      COMMENT = 'True if the policy is active and its renewal date falls within 30 days of as_of_date. Timing only -- this says nothing about whether the renewal is in doubt. For renewals in doubt use is_at_risk_30d.',
    policies.has_complaint_last_60d AS HAS_COMPLAINT_LAST_60D
      WITH SYNONYMS ('recent complaint', 'complained recently',
                     'complaint in the last 60 days', 'recent grievance')
      COMMENT = 'True if the customer holding this policy raised a complaint in the 60 days before as_of_date. Customer-level, so it is true on every policy that customer holds.',
    policies.is_at_risk_30d AS IS_AT_RISK_30D
      WITH SYNONYMS ('at risk', 'at-risk policy', 'renewal at risk',
                     'retention risk', 'likely to lapse', 'in danger of lapsing',
                     'needs saving', 'retention save', 'renewal in doubt')
      COMMENT = 'True if the policy is active, renews within 30 days, AND the customer complained in the last 60 days. Both halves together -- an approaching renewal alone is just the calendar, and roughly one policy in twelve renews in any 30-day window. This is the retention-save population: the correct action is to KEEP the customer, and a cross-sell recommendation to anybody in here is a ranking failure. 420 policies at the current anchor. NOTE this is POLICY-level and forward-looking. It is not the same thing as a customer-level churn signal (see sentiment_trend) and not the same thing as a lapse that has already happened (see is_lapsed_policy).',
    policies.premium_frequency AS PREMIUM_FREQUENCY
      WITH SYNONYMS ('premium frequency', 'payment frequency', 'how often they pay',
                     'billing frequency', 'payment mode')
      COMMENT = 'How often premium falls due: MONTHLY, QUARTERLY, HALF_YEARLY or ANNUAL. This is why raw premium is not comparable across policies.',
    policies.channel_sold AS CHANNEL_SOLD
      WITH SYNONYMS ('channel sold', 'sales channel', 'sold through',
                     'origination channel', 'where it was sold', 'acquisition channel')
      COMMENT = 'The channel the policy was originally sold through. An origination attribute, unrelated to which channel the customer may now be contacted on.',
    policies.agent_id AS AGENT_ID
      WITH SYNONYMS ('agent', 'agent id', 'who sold it', 'selling agent', 'adviser')
      COMMENT = 'Identifier of the agent who sold the policy.',

    /* ---- loans ---- */
    loans.loan_account_no AS LOAN_ACCOUNT_NO
      WITH SYNONYMS ('loan account number', 'loan account', 'account number',
                     'loan reference')
      COMMENT = 'Human-readable loan account reference.',
    loans.loan_type AS LOAN_TYPE
      WITH SYNONYMS ('loan type', 'type of loan', 'kind of loan',
                     'home auto personal', 'lending product')
      COMMENT = 'What the loan is for: home, auto, personal and so on.',
    loans.loan_product_family AS LOAN_PRODUCT_FAMILY
      WITH SYNONYMS ('loan product family', 'lending product family',
                     'loan product group')
      COMMENT = 'Product family the loan belongs to, from the product catalogue.',
    loans.loan_status AS LOAN_STATUS
      WITH SYNONYMS ('loan status', 'status of the loan', 'is the loan open')
      COMMENT = 'Loan status. Every loan in this table is currently ACTIVE, so this does not discriminate -- for loan health use dpd_bucket or is_in_arrears instead.',
    loans.dpd_bucket AS DPD_BUCKET
      WITH SYNONYMS ('arrears', 'arrears bucket', 'overdue', 'overdue bucket',
                     'DPD', 'DPD bucket', 'days past due', 'days past due bucket',
                     'delinquency', 'delinquency bucket', 'late bucket',
                     'how late', 'ageing bucket', 'aging bucket')
      COMMENT = 'Arrears bucket for this loan: CURRENT, 1-30, 31-60 or 61-90 days past due. THE STANDARD WAY TO ASK ABOUT ARREARS, OVERDUE OR DPD IN THIS MODEL. Note this is per loan -- a customer with two loans appears in two buckets, so for a customer-level reading use worst_dpd_bucket on the customers table instead. WHEN BREAKING ANYTHING DOWN BY THIS BUCKET, include total_outstanding_inr and not only arrears_exposure_inr: arrears exposure is zero by construction in the CURRENT bucket, so a bucket breakdown showing arrears exposure alone reports the 2,654 up-to-date loans as carrying no balance, which is wrong by a wide margin.',
    loans.is_in_arrears AS IS_IN_ARREARS
      WITH SYNONYMS ('in arrears', 'overdue', 'late', 'behind on payments',
                     'delinquent', 'not paying', 'past due', 'defaulting')
      COMMENT = 'True if the loan is at least one day past due. The filter behind arrears_exposure_inr and loans_in_arrears.',
    loans.is_restructured AS IS_RESTRUCTURED
      WITH SYNONYMS ('restructured', 'restructured loan', 'reworked',
                     'terms changed', 'rescheduled', 'forbearance')
      COMMENT = 'True if the loan terms were renegotiated because the customer could not meet the original schedule. A hardship marker that persists after the arrears themselves clear.',
    loans.is_dpd_rising AS IS_DPD_RISING
      WITH SYNONYMS ('DPD rising', 'arrears worsening', 'getting worse',
                     'deteriorating arrears', 'arrears increasing',
                     'worsening delinquency', 'slipping')
      COMMENT = 'True if days past due increased across three consecutive monthly readings. A trajectory, not a level -- a loan at 40 days and rising is a different problem from one at 40 days and falling, and this separates them. One of the four arms of the customer hardship signal.',

    /* ---- claims ---- */
    claims.claim_number AS CLAIM_NUMBER
      WITH SYNONYMS ('claim number', 'claim reference', 'claim no')
      COMMENT = 'Human-readable claim reference.',
    claims.claim_type AS CLAIM_TYPE
      WITH SYNONYMS ('claim type', 'type of claim', 'kind of claim', 'what was claimed for')
      COMMENT = 'What the claim was for.',
    claims.claim_status AS CLAIM_STATUS
      WITH SYNONYMS ('claim status', 'status of the claim', 'where is the claim',
                     'settled or open')
      COMMENT = 'OPEN, IN_REVIEW, SETTLED or REJECTED. Only SETTLED has a payout; the other three have a NULL approved amount.',
    claims.is_settled_claim AS IS_SETTLED_CLAIM
      WITH SYNONYMS ('settled', 'settled claim', 'paid out', 'claim paid', 'closed and paid')
      COMMENT = 'True if the claim was settled and paid.',
    claims.is_rejected_claim AS IS_REJECTED_CLAIM
      WITH SYNONYMS ('rejected', 'rejected claim', 'declined claim', 'refused',
                     'turned down', 'repudiated')
      COMMENT = 'True if the claim was rejected. A rejection is a strong dissatisfaction driver and often precedes a complaint or a lapse.',
    claims.is_open_claim AS IS_OPEN_CLAIM
      WITH SYNONYMS ('open claim', 'pending claim', 'unsettled claim',
                     'claim in progress', 'awaiting settlement', 'in review')
      COMMENT = 'True if the claim is still open or in review, that is, the customer is waiting. Combine with claim_age_days to find customers who have been waiting a long time.',
    claims.claim_policy_type AS CLAIM_POLICY_TYPE
      WITH SYNONYMS ('policy type of the claim', 'claim policy type',
                     'which policy type claimed', 'product claimed on')
      COMMENT = 'Policy type the claim was filed against, carried on the claim row so claims can be sliced by product without a second join.',
    claims.claim_product_family AS CLAIM_PRODUCT_FAMILY
      WITH SYNONYMS ('claim product family', 'product family of the claim')
      COMMENT = 'Product family the claimed policy belongs to.',

    /* ---- campaigns ---- */
    campaigns.campaign_id AS CAMPAIGN_ID
      WITH SYNONYMS ('campaign id', 'campaign code', 'campaign reference')
      COMMENT = 'Campaign identifier.',
    campaigns.campaign_name AS CAMPAIGN_NAME
      WITH SYNONYMS ('campaign', 'campaign name', 'which campaign', 'offer name')
      COMMENT = 'Human-readable campaign name.',
    campaigns.campaign_channel AS CAMPAIGN_CHANNEL
      WITH SYNONYMS ('channel', 'campaign channel', 'contact channel',
                     'which channel', 'medium', 'how they were contacted',
                     'SMS email call WhatsApp')
      COMMENT = 'Channel the contact attempt was made on: SMS, EMAIL, CALL or WHATSAPP. The channel actually USED -- distinct from preferred_channel, which is where the customer responds best, and from the consent dimensions, which govern where contact is permitted.',
    campaigns.campaign_outcome AS CAMPAIGN_OUTCOME
      WITH SYNONYMS ('outcome', 'campaign outcome', 'result', 'response',
                     'what happened', 'how did they respond')
      COMMENT = 'How the customer responded: CONVERTED, INTERESTED, DECLINED, NO_RESPONSE, OPT_OUT or COMPLAINED. The last two are adverse -- contacting somebody has a cost, and a channel with a high conversion rate and a high opt-out rate is not obviously a good channel.',
    campaigns.campaign_product_family AS CAMPAIGN_PRODUCT_FAMILY
      WITH SYNONYMS ('campaign product family', 'what was offered',
                     'product offered', 'offer product family')
      COMMENT = 'Product family that was offered in this contact.',
    campaigns.contacted_month AS CONTACTED_MONTH
      WITH SYNONYMS ('month', 'contact month', 'month contacted', 'when',
                     'by month', 'monthly')
      COMMENT = 'Month the contact was made, truncated to the first of the month. The time grain for any campaign trend question. Covers 12 rolling months.',
    campaigns.contacted_at AS CONTACTED_AT
      WITH SYNONYMS ('contacted at', 'contact date', 'contact timestamp',
                     'when were they contacted', 'date of contact')
      COMMENT = 'Exact timestamp of the contact attempt.',
    campaigns.is_converted AS IS_CONVERTED
      WITH SYNONYMS ('converted', 'sale made', 'bought', 'accepted',
                     'took the offer', 'successful contact')
      COMMENT = 'True if the contact resulted in a sale.',
    campaigns.is_engaged AS IS_ENGAGED
      WITH SYNONYMS ('engaged', 'responded positively', 'showed interest',
                     'interested or converted', 'positive response')
      COMMENT = 'True if the customer converted OR expressed interest. A softer success measure than conversion, and the one behind preferred_channel.',
    campaigns.is_opt_out AS IS_OPT_OUT
      WITH SYNONYMS ('opted out', 'opt out', 'unsubscribed', 'asked us to stop',
                     'withdrew consent', 'adverse outcome')
      COMMENT = 'True if the customer used this contact to opt out of future contact. An adverse outcome: it permanently reduces the reachable book, so it is a real cost of campaigning and not a neutral non-response.',
    campaigns.is_complaint_outcome AS IS_COMPLAINT_OUTCOME
      WITH SYNONYMS ('complained about the contact', 'complaint outcome',
                     'contact generated a complaint', 'adverse outcome')
      COMMENT = 'True if the customer complained in response to being contacted. The most adverse campaign outcome there is.',
    campaigns.is_no_response AS IS_NO_RESPONSE
      WITH SYNONYMS ('no response', 'did not respond', 'no reply', 'ignored',
                     'unanswered')
      COMMENT = 'True if the contact attempt got no response at all.'
  )

  METRICS (
    /* ======================================================================
       THE SIX HEADLINE METRICS
       Named exactly as the business asks for them. Reference values at
       anchor 2026-08-28 are in each comment so a wrong answer is visible.
       ====================================================================== */

    customers.total_customers AS COUNT(DISTINCT customers.CUSTOMER_ID)
      WITH SYNONYMS ('total customers', 'number of customers', 'customer count',
                     'how many customers', 'headcount', 'size of the book',
                     'book size', 'how many clients', 'number of clients')
      COMMENT = 'Distinct customers. Use this whenever the question asks how many PEOPLE, even if the filter is on a policy or a loan -- a customer with three policies is one customer. 5,000 across the whole book.',

    customers.avg_relationship_value AS AVG(customers.EST_ANNUAL_MARGIN_INR)
      WITH SYNONYMS ('average relationship value', 'avg relationship value',
                     'average customer value', 'mean customer value',
                     'average margin', 'average value per customer',
                     'typical customer value', 'value per customer')
      COMMENT = 'Mean estimated annual margin per customer, in INR. 56,574 across the whole book. The distribution is heavily skewed -- median is about 29,500 -- so the mean sits well above the typical customer. If the question is about a typical customer rather than a portfolio total, say so, and consider reporting the band mix from relationship_value_band alongside this.',

    policies.policies_at_risk_30d AS COUNT_IF(policies.IS_AT_RISK_30D)
      WITH SYNONYMS ('policies at risk', 'at risk policies', 'policies at risk in 30 days',
                     'retention risk', 'renewals at risk', 'policies likely to lapse',
                     'retention saves needed', 'policies needing intervention',
                     'renewals in doubt')
      COMMENT = 'Active policies that renew within 30 days of as_of_date AND whose customer complained in the last 60 days. 420 policies, held by 400 customers. Both halves matter: about one policy in twelve renews in any 30-day window, so the renewal alone is the calendar rather than a risk. This is the retention-save population -- the right action is to keep the customer, and recommending a cross-sell to anybody in it is a ranking failure. Counts POLICIES; for the number of people use total_customers filtered on the same condition. DO NOT use this for a question about customers showing churn signals -- that is customers_deteriorating, a different grain and a different signal entirely.',

    policies.lapse_rate AS COUNT_IF(policies.IS_LAPSED_POLICY) / NULLIF(COUNT(policies.POLICY_ID), 0)
      WITH SYNONYMS ('lapse rate', 'lapsed rate', 'churn rate', 'attrition rate',
                     'rate of lapse', 'percentage lapsed', 'percent churned',
                     'how much churn', 'churn', 'attrition')
      COMMENT = 'Lapsed policies as a fraction of all policies. 0.0832, that is 8.3 percent -- 675 lapsed of 8,116. Report it as a percentage. THE DENOMINATOR IS ALL POLICIES, including matured and surrendered ones, so this is a lifetime lapse rate over the whole book rather than an annual rate. A matured policy is not churn (it ran its term) and neither is a surrender (a deliberate exit), so only recorded lapses count in the numerator. Break this down by policy_type, city or channel_sold to find where cover is being lost.',

    customers.cross_sell_gap_count AS SUM(customers.PRODUCT_GAP_COUNT)
      WITH SYNONYMS ('cross sell gaps', 'cross-sell gap count', 'total product gaps',
                     'number of gaps', 'cross sell opportunities',
                     'total opportunities', 'white space', 'unmet needs',
                     'how many gaps', 'sales opportunities')
      COMMENT = 'Total count of product gaps across customers -- the size of the cross-sell opportunity in units, not rupees. 7,855 gaps across 5,000 customers. IMPORTANT -- a gap is a statement that the customer plausibly needs a product they do not hold. It is NOT an eligibility verdict: income-band, KYC and vulnerability gates are deliberately not applied here, so the number of gaps that can lawfully be acted on is smaller. When answering, do not describe these as customers who can be sold to.',

    loans.arrears_exposure_inr AS SUM(loans.ARREARS_OUTSTANDING_INR)
      WITH SYNONYMS ('arrears exposure', 'arrears exposure in INR', 'overdue exposure',
                     'exposure in arrears', 'money at risk', 'amount in arrears',
                     'delinquent exposure', 'DPD exposure', 'total overdue',
                     'balance at risk', 'value in arrears')
      COMMENT = 'Total outstanding balance on loans that are at least one day past due, in INR. 521,397,600 -- about 52.1 crore. This is the WHOLE balance of every late loan, not the sum of overdue instalments: a loan 45 days down puts its full balance in question, which is how collections reads exposure. If somebody asks for the value of missed payments rather than the exposure they are asking a different question, and this is not it.',

    /* ======================================================================
       SUPPORTING METRICS
       Not on the headline list, but a portfolio question that gets one of
       the six almost always needs a denominator or a companion from here.
       ====================================================================== */

    /* ---- customers ---- */
    customers.total_est_annual_margin_inr AS SUM(customers.EST_ANNUAL_MARGIN_INR)
      WITH SYNONYMS ('total relationship value', 'total margin', 'portfolio value',
                     'total customer value', 'book value', 'total annual margin')
      COMMENT = 'Sum of estimated annual margin across customers, in INR. A ranking and sizing quantity, not a reportable profit figure -- see the est_annual_margin_inr fact.',
    customers.total_annual_premium_inr AS SUM(customers.ANNUAL_PREMIUM_INR)
      WITH SYNONYMS ('total annual premium', 'total premium', 'premium book',
                     'annual premium income', 'total premium income')
      COMMENT = 'Sum of annualised premium across customers, in INR. Computed on the customer spine, so it counts each customer once across all their active policies.',
    customers.total_outstanding_credit_inr AS SUM(customers.OUTSTANDING_CREDIT_INR)
      WITH SYNONYMS ('total outstanding credit', 'total credit exposure',
                     'total lending exposure', 'total debt', 'credit book')
      COMMENT = 'Sum of outstanding credit across customers, in INR. Total exposure whether or not the borrowing is up to date -- for the overdue subset use arrears_exposure_inr.',
    customers.avg_products_held AS AVG(customers.PRODUCT_COUNT)
      WITH SYNONYMS ('average products held', 'products per customer',
                     'average holdings', 'cross-holding', 'depth of relationship')
      COMMENT = 'Mean number of distinct product families per customer. The standard measure of relationship depth.',
    customers.avg_product_gaps AS AVG(customers.PRODUCT_GAP_COUNT)
      WITH SYNONYMS ('average gaps', 'gaps per customer', 'average opportunities per customer')
      COMMENT = 'Mean number of product gaps per customer. Same caveat as cross_sell_gap_count -- a need, not an eligibility verdict.',
    customers.customers_deteriorating AS COUNT_IF(customers.SENTIMENT_TREND = 'DETERIORATING')
      WITH SYNONYMS ('churn signal', 'churn signals', 'showing churn signals',
                     'customers showing churn signals', 'customers with churn signals',
                     'churn signal count', 'attrition signal', 'attrition signals',
                     'customers at churn risk', 'customers at risk of churning',
                     'deteriorating customers', 'customers souring',
                     'relationships getting worse',
                     'unhappy and getting unhappier', 'declining relationships')
      COMMENT = 'Customers whose sentiment is measurably deteriorating across their interactions. THIS IS THE CUSTOMER-LEVEL CHURN SIGNAL -- use it for any question of the form "how many customers are showing churn signals". Only 12 customers at the current anchor, and that small number is the point: 4,864 of 5,000 have too few interactions to fit a trend at all. Counts DETERIORATING only; INSUFFICIENT_DATA and NO_CONTACT_HISTORY are unknown, not calm, and are excluded. ALWAYS report customers_unknown_trend alongside this, because 12 out of 5,000 read without that context implies a healthy book when the truth is that the book is mostly unmeasured. Distinct from policies_at_risk_30d, which is policy-level forward-looking retention risk, and from lapse_rate, which is churn that already happened.',
    customers.customers_unknown_trend AS COUNT_IF(customers.SENTIMENT_TREND IN ('INSUFFICIENT_DATA', 'NO_CONTACT_HISTORY'))
      WITH SYNONYMS ('unknown trend', 'no trend data', 'insufficient data customers',
                     'customers with no sentiment trend', 'unmeasured customers')
      COMMENT = 'Customers whose sentiment trend cannot be determined -- either too few interactions to fit one, or no contact history at all. Report this alongside any trend breakdown so the reader knows how much of the book is unmeasured rather than calm. It is the majority of the book.',
    customers.customers_in_arrears AS COUNT_IF(customers.IS_IN_ARREARS_CUSTOMER)
      WITH SYNONYMS ('customers in arrears', 'how many customers are overdue',
                     'number of customers in arrears', 'delinquent customers',
                     'customers behind on payments', 'people in arrears')
      COMMENT = 'Customers with at least one loan past due. Counts PEOPLE, unlike loans_in_arrears which counts loans -- a customer with two overdue loans is one customer here and two there, and the two numbers should not be used interchangeably.',
    customers.customers_with_hardship AS COUNT_IF(customers.HARDSHIP_SIGNAL)
      WITH SYNONYMS ('customers in hardship', 'hardship count',
                     'customers in difficulty', 'financially stressed customers',
                     'customers to protect')
      COMMENT = 'Customers showing a financial hardship signal on any of its four arms. These should be routed to service, not sales.',
    customers.customers_with_open_complaint AS COUNT_IF(customers.OPEN_COMPLAINT)
      WITH SYNONYMS ('customers complaining', 'open complaints',
                     'customers with a complaint', 'complaint count',
                     'unresolved complaints')
      COMMENT = 'Customers with a service complaint still open. Customer-level, so a customer with three open complaints counts once.',
    customers.reachable_customers AS COUNT_IF(customers.IS_REACHABLE_ANY_CHANNEL)
      WITH SYNONYMS ('reachable customers', 'contactable customers',
                     'how many can we contact', 'permitted contacts',
                     'addressable book')
      COMMENT = 'Customers who can lawfully be contacted on at least one channel. The realistic denominator for any campaign sizing -- the difference between this and total_customers is book that cannot be spoken to at all.',
    customers.dnc_customers AS COUNT_IF(customers.DNC_FLAG)
      WITH SYNONYMS ('DNC customers', 'do not contact count', 'suppressed customers',
                     'how many on the DNC list', 'opted out customers')
      COMMENT = 'Customers on the do-not-contact registry for call or SMS. 1,330, about 27 percent of the book.',
    customers.kyc_stale_customers AS COUNT_IF(NOT customers.KYC_CURRENT)
      WITH SYNONYMS ('stale KYC', 'KYC not current', 'customers needing KYC',
                     'KYC overdue', 'unverified customers')
      COMMENT = 'Customers whose KYC is not current. Any new product sale to these is blocked until it is refreshed, so this is a hard cap on how much of the cross-sell opportunity is actionable.',
    customers.vulnerable_customers AS COUNT_IF(customers.VULNERABILITY_FLAG)
      WITH SYNONYMS ('vulnerable customers', 'vulnerability count',
                     'how many vulnerable', 'customers needing care')
      COMMENT = 'Customers on the vulnerability register. A conduct population -- marketing to them is constrained by product suitability rules.',
    customers.avg_credit_utilisation AS AVG(customers.CREDIT_UTILISATION)
      WITH SYNONYMS ('average credit utilisation', 'average utilization',
                     'mean limit usage', 'average card usage')
      COMMENT = 'Mean card utilisation, 0 to 1. Rising utilisation across a cohort is an early stress signal.',
    customers.avg_tenure_years AS AVG(customers.TENURE_YEARS)
      WITH SYNONYMS ('average tenure', 'mean tenure', 'average relationship length',
                     'how long customers stay')
      COMMENT = 'Mean years of relationship across customers.',
    customers.total_missed_payments_12m AS SUM(customers.MISSED_PAYMENTS_12M)
      WITH SYNONYMS ('total missed payments', 'missed payments across the book',
                     'total missed instalments')
      COMMENT = 'Total missed instalments across customers in the last 12 months.',

    /* ---- policies ---- */
    policies.policy_count AS COUNT(policies.POLICY_ID)
      WITH SYNONYMS ('policy count', 'number of policies', 'how many policies',
                     'total policies', 'policies')
      COMMENT = 'Policies of every status, including lapsed, matured and surrendered. 8,116. The denominator of lapse_rate. For the live book use active_policy_count.',
    policies.active_policy_count AS COUNT_IF(policies.IS_ACTIVE_POLICY)
      WITH SYNONYMS ('active policies', 'live policies', 'policies in force',
                     'how many active policies', 'in-force count')
      COMMENT = 'Policies currently in force. The right count for "the book" in almost any present-tense question.',
    policies.lapsed_policy_count AS COUNT_IF(policies.IS_LAPSED_POLICY)
      WITH SYNONYMS ('lapsed policies', 'churned policies', 'attrited policies',
                     'how many lapsed', 'lapses', 'policies lost',
                     'number of churns', 'churn count', 'attrition count')
      COMMENT = 'Policies that lapsed. 675. The numerator of lapse_rate. Matured and surrendered policies are NOT counted here -- see the is_lapsed_policy dimension for why neither is churn.',
    policies.renewals_within_30d AS COUNT_IF(policies.RENEWS_WITHIN_30D)
      WITH SYNONYMS ('renewals due', 'renewals in 30 days', 'upcoming renewals',
                     'policies renewing soon', 'renewal pipeline')
      COMMENT = 'Active policies renewing within 30 days of as_of_date. Timing only, no risk signal -- about one policy in twelve. For the subset in doubt use policies_at_risk_30d.',
    policies.total_annualised_premium_inr AS SUM(policies.ANNUALISED_PREMIUM_INR)
      WITH SYNONYMS ('total annualised premium', 'premium book', 'total premium',
                     'annualised premium income', 'gross written premium')
      COMMENT = 'Sum of annualised premium across policies, in INR. Computed at policy grain, so filter on is_active_policy for the in-force premium book -- unfiltered it includes premium from policies that have ended.',
    policies.total_sum_assured_inr AS SUM(policies.SUM_ASSURED_INR)
      WITH SYNONYMS ('total sum assured', 'total cover', 'total coverage',
                     'total exposure', 'aggregate cover', 'total sum insured')
      COMMENT = 'Sum of cover across policies, in INR. The gross amount the group would owe if every policy claimed in full. Filter on is_active_policy for live exposure.',
    policies.avg_sum_assured_inr AS AVG(policies.SUM_ASSURED_INR)
      WITH SYNONYMS ('average sum assured', 'average cover', 'mean coverage',
                     'typical cover')
      COMMENT = 'Mean cover per policy, in INR.',
    policies.premium_at_risk_30d AS SUM(CASE WHEN policies.IS_AT_RISK_30D THEN policies.ANNUALISED_PREMIUM_INR ELSE 0 END)
      WITH SYNONYMS ('premium at risk', 'premium at risk in 30 days',
                     'revenue at risk', 'annual premium at risk',
                     'value of policies at risk', 'money at risk from lapse')
      COMMENT = 'Annualised premium on the at-risk policies, in INR -- what would be lost if every retention save failed. The rupee companion to policies_at_risk_30d, and usually the number that decides whether an intervention is worth funding.',

    /* ---- loans ---- */
    loans.loan_count AS COUNT(loans.LOAN_ID)
      WITH SYNONYMS ('loan count', 'number of loans', 'how many loans', 'total loans')
      COMMENT = 'Loans on the book. 3,219, all currently active.',
    loans.loans_in_arrears AS COUNT_IF(loans.IS_IN_ARREARS)
      WITH SYNONYMS ('loans in arrears', 'overdue loans', 'late loans',
                     'delinquent loans', 'how many loans are overdue',
                     'loans past due', 'arrears count')
      COMMENT = 'Loans at least one day past due. Counts LOANS -- a customer with two overdue loans counts twice, so for people use total_customers filtered on the arrears condition.',
    loans.total_outstanding_inr AS SUM(loans.OUTSTANDING_INR)
      WITH SYNONYMS ('total outstanding', 'total loan book', 'lending exposure',
                     'total balance', 'book size in rupees', 'total loan exposure')
      COMMENT = 'Total outstanding balance across loans, in INR. The whole lending book, current and overdue together. The denominator for an arrears exposure ratio.',
    loans.avg_dpd_days AS AVG(loans.DPD_DAYS)
      WITH SYNONYMS ('average DPD', 'average days past due', 'mean days overdue',
                     'average delinquency')
      COMMENT = 'Mean days past due across loans, INCLUDING loans that are up to date at zero, which pulls it toward zero. For the average among late loans only, filter on is_in_arrears first -- the two numbers are very different and the unfiltered one is usually not what is meant.',
    loans.total_emi_inr AS SUM(loans.EMI_INR)
      WITH SYNONYMS ('total EMI', 'total instalments', 'monthly collections due',
                     'total monthly repayments', 'collections due')
      COMMENT = 'Sum of monthly instalments due across loans, in INR. What the book should collect each month.',
    loans.rising_dpd_loan_count AS COUNT_IF(loans.IS_DPD_RISING)
      WITH SYNONYMS ('loans with rising arrears', 'worsening loans',
                     'deteriorating loans', 'loans getting worse',
                     'rising DPD count', 'slipping loans')
      COMMENT = 'Loans where days past due rose across three consecutive monthly readings. The forward-looking arrears measure -- these are the loans about to enter a worse bucket.',
    loans.restructured_loan_count AS COUNT_IF(loans.IS_RESTRUCTURED)
      WITH SYNONYMS ('restructured loans', 'reworked loans', 'rescheduled loans',
                     'forbearance count')
      COMMENT = 'Loans whose terms were renegotiated because the customer could not meet the original schedule.',

    /* ---- claims ---- */
    claims.claim_count AS COUNT(claims.CLAIM_ID)
      WITH SYNONYMS ('claim count', 'number of claims', 'how many claims',
                     'total claims', 'claims filed')
      COMMENT = 'Claims ever filed, all statuses. 1,621.',
    claims.total_claimed_inr AS SUM(claims.CLAIM_AMOUNT_INR)
      WITH SYNONYMS ('total claimed', 'total claim amount', 'amount claimed',
                     'gross claims', 'claims value')
      COMMENT = 'Sum of amounts claimed, in INR, regardless of outcome.',
    claims.total_approved_inr AS SUM(claims.APPROVED_AMOUNT_INR_ZEROED)
      WITH SYNONYMS ('total approved', 'total paid out', 'total settled amount',
                     'claims paid', 'payouts')
      COMMENT = 'Sum of approved amounts, in INR, with unsettled and rejected claims counted as zero recovered. That zeroing is deliberate and is what makes this the right numerator for a settlement ratio.',
    claims.settled_claim_count AS COUNT_IF(claims.IS_SETTLED_CLAIM)
      WITH SYNONYMS ('settled claims', 'claims settled', 'claims paid out',
                     'how many settled')
      COMMENT = 'Claims settled and paid.',
    claims.rejected_claim_count AS COUNT_IF(claims.IS_REJECTED_CLAIM)
      WITH SYNONYMS ('rejected claims', 'declined claims', 'claims refused',
                     'how many rejected', 'repudiations')
      COMMENT = 'Claims rejected. Worth watching next to complaints and lapses -- a rejection is a common trigger for both.',
    claims.open_claim_count AS COUNT_IF(claims.IS_OPEN_CLAIM)
      WITH SYNONYMS ('open claims', 'pending claims', 'unsettled claims',
                     'claims in progress', 'claims awaiting decision')
      COMMENT = 'Claims still open or in review -- customers currently waiting for a decision.',
    claims.avg_settlement_days AS AVG(claims.SETTLEMENT_DAYS)
      WITH SYNONYMS ('average settlement days', 'average time to settle',
                     'settlement turnaround', 'average TAT', 'claims turnaround')
      COMMENT = 'Mean days from filing to settlement, across SETTLED claims only -- unsettled and rejected claims carry a NULL and are excluded automatically. So this measures how fast the group pays when it pays, not how long customers wait overall.',

    /* ---- campaigns ---- */
    campaigns.contact_count AS COUNT(campaigns.CAMPAIGN_CONTACT_ID)
      WITH SYNONYMS ('contacts', 'contact count', 'number of contacts',
                     'contact attempts', 'how many times contacted',
                     'outreach volume', 'campaign volume')
      COMMENT = 'Outbound contact attempts. 24,918 over 12 rolling months. Counts ATTEMPTS, not people -- the same customer appears many times.',
    campaigns.customers_contacted AS COUNT(DISTINCT campaigns.CUSTOMER_ID)
      WITH SYNONYMS ('customers contacted', 'distinct customers contacted',
                     'how many customers did we contact', 'people contacted',
                     'customers we reached out to', 'unique customers contacted',
                     'customers in campaigns', 'customers we are contacting')
      COMMENT = 'DISTINCT customers who received at least one outbound contact, as opposed to contact_count which counts attempts. Use this for any question about how many PEOPLE were contacted, and in particular for questions that cross a customer attribute with campaign activity -- for example how many customers with a hardship signal are still being contacted, which is this metric filtered on has_hardship_signal. Without it that question cannot be expressed in this model and has to fall back to hand-written SQL outside it.',
    campaigns.converted_count AS COUNT_IF(campaigns.IS_CONVERTED)
      WITH SYNONYMS ('conversions', 'converted count', 'sales made',
                     'how many converted', 'successful contacts')
      COMMENT = 'Contact attempts that resulted in a sale.',
    campaigns.engaged_count AS COUNT_IF(campaigns.IS_ENGAGED)
      WITH SYNONYMS ('engaged count', 'positive responses',
                     'interested or converted count', 'engagement volume')
      COMMENT = 'Contact attempts that produced a conversion or an expression of interest.',
    campaigns.opt_out_count AS COUNT_IF(campaigns.IS_OPT_OUT)
      WITH SYNONYMS ('opt outs', 'opt-out count', 'unsubscribes',
                     'how many opted out', 'consent withdrawals')
      COMMENT = 'Contact attempts that caused the customer to opt out of future contact. A permanent reduction in the reachable book and a real cost of campaigning.',
    campaigns.complaint_outcome_count AS COUNT_IF(campaigns.IS_COMPLAINT_OUTCOME)
      WITH SYNONYMS ('complaints from campaigns', 'contacts that caused a complaint',
                     'campaign complaints', 'adverse outcomes')
      COMMENT = 'Contact attempts that caused the customer to complain. The most adverse outcome a campaign can produce.',
    campaigns.campaign_revenue_inr AS SUM(campaigns.REVENUE_INR)
      WITH SYNONYMS ('campaign revenue', 'revenue from campaigns',
                     'total campaign revenue', 'sales value', 'revenue generated')
      COMMENT = 'Revenue attributed to campaign contacts, in INR. Only conversions contribute.',

    /* ======================================================================
       DERIVED METRICS
       Ratios, defined once here so Analyst never has to assemble a
       numerator and a denominator itself and pick the wrong grain.
       ====================================================================== */

    arrears_exposure_rate AS loans.arrears_exposure_inr / NULLIF(loans.total_outstanding_inr, 0)
      WITH SYNONYMS ('arrears exposure rate', 'share of book in arrears',
                     'percentage of book overdue', 'arrears ratio',
                     'proportion of exposure overdue', 'delinquency rate by value')
      COMMENT = 'Outstanding balance on late loans as a fraction of the whole loan book. A value-weighted delinquency measure -- report as a percentage. Different from the loan-count share, and higher when the large loans are the late ones.',

    arrears_loan_rate AS loans.loans_in_arrears / NULLIF(loans.loan_count, 0)
      WITH SYNONYMS ('arrears loan rate', 'share of loans in arrears',
                     'percentage of loans overdue', 'delinquency rate by count',
                     'proportion of loans late')
      COMMENT = 'Late loans as a fraction of all loans. The count-weighted companion to arrears_exposure_rate; compare the two to see whether arrears are concentrated in large loans or small ones.',

    campaign_conversion_rate AS campaigns.converted_count / NULLIF(campaigns.contact_count, 0)
      WITH SYNONYMS ('conversion rate', 'campaign conversion rate', 'hit rate',
                     'success rate', 'percentage converted', 'response rate')
      COMMENT = 'Conversions as a fraction of contact attempts. Report as a percentage. Judge a channel or campaign on this TOGETHER WITH opt_out_rate -- a channel that converts well and burns consent is not a good channel.',

    campaign_opt_out_rate AS campaigns.opt_out_count / NULLIF(campaigns.contact_count, 0)
      WITH SYNONYMS ('opt out rate', 'opt-out rate', 'unsubscribe rate',
                     'consent burn rate', 'percentage opting out')
      COMMENT = 'Opt-outs as a fraction of contact attempts. The cost side of campaigning: every opt-out permanently shrinks the reachable book. Always worth reporting next to campaign_conversion_rate.',

    campaign_revenue_per_contact AS campaigns.campaign_revenue_inr / NULLIF(campaigns.contact_count, 0)
      WITH SYNONYMS ('revenue per contact', 'value per contact',
                     'revenue per attempt', 'yield per contact')
      COMMENT = 'Campaign revenue divided by contact attempts, in INR. Folds conversion rate and ticket size into one comparable figure across channels and campaigns.',

    claim_settlement_ratio AS claims.total_approved_inr / NULLIF(claims.total_claimed_inr, 0)
      WITH SYNONYMS ('settlement ratio', 'claim settlement ratio', 'payout ratio',
                     'proportion of claims paid', 'loss ratio', 'recovery rate')
      COMMENT = 'Approved amount over claimed amount across claims, in value terms. Unsettled and rejected claims count as zero recovered in the numerator, so this is the ratio a customer would experience rather than an underwriting loss ratio on settled business only.',

    claim_rejection_rate AS claims.rejected_claim_count / NULLIF(claims.claim_count, 0)
      WITH SYNONYMS ('rejection rate', 'claim rejection rate', 'decline rate',
                     'percentage of claims rejected', 'repudiation rate')
      COMMENT = 'Rejected claims as a fraction of all claims. A dissatisfaction driver -- break it down by policy_type or city to find where the group is generating grievances.',

    reachable_share AS customers.reachable_customers / NULLIF(customers.total_customers, 0)
      WITH SYNONYMS ('reachable share', 'contactable share',
                     'percentage of the book we can contact',
                     'addressable proportion', 'permission coverage')
      COMMENT = 'Customers contactable on at least one channel as a fraction of all customers. The ceiling on any campaign reach, and the first number to check before sizing an outreach.'
  )

  COMMENT = 'Customer 360 for an Indian bank-and-insurer group: one customer spine (5,000 customers) with the insurance book, the lending book, claims and the outbound contact log hanging off it. Answers portfolio questions about relationship value, retention risk, arrears, cross-sell opportunity, claims experience and campaign effectiveness. THREE THINGS TO KNOW BEFORE TRUSTING AN ANSWER. First, every day-count is measured from as_of_date, a stored anchor, not from today. Second, the four facts are at different grains -- policies, loans, claims and contacts are all many-per-customer, so use total_customers whenever the question asks how many people. Third, a product gap is a statement about customer need and NOT an eligibility verdict; income, KYC and vulnerability gates are applied downstream, not here. Next-best-action recommendations and their expected values are deliberately not in this model yet.'

  AI_SQL_GENERATION 'GRAIN. customers is one row per customer and is the spine. policies, loans, claims and campaigns are all many-per-customer facts joined to it on CUSTOMER_ID. When the question asks how many PEOPLE, use total_customers even if the filter is on a fact -- a customer with three overdue loans is one customer. When it asks how many policies, loans, claims or contacts, use the fact count.

TIME. There is no date dimension. Every day-count is measured from customers.as_of_date, a stored anchor date. Never substitute CURRENT_DATE. "Within 30 days", "days to renewal" and "days since contact" are all precomputed relative to the anchor -- use renews_within_30d, policy_days_to_renewal and days_since_contact rather than doing date arithmetic. The only genuine time grain is campaigns.contacted_month, for campaign trends over 12 rolling months.

FILTERS THAT ARE ALMOST ALWAYS WANTED. policies contains lapsed, matured and surrendered policies as well as active ones -- filter is_active_policy for any present-tense question about the book. policy_count and total_annualised_premium_inr are unfiltered by design because lapse_rate needs the full denominator.

CHURN IS THREE DIFFERENT QUESTIONS AND THEY HAVE THREE DIFFERENT ANSWERS. Read which one is being asked before choosing a metric. (a) CHURN THAT ALREADY HAPPENED -- "what is our churn rate", "how many customers left", "lapse rate": use lapse_rate and lapsed_policy_count over policies.is_lapsed_policy, the recorded lapse event. Never count MATURED (ran its full term) or SURRENDERED (deliberate exit) as churn. (b) A CUSTOMER SHOWING A CHURN SIGNAL -- "how many customers are showing churn signals", "which customers are souring", anything about customers and sentiment: use customers_deteriorating, and ALWAYS report customers_unknown_trend beside it, because only 12 of 5,000 customers have a measurable deteriorating trend and 4,864 have too few interactions to have any trend at all. (c) A POLICY WHOSE RENEWAL IS IN DOUBT -- "which policies are at risk", "retention risk", "what do we need to save": use policies_at_risk_30d and premium_at_risk_30d. These are POLICIES, not customers. Do not answer (b) with (c): a question about how many CUSTOMERS show churn signals is not answered by a count of at-risk POLICIES.

ARREARS, OVERDUE and DPD are the same thing. Per loan use loans.dpd_bucket, dpd_days or is_in_arrears. Per CUSTOMER use customers.is_in_arrears_customer and the customers_in_arrears metric -- do not rebuild the predicate from worst_dpd_bucket, and never group NO_CREDIT_OBLIGATION (no borrowing) with CURRENT (borrowing, up to date). For rupee exposure use arrears_exposure_inr, which is the full balance of every late loan. When breaking down by dpd_bucket, select total_outstanding_inr as well as arrears_exposure_inr, because arrears exposure is zero by construction in the CURRENT bucket and showing it alone reports 2,654 healthy loans as carrying no balance.

COUNTING PEOPLE VERSUS COUNTING ROWS. total_customers for customers, customers_in_arrears for people in arrears, campaigns.customers_contacted for distinct people contacted. loans_in_arrears, policy_count and contact_count are row counts on the facts. If a question crosses a customer attribute with campaign activity -- for example how many hardship customers are still being contacted -- use campaigns.customers_contacted filtered on the customer dimension, inside the semantic view. Do not drop out of the semantic view into hand-written SQL against the underlying V_SV_ views; they are presentation shims and carry none of the guidance above.

TRAPS TO AVOID. sentiment_trend values INSUFFICIENT_DATA and NO_CONTACT_HISTORY mean UNKNOWN, never STABLE -- when reporting a trend breakdown say how much of the book is unknown, using customers_unknown_trend. claim_ratio is NULL for customers who never claimed, which is not zero, so do not coalesce it when averaging. avg_dpd_days includes loans at zero days and is dragged toward zero; filter is_in_arrears if the question means the average among late loans. preferred_channel is a behaviour and not a permission -- the consent dimensions govern whether contact is allowed. A product gap is a need and not an eligibility verdict, so never describe gap counts as customers who can be sold to.

PAIRINGS THAT MAKE ANSWERS HONEST. Report campaign_conversion_rate together with campaign_opt_out_rate. Report policies_at_risk_30d together with premium_at_risk_30d for the rupee stake. Report avg_relationship_value with the relationship_value_band mix, because the mean sits well above the median on a skewed distribution. Size any outreach against reachable_customers, not total_customers.

NOT IN THIS MODEL. Next-best-action recommendations, propensity scores and expected values are deliberately absent -- if asked, say the recommendation engine is not part of this semantic view rather than substituting product gaps for it.'

  AI_QUESTION_CATEGORIZATION 'Answerable: customer counts and mix by city, segment, age band, tenure band and value band; relationship value totals and averages; product holdings, cross-sell gaps and relationship depth; the insurance book by type, status, premium and sum assured; lapse rates and lapse counts sliced any way; retention risk from approaching renewals plus recent complaints, and the premium at stake; the lending book, arrears by bucket, days past due, rising-arrears trajectories, restructures and rupee arrears exposure; claims volumes, settlement ratios, rejection rates and turnaround; campaign volumes, conversion and opt-out rates by channel, campaign and month; contact permission and reachability; hardship, vulnerability and KYC populations.

Not answerable: next-best-action recommendations, propensity scores, expected values or the ranked action list -- deliberately not modelled here. Individual interaction text, call transcripts and their sentiment scores at interaction grain (the spine carries only the customer-level roll-up). Anything needing a date other than the stored as-of anchor, including point-in-time history, month-over-month customer trends or aged snapshots of the book. Transaction-level spend, merchant category mix and payment-ledger detail. Household relationships beyond household size. Eligibility verdicts and compliance traces.'
;


/* ============================================================================
   PART 3 — VERIFICATION
   ----------------------------------------------------------------------------
   Every assertion re-derives the answer in plain SQL over the underlying
   tables and compares it with what the semantic view returns, emitting a
   PASS / FAIL verdict column -- the same idiom sql/08 §VERIFY uses, so the
   whole rebuild is checked the same way and read the same way.
   ============================================================================ */

/* 3.1  A1. The quarantine holds. The ground-truth table must not be reachable
        from anything this file creates -- checked against the stored DDL of
        each object, the same way sql/08 A5 checks it, rather than trusted
        from a header comment.

        Note this reads the STORED DDL of the created objects, not this source
        file, so the fact that the header above names the table in prose does
        not make the assertion pass vacuously. */
SELECT 'A1 segment truth not referenced' AS assertion,
       COUNT_IF(UPPER(ddl) LIKE '%CUSTOMER_SEGMENT_TRUTH%') AS violations,
       IFF(COUNT_IF(UPPER(ddl) LIKE '%CUSTOMER_SEGMENT_TRUTH%') = 0, 'PASS', 'FAIL') AS verdict
FROM (
  SELECT GET_DDL('VIEW', 'GOLD.V_SV_CUSTOMER')  AS ddl
  UNION ALL SELECT GET_DDL('VIEW', 'GOLD.V_SV_POLICY')
  UNION ALL SELECT GET_DDL('VIEW', 'GOLD.V_SV_LOAN')
  UNION ALL SELECT GET_DDL('VIEW', 'GOLD.V_SV_CLAIM')
  UNION ALL SELECT GET_DDL('VIEW', 'GOLD.V_SV_CAMPAIGN')
  UNION ALL SELECT GET_DDL('SEMANTIC_VIEW', 'GOLD.SV_CUSTOMER_360')
);

/* 3.1b  A2. NEXT_BEST_ACTION is likewise absent, which is the decision this
        file's header records rather than an accident. When M5/M6 replace the
        placeholder contents and the table is added, this assertion is the one
        to delete -- deliberately, and in the same commit. */
SELECT 'A2 nba table not referenced' AS assertion,
       COUNT_IF(UPPER(ddl) LIKE '%NEXT_BEST_ACTION%') AS violations,
       IFF(COUNT_IF(UPPER(ddl) LIKE '%NEXT_BEST_ACTION%') = 0, 'PASS', 'FAIL') AS verdict
FROM (
  SELECT GET_DDL('VIEW', 'GOLD.V_SV_CUSTOMER')  AS ddl
  UNION ALL SELECT GET_DDL('VIEW', 'GOLD.V_SV_POLICY')
  UNION ALL SELECT GET_DDL('VIEW', 'GOLD.V_SV_LOAN')
  UNION ALL SELECT GET_DDL('VIEW', 'GOLD.V_SV_CLAIM')
  UNION ALL SELECT GET_DDL('VIEW', 'GOLD.V_SV_CAMPAIGN')
);

/* 3.2  A3. The six headline metrics agree with plain SQL over the underlying
        tables. The truth side is recomputed here rather than hardcoded to the
        reference values in the header, so this assertion survives the as-of
        anchor moving -- policies_at_risk_30d moves with the anchor and would
        otherwise start failing for the wrong reason.

        Both sides are emitted, not just the verdict, so a failure says which
        metric drifted and by how much rather than only that one did. */
WITH sv AS (
  SELECT * FROM SEMANTIC_VIEW(
    GOLD.SV_CUSTOMER_360
    METRICS total_customers,
            avg_relationship_value,
            policies_at_risk_30d,
            lapse_rate,
            cross_sell_gap_count,
            arrears_exposure_inr
  )
),
truth AS (
  SELECT
    (SELECT COUNT(*) FROM GOLD.CUSTOMER_360)                            AS total_customers,
    (SELECT AVG(EST_ANNUAL_MARGIN_INR) FROM GOLD.CUSTOMER_360)          AS avg_relationship_value,
    (SELECT COUNT(*)
       FROM RAW.POLICY p
       CROSS JOIN GOLD.C360_ASOF a
      WHERE p.STATUS = 'ACTIVE'
        AND p.RENEWAL_DATE BETWEEN a.AS_OF_DATE AND DATEADD(day, 30, a.AS_OF_DATE)
        AND EXISTS (SELECT 1
                      FROM RAW.SERVICE_TICKET t
                      CROSS JOIN GOLD.C360_ASOF a2
                     WHERE t.CUSTOMER_ID = p.CUSTOMER_ID
                       AND t.IS_COMPLAINT
                       AND t.OPENED_AT >= DATEADD(day, -60, a2.AS_OF_DATE)))  AS policies_at_risk_30d,
    (SELECT COUNT_IF(LAPSE_FLAG) / NULLIF(COUNT(*), 0) FROM RAW.POLICY)  AS lapse_rate,
    (SELECT SUM(ARRAY_SIZE(PRODUCT_GAP)) FROM GOLD.CUSTOMER_360)         AS cross_sell_gap_count,
    (SELECT SUM(OUTSTANDING_INR) FROM RAW.LOAN WHERE DPD_DAYS > 0)       AS arrears_exposure_inr
),
cmp AS (
  SELECT 'total_customers'        AS metric, sv.TOTAL_CUSTOMERS::FLOAT               AS via_sv, truth.TOTAL_CUSTOMERS::FLOAT               AS via_sql FROM sv, truth
  UNION ALL SELECT 'avg_relationship_value',  ROUND(sv.AVG_RELATIONSHIP_VALUE, 2),   ROUND(truth.AVG_RELATIONSHIP_VALUE, 2)                FROM sv, truth
  UNION ALL SELECT 'policies_at_risk_30d',    sv.POLICIES_AT_RISK_30D::FLOAT,        truth.POLICIES_AT_RISK_30D::FLOAT                     FROM sv, truth
  UNION ALL SELECT 'lapse_rate',              ROUND(sv.LAPSE_RATE, 8),               ROUND(truth.LAPSE_RATE, 8)                            FROM sv, truth
  UNION ALL SELECT 'cross_sell_gap_count',    sv.CROSS_SELL_GAP_COUNT::FLOAT,        truth.CROSS_SELL_GAP_COUNT::FLOAT                     FROM sv, truth
  UNION ALL SELECT 'arrears_exposure_inr',    sv.ARREARS_EXPOSURE_INR::FLOAT,        truth.ARREARS_EXPOSURE_INR::FLOAT                     FROM sv, truth
)
SELECT 'A3 headline metrics match plain SQL' AS assertion,
       metric,
       via_sv,
       via_sql,
       IFF(EQUAL_NULL(via_sv, via_sql), 'PASS', 'FAIL') AS verdict
FROM cmp
ORDER BY metric;

/* 3.3  A4. Grain sanity: no fact inflates the spine. Each fact's distinct
        customer count must not exceed the spine's row count, and the
        relationship must not manufacture customers that do not exist. */
SELECT
  CASE WHEN orphan_policies = 0 AND orphan_loans = 0
        AND orphan_claims = 0   AND orphan_campaigns = 0
       THEN 'A4 PASS: no fact rows reference a customer absent from the spine'
       ELSE 'A4 FAIL: orphans -- policies ' || orphan_policies
            || ', loans '     || orphan_loans
            || ', claims '    || orphan_claims
            || ', campaigns ' || orphan_campaigns
  END AS referential_check
FROM (
  SELECT
    (SELECT COUNT(*) FROM GOLD.V_SV_POLICY   f WHERE NOT EXISTS (SELECT 1 FROM GOLD.V_SV_CUSTOMER c WHERE c.CUSTOMER_ID = f.CUSTOMER_ID)) AS orphan_policies,
    (SELECT COUNT(*) FROM GOLD.V_SV_LOAN     f WHERE NOT EXISTS (SELECT 1 FROM GOLD.V_SV_CUSTOMER c WHERE c.CUSTOMER_ID = f.CUSTOMER_ID)) AS orphan_loans,
    (SELECT COUNT(*) FROM GOLD.V_SV_CLAIM    f WHERE NOT EXISTS (SELECT 1 FROM GOLD.V_SV_CUSTOMER c WHERE c.CUSTOMER_ID = f.CUSTOMER_ID)) AS orphan_claims,
    (SELECT COUNT(*) FROM GOLD.V_SV_CAMPAIGN f WHERE NOT EXISTS (SELECT 1 FROM GOLD.V_SV_CUSTOMER c WHERE c.CUSTOMER_ID = f.CUSTOMER_ID)) AS orphan_campaigns
);

/* 3.4  A5. Synonym coverage for the two sets the brief names explicitly.
        'churn', 'attrition' and 'lapse' must all resolve; so must
        'arrears', 'overdue' and 'DPD'. Checked against the catalogue rather
        than eyeballed, so a synonym dropped in a later edit fails here
        instead of in a demo.

        SHOW populates the result set that the next query RESULT_SCANs, so
        these two statements must run in order and adjacently. */
SHOW SEMANTIC DIMENSIONS IN GOLD.SV_CUSTOMER_360;

WITH declared AS (
  SELECT "name" AS dim_name,
         LOWER(s.VALUE::STRING) AS synonym
  FROM TABLE(RESULT_SCAN(LAST_QUERY_ID())),
       LATERAL FLATTEN(input => TRY_PARSE_JSON("synonyms")) s
),
required AS (
  SELECT * FROM VALUES
    ('churn'), ('attrition'), ('lapse'),
    ('arrears'), ('overdue'), ('dpd')
  AS t(term)
),
resolution AS (
  SELECT r.term,
         COUNT(d.dim_name)            AS hits,
         LISTAGG(DISTINCT d.dim_name, '/') AS resolves_to
  FROM required r
  LEFT JOIN declared d ON d.synonym = r.term
  GROUP BY r.term
)
SELECT
  CASE WHEN COUNT_IF(hits = 0) = 0
       THEN 'A5 PASS: all six required synonyms resolve -- '
            || LISTAGG(term || '->' || resolves_to, ', ') WITHIN GROUP (ORDER BY term)
       ELSE 'A5 FAIL: unresolved -- '
            || LISTAGG(CASE WHEN hits = 0 THEN term END, ', ')
  END AS synonym_check
FROM resolution;

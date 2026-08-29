/* ============================================================================
   09_semantic_view.sql  —  the five feeder views under GOLD.SV_CUSTOMER_360
   ----------------------------------------------------------------------------
   THIS FILE NO LONGER CREATES THE SEMANTIC VIEW. It creates the five
   presentation shims the model reads. sql/16_semantic_view_nba.sql issues the
   CREATE OR REPLACE SEMANTIC VIEW and is the single authoritative definition.

   The name is kept because renaming it would break the numeric-order-is-run-order
   contract in PROJECT_BRIEF §6 for no gain, and because the five views below are
   still the layer this file was written to justify.

   WHY THE DEFINITION MOVED. When this file was written the model covered the
   spine and four facts, and deliberately excluded GOLD.NEXT_BEST_ACTION because
   that table then held placeholder propensities -- the argument is preserved
   below because it is still the right argument for the state it described. M9
   added the engine to the model, which needs two objects created after this file
   runs: GOLD.NBA_ELIGIBLE (sql/12), the only place suppression is recorded, and
   GOLD.V_NEXT_BEST_ACTION_AUDIT (sql/15). A feeder view over a table that does
   not exist yet fails at CREATE, so the definition could not stay here.

   ALTER SEMANTIC VIEW cannot add a table or a metric -- it changes the comment,
   the tags and the materializations only -- so there was no incremental path
   either. The choice was between duplicating ~830 lines of definition in sql/16
   and leaving a second copy here to drift, or moving it. It moved. sql/16's
   header records the same reasoning from the other side.

   WHAT WENT WITH IT. The three assertions in the old §3.2-3.4 -- headline
   metrics against plain SQL, fact-to-spine referential integrity, synonym
   resolution -- all query SEMANTIC_VIEW(), so they now live in sql/16 §3. The
   old A2, which asserted that GOLD.NEXT_BEST_ACTION was NOT referenced, is
   deleted: it asserted a decision M9 deliberately reverses, and the comment on
   it said to delete it in the same commit that added the table. A1, the
   quarantine check, stays here for the five views and is repeated in sql/16 over
   all seven plus the model.

   Cost: ZERO CREDITS. No AI function is called anywhere in this file.

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
      straight to the spine. A flat star, no ambiguity. Same treatment for the
      PRODUCT_CATALOG lookups on policies, loans and campaigns: folded into the
      views rather than declared as a shared dimension that three facts point at.

   sql/16 adds two more shims on exactly this contract -- V_SV_NBA and
   V_SV_NBA_CANDIDATE -- for the third reason: V_SV_NBA joins the audit view to
   pick up RATIONALE_SOURCE, which the model cannot reach itself.

   The views are named V_SV_* to mark them as presentation-layer shims for this
   semantic view specifically. Nothing else should read them; downstream code
   wanting these facts should read RAW or CURATED. Cortex Analyst reaching around
   the model into these views is a governance failure even when the number it
   returns is right -- see evals/analyst_questions.md Q12, and the assertion in
   evals/run_analyst_evals.py that now fails an answer for doing it.

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

   The metric itself is now declared in sql/16, and the reference values it is
   asserted against live there too.

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
   PART 2 — VERIFICATION
   ----------------------------------------------------------------------------
   One assertion. The other four moved to sql/16 §3, which is where the object
   they query is now created; A2 was deleted rather than moved.
   ============================================================================ */

/* 2.1  A1. The quarantine holds. Checked against the stored DDL of each created
        object, the same way sql/08 A5 checks it, rather than trusted from a
        header comment. Reads the STORED DDL and not this source file, so the
        fact that the header above names the table in prose does not make the
        assertion pass vacuously.

        The semantic view is not in this list any more because this file does
        not create it. sql/16 §3.1 runs the same check over all seven views plus
        the model, so nothing is left unchecked by the move. */
SELECT 'A1 segment truth not referenced' AS assertion,
       COUNT_IF(UPPER(ddl) LIKE '%CUSTOMER_SEGMENT_TRUTH%') AS violations,
       IFF(COUNT_IF(UPPER(ddl) LIKE '%CUSTOMER_SEGMENT_TRUTH%') = 0, 'PASS', 'FAIL') AS verdict
FROM (
  SELECT GET_DDL('VIEW', 'GOLD.V_SV_CUSTOMER')  AS ddl
  UNION ALL SELECT GET_DDL('VIEW', 'GOLD.V_SV_POLICY')
  UNION ALL SELECT GET_DDL('VIEW', 'GOLD.V_SV_LOAN')
  UNION ALL SELECT GET_DDL('VIEW', 'GOLD.V_SV_CLAIM')
  UNION ALL SELECT GET_DDL('VIEW', 'GOLD.V_SV_CAMPAIGN')
);

/* 2.2  Row counts, so the shim layer is visibly the same shape as its sources.
        Not an assertion -- the semantic view's own A4 in sql/16 covers
        referential integrity, and duplicating it here would be two places to
        update when a grain changes. */
SELECT 'V_SV_CUSTOMER' AS view_name, COUNT(*) AS row_count FROM GOLD.V_SV_CUSTOMER
UNION ALL SELECT 'V_SV_POLICY',   COUNT(*) FROM GOLD.V_SV_POLICY
UNION ALL SELECT 'V_SV_LOAN',     COUNT(*) FROM GOLD.V_SV_LOAN
UNION ALL SELECT 'V_SV_CLAIM',    COUNT(*) FROM GOLD.V_SV_CLAIM
UNION ALL SELECT 'V_SV_CAMPAIGN', COUNT(*) FROM GOLD.V_SV_CAMPAIGN
ORDER BY view_name;

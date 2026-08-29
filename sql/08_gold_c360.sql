/* ============================================================================
   08_gold_c360.sql  —  GOLD.CUSTOMER_360, GOLD.CUSTOMER_TIMELINE,
                        GOLD.NEXT_BEST_ACTION (placeholder contract)
   ----------------------------------------------------------------------------
   The customer spine. One row per customer, wide, with every column named so a
   business user reads it without a data dictionary. Plus the chronological
   event stream the Streamlit app renders, and a placeholder NBA table that
   fixes the column contract now so the app can be built before the real engine
   exists.

   This is M4 in PROJECT_BRIEF §10. It was scoped there as 20_gold_spine.sql;
   it lands at 08 because the unstructured chain took 04-07 (see the brief's
   note on numbering in §6). 08 is the next free number.

   ----------------------------------------------------------------------------
   IT READS RAW DIRECTLY, BECAUSE THE CONFORM LAYER DOES NOT EXIST
   ----------------------------------------------------------------------------
   The brief has M4 reading CURATED.DIM_PARTY, CURATED.CONTRACT,
   CURATED.PAYMENT_FACT and CURATED.SPEND_FACT -- the M2 conform layer, files
   10-13. Those files were never written. What actually exists in CURATED is
   the M3 unstructured chain: INTERACTION_SIGNALS_RAW and its views, plus
   CUSTOMER_INTERACTION_ROLLUP.

   So the structured half of this spine reads RAW.CUSTOMER, HOUSEHOLD, POLICY,
   CLAIM, LOAN, CARD, REPAYMENT, TXN, CONSENT, CAMPAIGN_HISTORY and
   PRODUCT_CATALOG directly, and only the unstructured half comes through
   CURATED. That is the same deliberate bridge 07_curated_rollup.sql already
   takes for OPEN_COMPLAINT_TICKET_FLAG, flagged the same way rather than
   pretending the silo does not exist.

   This is a real deviation, not a shortcut with no cost. What is lost:
     - identity resolution. PARTY_ID -> CUSTOMER_ID is taken as given from
       RAW.CUSTOMER rather than resolved, so duplicate parties would survive.
     - one CONTRACT grain. Policy, loan and card are aggregated three separate
       times here, so the same normalisation (annualised premium, margin rate
       lookup) is expressed once per silo instead of once.
     - DPD bucketing lives here rather than in PAYMENT_FACT, so M5 cannot
       reuse it without reading this table.

   When M2 lands, the CTEs named pol / pol_hist / loan_sched / ln / cd / rep /
   clm / lump are the ones to replace with reads of CONTRACT and PAYMENT_FACT.
   Nothing else in this file changes: the projection is deliberately separated
   from the sourcing for exactly that reason.

   ----------------------------------------------------------------------------
   WHY THERE IS AN ANCHOR TABLE, AND WHY IT IS NOT OPTIONAL
   ----------------------------------------------------------------------------
   CUSTOMER_360 is a dynamic table so refresh is declarative and incremental
   behaviour is demonstrable. That rules out RAW.AS_OF() anywhere in its SELECT
   list. RAW.AS_OF() is CURRENT_DATE, and Snowflake supports CURRENT_DATE in a
   dynamic table only inside WHERE / HAVING / QUALIFY. In a projection it is a
   hard compilation failure, not a silent downgrade to full refresh:

     Query contains the function 'CURRENT_DATE', but change tracking is not
     supported on queries with non-deterministic functions.

   Verified against this account, not inferred from the docs.

   So the calendar anchor is materialised. GOLD.C360_ASOF holds exactly one row
   carrying the as-of date, the dynamic tables CROSS JOIN it, and every
   day-count column (TENURE_YEARS, DAYS_TO_RENEWAL, LAST_CONTACT_DAYS,
   NEXT_EMI_DATE) is derived from that stored date. Three consequences, all of
   them improvements over calling CURRENT_DATE:

     - Incremental refresh is available at all. That was the point.
     - The anchor is auditable. CUSTOMER_360.AS_OF_DATE states which date the
       day-counts were computed against, so a stale count is visible rather
       than assumed.
     - Re-anchoring is an explicit, tracked data change. The MERGE below
       updates one row, which is a change the dynamic table refreshes on. That
       makes "advance the clock and watch the spine move" a demoable action.

   The anchor is created IF NOT EXISTS and MERGE-d, never CREATE OR REPLACE.
   Replacing the table would drop change tracking on it and force CUSTOMER_360
   to reinitialise from scratch on the next refresh. Updating one row does not.

   ----------------------------------------------------------------------------
   NEXT_EMI_DATE IS PROJECTED, NOT LOOKED UP
   ----------------------------------------------------------------------------
   RAW.REPAYMENT is a collections ledger, and it stops at the as-of date -- its
   latest DUE_DATE is the current month's instalment and there are no future
   rows at all. Reading "next EMI" from it would return the instalment that has
   already fallen due, or nothing.

   So it is projected from the loan schedule instead: EMIs fall on
   DAY(FIRST_EMI_DATE) each month, so the next one is the first monthly
   anniversary of FIRST_EMI_DATE strictly after the anchor, and NULL once that
   date passes the final instalment (FIRST_EMI_DATE + TENURE_MONTHS - 1).

   ----------------------------------------------------------------------------
   NO AI, NO CREDITS
   ----------------------------------------------------------------------------
   Every column in this file is deterministic SQL over data that was either
   generated in 03 or already paid for in 05. Re-running it costs warehouse
   compute and zero credits, which is what the incremental rule in AGENTS.md
   requires. The two dynamic tables at TARGET_LAG = '1 day' wake COCO_WH once
   a day between them rather than hourly -- the demo triggers
   ALTER DYNAMIC TABLE ... REFRESH by hand.

   SENTIMENT_TREND is carried through as-is and the raw slope is not read at
   all, per PROJECT_BRIEF D6. INSUFFICIENT_DATA is preserved rather than
   collapsed to STABLE, and customers who have never been in contact get a
   distinct NO_CONTACT_HISTORY so "unknown" and "calm" stay different.

   RAW.CUSTOMER_SEGMENT_TRUTH is not referenced. Asserted below by inspecting
   the DDL of every object this file creates, not by trusting this paragraph.
   ============================================================================ */

USE ROLE COCO_BUILDER;
USE WAREHOUSE COCO_WH;
USE DATABASE C360_NBA;

CREATE SCHEMA IF NOT EXISTS C360_NBA.GOLD;
USE SCHEMA C360_NBA.GOLD;

/* ============================================================================
   THE CALENDAR ANCHOR
   ----------------------------------------------------------------------------
   One row. IF NOT EXISTS + MERGE rather than CREATE OR REPLACE, so change
   tracking survives a re-run and the dynamic tables downstream refresh
   incrementally instead of reinitialising. PK exists only to give the MERGE
   something to match on and to make a second row impossible.
   ============================================================================ */

CREATE TABLE IF NOT EXISTS GOLD.C360_ASOF (
  PK          NUMBER        NOT NULL,
  AS_OF_DATE  DATE          NOT NULL,
  SET_AT      TIMESTAMP_LTZ NOT NULL,
  CONSTRAINT PK_C360_ASOF PRIMARY KEY (PK)
);

MERGE INTO GOLD.C360_ASOF t
USING (SELECT 1 AS PK, RAW.AS_OF() AS AS_OF_DATE) s
   ON t.PK = s.PK
WHEN MATCHED THEN UPDATE SET t.AS_OF_DATE = s.AS_OF_DATE, t.SET_AT = CURRENT_TIMESTAMP()
WHEN NOT MATCHED THEN INSERT (PK, AS_OF_DATE, SET_AT)
                      VALUES (s.PK, s.AS_OF_DATE, CURRENT_TIMESTAMP());

COMMENT ON TABLE GOLD.C360_ASOF IS
  'Materialised calendar anchor for the GOLD dynamic tables. Exists because CURRENT_DATE (and therefore RAW.AS_OF()) cannot appear in a dynamic table SELECT list without failing change tracking, so every day-count in CUSTOMER_360 is derived from this stored date instead. Updated by MERGE, never CREATE OR REPLACE, so change tracking survives and downstream refreshes stay incremental. Re-anchor by re-running 08 or by updating this row; both are tracked changes that trigger a refresh.';

/* ============================================================================
   GOLD.CUSTOMER_360
   ============================================================================ */

CREATE OR REPLACE DYNAMIC TABLE GOLD.CUSTOMER_360
  TARGET_LAG   = '1 day'
  WAREHOUSE    = COCO_WH
  REFRESH_MODE = INCREMENTAL
  COMMENT      = 'One row per customer, wide. Six feature families: identity, holdings, value, risk, engagement, eligibility, plus derived product gaps and renewal/EMI timing. Structured half reads RAW directly because the M2 conform layer was never built (see 08_gold_c360.sql header); unstructured half comes from CURATED.CUSTOMER_INTERACTION_ROLLUP. Day-counts are anchored on GOLD.C360_ASOF, not CURRENT_DATE. Does not read the quarantined ground-truth table (asserted in sql/08; the name is deliberately not spelled out here so the assertion cannot match its own documentation).'
AS
WITH cal AS (SELECT AS_OF_DATE FROM GOLD.C360_ASOF),

/* -------------------------------------------------------------------------
   Household. RAW.HOUSEHOLD is one row per customer with the size of the
   household they belong to, so MAX is a grain-safe no-op that also protects
   against a future multi-membership shape.
   ------------------------------------------------------------------------- */
hh AS (
  SELECT CUSTOMER_ID, MAX(HOUSEHOLD_SIZE) AS household_size
  FROM RAW.HOUSEHOLD
  GROUP BY 1
),

/* -------------------------------------------------------------------------
   Active policies. Premium is annualised before anything else touches it --
   a MONTHLY 5,000 and an ANNUAL 5,000 are not the same customer value, and
   summing them raw is the single easiest way to get this table wrong.

   Margin comes from RAW.PRODUCT_CATALOG per product code rather than a blended
   constant, so EST_ANNUAL_MARGIN_INR is defensible line by line.
   ------------------------------------------------------------------------- */
pol AS (
  SELECT
    p.CUSTOMER_ID,
    SUM(CASE p.PREMIUM_FREQUENCY WHEN 'MONTHLY'   THEN p.PREMIUM_INR * 12
                                 WHEN 'QUARTERLY' THEN p.PREMIUM_INR * 4
                                 ELSE p.PREMIUM_INR END)                     AS annual_premium_inr,
    SUM(CASE p.PREMIUM_FREQUENCY WHEN 'MONTHLY'   THEN p.PREMIUM_INR * 12
                                 WHEN 'QUARTERLY' THEN p.PREMIUM_INR * 4
                                 ELSE p.PREMIUM_INR END * pc.MARGIN_RATE)    AS policy_margin_inr,
    COUNT_IF(p.POLICY_TYPE = 'TERM')                                         AS n_term,
    COUNT_IF(p.POLICY_TYPE = 'HEALTH')                                       AS n_health,
    COUNT_IF(p.POLICY_TYPE = 'MOTOR')                                        AS n_motor,
    COUNT_IF(p.POLICY_TYPE = 'HOME')                                         AS n_home_ins,
    COUNT_IF(p.POLICY_TYPE = 'ULIP')                                         AS n_ulip,
    -- next renewal still ahead of the anchor; every active policy qualifies in
    -- the current dataset, but the guard is what makes that a fact rather than
    -- an assumption that breaks when the calendar moves.
    MIN(IFF(p.RENEWAL_DATE >= a.AS_OF_DATE, p.RENEWAL_DATE, NULL))           AS next_renewal_date
  FROM RAW.POLICY p
  JOIN RAW.PRODUCT_CATALOG pc ON pc.PRODUCT_CODE = p.PRODUCT_CODE
  CROSS JOIN cal a
  WHERE p.STATUS = 'ACTIVE'
  GROUP BY 1
),

/* -------------------------------------------------------------------------
   Lapse history is deliberately over ALL policies, not just active ones --
   the whole point of the column is the ones that are no longer active.
   ------------------------------------------------------------------------- */
pol_hist AS (
  SELECT CUSTOMER_ID,
         COUNT_IF(LAPSE_FLAG OR STATUS IN ('LAPSED','SURRENDERED')) AS lapse_history
  FROM RAW.POLICY
  GROUP BY 1
),

/* -------------------------------------------------------------------------
   Loan schedule. projected_next_emi is the first monthly anniversary of
   FIRST_EMI_DATE strictly after the anchor; final_emi_date closes the schedule
   so a loan in its last month does not project an instalment that will never
   be billed. See the header on why this is not read from RAW.REPAYMENT.
   ------------------------------------------------------------------------- */
loan_sched AS (
  SELECT
    l.CUSTOMER_ID,
    l.LOAN_TYPE,
    l.OUTSTANDING_INR,
    l.DPD_DAYS,
    l.DPD_DAYS_M1,
    l.DPD_DAYS_M2,
    l.RESTRUCTURE_FLAG,
    pc.MARGIN_RATE,
    DATEADD(month,
            DATEDIFF(month, l.FIRST_EMI_DATE, a.AS_OF_DATE)
              + IFF(DATEADD(month,
                            DATEDIFF(month, l.FIRST_EMI_DATE, a.AS_OF_DATE),
                            l.FIRST_EMI_DATE) > a.AS_OF_DATE, 0, 1),
            l.FIRST_EMI_DATE)                                        AS projected_next_emi,
    DATEADD(month, l.TENURE_MONTHS - 1, l.FIRST_EMI_DATE)            AS final_emi_date
  FROM RAW.LOAN l
  JOIN RAW.PRODUCT_CATALOG pc ON pc.PRODUCT_CODE = l.PRODUCT_CODE
  CROSS JOIN cal a
  WHERE l.STATUS = 'ACTIVE'
),
ln AS (
  SELECT
    CUSTOMER_ID,
    SUM(OUTSTANDING_INR)                                             AS loan_outstanding_inr,
    SUM(OUTSTANDING_INR * MARGIN_RATE)                               AS loan_margin_inr,
    MAX(DPD_DAYS)                                                    AS worst_dpd_days,
    COUNT_IF(LOAN_TYPE = 'HOME')                                     AS n_home_loan,
    COUNT_IF(LOAN_TYPE = 'AUTO')                                     AS n_auto_loan,
    COUNT_IF(LOAN_TYPE = 'PERSONAL')                                 AS n_personal_loan,
    COUNT_IF(RESTRUCTURE_FLAG)                                       AS n_restructured,
    -- rising DPD across three consecutive readings: the S4 hardship shape
    COUNT_IF(DPD_DAYS_M2 < DPD_DAYS_M1 AND DPD_DAYS_M1 < DPD_DAYS)   AS n_rising_dpd,
    MIN(IFF(projected_next_emi <= final_emi_date, projected_next_emi, NULL)) AS next_emi_date
  FROM loan_sched
  GROUP BY 1
),

/* -------------------------------------------------------------------------
   Active cards. Utilisation is computed on summed balance over summed limit
   rather than averaging per-card percentages, so a small maxed-out card does
   not outvote a large one sitting idle.
   ------------------------------------------------------------------------- */
cd AS (
  SELECT
    c.CUSTOMER_ID,
    COUNT(*)                                                         AS n_card,
    SUM(c.CURRENT_BALANCE_INR)                                       AS card_balance_inr,
    SUM(c.CREDIT_LIMIT_INR)                                          AS card_limit_inr,
    SUM(c.CURRENT_BALANCE_INR * pc.MARGIN_RATE)                      AS card_margin_inr,
    -- four consecutive rising readings: the S2 limit-increase shape
    COUNT_IF(c.UTILISATION_PCT_M3 < c.UTILISATION_PCT_M2
         AND c.UTILISATION_PCT_M2 < c.UTILISATION_PCT_M1
         AND c.UTILISATION_PCT_M1 < c.UTILISATION_PCT)               AS n_rising_util
  FROM RAW.CARD c
  JOIN RAW.PRODUCT_CATALOG pc ON pc.PRODUCT_CODE = c.PRODUCT_CODE
  WHERE c.STATUS = 'ACTIVE'
  GROUP BY 1
),

/* -------------------------------------------------------------------------
   Collections ledger. Windows are anchored, and the "ever" count is kept
   because the S2 limit-increase shape requires a completely clean record
   rather than a clean recent one.
   ------------------------------------------------------------------------- */
rep AS (
  SELECT
    r.CUSTOMER_ID,
    COUNT_IF(r.MISSED_FLAG AND r.DUE_DATE >= DATEADD(month, -12, a.AS_OF_DATE)) AS missed_payments_12m,
    COUNT_IF(r.MISSED_FLAG AND r.DUE_DATE >= DATEADD(month,  -6, a.AS_OF_DATE)) AS missed_payments_6m,
    COUNT_IF(r.LATE_FLAG OR r.MISSED_FLAG)                                      AS adverse_payments_ever
  FROM RAW.REPAYMENT r
  CROSS JOIN cal a
  GROUP BY 1
),

/* -------------------------------------------------------------------------
   Claims. DIV0 guards the denominator; an unsettled or rejected claim has a
   NULL approved amount, which counts as zero recovered rather than dropping
   out of the ratio. Customers with no claims get NULL, not 0 -- "never
   claimed" is not "claimed and got nothing".
   ------------------------------------------------------------------------- */
clm AS (
  SELECT
    CUSTOMER_ID,
    COUNT(*)                                                                    AS n_claims,
    ROUND(DIV0(SUM(COALESCE(APPROVED_AMOUNT_INR, 0)), SUM(CLAIM_AMOUNT_INR)), 4) AS claim_ratio
  FROM RAW.CLAIM
  GROUP BY 1
),

/* -------------------------------------------------------------------------
   Large inbound credit in the last 90 days. Feeds the investment gap; the
   1,000,000 threshold and the 90-day window are the S5 wealth-referral shape.
   ------------------------------------------------------------------------- */
lump AS (
  SELECT t.CUSTOMER_ID, MAX(t.AMOUNT_INR) AS max_inbound_lumpsum_90d
  FROM RAW.TXN t
  CROSS JOIN cal a
  WHERE t.DIRECTION = 'CREDIT'
    AND t.AMOUNT_INR >= 1000000
    AND t.TXN_DATE >= DATEADD(day, -90, a.AS_OF_DATE)
  GROUP BY 1
),

/* -------------------------------------------------------------------------
   Consent, per channel, folded to one row per customer.

   "Granted" means all four conditions at once: opted in, not marked DNC, and
   inside the validity window as of the anchor. 1,548 of 20,000 consent rows
   are expired and 4,933 were never opted in, so treating the raw OPT_IN_FLAG
   as consent would overstate reachability by roughly a third.

   DNC_FLAG is the CALL-or-SMS registry marker -- 1,330 customers, 27% of the
   book -- because that is what a DNC registry governs in this market. An
   any-channel reading would flag 2,285 customers (46%) and stop being a
   signal. The per-channel CONSENT_* columns are authoritative for a specific
   channel and already fold DNC in; DNC_FLAG is the customer-level headline.
   ------------------------------------------------------------------------- */
cons_base AS (
  SELECT
    k.CUSTOMER_ID,
    k.CHANNEL,
    k.DNC_FLAG,
    (      k.OPT_IN_FLAG
      AND  NOT k.DNC_FLAG
      AND  k.VALID_FROM <= a.AS_OF_DATE
      AND (k.VALID_TO IS NULL OR k.VALID_TO >= a.AS_OF_DATE) ) AS granted
  FROM RAW.CONSENT k
  CROSS JOIN cal a
),
cons AS (
  SELECT
    CUSTOMER_ID,
    COUNT_IF(CHANNEL = 'CALL'  AND granted) > 0                   AS consent_call,
    COUNT_IF(CHANNEL = 'EMAIL' AND granted) > 0                   AS consent_email,
    COUNT_IF(CHANNEL = 'SMS'   AND granted) > 0                   AS consent_sms,
    COUNT_IF(CHANNEL IN ('CALL','SMS') AND DNC_FLAG) > 0          AS dnc_flag,
    COUNT_IF(granted)                                             AS channels_reachable
  FROM cons_base
  GROUP BY 1
),

/* -------------------------------------------------------------------------
   Preferred channel, from outbound history: the channel that has actually
   produced engagement, tie-broken by fewest non-responses and then by name so
   the result is deterministic. This is a behavioural preference, not a
   permission -- the CONSENT_* columns decide whether it may be used.
   ------------------------------------------------------------------------- */
camp AS (
  SELECT CUSTOMER_ID, CHANNEL AS preferred_channel
  FROM (
    SELECT
      CUSTOMER_ID,
      CHANNEL,
      ROW_NUMBER() OVER (
        PARTITION BY CUSTOMER_ID
        ORDER BY COUNT_IF(OUTCOME IN ('CONVERTED','INTERESTED')) DESC,
                 COUNT_IF(OUTCOME = 'NO_RESPONSE')               ASC,
                 CHANNEL                                          ASC
      ) AS rn
    FROM RAW.CAMPAIGN_HISTORY
    GROUP BY 1, 2
  )
  WHERE rn = 1
),

/* -------------------------------------------------------------------------
   Everything assembled with the holdings flags resolved, so the arrays below
   can be built from named booleans instead of repeating nine COALESCE
   expressions twice each.
   ------------------------------------------------------------------------- */
assembled AS (
  SELECT
    c.CUSTOMER_ID,
    a.AS_OF_DATE,

    c.FULL_NAME,
    c.AGE_YEARS,
    c.CITY,
    c.SEGMENT,
    c.INCOME_BAND_RANK,
    c.KYC_STATUS,
    c.VULNERABILITY_FLAG,
    c.TENURE_MONTHS,
    COALESCE(hh.household_size, 1)                        AS household_size,

    /* holdings, one boolean per product family */
    COALESCE(pol.n_term,      0) > 0                      AS has_term,
    COALESCE(pol.n_health,    0) > 0                      AS has_health,
    COALESCE(pol.n_motor,     0) > 0                      AS has_motor_insurance,
    COALESCE(pol.n_home_ins,  0) > 0                      AS has_home_insurance,
    COALESCE(pol.n_ulip,      0) > 0                      AS has_investment,
    COALESCE(ln.n_home_loan,  0) > 0                      AS has_home_loan,
    COALESCE(ln.n_auto_loan,  0) > 0                      AS has_auto_loan,
    COALESCE(ln.n_personal_loan, 0) > 0                   AS has_personal_loan,
    COALESCE(cd.n_card,       0) > 0                      AS has_card,

    /* value */
    COALESCE(pol.annual_premium_inr, 0)                   AS annual_premium_inr,
    COALESCE(ln.loan_outstanding_inr, 0)
      + COALESCE(cd.card_balance_inr, 0)                  AS outstanding_credit_inr,
    ROUND(  COALESCE(pol.policy_margin_inr, 0)
          + COALESCE(ln.loan_margin_inr,    0)
          + COALESCE(cd.card_margin_inr,    0))           AS est_annual_margin_inr,

    /* risk */
    ln.worst_dpd_days,
    COALESCE(rep.missed_payments_12m, 0)                  AS missed_payments_12m,
    COALESCE(rep.missed_payments_6m,  0)                  AS missed_payments_6m,
    COALESCE(rep.adverse_payments_ever, 0)                AS adverse_payments_ever,
    COALESCE(pol_hist.lapse_history, 0)                   AS lapse_history,
    clm.claim_ratio,
    ROUND(DIV0(cd.card_balance_inr, cd.card_limit_inr), 4) AS credit_utilisation,
    COALESCE(ln.n_rising_dpd,  0) > 0                     AS rising_dpd,
    COALESCE(cd.n_rising_util, 0) > 0                     AS rising_utilisation,
    COALESCE(ln.n_restructured, 0) > 0                    AS restructured,

    /* engagement -- rollup covers only customers who have been in contact */
    COALESCE(roll.INTERACTIONS_90D, 0)                    AS interactions_90d,
    roll.LATEST_SENTIMENT                                 AS sentiment_now,
    roll.SENTIMENT_TREND                                  AS sentiment_trend_raw,
    COALESCE(roll.OPEN_COMPLAINT_FLAG, FALSE)             AS open_complaint,
    roll.LAST_CONTACT_AT,
    roll.HARDSHIP_MENTIONS_90D,
    COALESCE(camp.preferred_channel, 'CALL')              AS preferred_channel,

    /* eligibility */
    COALESCE(cons.consent_call,  FALSE)                   AS consent_call,
    COALESCE(cons.consent_email, FALSE)                   AS consent_email,
    COALESCE(cons.consent_sms,   FALSE)                   AS consent_sms,
    COALESCE(cons.dnc_flag,      FALSE)                   AS dnc_flag,
    COALESCE(cons.channels_reachable, 0)                  AS channels_reachable,

    /* timing */
    pol.next_renewal_date,
    ln.next_emi_date,

    /* gap inputs */
    COALESCE(lump.max_inbound_lumpsum_90d, 0)             AS max_inbound_lumpsum_90d

  FROM RAW.CUSTOMER c
  CROSS JOIN cal a
  LEFT JOIN hh       ON hh.CUSTOMER_ID       = c.CUSTOMER_ID
  LEFT JOIN pol      ON pol.CUSTOMER_ID      = c.CUSTOMER_ID
  LEFT JOIN pol_hist ON pol_hist.CUSTOMER_ID = c.CUSTOMER_ID
  LEFT JOIN ln       ON ln.CUSTOMER_ID       = c.CUSTOMER_ID
  LEFT JOIN cd       ON cd.CUSTOMER_ID       = c.CUSTOMER_ID
  LEFT JOIN rep      ON rep.CUSTOMER_ID      = c.CUSTOMER_ID
  LEFT JOIN clm      ON clm.CUSTOMER_ID      = c.CUSTOMER_ID
  LEFT JOIN lump     ON lump.CUSTOMER_ID     = c.CUSTOMER_ID
  LEFT JOIN cons     ON cons.CUSTOMER_ID     = c.CUSTOMER_ID
  LEFT JOIN camp     ON camp.CUSTOMER_ID     = c.CUSTOMER_ID
  LEFT JOIN CURATED.CUSTOMER_INTERACTION_ROLLUP roll
                     ON roll.CUSTOMER_ID     = c.CUSTOMER_ID
)

SELECT
  s.CUSTOMER_ID                                           AS CUSTOMER_ID,
  s.AS_OF_DATE                                            AS AS_OF_DATE,

  /* ---------- identity ---------- */
  s.FULL_NAME                                             AS CUSTOMER_NAME,
  s.AGE_YEARS                                             AS AGE,
  s.CITY                                                  AS CITY,
  s.SEGMENT                                               AS SEGMENT,
  s.household_size                                        AS HOUSEHOLD_SIZE,
  ROUND(s.TENURE_MONTHS / 12.0, 1)                        AS TENURE_YEARS,

  /* ---------- holdings ----------
     PRODUCTS_HELD is built from fixed labels in a fixed order rather than
     ARRAY_AGG over a type column, so the array is stable between refreshes
     and reads as a sentence. PRODUCT_COUNT counts families, not contracts,
     and is therefore exactly ARRAY_SIZE(PRODUCTS_HELD) by construction. */
  ARRAY_COMPACT(ARRAY_CONSTRUCT(
    IFF(s.has_term,             'Term Life',          NULL),
    IFF(s.has_health,           'Health Insurance',   NULL),
    IFF(s.has_motor_insurance,  'Motor Insurance',    NULL),
    IFF(s.has_home_insurance,   'Home Insurance',     NULL),
    IFF(s.has_investment,       'Investment (ULIP)',  NULL),
    IFF(s.has_home_loan,        'Home Loan',          NULL),
    IFF(s.has_auto_loan,        'Auto Loan',          NULL),
    IFF(s.has_personal_loan,    'Personal Loan',      NULL),
    IFF(s.has_card,             'Credit Card',        NULL)
  ))                                                      AS PRODUCTS_HELD,
  ARRAY_SIZE(ARRAY_COMPACT(ARRAY_CONSTRUCT(
    IFF(s.has_term,             'Term Life',          NULL),
    IFF(s.has_health,           'Health Insurance',   NULL),
    IFF(s.has_motor_insurance,  'Motor Insurance',    NULL),
    IFF(s.has_home_insurance,   'Home Insurance',     NULL),
    IFF(s.has_investment,       'Investment (ULIP)',  NULL),
    IFF(s.has_home_loan,        'Home Loan',          NULL),
    IFF(s.has_auto_loan,        'Auto Loan',          NULL),
    IFF(s.has_personal_loan,    'Personal Loan',      NULL),
    IFF(s.has_card,             'Credit Card',        NULL)
  )))                                                     AS PRODUCT_COUNT,
  s.has_home_loan                                         AS HAS_HOME_LOAN,
  s.has_home_insurance                                    AS HAS_HOME_INSURANCE,
  s.has_health                                            AS HAS_HEALTH,
  s.has_card                                              AS HAS_CARD,
  s.has_investment                                        AS HAS_INVESTMENT,

  /* ---------- value ----------
     Bands are fixed INR thresholds, not quantiles. NTILE over the whole book
     would have no PARTITION BY, which makes every refresh recompute every row
     and defeats the point of an incremental dynamic table. Thresholds are set
     from the measured margin distribution (p50 29.5k, p75 84.5k, p90 154k,
     max 522k), so PLATINUM is roughly the top decile and GOLD the top quartile
     -- and they stay put when the book grows, which a quantile would not. */
  s.annual_premium_inr                                    AS ANNUAL_PREMIUM_INR,
  s.outstanding_credit_inr                                AS OUTSTANDING_CREDIT_INR,
  s.est_annual_margin_inr                                 AS EST_ANNUAL_MARGIN_INR,
  CASE
    WHEN s.est_annual_margin_inr >= 150000 THEN 'PLATINUM'
    WHEN s.est_annual_margin_inr >=  75000 THEN 'GOLD'
    WHEN s.est_annual_margin_inr >=  25000 THEN 'SILVER'
    WHEN s.est_annual_margin_inr >       0 THEN 'BRONZE'
    ELSE                                        'NO_ACTIVE_HOLDINGS'
  END                                                     AS RELATIONSHIP_VALUE_BAND,

  /* ---------- risk ----------
     DPD_BUCKET keeps RAW.LOAN's vocabulary so M5 can join on it, with an
     explicit NO_CREDIT_OBLIGATION for customers who hold no loan at all --
     distinct from CURRENT, which means "holds a loan and is up to date". */
  CASE
    WHEN s.worst_dpd_days IS NULL THEN 'NO_CREDIT_OBLIGATION'
    WHEN s.worst_dpd_days = 0     THEN 'CURRENT'
    WHEN s.worst_dpd_days <= 30   THEN '1-30'
    WHEN s.worst_dpd_days <= 60   THEN '31-60'
    WHEN s.worst_dpd_days <= 90   THEN '61-90'
    ELSE                               '90+'
  END                                                     AS DPD_BUCKET,
  s.missed_payments_12m                                   AS MISSED_PAYMENTS_12M,
  s.lapse_history                                         AS LAPSE_HISTORY,
  s.claim_ratio                                           AS CLAIM_RATIO,
  s.credit_utilisation                                    AS CREDIT_UTILISATION,
  /* Three independent arms, OR-ed: the book says arrears are deepening, the
     ledger says instalments are being missed, or the customer said so out loud
     in a conversation. Any one is enough to route to service over sales. */
  (      s.rising_dpd
     OR  s.missed_payments_6m >= 2
     OR  s.restructured
     OR  COALESCE(s.HARDSHIP_MENTIONS_90D, 0) > 0 )       AS HARDSHIP_SIGNAL,

  /* ---------- engagement ----------
     SENTIMENT_TREND distinguishes three kinds of not-knowing: never contacted,
     contacted too few times to fit a trend, and a real trend. Collapsing any
     of those into STABLE would read a deteriorating relationship as a calm
     one -- PROJECT_BRIEF D6. The raw slope is deliberately not carried. */
  s.interactions_90d                                      AS INTERACTIONS_90D,
  s.sentiment_now                                         AS SENTIMENT_NOW,
  COALESCE(s.sentiment_trend_raw, 'NO_CONTACT_HISTORY')   AS SENTIMENT_TREND,
  s.open_complaint                                        AS OPEN_COMPLAINT,
  DATEDIFF(day, s.LAST_CONTACT_AT, s.AS_OF_DATE)          AS LAST_CONTACT_DAYS,
  s.preferred_channel                                     AS PREFERRED_CHANNEL,

  /* ---------- eligibility ---------- */
  s.consent_call                                          AS CONSENT_CALL,
  s.consent_email                                         AS CONSENT_EMAIL,
  s.consent_sms                                           AS CONSENT_SMS,
  s.dnc_flag                                              AS DNC_FLAG,
  s.VULNERABILITY_FLAG                                    AS VULNERABILITY_FLAG,
  (s.KYC_STATUS = 'VERIFIED')                             AS KYC_CURRENT,

  /* ---------- gaps ----------
     Products the customer plausibly needs and does not hold. Every rule is
     gated on NOT holding the thing, and every label is drawn from the same
     nine-family vocabulary as PRODUCTS_HELD -- which is what makes the
     assertion below a literal set-intersection test rather than a guess.

     Note what is NOT here: a credit limit increase is an upsell on a product
     the customer already holds, so it is not a gap. It lives in
     NEXT_BEST_ACTION instead.

     Gates here are need and life stage only -- a dependant in the household, an
     insurable age, a financed asset, money that has just landed. Income-band
     and KYC gates were tried and removed: they are eligibility thresholds
     copied out of RAW.PRODUCT_CATALOG, and applying them here both double-counts
     what M5 evaluates properly and hides real gaps. The measured cost of that
     mistake was concrete -- an INCOME_BAND_RANK >= 4 gate on the investment gap
     cut it from 150 customers to 37, suppressing 113 of the 150 planted
     WEALTH_REFERRAL customers the demo is meant to surface. A gap here may well
     turn out to be an ineligible action in M5, and that is correct: this column
     describes the customer, not the offer. */
  ARRAY_COMPACT(ARRAY_CONSTRUCT(
    -- home loan with no cover on the asset: the clearest cross-silo gap
    IFF(s.has_home_loan AND NOT s.has_home_insurance,
        'Home Insurance', NULL),
    -- financed vehicle with no motor cover
    IFF(s.has_auto_loan AND NOT s.has_motor_insurance,
        'Motor Insurance', NULL),
    -- insurable age and no health cover
    IFF(NOT s.has_health
        AND s.AGE_YEARS BETWEEN 18 AND 65,
        'Health Insurance', NULL),
    -- dependants and no death cover
    IFF(NOT s.has_term
        AND s.household_size >= 2
        AND s.AGE_YEARS BETWEEN 21 AND 60,
        'Term Life', NULL),
    -- a large credit landed and nothing is invested
    IFF(NOT s.has_investment
        AND s.max_inbound_lumpsum_90d >= 1000000,
        'Investment (ULIP)', NULL),
    -- no card at an age where one is the norm
    IFF(NOT s.has_card
        AND s.AGE_YEARS BETWEEN 21 AND 65,
        'Credit Card', NULL)
  ))                                                      AS PRODUCT_GAP,

  /* ---------- timing ---------- */
  s.next_renewal_date                                     AS NEXT_RENEWAL_DATE,
  DATEDIFF(day, s.AS_OF_DATE, s.next_renewal_date)        AS DAYS_TO_RENEWAL,
  s.next_emi_date                                         AS NEXT_EMI_DATE

FROM assembled s;

/* ----------------------------------------------------------------------------
   Column contracts in the catalog. A dynamic table cannot declare these in its
   definition, so they are applied after creation on every run -- same pattern
   as 07.
   ---------------------------------------------------------------------------- */

COMMENT ON COLUMN GOLD.CUSTOMER_360.AS_OF_DATE IS
  'The calendar anchor every day-count in this row was computed against, from GOLD.C360_ASOF. Read this before trusting DAYS_TO_RENEWAL, LAST_CONTACT_DAYS or TENURE_YEARS: with TARGET_LAG = 1 day they are at most a day stale in normal operation, but a dynamic table only refreshes when its inputs change, so a long gap with no data movement leaves them anchored here rather than on today. Re-anchor by re-running sql/08 or updating GOLD.C360_ASOF.';

COMMENT ON COLUMN GOLD.CUSTOMER_360.PRODUCT_COUNT IS
  'Number of distinct product FAMILIES held, not number of contracts. Equal to ARRAY_SIZE(PRODUCTS_HELD) by construction. A customer with three motor policies counts one.';

COMMENT ON COLUMN GOLD.CUSTOMER_360.PRODUCTS_HELD IS
  'Product families currently held, active contracts only, in a fixed order from the same nine-label vocabulary as PRODUCT_GAP. Shares that vocabulary so the "no gap already held" assertion is a literal set intersection.';

COMMENT ON COLUMN GOLD.CUSTOMER_360.PRODUCT_GAP IS
  'Products the customer plausibly needs and does not hold, from holdings + life stage + transaction behaviour. Every entry is gated on NOT holding it, and ARRAY_INTERSECTION(PRODUCT_GAP, PRODUCTS_HELD) is asserted empty. This is a statement about the customer, NOT an eligibility verdict: gates are need and life stage only, and income-band and KYC thresholds are deliberately absent because they belong to M5 -- an income gate on the investment gap was measured suppressing 113 of the 150 planted WEALTH_REFERRAL customers. A credit limit increase is also absent: it is an upsell on a held product, not a gap.';

COMMENT ON COLUMN GOLD.CUSTOMER_360.EST_ANNUAL_MARGIN_INR IS
  'Modelled annual margin: annualised premium x MARGIN_RATE for active policies, plus outstanding balance x MARGIN_RATE for active loans and cards, rates taken per product code from RAW.PRODUCT_CATALOG. The credit terms are a spread proxy on a stock rather than a measured flow, so treat this as a ranking quantity, not a profit-and-loss figure.';

COMMENT ON COLUMN GOLD.CUSTOMER_360.RELATIONSHIP_VALUE_BAND IS
  'Fixed INR thresholds on EST_ANNUAL_MARGIN_INR: PLATINUM >=150k, GOLD >=75k, SILVER >=25k, BRONZE >0, else NO_ACTIVE_HOLDINGS. Set from the measured distribution (p50 29.5k, p75 84.5k, p90 154k) so PLATINUM is about the top decile. Deliberately not NTILE: an unpartitioned window function would force every row to recompute on every refresh.';

COMMENT ON COLUMN GOLD.CUSTOMER_360.SENTIMENT_TREND IS
  'Passed through from CURATED.CUSTOMER_INTERACTION_ROLLUP, with NO_CONTACT_HISTORY added for customers the rollup does not cover. Four values plus that one: DETERIORATING / STABLE / IMPROVING / INSUFFICIENT_DATA / NO_CONTACT_HISTORY. INSUFFICIENT_DATA and NO_CONTACT_HISTORY both mean UNKNOWN and must never be read as STABLE. The underlying slope is diagnostic-only and is deliberately not carried into GOLD -- see PROJECT_BRIEF D6.';

COMMENT ON COLUMN GOLD.CUSTOMER_360.DPD_BUCKET IS
  'Worst arrears bucket across active loans, in RAW.LOAN vocabulary (CURRENT / 1-30 / 31-60 / 61-90 / 90+) so M5 can join on it, plus NO_CREDIT_OBLIGATION for customers holding no loan. NO_CREDIT_OBLIGATION is not CURRENT: one has no exposure, the other has exposure and is up to date.';

COMMENT ON COLUMN GOLD.CUSTOMER_360.HARDSHIP_SIGNAL IS
  'True on any of four arms: DPD rising across three consecutive readings, two or more missed instalments in six months, a restructured loan, or hardship raised in conversation in the last 90 days. Deliberately broad -- this routes a customer to service instead of sales, and a false positive costs a cross-sell while a false negative costs a vulnerable customer being marketed to.';

COMMENT ON COLUMN GOLD.CUSTOMER_360.CLAIM_RATIO IS
  'Approved amount over claimed amount across all claims ever. NULL means never claimed, which is NOT the same as 0 (claimed and recovered nothing). Unsettled and rejected claims carry a NULL approved amount and count as zero recovered.';

COMMENT ON COLUMN GOLD.CUSTOMER_360.DNC_FLAG IS
  'Do-not-contact registry marker on the CALL or SMS channel -- the channels a DNC registry governs in this market. 1,330 customers (27%). NOT an any-channel reading, which would flag 2,285 (46%) and stop discriminating. For a specific channel the authoritative columns are CONSENT_CALL / CONSENT_EMAIL / CONSENT_SMS, which already fold DNC, opt-in and the validity window together.';

COMMENT ON COLUMN GOLD.CUSTOMER_360.CONSENT_CALL IS
  'Permission to contact by call as of AS_OF_DATE: opted in AND not DNC AND inside the consent validity window, all three. Never NULL. Distinct from PREFERRED_CHANNEL, which is a behavioural preference and carries no permission.';

COMMENT ON COLUMN GOLD.CUSTOMER_360.PREFERRED_CHANNEL IS
  'The channel that has historically produced engagement (CONVERTED or INTERESTED) in RAW.CAMPAIGN_HISTORY, tie-broken by fewest non-responses then alphabetically. A behavioural preference, NOT a permission -- always check the matching CONSENT_* column before using it.';

COMMENT ON COLUMN GOLD.CUSTOMER_360.NEXT_EMI_DATE IS
  'Projected from the loan schedule (first monthly anniversary of FIRST_EMI_DATE after AS_OF_DATE, NULL past the final instalment), NOT read from RAW.REPAYMENT. The ledger is historical and holds no future dues, so looking it up there would return an instalment already fallen due.';

COMMENT ON COLUMN GOLD.CUSTOMER_360.LAST_CONTACT_DAYS IS
  'Days from the last interaction to AS_OF_DATE, recomputed here against this table anchor rather than reusing CUSTOMER_INTERACTION_ROLLUP.DAYS_SINCE_LAST_CONTACT, which was frozen against the anchor in force when 07 last ran. NULL means never contacted.';

/* ============================================================================
   GOLD.CUSTOMER_TIMELINE
   ----------------------------------------------------------------------------
   One row per event, unioned across the silos, chronological per customer.
   This is what makes the 360 feel like a real customer record rather than a
   feature vector.

   Almost every timestamp here is absolute and needs no calendar anchor. The
   one exception is POLICY_LAPSED (see below), which reads GOLD.C360_ASOF in a
   projection -- so this table takes the same anchor-table treatment as
   CUSTOMER_360 and stays incremental for the same reason.

   Two things worth knowing before reading it:

   - Routine EMI and premium payments are included, not just exceptions. They
     are ~half the rows, and they are the reason "paid on time for three years"
     is visible at all. Filter by EVENT_TYPE in the app rather than dropping
     them here.
   - Service tickets are in, although the milestone brief named only policies,
     claims, loans, payments, interactions and campaigns. OPEN_COMPLAINT in the
     360 is sourced from tickets, so a timeline without them could not evidence
     the one flag most likely to be questioned in the demo.

   POLICY_LAPSED has no source timestamp -- RAW.POLICY records no lapse date --
   so it is dated at the renewal the policy failed to complete: RENEWAL_DATE
   less one year where RENEWAL_DATE is still ahead of the anchor. Using
   RENEWAL_DATE itself was tried first and dated all 675 lapse events in the
   future, because the generator advances RENEWAL_DATE regardless of status.
   An acknowledged proxy either way, but one that lands in the past.
   ============================================================================ */

CREATE OR REPLACE DYNAMIC TABLE GOLD.CUSTOMER_TIMELINE
  TARGET_LAG   = '1 day'
  WAREHOUSE    = COCO_WH
  REFRESH_MODE = INCREMENTAL
  COMMENT      = 'Chronological event stream, one row per event per customer, unioned across policies, claims, loans, payments, interactions, service tickets and campaigns. Rendered by the Streamlit app. All timestamps are absolute except POLICY_LAPSED, which is dated at the renewal the policy failed to complete and therefore reads the GOLD.C360_ASOF anchor. Does not read the quarantined ground-truth table (asserted in sql/08; the name is deliberately not spelled out here so the assertion cannot match its own documentation).'
AS
WITH cal AS (SELECT AS_OF_DATE FROM GOLD.C360_ASOF),
ev AS (

  /* ---- policies ---- */
  SELECT p.CUSTOMER_ID,
         'POLICY_ISSUED'                                          AS event_type,
         p.START_DATE::TIMESTAMP_NTZ                              AS occurred_at,
         'Policy issued — ' || INITCAP(p.POLICY_TYPE)             AS title,
         'Premium ₹' || TO_VARCHAR(p.PREMIUM_INR, '999,999,999')
           || ' ' || LOWER(p.PREMIUM_FREQUENCY)
           || ', sum assured ₹' || TO_VARCHAR(p.SUM_ASSURED_INR, '999,999,999')
           || ', sold via ' || LOWER(p.CHANNEL_SOLD)              AS detail,
         'RAW.POLICY'                                             AS source_table,
         p.POLICY_NUMBER                                          AS source_id
  FROM RAW.POLICY p

  UNION ALL
  SELECT p.CUSTOMER_ID,
         'POLICY_LAPSED',
         IFF(p.RENEWAL_DATE > a.AS_OF_DATE,
             DATEADD(year, -1, p.RENEWAL_DATE),
             p.RENEWAL_DATE)::TIMESTAMP_NTZ,
         'Policy lapsed — ' || INITCAP(p.POLICY_TYPE),
         'Cover ceased. Annual premium at lapse ₹'
           || TO_VARCHAR(p.PREMIUM_INR, '999,999,999')
           || '. Timestamp is the renewal the policy failed to complete; RAW.POLICY records no lapse date.',
         'RAW.POLICY',
         p.POLICY_NUMBER
  FROM RAW.POLICY p
  CROSS JOIN cal a
  WHERE p.LAPSE_FLAG OR p.STATUS = 'LAPSED'

  /* ---- claims ---- */
  UNION ALL
  SELECT cl.CUSTOMER_ID,
         'CLAIM_FILED',
         cl.FILED_AT,
         'Claim filed — ' || INITCAP(REPLACE(cl.CLAIM_TYPE, '_', ' ')),
         'Claimed ₹' || TO_VARCHAR(cl.CLAIM_AMOUNT_INR, '999,999,999')
           || ', status ' || LOWER(cl.STATUS),
         'RAW.CLAIM',
         cl.CLAIM_NUMBER
  FROM RAW.CLAIM cl

  UNION ALL
  SELECT cl.CUSTOMER_ID,
         'CLAIM_SETTLED',
         cl.SETTLED_AT,
         'Claim settled — ' || INITCAP(REPLACE(cl.CLAIM_TYPE, '_', ' ')),
         'Approved ₹' || TO_VARCHAR(COALESCE(cl.APPROVED_AMOUNT_INR, 0), '999,999,999')
           || ' of ₹' || TO_VARCHAR(cl.CLAIM_AMOUNT_INR, '999,999,999')
           || ' claimed, in ' || TO_VARCHAR(cl.SETTLEMENT_DAYS) || ' days',
         'RAW.CLAIM',
         cl.CLAIM_NUMBER
  FROM RAW.CLAIM cl
  WHERE cl.SETTLED_AT IS NOT NULL

  /* ---- loans ---- */
  UNION ALL
  SELECT l.CUSTOMER_ID,
         'LOAN_DISBURSED',
         l.DISBURSAL_DATE::TIMESTAMP_NTZ,
         'Loan disbursed — ' || INITCAP(l.LOAN_TYPE),
         'Principal ₹' || TO_VARCHAR(l.PRINCIPAL_INR, '999,999,999')
           || ' over ' || TO_VARCHAR(l.TENURE_MONTHS) || ' months at '
           || TO_VARCHAR(l.INTEREST_RATE_PCT) || '%, EMI ₹'
           || TO_VARCHAR(l.EMI_INR, '999,999,999'),
         'RAW.LOAN',
         l.LOAN_ACCOUNT_NO
  FROM RAW.LOAN l

  /* ---- payments ---- */
  UNION ALL
  SELECT r.CUSTOMER_ID,
         CASE WHEN r.MISSED_FLAG THEN 'PAYMENT_MISSED'
              WHEN r.LATE_FLAG   THEN 'PAYMENT_LATE'
              ELSE                    'PAYMENT_ON_TIME' END,
         COALESCE(r.PAID_DATE, r.DUE_DATE)::TIMESTAMP_NTZ,
         CASE WHEN r.MISSED_FLAG THEN 'Instalment missed — '
              WHEN r.LATE_FLAG   THEN 'Instalment paid late — '
              ELSE                    'Instalment paid — ' END
           || IFF(r.OBLIGATION_TYPE = 'LOAN_EMI', 'loan EMI', 'policy premium'),
         '₹' || TO_VARCHAR(r.DUE_AMOUNT_INR, '999,999,999')
           || ' due ' || TO_VARCHAR(r.DUE_DATE, 'DD Mon YYYY')
           || IFF(r.MISSED_FLAG,
                  ', not received',
                  ', paid ' || TO_VARCHAR(r.PAID_DATE, 'DD Mon YYYY')
                    || IFF(COALESCE(r.DAYS_LATE, 0) > 0,
                           ' (' || TO_VARCHAR(r.DAYS_LATE) || ' days late)', '')),
         'RAW.REPAYMENT',
         TO_VARCHAR(r.REPAYMENT_ID)
  FROM RAW.REPAYMENT r

  /* ---- interactions, with the AI signals already paid for in 05 ---- */
  UNION ALL
  SELECT i.CUSTOMER_ID,
         'INTERACTION',
         i.OCCURRED_AT,
         COALESCE(NULLIF(TRIM(i.SUBJECT), ''),
                  INITCAP(REPLACE(i.ARTEFACT_TYPE, '_', ' '))),
         COALESCE(g.SUMMARY_25W, LEFT(i.BODY, 300))
           || IFF(g.SENTIMENT_OVERALL IS NOT NULL,
                  '  ·  sentiment: ' || g.SENTIMENT_OVERALL, '')
           || IFF(g.INTENT IS NOT NULL,
                  '  ·  intent: ' || LOWER(REPLACE(g.INTENT, '_', ' ')), '')
           || '  ·  ' || LOWER(i.CHANNEL) || ', ' || LOWER(i.DIRECTION),
         'RAW.INTERACTION',
         i.INTERACTION_ID
  FROM RAW.INTERACTION i
  LEFT JOIN CURATED.INTERACTION_SIGNALS_GATED g
         ON g.INTERACTION_ID = i.INTERACTION_ID

  /* ---- service tickets ---- */
  UNION ALL
  SELECT t.CUSTOMER_ID,
         IFF(t.IS_COMPLAINT, 'COMPLAINT_RAISED', 'TICKET_OPENED'),
         t.OPENED_AT,
         IFF(t.IS_COMPLAINT, 'Complaint raised — ', 'Service request — ')
           || INITCAP(REPLACE(t.CATEGORY, '_', ' ')),
         'Severity ' || TO_VARCHAR(t.SEVERITY) || ', ' || LOWER(t.CHANNEL)
           || ', status ' || LOWER(t.STATUS)
           || IFF(t.SUB_CATEGORY IS NOT NULL,
                  ' — ' || INITCAP(REPLACE(t.SUB_CATEGORY, '_', ' ')), ''),
         'RAW.SERVICE_TICKET',
         t.TICKET_NUMBER
  FROM RAW.SERVICE_TICKET t

  UNION ALL
  SELECT t.CUSTOMER_ID,
         'TICKET_CLOSED',
         t.CLOSED_AT,
         'Ticket closed — ' || INITCAP(REPLACE(t.CATEGORY, '_', ' ')),
         'Resolved in ' || TO_VARCHAR(ROUND(t.RESOLUTION_HOURS, 1)) || ' hours',
         'RAW.SERVICE_TICKET',
         t.TICKET_NUMBER
  FROM RAW.SERVICE_TICKET t
  WHERE t.CLOSED_AT IS NOT NULL

  /* ---- outbound campaigns ---- */
  UNION ALL
  SELECT ca.CUSTOMER_ID,
         'CAMPAIGN_CONTACT',
         ca.CONTACTED_AT,
         'Outbound contact — ' || ca.CAMPAIGN_NAME,
         LOWER(ca.CHANNEL) || ', outcome ' || LOWER(REPLACE(ca.OUTCOME, '_', ' '))
           || IFF(ca.CONVERTED_FLAG,
                  ', converted at ₹' || TO_VARCHAR(COALESCE(ca.REVENUE_INR, 0), '999,999,999'),
                  ''),
         'RAW.CAMPAIGN_HISTORY',
         TO_VARCHAR(ca.CAMPAIGN_CONTACT_ID)
  FROM RAW.CAMPAIGN_HISTORY ca
)
SELECT
  /* Stable surrogate. Source table plus natural key plus event type is unique
     because the only table contributing two event types for one key -- POLICY,
     CLAIM, SERVICE_TICKET -- differ in the event_type component. */
  e.source_table || '|' || e.source_id || '|' || e.event_type AS EVENT_ID,
  e.CUSTOMER_ID                                              AS CUSTOMER_ID,
  e.event_type                                               AS EVENT_TYPE,
  e.occurred_at                                              AS OCCURRED_AT,
  e.title                                                    AS TITLE,
  e.detail                                                   AS DETAIL,
  e.source_table                                             AS SOURCE_TABLE,
  e.source_id                                                AS SOURCE_ID
FROM ev e
WHERE e.occurred_at IS NOT NULL;

COMMENT ON COLUMN GOLD.CUSTOMER_TIMELINE.EVENT_ID IS
  'Stable surrogate key: SOURCE_TABLE|SOURCE_ID|EVENT_TYPE. Unique because the three tables that emit two event types each (POLICY, CLAIM, SERVICE_TICKET) differ in the EVENT_TYPE component.';

COMMENT ON COLUMN GOLD.CUSTOMER_TIMELINE.EVENT_TYPE IS
  'POLICY_ISSUED, POLICY_LAPSED, CLAIM_FILED, CLAIM_SETTLED, LOAN_DISBURSED, PAYMENT_ON_TIME, PAYMENT_LATE, PAYMENT_MISSED, INTERACTION, COMPLAINT_RAISED, TICKET_OPENED, TICKET_CLOSED, CAMPAIGN_CONTACT. Routine on-time payments are included on purpose and are about half the rows; filter here in the app rather than excluding them from the table.';

COMMENT ON COLUMN GOLD.CUSTOMER_TIMELINE.OCCURRED_AT IS
  'Absolute event timestamp, never NULL (null-timestamp rows are filtered out). For POLICY_LAPSED this is the renewal the policy failed to complete -- RENEWAL_DATE less one year where RENEWAL_DATE is still ahead of the anchor -- because RAW.POLICY records no lapse date. An acknowledged proxy, not a measured lapse time. Note that a handful of PAYMENT_LATE and CLAIM_SETTLED events are dated after the anchor: those timestamps come straight from RAW and are a seed-data artefact, not a derivation here.';

COMMENT ON COLUMN GOLD.CUSTOMER_TIMELINE.DETAIL IS
  'Human-readable one-liner. For INTERACTION rows this carries the AI 25-word summary, sentiment and intent already paid for in sql/05, falling back to the first 300 characters of the body where the confidence gate withheld a signal.';

/* ============================================================================
   GOLD.NEXT_BEST_ACTION  —  PLACEHOLDER CONTENTS, FINAL COLUMN CONTRACT
   ----------------------------------------------------------------------------
   The real engine is M5 (deterministic eligibility and EV) plus M6 (LLM
   reasons). This table exists now so the Streamlit screens can be built
   against a stable shape and stable types, and so the app does not have to be
   rewritten when the engine lands.

   The contract is exactly the twelve columns requested and no more. Nothing is
   added -- not REASON_SOURCE, not a placeholder marker column -- because a
   column the app can read is part of the contract whether or not it is
   intended to be. The placeholder-ness is carried in the table COMMENT and as
   a visible '[PLACEHOLDER]' prefix on RATIONALE, so it shows up on screen
   during development and cannot be mistaken for engine output.

   What is genuinely real here, and worth keeping when the engine replaces the
   contents:
     - RANK is dense 1..3 for every customer, always exactly three rows.
     - EXPECTED_VALUE_INR is arithmetic, not a literal:
       propensity x value_at_stake x margin_rate, with margin_rate and ticket
       size read from RAW.PRODUCT_CATALOG. Wrong inputs, right shape.
     - ELIGIBILITY_TRACE evaluates five real rules against CUSTOMER_360 and
       records the observed value per rule, so the compliance panel has
       something true to render.
     - EVIDENCE_IDS points at the customer's actual most recent interaction and
       open complaint ticket where those exist.

   What is fake and must not be trusted or demoed as a result:
     - PROPENSITY is a seeded hash, not a model. Deterministic via RAW.RND so
       the app sees stable numbers between runs, which is the only property it
       needs from it.
     - Action selection is a priority ladder over CUSTOMER_360 flags, not a
       ranked EV competition against an action catalogue.
     - RATIONALE is templated, not generated.

   A plain table, not a dynamic table: its contents are meant to be replaced
   wholesale by M5/M6, and a dynamic table's contents cannot be.
   ============================================================================ */

CREATE OR REPLACE TABLE GOLD.NEXT_BEST_ACTION AS
WITH c AS (SELECT * FROM GOLD.CUSTOMER_360),

/* most recent interaction and open complaint, for EVIDENCE_IDS */
last_ix AS (
  SELECT CUSTOMER_ID, INTERACTION_ID
  FROM (SELECT CUSTOMER_ID, INTERACTION_ID,
               ROW_NUMBER() OVER (PARTITION BY CUSTOMER_ID ORDER BY OCCURRED_AT DESC) rn
        FROM RAW.INTERACTION)
  WHERE rn = 1
),
open_tkt AS (
  SELECT CUSTOMER_ID, TICKET_NUMBER
  FROM (SELECT CUSTOMER_ID, TICKET_NUMBER,
               ROW_NUMBER() OVER (PARTITION BY CUSTOMER_ID ORDER BY SEVERITY DESC, OPENED_AT DESC) rn
        FROM RAW.SERVICE_TICKET
        WHERE IS_COMPLAINT AND STATUS IN ('OPEN','IN_PROGRESS'))
  WHERE rn = 1
),

/* product economics, so EV arithmetic reads real rates rather than literals */
cat AS (SELECT PRODUCT_CODE, AVG_TICKET_SIZE_INR, MARGIN_RATE FROM RAW.PRODUCT_CATALOG),

/* ------------------------------------------------------------------------
   Candidate actions. One branch per action, each with the trigger predicate,
   the channel it would run on, and the value/margin terms EV multiplies.

   PRIORITY encodes "suppression and service beat sales" (principle 3): the
   hardship and service branches sort ahead of every cross-sell regardless of
   how large the cross-sell EV is.
   ------------------------------------------------------------------------ */
cand AS (

  /* -- service and retention: priority 10-40 -- */
  SELECT c.CUSTOMER_ID, 10 AS priority,
         'COLLECTIONS_HARDSHIP_OUTREACH'      AS action_code,
         'Hardship and restructure review'    AS action_name,
         'CALL'                               AS channel,
         c.outstanding_credit_inr             AS value_at_stake,
         0.0                                  AS margin_rate,
         'Arrears deepening or hardship raised; route to collections support, not sales.' AS rationale_body,
         'This is a service contact. No product is being offered and no sale may be attempted on this call.' AS disclosure
  FROM c WHERE c.HARDSHIP_SIGNAL

  UNION ALL
  SELECT c.CUSTOMER_ID, 20,
         'RETENTION_SAVE_CALL', 'Retention save call', 'CALL',
         c.annual_premium_inr, 0.1800,
         'Open complaint with a renewal inside 30 days. Save the relationship before it lapses; do not cross-sell.',
         'Retention conversation. Any change to cover must be confirmed in writing before the renewal date.'
  FROM c WHERE c.OPEN_COMPLAINT AND c.DAYS_TO_RENEWAL IS NOT NULL AND c.DAYS_TO_RENEWAL <= 30

  UNION ALL
  SELECT c.CUSTOMER_ID, 30,
         'SERVICE_RECOVERY_CALL', 'Service recovery call', 'CALL',
         c.annual_premium_inr, 0.0,
         'Unresolved complaint on file. Close the loop before any commercial conversation.',
         'Service contact regarding an open complaint. Grievance escalation rights apply and must be restated.'
  FROM c WHERE c.OPEN_COMPLAINT

  UNION ALL
  SELECT c.CUSTOMER_ID, 40,
         'KYC_REFRESH_OUTREACH', 'KYC refresh', 'SMS',
         0, 0.0,
         'KYC is not current, which blocks every regulated product action until refreshed.',
         'Regulatory KYC refresh request. No product is being sold.'
  FROM c WHERE NOT c.KYC_CURRENT

  /* -- cross-sell against a measured gap: priority 50 -- */
  UNION ALL
  SELECT c.CUSTOMER_ID, 50,
         'HOME_PROTECTION_CROSS_SELL', 'Home cover for a financed property', c.PREFERRED_CHANNEL,
         cat.AVG_TICKET_SIZE_INR, cat.MARGIN_RATE,
         'Holds a home loan with no home insurance. The asset securing the loan is uninsured.',
         'Indicative premium only. Cover is subject to underwriting and the policy wording prevails.'
  FROM c JOIN cat ON cat.PRODUCT_CODE = 'INS_HOME_LOAN_LINKED'
  WHERE ARRAY_CONTAINS('Home Insurance'::VARIANT, c.PRODUCT_GAP)

  UNION ALL
  SELECT c.CUSTOMER_ID, 50,
         'MOTOR_PROTECTION_CROSS_SELL', 'Motor cover for a financed vehicle', c.PREFERRED_CHANNEL,
         cat.AVG_TICKET_SIZE_INR, cat.MARGIN_RATE,
         'Holds an auto loan with no motor insurance on file.',
         'Indicative premium only. Cover is subject to underwriting and the policy wording prevails.'
  FROM c JOIN cat ON cat.PRODUCT_CODE = 'INS_MOTOR_COMP'
  WHERE ARRAY_CONTAINS('Motor Insurance'::VARIANT, c.PRODUCT_GAP)

  UNION ALL
  SELECT c.CUSTOMER_ID, 50,
         'HEALTH_COVER_CROSS_SELL', 'Health cover', c.PREFERRED_CHANNEL,
         cat.AVG_TICKET_SIZE_INR, cat.MARGIN_RATE,
         'No health cover held at an age and income where it is the standard first protection product.',
         'Indicative premium only. Waiting periods and pre-existing condition exclusions apply.'
  FROM c JOIN cat ON cat.PRODUCT_CODE = 'INS_HEALTH_IND'
  WHERE ARRAY_CONTAINS('Health Insurance'::VARIANT, c.PRODUCT_GAP)

  UNION ALL
  SELECT c.CUSTOMER_ID, 50,
         'TERM_LIFE_CROSS_SELL', 'Term life cover', c.PREFERRED_CHANNEL,
         cat.AVG_TICKET_SIZE_INR, cat.MARGIN_RATE,
         'Dependants in the household and no death cover held.',
         'Indicative premium only. Subject to medical underwriting; the policy wording prevails.'
  FROM c JOIN cat ON cat.PRODUCT_CODE = 'INS_TERM_PLAIN'
  WHERE ARRAY_CONTAINS('Term Life'::VARIANT, c.PRODUCT_GAP)

  UNION ALL
  SELECT c.CUSTOMER_ID, 50,
         'WEALTH_REFERRAL', 'Referral to wealth advisory', 'CALL',
         cat.AVG_TICKET_SIZE_INR, cat.MARGIN_RATE,
         'A large inbound credit landed in the last 90 days with no investment product held.',
         'Referral to an advised conversation. Market-linked returns are not guaranteed and capital is at risk.'
  FROM c JOIN cat ON cat.PRODUCT_CODE = 'INS_ULIP_BAL'
  WHERE ARRAY_CONTAINS('Investment (ULIP)'::VARIANT, c.PRODUCT_GAP)

  UNION ALL
  SELECT c.CUSTOMER_ID, 50,
         'CARD_CROSS_SELL', 'Credit card', c.PREFERRED_CHANNEL,
         cat.AVG_TICKET_SIZE_INR, cat.MARGIN_RATE,
         'No card held, KYC verified, and income band supports an entry-tier limit.',
         'Indicative limit only. Subject to credit assessment. Interest applies to revolved balances.'
  FROM c JOIN cat ON cat.PRODUCT_CODE = 'BNK_CARD_GOLD'
  WHERE ARRAY_CONTAINS('Credit Card'::VARIANT, c.PRODUCT_GAP)

  /* -- upsell on a held product: priority 60. Not a PRODUCT_GAP, by design. -- */
  UNION ALL
  SELECT c.CUSTOMER_ID, 60,
         'CARD_LIMIT_INCREASE', 'Credit limit increase', c.PREFERRED_CHANNEL,
         cat.AVG_TICKET_SIZE_INR, cat.MARGIN_RATE,
         'Card utilisation running high on a clean repayment record.',
         'Subject to credit assessment. A higher limit increases the maximum interest payable.'
  FROM c JOIN cat ON cat.PRODUCT_CODE = 'BNK_CARD_LIMIT_INC'
  WHERE c.HAS_CARD AND c.CREDIT_UTILISATION > 0.50 AND c.MISSED_PAYMENTS_12M = 0

  /* -- fallbacks: priority 90+. Guarantee three rows for every customer. -- */
  UNION ALL
  SELECT c.CUSTOMER_ID, 90,
         'ANNUAL_REVIEW_CALL', 'Annual relationship review', 'CALL',
         c.est_annual_margin_inr, 0.0,
         'No stronger signal on file. A periodic review keeps the record current.',
         'Review conversation. No product is being offered.'
  FROM c

  UNION ALL
  SELECT c.CUSTOMER_ID, 91,
         'DIGITAL_ENROLMENT_NUDGE', 'Digital servicing enrolment', 'EMAIL',
         0, 0.0,
         'Servicing volume can be reduced by moving routine requests to self-service.',
         'Servicing communication. No product is being offered.'
  FROM c

  UNION ALL
  SELECT c.CUSTOMER_ID, 92,
         'CONTACT_DETAILS_REFRESH', 'Confirm contact details', 'SMS',
         0, 0.0,
         'Contact and consent details are worth confirming before any outbound campaign.',
         'Data accuracy request. No product is being offered.'
  FROM c
),

/* propensity is a seeded hash keyed on (customer, action) -- stable between
   runs so the app sees steady numbers, and not a model in any sense */
priced AS (
  SELECT
    cd.*,
    ROUND(0.05 + 0.45 * RAW.RND('nba|' || cd.CUSTOMER_ID || '|' || cd.action_code), 4) AS propensity
  FROM cand cd
),
ranked AS (
  SELECT
    p.*,
    ROUND(p.propensity * p.value_at_stake * p.margin_rate)                    AS expected_value_inr,
    ROW_NUMBER() OVER (PARTITION BY p.CUSTOMER_ID
                       ORDER BY p.priority ASC,
                                p.propensity * p.value_at_stake * p.margin_rate DESC,
                                p.action_code ASC)                            AS rnk
  FROM priced p
)
SELECT
  r.CUSTOMER_ID                                          AS CUSTOMER_ID,
  r.rnk                                                  AS RANK,
  r.action_code                                          AS ACTION_CODE,
  r.action_name                                          AS ACTION_NAME,
  r.channel                                              AS CHANNEL,
  r.propensity                                           AS PROPENSITY,
  r.expected_value_inr                                   AS EXPECTED_VALUE_INR,
  '[PLACEHOLDER] ' || r.rationale_body                   AS RATIONALE,
  ARRAY_COMPACT(ARRAY_CONSTRUCT(li.INTERACTION_ID, ot.TICKET_NUMBER))
                                                         AS EVIDENCE_IDS,
  r.disclosure                                           AS DISCLOSURE,
  /* Five rules evaluated for real against CUSTOMER_360, each carrying the
     value it fired on so the verdict can be replayed. M5 replaces this with
     GOLD.ELIGIBILITY_TRACE rows; the shape here is what the app renders. */
  ARRAY_CONSTRUCT(
    OBJECT_CONSTRUCT('rule', 'CHANNEL_CONSENT_PRESENT',
                     'verdict', IFF(CASE r.channel
                                      WHEN 'CALL'  THEN c.CONSENT_CALL
                                      WHEN 'EMAIL' THEN c.CONSENT_EMAIL
                                      WHEN 'SMS'   THEN c.CONSENT_SMS
                                      ELSE FALSE END, 'PASS', 'FAIL'),
                     'observed', 'channel=' || r.channel),
    OBJECT_CONSTRUCT('rule', 'NOT_ON_DNC_REGISTRY',
                     'verdict', IFF(NOT c.DNC_FLAG, 'PASS', 'FAIL'),
                     'observed', 'dnc_flag=' || c.DNC_FLAG::VARCHAR),
    OBJECT_CONSTRUCT('rule', 'KYC_CURRENT',
                     'verdict', IFF(c.KYC_CURRENT, 'PASS', 'FAIL'),
                     'observed', 'kyc_current=' || c.KYC_CURRENT::VARCHAR),
    OBJECT_CONSTRUCT('rule', 'ARREARS_GATE',
                     'verdict', IFF(c.DPD_BUCKET IN ('CURRENT','NO_CREDIT_OBLIGATION'), 'PASS', 'FAIL'),
                     'observed', 'dpd_bucket=' || c.DPD_BUCKET),
    OBJECT_CONSTRUCT('rule', 'VULNERABILITY_GATE',
                     'verdict', IFF(NOT c.VULNERABILITY_FLAG, 'PASS', 'FAIL'),
                     'observed', 'vulnerability_flag=' || c.VULNERABILITY_FLAG::VARCHAR)
  )                                                      AS ELIGIBILITY_TRACE,
  CURRENT_TIMESTAMP()                                    AS GENERATED_AT
FROM ranked r
JOIN GOLD.CUSTOMER_360 c ON c.CUSTOMER_ID = r.CUSTOMER_ID
LEFT JOIN last_ix  li ON li.CUSTOMER_ID = r.CUSTOMER_ID
LEFT JOIN open_tkt ot ON ot.CUSTOMER_ID = r.CUSTOMER_ID
WHERE r.rnk <= 3;

COMMENT ON TABLE GOLD.NEXT_BEST_ACTION IS
  'PLACEHOLDER CONTENTS, FINAL COLUMN CONTRACT. Exists so the Streamlit screens can be built against a stable shape before the real engine lands. PROPENSITY is a seeded hash and not a model; action selection is a priority ladder over CUSTOMER_360 flags, not an EV competition; RATIONALE is templated and prefixed [PLACEHOLDER]. EXPECTED_VALUE_INR, ELIGIBILITY_TRACE and EVIDENCE_IDS are computed for real and are the parts worth keeping. M5 (sql/21-23) and M6 (sql/24) replace the contents; the twelve columns do not change.';

COMMENT ON COLUMN GOLD.NEXT_BEST_ACTION.PROPENSITY IS
  'PLACEHOLDER. A seeded hash of (customer, action) via RAW.RND, in 0.05-0.50. Deterministic between runs so the app sees stable values, which is the only property it needs. Not a model output and must not be demoed as one.';

COMMENT ON COLUMN GOLD.NEXT_BEST_ACTION.EXPECTED_VALUE_INR IS
  'propensity x value_at_stake x margin_rate, rounded to rupees. Real arithmetic on a placeholder propensity: ticket sizes and margin rates come from RAW.PRODUCT_CATALOG, so the shape and magnitudes are right even though the propensity is not. Service and retention actions carry a zero or blended margin and so rank on priority rather than value.';

COMMENT ON COLUMN GOLD.NEXT_BEST_ACTION.RANK IS
  'Dense 1..3 per customer, always exactly three rows. Ordered by an explicit priority ladder first (hardship and service outrank every cross-sell, per product principle 3) and only then by expected value.';

COMMENT ON COLUMN GOLD.NEXT_BEST_ACTION.ELIGIBILITY_TRACE IS
  'Array of {rule, verdict, observed} objects, five rules evaluated for real against GOLD.CUSTOMER_360: channel consent, DNC registry, KYC currency, arrears gate, vulnerability gate. Each carries the value it fired on so the verdict is replayable. M5 replaces this from GOLD.ELIGIBILITY_TRACE; the object shape is what the app renders and should be treated as fixed.';

COMMENT ON COLUMN GOLD.NEXT_BEST_ACTION.EVIDENCE_IDS IS
  'The customer''s most recent RAW.INTERACTION id and highest-severity open complaint ticket number, where each exists. Real references, empty array where the customer has neither. M6 extends this to the specific passages a reason was grounded in.';

/* ============================================================================
   VERIFY
   ============================================================================ */

SELECT 'row counts' AS check_name,
       (SELECT COUNT(*) FROM GOLD.CUSTOMER_360)                    AS customer_360,
       (SELECT COUNT(*) FROM RAW.CUSTOMER)                         AS raw_customers,
       (SELECT COUNT(*) FROM GOLD.CUSTOMER_TIMELINE)               AS timeline_events,
       (SELECT COUNT(DISTINCT CUSTOMER_ID) FROM GOLD.CUSTOMER_TIMELINE) AS timeline_customers,
       (SELECT COUNT(*) FROM GOLD.NEXT_BEST_ACTION)                AS nba_rows,
       (SELECT AS_OF_DATE FROM GOLD.C360_ASOF)                     AS anchor_date;

/* ----------------------------------------------------------------------------
   A1. No customer carries a product gap they already hold.

   This is a literal set-intersection test, which is only possible because
   PRODUCT_GAP and PRODUCTS_HELD are drawn from the same nine-label vocabulary.
   A name-matching assertion over free labels would pass vacuously.
   ---------------------------------------------------------------------------- */
SELECT 'A1 no gap already held' AS assertion,
       COUNT_IF(ARRAY_SIZE(ARRAY_INTERSECTION(PRODUCT_GAP, PRODUCTS_HELD)) > 0) AS violations,
       IFF(COUNT_IF(ARRAY_SIZE(ARRAY_INTERSECTION(PRODUCT_GAP, PRODUCTS_HELD)) > 0) = 0,
           'PASS', 'FAIL')                                                      AS verdict
FROM GOLD.CUSTOMER_360;

/* A2. No negative tenure. */
SELECT 'A2 no negative tenure' AS assertion,
       COUNT_IF(TENURE_YEARS < 0 OR TENURE_YEARS IS NULL) AS violations,
       IFF(COUNT_IF(TENURE_YEARS < 0 OR TENURE_YEARS IS NULL) = 0, 'PASS', 'FAIL') AS verdict
FROM GOLD.CUSTOMER_360;

/* A3. Consent flags never null. Includes DNC_FLAG: a null there would read as
   "not suppressed" in any downstream boolean test, which is the dangerous
   direction. */
SELECT 'A3 consent flags never null' AS assertion,
       COUNT_IF(CONSENT_CALL IS NULL OR CONSENT_EMAIL IS NULL
                OR CONSENT_SMS IS NULL OR DNC_FLAG IS NULL) AS violations,
       IFF(COUNT_IF(CONSENT_CALL IS NULL OR CONSENT_EMAIL IS NULL
                    OR CONSENT_SMS IS NULL OR DNC_FLAG IS NULL) = 0,
           'PASS', 'FAIL')                                  AS verdict
FROM GOLD.CUSTOMER_360;

/* A4. Grain: exactly one row per customer in RAW.CUSTOMER, no more, no fewer. */
SELECT 'A4 one row per customer' AS assertion,
       (SELECT COUNT(*) FROM GOLD.CUSTOMER_360)                                  AS rows_out,
       (SELECT COUNT(DISTINCT CUSTOMER_ID) FROM GOLD.CUSTOMER_360)               AS distinct_customers,
       (SELECT COUNT(*) FROM RAW.CUSTOMER)                                       AS expected,
       IFF( (SELECT COUNT(*) FROM GOLD.CUSTOMER_360)
              = (SELECT COUNT(*) FROM RAW.CUSTOMER)
        AND (SELECT COUNT(DISTINCT CUSTOMER_ID) FROM GOLD.CUSTOMER_360)
              = (SELECT COUNT(*) FROM RAW.CUSTOMER),
           'PASS', 'FAIL')                                                       AS verdict;

/* A5. The quarantine holds. RAW.CUSTOMER_SEGMENT_TRUTH must not be reachable
   from anything this file creates -- checked against the stored DDL of each
   object rather than trusted from a header comment. */
SELECT 'A5 segment truth not referenced' AS assertion,
       COUNT_IF(UPPER(ddl) LIKE '%CUSTOMER_SEGMENT_TRUTH%') AS violations,
       IFF(COUNT_IF(UPPER(ddl) LIKE '%CUSTOMER_SEGMENT_TRUTH%') = 0, 'PASS', 'FAIL') AS verdict
FROM (
  SELECT GET_DDL('TABLE', 'GOLD.CUSTOMER_360')      AS ddl
  UNION ALL SELECT GET_DDL('TABLE', 'GOLD.CUSTOMER_TIMELINE')
  UNION ALL SELECT GET_DDL('TABLE', 'GOLD.NEXT_BEST_ACTION')
);

/* A6. Every dynamic table resolved to INCREMENTAL. If the anchor pattern ever
   regresses to a bare CURRENT_DATE this flips to FULL, and the demo's whole
   reason for using a dynamic table quietly disappears. */
SHOW DYNAMIC TABLES IN SCHEMA GOLD;
SELECT 'A6 refresh mode incremental' AS assertion,
       "name"                                                     AS dynamic_table,
       "refresh_mode"                                             AS refresh_mode,
       "target_lag"                                               AS target_lag,
       IFF("refresh_mode" = 'INCREMENTAL', 'PASS', 'FAIL')        AS verdict
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));

/* A7. NBA contract: exactly three ranks per customer, dense 1..3, every
   customer covered. */
SELECT 'A7 nba three ranks per customer' AS assertion,
       COUNT(*)                                                    AS customers,
       COUNT_IF(n <> 3)                                            AS wrong_count,
       COUNT_IF(min_rank <> 1 OR max_rank <> 3)                    AS wrong_range,
       IFF(COUNT_IF(n <> 3) = 0 AND COUNT_IF(min_rank <> 1 OR max_rank <> 3) = 0
           AND COUNT(*) = (SELECT COUNT(*) FROM GOLD.CUSTOMER_360),
           'PASS', 'FAIL')                                         AS verdict
FROM (SELECT CUSTOMER_ID, COUNT(*) n, MIN(RANK) min_rank, MAX(RANK) max_rank
      FROM GOLD.NEXT_BEST_ACTION GROUP BY 1);

/* A8. Timeline referential integrity: every event belongs to a customer on the
   spine, and no event has a null timestamp. */
SELECT 'A8 timeline integrity' AS assertion,
       (SELECT COUNT(*) FROM GOLD.CUSTOMER_TIMELINE t
         WHERE NOT EXISTS (SELECT 1 FROM GOLD.CUSTOMER_360 c
                            WHERE c.CUSTOMER_ID = t.CUSTOMER_ID))    AS orphan_events,
       (SELECT COUNT(*) FROM GOLD.CUSTOMER_TIMELINE
         WHERE OCCURRED_AT IS NULL)                                  AS null_timestamps,
       (SELECT COUNT(*) FROM (SELECT EVENT_ID FROM GOLD.CUSTOMER_TIMELINE
                              GROUP BY 1 HAVING COUNT(*) > 1))       AS duplicate_event_ids,
       IFF( (SELECT COUNT(*) FROM GOLD.CUSTOMER_TIMELINE t
              WHERE NOT EXISTS (SELECT 1 FROM GOLD.CUSTOMER_360 c
                                 WHERE c.CUSTOMER_ID = t.CUSTOMER_ID)) = 0
        AND (SELECT COUNT(*) FROM GOLD.CUSTOMER_TIMELINE WHERE OCCURRED_AT IS NULL) = 0
        AND (SELECT COUNT(*) FROM (SELECT EVENT_ID FROM GOLD.CUSTOMER_TIMELINE
                                   GROUP BY 1 HAVING COUNT(*) > 1)) = 0,
           'PASS', 'FAIL')                                           AS verdict;

/* ----------------------------------------------------------------------------
   Distributions, for eyeballing rather than asserting. These are the numbers
   to sanity-check against docs/DATA_SEGMENTS.md: the home-loan-without-cover
   gap should land near the 250 planted PROTECTION_GAP customers, and the
   hardship signal near the 200 planted COLLECTIONS_HARDSHIP ones plus the
   noise floor.
   ---------------------------------------------------------------------------- */

SELECT RELATIONSHIP_VALUE_BAND, COUNT(*) AS customers,
       ROUND(AVG(EST_ANNUAL_MARGIN_INR)) AS avg_margin_inr,
       ROUND(AVG(PRODUCT_COUNT), 2)      AS avg_families_held
FROM GOLD.CUSTOMER_360 GROUP BY 1 ORDER BY avg_margin_inr DESC NULLS LAST;

SELECT DPD_BUCKET, COUNT(*) AS customers, COUNT_IF(HARDSHIP_SIGNAL) AS hardship
FROM GOLD.CUSTOMER_360 GROUP BY 1 ORDER BY customers DESC;

SELECT SENTIMENT_TREND, COUNT(*) AS customers, COUNT_IF(OPEN_COMPLAINT) AS open_complaints
FROM GOLD.CUSTOMER_360 GROUP BY 1 ORDER BY customers DESC;

SELECT g.VALUE::VARCHAR AS product_gap, COUNT(*) AS customers
FROM GOLD.CUSTOMER_360 c, LATERAL FLATTEN(input => c.PRODUCT_GAP) g
GROUP BY 1 ORDER BY customers DESC;

SELECT 'reachability' AS check_name,
       COUNT(*)                                                          AS customers,
       COUNT_IF(DNC_FLAG)                                                AS on_dnc,
       COUNT_IF(CONSENT_CALL)                                            AS consent_call,
       COUNT_IF(CONSENT_EMAIL)                                           AS consent_email,
       COUNT_IF(CONSENT_SMS)                                             AS consent_sms,
       COUNT_IF(NOT CONSENT_CALL AND NOT CONSENT_EMAIL AND NOT CONSENT_SMS) AS unreachable,
       COUNT_IF(VULNERABILITY_FLAG)                                      AS vulnerable,
       COUNT_IF(NOT KYC_CURRENT)                                         AS kyc_not_current
FROM GOLD.CUSTOMER_360;

SELECT EVENT_TYPE, COUNT(*) AS events,
       COUNT(DISTINCT CUSTOMER_ID) AS customers,
       MIN(OCCURRED_AT)::DATE      AS earliest,
       MAX(OCCURRED_AT)::DATE      AS latest
FROM GOLD.CUSTOMER_TIMELINE GROUP BY 1 ORDER BY events DESC;

SELECT ACTION_CODE, COUNT(*) AS picks,
       COUNT_IF(RANK = 1)                    AS as_rank_1,
       ROUND(AVG(EXPECTED_VALUE_INR))        AS avg_ev_inr
FROM GOLD.NEXT_BEST_ACTION GROUP BY 1 ORDER BY picks DESC;

SELECT 'GOLD.CUSTOMER_360, GOLD.CUSTOMER_TIMELINE, GOLD.NEXT_BEST_ACTION built' AS status;

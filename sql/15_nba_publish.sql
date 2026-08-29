/* ============================================================================
   15_nba_publish.sql — publish GOLD.NEXT_BEST_ACTION, then prove it
   ============================================================================
   Layer 4 produced language. This file assembles the shipped artefact and then
   tries to break it.

   THE CONTRACT IS FIXED. GOLD.NEXT_BEST_ACTION was created by
   08_gold_c360.sql with twelve columns and the Streamlit screens are built
   against them. Nothing here widens it. Provenance that would have been a
   thirteenth column lives in GOLD.V_NEXT_BEST_ACTION_AUDIT instead.

   TWO POPULATIONS, ONE TABLE. 1,800 customers were narrated by the model;
   the rest of the 2,334 with an eligible action are ranked and published by the
   deterministic scorer alone. A customer outside the narration cohort still gets
   a recommendation, an expected value and a full eligibility trace — they just
   get a mechanical sentence instead of a written one. The engine degrades to
   deterministic output, never to no output.

   THE CARE BOUNDARY. The model was allowed to reorder, and it used that freedom
   on 356 pairs across 300 customers. Measured, every one of those inversions sat
   inside the sales band; the two servicing actions it ever pushed below a sale
   were RETENTION_WINBACK_LAPSED (tier 25, 34 times) and RENEWAL_REMINDER_EARLY
   (tier 30, 43 times) — a lapsed-policy win-back and a 31-60 day reminder, both
   defensible things to rank under a live commercial opportunity.

   It never once pushed a hardship outreach, an arrears reminder, a complaint
   callback, a service recovery or a retention save below a sale. That is the
   line that matters, so it is enforced here rather than left to hold by luck:
   any action at PRIORITY_TIER <= 20 outranks every sales action regardless of
   what the model asked for. Today the guard changes nothing, which is the point
   — it is regression protection for the ordering property Layer 3 established
   and a prompt cannot guarantee.
   ============================================================================ */

USE DATABASE C360_NBA;
USE SCHEMA GOLD;
USE WAREHOUSE COCO_WH;

SET PROMPT_VERSION = 'nba-reason-v2';


/* ============================================================================
   PART 1 — PUBLISH
   ============================================================================ */

CREATE OR REPLACE TABLE GOLD.NEXT_BEST_ACTION_NEW AS
WITH accepted AS (
    /* BAD_EVIDENCE is publishable: its unresolvable labels were already stripped
       in Layer 4, so what survives is a good recommendation with a short
       bibliography. HALLUCINATED_CODE, DUPLICATE_CODE and MISSING_FIELD drop. */
    SELECT v.CUSTOMER_ID, v.ACTION_CODE, v.RATIONALE, v.EVIDENCE_IDS,
           v.LLM_RANK_DENSE
    FROM GOLD.NBA_REASONING_VALIDATED v
    WHERE v.PROMPT_VERSION = $PROMPT_VERSION
      AND v.VERDICT IN ('ACCEPTED', 'BAD_EVIDENCE')
),
narrated AS (
    SELECT s.CUSTOMER_ID, s.ACTION_CODE, s.ACTION_NAME, s.CHANNEL,
           s.PROPENSITY, s.EXPECTED_VALUE_INR, s.PRIORITY_TIER,
           s.IS_SALES_ACTION, s.REQUIRED_DISCLOSURE, s.ELIGIBILITY_TRACE,
           a.RATIONALE, a.EVIDENCE_IDS, a.LLM_RANK_DENSE AS SOURCE_RANK,
           'LLM'                                             AS RATIONALE_SOURCE
    FROM accepted a
    JOIN GOLD.NBA_SCORED s
      ON s.CUSTOMER_ID = a.CUSTOMER_ID AND s.ACTION_CODE = a.ACTION_CODE
),
/* Deterministic population: every scored customer with no surviving narrated
   row. Covers customers outside the cohort and any cohort customer whose whole
   response was rejected -- a validation failure must not delete a customer from
   the output. */
mechanical AS (
    SELECT s.CUSTOMER_ID, s.ACTION_CODE, s.ACTION_NAME, s.CHANNEL,
           s.PROPENSITY, s.EXPECTED_VALUE_INR, s.PRIORITY_TIER,
           s.IS_SALES_ACTION, s.REQUIRED_DISCLOSURE, s.ELIGIBILITY_TRACE,
           s.ACTION_NAME || ' — ranked on expected value of INR '
             || TO_VARCHAR(s.EXPECTED_VALUE_INR::NUMBER, '999,999,999')
             || ' at propensity ' || TO_VARCHAR(ROUND(s.PROPENSITY, 3))
             || COALESCE('. Scoring drivers: ' || d.DRIVER_LIST || '.', '.')
             || ' Deterministic ranking; no written rationale for this customer.'
                                                             AS RATIONALE,
           ARRAY_CONSTRUCT()                                 AS EVIDENCE_IDS,
           s.RANK_WITHIN_CUSTOMER                            AS SOURCE_RANK,
           'DETERMINISTIC'                                   AS RATIONALE_SOURCE
    FROM GOLD.NBA_SCORED s
    LEFT JOIN (
        SELECT s2.CUSTOMER_ID, s2.ACTION_CODE,
               ARRAY_TO_STRING(
                   ARRAY_COMPACT(ARRAY_AGG(IFF(dd.VALUE::FLOAT <> 0, dd.KEY, NULL))
                                 WITHIN GROUP (ORDER BY dd.KEY)), ', ') AS DRIVER_LIST
        FROM GOLD.NBA_SCORED s2, LATERAL FLATTEN(input => s2.DRIVER_FEATURES) dd
        GROUP BY 1, 2
    ) d ON d.CUSTOMER_ID = s.CUSTOMER_ID AND d.ACTION_CODE = s.ACTION_CODE
    WHERE NOT EXISTS (
        SELECT 1 FROM narrated n WHERE n.CUSTOMER_ID = s.CUSTOMER_ID
    )
),
combined AS (
    SELECT * FROM narrated
    UNION ALL
    SELECT * FROM mechanical
),
ranked AS (
    SELECT c.*,
           /* The care boundary. Band 0 is duty of care and always precedes a
              sale; inside band 0 the tier ladder decides, not the model. Band 1
              is where the model's reordering is honoured. */
           IFF(c.PRIORITY_TIER <= 20, 0, 1)                   AS CARE_BAND,
           ROW_NUMBER() OVER (
               PARTITION BY c.CUSTOMER_ID
               ORDER BY IFF(c.PRIORITY_TIER <= 20, 0, 1) ASC,
                        IFF(c.PRIORITY_TIER <= 20, c.PRIORITY_TIER, 0) ASC,
                        c.SOURCE_RANK ASC,
                        c.ACTION_CODE ASC)                    AS FINAL_RANK
    FROM combined c
)
SELECT CUSTOMER_ID,
       FINAL_RANK                                            AS "RANK",
       ACTION_CODE,
       ACTION_NAME,
       CHANNEL,
       PROPENSITY,
       EXPECTED_VALUE_INR,
       RATIONALE,
       EVIDENCE_IDS,
       REQUIRED_DISCLOSURE                                   AS DISCLOSURE,
       ELIGIBILITY_TRACE,
       CURRENT_TIMESTAMP()                                   AS GENERATED_AT,
       /* dropped before the contract table is written; kept here for the audit view */
       RATIONALE_SOURCE, PRIORITY_TIER, IS_SALES_ACTION, SOURCE_RANK, CARE_BAND
FROM ranked
WHERE FINAL_RANK <= 3;

/* Swap into the contract table, twelve columns exactly and in order. */
CREATE OR REPLACE TABLE GOLD.NEXT_BEST_ACTION
COMMENT = 'Published next best actions, at most 3 per customer. Deterministic SQL decided eligibility (12), a transparent weighted score decided value (13), and an LLM ranked and wrote the rationale within that eligible set only (14). RATIONALE and EVIDENCE_IDS are the only generated columns; PROPENSITY, EXPECTED_VALUE_INR, CHANNEL and DISCLOSURE are carried from the scorer and the catalogue and no model ever touched them. Ordering enforces the care boundary: any action at PRIORITY_TIER <= 20 outranks every sales action. Provenance in GOLD.V_NEXT_BEST_ACTION_AUDIT.'
AS
SELECT CUSTOMER_ID, "RANK", ACTION_CODE, ACTION_NAME, CHANNEL, PROPENSITY,
       EXPECTED_VALUE_INR, RATIONALE, EVIDENCE_IDS, DISCLOSURE,
       ELIGIBILITY_TRACE, GENERATED_AT
FROM GOLD.NEXT_BEST_ACTION_NEW;

CREATE OR REPLACE VIEW GOLD.V_NEXT_BEST_ACTION_AUDIT
COMMENT = 'GOLD.NEXT_BEST_ACTION plus the provenance the twelve-column contract has no room for: whether the rationale was written or mechanical, the priority tier, and whether the care boundary moved the row away from the rank the source asked for.'
AS
SELECT n.CUSTOMER_ID, n."RANK", n.ACTION_CODE, n.RATIONALE_SOURCE,
       n.PRIORITY_TIER, n.IS_SALES_ACTION, n.CARE_BAND,
       n.SOURCE_RANK, n."RANK" <> n.SOURCE_RANK                AS RANK_MOVED,
       n.PROPENSITY, n.EXPECTED_VALUE_INR
FROM GOLD.NEXT_BEST_ACTION_NEW n;

DROP TABLE IF EXISTS GOLD.NEXT_BEST_ACTION_NEW_OLD;


/* ============================================================================
   PART 2 — STRUCTURAL VERIFICATION
   ============================================================================ */

SELECT '15.1a contract is exactly the twelve original columns'   AS check_name,
       COUNT(*)                                                  AS obs,
       IFF(COUNT(*) = 12, 'PASS', 'FAIL')                         AS verdict
FROM C360_NBA.INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_SCHEMA = 'GOLD' AND TABLE_NAME = 'NEXT_BEST_ACTION'
UNION ALL
SELECT '15.1b rank is dense from 1 within every customer',
       COUNT(*),
       IFF(COUNT(*) = 0, 'PASS', 'FAIL')
FROM (
    SELECT CUSTOMER_ID FROM GOLD.NEXT_BEST_ACTION
    GROUP BY 1
    HAVING MIN("RANK") <> 1 OR MAX("RANK") <> COUNT(*) OR COUNT(DISTINCT "RANK") <> COUNT(*)
)
UNION ALL
SELECT '15.1c at most 3 actions per customer',
       COUNT(*),
       IFF(COUNT(*) = 0, 'PASS', 'FAIL')
FROM (SELECT CUSTOMER_ID FROM GOLD.NEXT_BEST_ACTION GROUP BY 1 HAVING COUNT(*) > 3)
UNION ALL
SELECT '15.1d every published row was recommendable in layer 2',
       COUNT(*),
       IFF(COUNT(*) = 0, 'PASS', 'FAIL')
FROM GOLD.NEXT_BEST_ACTION n
WHERE NOT EXISTS (
    SELECT 1 FROM GOLD.NBA_ELIGIBLE e
    WHERE e.CUSTOMER_ID = n.CUSTOMER_ID AND e.ACTION_CODE = n.ACTION_CODE
      AND e.FINAL_VERDICT = 'ELIGIBLE')
UNION ALL
SELECT '15.1e no published action is outside the catalogue',
       COUNT(*),
       IFF(COUNT(*) = 0, 'PASS', 'FAIL')
FROM GOLD.NEXT_BEST_ACTION n
WHERE NOT EXISTS (SELECT 1 FROM GOLD.ACTION_CATALOG a
                  WHERE a.ACTION_CODE = n.ACTION_CODE)
UNION ALL
SELECT '15.1f disclosure and EV carried intact from catalogue and scorer',
       COUNT(*),
       IFF(COUNT(*) = 0, 'PASS', 'FAIL')
FROM GOLD.NEXT_BEST_ACTION n
JOIN GOLD.NBA_SCORED s ON s.CUSTOMER_ID = n.CUSTOMER_ID AND s.ACTION_CODE = n.ACTION_CODE
WHERE n.DISCLOSURE <> s.REQUIRED_DISCLOSURE
   OR n.EXPECTED_VALUE_INR <> s.EXPECTED_VALUE_INR
   OR n.PROPENSITY <> s.PROPENSITY
UNION ALL
SELECT '15.1h no customer with an eligible action is missing from the output',
       COUNT(*),
       IFF(COUNT(*) = 0, 'PASS', 'FAIL')
FROM (SELECT DISTINCT CUSTOMER_ID FROM GOLD.NBA_SCORED) s
WHERE NOT EXISTS (SELECT 1 FROM GOLD.NEXT_BEST_ACTION n
                  WHERE n.CUSTOMER_ID = s.CUSTOMER_ID);

/* 15.1g is a separate statement, not another UNION ALL branch. Resolving a cited
   id needs the evidence map flattened, and a correlated FLATTEN in a subquery
   raises "Unsupported subquery type cannot be evaluated" -- the same error the
   trace-rollup in 12 hit. Flattening once in a CTE and joining avoids it. */
WITH valid_ids AS (
    SELECT e.CUSTOMER_ID, m.VALUE::VARCHAR AS CITE_ID
    FROM GOLD.NBA_EVIDENCE e, LATERAL FLATTEN(input => e.EVIDENCE_MAP) m
),
cited AS (
    SELECT n.CUSTOMER_ID, x.VALUE::VARCHAR AS CITE_ID
    FROM GOLD.NEXT_BEST_ACTION n, LATERAL FLATTEN(input => n.EVIDENCE_IDS) x
)
SELECT '15.1g every cited evidence id resolves to a real source row' AS check_name,
       COUNT_IF(v.CITE_ID IS NULL)                               AS obs,
       IFF(COUNT_IF(v.CITE_ID IS NULL) = 0, 'PASS', 'FAIL')      AS verdict
FROM cited c
LEFT JOIN valid_ids v
       ON v.CUSTOMER_ID = c.CUSTOMER_ID AND v.CITE_ID = c.CITE_ID;


/* ============================================================================
   PART 3 — THE GUARDRAIL HUNT
   ----------------------------------------------------------------------------
   "If the engine recommends a cross-sell to a vulnerability-flagged or
   in-arrears customer, that is a bug — find it."

   These re-derive every condition from RAW, not from any GOLD feature. That
   discipline is why 12.4.3h exists: the earlier open-complaint check joined the
   engine's own OPEN_COMPLAINT column and so was blind to exactly the 462
   customers that column was blind to, and reported PASS on 312 wrong rows.
   ============================================================================ */

SELECT '15.2a NO sales action published to a vulnerable customer (from RAW)' AS check_name,
       COUNT(*)                                                  AS obs,
       IFF(COUNT(*) = 0, 'PASS', 'FAIL')                         AS verdict
FROM GOLD.NEXT_BEST_ACTION n
JOIN GOLD.ACTION_CATALOG a ON a.ACTION_CODE = n.ACTION_CODE
JOIN RAW.CUSTOMER c        ON c.CUSTOMER_ID = n.CUSTOMER_ID
WHERE a.IS_SALES_ACTION AND c.VULNERABILITY_FLAG
UNION ALL
SELECT '15.2b NO cross-sell published to a customer in arrears (from RAW)',
       COUNT(*),
       IFF(COUNT(*) = 0, 'PASS', 'FAIL')
FROM GOLD.NEXT_BEST_ACTION n
JOIN GOLD.ACTION_CATALOG a ON a.ACTION_CODE = n.ACTION_CODE
WHERE a.CATEGORY = 'CROSS_SELL'
  AND EXISTS (SELECT 1 FROM RAW.LOAN l
              WHERE l.CUSTOMER_ID = n.CUSTOMER_ID AND l.DPD_DAYS > 0)
UNION ALL
SELECT '15.2b2 NO sales action published to a customer in arrears (from RAW)',
       COUNT(*),
       IFF(COUNT(*) = 0, 'PASS', 'FAIL')
FROM GOLD.NEXT_BEST_ACTION n
JOIN GOLD.ACTION_CATALOG a ON a.ACTION_CODE = n.ACTION_CODE
WHERE a.IS_SALES_ACTION
  AND EXISTS (SELECT 1 FROM RAW.LOAN l
              WHERE l.CUSTOMER_ID = n.CUSTOMER_ID AND l.DPD_DAYS > 0)
UNION ALL
SELECT '15.2c NO sales action published to a customer with a live complaint (from RAW)',
       COUNT(*),
       IFF(COUNT(*) = 0, 'PASS', 'FAIL')
FROM GOLD.NEXT_BEST_ACTION n
JOIN GOLD.ACTION_CATALOG a ON a.ACTION_CODE = n.ACTION_CODE
WHERE a.IS_SALES_ACTION
  AND EXISTS (SELECT 1 FROM RAW.SERVICE_TICKET t
              WHERE t.CUSTOMER_ID = n.CUSTOMER_ID AND t.IS_COMPLAINT
                AND t.STATUS IN ('OPEN', 'IN_PROGRESS'))
UNION ALL
SELECT '15.2d NO action published on a channel the customer did not consent to',
       COUNT(*),
       IFF(COUNT(*) = 0, 'PASS', 'FAIL')
FROM GOLD.NEXT_BEST_ACTION n
JOIN GOLD.NBA_FEATURE_BASE f ON f.CUSTOMER_ID = n.CUSTOMER_ID
WHERE NOT CASE n.CHANNEL WHEN 'CALL'  THEN f.CONSENT_CALL
                         WHEN 'EMAIL' THEN f.CONSENT_EMAIL
                         WHEN 'SMS'   THEN f.CONSENT_SMS END
UNION ALL
SELECT '15.2e NO duty-of-care action ranked below a sales action',
       COUNT(*),
       IFF(COUNT(*) = 0, 'PASS', 'FAIL')
FROM GOLD.NEXT_BEST_ACTION x
JOIN GOLD.ACTION_CATALOG ax ON ax.ACTION_CODE = x.ACTION_CODE
JOIN GOLD.NEXT_BEST_ACTION y ON y.CUSTOMER_ID = x.CUSTOMER_ID
JOIN GOLD.ACTION_CATALOG ay ON ay.ACTION_CODE = y.ACTION_CODE
WHERE ax.PRIORITY_TIER <= 20 AND ay.IS_SALES_ACTION AND x."RANK" > y."RANK"
UNION ALL
SELECT '15.2f NO duty-of-care action missing from a customer who qualified for one',
       COUNT(*),
       IFF(COUNT(*) = 0, 'PASS', 'FAIL')
FROM GOLD.NBA_SCORED s
JOIN GOLD.ACTION_CATALOG a ON a.ACTION_CODE = s.ACTION_CODE
WHERE a.PRIORITY_TIER <= 20
  AND NOT EXISTS (SELECT 1 FROM GOLD.NEXT_BEST_ACTION n
                  WHERE n.CUSTOMER_ID = s.CUSTOMER_ID
                    AND n.ACTION_CODE = s.ACTION_CODE);


/* ============================================================================
   PART 4 — IS THE GENERATED PROSE GROUNDED?
   ----------------------------------------------------------------------------
   The first version of this check flagged any rationale containing a rupee
   figure and reported 107 failures. That was the check being wrong, not the
   output: prompt rule 4 permits quoting an amount that appears in the CUSTOMER
   or EVIDENCE blocks, and it is exactly the right thing for an agent to say. The
   flagged rows were verbatim quotes -- customer 2's "premium increased 32% to
   INR 29,000 ... competing offer at INR 22,500 from Star Health" is word for
   word out of evidence lines E4 and E5.

   So the test is groundedness, not presence: every number of three digits or
   more in a generated rationale must appear in that customer's own prompt.
   Commas are stripped from both sides first so 29,000 matches 29000. Two-digit
   numbers are ignored deliberately -- ages, percentages and day counts are
   noise, and an invented monetary amount is not two digits.
   ============================================================================ */

WITH src AS (
    SELECT n.CUSTOMER_ID, n."RANK",
           REPLACE(n.RATIONALE, ',', '')                      AS RAT,
           REPLACE(p.PROMPT,   ',', '')                       AS PRM
    FROM GOLD.NEXT_BEST_ACTION n
    JOIN GOLD.V_NEXT_BEST_ACTION_AUDIT v
      ON v.CUSTOMER_ID = n.CUSTOMER_ID AND v."RANK" = n."RANK"
    JOIN GOLD.NBA_REASONING_PLAN p ON p.CUSTOMER_ID = n.CUSTOMER_ID
    WHERE v.RATIONALE_SOURCE = 'LLM'
),
tok AS (
    SELECT s.CUSTOMER_ID, s."RANK", s.PRM, t.VALUE::VARCHAR AS NUM
    FROM src s, LATERAL FLATTEN(input => REGEXP_SUBSTR_ALL(s.RAT, '[0-9]{3,}')) t
)
SELECT '15.3a numbers in a generated rationale not literally in its prompt' AS check_name,
       COUNT_IF(POSITION(NUM IN PRM) = 0)                        AS derived_numbers,
       COUNT(*)                                                  AS numbers_checked,
       IFF(COUNT_IF(POSITION(NUM IN PRM) = 0) <= 5, 'REVIEW', 'FAIL') AS verdict
FROM tok;

/* 15.3a is a review flag, not a gate, and the threshold is deliberate rather
   than generous. Measured: 3 of 300 numbers were not literal substrings of the
   prompt, and all three were checked by hand:

     4188  "loan term runs until September 2027"  -- disbursement date plus term
     436   "took over 300 hours to resolve"       -- evidence E8 says 316.0 hours
     1361  "two open claims totalling over 518,000" -- 139,700 + 379,200 = 518,900

   Every one is arithmetic on values that were in the prompt, and every one is
   correct. None is invention. But they are the model calculating, which rule 4
   asks it not to do, and no automated check can confirm arithmetic it did not
   perform itself -- so this reports for human review rather than passing silently
   or failing a batch whose numbers are right. A count above 5 means the
   behaviour has changed and the sample needs re-reading.

   Also measured, and the residual quality item worth naming: exactly 1 row of
   3,917 frames rising card utilisation on a clean-repayment customer as "cash
   flow pressure" justifying a personal loan. The rules permitted it -- customer
   1887's CARD_LIMIT_INCREASE was suppressed by cooldown, so the loan was what
   remained -- but the sentence imputes distress the scorer never asserted about a
   customer whose defining trait is never having missed a payment. One row is a
   one-off, not a pattern; a prompt rule forbidding a distress reading of a
   positive signal is the fix if it ever becomes one. */

/* Informational, not a gate. A model that turns "INR 4,839,000" into
   "48.39 lakh" has done correct arithmetic on a money figure, which is idiomatic
   Indian banking register and also, strictly, rule 4 asking to be re-read. It is
   surfaced rather than blocked because the underlying figure is the engine's own
   and the conversion is verifiable -- but it is the one place a generated
   sentence performs a calculation, so it should be visible. */
SELECT '15.3b rationales that convert a figure to lakh or crore' AS check_name,
       COUNT(*)                                                  AS obs
FROM GOLD.NEXT_BEST_ACTION n
JOIN GOLD.V_NEXT_BEST_ACTION_AUDIT v
  ON v.CUSTOMER_ID = n.CUSTOMER_ID AND v."RANK" = n."RANK"
WHERE v.RATIONALE_SOURCE = 'LLM'
  AND (n.RATIONALE ILIKE '%lakh%' OR n.RATIONALE ILIKE '%crore%');


/* ============================================================================
   PART 5 — THE PROOF, SEGMENT BY SEGMENT
   ----------------------------------------------------------------------------
   VERIFICATION BLOCK. This is the one place in this file that reads
   RAW.CUSTOMER_SEGMENT_TRUTH. Per AGENTS.md the answer key is quarantined from
   CURATED, GOLD and APP; explicit verification blocks may read it, exactly as
   11.4.3 and 12.4.7 do. Nothing here is materialised and nothing downstream
   depends on it -- the engine has already decided, and this only marks the exam.
   ============================================================================ */

SELECT '15.4 top published action per planted segment'         AS check_name,
       t.SEGMENT_CODE,
       n.ACTION_CODE,
       COUNT(*)                                                AS customers,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (PARTITION BY t.SEGMENT_CODE), 1)
                                                               AS pct_of_segment
FROM RAW.CUSTOMER_SEGMENT_TRUTH t
JOIN GOLD.NEXT_BEST_ACTION n
      ON n.CUSTOMER_ID = t.CUSTOMER_ID AND n."RANK" = 1
WHERE t.SEGMENT_CODE <> 'NONE'
GROUP BY 1, 2, 3
QUALIFY ROW_NUMBER() OVER (PARTITION BY t.SEGMENT_CODE ORDER BY COUNT(*) DESC) <= 3
ORDER BY t.SEGMENT_CODE, customers DESC;


/* Three worked examples per segment: the actual sentence an agent would read. */
SELECT '15.5 worked examples'                                  AS check_name,
       t.SEGMENT_CODE,
       n.CUSTOMER_ID,
       n.ACTION_CODE,
       n.CHANNEL,
       n.EXPECTED_VALUE_INR                                    AS ev_inr,
       n.RATIONALE,
       n.EVIDENCE_IDS
FROM RAW.CUSTOMER_SEGMENT_TRUTH t
JOIN GOLD.NEXT_BEST_ACTION n
      ON n.CUSTOMER_ID = t.CUSTOMER_ID AND n."RANK" = 1
JOIN GOLD.V_NEXT_BEST_ACTION_AUDIT v
      ON v.CUSTOMER_ID = n.CUSTOMER_ID AND v."RANK" = n."RANK"
WHERE t.SEGMENT_CODE IN ('RETENTION_SAVE', 'LIMIT_INCREASE', 'PROTECTION_GAP',
                         'COLLECTIONS_HARDSHIP', 'WEALTH_REFERRAL')
  AND v.RATIONALE_SOURCE = 'LLM'
QUALIFY ROW_NUMBER() OVER (PARTITION BY t.SEGMENT_CODE
                           ORDER BY n.EXPECTED_VALUE_INR DESC) <= 3
ORDER BY t.SEGMENT_CODE, ev_inr DESC;


/* ============================================================================
   PART 6 — SUPPRESSION CASES: HIGH VALUE, CORRECTLY BLOCKED
   ----------------------------------------------------------------------------
   "The audit trail is the product." These are the rows the engine refused to
   recommend despite them carrying the most money, each with the governing rule
   and the observation that triggered it.
   ============================================================================ */

SELECT '15.6 highest-value suppressions by reason'             AS check_name,
       e.SUPPRESSION_REASON,
       e.CUSTOMER_ID,
       e.ACTION_CODE,
       ROUND(e.VALUE_AT_STAKE_INR)                             AS value_at_stake_inr,
       e.RULES_FAILED
FROM GOLD.NBA_ELIGIBLE e
WHERE e.SUPPRESSED AND e.ELIGIBLE_ON_NEED
  AND e.SUPPRESSION_REASON IN ('VULNERABILITY_GATE', 'ARREARS_CROSS_SELL',
                               'OPEN_COMPLAINT', 'DNC_REGISTRY', 'NO_CHANNEL_CONSENT')
QUALIFY ROW_NUMBER() OVER (PARTITION BY e.SUPPRESSION_REASON
                           ORDER BY e.VALUE_AT_STAKE_INR DESC) = 1
ORDER BY value_at_stake_inr DESC;


/* The full trace for the single highest-value blocked row, rule by rule. Pinned
   to one (customer, action) pair: an earlier version deduplicated by rule name
   across all of the customer's actions, which silently interleaved CARD_ACQUISITION's
   rules with CARD_LIMIT_INCREASE's and produced a trace that described no single
   decision. */
WITH worst AS (
    SELECT CUSTOMER_ID, ACTION_CODE, VALUE_AT_STAKE_INR
    FROM GOLD.NBA_ELIGIBLE
    WHERE SUPPRESSED AND ELIGIBLE_ON_NEED
      AND SUPPRESSION_REASON = 'VULNERABILITY_GATE'
    ORDER BY VALUE_AT_STAKE_INR DESC
    LIMIT 1
)
SELECT '15.7 full trace, highest-value suppression'            AS check_name,
       e.CUSTOMER_ID, e.ACTION_CODE, e.SUPPRESSION_REASON,
       ROUND(e.VALUE_AT_STAKE_INR)                             AS value_at_stake_inr,
       x.VALUE:rule::VARCHAR                                   AS rule,
       x.VALUE:kind::VARCHAR                                   AS kind,
       x.VALUE:verdict::VARCHAR                                AS verdict,
       x.VALUE:observed::VARCHAR                               AS observed
FROM GOLD.NBA_ELIGIBLE e
JOIN worst w ON w.CUSTOMER_ID = e.CUSTOMER_ID AND w.ACTION_CODE = e.ACTION_CODE,
     LATERAL FLATTEN(input => e.ELIGIBILITY_TRACE) x
ORDER BY IFF(verdict = 'BLOCK', 0, 1), rule;


/* Population summary. */
SELECT '15.8 published population'                             AS check_name,
       v.RATIONALE_SOURCE,
       COUNT(DISTINCT v.CUSTOMER_ID)                           AS customers,
       COUNT(*)                                                AS published_rows,
       ROUND(SUM(v.EXPECTED_VALUE_INR))                         AS total_ev_inr
FROM GOLD.V_NEXT_BEST_ACTION_AUDIT v
GROUP BY 1, 2
UNION ALL
SELECT '15.8 published population', 'TOTAL',
       COUNT(DISTINCT CUSTOMER_ID), COUNT(*), ROUND(SUM(EXPECTED_VALUE_INR))
FROM GOLD.V_NEXT_BEST_ACTION_AUDIT
ORDER BY 2;

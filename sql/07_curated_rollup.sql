/* ============================================================================
   07_curated_rollup.sql  —  CURATED.CUSTOMER_INTERACTION_ROLLUP
   ----------------------------------------------------------------------------
   One row per customer who has ever been in contact. Collapses the interaction
   stream into the shape GOLD needs: how often, about what, getting better or
   worse, last reached on which channel, and whether something is still open.

   No AI. Every column here is deterministic SQL over signals that were already
   paid for in 05, so this file is free to re-run and free to change. That
   matters more than it sounds: the windows and the slope definition are exactly
   the things likely to need adjusting once the NBA ranking is being tuned, and
   none of that should cost credits.

   ----------------------------------------------------------------------------
   READS THE GATED VIEW, NOT THE RAW ONE
   ----------------------------------------------------------------------------
   Every signal comes from CURATED.INTERACTION_SIGNALS_GATED, so a
   low-confidence intent or sentiment is NULL here and drops out of the
   aggregates rather than being counted as if it were established. That is the
   point of the threshold: it has to bite somewhere, and this is the first place
   downstream of it.

   Consequence worth knowing: raising MIN_CONFIDENCE in CURATED.AI_CONFIG will
   reduce the counts in this table. That is correct behaviour, not data loss.
   INTERACTIONS_* counts every interaction regardless of confidence, so the gap
   between INTERACTIONS_90D and the sum of INTENT_COUNTS_90D is a readable
   measure of how much the threshold is currently withholding.

   ----------------------------------------------------------------------------
   SENTIMENT: WHICH COLUMN IS LOAD-BEARING
   ----------------------------------------------------------------------------
   SENTIMENT_TREND is the signal. SENTIMENT_SLOPE_PER_30D is DIAGNOSTIC ONLY and
   must not appear in a ranking expression, a propensity term, or an eligibility
   predicate in GOLD.

   The reason is coverage and scale, not correctness. A slope needs three
   sentiment readings, and only 136 of 596 customers have them -- the 2-3 artefact
   retention and hardship cohorts, which is where it matters, but still 23% of the
   book. Worse, those three readings usually sit inside a few weeks, so the fitted
   line is steep almost regardless of the underlying change: measured averages came
   out around +1.4 and -0.65 points per 30 days on a scale that only spans -1..+1.
   The direction is trustworthy; the magnitude is an artefact of a short baseline.

   Densifying the corpus to 4+ artefacts for those cohorts would fix it for about
   2 credits. That was considered and declined: the bucketed trend carries the
   signal M4 needs, and the credits are better spent on the frontier-model
   narrative in M6. See PROJECT_BRIEF D6.

   The two columns carry COMMENTs saying exactly this, applied below, so the
   constraint is visible in DESCRIBE TABLE and in the Snowsight column list rather
   than only in this header.

   ----------------------------------------------------------------------------
   ONE TEMPORARY BRIDGE, FLAGGED
   ----------------------------------------------------------------------------
   OPEN_COMPLAINT_TICKET_FLAG reads RAW.SERVICE_TICKET directly. Properly that
   should come through CURATED.INTERACTION, which M2 (13_curated_interaction.sql)
   will build to unify tickets and calls on one grain. Until that exists, this
   column reaches into RAW rather than pretending the servicing silo does not
   exist. Replace the ticket CTE with a read of CURATED.INTERACTION when M2
   lands; nothing else in this file changes.
   ============================================================================ */

USE ROLE COCO_BUILDER;
USE WAREHOUSE COCO_WH;
USE DATABASE C360_NBA;
USE SCHEMA CURATED;

/* ----------------------------------------------------------------------------
   Window definitions, in one place. Anchored on RAW.AS_OF() rather than
   CURRENT_DATE so the windows slide with the rest of the dataset and
   "a complaint in the last 60 days" keeps meaning the same thing whenever the
   demo runs.
   ---------------------------------------------------------------------------- */

CREATE OR REPLACE VIEW CURATED.ROLLUP_WINDOW AS
SELECT RAW.AS_OF()                            AS as_of,
       DATEADD(day,  -30, RAW.AS_OF())        AS w30,
       DATEADD(day,  -90, RAW.AS_OF())        AS w90,
       DATEADD(day, -365, RAW.AS_OF())        AS w365,
       DATEADD(day,  -60, RAW.AS_OF())        AS w60_complaint;

CREATE OR REPLACE TABLE CURATED.CUSTOMER_INTERACTION_ROLLUP AS
WITH win AS (SELECT * FROM CURATED.ROLLUP_WINDOW),

/* -------------------------------------------------------------------------
   Base: every enriched interaction, with its window membership and its age in
   days precomputed. DAYS_AGO is what the slope regresses against.
   ------------------------------------------------------------------------- */
base AS (
  SELECT
    g.CUSTOMER_ID,
    g.INTERACTION_ID,
    g.OCCURRED_AT,
    g.CHANNEL,
    g.ARTEFACT_TYPE,
    g.SOURCE_KIND,
    g.INTENT,
    g.SENTIMENT_SCORE,
    g.SENTIMENT_OVERALL,
    g.COMPLAINT,
    g.CHURN_RISK_MENTIONED,
    g.COMPETITOR_MENTIONED,
    g.HARDSHIP_SIGNAL,
    g.LIFE_EVENT,
    g.CONSENT_WITHDRAWAL,
    g.COMPETITOR_NAME,
    g.AMOUNT_DISCUSSED_INR,
    g.PROMISED_CALLBACK_DATE,
    DATEDIFF(day, g.OCCURRED_AT, w.as_of)          AS days_ago,
    (g.OCCURRED_AT::DATE >= w.w30)                 AS in_30d,
    (g.OCCURRED_AT::DATE >= w.w90)                 AS in_90d,
    (g.OCCURRED_AT::DATE >= w.w365)                AS in_365d,
    (g.OCCURRED_AT::DATE >= w.w60_complaint)       AS in_60d
  FROM CURATED.INTERACTION_SIGNALS_GATED g
  CROSS JOIN win w
),

/* -------------------------------------------------------------------------
   Intent counts per window. OBJECT_AGG rather than 48 flat columns: the
   taxonomy has 16 labels and three windows, and a customer touches two or
   three of them. A sparse object is the honest shape, and Cortex Analyst reads
   it fine. The handful of intents that actually drive actions get flat columns
   further down, because a ranking rule should not have to index into a VARIANT.
   ------------------------------------------------------------------------- */
intent_30 AS (
  SELECT CUSTOMER_ID, OBJECT_AGG(INTENT, n::VARIANT) AS obj
  FROM (SELECT CUSTOMER_ID, INTENT, COUNT(*) AS n FROM base
         WHERE in_30d AND INTENT IS NOT NULL GROUP BY 1,2)
  GROUP BY 1
),
intent_90 AS (
  SELECT CUSTOMER_ID, OBJECT_AGG(INTENT, n::VARIANT) AS obj
  FROM (SELECT CUSTOMER_ID, INTENT, COUNT(*) AS n FROM base
         WHERE in_90d AND INTENT IS NOT NULL GROUP BY 1,2)
  GROUP BY 1
),
intent_365 AS (
  SELECT CUSTOMER_ID, OBJECT_AGG(INTENT, n::VARIANT) AS obj
  FROM (SELECT CUSTOMER_ID, INTENT, COUNT(*) AS n FROM base
         WHERE in_365d AND INTENT IS NOT NULL GROUP BY 1,2)
  GROUP BY 1
),

/* -------------------------------------------------------------------------
   Last contact per channel. Pivoted to flat columns because the cooling-off
   compliance rule in M5 needs "when did we last touch this customer on the
   channel we are about to use", which is a per-channel question.

   WHATSAPP and APP_CHAT collapse into one LAST_CHAT_AT: they are the same
   conversational surface from the customer's point of view, and consent is
   registered per RAW.CONSENT channel where WHATSAPP is the relevant key.
   ------------------------------------------------------------------------- */
chan AS (
  SELECT
    CUSTOMER_ID,
    MAX(OCCURRED_AT)                                                    AS last_contact_at,
    MAX(IFF(CHANNEL = 'CALL',                    OCCURRED_AT, NULL))    AS last_call_at,
    MAX(IFF(CHANNEL = 'EMAIL',                   OCCURRED_AT, NULL))    AS last_email_at,
    MAX(IFF(CHANNEL IN ('WHATSAPP','APP_CHAT'),  OCCURRED_AT, NULL))    AS last_chat_at,
    MAX(IFF(CHANNEL = 'BRANCH',                  OCCURRED_AT, NULL))    AS last_branch_at,
    MAX(IFF(SOURCE_KIND = 'AUDIO',               OCCURRED_AT, NULL))    AS last_recorded_call_at
  FROM base GROUP BY 1
),

/* -------------------------------------------------------------------------
   Sentiment trend.

   REGR_SLOPE(y, x) with y = sentiment score and x = NEGATED days_ago, so x
   increases with time and a positive slope means "getting happier". Regressing
   against days_ago directly would invert the sign, which is the kind of thing
   that silently reverses a retention rule.

   Scaled to points per 30 days rather than per day, because a per-day slope on
   a -1..+1 scale is a number with four leading zeros and nobody reads it
   correctly.

   Requires at least three sentiment observations. Two points always produce a
   perfectly fitting line, so a two-interaction customer would otherwise get a
   confident-looking trend from no evidence. NULL is the right answer there.

   Read the MAGNITUDE with suspicion and the DIRECTION with confidence. Most
   customers who qualify have exactly three interactions inside a few weeks, so
   the fitted slope is steep almost regardless of the underlying change --
   measured averages came out around +1.4 and -0.65 points per 30 days on a
   -1..+1 scale, which is arithmetically fine and substantively overstated.
   SENTIMENT_TREND is the column downstream should read; the raw slope is exposed
   for inspection, not for arithmetic. Settled in PROJECT_BRIEF D6, and asserted
   as a column COMMENT so it survives outside this file.
   ------------------------------------------------------------------------- */
trend AS (
  SELECT
    CUSTOMER_ID,
    COUNT(SENTIMENT_SCORE)                                       AS sentiment_obs_365d,
    ROUND(AVG(IFF(in_30d,  SENTIMENT_SCORE, NULL)), 4)           AS sentiment_avg_30d,
    ROUND(AVG(IFF(in_90d,  SENTIMENT_SCORE, NULL)), 4)           AS sentiment_avg_90d,
    ROUND(AVG(SENTIMENT_SCORE), 4)                               AS sentiment_avg_365d,
    ROUND(
      IFF(COUNT(SENTIMENT_SCORE) >= 3,
          REGR_SLOPE(SENTIMENT_SCORE, -days_ago) * 30.0,
          NULL), 5)                                              AS sentiment_slope_per_30d
  FROM base
  WHERE in_365d
  GROUP BY 1
),
latest_sentiment AS (
  SELECT CUSTOMER_ID, SENTIMENT_OVERALL AS latest_sentiment, OCCURRED_AT AS latest_sentiment_at
  FROM (
    SELECT CUSTOMER_ID, SENTIMENT_OVERALL, OCCURRED_AT,
           ROW_NUMBER() OVER (PARTITION BY CUSTOMER_ID ORDER BY OCCURRED_AT DESC) AS rn
    FROM base WHERE SENTIMENT_OVERALL IS NOT NULL
  ) WHERE rn = 1
),

/* -------------------------------------------------------------------------
   Open complaint. Two independent arms, kept as separate columns so a reviewer
   can see which one fired, and OR-ed into one flag for convenience.

   Arm 1, from the text: a complaint in the last 60 days with nothing on the
   account since. Absence of follow-up is the only unresolvedness signal the
   interaction stream carries on its own -- there is no resolution event in it --
   so this is deliberately conservative and will miss a complaint that was
   chased and still not fixed.

   Arm 2, from the book: an OPEN or IN_PROGRESS complaint ticket. This is the
   authoritative one, and it is what the S1 retention predicate in
   docs/DATA_SEGMENTS.md is actually defined on. See the header note: this reads
   RAW.SERVICE_TICKET as a temporary bridge until M2 exists.
   ------------------------------------------------------------------------- */
complaint_text AS (
  SELECT
    b.CUSTOMER_ID,
    COUNT_IF(b.COMPLAINT AND b.in_60d)                                  AS complaint_interactions_60d,
    COUNT_IF(b.COMPLAINT AND b.in_365d)                                 AS complaint_interactions_365d,
    MAX(IFF(b.COMPLAINT, b.OCCURRED_AT, NULL))                          AS last_complaint_at
  FROM base b GROUP BY 1
),
complaint_unresolved AS (
  SELECT ct.CUSTOMER_ID,
         (ct.last_complaint_at IS NOT NULL
          AND ct.last_complaint_at::DATE >= w.w60_complaint
          AND ct.last_complaint_at = c.last_contact_at) AS unresolved_complaint_flag
  FROM complaint_text ct
  JOIN chan c ON c.CUSTOMER_ID = ct.CUSTOMER_ID
  CROSS JOIN win w
),
complaint_ticket AS (
  SELECT t.CUSTOMER_ID,
         TRUE AS open_complaint_ticket_flag,
         MAX(t.SEVERITY) AS max_open_complaint_severity
  FROM RAW.SERVICE_TICKET t
  WHERE t.IS_COMPLAINT
    AND t.STATUS IN ('OPEN','IN_PROGRESS')
  GROUP BY 1
),

/* -------------------------------------------------------------------------
   Flags and entities. Counts rather than booleans wherever a count is
   meaningful: one competitor mention is a data point, four in ninety days is a
   pattern, and collapsing both to TRUE throws away the distinction the EV
   arithmetic in M5 wants.
   ------------------------------------------------------------------------- */
flags AS (
  SELECT
    CUSTOMER_ID,
    COUNT(*)                                                     AS interactions_365d,
    COUNT_IF(in_30d)                                             AS interactions_30d,
    COUNT_IF(in_90d)                                             AS interactions_90d,
    COUNT_IF(SOURCE_KIND = 'AUDIO')                              AS interactions_from_audio,

    COUNT_IF(CHURN_RISK_MENTIONED AND in_90d)                    AS churn_mentions_90d,
    COUNT_IF(COMPETITOR_MENTIONED AND in_90d)                    AS competitor_mentions_90d,
    COUNT_IF(HARDSHIP_SIGNAL      AND in_90d)                    AS hardship_mentions_90d,
    COUNT_IF(LIFE_EVENT           AND in_365d)                   AS life_events_365d,
    COUNT_IF(CONSENT_WITHDRAWAL   AND in_365d)                   AS consent_withdrawals_365d,

    -- consent withdrawal never expires on a rollup window: an opt-out asked for
    -- 400 days ago has not been un-asked, and letting it age out of a 365-day
    -- window would quietly re-enable marketing to someone who said stop.
    COUNT_IF(CONSENT_WITHDRAWAL)                                 AS consent_withdrawals_ever,
    MAX(IFF(CONSENT_WITHDRAWAL, OCCURRED_AT, NULL))              AS last_consent_withdrawal_at,

    -- action-driving intents get flat columns; the rest stay in the objects
    COUNT_IF(INTENT = 'RENEWAL_PRICING_DISPUTE'         AND in_90d) AS renewal_dispute_90d,
    COUNT_IF(INTENT = 'PAYMENT_DIFFICULTY_OR_DEFERRAL'  AND in_90d) AS payment_difficulty_90d,
    COUNT_IF(INTENT = 'SERVICE_QUALITY_COMPLAINT'       AND in_90d) AS service_complaint_90d,
    COUNT_IF(INTENT = 'CANCELLATION_OR_SURRENDER'       AND in_90d) AS cancellation_intent_90d,
    COUNT_IF(INTENT = 'CREDIT_LIMIT_OR_LOAN_REQUEST'    AND in_90d) AS limit_request_90d,
    COUNT_IF(INTENT IN ('CLAIM_STATUS_CHASE','CLAIM_REJECTION_GRIEVANCE') AND in_90d) AS claim_intents_90d,
    COUNT_IF(INTENT = 'MARKETING_OPT_OUT_REQUEST'       AND in_365d) AS opt_out_intents_365d,
    COUNT_IF(INTENT = 'BEREAVEMENT_OR_MEDICAL_NOTIFICATION')        AS bereavement_medical_ever,

    -- entities: the most recent non-null wins, since a stale competitor quote is
    -- less useful to an agent than the current one
    MAX(IFF(COMPETITOR_NAME IS NOT NULL, OCCURRED_AT, NULL))     AS last_competitor_mention_at,
    MAX(AMOUNT_DISCUSSED_INR)                                    AS max_amount_discussed_inr,
    MAX(PROMISED_CALLBACK_DATE)                                  AS latest_promised_callback_date,
    COUNT_IF(PROMISED_CALLBACK_DATE IS NOT NULL
             AND PROMISED_CALLBACK_DATE < (SELECT as_of FROM win)) AS callbacks_promised_and_past
  FROM base
  WHERE in_365d
  GROUP BY 1
),
latest_competitor AS (
  SELECT CUSTOMER_ID, COMPETITOR_NAME AS latest_competitor_name
  FROM (
    SELECT CUSTOMER_ID, COMPETITOR_NAME,
           ROW_NUMBER() OVER (PARTITION BY CUSTOMER_ID ORDER BY OCCURRED_AT DESC) AS rn
    FROM base WHERE COMPETITOR_NAME IS NOT NULL
  ) WHERE rn = 1
)

SELECT
  f.CUSTOMER_ID,

  /* volume */
  f.interactions_30d                        AS INTERACTIONS_30D,
  f.interactions_90d                        AS INTERACTIONS_90D,
  f.interactions_365d                       AS INTERACTIONS_365D,
  f.interactions_from_audio                 AS INTERACTIONS_FROM_AUDIO,

  /* intent breakdown */
  COALESCE(i30.obj,  OBJECT_CONSTRUCT())    AS INTENT_COUNTS_30D,
  COALESCE(i90.obj,  OBJECT_CONSTRUCT())    AS INTENT_COUNTS_90D,
  COALESCE(i365.obj, OBJECT_CONSTRUCT())    AS INTENT_COUNTS_365D,

  /* the intents a ranking rule reads directly */
  f.renewal_dispute_90d                     AS RENEWAL_DISPUTE_90D,
  f.payment_difficulty_90d                  AS PAYMENT_DIFFICULTY_90D,
  f.service_complaint_90d                   AS SERVICE_COMPLAINT_90D,
  f.cancellation_intent_90d                 AS CANCELLATION_INTENT_90D,
  f.limit_request_90d                       AS LIMIT_REQUEST_90D,
  f.claim_intents_90d                       AS CLAIM_INTENTS_90D,
  f.opt_out_intents_365d                    AS OPT_OUT_INTENTS_365D,
  f.bereavement_medical_ever                AS BEREAVEMENT_MEDICAL_EVER,

  /* sentiment level and trend */
  t.sentiment_avg_30d                       AS SENTIMENT_AVG_30D,
  t.sentiment_avg_90d                       AS SENTIMENT_AVG_90D,
  t.sentiment_avg_365d                      AS SENTIMENT_AVG_365D,
  t.sentiment_slope_per_30d                 AS SENTIMENT_SLOPE_PER_30D,
  t.sentiment_obs_365d                      AS SENTIMENT_OBS_365D,
  ls.latest_sentiment                       AS LATEST_SENTIMENT,
  ls.latest_sentiment_at                    AS LATEST_SENTIMENT_AT,
  CASE
    WHEN t.sentiment_slope_per_30d IS NULL      THEN 'INSUFFICIENT_DATA'
    WHEN t.sentiment_slope_per_30d <= -0.15     THEN 'DETERIORATING'
    WHEN t.sentiment_slope_per_30d >=  0.15     THEN 'IMPROVING'
    ELSE                                             'STABLE'
  END                                       AS SENTIMENT_TREND,

  /* behavioural flags */
  f.churn_mentions_90d                      AS CHURN_MENTIONS_90D,
  f.competitor_mentions_90d                 AS COMPETITOR_MENTIONS_90D,
  f.hardship_mentions_90d                   AS HARDSHIP_MENTIONS_90D,
  f.life_events_365d                        AS LIFE_EVENTS_365D,
  f.consent_withdrawals_365d                AS CONSENT_WITHDRAWALS_365D,
  f.consent_withdrawals_ever                AS CONSENT_WITHDRAWALS_EVER,
  f.last_consent_withdrawal_at              AS LAST_CONSENT_WITHDRAWAL_AT,

  /* extracted entities */
  lc.latest_competitor_name                 AS LATEST_COMPETITOR_NAME,
  f.last_competitor_mention_at              AS LAST_COMPETITOR_MENTION_AT,
  f.max_amount_discussed_inr                AS MAX_AMOUNT_DISCUSSED_INR,
  f.latest_promised_callback_date           AS LATEST_PROMISED_CALLBACK_DATE,
  f.callbacks_promised_and_past             AS CALLBACKS_PROMISED_AND_PAST,

  /* last contact, overall and per channel */
  c.last_contact_at                         AS LAST_CONTACT_AT,
  DATEDIFF(day, c.last_contact_at, (SELECT as_of FROM win)) AS DAYS_SINCE_LAST_CONTACT,
  c.last_call_at                            AS LAST_CALL_AT,
  c.last_email_at                           AS LAST_EMAIL_AT,
  c.last_chat_at                            AS LAST_CHAT_AT,
  c.last_branch_at                          AS LAST_BRANCH_AT,
  c.last_recorded_call_at                   AS LAST_RECORDED_CALL_AT,

  /* open complaint, both arms plus the union */
  ct.complaint_interactions_60d             AS COMPLAINT_INTERACTIONS_60D,
  ct.complaint_interactions_365d            AS COMPLAINT_INTERACTIONS_365D,
  ct.last_complaint_at                      AS LAST_COMPLAINT_AT,
  COALESCE(cu.unresolved_complaint_flag, FALSE)   AS UNRESOLVED_COMPLAINT_FLAG,
  COALESCE(ck.open_complaint_ticket_flag,  FALSE) AS OPEN_COMPLAINT_TICKET_FLAG,
  ck.max_open_complaint_severity                  AS MAX_OPEN_COMPLAINT_SEVERITY,
  ( COALESCE(cu.unresolved_complaint_flag, FALSE)
    OR COALESCE(ck.open_complaint_ticket_flag, FALSE) ) AS OPEN_COMPLAINT_FLAG,

  CURRENT_TIMESTAMP()                       AS LOAD_TS
FROM flags f
LEFT JOIN intent_30           i30 ON i30.CUSTOMER_ID = f.CUSTOMER_ID
LEFT JOIN intent_90           i90 ON i90.CUSTOMER_ID = f.CUSTOMER_ID
LEFT JOIN intent_365          i365 ON i365.CUSTOMER_ID = f.CUSTOMER_ID
LEFT JOIN chan                c   ON c.CUSTOMER_ID   = f.CUSTOMER_ID
LEFT JOIN trend               t   ON t.CUSTOMER_ID   = f.CUSTOMER_ID
LEFT JOIN latest_sentiment    ls  ON ls.CUSTOMER_ID  = f.CUSTOMER_ID
LEFT JOIN latest_competitor   lc  ON lc.CUSTOMER_ID  = f.CUSTOMER_ID
LEFT JOIN complaint_text      ct  ON ct.CUSTOMER_ID  = f.CUSTOMER_ID
LEFT JOIN complaint_unresolved cu ON cu.CUSTOMER_ID  = f.CUSTOMER_ID
LEFT JOIN complaint_ticket    ck  ON ck.CUSTOMER_ID  = f.CUSTOMER_ID;

/* ----------------------------------------------------------------------------
   Column contracts, in the catalog rather than only in a comment block. A CTAS
   cannot carry these, so they are reapplied on every run.
   ---------------------------------------------------------------------------- */

COMMENT ON COLUMN CURATED.CUSTOMER_INTERACTION_ROLLUP.SENTIMENT_TREND IS
  'LOAD-BEARING. The sentiment signal GOLD should rank on. One of DETERIORATING / STABLE / IMPROVING / INSUFFICIENT_DATA, bucketed from SENTIMENT_SLOPE_PER_30D at +/-0.15. Treat INSUFFICIENT_DATA as "unknown", never as "stable".';

COMMENT ON COLUMN CURATED.CUSTOMER_INTERACTION_ROLLUP.SENTIMENT_SLOPE_PER_30D IS
  'DIAGNOSTIC ONLY -- do NOT use in a ranking expression, propensity term or eligibility predicate. Populated for only ~23% of customers (needs 3+ sentiment readings) and the magnitude is inflated by a short baseline: three readings inside a few weeks fit a steep line regardless of the real change. Direction is reliable, magnitude is not. Read SENTIMENT_TREND instead. See PROJECT_BRIEF D6.';

COMMENT ON COLUMN CURATED.CUSTOMER_INTERACTION_ROLLUP.SENTIMENT_OBS_365D IS
  'How many sentiment readings the slope was fitted from. Below 3 the slope is NULL. Use this to judge how much weight SENTIMENT_TREND deserves for a given customer.';

COMMENT ON COLUMN CURATED.CUSTOMER_INTERACTION_ROLLUP.OPEN_COMPLAINT_TICKET_FLAG IS
  'Reads RAW.SERVICE_TICKET directly as a temporary bridge until M2 builds CURATED.INTERACTION. This is the authoritative complaint arm and the one the S1 retention predicate is defined on.';

COMMENT ON COLUMN CURATED.CUSTOMER_INTERACTION_ROLLUP.CONSENT_WITHDRAWALS_EVER IS
  'Deliberately unwindowed. An opt-out asked for 400 days ago has not been un-asked, so letting it age out of a 365-day window would quietly re-enable marketing to someone who said stop. Prefer this over CONSENT_WITHDRAWALS_365D in any suppression rule.';

/* ============================================================================
   VERIFY
   ============================================================================ */

SELECT 'rollup' AS check_name,
       COUNT(*)                                            AS customers,
       SUM(INTERACTIONS_365D)                              AS interactions_covered,
       COUNT_IF(SENTIMENT_SLOPE_PER_30D IS NOT NULL)        AS have_a_trend,
       COUNT_IF(OPEN_COMPLAINT_FLAG)                        AS open_complaints,
       COUNT_IF(INTERACTIONS_FROM_AUDIO > 0)                AS reached_by_audio
FROM CURATED.CUSTOMER_INTERACTION_ROLLUP;

-- Grain assertion: one row per customer, and every enriched interaction
-- accounted for exactly once.
SELECT 'grain' AS check_name,
       (SELECT COUNT(*) FROM CURATED.CUSTOMER_INTERACTION_ROLLUP)                    AS rollup_rows,
       (SELECT COUNT(DISTINCT CUSTOMER_ID) FROM CURATED.CUSTOMER_INTERACTION_ROLLUP) AS distinct_customers,
       (SELECT SUM(INTERACTIONS_365D) FROM CURATED.CUSTOMER_INTERACTION_ROLLUP)      AS summed_365d,
       (SELECT COUNT(*) FROM CURATED.INTERACTION_SIGNALS_GATED
         WHERE OCCURRED_AT::DATE >= DATEADD(day,-365, RAW.AS_OF()))                  AS actual_in_365d;

SELECT SENTIMENT_TREND, COUNT(*) AS customers,
       ROUND(AVG(SENTIMENT_SLOPE_PER_30D), 4) AS avg_slope,
       ROUND(AVG(INTERACTIONS_365D), 2)       AS avg_interactions
FROM CURATED.CUSTOMER_INTERACTION_ROLLUP GROUP BY 1 ORDER BY 2 DESC;

-- How much the confidence threshold is currently withholding. The gap between
-- interactions counted and intents attributed is the visible cost of the gate.
WITH attributed AS (
  SELECT SUM(v.value::NUMBER) AS n
  FROM CURATED.CUSTOMER_INTERACTION_ROLLUP r,
       LATERAL FLATTEN(input => r.INTENT_COUNTS_90D) v
)
SELECT 'threshold withholding' AS check_name,
       (SELECT SUM(INTERACTIONS_90D) FROM CURATED.CUSTOMER_INTERACTION_ROLLUP) AS interactions_90d,
       a.n                                                                     AS intents_attributed_90d,
       (SELECT SUM(INTERACTIONS_90D) FROM CURATED.CUSTOMER_INTERACTION_ROLLUP) - a.n AS withheld_by_threshold
FROM attributed a;

SELECT 'CURATED.CUSTOMER_INTERACTION_ROLLUP built' AS status;

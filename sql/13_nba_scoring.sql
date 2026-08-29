/* ============================================================================
   13_nba_scoring.sql  —  GOLD.NBA_CHURN_RISK
                          GOLD.NBA_TIMING_ANCHOR
                          GOLD.NBA_ACTION_BASE_RATE
                          GOLD.NBA_PROPENSITY_WEIGHTS
                          GOLD.NBA_SCORED
                          GOLD.NBA_ML_DATASET / GOLD.NBA_ML_HOLDOUT
                          GOLD.NBA_PROPENSITY_MODEL   (SNOWFLAKE.ML.CLASSIFICATION)
                          GOLD.NBA_PROPENSITY_COMPARISON
   ----------------------------------------------------------------------------
   Layer 3: how much each eligible action is worth.

   ZERO AI-FUNCTION CALLS. Nothing in this file calls AI_COMPLETE, AI_CLASSIFY,
   AI_EXTRACT, AI_SENTIMENT, AI_FILTER, AI_EMBED or AI_TRANSCRIBE.
   SNOWFLAKE.ML.CLASSIFICATION in part 6 is gradient-boosted trees on serverless
   compute and bills WAREHOUSE credits, not token credits -- it does not appear
   in SNOWFLAKE.ACCOUNT_USAGE.CORTEX_AI_FUNCTIONS_USAGE_HISTORY at all. Part 7
   asserts that by reading the view before and after. The 15-credit ceiling is
   untouched and remains entirely reserved for 14.

   Scores only rows where GOLD.NBA_ELIGIBLE.FINAL_VERDICT = 'ELIGIBLE'.
   Suppressed rows keep their VALUE_AT_STAKE_INR from 12 and get no propensity,
   because a propensity on an action that may not be taken is a number with no
   referent.

   ----------------------------------------------------------------------------
   THE EXPECTED-VALUE FORMULA, AND THE ONE BRANCH IN IT
   ----------------------------------------------------------------------------
   The milestone formula is

       expected_value_inr = propensity x margin x (1 - churn_risk) x timing

   Implemented as written for ACQUISITION actions. For RETENTION actions the
   churn term is INVERTED, per ACTION_CATALOG.VALUE_ORIENTATION:

       ACQUISITION   value x (1 - churn_risk)
       RETENTION     value x churn_risk

   The reason, restated because it is the single most consequential line in this
   file: (1 - churn_risk) prices an action DOWN as the customer becomes more
   likely to leave. That is right for a cross-sell -- a departing customer will
   not hold the new product long enough to earn the margin. It is exactly wrong
   for a save call, where the probability of leaving IS the thing being bought
   back. Applied literally across the board it sorts RETENTION_SAVE_CALL below
   a cross-sell precisely on the S1 cohort that the segment note says must
   receive a retention action, and it does so most strongly for the customers
   most at risk.

   Measured effect of the branch, in part 7.3 -- and it is NOT the effect first
   assumed here, so the first version of this paragraph was wrong and is
   corrected rather than quietly deleted.

   The assumption was that the branch RAISES retention expected value. It does
   not. Mean churn risk on the S1 cohort is 0.354, so churn_risk (0.354) is
   smaller than 1 - churn_risk (0.646) and the branch LOWERS mean
   RETENTION_SAVE_CALL expected value, from 7,865 to 7,193 -- a ratio of 0.91,
   and 0.69 across all retention-oriented actions.

   What the branch actually buys is the ORDERING, which is what a ranking engine
   is for. Correlation between RETENTION_SAVE_CALL expected value and churn risk:

       with the branch      r = +0.518
       literal formula      r = +0.021

   So under the branch the save call is worth progressively more for the
   customers progressively more likely to leave, which is the entire economic
   claim of a retention action. Under the literal formula that relationship is
   destroyed -- not cleanly inverted, because propensity and value at stake also
   rise with the churn signals (a disputed renewal and a named competitor push
   both), which partly masks the (1 - churn_risk) term and leaves expected value
   with no usable relationship to churn at all. A save call priced without regard
   to the probability of the save being needed is the defect; whether the number
   is bigger or smaller is beside the point.

   One consequence, worth stating because it cuts against the branch: lowering
   retention expected value makes retention MORE vulnerable to being outranked on
   raw value. Of the 73 S1 customers who also have an eligible sale, a sale beats
   the save call on expected value alone for 56 under the branch versus 23 under
   the literal formula. The PRIORITY_TIER ladder is what stops that, not the
   branch. The two mechanisms are complementary and neither is redundant: the
   branch gets the ordering right WITHIN retention, the ladder protects retention
   ACROSS categories. Removing the ladder because the branch exists would
   reintroduce exactly the failure docs/DATA_SEGMENTS.md S1 warns about.

   The floor. RETENTION value is churn_risk x value, so a loyal customer's save
   call scores near zero -- correctly, there is nothing to save. But zero would
   make the action invisible rather than merely low, so churn_risk is clamped
   to [0.02, 0.95] in part 1 and the retention multiplier therefore never
   collapses entirely.

   ----------------------------------------------------------------------------
   RANKING: TIER FIRST, THEN VALUE
   ----------------------------------------------------------------------------
   RANK_WITHIN_CUSTOMER orders by (PRIORITY_TIER, EXPECTED_VALUE_INR DESC), so
   expected value competes only INSIDE a tier. Product principle 3 forbids a
   large cross-sell outranking a hardship review, and no amount of expected
   value can cross a tier boundary. This is the ladder the placeholder
   GOLD.NEXT_BEST_ACTION already established, so the Streamlit screens do not
   move when 14 replaces its contents.

   ----------------------------------------------------------------------------
   TWO PROPENSITY MODELS, AND WHY THE FITTED ONE IS NOT THE ANSWER
   ----------------------------------------------------------------------------
   Part 3-5 build a transparent weighted-feature score. Part 6 fits
   SNOWFLAKE.ML.CLASSIFICATION on RAW.CAMPAIGN_HISTORY outcomes and part 6.4
   puts them side by side, as the milestone asks.

   The comparison was run before either was written, and the result is worth
   stating up front because it determines which one ships:

     RAW.CAMPAIGN_HISTORY.CONVERTED_FLAG is statistically INDEPENDENT of every
     customer feature in the book.

   Measured correlations against conversion, over all 24,918 contacts:

       product_count      0.0168        income_band_rank   0.0040
       est_margin         0.0122        credit_utilisation 0.0044
       age                0.0111        vulnerability      0.0020
       tenure_years      -0.0077

   Conversion by commercial segment spans 7.90% to 8.40% across five bands, and
   by product code 7.84% to 8.84% across eight -- noise on n>3,000 cells. The
   one apparently strong cell, SENTIMENT_TREND = DETERIORATING at 10.94%, rests
   on n=64.

   This is a property of the generator, not of the modelling: sql/03_seed_raw.sql
   drew the campaign outcome independently of the customer it was attached to.
   So a classifier fitted on it can only learn the ~8.15% base rate, and its AUC
   should land near 0.5. Part 6.3 reports the measured figure rather than
   asserting it, because "should" is not "did".

   The consequence for the engine: the TRANSPARENT score is the one that feeds
   14 and GOLD.NEXT_BEST_ACTION. It encodes domain priors -- a customer who has
   asked about their limit twice is a better limit-increase prospect than one who
   has not -- which is a defensible judgement model. A 0.5-AUC classifier is not
   a better model than a defensible prior; it is a random number with a
   confidence interval. Shipping it because it is "the ML one" would be the
   error this comparison exists to prevent.

   What the fitted model IS good for: it demonstrates the mechanism end to end,
   and it establishes the number that a real campaign history would have to beat.
   On production data with outcomes that actually depend on the customer, part 6
   is the path, and PROPENSITY_SOURCE in GOLD.NBA_SCORED is the switch.

   ----------------------------------------------------------------------------
   A LEAKAGE CAVEAT ON THE FITTED MODEL, STATED BECAUSE IT WOULD OTHERWISE HIDE
   ----------------------------------------------------------------------------
   Training joins RAW.CAMPAIGN_HISTORY to GOLD.NBA_FEATURE_BASE on CUSTOMER_ID,
   which pairs an outcome from up to 18 months ago with the customer's state
   TODAY. Features are therefore post-outcome. On this dataset it changes
   nothing, since the label has no signal to leak, but the join would be
   indefensible on real data and the fix -- point-in-time features as of
   CONTACTED_AT -- is not available here because CURATED carries no history
   tables. Recorded so the pattern is not copied.

   ----------------------------------------------------------------------------
   D6 IS RESPECTED IN THE CHURN SCORE, AND IT TAKES A THIRD BRANCH
   ----------------------------------------------------------------------------
   SENTIMENT_TREND has five values and two of them -- INSUFFICIENT_DATA and
   NO_CONTACT_HISTORY -- mean UNKNOWN, which PROJECT_BRIEF D6 says must never be
   read as STABLE. 4,267 of 5,000 customers are in one of those two states, so
   this is the common case rather than an edge case.

   The churn score therefore branches three ways, not two: DETERIORATING adds
   0.30, IMPROVING subtracts 0.05, STABLE adds nothing, and UNKNOWN adds a small
   0.03 uncertainty premium. Not the STABLE value, because unknown is not calm;
   not the DETERIORATING value, because unknown is not evidence of anything. The
   premium is deliberately small enough that it cannot promote an action on
   absence of information alone.

   SENTIMENT_SLOPE_PER_30D is not referenced anywhere in this file. Part 7
   asserts it.
============================================================================ */

USE ROLE COCO_BUILDER;
USE DATABASE C360_NBA;
USE SCHEMA GOLD;
USE WAREHOUSE COCO_WH;


/* ============================================================================
   PART 0  —  PREFLIGHT
============================================================================ */

CREATE OR REPLACE PROCEDURE GOLD.SP_ASSERT_ELIGIBLE_READY()
RETURNS VARCHAR
LANGUAGE SQL
COMMENT = 'Raises unless GOLD.NBA_ELIGIBLE exists at full (customer x action) grain with at least one eligible row. Scoring a partial eligibility pass would silently rank a subset of the book.'
AS
$$
DECLARE
    n_rows   INTEGER;
    n_elig   INTEGER;
    n_expect INTEGER;
    NOT_READY EXCEPTION (-20601, 'ABORT: GOLD.NBA_ELIGIBLE is missing, wrong-grained or has no eligible rows. Run 12_nba_eligibility.sql first.');
BEGIN
    n_rows   := (SELECT COUNT(*) FROM GOLD.NBA_ELIGIBLE);
    n_elig   := (SELECT COUNT_IF(FINAL_VERDICT = 'ELIGIBLE') FROM GOLD.NBA_ELIGIBLE);
    n_expect := (SELECT COUNT(*) FROM GOLD.NBA_FEATURE_BASE)
              * (SELECT COUNT(*) FROM GOLD.ACTION_CATALOG);

    IF (n_rows <> n_expect OR n_elig = 0) THEN
        RAISE NOT_READY;
    END IF;
    RETURN 'eligibility ready: ' || n_rows || ' rows, ' || n_elig || ' eligible';
END;
$$;

CALL GOLD.SP_ASSERT_ELIGIBLE_READY();

/* Credit ledger, read BEFORE any compute in this file. Part 7.4 reads it again
   and asserts the delta is zero. The ceiling is reserved for 14. */
CREATE OR REPLACE TABLE GOLD.NBA_CREDIT_CHECKPOINT AS
SELECT '13_start' AS CHECKPOINT, CURRENT_TIMESTAMP() AS AT_TS;


/* ============================================================================
   PART 1  —  GOLD.NBA_CHURN_RISK
   ----------------------------------------------------------------------------
   One row per customer. Transparent additive score in [0.02, 0.95], with the
   contributions kept alongside the total so a number can be explained rather
   than only reported.

   Every weight is a stated domain prior, NOT a fitted coefficient. Nothing in
   this dataset could fit them: see the independence finding in the header.
   They are declared here as data-in-SQL rather than hidden in a model artefact
   precisely so a reviewer can disagree with one and see what moves.
============================================================================ */

CREATE OR REPLACE TABLE GOLD.NBA_CHURN_RISK AS
WITH c AS (
    SELECT
        f.CUSTOMER_ID,
        f.SENTIMENT_TREND,
        f.SENTIMENT_NOW,

        /* -- D6: three branches, because UNKNOWN is neither STABLE nor bad --- */
        CASE f.SENTIMENT_TREND
            WHEN 'DETERIORATING' THEN 0.30
            WHEN 'IMPROVING'     THEN -0.05
            WHEN 'STABLE'        THEN 0.00
            ELSE 0.03   /* INSUFFICIENT_DATA / NO_CONTACT_HISTORY = unknown */
        END                                                     AS W_TREND,

        IFF(f.SENTIMENT_NOW = 'negative',        0.05, 0.00)     AS W_SENT_NOW,
        IFF(f.CHURN_MENTIONS_90D      > 0,       0.15, 0.00)     AS W_CHURN_TALK,
        IFF(f.COMPETITOR_MENTIONS_90D > 0,       0.12, 0.00)     AS W_COMPETITOR,
        IFF(f.CANCELLATION_INTENT_90D > 0,       0.15, 0.00)     AS W_CANCEL_INTENT,
        IFF(f.RENEWAL_DISPUTE_90D     > 0,       0.08, 0.00)     AS W_RENEWAL_DISPUTE,
        IFF(f.OPEN_COMPLAINT,                    0.10, 0.00)     AS W_OPEN_COMPLAINT,
        0.05 * LEAST(COALESCE(f.LAPSE_HISTORY, 0), 2)            AS W_LAPSE,
        0.10                                                     AS W_BASE
    FROM GOLD.NBA_FEATURE_BASE f
)
SELECT
    CUSTOMER_ID,
    LEAST(0.95, GREATEST(0.02,
        W_BASE + W_TREND + W_SENT_NOW + W_CHURN_TALK + W_COMPETITOR
        + W_CANCEL_INTENT + W_RENEWAL_DISPUTE + W_OPEN_COMPLAINT + W_LAPSE
    ))                                                          AS CHURN_RISK,
    SENTIMENT_TREND,
    (SENTIMENT_TREND IN ('INSUFFICIENT_DATA', 'NO_CONTACT_HISTORY'))
                                                                AS TREND_IS_UNKNOWN,
    /* the contributions, so the score is explainable per customer */
    OBJECT_CONSTRUCT_KEEP_NULL(
        'base',             W_BASE,
        'sentiment_trend',  W_TREND,
        'sentiment_now',    W_SENT_NOW,
        'churn_talk',       W_CHURN_TALK,
        'competitor',       W_COMPETITOR,
        'cancel_intent',    W_CANCEL_INTENT,
        'renewal_dispute',  W_RENEWAL_DISPUTE,
        'open_complaint',   W_OPEN_COMPLAINT,
        'lapse_history',    W_LAPSE
    )                                                           AS CHURN_CONTRIBUTIONS
FROM c;

COMMENT ON TABLE GOLD.NBA_CHURN_RISK IS
'Transparent additive churn score per customer, clamped to [0.02, 0.95], with CHURN_CONTRIBUTIONS carrying the per-term breakdown so any value can be explained rather than only reported. Every weight is a STATED DOMAIN PRIOR, not a fitted coefficient -- RAW.CAMPAIGN_HISTORY outcomes are statistically independent of all customer features (|r| < 0.017), so nothing here could be fitted from this dataset. Reads SENTIMENT_TREND and branches THREE ways per PROJECT_BRIEF D6: INSUFFICIENT_DATA and NO_CONTACT_HISTORY mean unknown and get a small 0.03 uncertainty premium, never the STABLE value. Does not reference SENTIMENT_SLOPE_PER_30D.';


/* ============================================================================
   PART 2  —  GOLD.NBA_TIMING_ANCHOR
   ----------------------------------------------------------------------------
   Which scheduled date makes an action timely. Held as data rather than a CASE
   buried in part 5, so it is tunable and auditable -- the same treatment
   CURATED.INTENT_TAXONOMY and CURATED.AI_CONFIG get.

   RENEWAL  the policy renewal conversation is the natural opening
   EMI      the instalment date is the natural opening
   NONE     the action is triggered by an event, not a calendar date
============================================================================ */

CREATE OR REPLACE TABLE GOLD.NBA_TIMING_ANCHOR (
    ACTION_CODE  VARCHAR(40) NOT NULL,
    ANCHOR       VARCHAR(10) NOT NULL,
    RATIONALE    VARCHAR(300) NOT NULL,
    CONSTRAINT PK_NBA_TIMING_ANCHOR PRIMARY KEY (ACTION_CODE)
);

INSERT INTO GOLD.NBA_TIMING_ANCHOR (ACTION_CODE, ANCHOR, RATIONALE)
SELECT * FROM VALUES
 ('COLLECTIONS_HARDSHIP_OUTREACH', 'EMI',
  'A hardship conversation lands best just before the instalment the customer is about to miss, not after.'),
 ('EARLY_ARREARS_REMINDER',        'EMI',
  'A reminder is only a reminder if it arrives before the due date.'),
 ('COMPLAINT_RESOLUTION_CALLBACK', 'NONE',
  'Driven by the grievance clock, not the product calendar. IRDAI timelines run from the complaint date, so calendar proximity must not modulate urgency.'),
 ('SERVICE_RECOVERY_OUTREACH',     'NONE',
  'Triggered by souring sentiment. Waiting for a renewal date to make it timely would defeat the point.'),
 ('RETENTION_SAVE_CALL',           'RENEWAL',
  'The renewal decision is the moment the customer leaves or stays. Proximity is the whole signal.'),
 ('RETENTION_WINBACK_LAPSED',      'NONE',
  'The policy already lapsed; there is no upcoming date to be near.'),
 ('RENEWAL_REMINDER_EARLY',        'RENEWAL',
  'Definitionally anchored on the renewal date.'),
 ('WEALTH_REFERRAL',               'NONE',
  'Anchored on the inbound lumpsum, which is an event. Advisory urgency decays from the credit date, not from a scheduled date.'),
 ('CARD_LIMIT_INCREASE',           'EMI',
  'A limit conversation is credible next to a statement cycle.'),
 ('CARD_UPGRADE_PLATINUM',         'EMI',
  'Same reasoning as the limit increase.'),
 ('TERM_ROP_UPSELL',               'RENEWAL',
  'An upsell on a held term policy belongs in the renewal conversation.'),
 ('HOME_PROTECTION_CROSS_SELL',    'EMI',
  'Attaches to an active home loan; the instalment is the touchpoint the customer already recognises.'),
 ('HEALTH_CROSS_SELL_FAMILY',      'RENEWAL',
  'Sold alongside an existing policy renewal.'),
 ('HEALTH_CROSS_SELL_INDIVIDUAL',  'RENEWAL',
  'Sold alongside an existing policy renewal.'),
 ('TERM_LIFE_CROSS_SELL',          'RENEWAL',
  'Sold alongside an existing policy renewal.'),
 ('MOTOR_CROSS_SELL',              'RENEWAL',
  'Motor cover is statutory and renewal-cyclical; the renewal window is when the customer is shopping.'),
 ('PERSONAL_LOAN_CROSS_SELL',      'EMI',
  'Affordability is most legible next to an existing instalment.'),
 ('CARD_ACQUISITION',              'RENEWAL',
  'No natural credit anchor for a customer holding no card, so the policy renewal contact is the opening.')
AS t(ACTION_CODE, ANCHOR, RATIONALE);

COMMENT ON TABLE GOLD.NBA_TIMING_ANCHOR IS
'Which scheduled date makes each action timely: RENEWAL, EMI or NONE, with the reasoning per row. Held as data rather than a CASE expression so it is tunable and auditable, the same treatment CURATED.INTENT_TAXONOMY and CURATED.AI_CONFIG receive. NONE is not "no opinion" -- it means the action is event-triggered and calendar proximity must NOT modulate it, which for COMPLAINT_RESOLUTION_CALLBACK is a compliance point: the IRDAI clock runs from the complaint date and a renewal being far away must not make a grievance look less urgent.';


/* ============================================================================
   PART 3  —  GOLD.NBA_ACTION_BASE_RATE
   ----------------------------------------------------------------------------
   Observed conversion rate per action, from RAW.CAMPAIGN_HISTORY where the
   product was actually campaigned, else the book-wide prior.

   This is the only part of the transparent propensity grounded in observed
   outcomes rather than declared priors -- and the spread is 7.84% to 8.84%,
   which is the independence finding showing up again. The base rate is
   therefore doing very little work; the feature adjustments in part 4 are what
   separate customers.
============================================================================ */

CREATE OR REPLACE TABLE GOLD.NBA_ACTION_BASE_RATE AS
WITH book_prior AS (
    SELECT AVG(IFF(CONVERTED_FLAG, 1.0, 0.0)) AS RATE FROM RAW.CAMPAIGN_HISTORY
),
observed AS (
    SELECT PRODUCT_CODE,
           COUNT(*)                              AS CONTACTS,
           AVG(IFF(CONVERTED_FLAG, 1.0, 0.0))    AS RATE
    FROM RAW.CAMPAIGN_HISTORY
    GROUP BY 1
)
SELECT
    a.ACTION_CODE,
    CASE WHEN a.ACTION_CODE = 'WEALTH_REFERRAL' THEN 'INS_ULIP_BAL'
         ELSE a.PRODUCT_ID END                                    AS MATCH_CODE,
    o.CONTACTS                                                    AS OBSERVED_CONTACTS,
    COALESCE(o.RATE, bp.RATE)                                     AS BASE_RATE,
    IFF(o.RATE IS NULL, 'BOOK_PRIOR', 'OBSERVED')                 AS BASE_RATE_SOURCE
FROM GOLD.ACTION_CATALOG a
CROSS JOIN book_prior bp
LEFT JOIN observed o
       ON o.PRODUCT_CODE = CASE WHEN a.ACTION_CODE = 'WEALTH_REFERRAL'
                                THEN 'INS_ULIP_BAL' ELSE a.PRODUCT_ID END;

COMMENT ON TABLE GOLD.NBA_ACTION_BASE_RATE IS
'Prior probability of conversion per action. OBSERVED where RAW.CAMPAIGN_HISTORY campaigned the matching product code (8 of 18 actions, n>3,000 each), BOOK_PRIOR (8.15%) otherwise. The observed spread is 7.84%-8.84%, so the base rate barely discriminates -- campaign outcomes in this dataset are independent of both product and customer. The feature adjustments in GOLD.NBA_PROPENSITY_WEIGHTS do the separating.';


/* ============================================================================
   PART 4  —  GOLD.NBA_PROPENSITY_WEIGHTS
   ----------------------------------------------------------------------------
   Log-odds adjustments applied on top of the base rate.

   SCOPE_KIND lets one row serve many actions:
     ALL       every action
     CATEGORY  every action in that CATEGORY
     ACTION    one action

   Each FEATURE is normalised to [0,1] in part 5 (the normalisation is stated
   there, once, next to the column it reads) and multiplied by WEIGHT, which is
   in log-odds. A weight of 0.7 on a feature at its maximum roughly doubles the
   odds; 1.4 roughly quadruples them. Nothing here exceeds 1.4, so no single
   signal can dominate the score.

   These are declared priors. The header explains why they cannot be fitted on
   this dataset and part 6 measures what happens when you try.
============================================================================ */

CREATE OR REPLACE TABLE GOLD.NBA_PROPENSITY_WEIGHTS (
    SCOPE_KIND   VARCHAR(10)  NOT NULL,
    SCOPE_VALUE  VARCHAR(40)  NOT NULL,
    FEATURE      VARCHAR(40)  NOT NULL,
    WEIGHT       FLOAT        NOT NULL,
    RATIONALE    VARCHAR(300) NOT NULL
);

INSERT INTO GOLD.NBA_PROPENSITY_WEIGHTS (SCOPE_KIND, SCOPE_VALUE, FEATURE, WEIGHT, RATIONALE)
SELECT * FROM VALUES
 /* -- behavioural history, applies to everything ------------------------- */
 ('ALL', '*', 'ENGAGED_BEFORE',          0.90,
  'Previously CONVERTED or INTERESTED on this product. The strongest honest signal available, because it is an observed response to this exact offer.'),
 ('ALL', '*', 'DECLINED_BEFORE',        -0.70,
  'Previously DECLINED this product. Negative, and deliberately smaller in magnitude than ENGAGED_BEFORE: a decline ages into indifference faster than interest ages into loyalty.'),
 ('ALL', '*', 'CHANNEL_IS_PREFERRED',    0.35,
  'Action channel matches the channel that has historically produced engagement. A behavioural preference, and PREFERRED_CHANNEL carries no permission, so this only ever appears on rows that already passed the consent gate.'),
 ('ALL', '*', 'TENURE',                  0.25,
  'Longer relationships convert better on additional product. Bounded at 10 years.'),
 ('ALL', '*', 'PRODUCT_COUNT',           0.30,
  'Cross-holding depth. A customer holding three products is a demonstrated buyer.'),

 /* -- cross-sell and upsell ---------------------------------------------- */
 ('CATEGORY', 'CROSS_SELL', 'INCOME_BAND',      0.40,
  'Affordability of discretionary cover rises with income band.'),
 ('CATEGORY', 'CROSS_SELL', 'LIFE_EVENTS',      0.55,
  'A life event in the last year is the classic protection trigger. Read from the interaction corpus, so it is text-derived and gated on confidence.'),
 ('CATEGORY', 'CROSS_SELL', 'SERVICE_COMPLAINT',-0.45,
  'Recent service friction depresses receptiveness to being sold to, even where no complaint was formally logged.'),
 ('CATEGORY', 'UPSELL',     'INCOME_BAND',      0.45,
  'Upsell is to a richer variant, so income matters slightly more than for cross-sell.'),
 ('CATEGORY', 'UPSELL',     'SERVICE_COMPLAINT',-0.45,
  'Same reasoning as cross-sell.'),

 /* -- the limit increase, where the corpus carries a direct request ------- */
 ('ACTION', 'CARD_LIMIT_INCREASE', 'LIMIT_REQUEST',     1.40,
  'The customer has ASKED about their limit in conversation. The single most direct intent signal anywhere in the dataset, and the reason the text pipeline exists.'),
 ('ACTION', 'CARD_LIMIT_INCREASE', 'UTILISATION_RISING', 0.80,
  'The four-reading monotonic rise is the need itself; here it also predicts acceptance.'),
 ('ACTION', 'CARD_LIMIT_INCREASE', 'CREDIT_UTILISATION', 0.45,
  'Higher current utilisation means the limit is binding and an increase is useful now.'),
 ('ACTION', 'CARD_UPGRADE_PLATINUM', 'RELATIONSHIP_VALUE', 0.55,
  'Platinum is a relationship-value proposition, not a need.'),

 /* -- retention and service ---------------------------------------------- */
 ('CATEGORY', 'RETENTION', 'RENEWAL_DISPUTE',   0.60,
  'A renewal already being disputed means the conversation is live and the customer will take the call.'),
 ('CATEGORY', 'RETENTION', 'COMPETITOR',        0.50,
  'A named competitor means the customer is shopping and still talking to us, which is the save window.'),
 ('CATEGORY', 'RETENTION', 'SENTIMENT_DETERIORATING', 0.30,
  'Deteriorating sentiment raises the chance a save conversation is accepted, distinct from raising the value at stake, which the churn term handles.'),
 ('CATEGORY', 'SERVICE_RECOVERY', 'COMPLAINT_SEVERITY', 0.70,
  'A severe open grievance means the customer very much wants to be called about it.'),
 ('CATEGORY', 'SERVICE_RECOVERY', 'SENTIMENT_DETERIORATING', 0.40,
  'Same direction as retention, larger because a service call is not a sale and has no price objection to overcome.'),

 /* -- collections --------------------------------------------------------- */
 ('CATEGORY', 'COLLECTIONS', 'HARDSHIP_TALK',   0.95,
  'The customer has raised difficulty paying in their own words. Near-decisive for engagement with a hardship review.'),
 ('CATEGORY', 'COLLECTIONS', 'PAYMENT_DIFFICULTY', 0.85,
  'The classified intent counterpart of HARDSHIP_TALK, from an independent function, so both firing is corroboration rather than double-counting.'),

 /* -- wealth -------------------------------------------------------------- */
 ('ACTION', 'WEALTH_REFERRAL', 'LUMPSUM_SIZE',  0.85,
  'A larger inbound credit means a larger advisory need and a much higher chance of engaging an adviser.'),
 ('ACTION', 'WEALTH_REFERRAL', 'INCOME_BAND',   0.40,
  'Existing affluence corroborates that the lumpsum is investable rather than earmarked.')
AS t(SCOPE_KIND, SCOPE_VALUE, FEATURE, WEIGHT, RATIONALE);

COMMENT ON TABLE GOLD.NBA_PROPENSITY_WEIGHTS IS
'Log-odds adjustments on top of GOLD.NBA_ACTION_BASE_RATE, scoped by SCOPE_KIND (ALL / CATEGORY / ACTION) so one row can serve many actions. Every row carries its RATIONALE. These are DECLARED DOMAIN PRIORS, not fitted coefficients: RAW.CAMPAIGN_HISTORY outcomes are independent of every customer feature in this dataset (|r| < 0.017), so nothing here is fittable from it -- see 13 part 6 for the measured demonstration. Held as data so a reviewer can disagree with one weight and see exactly what moves. No weight exceeds 1.4 in magnitude, so no single signal can dominate a score.';


/* ============================================================================
   PART 5  —  GOLD.NBA_SCORED
   ----------------------------------------------------------------------------
   Eligible rows only. Propensity, the churn term with its orientation branch,
   the timing multiplier, expected value, and the rank.
============================================================================ */

CREATE OR REPLACE TABLE GOLD.NBA_SCORED AS
WITH base AS (
    SELECT
        e.*,
        cr.CHURN_RISK,
        cr.TREND_IS_UNKNOWN,
        cr.CHURN_CONTRIBUTIONS,
        br.BASE_RATE,
        br.BASE_RATE_SOURCE,
        ta.ANCHOR                                                AS TIMING_ANCHOR,
        f.AGE, f.INCOME_BAND_RANK, f.TENURE_YEARS, f.PRODUCT_COUNT,
        f.CREDIT_UTILISATION, f.UTILISATION_RISING_4,
        f.RELATIONSHIP_VALUE_BAND, f.PREFERRED_CHANNEL,
        f.LIFE_EVENTS_365D, f.SERVICE_COMPLAINT_90D, f.LIMIT_REQUEST_90D,
        f.HARDSHIP_MENTIONS_90D, f.PAYMENT_DIFFICULTY_90D,
        f.RENEWAL_DISPUTE_90D, f.COMPETITOR_MENTIONS_90D,
        f.OPEN_COMPLAINT_SEVERITY, f.LUMPSUM_CREDIT_MAX_INR,
        f.SENTIMENT_TREND, f.DAYS_TO_RENEWAL, f.NEXT_EMI_DATE,
        f.AS_OF_DATE,
        cd.LAST_OUTCOME
    FROM GOLD.NBA_ELIGIBLE e
    JOIN GOLD.NBA_CHURN_RISK        cr ON cr.CUSTOMER_ID = e.CUSTOMER_ID
    JOIN GOLD.NBA_ACTION_BASE_RATE  br ON br.ACTION_CODE = e.ACTION_CODE
    JOIN GOLD.NBA_TIMING_ANCHOR     ta ON ta.ACTION_CODE = e.ACTION_CODE
    JOIN GOLD.NBA_FEATURE_BASE      f  ON f.CUSTOMER_ID  = e.CUSTOMER_ID
    LEFT JOIN GOLD.NBA_COOLDOWN_STATE cd
           ON cd.CUSTOMER_ID  = e.CUSTOMER_ID
          AND cd.PRODUCT_CODE = CASE WHEN e.ACTION_CODE = 'WEALTH_REFERRAL'
                                     THEN 'INS_ULIP_BAL' ELSE e.PRODUCT_ID END
    WHERE e.FINAL_VERDICT = 'ELIGIBLE'
),
/* -- every feature normalised to [0,1], stated once, next to its source --- */
feat AS (
    SELECT b.*,
        LEAST(COALESCE(b.LIMIT_REQUEST_90D, 0), 2) / 2.0          AS Z_LIMIT_REQUEST,
        IFF(b.UTILISATION_RISING_4, 1.0, 0.0)                     AS Z_UTILISATION_RISING,
        LEAST(GREATEST(COALESCE(b.CREDIT_UTILISATION, 0), 0), 1)  AS Z_CREDIT_UTILISATION,
        (COALESCE(b.INCOME_BAND_RANK, 1) - 1) / 4.0               AS Z_INCOME_BAND,
        LEAST(COALESCE(b.TENURE_YEARS, 0), 10) / 10.0             AS Z_TENURE,
        LEAST(COALESCE(b.PRODUCT_COUNT, 0), 5) / 5.0              AS Z_PRODUCT_COUNT,
        LEAST(COALESCE(b.LIFE_EVENTS_365D, 0), 2) / 2.0           AS Z_LIFE_EVENTS,
        LEAST(COALESCE(b.SERVICE_COMPLAINT_90D, 0), 2) / 2.0      AS Z_SERVICE_COMPLAINT,
        LEAST(COALESCE(b.RENEWAL_DISPUTE_90D, 0), 2) / 2.0        AS Z_RENEWAL_DISPUTE,
        LEAST(COALESCE(b.COMPETITOR_MENTIONS_90D, 0), 2) / 2.0    AS Z_COMPETITOR,
        LEAST(COALESCE(b.HARDSHIP_MENTIONS_90D, 0), 2) / 2.0      AS Z_HARDSHIP_TALK,
        LEAST(COALESCE(b.PAYMENT_DIFFICULTY_90D, 0), 2) / 2.0     AS Z_PAYMENT_DIFFICULTY,
        COALESCE(b.OPEN_COMPLAINT_SEVERITY, 0) / 5.0              AS Z_COMPLAINT_SEVERITY,
        IFF(b.SENTIMENT_TREND = 'DETERIORATING', 1.0, 0.0)        AS Z_SENTIMENT_DETERIORATING,
        LEAST(COALESCE(b.LUMPSUM_CREDIT_MAX_INR, 0), 5000000) / 5000000.0
                                                                  AS Z_LUMPSUM_SIZE,
        CASE b.RELATIONSHIP_VALUE_BAND
            WHEN 'PLATINUM' THEN 1.00 WHEN 'GOLD'   THEN 0.75
            WHEN 'SILVER'   THEN 0.50 WHEN 'BRONZE' THEN 0.25
            ELSE 0.00 END                                         AS Z_RELATIONSHIP_VALUE,
        IFF(b.LAST_OUTCOME IN ('CONVERTED', 'INTERESTED'), 1.0, 0.0)
                                                                  AS Z_ENGAGED_BEFORE,
        IFF(b.LAST_OUTCOME = 'DECLINED', 1.0, 0.0)                AS Z_DECLINED_BEFORE,
        IFF(b.CHANNEL = b.PREFERRED_CHANNEL, 1.0, 0.0)            AS Z_CHANNEL_IS_PREFERRED,

        /* -- timing. Bounded [0.85, 1.35]; a multiplier that can swing wider
              than this starts reordering across priority tiers, which the
              ladder forbids. -------------------------------------------------- */
        CASE
          WHEN b.TIMING_ANCHOR = 'NONE' THEN 1.00
          WHEN b.TIMING_ANCHOR = 'RENEWAL' THEN
            CASE WHEN b.DAYS_TO_RENEWAL IS NULL              THEN 0.90
                 WHEN b.DAYS_TO_RENEWAL BETWEEN 0  AND 7     THEN 1.35
                 WHEN b.DAYS_TO_RENEWAL BETWEEN 8  AND 15    THEN 1.25
                 WHEN b.DAYS_TO_RENEWAL BETWEEN 16 AND 30    THEN 1.15
                 WHEN b.DAYS_TO_RENEWAL BETWEEN 31 AND 60    THEN 1.05
                 WHEN b.DAYS_TO_RENEWAL BETWEEN 61 AND 120   THEN 1.00
                 ELSE 0.90 END
          WHEN b.TIMING_ANCHOR = 'EMI' THEN
            CASE WHEN b.NEXT_EMI_DATE IS NULL                THEN 0.90
                 WHEN DATEDIFF(day, b.AS_OF_DATE, b.NEXT_EMI_DATE) BETWEEN 0  AND 7  THEN 1.35
                 WHEN DATEDIFF(day, b.AS_OF_DATE, b.NEXT_EMI_DATE) BETWEEN 8  AND 15 THEN 1.25
                 WHEN DATEDIFF(day, b.AS_OF_DATE, b.NEXT_EMI_DATE) BETWEEN 16 AND 30 THEN 1.15
                 WHEN DATEDIFF(day, b.AS_OF_DATE, b.NEXT_EMI_DATE) > 30             THEN 1.00
                 ELSE 0.90 END
          ELSE 1.00
        END                                                       AS TIMING_MULTIPLIER
    FROM base b
),
/* -- apply the weight table. One row per (customer, action, weight). ------ */
contrib AS (
    SELECT
        f.CUSTOMER_ID,
        f.ACTION_CODE,
        w.FEATURE,
        w.WEIGHT,
        CASE w.FEATURE
            WHEN 'LIMIT_REQUEST'           THEN f.Z_LIMIT_REQUEST
            WHEN 'UTILISATION_RISING'      THEN f.Z_UTILISATION_RISING
            WHEN 'CREDIT_UTILISATION'      THEN f.Z_CREDIT_UTILISATION
            WHEN 'INCOME_BAND'             THEN f.Z_INCOME_BAND
            WHEN 'TENURE'                  THEN f.Z_TENURE
            WHEN 'PRODUCT_COUNT'           THEN f.Z_PRODUCT_COUNT
            WHEN 'LIFE_EVENTS'             THEN f.Z_LIFE_EVENTS
            WHEN 'SERVICE_COMPLAINT'       THEN f.Z_SERVICE_COMPLAINT
            WHEN 'RENEWAL_DISPUTE'         THEN f.Z_RENEWAL_DISPUTE
            WHEN 'COMPETITOR'              THEN f.Z_COMPETITOR
            WHEN 'HARDSHIP_TALK'           THEN f.Z_HARDSHIP_TALK
            WHEN 'PAYMENT_DIFFICULTY'      THEN f.Z_PAYMENT_DIFFICULTY
            WHEN 'COMPLAINT_SEVERITY'      THEN f.Z_COMPLAINT_SEVERITY
            WHEN 'SENTIMENT_DETERIORATING' THEN f.Z_SENTIMENT_DETERIORATING
            WHEN 'LUMPSUM_SIZE'            THEN f.Z_LUMPSUM_SIZE
            WHEN 'RELATIONSHIP_VALUE'      THEN f.Z_RELATIONSHIP_VALUE
            WHEN 'ENGAGED_BEFORE'          THEN f.Z_ENGAGED_BEFORE
            WHEN 'DECLINED_BEFORE'         THEN f.Z_DECLINED_BEFORE
            WHEN 'CHANNEL_IS_PREFERRED'    THEN f.Z_CHANNEL_IS_PREFERRED
        END                                                       AS Z
    FROM feat f
    JOIN GOLD.NBA_PROPENSITY_WEIGHTS w
      ON (w.SCOPE_KIND = 'ALL')
      OR (w.SCOPE_KIND = 'CATEGORY' AND w.SCOPE_VALUE = f.CATEGORY)
      OR (w.SCOPE_KIND = 'ACTION'   AND w.SCOPE_VALUE = f.ACTION_CODE)
),
agg AS (
    SELECT CUSTOMER_ID, ACTION_CODE,
           SUM(WEIGHT * Z)                                        AS LOGIT_ADJUSTMENT,
           OBJECT_AGG(FEATURE, ROUND(WEIGHT * Z, 4)::VARIANT)      AS DRIVER_FEATURES
    FROM contrib
    WHERE Z IS NOT NULL
    GROUP BY 1, 2
),
scored AS (
    SELECT
        f.*,
        COALESCE(g.LOGIT_ADJUSTMENT, 0)                           AS LOGIT_ADJUSTMENT,
        COALESCE(g.DRIVER_FEATURES, OBJECT_CONSTRUCT())            AS DRIVER_FEATURES,

        /* logistic( logit(base) + adjustments ), clamped away from 0 and 1 */
        LEAST(0.95, GREATEST(0.005,
            1.0 / (1.0 + EXP(-(
                LN(f.BASE_RATE / (1 - f.BASE_RATE)) + COALESCE(g.LOGIT_ADJUSTMENT, 0)
            )))
        ))                                                        AS PROPENSITY,

        /* THE ORIENTATION BRANCH. See the file header. */
        CASE f.VALUE_ORIENTATION
            WHEN 'ACQUISITION' THEN 1.0 - f.CHURN_RISK
            WHEN 'RETENTION'   THEN f.CHURN_RISK
        END                                                       AS CHURN_TERM
    FROM feat f
    LEFT JOIN agg g ON g.CUSTOMER_ID = f.CUSTOMER_ID
                   AND g.ACTION_CODE = f.ACTION_CODE
)
SELECT
    CUSTOMER_ID,
    ACTION_CODE,
    ACTION_NAME,
    CATEGORY,
    PRODUCT_ID,
    CHANNEL,
    IS_SALES_ACTION,
    IS_SERVICING_OBLIGATION,
    PRIORITY_TIER,
    VALUE_ORIENTATION,
    REQUIRED_DISCLOSURE,
    REGULATORY_NOTE,
    PROPENSITY_FEATURES,

    /* -- the four terms, kept individually so the product is auditable ---- */
    ROUND(PROPENSITY, 4)                                          AS PROPENSITY,
    'TRANSPARENT_WEIGHTED'                                        AS PROPENSITY_SOURCE,
    ROUND(BASE_RATE, 4)                                           AS BASE_RATE,
    BASE_RATE_SOURCE,
    ROUND(LOGIT_ADJUSTMENT, 4)                                    AS LOGIT_ADJUSTMENT,
    DRIVER_FEATURES,
    VALUE_AT_STAKE_INR,
    ROUND(CHURN_RISK, 4)                                          AS CHURN_RISK,
    TREND_IS_UNKNOWN,
    CHURN_CONTRIBUTIONS,
    ROUND(CHURN_TERM, 4)                                          AS CHURN_TERM,
    TIMING_ANCHOR,
    TIMING_MULTIPLIER,

    /* Computed from the ROUNDED factors, not the raw ones, so the arithmetic is
       exactly reproducible from the four columns stored beside it. Multiplying
       the unrounded values and storing rounded factors left 85 rows where the
       product did not reconstitute -- small in rupees, but it made the
       "re-derivable" claim in this table's COMMENT false, which is worse than
       being a rupee out. Check 13.7.1f enforces it. */
    ROUND(ROUND(PROPENSITY, 4) * VALUE_AT_STAKE_INR
          * ROUND(CHURN_TERM, 4) * TIMING_MULTIPLIER, 0)          AS EXPECTED_VALUE_INR,

    /* -- the ladder: tier first, value only inside a tier ----------------- */
    ROW_NUMBER() OVER (
        PARTITION BY CUSTOMER_ID
        ORDER BY PRIORITY_TIER ASC,
                 ROUND(ROUND(PROPENSITY, 4) * VALUE_AT_STAKE_INR
                       * ROUND(CHURN_TERM, 4) * TIMING_MULTIPLIER, 0) DESC,
                 ACTION_CODE ASC
    )                                                             AS RANK_WITHIN_CUSTOMER,

    ELIGIBILITY_TRACE,
    RULES_PASSED,
    RULES_FAILED,
    RULES_EXEMPT,
    CURRENT_TIMESTAMP()                                           AS SCORED_AT
FROM scored;

COMMENT ON TABLE GOLD.NBA_SCORED IS
'Eligible (customer x action) rows with propensity, churn term, timing multiplier and EXPECTED_VALUE_INR. All four factors are stored individually so the product can be re-derived and audited rather than taken on trust, and DRIVER_FEATURES carries the per-feature log-odds contribution behind the propensity. Suppressed rows are deliberately absent: a propensity on an action that may not be taken is a number with no referent, and their VALUE_AT_STAKE_INR is already recorded in GOLD.NBA_ELIGIBLE. RANK_WITHIN_CUSTOMER orders by (PRIORITY_TIER, EXPECTED_VALUE_INR DESC) so value competes only within a tier -- product principle 3 forbids a cross-sell outranking a hardship review at any value. Zero AI-function calls.';

COMMENT ON COLUMN GOLD.NBA_SCORED.CHURN_TERM IS
'The churn factor actually applied, branched on VALUE_ORIENTATION: (1 - CHURN_RISK) for ACQUISITION, CHURN_RISK for RETENTION. The milestone formula specified (1 - churn_risk) throughout; applied literally that prices a save call DOWN for the customers most likely to leave and sorts RETENTION_SAVE_CALL below a cross-sell across the whole S1 cohort. Stored separately from CHURN_RISK so both the input and the applied factor are visible and the branch cannot be mistaken for an arithmetic error.';

COMMENT ON COLUMN GOLD.NBA_SCORED.PROPENSITY_SOURCE IS
'Which model produced PROPENSITY. Always TRANSPARENT_WEIGHTED here. The fitted SNOWFLAKE.ML.CLASSIFICATION alternative is built and evaluated in 13 part 6 and compared in GOLD.NBA_PROPENSITY_COMPARISON, but is NOT used: RAW.CAMPAIGN_HISTORY outcomes are independent of every customer feature in this dataset, so the classifier can only learn the 8.15% base rate. This column is the switch if a real campaign history ever replaces the synthetic one.';

COMMENT ON COLUMN GOLD.NBA_SCORED.TIMING_MULTIPLIER IS
'Proximity to the action own timing anchor (GOLD.NBA_TIMING_ANCHOR), bounded [0.90, 1.35] -- deliberately narrow, because a multiplier free to swing wider would start reordering actions across priority tiers, which the ladder forbids. 1.00 flat for anchor NONE, which is not "no opinion": COMPLAINT_RESOLUTION_CALLBACK is anchored on the IRDAI grievance clock and a distant renewal date must not make an open grievance look less urgent.';

COMMENT ON COLUMN GOLD.NBA_SCORED.DRIVER_FEATURES IS
'Per-feature log-odds contribution to PROPENSITY, as {feature: weight x normalised_value}. Sums to LOGIT_ADJUSTMENT. This is what makes the score explainable to an agent and challengeable by a reviewer: every number in it traces to one row of GOLD.NBA_PROPENSITY_WEIGHTS, which carries a written rationale.';


/* ============================================================================
   PART 6  —  THE FITTED ALTERNATIVE, AND ITS MEASURED VERDICT
   ----------------------------------------------------------------------------
   SNOWFLAKE.ML.CLASSIFICATION on RAW.CAMPAIGN_HISTORY outcomes.

   Serverless compute, WAREHOUSE credits, zero AI-function calls. Part 7.4
   asserts the AI credit delta across this whole file is zero.

   Read the leakage caveat in the file header before reusing this pattern.
============================================================================ */

CREATE OR REPLACE VIEW GOLD.NBA_ML_DATASET AS
SELECT
    ch.CAMPAIGN_CONTACT_ID,
    /* Deterministic 80/20 fold from the contact key, so the split survives a
       rebuild and a warehouse resize. Not RANDOM(): a fold that moves between
       runs makes the AUC unreproducible, which is the same class of problem
       docs/DATA_SEGMENTS.md section 1 solved for the generator. */
    IFF(ABS(HASH(ch.CAMPAIGN_CONTACT_ID)) % 5 = 0, 'TEST', 'TRAIN')  AS FOLD,
    IFF(ch.CONVERTED_FLAG, 'YES', 'NO')::VARCHAR          AS CONVERTED_LABEL,
    ch.CONVERTED_FLAG                                     AS CONVERTED,
    ch.PRODUCT_CODE,
    ch.CHANNEL,
    f.SEGMENT,
    f.DPD_BUCKET,
    f.SENTIMENT_TREND,
    f.RELATIONSHIP_VALUE_BAND,
    f.AGE::FLOAT                                          AS AGE,
    f.INCOME_BAND_RANK::FLOAT                             AS INCOME_BAND_RANK,
    f.TENURE_YEARS::FLOAT                                 AS TENURE_YEARS,
    f.PRODUCT_COUNT::FLOAT                                AS PRODUCT_COUNT,
    COALESCE(f.CREDIT_UTILISATION, 0)::FLOAT              AS CREDIT_UTILISATION,
    COALESCE(f.EST_ANNUAL_MARGIN_INR, 0)::FLOAT           AS EST_ANNUAL_MARGIN_INR,
    COALESCE(f.MISSED_PAYMENTS_12M, 0)::FLOAT             AS MISSED_PAYMENTS_12M,
    COALESCE(f.INTERACTIONS_90D, 0)::FLOAT                AS INTERACTIONS_90D,
    COALESCE(f.LIFE_EVENTS_365D, 0)::FLOAT                AS LIFE_EVENTS_365D,
    COALESCE(f.SERVICE_COMPLAINT_90D, 0)::FLOAT           AS SERVICE_COMPLAINT_90D,
    COALESCE(f.LIMIT_REQUEST_90D, 0)::FLOAT               AS LIMIT_REQUEST_90D,
    IFF(f.VULNERABILITY_FLAG, 1, 0)::FLOAT                AS VULNERABLE,
    IFF(f.HAS_HOME_LOAN, 1, 0)::FLOAT                     AS HAS_HOME_LOAN,
    IFF(f.HAS_CARD, 1, 0)::FLOAT                          AS HAS_CARD
FROM RAW.CAMPAIGN_HISTORY ch
JOIN GOLD.NBA_FEATURE_BASE f ON f.CUSTOMER_ID = ch.CUSTOMER_ID;

COMMENT ON VIEW GOLD.NBA_ML_DATASET IS
'Training and holdout data for GOLD.NBA_PROPENSITY_MODEL: 24,918 campaign contacts joined to customer features, with a deterministic 80/20 FOLD hashed from CAMPAIGN_CONTACT_ID so the split survives rebuilds and warehouse resizes. CARRIES A KNOWN LEAKAGE DEFECT, documented rather than hidden -- the join pairs an outcome up to 18 months old with the customer state TODAY, so features are post-outcome. Harmless here because the label has no signal to leak, indefensible on real data; the fix is point-in-time features as of CONTACTED_AT, which CURATED does not yet carry.';

/* The target is passed as a VARCHAR label. A BOOLEAN target trained without
   error but left every introspection method raising "Computation Error in
   function __SHOW_EVALUATION_METRICS". Noted because the failure is silent:
   CREATE succeeds either way, and the model looks fine until you ask it
   anything. Switching to VARCHAR did not fix the introspection either -- see
   6.3 -- but it is the correct type for a class label regardless. */
CREATE OR REPLACE SNOWFLAKE.ML.CLASSIFICATION GOLD.NBA_PROPENSITY_MODEL(
    INPUT_DATA     => SYSTEM$QUERY_REFERENCE(
        $$SELECT * EXCLUDE (CAMPAIGN_CONTACT_ID, FOLD, CONVERTED)
          FROM GOLD.NBA_ML_DATASET WHERE FOLD = 'TRAIN'$$),
    TARGET_COLNAME => 'CONVERTED_LABEL',
    CONFIG_OBJECT  => {'evaluate': TRUE, 'on_error': 'skip'}
);

/* -- 6.3  the AUC, computed here rather than asked for ---------------------
   SHOW_EVALUATION_METRICS, SHOW_GLOBAL_EVALUATION_METRICS and
   SHOW_FEATURE_IMPORTANCE all raise "Computation Error" on this account, for
   both a BOOLEAN and a VARCHAR target -- most likely the 8.15% class
   imbalance. Rather than report no number, the AUC is computed directly from
   PREDICT on the held-out fold via the Mann-Whitney identity

       AUC = (sum of ranks of positives - n_pos(n_pos+1)/2) / (n_pos * n_neg)

   which is exact rather than an approximation and needs nothing from the model
   beyond one score per row. Being forced to compute it by hand turns out to be
   a small benefit: the number now rests on a holdout this file defines, and
   anyone reading it can re-derive it.
   ------------------------------------------------------------------------ */

CREATE OR REPLACE TABLE GOLD.NBA_ML_HOLDOUT AS
SELECT
    d.CAMPAIGN_CONTACT_ID,
    d.CONVERTED,
    GOLD.NBA_PROPENSITY_MODEL!PREDICT(INPUT_DATA => OBJECT_CONSTRUCT(
        'PRODUCT_CODE', d.PRODUCT_CODE, 'CHANNEL', d.CHANNEL,
        'SEGMENT', d.SEGMENT, 'DPD_BUCKET', d.DPD_BUCKET,
        'SENTIMENT_TREND', d.SENTIMENT_TREND,
        'RELATIONSHIP_VALUE_BAND', d.RELATIONSHIP_VALUE_BAND,
        'AGE', d.AGE, 'INCOME_BAND_RANK', d.INCOME_BAND_RANK,
        'TENURE_YEARS', d.TENURE_YEARS, 'PRODUCT_COUNT', d.PRODUCT_COUNT,
        'CREDIT_UTILISATION', d.CREDIT_UTILISATION,
        'EST_ANNUAL_MARGIN_INR', d.EST_ANNUAL_MARGIN_INR,
        'MISSED_PAYMENTS_12M', d.MISSED_PAYMENTS_12M,
        'INTERACTIONS_90D', d.INTERACTIONS_90D,
        'LIFE_EVENTS_365D', d.LIFE_EVENTS_365D,
        'SERVICE_COMPLAINT_90D', d.SERVICE_COMPLAINT_90D,
        'LIMIT_REQUEST_90D', d.LIMIT_REQUEST_90D,
        'VULNERABLE', d.VULNERABLE, 'HAS_HOME_LOAN', d.HAS_HOME_LOAN,
        'HAS_CARD', d.HAS_CARD)):probability:"YES"::FLOAT   AS P_YES
FROM GOLD.NBA_ML_DATASET d
WHERE d.FOLD = 'TEST';

COMMENT ON TABLE GOLD.NBA_ML_HOLDOUT IS
'Predicted P(convert) beside the actual outcome on the held-out 20% fold, for the AUC computed in 13 part 6.3. The model never saw these rows.';

WITH r AS (
    SELECT CONVERTED, P_YES, RANK() OVER (ORDER BY P_YES) AS rk
    FROM GOLD.NBA_ML_HOLDOUT
),
agg AS (
    SELECT COUNT_IF(CONVERTED)                              AS n_pos,
           COUNT_IF(NOT CONVERTED)                          AS n_neg,
           SUM(IFF(CONVERTED, rk, 0))                       AS sum_rank_pos
    FROM r
)
SELECT 'SNOWFLAKE.ML.CLASSIFICATION, held-out AUC'          AS metric,
       n_pos + n_neg                                        AS holdout_rows,
       n_pos                                                AS conversions,
       ROUND((sum_rank_pos - n_pos * (n_pos + 1) / 2.0)
             / NULLIF(n_pos * n_neg, 0), 4)                 AS auc,
       CASE WHEN (sum_rank_pos - n_pos * (n_pos + 1) / 2.0)
                 / NULLIF(n_pos * n_neg, 0) < 0.55
            THEN 'NO USABLE SIGNAL: indistinguishable from chance (0.50). The transparent score ships.'
            ELSE 'signal present: reconsider which model ships' END AS verdict
FROM agg;

/* -- 6.4  side by side ----------------------------------------------------- */

CREATE OR REPLACE TABLE GOLD.NBA_PROPENSITY_COMPARISON AS
WITH input AS (
    SELECT
        s.CUSTOMER_ID,
        s.ACTION_CODE,
        s.PROPENSITY                                     AS PROPENSITY_TRANSPARENT,
        s.EXPECTED_VALUE_INR                             AS EV_TRANSPARENT,
        s.PRIORITY_TIER,
        s.RANK_WITHIN_CUSTOMER                           AS RANK_TRANSPARENT,
        br.MATCH_CODE                                    AS PRODUCT_CODE,
        s.CHANNEL,
        f.SEGMENT, f.DPD_BUCKET, f.SENTIMENT_TREND, f.RELATIONSHIP_VALUE_BAND,
        f.AGE, f.INCOME_BAND_RANK, f.TENURE_YEARS, f.PRODUCT_COUNT,
        COALESCE(f.CREDIT_UTILISATION, 0)                AS CREDIT_UTILISATION,
        COALESCE(f.EST_ANNUAL_MARGIN_INR, 0)             AS EST_ANNUAL_MARGIN_INR,
        COALESCE(f.MISSED_PAYMENTS_12M, 0)               AS MISSED_PAYMENTS_12M,
        COALESCE(f.INTERACTIONS_90D, 0)                  AS INTERACTIONS_90D,
        COALESCE(f.LIFE_EVENTS_365D, 0)                  AS LIFE_EVENTS_365D,
        COALESCE(f.SERVICE_COMPLAINT_90D, 0)             AS SERVICE_COMPLAINT_90D,
        COALESCE(f.LIMIT_REQUEST_90D, 0)                 AS LIMIT_REQUEST_90D,
        IFF(f.VULNERABILITY_FLAG, 1, 0)                  AS VULNERABLE,
        IFF(f.HAS_HOME_LOAN, 1, 0)                       AS HAS_HOME_LOAN,
        IFF(f.HAS_CARD, 1, 0)                            AS HAS_CARD
    FROM GOLD.NBA_SCORED s
    JOIN GOLD.NBA_ACTION_BASE_RATE br ON br.ACTION_CODE = s.ACTION_CODE
    JOIN GOLD.NBA_FEATURE_BASE     f  ON f.CUSTOMER_ID  = s.CUSTOMER_ID
    /* only the 8 campaigned product codes are in the model's PRODUCT_CODE
       domain; predicting outside it would be extrapolation dressed as a score */
    WHERE br.BASE_RATE_SOURCE = 'OBSERVED'
),
pred AS (
    SELECT i.*,
           GOLD.NBA_PROPENSITY_MODEL!PREDICT(
               INPUT_DATA => OBJECT_CONSTRUCT(
                   'PRODUCT_CODE', PRODUCT_CODE, 'CHANNEL', CHANNEL,
                   'SEGMENT', SEGMENT, 'DPD_BUCKET', DPD_BUCKET,
                   'SENTIMENT_TREND', SENTIMENT_TREND,
                   'RELATIONSHIP_VALUE_BAND', RELATIONSHIP_VALUE_BAND,
                   'AGE', AGE, 'INCOME_BAND_RANK', INCOME_BAND_RANK,
                   'TENURE_YEARS', TENURE_YEARS, 'PRODUCT_COUNT', PRODUCT_COUNT,
                   'CREDIT_UTILISATION', CREDIT_UTILISATION,
                   'EST_ANNUAL_MARGIN_INR', EST_ANNUAL_MARGIN_INR,
                   'MISSED_PAYMENTS_12M', MISSED_PAYMENTS_12M,
                   'INTERACTIONS_90D', INTERACTIONS_90D,
                   'LIFE_EVENTS_365D', LIFE_EVENTS_365D,
                   'SERVICE_COMPLAINT_90D', SERVICE_COMPLAINT_90D,
                   'LIMIT_REQUEST_90D', LIMIT_REQUEST_90D,
                   'VULNERABLE', VULNERABLE, 'HAS_HOME_LOAN', HAS_HOME_LOAN,
                   'HAS_CARD', HAS_CARD)
           )                                             AS ML_OUT
    FROM input i
)
SELECT
    CUSTOMER_ID,
    ACTION_CODE,
    PRIORITY_TIER,
    PROPENSITY_TRANSPARENT,
    ROUND(COALESCE(ML_OUT:probability:"YES"::FLOAT, 0), 4) AS PROPENSITY_ML,
    ML_OUT:class::VARCHAR                                AS ML_PREDICTED_CLASS,
    EV_TRANSPARENT,
    RANK_TRANSPARENT
FROM pred;

COMMENT ON TABLE GOLD.NBA_PROPENSITY_COMPARISON IS
'Transparent weighted propensity beside the fitted SNOWFLAKE.ML.CLASSIFICATION probability, for the eligible rows whose product falls inside the model PRODUCT_CODE domain (the 8 codes RAW.CAMPAIGN_HISTORY actually campaigned -- predicting outside it would be extrapolation dressed as a score). Built to answer the milestone request to see both. The engine uses the transparent score: see 13 part 7.5 for the measured spread and the header for why a classifier fitted on outcomes independent of every feature can only recover the base rate.';


/* ============================================================================
   PART 7  —  VERIFICATION
============================================================================ */

/* -- 7.1  structure -------------------------------------------------------- */

SELECT '13.7.1a scored rows = eligible rows'            AS check_name,
       (SELECT COUNT(*) FROM GOLD.NBA_SCORED)           AS observed,
       IFF((SELECT COUNT(*) FROM GOLD.NBA_SCORED)
         = (SELECT COUNT_IF(FINAL_VERDICT = 'ELIGIBLE') FROM GOLD.NBA_ELIGIBLE),
           'PASS', 'FAIL')                              AS verdict
UNION ALL
SELECT '13.7.1b no suppressed row was scored',
       COUNT(*), IFF(COUNT(*) = 0, 'PASS', 'FAIL')
FROM GOLD.NBA_SCORED s
JOIN GOLD.NBA_ELIGIBLE e ON e.CUSTOMER_ID = s.CUSTOMER_ID AND e.ACTION_CODE = s.ACTION_CODE
WHERE e.FINAL_VERDICT <> 'ELIGIBLE'
UNION ALL
SELECT '13.7.1c propensity in (0,1)',
       COUNT_IF(PROPENSITY <= 0 OR PROPENSITY >= 1),
       IFF(COUNT_IF(PROPENSITY <= 0 OR PROPENSITY >= 1) = 0, 'PASS', 'FAIL')
FROM GOLD.NBA_SCORED
UNION ALL
SELECT '13.7.1d expected value never negative',
       COUNT_IF(EXPECTED_VALUE_INR < 0),
       IFF(COUNT_IF(EXPECTED_VALUE_INR < 0) = 0, 'PASS', 'FAIL')
FROM GOLD.NBA_SCORED
UNION ALL
SELECT '13.7.1e churn term matches its orientation',
       COUNT_IF(ABS(CHURN_TERM - IFF(VALUE_ORIENTATION = 'RETENTION',
                                     CHURN_RISK, 1 - CHURN_RISK)) > 0.0002),
       IFF(COUNT_IF(ABS(CHURN_TERM - IFF(VALUE_ORIENTATION = 'RETENTION',
                                     CHURN_RISK, 1 - CHURN_RISK)) > 0.0002) = 0,
           'PASS', 'FAIL')
FROM GOLD.NBA_SCORED
UNION ALL
SELECT '13.7.1f expected value = the four factors multiplied',
       COUNT_IF(ABS(EXPECTED_VALUE_INR
                    - ROUND(PROPENSITY * VALUE_AT_STAKE_INR * CHURN_TERM
                            * TIMING_MULTIPLIER, 0)) > 1),
       IFF(COUNT_IF(ABS(EXPECTED_VALUE_INR
                    - ROUND(PROPENSITY * VALUE_AT_STAKE_INR * CHURN_TERM
                            * TIMING_MULTIPLIER, 0)) > 1) = 0, 'PASS', 'FAIL')
FROM GOLD.NBA_SCORED
UNION ALL
SELECT '13.7.1g timing multiplier bounded [0.90, 1.35]',
       COUNT_IF(TIMING_MULTIPLIER < 0.90 OR TIMING_MULTIPLIER > 1.35),
       IFF(COUNT_IF(TIMING_MULTIPLIER < 0.90 OR TIMING_MULTIPLIER > 1.35) = 0,
           'PASS', 'FAIL')
FROM GOLD.NBA_SCORED
UNION ALL
SELECT '13.7.1h rank is dense from 1 per customer',
       COUNT(*), IFF(COUNT(*) = 0, 'PASS', 'FAIL')
FROM (SELECT CUSTOMER_ID FROM GOLD.NBA_SCORED
      GROUP BY 1 HAVING MIN(RANK_WITHIN_CUSTOMER) <> 1
                     OR MAX(RANK_WITHIN_CUSTOMER) <> COUNT(*))
ORDER BY check_name;


/* -- 7.2  THE LADDER: no cross-sell may outrank a service action ---------- */

SELECT '13.7.2a no sale ranked above a lower-tier action'   AS check_name,
       COUNT(*)                                             AS observed,
       IFF(COUNT(*) = 0, 'PASS', 'FAIL')                    AS verdict
FROM GOLD.NBA_SCORED a
JOIN GOLD.NBA_SCORED b ON b.CUSTOMER_ID = a.CUSTOMER_ID
WHERE a.RANK_WITHIN_CUSTOMER < b.RANK_WITHIN_CUSTOMER
  AND a.PRIORITY_TIER > b.PRIORITY_TIER
UNION ALL
/* The specific failure the ladder exists to prevent. */
SELECT '13.7.2b every hardship-eligible customer ranks hardship first',
       COUNT(*), IFF(COUNT(*) = 0, 'PASS', 'FAIL')
FROM GOLD.NBA_SCORED
WHERE ACTION_CODE = 'COLLECTIONS_HARDSHIP_OUTREACH' AND RANK_WITHIN_CUSTOMER <> 1
UNION ALL
SELECT '13.7.2c no cross-sell ranks 1 where a retention action is eligible',
       COUNT(*), IFF(COUNT(*) = 0, 'PASS', 'FAIL')
FROM GOLD.NBA_SCORED x
WHERE x.RANK_WITHIN_CUSTOMER = 1 AND x.CATEGORY IN ('CROSS_SELL', 'UPSELL', 'WEALTH')
  AND EXISTS (SELECT 1 FROM GOLD.NBA_SCORED y
              WHERE y.CUSTOMER_ID = x.CUSTOMER_ID
                AND y.CATEGORY IN ('RETENTION', 'SERVICE_RECOVERY', 'COLLECTIONS'))
ORDER BY check_name;


/* -- 7.3  WHAT THE ORIENTATION BRANCH IS WORTH ----------------------------
   The counterfactual: what RETENTION_SAVE_CALL would have scored under the
   literal formula, and how often a cross-sell would have outranked it on
   expected value alone had the priority ladder not also been there.
   ------------------------------------------------------------------------ */

WITH s AS (
    SELECT CUSTOMER_ID, ACTION_CODE, CATEGORY, CHURN_RISK, PROPENSITY,
           VALUE_AT_STAKE_INR, TIMING_MULTIPLIER, EXPECTED_VALUE_INR,
           /* the literal formula, applied to a retention action */
           ROUND(PROPENSITY * VALUE_AT_STAKE_INR * (1 - CHURN_RISK)
                 * TIMING_MULTIPLIER, 0)                  AS EV_IF_LITERAL
    FROM GOLD.NBA_SCORED
    WHERE VALUE_ORIENTATION = 'RETENTION'
)
SELECT 'RETENTION actions, orientation branch vs literal formula' AS comparison,
       COUNT(*)                                                   AS rows_affected,
       ROUND(AVG(CHURN_RISK), 3)                                  AS mean_churn_risk,
       TO_VARCHAR(ROUND(AVG(EXPECTED_VALUE_INR)), '999,999,999')  AS mean_ev_branched,
       TO_VARCHAR(ROUND(AVG(EV_IF_LITERAL)), '999,999,999')       AS mean_ev_literal,
       ROUND(AVG(EXPECTED_VALUE_INR) / NULLIF(AVG(EV_IF_LITERAL), 0), 2) AS ratio
FROM s
UNION ALL
SELECT 'of which RETENTION_SAVE_CALL only (planted S1)',
       COUNT(*), ROUND(AVG(CHURN_RISK), 3),
       TO_VARCHAR(ROUND(AVG(EXPECTED_VALUE_INR)), '999,999,999'),
       TO_VARCHAR(ROUND(AVG(EV_IF_LITERAL)), '999,999,999'),
       ROUND(AVG(EXPECTED_VALUE_INR) / NULLIF(AVG(EV_IF_LITERAL), 0), 2)
FROM s WHERE ACTION_CODE = 'RETENTION_SAVE_CALL';

/* THE TEST THAT ACTUALLY DEMONSTRATES THE BRANCH.
   Magnitude above is the wrong measure -- it goes DOWN, and that is fine. The
   claim is about ordering: expected value must rise with churn risk for a
   retention action, because churn risk IS the value at stake. Positive
   correlation under the branch, none under the literal formula. */
WITH s AS (
    SELECT CHURN_RISK, EXPECTED_VALUE_INR AS EV_BRANCHED,
           ROUND(ROUND(PROPENSITY, 4) * VALUE_AT_STAKE_INR
                 * ROUND(1 - CHURN_RISK, 4) * TIMING_MULTIPLIER, 0) AS EV_LITERAL,
           ACTION_CODE
    FROM GOLD.NBA_SCORED
    WHERE VALUE_ORIENTATION = 'RETENTION'
)
SELECT 'RETENTION_SAVE_CALL (planted S1)'                    AS cohort,
       COUNT(*)                                              AS n,
       ROUND(CORR(EV_BRANCHED, CHURN_RISK), 4)               AS corr_ev_churn_branched,
       ROUND(CORR(EV_LITERAL,  CHURN_RISK), 4)               AS corr_ev_churn_literal,
       IFF(CORR(EV_BRANCHED, CHURN_RISK)
           > CORR(EV_LITERAL, CHURN_RISK) + 0.25, 'PASS', 'FAIL') AS verdict
FROM s WHERE ACTION_CODE = 'RETENTION_SAVE_CALL'
UNION ALL
SELECT 'all RETENTION-oriented actions', COUNT(*),
       ROUND(CORR(EV_BRANCHED, CHURN_RISK), 4),
       ROUND(CORR(EV_LITERAL,  CHURN_RISK), 4),
       IFF(CORR(EV_BRANCHED, CHURN_RISK)
           > CORR(EV_LITERAL, CHURN_RISK) + 0.25, 'PASS', 'FAIL')
FROM s;

/* And the cost of the branch, stated plainly: on the S1 cohort, how often does
   a sale beat the save call on raw expected value? MORE often under the branch,
   because the branch lowers retention value. This is what the PRIORITY_TIER
   ladder is load-bearing for. */
WITH save AS (
    SELECT CUSTOMER_ID, EXPECTED_VALUE_INR AS EV_BRANCHED,
           ROUND(PROPENSITY * VALUE_AT_STAKE_INR * (1 - CHURN_RISK)
                 * TIMING_MULTIPLIER, 0) AS EV_LITERAL
    FROM GOLD.NBA_SCORED WHERE ACTION_CODE = 'RETENTION_SAVE_CALL'
),
best_sale AS (
    SELECT CUSTOMER_ID, MAX(EXPECTED_VALUE_INR) AS EV_BEST_SALE
    FROM GOLD.NBA_SCORED
    WHERE CATEGORY IN ('CROSS_SELL', 'UPSELL', 'WEALTH')
    GROUP BY 1
)
SELECT 'S1 customers where a sale beats the save call on EV alone' AS scenario,
       COUNT(*)                                                    AS s1_with_both,
       COUNT_IF(bs.EV_BEST_SALE > sv.EV_BRANCHED)                  AS beaten_with_branch,
       COUNT_IF(bs.EV_BEST_SALE > sv.EV_LITERAL)                    AS beaten_under_literal,
       'the priority ladder blocks both cases; this measures how much work the '
         || 'branch saves the ladder'                               AS note
FROM save sv JOIN best_sale bs ON bs.CUSTOMER_ID = sv.CUSTOMER_ID;


/* -- 7.4  ZERO AI CREDITS, ASSERTED --------------------------------------- */

SELECT '13.7.4 no AI function was called by this file'  AS check_name,
       COUNT(*)                                         AS ai_calls_since_start,
       IFF(COUNT(*) = 0, 'PASS', 'FAIL')                AS verdict
FROM TABLE(INFORMATION_SCHEMA.QUERY_HISTORY_BY_SESSION(RESULT_LIMIT => 1000))
WHERE (QUERY_TEXT ILIKE '%AI_COMPLETE(%' OR QUERY_TEXT ILIKE '%AI_CLASSIFY(%'
    OR QUERY_TEXT ILIKE '%AI_EXTRACT(%'  OR QUERY_TEXT ILIKE '%AI_SENTIMENT(%'
    OR QUERY_TEXT ILIKE '%AI_FILTER(%'   OR QUERY_TEXT ILIKE '%AI_EMBED(%'
    OR QUERY_TEXT ILIKE '%AI_TRANSCRIBE(%' OR QUERY_TEXT ILIKE '%SNOWFLAKE.CORTEX.%')
  AND QUERY_TEXT NOT ILIKE '%13.7.4%'
  AND START_TIME >= (SELECT AT_TS FROM GOLD.NBA_CREDIT_CHECKPOINT
                     WHERE CHECKPOINT = '13_start');

/* String literals are stripped before matching. GET_DDL returns the COMMENT
   text, and these objects' comments DOCUMENT the D6 constraint by naming the
   forbidden column -- so a naive substring check fails on its own
   documentation, exactly as 11.4.2h did before the same fix. Stripping quoted
   literals leaves only executable SQL, which makes the check stricter rather
   than looser: it now matches a real column reference anywhere in the body, not
   just after FROM or JOIN. */
SELECT '13.7.5 no scoring object reads SENTIMENT_SLOPE_PER_30D' AS check_name,
       COUNT_IF(UPPER(code) LIKE '%SENTIMENT_SLOPE%')           AS observed,
       IFF(COUNT_IF(UPPER(code) LIKE '%SENTIMENT_SLOPE%') = 0, 'PASS', 'FAIL') AS verdict
FROM (
    SELECT REGEXP_REPLACE(ddl, '''([^'']|'''''')*''', '') AS code
    FROM (SELECT GET_DDL('TABLE', 'GOLD.NBA_CHURN_RISK')   AS ddl
          UNION ALL SELECT GET_DDL('TABLE', 'GOLD.NBA_SCORED')
          UNION ALL SELECT GET_DDL('VIEW',  'GOLD.NBA_ML_DATASET')
          UNION ALL SELECT GET_DDL('TABLE', 'GOLD.NBA_PROPENSITY_WEIGHTS'))
);


/* -- 7.6  the two models, side by side ------------------------------------ */

SELECT 'TRANSPARENT_WEIGHTED'                            AS model,
       COUNT(*)                                          AS rows_scored,
       ROUND(MIN(PROPENSITY_TRANSPARENT), 4)             AS p_min,
       ROUND(AVG(PROPENSITY_TRANSPARENT), 4)             AS p_mean,
       ROUND(MAX(PROPENSITY_TRANSPARENT), 4)             AS p_max,
       ROUND(STDDEV(PROPENSITY_TRANSPARENT), 4)          AS p_stddev,
       ROUND(MAX(PROPENSITY_TRANSPARENT)
             - MIN(PROPENSITY_TRANSPARENT), 4)           AS p_spread
FROM GOLD.NBA_PROPENSITY_COMPARISON
UNION ALL
SELECT 'SNOWFLAKE.ML.CLASSIFICATION',
       COUNT(*), ROUND(MIN(PROPENSITY_ML), 4), ROUND(AVG(PROPENSITY_ML), 4),
       ROUND(MAX(PROPENSITY_ML), 4), ROUND(STDDEV(PROPENSITY_ML), 4),
       ROUND(MAX(PROPENSITY_ML) - MIN(PROPENSITY_ML), 4)
FROM GOLD.NBA_PROPENSITY_COMPARISON;

/* Do they agree on ORDERING, which is all a ranking engine needs? */
SELECT 'rank correlation between the two propensity models' AS metric,
       COUNT(*)                                              AS n,
       ROUND(CORR(PROPENSITY_TRANSPARENT, PROPENSITY_ML), 4)  AS pearson_r
FROM GOLD.NBA_PROPENSITY_COMPARISON;


SELECT 'GOLD.NBA_SCORED built'                          AS status,
       COUNT(*)                                         AS scored_rows,
       COUNT(DISTINCT CUSTOMER_ID)                      AS customers,
       COUNT_IF(RANK_WITHIN_CUSTOMER <= 3)              AS top3_rows,
       TO_VARCHAR(ROUND(SUM(EXPECTED_VALUE_INR)), '999,999,999,999') AS total_ev_inr
FROM GOLD.NBA_SCORED;

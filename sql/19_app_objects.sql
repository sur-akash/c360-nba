/* ============================================================================
   19_app_objects.sql  —  the objects the Streamlit app reads and writes
   ----------------------------------------------------------------------------
   M10 step 1 of 2. This file creates everything the application needs that is
   not already in GOLD, and nothing that renders. sql/20_streamlit.sql creates
   the STREAMLIT object itself, and cannot run until app/ has been copied to the
   stage created here -- that is the one non-SQL seam in the rebuild (D2).

   The app is a thin renderer over the nine objects below. That is deliberate
   and it is the main design decision in this file: every query the app runs is
   a named view in APP, reviewable with GET_DDL and testable from a worksheet,
   rather than a string literal inside a Python file. A judge can read the SQL
   without reading the app, and a broken screen can be diagnosed with a SELECT.

   ----------------------------------------------------------------------------
   WHAT IS CREATED, AND WHY EACH ONE EARNS ITS PLACE
   ----------------------------------------------------------------------------
     APP.APP_STAGE               Streamlit source. Should have come from the
                                 never-written 01_schemas.sql; created here
                                 instead, IF NOT EXISTS.

     APP.ACTION_FEEDBACK         The only table in this project a user writes
                                 to. CREATE TABLE IF NOT EXISTS, never OR
                                 REPLACE -- see PART 2.

     APP.V_RM_BOOK               Relationship-manager assignment. DERIVED, not
                                 seeded. See PART 3 before believing this
                                 column.

     APP.V_WORKLIST              Screen 1 worklist + screen 2 action cards. One
                                 row per published recommendation, joined to
                                 the customer, the catalogue and the audit view.

     APP.V_PORTFOLIO_KPI         Screen 1 KPI row. Exactly one row. Every
                                 headline number the app shows is computed here
                                 rather than in Python, so the app cannot drift
                                 from the warehouse.

     APP.V_SUPPRESSION_SUMMARY   Screen 1 "suppressed and why", screen 4 base.
                                 Suppression by governing rule.

     APP.V_CUSTOMER_SUPPRESSED   Screen 2 "Suppressed" expander. The blocked
                                 actions for one customer and the rule that
                                 blocked each.

     APP.V_TIMELINE_DETAIL       Screen 2 centre column. GOLD.CUSTOMER_TIMELINE
                                 with the interaction body and its extracted
                                 signals attached, so an INTERACTION row can
                                 expand into the transcript that produced it.

     APP.V_SENTIMENT_SERIES      Screen 2 sparkline. Per-interaction sentiment
                                 readings. Deliberately NOT a trend statistic
                                 -- see PART 8.

     APP.V_IMPACT_BASE           Screen 4 simulator. The contact-everyone
                                 baseline beside the targeted book, at
                                 (channel x outcome) grain.

   ----------------------------------------------------------------------------
   COST: ZERO CREDITS
   ----------------------------------------------------------------------------
   Nine views, one table, one stage. No AI function is called by this file, and
   none is called by the app except on the ASK screen, where each question the
   user asks invokes APP.RM_COPILOT. Enumerated for the M10 running total per
   AGENTS.md: the only AI spend in this milestone is agent invocations at demo
   time, which are user-initiated and bounded by the agent's own 32,000-token
   budget, plus 0.067 credits per Cortex Analyst message. Building and
   deploying the app spends nothing.

   Re-running this file is free and idempotent. The one object that carries
   state, APP.ACTION_FEEDBACK, survives a re-run by construction.
   ============================================================================ */

USE ROLE COCO_BUILDER;
USE WAREHOUSE COCO_WH;
USE DATABASE C360_NBA;
USE SCHEMA APP;


/* ============================================================================
   PART 1 — THE STAGE
   ----------------------------------------------------------------------------
   PROJECT_BRIEF M0 assigned this to sql/01_schemas.sql, which was never
   written -- the schemas arrived via 02 and its successors instead. The stage
   is therefore created here, at its first point of use, rather than leaving a
   dangling reference to a file that does not exist.

   Server-side encryption because CREATE STREAMLIT reads the source from the
   stage; unlike RAW.AUDIO_STAGE this is not a TO_FILE requirement, it is just
   the default worth stating.
   ============================================================================ */

CREATE STAGE IF NOT EXISTS APP.APP_STAGE
  ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE')
  DIRECTORY  = (ENABLE = TRUE)
  COMMENT    = 'Streamlit in Snowflake source for APP.C360_APP. Populated by "snow stage copy app/" before sql/20_streamlit.sql runs -- the single documented non-SQL step in the rebuild (PROJECT_BRIEF D2).';


/* ============================================================================
   PART 2 — ACTION_FEEDBACK, AND WHY IT IS THE ONE TABLE NOT REBUILT
   ----------------------------------------------------------------------------
   Every other object in this project is CREATE OR REPLACE, because every other
   object is derived -- drop it and it can be recomputed from RAW. This one
   cannot. It holds an RM's decision to accept or reject a recommendation, which
   exists nowhere else and cannot be regenerated. CREATE OR REPLACE here would
   silently destroy the accept/reject history on the next rebuild, and it would
   do so quietly, which is the worst version of that bug.

   So: CREATE TABLE IF NOT EXISTS. This is the same reasoning that makes
   RAW.INTERACTION_GEN_RAW and GOLD.NBA_REASONING_RAW incremental (D5,
   AGENTS.md) -- paid or unrecoverable output lands once and is never
   regenerated -- applied to output that is unrecoverable rather than paid.

   The grain is one row per decision, not one row per action: a rejected
   recommendation that is later accepted leaves both rows, and the app reads
   the latest by DECIDED_AT. An append-only decision log answers "what did the
   RM think of this in March" and a mutable one does not.

   DECIDED_BY is CURRENT_USER(), not an app-supplied string, so the actor
   cannot be forged from the client. In Streamlit in Snowflake this resolves to
   the logged-in Snowsight user, not the app owner.
   ============================================================================ */

CREATE TABLE IF NOT EXISTS APP.ACTION_FEEDBACK (
  FEEDBACK_ID    NUMBER      IDENTITY START 1 INCREMENT 1,
  CUSTOMER_ID    NUMBER      NOT NULL,
  ACTION_CODE    VARCHAR     NOT NULL,
  ACTION_RANK    NUMBER,
  DECISION       VARCHAR     NOT NULL,
  REJECT_REASON  VARCHAR,
  NOTE           VARCHAR,
  EXPECTED_VALUE_INR FLOAT,
  DECIDED_BY     VARCHAR     NOT NULL,
  DECIDED_AT     TIMESTAMP_LTZ NOT NULL,
  CONSTRAINT CHK_DECISION CHECK (DECISION IN ('ACCEPTED','REJECTED'))
)
COMMENT = 'Append-only decision log: one row per accept/reject an RM records against a published recommendation. The only user-written table in the project, and the only one created IF NOT EXISTS rather than CREATE OR REPLACE -- a decision cannot be recomputed from RAW, so rebuilding it would destroy it. Latest decision per (customer, action) is the one with the greatest DECIDED_AT; earlier rows are kept so a change of mind is visible rather than overwritten. DECIDED_BY is CURRENT_USER() captured server-side and is not client-supplied.';

/* REJECT_REASON is constrained by the app to a fixed list rather than by a
   CHECK constraint, because the list is presentation and will change more often
   than the table. The app's list is: NOT_RELEVANT, ALREADY_CONTACTED,
   CUSTOMER_DECLINED, WRONG_TIMING, WRONG_CHANNEL, DATA_LOOKS_WRONG, OTHER. */


/* ============================================================================
   PART 3 — V_RM_BOOK: A DERIVED COLUMN, LABELLED AS ONE
   ----------------------------------------------------------------------------
   READ THIS BEFORE USING RM_NAME FOR ANYTHING.

   There is no relationship manager in this data model. Not in RAW.CUSTOMER,
   not in GOLD.CUSTOMER_360, not anywhere -- the seed in sql/03 never generated
   one. PROJECT_BRIEF section 1 lists the relationship manager as a user of the
   system and M10 scoped an "RM book" view, but the attribute that would make a
   book was never created.

   The M10 requirement is a worklist filterable by RM. Two honest options
   existed: drop the filter, or derive the attribute and say so. Derived, and
   said so.

   THE DERIVATION: RM_NAME is a pure function of CITY. One RM owns one city's
   customers, which is how a retail book is actually organised, and it makes the
   filter interact with the data the way a real one would -- books differ in
   size, in value mix and in arrears concentration, because cities do.

   WHAT THIS IS NOT. It is not a seeded silo, it carries no independent
   information, and it must not be read as a signal. Filtering the worklist by
   RM is filtering by city under another name. Nothing in GOLD or CURATED
   references this view, no propensity term reads it, and no eligibility
   predicate reads it -- it exists at the APP layer, downstream of every
   decision the engine makes, purely so a screen can group by it.

   The roster is indexed by DENSE_RANK over CITY rather than by a hard-coded
   city -> name map, so the view survives a reseed that changes the city list
   without silently mis-assigning anybody. Twenty cities, twenty names.
   ============================================================================ */

CREATE OR REPLACE VIEW APP.V_RM_BOOK
  COMMENT = 'DERIVED demo attribute -- not a seeded silo. No relationship manager exists anywhere in RAW or GOLD; this view manufactures one so the M10 worklist can be filtered by RM. RM_NAME is a pure function of CITY (one RM owns one city book), so filtering by RM is filtering by city under another name and RM_NAME carries no information of its own. Read by the app only. Nothing in CURATED or GOLD references it, and it is not an input to any propensity, eligibility or ranking expression.'
AS
WITH roster AS (
  SELECT ARRAY_CONSTRUCT(
    'Aarti Bhandari',      'Rohit Deshpande',   'Kavita Iyer',        'Nikhil Ranganathan',
    'Sneha Kulkarni',      'Vikram Nair',       'Priya Venkatesan',   'Aditya Chaturvedi',
    'Meera Subramanian',   'Sanjay Bhatt',      'Divya Pillai',       'Harish Mukherjee',
    'Ritu Chandra',        'Ganesh Sundaram',   'Lakshmi Narayanan',  'Pankaj Trivedi',
    'Shalini Gokhale',     'Tarun Bajaj',       'Neha Saxena',        'Yogesh Patil'
  ) AS names
),
city_rank AS (
  SELECT CITY,
         DENSE_RANK() OVER (ORDER BY CITY) - 1 AS city_ix
  FROM   GOLD.CUSTOMER_360
  GROUP  BY CITY
)
SELECT c.CUSTOMER_ID,
       c.CITY,
       /* MOD keeps the view correct if a reseed ever produces more cities than
          the roster has names, rather than emitting NULL for the overflow. */
       r.names[MOD(cr.city_ix, ARRAY_SIZE(r.names))]::VARCHAR AS RM_NAME
FROM   GOLD.CUSTOMER_360 c
JOIN   city_rank        cr ON cr.CITY = c.CITY
CROSS JOIN roster       r;


/* ============================================================================
   PART 4 — V_WORKLIST: the published book, one row per recommendation
   ----------------------------------------------------------------------------
   Feeds the screen 1 ranked worklist and the screen 2 action cards. Both need
   the same twelve-column NBA contract plus the customer state an RM reads
   before dialling, so they share one view rather than two that drift.

   CATEGORY comes from GOLD.ACTION_CATALOG because GOLD.NEXT_BEST_ACTION does
   not carry it -- the twelve-column contract has no room for it and the
   catalogue is its authoritative home.

   The provenance columns from GOLD.V_NEXT_BEST_ACTION_AUDIT are carried
   deliberately. RATIONALE_SOURCE tells the reader whether the sentence they
   are about to read to a customer was written by claude-opus-5 or assembled
   from a template, and RANK_MOVED tells them the care boundary reordered this
   row away from where expected value alone would have put it. Both are facts
   about the recommendation and the app shows them.
   ============================================================================ */

CREATE OR REPLACE VIEW APP.V_WORKLIST
  COMMENT = 'One row per published recommendation (3,917), joined to customer state, action category and generation provenance. The single source for both the screen 1 portfolio worklist and the screen 2 action cards, so the two cannot disagree. EXPECTED_VALUE_INR, PROPENSITY, CHANNEL and DISCLOSURE are carried unmodified from GOLD.NEXT_BEST_ACTION -- no arithmetic happens here. RM_NAME is derived; see APP.V_RM_BOOK.'
AS
SELECT
  n.CUSTOMER_ID,
  c.CUSTOMER_NAME,
  c.CITY,
  rm.RM_NAME,
  c.SEGMENT,
  c.RELATIONSHIP_VALUE_BAND,
  n.RANK                          AS ACTION_RANK,
  n.ACTION_CODE,
  n.ACTION_NAME,
  cat.CATEGORY,
  n.CHANNEL,
  n.PROPENSITY,
  n.EXPECTED_VALUE_INR,
  n.RATIONALE,
  n.DISCLOSURE,
  n.EVIDENCE_IDS,
  n.ELIGIBILITY_TRACE,
  ARRAY_SIZE(n.EVIDENCE_IDS)      AS EVIDENCE_COUNT,
  a.RATIONALE_SOURCE,
  a.PRIORITY_TIER,
  a.IS_SALES_ACTION,
  a.RANK_MOVED,
  a.SOURCE_RANK,
  cat.IS_SERVICING_OBLIGATION,
  cat.REGULATORY_NOTE,
  /* Customer state an RM reads before making the call. */
  c.DPD_BUCKET,
  c.VULNERABILITY_FLAG,
  c.OPEN_COMPLAINT,
  c.SENTIMENT_NOW,
  c.SENTIMENT_TREND,
  c.DAYS_TO_RENEWAL,
  c.OUTSTANDING_CREDIT_INR,
  c.EST_ANNUAL_MARGIN_INR,
  c.PREFERRED_CHANNEL,
  c.CONSENT_CALL,
  c.CONSENT_EMAIL,
  c.CONSENT_SMS,
  n.GENERATED_AT
FROM       GOLD.NEXT_BEST_ACTION          n
JOIN       GOLD.CUSTOMER_360              c   ON c.CUSTOMER_ID = n.CUSTOMER_ID
JOIN       GOLD.ACTION_CATALOG            cat ON cat.ACTION_CODE = n.ACTION_CODE
LEFT JOIN  GOLD.V_NEXT_BEST_ACTION_AUDIT  a   ON a.CUSTOMER_ID = n.CUSTOMER_ID
                                             AND a.RANK        = n.RANK
LEFT JOIN  APP.V_RM_BOOK                  rm  ON rm.CUSTOMER_ID = n.CUSTOMER_ID;


/* ============================================================================
   PART 5 — V_PORTFOLIO_KPI: exactly one row
   ----------------------------------------------------------------------------
   The screen 1 KPI strip. Every headline number is computed here so that the
   app renders figures rather than deriving them -- a KPI that disagrees with
   the warehouse is a bug the app layer should not be able to introduce.

   Two definitions are worth stating because the app displays them as bare
   numbers and a bare number invites the wrong reading:

   TOTAL_EXPECTED_VALUE_INR is the expected value of the CURRENT PUBLISHED SET,
   which is what "this week's actions" means in a system whose NBAs are
   published in one batch (see GENERATED_AT -- there is a single generation, not
   a weekly cadence). The app labels it as the published book, not as a weekly
   flow, because calling a one-off batch "this week" would be an invention.

   RENEWALS_AT_RISK_30D reuses GOLD.V_SV_POLICY.IS_AT_RISK_30D rather than
   composing a fresh predicate. The project already decided what at-risk means
   -- renewing inside 30 days with a complaint in the last 60 -- and a second
   definition in the app layer would be a second answer to the same question.

   ARREARS_EXPOSURE_INR reads GOLD.V_SV_LOAN, for the same reason and it was not
   the first attempt. The obvious source is CUSTOMER_360.OUTSTANDING_CREDIT_INR
   summed over customers whose DPD bucket is past due, which gives Rs 65.78
   crore. That is a defensible number and it is the wrong one to put on this
   screen, because it is the customer's TOTAL credit -- cards included -- and a
   card that is being paid on time is not arrears. 1,275 customers carry a
   balance with no loan obligation at all.

   The figure that matters is the one the ASK screen will quote when somebody
   asks the copilot the same question. APP.RM_COPILOT routes that to Cortex
   Analyst over GOLD.SV_CUSTOMER_360, whose arrears_exposure_inr metric reads
   V_SV_LOAN.ARREARS_OUTSTANDING_INR and returns Rs 52.14 crore. A cockpit KPI
   that contradicts the copilot on the same question, in the same app, is worse
   than either number alone. So this view reads the same column the semantic
   view does, and the two agree by construction rather than by coincidence.

   The suppression figures are restricted to ELIGIBLE_ON_NEED, and this was also
   a correction rather than the first attempt. Unrestricted, the KPI tile read
   57,038 suppressed actions while APP.V_SUPPRESSION_SUMMARY -- rendered as a
   table six inches below it on the same screen -- read 12,435, because the
   summary had always used the need-eligible denominator and the KPI had not.
   Both numbers were defensible and showing both unlabelled on one screen was
   not: a reader cannot be expected to infer that two suppression counts differ
   by denominator. 12,435 is the honest one, for the reason recorded in PART 6 --
   a (customer x action) pair the customer had no need for was never a candidate
   and was not suppressed by compliance.
   ============================================================================ */

CREATE OR REPLACE VIEW APP.V_PORTFOLIO_KPI
  COMMENT = 'Exactly one row: the screen 1 KPI strip, computed in SQL so the app cannot drift from the warehouse. TOTAL_EXPECTED_VALUE_INR is the expected value of the current published NBA set, which is one batch and not a weekly flow. RENEWALS_AT_RISK_30D reuses GOLD.V_SV_POLICY.IS_AT_RISK_30D and ARREARS_EXPOSURE_INR reuses GOLD.V_SV_LOAN.ARREARS_OUTSTANDING_INR -- both so the cockpit quotes the same figure the ASK screen gets back from Cortex Analyst, rather than a second definition of the same word.'
AS
WITH cust AS (
  SELECT COUNT(*)                     AS customers_total,
         COUNT_IF(VULNERABILITY_FLAG) AS customers_vulnerable
  FROM   GOLD.CUSTOMER_360
),
/* Arrears read from the loan book, not from the customer's total credit. See
   the header: the two differ by Rs 13.6 crore of card balances belonging to
   customers with no loan obligation, and only this one agrees with the
   semantic view the copilot queries. */
arrears AS (
  SELECT COUNT(DISTINCT IFF(IS_IN_ARREARS, CUSTOMER_ID, NULL)) AS customers_in_arrears,
         SUM(ARREARS_OUTSTANDING_INR)                          AS arrears_exposure_inr
  FROM   GOLD.V_SV_LOAN
),
nba AS (
  SELECT COUNT(*)                        AS actions_published,
         COUNT(DISTINCT CUSTOMER_ID)     AS customers_with_action,
         SUM(EXPECTED_VALUE_INR)         AS total_expected_value_inr
  FROM   GOLD.NEXT_BEST_ACTION
),
sup AS (
  SELECT COUNT(*)                                       AS actions_suppressed,
         COUNT(DISTINCT SUPPRESSION_REASON)             AS suppression_rules_fired,
         COUNT(DISTINCT CUSTOMER_ID)                    AS customers_touched_by_suppression,
         SUM(VALUE_AT_STAKE_INR)                        AS suppressed_value_at_stake_inr,
         SUM(VALUE_AT_STAKE_INR * MARGIN_RATE)          AS suppressed_gross_margin_inr
  FROM   GOLD.NBA_ELIGIBLE
  WHERE  SUPPRESSED
    AND  ELIGIBLE_ON_NEED
),
top_rule AS (
  SELECT SUPPRESSION_REASON AS top_suppression_reason,
         COUNT(*)           AS top_suppression_count
  FROM   GOLD.NBA_ELIGIBLE
  WHERE  SUPPRESSED
    AND  ELIGIBLE_ON_NEED
  GROUP  BY SUPPRESSION_REASON
  ORDER  BY COUNT(*) DESC
  LIMIT  1
),
/* Customers the engine evaluated, found a need for, and could not contact at
   all. This is the number a compliance reviewer cares about and it is not the
   same as "customers with a suppressed action" -- most of those still received
   a different recommendation. */
fully_blocked AS (
  SELECT COUNT(*) AS customers_fully_suppressed
  FROM (
    SELECT e.CUSTOMER_ID
    FROM   GOLD.NBA_ELIGIBLE e
    WHERE  e.SUPPRESSED
      AND  e.ELIGIBLE_ON_NEED
    GROUP  BY e.CUSTOMER_ID
    HAVING COUNT_IF(e.FINAL_VERDICT = 'ELIGIBLE') = 0
       AND NOT EXISTS (SELECT 1 FROM GOLD.NEXT_BEST_ACTION n
                       WHERE n.CUSTOMER_ID = e.CUSTOMER_ID)
  )
),
renewal AS (
  SELECT COUNT(DISTINCT CUSTOMER_ID)      AS renewals_at_risk_30d,
         COUNT(*)                         AS policies_at_risk_30d,
         SUM(ANNUALISED_PREMIUM_INR)      AS premium_at_risk_inr
  FROM   GOLD.V_SV_POLICY
  WHERE  IS_AT_RISK_30D
),
feedback AS (
  SELECT COUNT(*)                                 AS decisions_recorded,
         COALESCE(COUNT_IF(DECISION='ACCEPTED'),0) AS decisions_accepted
  FROM   APP.ACTION_FEEDBACK
)
SELECT
  cust.customers_total,
  nba.customers_with_action,
  nba.actions_published,
  nba.total_expected_value_inr,
  sup.actions_suppressed,
  sup.suppression_rules_fired,
  sup.customers_touched_by_suppression,
  fully_blocked.customers_fully_suppressed,
  sup.suppressed_value_at_stake_inr,
  sup.suppressed_gross_margin_inr,
  top_rule.top_suppression_reason,
  top_rule.top_suppression_count,
  renewal.renewals_at_risk_30d,
  renewal.policies_at_risk_30d,
  renewal.premium_at_risk_inr,
  arrears.customers_in_arrears,
  arrears.arrears_exposure_inr,
  cust.customers_vulnerable,
  feedback.decisions_recorded,
  feedback.decisions_accepted,
  (SELECT MAX(GENERATED_AT) FROM GOLD.NEXT_BEST_ACTION) AS published_at,
  (SELECT MAX(AS_OF_DATE)   FROM GOLD.CUSTOMER_360)     AS as_of_date
FROM cust, arrears, nba, sup, top_rule, fully_blocked, renewal, feedback;


/* ============================================================================
   PART 6 — V_SUPPRESSION_SUMMARY: what compliance blocked, by rule
   ----------------------------------------------------------------------------
   Screen 1's "actions suppressed and why", and the base for screen 4's
   quantification of the guardrail layer.

   Only rows that passed the need test are counted. A (customer x action) pair
   the customer had no need for was not suppressed by compliance, it was never a
   candidate, and counting the 90,000-row cross join as "blocked" would inflate
   the compliance story by an order of magnitude. GOLD.NBA_ELIGIBLE keeps all
   90,000 rows on purpose; this view is where the honest denominator is chosen.
   ============================================================================ */

CREATE OR REPLACE VIEW APP.V_SUPPRESSION_SUMMARY
  COMMENT = 'Suppression by governing rule, restricted to (customer x action) pairs that passed the need test -- a pair with no need was never a candidate and counting it as blocked would overstate the compliance layer. VALUE_AT_STAKE_INR is the exposure the rule prevented being solicited; GROSS_MARGIN_INR applies the product margin rate and is the figure screen 4 treats as forgone revenue at 100% acceptance.'
AS
SELECT
  SUPPRESSION_REASON,
  COUNT(*)                                  AS ACTIONS_SUPPRESSED,
  COUNT(DISTINCT CUSTOMER_ID)               AS CUSTOMERS_AFFECTED,
  COUNT(DISTINCT ACTION_CODE)               AS ACTIONS_DISTINCT,
  SUM(VALUE_AT_STAKE_INR)                   AS VALUE_AT_STAKE_INR,
  SUM(VALUE_AT_STAKE_INR * MARGIN_RATE)     AS GROSS_MARGIN_INR,
  COUNT_IF(CHANNEL = 'CALL')                AS VIA_CALL,
  COUNT_IF(CHANNEL = 'EMAIL')               AS VIA_EMAIL,
  COUNT_IF(CHANNEL = 'SMS')                 AS VIA_SMS,
  COUNT_IF(IS_SERVICING_OBLIGATION)         AS ON_SERVICING_OBLIGATIONS,
  RATIO_TO_REPORT(COUNT(*)) OVER ()         AS SHARE_OF_SUPPRESSIONS
FROM   GOLD.NBA_ELIGIBLE
WHERE  SUPPRESSED
  AND  ELIGIBLE_ON_NEED
GROUP  BY SUPPRESSION_REASON;


/* ============================================================================
   PART 7 — V_CUSTOMER_SUPPRESSED: the blocked actions for one customer
   ----------------------------------------------------------------------------
   Screen 2's "Suppressed" expander, which the M10 brief calls the most
   impressive thing on the screen and instructs must not be hidden.

   Three array columns are carried rather than one. GOLD.NBA_ELIGIBLE's header
   makes the distinction and the app surfaces it: RULES_FAILED is a rule that
   applied and blocked, RULES_NOT_APPLICABLE is a rule that did not apply, and
   RULES_EXEMPT is a rule that applied and was deliberately waived under D7's
   servicing-obligation carve-out. Collapsing exempt into not-applicable would
   erase the only evidence that the waiver happened.

   ----------------------------------------------------------------------------
   BLOCKING_RULES: FILTER ON THE VERDICT, NOT ON THE RULE NAME
   ----------------------------------------------------------------------------
   The first version of this view tried to pull the trace entry whose `rule`
   matched SUPPRESSION_REASON, so the app could show the value the governing rule
   fired on. It was wrong twice over and both mistakes are worth recording.

   First, it did not compile where it mattered. A correlated subquery over
   FLATTEN of an outer column is accepted by CREATE VIEW and then fails on
   SELECT with "Unsupported subquery type cannot be evaluated inside VIEW
   object". A view that creates successfully and cannot be read is the worst
   shape of this bug, because sql/19 reported PASS on all seven assertions while
   the screen it feeds was broken -- it was caught only by executing the app.

   Second, and more fundamentally, the join key did not exist. The trace and
   SUPPRESSION_REASON use different vocabularies: the trace says
   GLOBAL_CHANNEL_CONSENT, GATE_INCOME_BAND, GLOBAL_ARREARS, while the reason
   says NO_CHANNEL_CONSENT, PRODUCT_GATE_INCOME_BAND, ARREARS_CROSS_SELL. Even
   with a supported subquery the match would have returned empty for every row,
   silently -- an empty array renders as no detail, not as an error.

   Filtering on `verdict = 'BLOCK'` is both supported and better. It needs no
   name mapping, it uses a pure lambda with no outer reference, and it returns
   EVERY rule that blocked rather than only the one that got named as the
   headline reason. A customer refused a cross-sell on three independent grounds
   is a different compliance fact from one refused on a single ground, and the
   app can now show all three with the value each fired on.
   ============================================================================ */

CREATE OR REPLACE VIEW APP.V_CUSTOMER_SUPPRESSED
  COMMENT = 'Per-customer suppressed actions with every rule that blocked and the value each fired on, for the screen 2 Suppressed expander. Restricted to pairs that passed the need test, so every row is an action the customer genuinely needed and was not contacted about. BLOCKING_RULES / EXEMPT_RULES are extracted from ELIGIBILITY_TRACE by verdict rather than by rule name, because the trace vocabulary (GLOBAL_CHANNEL_CONSENT) and the SUPPRESSION_REASON vocabulary (NO_CHANNEL_CONSENT) are not the same and matching them returned empty for every row. RULES_FAILED / RULES_NOT_APPLICABLE / RULES_EXEMPT are also kept because a rule that blocked, a rule that did not apply and a rule that was deliberately waived (PROJECT_BRIEF D7) are three different compliance facts.'
AS
SELECT
  e.CUSTOMER_ID,
  e.ACTION_CODE,
  e.ACTION_NAME,
  e.CATEGORY,
  e.CHANNEL,
  e.PRIORITY_TIER,
  e.IS_SALES_ACTION,
  e.IS_SERVICING_OBLIGATION,
  e.SUPPRESSION_REASON,
  e.SUPPRESSION_REASONS,
  ARRAY_SIZE(e.SUPPRESSION_REASONS)    AS SUPPRESSION_REASON_COUNT,
  e.VALUE_AT_STAKE_INR,
  e.VALUE_AT_STAKE_INR * e.MARGIN_RATE AS GROSS_MARGIN_INR,
  e.RULES_FAILED,
  e.RULES_NOT_APPLICABLE,
  e.RULES_EXEMPT,
  e.REGULATORY_NOTE,
  e.ELIGIBILITY_TRACE,
  /* Every rule that blocked, each carrying the value it fired on. Pure lambda:
     no outer column is referenced, so this evaluates inside a view. */
  FILTER(e.ELIGIBILITY_TRACE, x -> x:verdict::VARCHAR = 'BLOCK')  AS BLOCKING_RULES,
  FILTER(e.ELIGIBILITY_TRACE, x -> x:verdict::VARCHAR = 'EXEMPT') AS EXEMPT_RULES
FROM   GOLD.NBA_ELIGIBLE e
WHERE  e.SUPPRESSED
  AND  e.ELIGIBLE_ON_NEED;


/* ============================================================================
   PART 8 — V_TIMELINE_DETAIL and V_SENTIMENT_SERIES
   ----------------------------------------------------------------------------
   Screen 2's centre column, and the sparkline beside it.

   V_TIMELINE_DETAIL attaches the interaction body and its extracted signals to
   the INTERACTION rows of GOLD.CUSTOMER_TIMELINE. All 1,203 interaction events
   join cleanly on SOURCE_ID = INTERACTION_ID, verified in PART 10. Non-
   interaction event types -- payments, policies, claims, tickets, campaigns --
   carry NULL in the interaction block, which is the correct answer rather than
   a gap: a repayment has no transcript.

   The signals shown are the ones sql/05 already paid for. Nothing here calls an
   AI function; the confidence gate has already been applied upstream in
   CURATED.INTERACTION_SIGNALS_GATED, and this view reads the gated columns so
   the app never displays a signal the threshold withheld.

   ----------------------------------------------------------------------------
   V_SENTIMENT_SERIES IS READINGS, NOT A TREND
   ----------------------------------------------------------------------------
   PROJECT_BRIEF D6 is load-bearing here. SENTIMENT_SLOPE_PER_30D must not
   appear in a ranking expression, a propensity term or an eligibility
   predicate, and this view does not reference it. What it emits is the raw
   per-interaction readings so the app can draw a sparkline -- a picture of
   observations, which is honest at any n, rather than a fitted statistic, which
   is not honest at n = 3 over three weeks.

   The app must therefore render the sparkline as marks and not as a fitted
   line, and must distinguish INSUFFICIENT_DATA from STABLE: 460 customers have
   readings too sparse to trend and 4,404 have never been contacted at all.
   Neither is a stable relationship. D6 is explicit that collapsing unknown to
   stable reads a deteriorating relationship as a calm one.
   ============================================================================ */

CREATE OR REPLACE VIEW APP.V_TIMELINE_DETAIL
  COMMENT = 'GOLD.CUSTOMER_TIMELINE with the interaction body and its AI-extracted signals attached, so an INTERACTION row on screen 2 can expand into the transcript that produced it and the signals drawn from it. Non-interaction events carry NULL in the interaction block by design -- a repayment has no transcript. Signals are read from the confidence-gated view, so the app cannot display a signal sql/05 withheld. Zero AI calls: everything here was paid for in sql/05.'
AS
SELECT
  t.EVENT_ID,
  t.CUSTOMER_ID,
  t.EVENT_TYPE,
  t.OCCURRED_AT,
  t.TITLE,
  t.DETAIL,
  t.SOURCE_TABLE,
  t.SOURCE_ID,
  /* Interaction block -- populated only for EVENT_TYPE = 'INTERACTION'. */
  i.SUBJECT              AS INTERACTION_SUBJECT,
  i.BODY                 AS INTERACTION_BODY,
  i.CHANNEL              AS INTERACTION_CHANNEL,
  i.DIRECTION            AS INTERACTION_DIRECTION,
  i.LANGUAGE_CODE        AS INTERACTION_LANGUAGE,
  i.SOURCE_KIND          AS INTERACTION_SOURCE_KIND,
  (i.SOURCE_KIND = 'AUDIO') AS FROM_AUDIO,
  s.SENTIMENT_OVERALL,
  s.SENTIMENT_SCORE,
  s.SENTIMENT_PRICING,
  s.SENTIMENT_SERVICE,
  s.SENTIMENT_CLAIMS,
  s.INTENT,
  s.INTENT_CONF,
  s.SUMMARY_25W,
  s.CHURN_RISK_MENTIONED,
  s.COMPETITOR_MENTIONED,
  s.COMPETITOR_NAME,
  s.COMPLAINT,
  s.LIFE_EVENT,
  s.HARDSHIP_SIGNAL,
  s.CONSENT_WITHDRAWAL,
  s.PRODUCT_MENTIONED,
  s.AMOUNT_DISCUSSED_INR,
  s.PROMISED_CALLBACK_DATE
FROM       GOLD.CUSTOMER_TIMELINE t
LEFT JOIN  RAW.INTERACTION        i ON t.SOURCE_TABLE = 'RAW.INTERACTION'
                                   AND t.SOURCE_ID   = i.INTERACTION_ID
LEFT JOIN  CURATED.INTERACTION_SIGNALS_GATED s ON s.INTERACTION_ID = i.INTERACTION_ID;


CREATE OR REPLACE VIEW APP.V_SENTIMENT_SERIES
  COMMENT = 'Per-interaction sentiment readings for the screen 2 sparkline. Deliberately raw observations rather than a fitted trend: PROJECT_BRIEF D6 records that a slope over three readings inside a few weeks is steep almost regardless of the underlying change, so the app draws the marks and lets the reader see n. Does not read the diagnostic-only regression slope column D6 quarantines from ranking (the column is deliberately not named here so the A2 assertion in sql/19 cannot match its own documentation). READING_COUNT lets the app suppress the chart entirely below two readings instead of drawing a line through one point.'
AS
SELECT
  s.CUSTOMER_ID,
  s.INTERACTION_ID,
  s.OCCURRED_AT,
  s.SENTIMENT_SCORE,
  s.SENTIMENT_OVERALL,
  s.INTENT,
  s.CHANNEL,
  COUNT(*)      OVER (PARTITION BY s.CUSTOMER_ID) AS READING_COUNT,
  ROW_NUMBER()  OVER (PARTITION BY s.CUSTOMER_ID ORDER BY s.OCCURRED_AT) AS READING_SEQ
FROM   CURATED.INTERACTION_SIGNALS_GATED s
WHERE  s.SENTIMENT_SCORE IS NOT NULL;


/* ============================================================================
   PART 9 — V_IMPACT_BASE: the contact-everyone counterfactual
   ----------------------------------------------------------------------------
   Screen 4 asks what the guardrail layer is worth in rupees. That needs a
   baseline, and the baseline has to be a campaign somebody might actually have
   run -- otherwise the comparison is rhetorical.

   THE BASELINE IS: contact every (customer x action) pair that passed the need
   test, ignoring compliance entirely. 16,475 contacts. That is the campaign a
   bank runs when it targets on need and propensity alone, which is exactly the
   system this project is arguing against, so it is the right counterfactual.
   It is NOT all 90,000 rows of GOLD.NBA_ELIGIBLE -- nobody solicits a product
   the customer has no need for, and using that denominator would flatter the
   comparison.

   THE TARGETED ARM IS: the 3,917 published recommendations.

   THREE ARMS, NOT TWO, and the third one exists because two would have been
   quietly wrong. 4,040 rows survive compliance but only 3,917 are published:
   GOLD.NEXT_BEST_ACTION caps at three actions per customer, so 123 eligible
   recommendations are held back by the cap rather than by a rule. Folding those
   into the targeted arm would overstate the book the app actually shows; folding
   them into the suppressed arm would credit the compliance layer with blocking
   something it permitted. They get their own arm and the app names it.

     PUBLISHED               3,917   what screen 1 lists and an RM would work
     ELIGIBLE_NOT_PUBLISHED    123   permitted, lost to the top-3 cap
     SUPPRESSED             12,435   blocked by a compliance rule
     -------------------------------------------------------------------
     contact-everyone       16,475   the baseline

   The grain is (arm x channel x category) so the app can price each arm against
   its own channel mix. Compliance blocks disproportionately on CALL -- 9,535 of
   12,435 suppressions -- and CALL is two orders of magnitude the most expensive
   channel, so a simulator that used one blended cost would understate the
   saving substantially.

   GROSS_MARGIN_AT_FULL_ACCEPTANCE is VALUE_AT_STAKE x MARGIN_RATE: the revenue
   if every contacted customer accepted. The app scales it by the acceptance
   slider. It is deliberately not the stored EXPECTED_VALUE_INR, because that
   already has the engine's propensity baked in and the slider's whole purpose
   is to substitute a different acceptance assumption for it. Multiplying the
   two would apply propensity twice.
   ============================================================================ */

CREATE OR REPLACE VIEW APP.V_IMPACT_BASE
  COMMENT = 'Screen 4 simulator base at (arm x channel x category) grain. Three arms: PUBLISHED (3,917 recommendations the app shows), ELIGIBLE_NOT_PUBLISHED (123 that passed compliance but lost to the three-per-customer cap), SUPPRESSED (12,435 blocked by a rule). The three together are the contact-everyone baseline of 16,475 solicitations. The middle arm is separated on purpose: counting it as targeted overstates the book, counting it as suppressed credits compliance with a block it did not make. GROSS_MARGIN_AT_FULL_ACCEPTANCE is VALUE_AT_STAKE x MARGIN_RATE and excludes propensity, because the app substitutes a slider acceptance rate for propensity and multiplying both would apply it twice.'
AS
SELECT
  CASE
    WHEN e.FINAL_VERDICT <> 'ELIGIBLE'  THEN 'SUPPRESSED'
    WHEN n.CUSTOMER_ID IS NOT NULL      THEN 'PUBLISHED'
    ELSE 'ELIGIBLE_NOT_PUBLISHED'
  END                                       AS ARM,
  e.CHANNEL,
  e.CATEGORY,
  e.IS_SALES_ACTION,
  COUNT(*)                                  AS CONTACTS,
  COUNT(DISTINCT e.CUSTOMER_ID)             AS CUSTOMERS,
  SUM(e.VALUE_AT_STAKE_INR)                 AS VALUE_AT_STAKE_INR,
  SUM(e.VALUE_AT_STAKE_INR * e.MARGIN_RATE) AS GROSS_MARGIN_AT_FULL_ACCEPTANCE,
  AVG(e.MARGIN_RATE)                        AS AVG_MARGIN_RATE
FROM       GOLD.NBA_ELIGIBLE     e
LEFT JOIN  GOLD.NEXT_BEST_ACTION n ON n.CUSTOMER_ID = e.CUSTOMER_ID
                                  AND n.ACTION_CODE = e.ACTION_CODE
WHERE  e.ELIGIBLE_ON_NEED
GROUP  BY 1, 2, 3, 4;


/* ============================================================================
   PART 10 — ASSERTIONS
   ----------------------------------------------------------------------------
   Six checks. Every one has failed at least once in some form during the build
   of the layers below this, which is why they are here rather than assumed.
   ============================================================================ */

/* A1. The quarantine holds. RAW.CUSTOMER_SEGMENT_TRUTH must not be reachable
       from anything the app reads. This is the AGENTS.md invariant, and the app
       is the layer most likely to break it by accident because it is the one
       place somebody is tempted to "just show the segment". Same GET_DDL
       inspection as sql/08 A5.

       Note this checks the APP views' own text. GOLD.CUSTOMER_360 and
       GOLD.CUSTOMER_TIMELINE are asserted clean by sql/08, so the transitive
       reachability is covered between the two files. */
SELECT 'A1 quarantine holds'                                       AS check_name,
       COUNT_IF(UPPER(ddl) LIKE '%CUSTOMER_SEGMENT_TRUTH%')        AS violations,
       IFF(COUNT_IF(UPPER(ddl) LIKE '%CUSTOMER_SEGMENT_TRUTH%') = 0,
           'PASS', 'FAIL')                                         AS verdict
FROM (
  SELECT GET_DDL('VIEW', 'APP.V_RM_BOOK')             AS ddl
  UNION ALL SELECT GET_DDL('VIEW', 'APP.V_WORKLIST')
  UNION ALL SELECT GET_DDL('VIEW', 'APP.V_PORTFOLIO_KPI')
  UNION ALL SELECT GET_DDL('VIEW', 'APP.V_SUPPRESSION_SUMMARY')
  UNION ALL SELECT GET_DDL('VIEW', 'APP.V_CUSTOMER_SUPPRESSED')
  UNION ALL SELECT GET_DDL('VIEW', 'APP.V_TIMELINE_DETAIL')
  UNION ALL SELECT GET_DDL('VIEW', 'APP.V_SENTIMENT_SERIES')
  UNION ALL SELECT GET_DDL('VIEW', 'APP.V_IMPACT_BASE')
);

/* A2. D6 holds: no app view reads the raw sentiment slope.

       This assertion failed on its first run, and the cause is worth recording
       because it is a trap this project has already fallen into once. It did
       not fail because a view read the column -- none does. It failed because
       V_SENTIMENT_SERIES's own COMMENT said "does not reference
       SENTIMENT_SLOPE_PER_30D", GET_DDL returns the comment along with the
       body, and the assertion matched its own documentation.

       sql/08 hit this and solved it the same way: the comments on
       GOLD.CUSTOMER_360 and GOLD.CUSTOMER_TIMELINE describe the quarantine
       without naming the quarantined table, precisely so the check cannot match
       the prose. Same fix applied here. A GET_DDL assertion cannot distinguish
       a reference from a mention, so the documentation has to stay out of the
       search space. */
SELECT 'A2 no sentiment slope in app layer'                 AS check_name,
       COUNT_IF(UPPER(ddl) LIKE '%SENTIMENT_SLOPE_PER_30D%') AS violations,
       IFF(COUNT_IF(UPPER(ddl) LIKE '%SENTIMENT_SLOPE_PER_30D%') = 0,
           'PASS', 'FAIL')                                   AS verdict
FROM (
  SELECT GET_DDL('VIEW', 'APP.V_SENTIMENT_SERIES') AS ddl
  UNION ALL SELECT GET_DDL('VIEW', 'APP.V_TIMELINE_DETAIL')
  UNION ALL SELECT GET_DDL('VIEW', 'APP.V_WORKLIST')
);

/* A3. V_PORTFOLIO_KPI is exactly one row. It is cross-joined from eight CTEs
       and any one of them returning zero rows would silently empty the whole
       KPI strip -- which is precisely what an empty ACTION_FEEDBACK table
       would have done had the feedback CTE not been an aggregate. */
SELECT 'A3 KPI view is single-row'   AS check_name,
       COUNT(*)                      AS row_count,
       IFF(COUNT(*) = 1, 'PASS', 'FAIL') AS verdict
FROM   APP.V_PORTFOLIO_KPI;

/* A4. Every published recommendation survives the worklist joins. V_WORKLIST
       inner-joins the catalogue and CUSTOMER_360; if either lost a row the
       worklist would be quietly short and the KPI strip -- computed from
       GOLD directly -- would not agree with it. */
SELECT 'A4 worklist preserves published set' AS check_name,
       (SELECT COUNT(*) FROM GOLD.NEXT_BEST_ACTION) AS published,
       (SELECT COUNT(*) FROM APP.V_WORKLIST)        AS in_worklist,
       IFF((SELECT COUNT(*) FROM GOLD.NEXT_BEST_ACTION)
           = (SELECT COUNT(*) FROM APP.V_WORKLIST), 'PASS', 'FAIL') AS verdict;

/* A5. Every RM assignment resolves, and the roster did not overflow. */
SELECT 'A5 RM book covers every customer' AS check_name,
       COUNT(*)                           AS customers,
       COUNT_IF(RM_NAME IS NULL)          AS unassigned,
       COUNT(DISTINCT RM_NAME)            AS distinct_rms,
       IFF(COUNT_IF(RM_NAME IS NULL) = 0
           AND COUNT(*) = (SELECT COUNT(*) FROM GOLD.CUSTOMER_360),
           'PASS', 'FAIL')                AS verdict
FROM   APP.V_RM_BOOK;

/* A6. Every INTERACTION timeline event resolves to a body. If this breaks, the
       screen 2 transcript expander silently shows an empty box rather than an
       error, which is the failure mode worth catching in SQL. */
SELECT 'A6 interaction events resolve to a transcript' AS check_name,
       COUNT(*)                              AS interaction_events,
       COUNT_IF(INTERACTION_BODY IS NULL)    AS unresolved,
       IFF(COUNT_IF(INTERACTION_BODY IS NULL) = 0, 'PASS', 'FAIL') AS verdict
FROM   APP.V_TIMELINE_DETAIL
WHERE  EVENT_TYPE = 'INTERACTION';


/* A7. The three impact arms reconcile. PUBLISHED must equal the published set
       exactly, and the three arms must sum to the need-eligible baseline with
       nothing double-counted by the LEFT JOIN -- which is the specific risk
       here, since a customer can hold the same ACTION_CODE only once but the
       join is on (customer, action) and a fanout would silently inflate the
       baseline. */
SELECT 'A7 impact arms reconcile' AS check_name,
       SUM(IFF(ARM='PUBLISHED', CONTACTS, 0))               AS published,
       SUM(IFF(ARM='ELIGIBLE_NOT_PUBLISHED', CONTACTS, 0))  AS held_by_cap,
       SUM(IFF(ARM='SUPPRESSED', CONTACTS, 0))              AS suppressed,
       SUM(CONTACTS)                                        AS baseline,
       IFF(SUM(IFF(ARM='PUBLISHED', CONTACTS, 0))
             = (SELECT COUNT(*) FROM GOLD.NEXT_BEST_ACTION)
           AND SUM(CONTACTS)
             = (SELECT COUNT(*) FROM GOLD.NBA_ELIGIBLE WHERE ELIGIBLE_ON_NEED),
           'PASS', 'FAIL')                                  AS verdict
FROM   APP.V_IMPACT_BASE;


/* A8. Every app view is READABLE, not merely creatable.

       This is the assertion the first version of this file did not have, and its
       absence let a broken view ship green. CREATE VIEW validates names and
       types; it does not plan the query. A correlated subquery over FLATTEN of an
       outer column passes CREATE and then fails on SELECT with "Unsupported
       subquery type cannot be evaluated inside VIEW object" -- so A1 through A7
       all reported PASS while APP.V_CUSTOMER_SUPPRESSED could not be read at all,
       and the failure surfaced only when the Streamlit app was executed against
       it.

       Touching one row of each view is enough: planning is what fails, and the
       planner runs regardless of how many rows come back. Each branch is
       parenthesised because a bare LIMIT inside a UNION ALL arm is a syntax
       error in Snowflake -- the LIMIT binds to the whole set operation, not to
       the arm, so it has to be scoped explicitly.

       Anything added to APP for the app to read must be added here too. */
SELECT 'A8 every app view is readable' AS check_name,
       COUNT(*)                        AS views_probed,
       9                               AS views_expected,
       IFF(COUNT(*) = 9, 'PASS', 'FAIL') AS verdict
FROM (
            (SELECT 1 AS probe FROM APP.V_RM_BOOK               LIMIT 1)
  UNION ALL (SELECT 1         FROM APP.V_WORKLIST               LIMIT 1)
  UNION ALL (SELECT 1         FROM APP.V_PORTFOLIO_KPI          LIMIT 1)
  UNION ALL (SELECT 1         FROM APP.V_SUPPRESSION_SUMMARY    LIMIT 1)
  UNION ALL (SELECT 1         FROM APP.V_CUSTOMER_SUPPRESSED    LIMIT 1)
  UNION ALL (SELECT 1         FROM APP.V_TIMELINE_DETAIL        LIMIT 1)
  UNION ALL (SELECT 1         FROM APP.V_SENTIMENT_SERIES       LIMIT 1)
  UNION ALL (SELECT 1         FROM APP.V_IMPACT_BASE            LIMIT 1)
  UNION ALL (SELECT 1         FROM APP.V_NBA_EVIDENCE_RESOLVED  LIMIT 1)
);

/* A9. BLOCKING_RULES is actually populated. The bug this file previously carried
       returned an empty array for every row rather than erroring, and an empty
       array renders as "no detail shown" -- invisible. Every suppressed row must
       carry at least one blocking rule, because that is what suppressed means. */
SELECT 'A9 blocking rules populated' AS check_name,
       COUNT(*)                                    AS suppressed_rows,
       COUNT_IF(ARRAY_SIZE(BLOCKING_RULES) = 0)    AS rows_with_no_rule,
       ROUND(AVG(ARRAY_SIZE(BLOCKING_RULES)), 2)   AS avg_rules_per_row,
       IFF(COUNT_IF(ARRAY_SIZE(BLOCKING_RULES) = 0) = 0, 'PASS', 'FAIL') AS verdict
FROM   APP.V_CUSTOMER_SUPPRESSED;


/* ============================================================================
   PART 11 — GRANTS
   ----------------------------------------------------------------------------
   The Streamlit object runs as its owner, COCO_BUILDER, which already owns
   every object above. No grant is needed for the app to read its own views.

   The one privilege that does NOT resolve through ownership is the agent call
   on the ASK screen: SNOWFLAKE.CORTEX.DATA_AGENT_RUN resolves privileges from
   the querying user's DEFAULT role, not the session role and not the app
   owner. sql/18b already granted COCO_BUILDER to SYSADMIN for exactly this
   reason. If the ASK screen returns a privilege error for a new user, that is
   the file to read -- their default role needs to inherit COCO_BUILDER.
   ============================================================================ */

/* Nothing to grant. Left as a comment rather than omitted, because "there are
   no grants here" is a fact the next reader will otherwise have to establish
   for themselves. */

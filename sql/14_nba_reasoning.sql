/* ============================================================================
   14_nba_reasoning.sql — LAYER 4 of the Next Best Action engine
   ============================================================================
   WHAT THIS LAYER DOES, AND THE ONE THING IT MUST NOT DO

   Layers 1-3 decided everything that matters commercially and legally:
     11  ACTION_CATALOG      what actions exist and what makes one relevant
     12  NBA_ELIGIBLE        who may be offered what, with a rule-by-rule trace
     13  NBA_SCORED          how likely, how valuable, in what order

   This layer adds language. It does not add decisions. The model receives ONLY
   the actions that survived Layer 2 and were scored in Layer 3, and it is
   structurally unable to introduce another one:

     - the candidate list in the prompt is the eligible set, nothing else
     - the response schema constrains action_code to a string, and Part 6
       hard-rejects any returned code that is not in that customer's own
       candidate array (not merely "not in the catalogue" — not in HIS list)
     - propensity, expected value, rank order, channel and disclosure text are
       all carried through from Layer 3 / the catalogue. The model never emits a
       number that lands in the final table.

   So the worst a bad generation can do is produce a poor sentence, or drop a
   row. It cannot recommend a product to someone the rules blocked.

   ----------------------------------------------------------------------------
   COST DISCIPLINE  (AGENTS.md: a ceiling covers the milestone, not a script)

   This is the ONLY layer in M5 that spends AI credits. Layers 11/12/13 were
   verified at zero (check 13.7.4). The M5 ceiling is 15 credits and this file
   is the whole of it.

   The paid output lands in GOLD.NBA_REASONING_RAW, created IF NOT EXISTS and
   filled by anti-join. Re-running this script costs zero credits: rows already
   generated are skipped. $BATCH_CUSTOMERS caps the spend per execution, which
   is what makes a 25-row measured pilot possible before committing the batch.

   Cost is measured per R8: from ACCOUNT_USAGE.CORTEX_AI_FUNCTIONS_USAGE_HISTORY
   filtered by the specific QUERY_ID of the generating INSERT — never by a time
   window. A shared window double-counted a pilot in M3 and produced a 2x-wrong
   per-row rate. AI_COUNT_TOKENS is used for sizing only; it undercounted 1.85x
   in M3 and is not a gate.

   ----------------------------------------------------------------------------
   OBJECTS

     GOLD.SP_ASSERT_SCORED_READY   guard: refuses to run on a stale Layer 3
     GOLD.NBA_LLM_COHORT           OR REPLACE   free   who gets a rationale
     GOLD.NBA_EVIDENCE             OR REPLACE   free   citable evidence lines
     GOLD.NBA_REASONING_PLAN       OR REPLACE   free   prompt + candidate set
     GOLD.NBA_REASONING_RAW        IF NOT EXISTS PAID   raw AI_COMPLETE JSON
     GOLD.NBA_REASONING_PENDING    view         free   what is left to generate
     GOLD.NBA_AI_SPEND_LOG         IF NOT EXISTS free   QUERY_ID per paid batch
     GOLD.NBA_REASONING_VALIDATED  OR REPLACE   free   parsed + hallucination-checked

   GOLD.NEXT_BEST_ACTION is rebuilt in 15_nba_publish.sql, after the cost gate.
   ============================================================================ */

USE DATABASE C360_NBA;
USE SCHEMA GOLD;
USE WAREHOUSE COCO_WH;

/* Pilot batch size. Set to 25 for the measured pilot; raised only after the
   projection has been reviewed against the remaining ceiling. */
SET BATCH_CUSTOMERS = 25;

SET GEN_MODEL      = 'claude-haiku-4-5';
/* v2 changed the prompt text, so it is a new version rather than a relabel of
   v1. Two pilot findings drove it: the model returned scoring-driver names as
   evidence labels (rule 3 now separates the two vocabularies), and it justified
   a limit increase on "she prefers calls" (rule 7 now requires a behavioural or
   transactional primary reason). v1's 25 rows stay in NBA_REASONING_RAW under
   their own version -- they cost 0.0486 credits and deleting paid output to
   pretend a superseded prompt never ran is not an audit trail. */
SET PROMPT_VERSION = 'nba-reason-v2';

/* Cohort bound. The full customer base is 5,000; 2,334 have at least one
   eligible action. We do not narrate all of them — see Part 1. */
SET COHORT_TARGET  = 1800;


/* ============================================================================
   PART 0 — PREFLIGHT
   ----------------------------------------------------------------------------
   Layer 3 refused to run on a failed predicate log; Layer 4 refuses to run on
   an empty or stale score table. Generating prose against a half-built score
   table would spend real credits on rows that are about to be replaced.
   ============================================================================ */

CREATE OR REPLACE PROCEDURE GOLD.SP_ASSERT_SCORED_READY()
RETURNS VARCHAR
LANGUAGE SQL
COMMENT = 'Raises unless GOLD.NBA_SCORED is populated and consistent with NBA_ELIGIBLE. Called before any paid generation.'
AS
$$
DECLARE
    n_scored    INTEGER;
    n_eligible  INTEGER;
    n_orphan    INTEGER;
    EMPTY_SCORE EXCEPTION (-20701,
        'ABORT: GOLD.NBA_SCORED is empty. Run sql/13_nba_scoring.sql first.');
    DRIFT       EXCEPTION (-20702,
        'ABORT: GOLD.NBA_SCORED contains rows absent from the current GOLD.NBA_ELIGIBLE non-suppressed set. Re-run 12 then 13 before spending credits.');
BEGIN
    SELECT COUNT(*) INTO n_scored FROM GOLD.NBA_SCORED;
    IF (n_scored = 0) THEN
        RAISE EMPTY_SCORE;
    END IF;

    SELECT COUNT(*) INTO n_eligible
      FROM GOLD.NBA_ELIGIBLE WHERE FINAL_VERDICT = 'ELIGIBLE';

    SELECT COUNT(*) INTO n_orphan
      FROM GOLD.NBA_SCORED s
      WHERE NOT EXISTS (
        SELECT 1 FROM GOLD.NBA_ELIGIBLE e
        WHERE e.CUSTOMER_ID = s.CUSTOMER_ID
          AND e.ACTION_CODE = s.ACTION_CODE
          AND e.FINAL_VERDICT = 'ELIGIBLE'
      );
    IF (n_orphan > 0) THEN
        RAISE DRIFT;
    END IF;

    RETURN 'OK: ' || n_scored || ' scored rows, ' || n_eligible
        || ' recommendable eligible rows, 0 orphans.';
END;
$$;

CALL GOLD.SP_ASSERT_SCORED_READY();


/* ============================================================================
   PART 1 — COHORT SELECTION
   ----------------------------------------------------------------------------
   Two constraints pull against each other.

   COST. ~1,800 calls is the agreed bound, not 5,000 and not even all 2,334
   customers who have an eligible action. Everyone outside the cohort still gets
   a recommendation — ranked by PRIORITY_TIER then expected value, exactly as
   Layer 3 computed it — just without a generated rationale. The engine degrades
   to deterministic output, it does not degrade to no output.

   COVERAGE. The demo has to show a rationale for every interesting case. The
   interesting cases are the planted segments, and we cannot select on them:
   RAW.CUSTOMER_SEGMENT_TRUTH is quarantined (AGENTS.md) and may only be read
   by evals/. So the cohort is defined by the ENGINE's own view of the world --
   customers eligible for one of the five signature actions that correspond to
   the planted segments. If the engine's eligibility is right, this set contains
   the planted customers; if it is wrong, the cohort is wrong too, and the
   verification in Part 7 of 12 already established which it is.

   A note that came out of measurement: 1,189 of the 2,334 eligible customers
   have exactly ONE eligible action. For them there is nothing to rank, and the
   model's contribution is purely the sentence an agent reads out. That is still
   the screen content, so they are not excluded -- but it does mean the ranking
   half of this layer only exercises on the 1,145 multi-action customers, and
   the random sample is deliberately weighted toward them.
   ============================================================================ */

CREATE OR REPLACE TABLE GOLD.NBA_LLM_COHORT
COMMENT = 'Customers selected for LLM rationale generation. SIGNATURE = eligible for an action that corresponds to a planted demand segment (chosen from GOLD only, never from the quarantined truth table). SAMPLE_MULTI / SAMPLE_SINGLE = deterministic hash sample of the remainder, weighted toward customers with something to rank.'
AS
WITH per_cust AS (
    SELECT CUSTOMER_ID,
           COUNT(*)                                          AS N_ACTIONS,
           MAX(EXPECTED_VALUE_INR)                           AS TOP_EV_INR,
           MAX(IFF(ACTION_CODE IN ('RETENTION_SAVE_CALL',
                                   'CARD_LIMIT_INCREASE',
                                   'HOME_PROTECTION_CROSS_SELL',
                                   'COLLECTIONS_HARDSHIP_OUTREACH',
                                   'WEALTH_REFERRAL'), TRUE, FALSE))
                                                             AS HAS_SIGNATURE_ACTION
    FROM GOLD.NBA_SCORED
    GROUP BY 1
),
/* Deterministic, reproducible sample. HASH not RANDOM: a re-run must select the
   same customers or the anti-join in Part 5 would start paying for new rows. */
ranked AS (
    SELECT p.*,
           ABS(HASH(p.CUSTOMER_ID)) % 1000000                AS SAMPLE_KEY,
           ROW_NUMBER() OVER (ORDER BY IFF(p.N_ACTIONS > 1, 0, 1),
                                       ABS(HASH(p.CUSTOMER_ID)) % 1000000)
                                                             AS SAMPLE_RANK
    FROM per_cust p
    WHERE NOT p.HAS_SIGNATURE_ACTION
),
n_sig AS (SELECT COUNT(*) AS c FROM per_cust WHERE HAS_SIGNATURE_ACTION)
SELECT CUSTOMER_ID, N_ACTIONS, TOP_EV_INR,
       'SIGNATURE'                                           AS COHORT_REASON,
       CURRENT_TIMESTAMP()                                   AS SELECTED_AT
FROM per_cust WHERE HAS_SIGNATURE_ACTION
UNION ALL
SELECT r.CUSTOMER_ID, r.N_ACTIONS, r.TOP_EV_INR,
       IFF(r.N_ACTIONS > 1, 'SAMPLE_MULTI', 'SAMPLE_SINGLE') AS COHORT_REASON,
       CURRENT_TIMESTAMP()
FROM ranked r, n_sig
WHERE r.SAMPLE_RANK <= GREATEST($COHORT_TARGET - n_sig.c, 0);

SELECT 'cohort'        AS check_name,
       COHORT_REASON,
       COUNT(*)                                              AS customers,
       SUM(N_ACTIONS)                                         AS eligible_rows,
       ROUND(AVG(N_ACTIONS), 2)                               AS avg_actions
FROM GOLD.NBA_LLM_COHORT
GROUP BY 1, 2
UNION ALL
SELECT 'cohort', 'TOTAL', COUNT(*), SUM(N_ACTIONS), ROUND(AVG(N_ACTIONS), 2)
FROM GOLD.NBA_LLM_COHORT
ORDER BY 2;


/* ============================================================================
   PART 2 — EVIDENCE
   ----------------------------------------------------------------------------
   "Every recommendation cites evidence" (PROJECT_BRIEF §2.4). For that to mean
   anything, the citation has to point at a row someone can open.

   GOLD.CUSTOMER_TIMELINE is already the right shape: 108,144 rows, each with a
   real SOURCE_ID (TKT-00007982, IX-004682-2, POL-00000030) and a one-line
   human-readable DETAIL. Two adjustments:

   1. PAYMENT_ON_TIME is 44,006 of those rows and would swamp the pack while
      saying almost nothing. It is dropped from the lines and re-introduced as a
      single counted fact, which is the form the clean-repayment argument for
      CARD_LIMIT_INCREASE actually needs.

   2. Events are ranked by materiality first and recency second, then capped at
      8. Priority-first means a live complaint can never be pushed out of the
      pack by a run of recent routine events.

   The model is shown short labels E1..E8, not the 45-character EVENT_IDs. That
   is a token decision, not a traceability one: EVIDENCE_MAP carries the label
   back to the real SOURCE_ID, so what lands in NEXT_BEST_ACTION.evidence_ids is
   the auditable identifier and what went over the wire was two characters.
   ============================================================================ */

CREATE OR REPLACE TABLE GOLD.NBA_EVIDENCE
COMMENT = 'Up to 8 material timeline events per cohort customer, labelled E1..E8 for compact prompting. EVIDENCE_MAP resolves each label to the real source row id so a generated citation stays auditable. PAYMENT_ON_TIME is excluded from lines and counted separately.'
AS
WITH material AS (
    SELECT t.CUSTOMER_ID,
           t.EVENT_ID,
           t.EVENT_TYPE,
           t.OCCURRED_AT,
           /* SOURCE_ID is a business key for tickets, policies, claims and
              interactions (TKT-00000088, POL-00000030, IX-004682-2) but a bare
              row number for repayments, and "338" is not a citation anyone can
              act on. Measured in the pilot: 13 of 48 citations came back as bare
              integers. Prefix those with their source table so every id that
              reaches the screen names the row it points at. */
           CASE WHEN COALESCE(t.SOURCE_ID, '') RLIKE '^[0-9]+$'
                THEN REPLACE(SPLIT_PART(t.EVENT_ID, '|', 1), 'RAW.', '')
                     || '-' || t.SOURCE_ID
                ELSE COALESCE(t.SOURCE_ID, t.EVENT_ID)
           END                                               AS CITE_ID,
           t.TITLE,
           LEFT(COALESCE(t.DETAIL, ''), 200)                 AS DETAIL_SHORT,
           ROW_NUMBER() OVER (
               PARTITION BY t.CUSTOMER_ID
               ORDER BY CASE t.EVENT_TYPE
                            WHEN 'COMPLAINT_RAISED' THEN 1
                            WHEN 'INTERACTION'      THEN 2
                            WHEN 'PAYMENT_MISSED'   THEN 3
                            WHEN 'POLICY_LAPSED'    THEN 4
                            WHEN 'PAYMENT_LATE'     THEN 5
                            WHEN 'TICKET_OPENED'    THEN 6
                            WHEN 'CLAIM_FILED'      THEN 7
                            WHEN 'CLAIM_SETTLED'    THEN 8
                            WHEN 'LOAN_DISBURSED'   THEN 9
                            WHEN 'POLICY_ISSUED'    THEN 10
                            ELSE 11
                        END,
                        t.OCCURRED_AT DESC)                  AS RN
    FROM GOLD.CUSTOMER_TIMELINE t
    JOIN GOLD.NBA_LLM_COHORT c ON c.CUSTOMER_ID = t.CUSTOMER_ID
    WHERE t.EVENT_TYPE <> 'PAYMENT_ON_TIME'
),
capped AS (
    SELECT *, 'E' || RN AS LABEL FROM material WHERE RN <= 8
),
ontime AS (
    SELECT t.CUSTOMER_ID, COUNT(*) AS ON_TIME_12M
    FROM GOLD.CUSTOMER_TIMELINE t
    JOIN GOLD.NBA_LLM_COHORT c ON c.CUSTOMER_ID = t.CUSTOMER_ID
    WHERE t.EVENT_TYPE = 'PAYMENT_ON_TIME'
      AND t.OCCURRED_AT >= DATEADD('month', -12, CURRENT_DATE())
    GROUP BY 1
)
SELECT c.CUSTOMER_ID,
       COALESCE(o.ON_TIME_12M, 0)                            AS ON_TIME_PAYMENTS_12M,
       COUNT(*)                                              AS N_EVIDENCE_LINES,
       /* One text block, newline-separated, ready to splice into the prompt. */
       LISTAGG(c.LABEL || ' [' || TO_CHAR(c.OCCURRED_AT::DATE, 'DD Mon YYYY')
                       || '] ' || c.TITLE
                       || IFF(c.DETAIL_SHORT = '', '', ' — ' || c.DETAIL_SHORT),
               '\n') WITHIN GROUP (ORDER BY c.RN)             AS EVIDENCE_BLOCK,
       OBJECT_AGG(c.LABEL, c.CITE_ID::VARIANT)               AS EVIDENCE_MAP,
       ARRAY_AGG(c.LABEL) WITHIN GROUP (ORDER BY c.RN)        AS EVIDENCE_LABELS
FROM capped c
LEFT JOIN ontime o ON o.CUSTOMER_ID = c.CUSTOMER_ID
GROUP BY 1, 2;

SELECT 'evidence' AS check_name,
       COUNT(*)                                              AS cohort_customers_with_evidence,
       (SELECT COUNT(*) FROM GOLD.NBA_LLM_COHORT)            AS cohort_total,
       ROUND(AVG(N_EVIDENCE_LINES), 2)                       AS avg_lines,
       MIN(N_EVIDENCE_LINES)                                 AS min_lines,
       ROUND(AVG(LENGTH(EVIDENCE_BLOCK)))                    AS avg_block_chars
FROM GOLD.NBA_EVIDENCE;


/* ============================================================================
   PART 3 — THE PROMPT PLAN
   ----------------------------------------------------------------------------
   Built as a free table so the exact text that was paid for is inspectable
   afterwards, and so token sizing can be run without spending anything.

   What goes in:
     - a compact customer fact block, values only where they are informative
     - the evidence lines from Part 2
     - the candidate actions: code, name, channel, propensity, EV, and the
       non-zero driver features Layer 3 used

   What deliberately does NOT go in:
     - REQUIRED_DISCLOSURE. It is regulated wording. The model must not
       paraphrase it, so it is never shown to it; it is attached deterministically
       from the catalogue at publish time.
     - the eligibility trace. It is the audit artefact for humans; feeding 12
       rule verdicts per action would multiply input tokens for no gain in the
       sentence quality.
     - VULNERABILITY_FLAG / DNC / consent. By the time a row reaches here those
       gates have already been applied. Showing them would invite the model to
       reason about compliance, which is precisely the job we removed from it.
   ============================================================================ */

CREATE OR REPLACE TABLE GOLD.NBA_REASONING_PLAN
COMMENT = 'One prompt per cohort customer plus the candidate action codes that prompt is allowed to mention. CANDIDATE_CODES is the validation whitelist used in Part 6: a returned action_code outside this array is a hallucination and is dropped.'
AS
WITH facts AS (
    SELECT f.CUSTOMER_ID,
           'Name: '        || f.CUSTOMER_NAME
        || ' | Age: '      || f.AGE
        || ' | City: '     || f.CITY
        || ' | Value band: ' || f.SEGMENT
        || ' | Tenure: '   || f.TENURE_YEARS || 'y'
        || ' | Household: ' || f.HOUSEHOLD_SIZE
        || '\nHolds: '     || ARRAY_TO_STRING(f.PRODUCTS_HELD, ', ')
        || IFF(ARRAY_SIZE(f.PRODUCT_GAP) = 0, '',
               '\nNot held: ' || ARRAY_TO_STRING(f.PRODUCT_GAP, ', '))
        || '\nAnnual premium: INR ' || TO_VARCHAR(f.ANNUAL_PREMIUM_INR, '999,999,999')
        || ' | Outstanding credit: INR ' || TO_VARCHAR(f.OUTSTANDING_CREDIT_INR, '999,999,999')
        || IFF(f.DAYS_TO_RENEWAL IS NULL, '',
               '\nNext renewal: ' || TO_CHAR(f.NEXT_RENEWAL_DATE, 'DD Mon YYYY')
                                  || ' (' || f.DAYS_TO_RENEWAL || ' days away)')
        || IFF(f.NEXT_EMI_DATE IS NULL, '',
               ' | Next EMI: ' || TO_CHAR(f.NEXT_EMI_DATE, 'DD Mon YYYY'))
        || '\nRepayment status: ' || f.DPD_BUCKET
        || IFF(COALESCE(f.MISSED_COUNT_6M, 0) = 0, '',
               ', ' || f.MISSED_COUNT_6M || ' missed instalment(s) in 6 months')
        || IFF(f.DPD_RISING_3, ', arrears deepening over last 3 readings', '')
        || IFF(f.CREDIT_UTILISATION IS NULL, '',
               '\nCard utilisation: ' || ROUND(f.CREDIT_UTILISATION * 100) || '%'
            || IFF(f.UTILISATION_RISING_4, ' and rising across the last 4 statements', '')
            || IFF(f.ACTIVE_CARD_LIMIT_INR IS NULL, '',
                   ' on a INR ' || TO_VARCHAR(f.ACTIVE_CARD_LIMIT_INR, '999,999,999') || ' limit'))
        || IFF(f.SENTIMENT_TREND IS NULL, '', '\nSentiment trend: ' || f.SENTIMENT_TREND)
        || IFF(f.SENTIMENT_NOW  IS NULL, '', ' (latest: ' || f.SENTIMENT_NOW || ')')
        || IFF(f.OPEN_COMPLAINT, '\nOPEN COMPLAINT'
               || IFF(f.OPEN_COMPLAINT_SEVERITY IS NULL, '',
                      ' at severity ' || f.OPEN_COMPLAINT_SEVERITY)
               || IFF(f.TOP_OPEN_COMPLAINT_TICKET IS NULL, '',
                      ' (' || f.TOP_OPEN_COMPLAINT_TICKET || ')'), '')
        || IFF(COALESCE(f.LATEST_COMPETITOR_NAME, '') = '', '',
               '\nMentioned competitor: ' || f.LATEST_COMPETITOR_NAME)
        || IFF(COALESCE(f.MAX_AMOUNT_DISCUSSED_INR, 0) = 0, '',
               '\nAmount discussed on a call: INR '
               || TO_VARCHAR(f.MAX_AMOUNT_DISCUSSED_INR, '999,999,999'))
        || IFF(NOT f.LUMPSUM_CREDIT_90D, '',
               '\nLarge credit received in last 90 days: INR '
               || TO_VARCHAR(f.LUMPSUM_CREDIT_MAX_INR, '999,999,999'))
        || IFF(COALESCE(f.LAPSE_HISTORY, 0) = 0, '',
               '\nLapsed policies previously: ' || f.LAPSE_HISTORY)
        || '\nInteractions in last 90 days: ' || COALESCE(f.INTERACTIONS_90D, 0)
        || IFF(f.LAST_CONTACT_DAYS IS NULL, '',
               ' | Last contact ' || f.LAST_CONTACT_DAYS || ' days ago')
        || IFF(f.PREFERRED_CHANNEL IS NULL, '',
               '\nPreferred channel: ' || f.PREFERRED_CHANNEL)
                                                             AS FACT_BLOCK
    FROM GOLD.NBA_FEATURE_BASE f
    JOIN GOLD.NBA_LLM_COHORT c ON c.CUSTOMER_ID = f.CUSTOMER_ID
),
/* Candidate lines. DRIVER_FEATURES is flattened to just the names that carried
   weight, which is the honest short answer to "why does the model think this is
   likely" without asking it to trust a logit. */
drivers AS (
    SELECT s.CUSTOMER_ID, s.ACTION_CODE,
           ARRAY_TO_STRING(
               ARRAY_COMPACT(ARRAY_AGG(IFF(d.VALUE::FLOAT <> 0, d.KEY, NULL))
                             WITHIN GROUP (ORDER BY d.KEY)), ', ')   AS DRIVER_LIST
    FROM GOLD.NBA_SCORED s, LATERAL FLATTEN(input => s.DRIVER_FEATURES) d
    GROUP BY 1, 2
),
cands AS (
    SELECT s.CUSTOMER_ID,
           LISTAGG(s.ACTION_CODE || ' | ' || s.ACTION_NAME
                   || ' | channel ' || s.CHANNEL
                   || ' | propensity ' || TO_VARCHAR(ROUND(s.PROPENSITY, 3))
                   || ' | expected value INR ' || TO_VARCHAR(s.EXPECTED_VALUE_INR::NUMBER, '999,999,999')
                   || IFF(COALESCE(d.DRIVER_LIST, '') = '', '',
                          ' | drivers: ' || d.DRIVER_LIST),
                   '\n') WITHIN GROUP (ORDER BY s.RANK_WITHIN_CUSTOMER)
                                                             AS CANDIDATE_BLOCK,
           ARRAY_AGG(s.ACTION_CODE) WITHIN GROUP (ORDER BY s.RANK_WITHIN_CUSTOMER)
                                                             AS CANDIDATE_CODES,
           COUNT(*)                                          AS N_CANDIDATES
    FROM GOLD.NBA_SCORED s
    JOIN GOLD.NBA_LLM_COHORT c ON c.CUSTOMER_ID = s.CUSTOMER_ID
    LEFT JOIN drivers d ON d.CUSTOMER_ID = s.CUSTOMER_ID AND d.ACTION_CODE = s.ACTION_CODE
    GROUP BY 1
)
SELECT c.CUSTOMER_ID,
       $PROMPT_VERSION                                       AS PROMPT_VERSION,
       cd.CANDIDATE_CODES,
       cd.N_CANDIDATES,
       COALESCE(e.EVIDENCE_MAP, OBJECT_CONSTRUCT())          AS EVIDENCE_MAP,
       COALESCE(e.EVIDENCE_LABELS, ARRAY_CONSTRUCT())        AS EVIDENCE_LABELS,
'You are briefing a bank relationship agent in India before they contact a customer. Write what the agent should SAY.

RULES YOU MUST FOLLOW
1. You may ONLY use action codes from the CANDIDATE ACTIONS list below. Never invent, rename, merge or substitute an action code. Copy each code exactly.
2. You may reorder the candidates and you may drop any you judge inappropriate. You may return fewer than three. You must never return an action that is not listed.
3. Cite evidence only by the labels shown in EVIDENCE (E1, E2, ...). An evidence label is always the letter E followed by a digit. The words after "drivers:" in CANDIDATE ACTIONS are scoring feature names, NOT evidence labels — never put them in the evidence list. Never cite a label that is not listed. If no evidence line supports the action, return an empty evidence list rather than a guess.
4. Do not state, imply or invent any rupee figure, interest rate, premium, discount, fee, approval or eligibility promise. The bank computes those separately. Refer to amounts only if they appear in the CUSTOMER or EVIDENCE blocks.
5. Do not mention compliance, consent, do-not-call status or vulnerability. Those checks are already done.
6. Plain English, Indian banking register, no jargon and no marketing adjectives. The rationale is one sentence the agent could read aloud to a colleague. The opening line is one sentence the agent could say to the customer, and for a complaint or hardship case it acknowledges the problem before anything else.
7. The main reason in the rationale must be something the customer DID or something that happened to their account — a payment pattern, a missed or late instalment, a complaint, a claim, a stated request or intent, a utilisation trend, a renewal or lapse, a large credit received. A contact preference, preferred channel, value band, tenure, age, city or household size is never the main reason on its own; mention those only as supporting detail after the behavioural reason. If no behavioural or transactional signal supports an action, say plainly that the case rests on profile fit alone and set confidence to LOW.

CUSTOMER
' || f.FACT_BLOCK
  || IFF(COALESCE(e.ON_TIME_PAYMENTS_12M, 0) = 0, '',
         '\nOn-time payments in last 12 months: ' || e.ON_TIME_PAYMENTS_12M)
  || '

EVIDENCE
' || COALESCE(e.EVIDENCE_BLOCK, '(no material history on file)')
  || '

CANDIDATE ACTIONS (ranked by the bank''s own priority and expected value)
' || cd.CANDIDATE_BLOCK
  || '

Return the best ' || LEAST(cd.N_CANDIDATES, 3) || ' of these ' || cd.N_CANDIDATES
  || ' action(s), best first.'                               AS PROMPT
FROM GOLD.NBA_LLM_COHORT c
JOIN cands cd ON cd.CUSTOMER_ID = c.CUSTOMER_ID
JOIN facts f  ON f.CUSTOMER_ID  = c.CUSTOMER_ID
LEFT JOIN GOLD.NBA_EVIDENCE e ON e.CUSTOMER_ID = c.CUSTOMER_ID;


/* Sizing only. Per R8 this is a floor and undercounted 1.85x in M3, so it is
   reported for shape and never used to decide whether to proceed. */
SELECT 'token sizing (FLOOR, R8: undercounts ~1.85x)'        AS check_name,
       COUNT(*)                                              AS prompts,
       ROUND(AVG(LENGTH(PROMPT)))                            AS avg_prompt_chars,
       MAX(LENGTH(PROMPT))                                   AS max_prompt_chars,
       ROUND(AVG(AI_COUNT_TOKENS('ai_complete', 'llama3.3-70b', PROMPT)))
                                                             AS avg_input_tokens_floor,
       SUM(AI_COUNT_TOKENS('ai_complete', 'llama3.3-70b', PROMPT))
                                                             AS total_input_tokens_floor
FROM GOLD.NBA_REASONING_PLAN;


/* ============================================================================
   PART 4 — PAID OUTPUT TABLE AND SPEND LOG
   ----------------------------------------------------------------------------
   IF NOT EXISTS, not OR REPLACE. Everything in NBA_REASONING_RAW cost money.
   ============================================================================ */

CREATE TABLE IF NOT EXISTS GOLD.NBA_REASONING_RAW (
    CUSTOMER_ID      NUMBER,
    PROMPT_VERSION   VARCHAR,
    GEN_MODEL        VARCHAR,
    CANDIDATE_CODES  ARRAY,
    EVIDENCE_MAP     OBJECT,
    RESPONSE         VARIANT,
    GENERATED_AT     TIMESTAMP_LTZ
)
COMMENT = 'Raw AI_COMPLETE output, one row per customer per prompt version. PAID. Filled by anti-join so re-running 14 costs zero credits. CANDIDATE_CODES and EVIDENCE_MAP are snapshotted alongside the response so validation compares against the whitelist that was actually sent, not a later rebuild of it.';

CREATE TABLE IF NOT EXISTS GOLD.NBA_AI_SPEND_LOG (
    BATCH_AT         TIMESTAMP_LTZ,
    LABEL            VARCHAR,
    QUERY_ID         VARCHAR,
    ROWS_GENERATED   NUMBER,
    GEN_MODEL        VARCHAR,
    PROMPT_VERSION   VARCHAR
)
COMMENT = 'One row per paid generation statement. QUERY_ID is the join key into SNOWFLAKE.ACCOUNT_USAGE.CORTEX_AI_FUNCTIONS_USAGE_HISTORY. Per R8 cost is attributed by QUERY_ID and never by time window: a shared window double-counted an M3 pilot and produced a 2x-wrong per-row rate.';

/* Stale-version hygiene. If PROMPT_VERSION moves on, old output is not silently
   reused under the new label, and not silently deleted either -- it stays in
   the table under its own version, which is why the anti-join keys on both. */
CREATE OR REPLACE VIEW GOLD.NBA_REASONING_PENDING AS
SELECT COUNT(*)                                              AS PENDING_CUSTOMERS,
       $PROMPT_VERSION                                       AS PROMPT_VERSION
FROM GOLD.NBA_REASONING_PLAN p
WHERE NOT EXISTS (
    SELECT 1 FROM GOLD.NBA_REASONING_RAW g
    WHERE g.CUSTOMER_ID    = p.CUSTOMER_ID
      AND g.PROMPT_VERSION = p.PROMPT_VERSION
);

SELECT 'pending before generation' AS check_name, * FROM GOLD.NBA_REASONING_PENDING;


/* ============================================================================
   PART 5 — GENERATE  (the only statement in M5 that costs AI credits)
   ----------------------------------------------------------------------------
   temperature 0.2, not 0.9. The opposite of the M3 seeding call, and for the
   opposite reason: there we needed 1,200 artefacts not to collapse into
   templates; here the same customer must get the same brief twice, and a
   creative rationale is a liability.

   ORDER BY CUSTOMER_ID makes successive batches walk the plan in a stable
   order, so the pilot is a prefix of the full run rather than a random subset
   that would have to be paid for again.
   ============================================================================ */

INSERT INTO GOLD.NBA_REASONING_RAW
    (CUSTOMER_ID, PROMPT_VERSION, GEN_MODEL, CANDIDATE_CODES, EVIDENCE_MAP,
     RESPONSE, GENERATED_AT)
WITH todo AS (
    SELECT p.CUSTOMER_ID, p.PROMPT_VERSION, p.PROMPT,
           p.CANDIDATE_CODES, p.EVIDENCE_MAP
    FROM GOLD.NBA_REASONING_PLAN p
    WHERE NOT EXISTS (
        SELECT 1 FROM GOLD.NBA_REASONING_RAW g
        WHERE g.CUSTOMER_ID    = p.CUSTOMER_ID
          AND g.PROMPT_VERSION = p.PROMPT_VERSION
    )
    ORDER BY p.CUSTOMER_ID
    LIMIT $BATCH_CUSTOMERS
)
SELECT t.CUSTOMER_ID,
       t.PROMPT_VERSION,
       $GEN_MODEL,
       t.CANDIDATE_CODES,
       t.EVIDENCE_MAP,
       AI_COMPLETE(
           model            => $GEN_MODEL,
           prompt           => t.PROMPT,
           model_parameters => { 'temperature': 0.2, 'max_tokens': 1400 },
           response_format  => {
             'type': 'json',
             'schema': {
               'type': 'object',
               'properties': {
                 'recommendations': {
                   'type': 'array',
                   'description': 'best first, at most 3, only codes from CANDIDATE ACTIONS',
                   'items': {
                     'type': 'object',
                     'properties': {
                       'rank':          { 'type': 'number',
                                          'description': '1 for best, then 2, then 3' },
                       'action_code':   { 'type': 'string',
                                          'description': 'copied exactly from CANDIDATE ACTIONS' },
                       'rationale':     { 'type': 'string',
                                          'description': 'one sentence, plain English, why this customer now' },
                       'evidence':      { 'type': 'array',
                                          'description': 'labels such as E1, E3 taken only from EVIDENCE',
                                          'items': { 'type': 'string' } },
                       'opening_line':  { 'type': 'string',
                                          'description': 'one sentence the agent says to the customer first' },
                       'confidence':    { 'type': 'string',
                                          'description': 'HIGH, MEDIUM or LOW' }
                     },
                     'required': ['rank','action_code','rationale','evidence',
                                  'opening_line','confidence']
                   }
                 }
               },
               'required': ['recommendations']
             }
           }
       ),
       CURRENT_TIMESTAMP()
FROM todo t;

/* Attribute this batch's cost to its own QUERY_ID immediately, while
   LAST_QUERY_ID() still refers to the INSERT above. */
INSERT INTO GOLD.NBA_AI_SPEND_LOG
    (BATCH_AT, LABEL, QUERY_ID, ROWS_GENERATED, GEN_MODEL, PROMPT_VERSION)
SELECT CURRENT_TIMESTAMP(),
       'nba_reasoning_batch',
       LAST_QUERY_ID(),
       (SELECT COUNT(*) FROM GOLD.NBA_REASONING_RAW
        WHERE PROMPT_VERSION = $PROMPT_VERSION),
       $GEN_MODEL,
       $PROMPT_VERSION;

SELECT 'pending after generation' AS check_name, * FROM GOLD.NBA_REASONING_PENDING;

SELECT 'spend log' AS check_name, BATCH_AT, QUERY_ID, ROWS_GENERATED, GEN_MODEL
FROM GOLD.NBA_AI_SPEND_LOG ORDER BY BATCH_AT DESC;


/* ============================================================================
   PART 6 — PARSE AND VALIDATE
   ----------------------------------------------------------------------------
   This is where the "it cannot invent an action" claim is actually enforced.

   Four rejection classes, all recorded rather than silently dropped:
     HALLUCINATED_CODE  action_code not in this customer's CANDIDATE_CODES
     DUPLICATE_CODE     same code returned twice for one customer
     BAD_EVIDENCE       cited a label not in that customer's EVIDENCE_MAP
     MISSING_FIELD      empty rationale or opening line

   BAD_EVIDENCE does not drop the row -- an unsupported citation is a bad
   footnote, not a bad recommendation -- but the offending labels are stripped
   so nothing untraceable reaches evidence_ids. A HALLUCINATED_CODE drops.
   ============================================================================ */

CREATE OR REPLACE TABLE GOLD.NBA_REASONING_VALIDATED
COMMENT = 'Flattened AI_COMPLETE output with hallucination checks applied. VERDICT=ACCEPTED rows are publishable. HALLUCINATED_CODE / DUPLICATE_CODE / MISSING_FIELD are dropped at publish; BAD_EVIDENCE is accepted with the unresolvable labels stripped from EVIDENCE_IDS. Kept rather than filtered so the rejection rate is measurable.'
AS
WITH raw_rows AS (
    SELECT g.CUSTOMER_ID,
           g.PROMPT_VERSION,
           g.GEN_MODEL,
           g.CANDIDATE_CODES,
           g.EVIDENCE_MAP,
           g.GENERATED_AT,
           r.INDEX                                           AS ITEM_INDEX,
           r.VALUE:rank::NUMBER                               AS LLM_RANK,
           r.VALUE:action_code::VARCHAR                       AS ACTION_CODE,
           TRIM(r.VALUE:rationale::VARCHAR)                   AS RATIONALE,
           TRIM(r.VALUE:opening_line::VARCHAR)                AS OPENING_LINE,
           UPPER(TRIM(r.VALUE:confidence::VARCHAR))           AS CONFIDENCE,
           r.VALUE:evidence                                   AS EVIDENCE_RAW
    FROM GOLD.NBA_REASONING_RAW g,
         LATERAL FLATTEN(input => g.RESPONSE:recommendations) r
),
ev AS (
    /* PROMPT_VERSION is part of the grain, not decoration. Without it this CTE
       collapses every version's evidence map for a customer into one group and
       the join below resolves labels against the wrong map. That is not
       hypothetical: it silently made v2 rows report v1's bare-integer citations
       and produced byte-identical defect counts for two different prompts, which
       is what gave it away. NBA_REASONING_RAW is keyed (CUSTOMER_ID,
       PROMPT_VERSION) everywhere else -- this was the one place that forgot. */
    SELECT rr.CUSTOMER_ID, rr.PROMPT_VERSION, rr.ITEM_INDEX,
           ARRAY_COMPACT(ARRAY_AGG(
               IFF(rr.EVIDENCE_MAP[x.VALUE::VARCHAR] IS NOT NULL,
                   rr.EVIDENCE_MAP[x.VALUE::VARCHAR]::VARCHAR, NULL))
               WITHIN GROUP (ORDER BY x.INDEX))              AS EVIDENCE_IDS,
           COUNT_IF(rr.EVIDENCE_MAP[x.VALUE::VARCHAR] IS NULL) AS N_BAD_LABELS,
           ARRAY_AGG(x.VALUE::VARCHAR) WITHIN GROUP (ORDER BY x.INDEX)
                                                             AS EVIDENCE_LABELS_RETURNED
    FROM raw_rows rr, LATERAL FLATTEN(input => rr.EVIDENCE_RAW) x
    GROUP BY 1, 2, 3
),
judged AS (
    SELECT rr.*,
           COALESCE(ev.EVIDENCE_IDS, ARRAY_CONSTRUCT())      AS EVIDENCE_IDS,
           COALESCE(ev.EVIDENCE_LABELS_RETURNED, ARRAY_CONSTRUCT())
                                                             AS EVIDENCE_LABELS_RETURNED,
           COALESCE(ev.N_BAD_LABELS, 0)                      AS N_BAD_LABELS,
           NOT ARRAY_CONTAINS(rr.ACTION_CODE::VARIANT, rr.CANDIDATE_CODES)
                                                             AS IS_HALLUCINATED,
           COUNT(*) OVER (PARTITION BY rr.CUSTOMER_ID, rr.PROMPT_VERSION,
                                       rr.ACTION_CODE) > 1   AS IS_DUPLICATE,
           (COALESCE(rr.RATIONALE, '') = '' OR COALESCE(rr.OPENING_LINE, '') = '')
                                                             AS IS_INCOMPLETE
    FROM raw_rows rr
    LEFT JOIN ev ON ev.CUSTOMER_ID    = rr.CUSTOMER_ID
                AND ev.PROMPT_VERSION = rr.PROMPT_VERSION
                AND ev.ITEM_INDEX     = rr.ITEM_INDEX
)
SELECT CUSTOMER_ID, PROMPT_VERSION, GEN_MODEL, GENERATED_AT,
       ITEM_INDEX, LLM_RANK, ACTION_CODE, RATIONALE, OPENING_LINE,
       /* Confidence is capped, not trusted. Prompt rule 7 asks the model to set
          LOW when a case rests on profile fit alone; measured on the v2 pilot it
          complied for 2 of the 3 such rows and rated the third MEDIUM on "no
          health cover despite being 51 and affluent, and he prefers calls" --
          age, value band and channel, with no behavioural signal at all. A rule
          the model follows most of the time is a preference, not a guarantee, so
          the guarantee is enforced here instead: if it cited nothing, it cannot
          claim more than LOW. The model's own value is kept in CONFIDENCE_STATED
          so the disagreement stays visible rather than being overwritten. */
       IFF(CONFIDENCE IN ('HIGH','MEDIUM','LOW'), CONFIDENCE, 'MEDIUM')
                                                             AS CONFIDENCE_STATED,
       IFF(ARRAY_SIZE(EVIDENCE_IDS) = 0, 'LOW',
           IFF(CONFIDENCE IN ('HIGH','MEDIUM','LOW'), CONFIDENCE, 'MEDIUM'))
                                                             AS CONFIDENCE,
       EVIDENCE_IDS, EVIDENCE_LABELS_RETURNED, N_BAD_LABELS,
       CANDIDATE_CODES,
       /* Ordering matters: a hallucinated code is fatal regardless of anything
          else, so it is tested before the softer classes. */
       CASE WHEN IS_HALLUCINATED THEN 'HALLUCINATED_CODE'
            WHEN IS_DUPLICATE    THEN 'DUPLICATE_CODE'
            WHEN IS_INCOMPLETE   THEN 'MISSING_FIELD'
            WHEN N_BAD_LABELS>0  THEN 'BAD_EVIDENCE'
            ELSE 'ACCEPTED'
       END                                                   AS VERDICT,
       /* Rank the model asked for, renumbered densely over surviving rows so
          publish never sees a gap or a tie. */
       ROW_NUMBER() OVER (PARTITION BY CUSTOMER_ID, PROMPT_VERSION
                          ORDER BY IFF(IS_HALLUCINATED OR IS_DUPLICATE
                                       OR IS_INCOMPLETE, 1, 0),
                                   LLM_RANK, ITEM_INDEX)     AS LLM_RANK_DENSE
FROM judged;

SELECT 'validation' AS check_name, VERDICT, COUNT(*) AS n_rows,
       COUNT(DISTINCT CUSTOMER_ID)                           AS customers,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1)    AS pct
FROM GOLD.NBA_REASONING_VALIDATED
GROUP BY 1, 2 ORDER BY 3 DESC;

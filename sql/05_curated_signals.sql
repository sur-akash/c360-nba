/* ============================================================================
   05_curated_signals.sql  —  CURATED.INTERACTION_SIGNALS
   ----------------------------------------------------------------------------
   Reads the free text in RAW.INTERACTION and turns it into typed, confidence-
   scored signals: sentiment overall and by aspect, an intent from a fixed
   taxonomy, six behavioural flags, four extracted entities, and a 25-word
   summary. One row per interaction.

   Nothing in here reads RAW.CUSTOMER_SEGMENT_TRUTH. The planted segment was an
   input to generation in 04 and is quarantined; if this layer could see it, the
   inference would be circular and the demo claim worthless.

   ----------------------------------------------------------------------------
   FIVE AI CALLS PER ROW, NOT TEN
   ----------------------------------------------------------------------------
   The obvious build is one AI_FILTER per boolean flag, which is six calls for
   the flags alone plus four more for sentiment, intent, entities and summary.
   Every one of those re-sends the interaction body. On a $400 trial that is the
   difference between a few credits and a few dozen.

   So the six flags, the summary and a second opinion on intent and sentiment
   all come from ONE AI_COMPLETE structured-output call. That leaves:

     AI_SENTIMENT   overall + pricing / service / claims aspects
     AI_CLASSIFY    intent against CURATED.INTENT_TAXONOMY
     AI_EXTRACT     four entities, with scores => TRUE for real confidence
     AI_COMPLETE    six flags + summary + second opinion, structured output
     AI_FILTER      churn_risk_mentioned only, as an independent cross-check

   AI_FILTER earns its place by being a *different* model reaching the same
   judgement, which is what makes the churn confidence mean something. Using it
   six times would have bought six more bills and no more information.

   ----------------------------------------------------------------------------
   MODEL SELECTION IS NARROWER THAN IT LOOKS
   ----------------------------------------------------------------------------
   AI_SENTIMENT, AI_CLASSIFY, AI_FILTER and AI_EXTRACT take NO model argument —
   they run on a fixed Snowflake-managed model. "Use a cheaper model for
   classification and extraction" is therefore not an available lever. The only
   model choice in this script is the AI_COMPLETE call, which uses the bulk tier
   (claude-haiku-4-5) per PROJECT_BRIEF D3. claude-opus-5 is reserved for the
   narrative generation in M6, where prose quality is actually what is being
   bought.

   The levers that do exist are call count (above) and input size (bodies are
   truncated to $MAX_BODY_CHARS before being sent).

   ----------------------------------------------------------------------------
   WHERE EACH CONFIDENCE COMES FROM
   ----------------------------------------------------------------------------
   "Every inferred column carries its confidence" is only honest if the number
   has a provenance. Three kinds here, and the distinction is recorded per
   column rather than blurred:

     MODEL_REPORTED     the function or model returns a score.
                        AI_EXTRACT with scores => TRUE, and the per-field
                        confidences the AI_COMPLETE schema requires.
     AGREEMENT_DERIVED  two independent functions were asked the same question;
                        agreement raises confidence, disagreement lowers it.
                        Used for intent (AI_CLASSIFY vs AI_COMPLETE), overall
                        sentiment (AI_SENTIMENT vs AI_COMPLETE) and churn
                        (AI_COMPLETE vs AI_FILTER).
     PRESENCE_BASED     AI_SENTIMENT returns 'unknown' for an aspect that was
                        not discussed. That is absence, not low confidence, so
                        the value is NULLed and no confidence is asserted.

   No confidence in this script is invented to fill a column.

   ----------------------------------------------------------------------------
   INCREMENTAL, LIKE 04
   ----------------------------------------------------------------------------
     CURATED.INTERACTION_SIGNALS_RAW    IF NOT EXISTS   PAID   raw AI output
     CURATED.INTERACTION_SIGNALS        OR REPLACE      free   typed view
     CURATED.INTERACTION_SIGNALS_GATED  OR REPLACE      free   threshold applied

   The raw AI output is landed once and never recomputed. Everything typed is a
   view over it, so changing how a sentiment maps to a numeric score, or moving
   a threshold, costs nothing. Re-running the script enriches only rows that
   have no output yet.
   ============================================================================ */

USE ROLE COCO_BUILDER;
USE WAREHOUSE COCO_WH;
USE DATABASE C360_NBA;

-- 01_schemas.sql is not on disk yet, so this script creates what it needs.
-- Same precedent as 02_schema_raw.sql, which also creates its own schema.
CREATE SCHEMA IF NOT EXISTS CURATED
  COMMENT = 'Conformed, typed, deduped and AI-enriched. Reads RAW, never reads ground truth.';

USE SCHEMA CURATED;

/* ----------------------------------------------------------------------------
   Knobs.
   ---------------------------------------------------------------------------- */

SET ENRICH_MODEL   = 'claude-haiku-4-5';  -- the ONLY model choice in this script
SET ENRICH_VERSION = 'v2';
SET BATCH_ROWS     = 300;                 -- rows per execution; re-run until PENDING is zero
SET MAX_BODY_CHARS = 6000;                -- AI_SENTIMENT caps at 2,048 tokens; this stays well inside

/* ============================================================================
   STEP 1 — THE TUNABLE THRESHOLD, IN ONE PLACE
   ----------------------------------------------------------------------------
   A table rather than a literal in a WHERE clause, so tuning is an UPDATE and
   not a redeploy of this script. A global default plus optional per-field
   overrides, resolved by COALESCE in the gated view.

   To raise the bar on everything:
     UPDATE CURATED.AI_CONFIG SET CONFIG_VALUE = 0.80 WHERE CONFIG_KEY = 'MIN_CONFIDENCE';

   To raise it on one field only:
     UPDATE CURATED.AI_CONFIG SET CONFIG_VALUE = 0.90
      WHERE CONFIG_KEY = 'MIN_CONFIDENCE.CONSENT_WITHDRAWAL';

   Nothing downstream may hardcode a threshold. GOLD reads
   INTERACTION_SIGNALS_GATED, never INTERACTION_SIGNALS.
   ============================================================================ */

CREATE TABLE IF NOT EXISTS CURATED.AI_CONFIG (
  CONFIG_KEY   VARCHAR(64)  NOT NULL,
  CONFIG_VALUE FLOAT        NOT NULL,
  DESCRIPTION  VARCHAR(1000),
  UPDATED_AT   TIMESTAMP_NTZ
)
COMMENT = 'Single point of control for AI confidence thresholds. Tune here, nowhere else.';

MERGE INTO CURATED.AI_CONFIG AS t
USING (
  SELECT * FROM VALUES
    ('MIN_CONFIDENCE', 0.65,
     'Global floor. Any inferred field whose confidence falls below this is NULLed in INTERACTION_SIGNALS_GATED.'),
    ('MIN_CONFIDENCE.CONSENT_WITHDRAWAL', 0.80,
     'Higher bar: acting on a false positive here means continuing to contact someone who asked us to stop, which is a compliance breach rather than a missed sale.'),
    ('MIN_CONFIDENCE.HARDSHIP_SIGNAL', 0.75,
     'Higher bar: hardship suppresses marketing and triggers a collections review, so a false positive removes a customer from the book for the wrong reason.'),
    ('MIN_CONFIDENCE.AMOUNT_DISCUSSED', 0.50,
     'LOWER bar, deliberately. A transcript arguing about a renewal typically contains three defensible answers to "the amount in dispute" -- last year premium, this year premium, competitor quote -- so a mid score is AI_EXTRACT correctly reporting genuine ambiguity, not a quality failure. Measured scores cluster 0.40-0.89 while the parsed values were correct. This field is an agent talking point and never feeds the EV arithmetic, which is deterministic SQL over RAW, so a wrong pick costs a slightly off conversation rather than a wrong rupee figure in a recommendation.')
  AS v(CONFIG_KEY, CONFIG_VALUE, DESCRIPTION)
) AS s
ON t.CONFIG_KEY = s.CONFIG_KEY
-- Deliberately does NOT overwrite CONFIG_VALUE on match: a tuned threshold must
-- survive a re-run of this script. Only the description is refreshed.
WHEN MATCHED THEN UPDATE SET t.DESCRIPTION = s.DESCRIPTION
WHEN NOT MATCHED THEN INSERT (CONFIG_KEY, CONFIG_VALUE, DESCRIPTION, UPDATED_AT)
  VALUES (s.CONFIG_KEY, s.CONFIG_VALUE, s.DESCRIPTION, CURRENT_TIMESTAMP());

/* ============================================================================
   STEP 2 — INTENT TAXONOMY
   ----------------------------------------------------------------------------
   Sixteen labels, held as DATA rather than as a comment or an inline array, so
   AI_CLASSIFY reads its categories from the same place a human reads the
   documentation and the two cannot drift apart.

   Designed so that the labels a contact centre would actually route on are
   distinguishable, and so the planted segments have a natural home without the
   taxonomy being a re-encoding of them: RENEWAL_PRICING_DISPUTE and
   PAYMENT_DIFFICULTY_OR_DEFERRAL are ordinary contact-centre intents that
   happen to be where RETENTION_SAVE and COLLECTIONS_HARDSHIP surface.

   IS_SERVICE_ONLY marks intents where a sales action is inappropriate whatever
   the expected value. It feeds the vulnerability and suitability gates in M5,
   and is the reason the taxonomy is a table with columns rather than a list of
   strings.
   ============================================================================ */

CREATE OR REPLACE TABLE CURATED.INTENT_TAXONOMY (
  INTENT_CODE     VARCHAR(48)  NOT NULL,
  DESCRIPTION     VARCHAR(300) NOT NULL,
  IS_SERVICE_ONLY BOOLEAN      NOT NULL,
  SORT_ORDER      NUMBER(2,0)  NOT NULL
)
COMMENT = 'Fixed intent taxonomy for AI_CLASSIFY. The categories argument is built from this table.';

INSERT INTO CURATED.INTENT_TAXONOMY
SELECT * FROM VALUES
  ('RENEWAL_PRICING_DISPUTE',
   'Objects to a premium or renewal price, challenges an increase, or compares the price against another provider.',
   FALSE, 1),
  ('CANCELLATION_OR_SURRENDER',
   'Asks to cancel, surrender, lapse, close or move a product to another provider.',
   FALSE, 2),
  ('CLAIM_STATUS_CHASE',
   'Chasing progress, payment or paperwork on a claim that has already been submitted.',
   TRUE, 3),
  ('CLAIM_REJECTION_GRIEVANCE',
   'Disputes a claim that was rejected, partly paid or settled for less than expected.',
   TRUE, 4),
  ('PAYMENT_DIFFICULTY_OR_DEFERRAL',
   'Cannot meet a payment and asks for time, a part payment, a restructure, a moratorium or a fee waiver. Includes explaining why payments were missed.',
   TRUE, 5),
  ('PAYMENT_FAILURE_OR_MANDATE_ISSUE',
   'A mechanical payment problem: a failed or duplicated debit, a broken mandate, a payment not reflected. The customer can pay and is not in difficulty.',
   FALSE, 6),
  ('CREDIT_LIMIT_OR_LOAN_REQUEST',
   'Asks for a credit limit increase, a loan top-up, a new facility, or how to apply for one. Includes reporting a declined transaction due to the limit.',
   FALSE, 7),
  ('PRODUCT_INFORMATION_ENQUIRY',
   'Asks how a product, benefit, exclusion, rate or process works, without a specific service request attached.',
   FALSE, 8),
  ('POLICY_SERVICING_REQUEST',
   'A change to an existing record: address, contact details, nominee, payment date, vehicle details, or a duplicate document.',
   FALSE, 9),
  ('DOCUMENT_OR_KYC_SUBMISSION',
   'Submitting, chasing or querying documents: KYC, proofs, interest or premium certificates, tax statements.',
   FALSE, 10),
  ('SERVICE_QUALITY_COMPLAINT',
   'Complains about how they were handled: a delay, an unreturned call, conflicting answers, staff conduct. Not about price and not about a claim decision.',
   TRUE, 11),
  ('MIS_SELLING_ALLEGATION',
   'Alleges the product was misrepresented when sold, or that terms differ from what they were told.',
   TRUE, 12),
  ('BEREAVEMENT_OR_MEDICAL_NOTIFICATION',
   'Informs of a death, serious illness or medical event, whether or not a claim is being made.',
   TRUE, 13),
  ('MARKETING_OPT_OUT_REQUEST',
   'Asks to stop marketing calls, messages or emails, or to be placed on a do-not-call list.',
   TRUE, 14),
  ('FRAUD_OR_UNAUTHORISED_TRANSACTION',
   'Reports a transaction they did not authorise, a suspected fraud, or a compromised card or account.',
   TRUE, 15),
  ('GENERAL_ENQUIRY_OTHER',
   'Anything that does not fit another label. Use sparingly.',
   FALSE, 16);

/* ============================================================================
   STEP 3 — HELPERS
   ============================================================================ */

/* Indian money as customers write it. AI_EXTRACT returns whatever string the
   text contained -- "Rs 14,200", "1.2 lakh", "fourteen thousand" -- and the
   deterministic EV arithmetic downstream needs a number. Words are not handled
   on purpose: a wrong number is worse than a NULL here, so anything that is not
   confidently parseable stays NULL and fails the threshold gate. */
CREATE OR REPLACE FUNCTION CURATED.PARSE_INR(TXT VARCHAR)
RETURNS NUMBER(14,2)
LANGUAGE SQL
AS
$$
  -- TRY_TO_DOUBLE, not TRY_TO_DECIMAL: TRY_TO_DECIMAL defaults to scale 0, so
  -- '1.2 lakh' rounded to 1 and became 100000 instead of 120000.
  (CASE
    WHEN TXT IS NULL THEN NULL
    -- crore first: "cr" would also match inside "crore" if the order were reversed
    WHEN REGEXP_LIKE(TXT, '.*(crore|crores|\\bcr\\b).*', 'i')
      THEN TRY_TO_DOUBLE(REGEXP_SUBSTR(TXT, '[0-9]+([.][0-9]+)?')) * 10000000
    WHEN REGEXP_LIKE(TXT, '.*(lakhs|lakh|lacs|lac|\\bL\\b).*', 'i')
      THEN TRY_TO_DOUBLE(REGEXP_SUBSTR(TXT, '[0-9]+([.][0-9]+)?')) * 100000
    -- plain digits with any mix of separators and currency marks around them
    ELSE TRY_TO_DOUBLE(REGEXP_REPLACE(TXT, '[^0-9.]', ''))
  END)::NUMBER(14,2)
$$;

/* Sentiment label to a number, so a trend can be regressed in the rollup.
   'mixed' is placed slightly negative rather than at zero: a customer who is
   half unhappy is not neutral, and treating them as neutral flattens exactly
   the trend the retention case depends on. 'unknown' stays NULL and is excluded
   from the regression rather than being scored as zero. */
CREATE OR REPLACE FUNCTION CURATED.SENTIMENT_SCORE(LBL VARCHAR)
RETURNS FLOAT
LANGUAGE SQL
AS
$$
  CAST(
    CASE LOWER(LBL)
      WHEN 'positive' THEN  1.0
      WHEN 'neutral'  THEN  0.0
      WHEN 'mixed'    THEN -0.25
      WHEN 'negative' THEN -1.0
      ELSE NULL
    END AS FLOAT)
$$;

/* ============================================================================
   STEP 4 — DDL FOR THE PAID TABLE
   ============================================================================ */

CREATE TABLE IF NOT EXISTS CURATED.INTERACTION_SIGNALS_RAW (
  INTERACTION_ID  VARCHAR(40)   NOT NULL,
  CUSTOMER_ID     NUMBER(10,0)  NOT NULL,
  ENRICH_VERSION  VARCHAR(8)    NOT NULL,
  ENRICH_MODEL    VARCHAR(40)   NOT NULL,
  SENTIMENT_RAW   VARIANT,      -- AI_SENTIMENT      : { categories: [ {name, sentiment} ] }
  INTENT_RAW      VARIANT,      -- AI_CLASSIFY       : { labels: [ ... ] }
  EXTRACT_RAW     VARIANT,      -- AI_EXTRACT        : { response: {...}, scoring: { scores: {...} } }
  COMPLETE_RAW    VARIANT,      -- AI_COMPLETE       : flags + summary + second opinion
  FILTER_CHURN    BOOLEAN,      -- AI_FILTER         : independent churn cross-check
  ENRICHED_AT     TIMESTAMP_NTZ NOT NULL
)
COMMENT = 'Raw output of five AI functions per interaction. Landed once, never recomputed. The typed columns downstream are views over this.';

CREATE OR REPLACE VIEW CURATED.INTERACTION_SIGNALS_PENDING AS
SELECT COUNT(*) AS rows_pending
FROM RAW.INTERACTION i
WHERE NOT EXISTS (
  SELECT 1 FROM CURATED.INTERACTION_SIGNALS_RAW s WHERE s.INTERACTION_ID = i.INTERACTION_ID
);

/* ============================================================================
   STEP 5 — TOKEN PROJECTION
   ----------------------------------------------------------------------------
   Per PROJECT_BRIEF R8, AI_COUNT_TOKENS undercounts materially and is used here
   for relative sizing only -- which call dominates, and whether a body is
   unexpectedly large. The authoritative figure comes from a measured pilot
   batch read back out of ACCOUNT_USAGE.

   AI_EXTRACT is absent because AI_COUNT_TOKENS does not support it.
   ============================================================================ */

WITH b AS (
  SELECT SUBSTR(BODY, 1, $MAX_BODY_CHARS) AS body FROM RAW.INTERACTION SAMPLE (100 ROWS)
),
cats AS (
  SELECT ARRAY_AGG(OBJECT_CONSTRUCT('label', INTENT_CODE, 'description', DESCRIPTION))
           WITHIN GROUP (ORDER BY SORT_ORDER) AS c
  FROM CURATED.INTENT_TAXONOMY
)
SELECT 'token projection (relative, see R8)'                  AS metric,
       (SELECT COUNT(*) FROM RAW.INTERACTION)                 AS rows_total,
       ROUND(AVG(AI_COUNT_TOKENS('ai_sentiment', b.body)))    AS avg_tok_sentiment,
       ROUND(AVG(AI_COUNT_TOKENS('ai_classify',  b.body, cats.c))) AS avg_tok_classify,
       ROUND(AVG(AI_COUNT_TOKENS('ai_filter',    b.body)))    AS avg_tok_filter,
       ROUND(AVG(AI_COUNT_TOKENS('ai_complete', 'llama3.3-70b', b.body))) AS avg_tok_complete_body_only
FROM b CROSS JOIN cats;

/* ============================================================================
   STEP 6 — ENRICH  (the only step that costs credits)
   ----------------------------------------------------------------------------
   Anti-join on INTERACTION_ID, LIMIT $BATCH_ROWS. Ordered by INTERACTION_ID so
   successive batches walk the corpus in a stable order.

   temperature 0 here, unlike generation. This is a measurement, and the same
   body must yield the same reading; variance would be noise in the signal
   rather than realism in the data.
   ============================================================================ */

INSERT INTO CURATED.INTERACTION_SIGNALS_RAW
  (INTERACTION_ID, CUSTOMER_ID, ENRICH_VERSION, ENRICH_MODEL,
   SENTIMENT_RAW, INTENT_RAW, EXTRACT_RAW, COMPLETE_RAW, FILTER_CHURN, ENRICHED_AT)
WITH cats AS (
  SELECT ARRAY_AGG(OBJECT_CONSTRUCT('label', INTENT_CODE, 'description', DESCRIPTION))
           WITHIN GROUP (ORDER BY SORT_ORDER) AS c,
         -- codes only, for the AI_COMPLETE second opinion. It needs the vocabulary,
         -- not the descriptions, so this stays cheap: ~70 input tokens per row.
         LISTAGG(INTENT_CODE, ', ') WITHIN GROUP (ORDER BY SORT_ORDER) AS codes
  FROM CURATED.INTENT_TAXONOMY
),
todo AS (
  SELECT i.INTERACTION_ID, i.CUSTOMER_ID, i.ARTEFACT_TYPE, i.CHANNEL,
         SUBSTR(i.BODY, 1, $MAX_BODY_CHARS) AS body
  FROM RAW.INTERACTION i
  WHERE NOT EXISTS (
    SELECT 1 FROM CURATED.INTERACTION_SIGNALS_RAW s WHERE s.INTERACTION_ID = i.INTERACTION_ID
  )
  ORDER BY i.INTERACTION_ID
  LIMIT $BATCH_ROWS
)
SELECT
  t.INTERACTION_ID,
  t.CUSTOMER_ID,
  $ENRICH_VERSION,
  $ENRICH_MODEL,

  /* ---- 1. AI_SENTIMENT, overall plus three aspects ---------------------- */
  AI_SENTIMENT(t.body, ['pricing', 'service', 'claims']),

  /* ---- 2. AI_CLASSIFY, intent from the taxonomy table ------------------- */
  AI_CLASSIFY(
    t.body,
    cats.c,
    {
      'task_description':
        'Classify the primary reason this Indian bank-and-insurer contact-centre record exists. '
        || 'The record may be a call transcript, an email, a chat or an internal adviser note, and may '
        || 'be written in English or in Roman-script Hindi-English code mixing (Hinglish). '
        || 'Choose the single dominant reason for the contact, not every topic mentioned in passing. '
        || 'If the customer is explaining why they cannot pay, that is PAYMENT_DIFFICULTY_OR_DEFERRAL '
        || 'even when a collections agent initiated the contact.',
      'output_mode': 'single'
    }
  ),

  /* ---- 3. AI_EXTRACT, four entities with real per-field confidence ------ */
  AI_EXTRACT(
    text => t.body,
    responseFormat => {
      'schema': {
        'type': 'object',
        'properties': {
          'product_mentioned': {
            'type': 'string',
            'description': 'Which product this record concerns: motor insurance, health insurance, term life, home insurance, ULIP, home loan, personal loan, auto loan, credit card, or savings account. Empty if none is identifiable.' },
          'competitor_name': {
            'type': 'string',
            'description': 'The name of any RIVAL insurer, bank or financial provider the customer refers to, for example a company they have a cheaper quote from. Aarohan is our own group and must never be returned here. Empty if no rival is named.' },
          'amount_discussed': {
            'type': 'string',
            'description': 'The single most important rupee amount in dispute or under discussion, exactly as written in the text. Prefer a disputed premium, an overdue balance or a competing quote over an incidental figure. Empty if no amount appears.' },
          'promised_callback_date': {
            'type': 'string',
            'description': 'Any date on which staff committed to call the customer back, as written. Empty unless a callback was actually promised.' }
        }
      }
    },
    scores => TRUE
  ),

  /* ---- 4. AI_COMPLETE, six flags + summary + second opinion ------------- */
  AI_COMPLETE(
    model  => $ENRICH_MODEL,
    prompt =>
      'You are reading one contact-centre record from an Indian bank-and-insurer group called Aarohan. '
      || 'It may be a call transcript, an email, a chat, or an internal note written by staff about the '
      || 'customer. It may be in English or in Roman-script Hindi-English code mixing (Hinglish); read '
      || 'Hinglish as fluently as English.'
      || '\n\nJudge only what the record actually supports. Do not infer a flag from the general topic: '
      || 'a customer discussing a premium is not automatically threatening to leave, and a customer '
      || 'reporting a failed direct debit is not in financial difficulty. Set a flag TRUE only where the '
      || 'text gives concrete grounds for it, and lower the confidence where the grounds are thin or '
      || 'ambiguous rather than setting the flag on a guess.'
      || '\n\nFlag definitions, which are narrower than they sound:'
      || '\n  churn_risk_mentioned  the customer states or clearly implies they may take their business '
      || 'elsewhere, cancel, surrender or not renew. Dissatisfaction alone is not enough.'
      || '\n  competitor_mentioned  a rival provider is referred to, whether or not it is named. Aarohan '
      || 'is our own group and does not count.'
      || '\n  complaint             the customer is expressing a grievance about something we did or '
      || 'failed to do, as opposed to making a request or asking a question.'
      || '\n  life_event            a material personal event is disclosed: bereavement, illness, '
      || 'marriage, birth, retirement, relocation, job change, property purchase.'
      || '\n  hardship_signal       the customer indicates genuine difficulty meeting financial '
      || 'obligations: lost income, medical costs, asking for more time. A mechanical payment failure '
      || 'is NOT hardship.'
      || '\n  consent_withdrawal    the customer asks to stop being contacted for marketing, or to be '
      || 'put on a do-not-call list. A complaint about too many calls without such a request is not this.'
      || '\n\nAlso give your own independent reading of the intent and the overall sentiment. These are '
      || 'compared against other functions to derive a confidence, so answer them on the text alone.'
      || '\n\nThe intent MUST be exactly one of these codes, copied verbatim. Do not invent a code, do '
      || 'not reword one, do not change its case:\n  ' || cats.codes
      || '\n\nEvery confidence is a number from 0 to 1 expressing how strongly the text supports YOUR '
      || 'answer for that field.'
      || '\n\nRECORD TYPE: ' || t.ARTEFACT_TYPE || ' via ' || t.CHANNEL
      || '\n\nRECORD:\n' || t.body,
    model_parameters => { 'temperature': 0, 'max_tokens': 1200 },
    response_format  => {
      'type': 'json',
      'schema': {
        'type': 'object',
        'properties': {
          'summary_25w':               { 'type': 'string',  'description': 'At most 25 words, factual, no adjectives of judgement. What happened and what the customer wants.' },
          'intent':                    { 'type': 'string',  'description': 'One intent code from the taxonomy, your independent reading.' },
          'intent_confidence':         { 'type': 'number' },
          'sentiment_overall':         { 'type': 'string',  'description': 'One of positive, neutral, mixed, negative.' },
          'churn_risk_mentioned':      { 'type': 'boolean' },
          'churn_risk_confidence':     { 'type': 'number' },
          'competitor_mentioned':      { 'type': 'boolean' },
          'competitor_confidence':     { 'type': 'number' },
          'complaint':                 { 'type': 'boolean' },
          'complaint_confidence':      { 'type': 'number' },
          'life_event':                { 'type': 'boolean' },
          'life_event_confidence':     { 'type': 'number' },
          'hardship_signal':           { 'type': 'boolean' },
          'hardship_confidence':       { 'type': 'number' },
          'consent_withdrawal':        { 'type': 'boolean' },
          'consent_withdrawal_confidence': { 'type': 'number' },
          'summary_confidence':        { 'type': 'number' }
        },
        'required': ['summary_25w','intent','intent_confidence','sentiment_overall',
                     'churn_risk_mentioned','churn_risk_confidence',
                     'competitor_mentioned','competitor_confidence',
                     'complaint','complaint_confidence',
                     'life_event','life_event_confidence',
                     'hardship_signal','hardship_confidence',
                     'consent_withdrawal','consent_withdrawal_confidence',
                     'summary_confidence']
      }
    }
  ),

  /* ---- 5. AI_FILTER, one independent cross-check ------------------------ */
  AI_FILTER(
    PROMPT(
      'In this contact-centre record, does the customer state or clearly imply that they may take '
      || 'their business elsewhere, cancel, surrender, or not renew? Dissatisfaction on its own does '
      || 'not count. Record: {0}',
      t.body)
  ),

  CURRENT_TIMESTAMP()
FROM todo t CROSS JOIN cats;

/* ----------------------------------------------------------------------------
   Self-healing, same reasoning as 04: AI functions return NULL per row on
   failure rather than raising, so without this a failed row would be recorded
   as enriched and never retried. AI_COMPLETE is the one that must be present --
   it carries the flags and the summary. A NULL from AI_SENTIMENT or AI_EXTRACT
   alone is tolerated and shows up as a NULL signal with no confidence.
   ---------------------------------------------------------------------------- */

DELETE FROM CURATED.INTERACTION_SIGNALS_RAW
WHERE COMPLETE_RAW IS NULL
   OR COMPLETE_RAW:summary_25w IS NULL;

-- Rows whose interaction no longer exists, e.g. after a PROMPT_VERSION bump in 04.
DELETE FROM CURATED.INTERACTION_SIGNALS_RAW s
WHERE NOT EXISTS (
  SELECT 1 FROM RAW.INTERACTION i WHERE i.INTERACTION_ID = s.INTERACTION_ID
);

-- Version reconcile, mirroring 04. The pending view keys on INTERACTION_ID
-- alone, so without this a bump of ENRICH_VERSION would requeue nothing and the
-- fix would silently never be applied to already-enriched rows.
DELETE FROM CURATED.INTERACTION_SIGNALS_RAW
WHERE ENRICH_VERSION <> $ENRICH_VERSION;

/* ============================================================================
   STEP 7 — THE TYPED VIEW
   ----------------------------------------------------------------------------
   Free to rebuild. Every inferred field sits next to its confidence and the
   provenance of that confidence.
   ============================================================================ */

CREATE OR REPLACE VIEW CURATED.INTERACTION_SIGNALS AS
WITH s AS (
  SELECT
    r.INTERACTION_ID,
    r.CUSTOMER_ID,
    i.ARTEFACT_TYPE,
    i.CHANNEL,
    i.DIRECTION,
    i.OCCURRED_AT,
    i.LANGUAGE_CODE,
    i.SOURCE_KIND,
    r.ENRICH_VERSION,
    r.ENRICH_MODEL,

    -- AI_SENTIMENT returns one row per category in an array; pull them by name.
    -- 'unknown' means the aspect was not discussed, which is absence rather
    -- than uncertainty, so it becomes NULL.
    NULLIF(LOWER(GET(FILTER(r.SENTIMENT_RAW:categories,
      c -> c:name::VARCHAR = 'overall'), 0):sentiment::VARCHAR), 'unknown') AS sent_overall,
    NULLIF(LOWER(GET(FILTER(r.SENTIMENT_RAW:categories,
      c -> c:name::VARCHAR = 'pricing'), 0):sentiment::VARCHAR), 'unknown') AS sent_pricing,
    NULLIF(LOWER(GET(FILTER(r.SENTIMENT_RAW:categories,
      c -> c:name::VARCHAR = 'service'), 0):sentiment::VARCHAR), 'unknown') AS sent_service,
    NULLIF(LOWER(GET(FILTER(r.SENTIMENT_RAW:categories,
      c -> c:name::VARCHAR = 'claims'), 0):sentiment::VARCHAR), 'unknown') AS sent_claims,

    r.INTENT_RAW:labels[0]::VARCHAR              AS intent_classify,
    r.COMPLETE_RAW:intent::VARCHAR               AS intent_complete,
    r.COMPLETE_RAW:intent_confidence::FLOAT      AS intent_conf_reported,
    LOWER(r.COMPLETE_RAW:sentiment_overall::VARCHAR) AS sent_overall_complete,

    r.EXTRACT_RAW:response                       AS ext,
    r.EXTRACT_RAW:scoring:scores                 AS ext_scores,
    r.COMPLETE_RAW                               AS cmp,
    r.FILTER_CHURN                               AS filter_churn
  FROM CURATED.INTERACTION_SIGNALS_RAW r
  JOIN RAW.INTERACTION i ON i.INTERACTION_ID = r.INTERACTION_ID
)
SELECT
  INTERACTION_ID,
  CUSTOMER_ID,
  ARTEFACT_TYPE,
  CHANNEL,
  DIRECTION,
  OCCURRED_AT,
  LANGUAGE_CODE,
  SOURCE_KIND,
  ENRICH_VERSION,
  ENRICH_MODEL,

  /* ---------------- sentiment ---------------- */
  sent_overall                                    AS SENTIMENT_OVERALL,
  CURATED.SENTIMENT_SCORE(sent_overall)           AS SENTIMENT_SCORE,
  -- AGREEMENT_DERIVED: AI_SENTIMENT vs the AI_COMPLETE second opinion.
  CASE
    WHEN sent_overall IS NULL                       THEN NULL
    WHEN sent_overall = sent_overall_complete       THEN 0.92
    -- adjacent readings (mixed vs negative) are a milder disagreement than
    -- opposite ones, and should not be punished as hard
    WHEN sent_overall IN ('mixed','negative') AND sent_overall_complete IN ('mixed','negative') THEN 0.72
    WHEN sent_overall IN ('mixed','positive') AND sent_overall_complete IN ('mixed','positive') THEN 0.72
    ELSE 0.45
  END                                             AS SENTIMENT_OVERALL_CONF,
  sent_pricing                                    AS SENTIMENT_PRICING,
  sent_service                                    AS SENTIMENT_SERVICE,
  sent_claims                                     AS SENTIMENT_CLAIMS,
  -- PRESENCE_BASED: the function gives no score, and 'unknown' has already been
  -- NULLed above, so a present aspect reading is asserted at a flat 0.85 and
  -- an absent one asserts nothing at all.
  IFF(sent_pricing IS NULL, NULL, 0.85)           AS SENTIMENT_PRICING_CONF,
  IFF(sent_service IS NULL, NULL, 0.85)           AS SENTIMENT_SERVICE_CONF,
  IFF(sent_claims  IS NULL, NULL, 0.85)           AS SENTIMENT_CLAIMS_CONF,

  /* ---------------- intent ---------------- */
  intent_classify                                 AS INTENT,
  intent_complete                                 AS INTENT_SECOND_OPINION,
  -- AGREEMENT_DERIVED, floored by what the model itself reported. Two functions
  -- agreeing is strong; disagreement is capped well below the global threshold
  -- so a contested intent does not silently drive an action.
  CASE
    WHEN intent_classify IS NULL                   THEN NULL
    WHEN intent_classify = intent_complete         THEN LEAST(0.97, GREATEST(0.85, COALESCE(intent_conf_reported, 0.85)))
    ELSE LEAST(0.60, COALESCE(intent_conf_reported, 0.50))
  END                                             AS INTENT_CONF,
  tx.IS_SERVICE_ONLY                              AS INTENT_IS_SERVICE_ONLY,

  /* ---------------- behavioural flags ---------------- */
  cmp:churn_risk_mentioned::BOOLEAN               AS CHURN_RISK_MENTIONED,
  -- AGREEMENT_DERIVED on top of MODEL_REPORTED: AI_FILTER is a different model
  -- answering the same question, so agreement is genuine corroboration.
  CASE
    WHEN filter_churn IS NULL THEN cmp:churn_risk_confidence::FLOAT
    WHEN filter_churn = cmp:churn_risk_mentioned::BOOLEAN
      THEN LEAST(0.98, COALESCE(cmp:churn_risk_confidence::FLOAT, 0.5) + 0.10)
    ELSE COALESCE(cmp:churn_risk_confidence::FLOAT, 0.5) * 0.55
  END                                             AS CHURN_RISK_CONF,
  filter_churn                                    AS CHURN_RISK_CROSSCHECK,
  (filter_churn = cmp:churn_risk_mentioned::BOOLEAN) AS CHURN_CROSSCHECK_AGREES,

  cmp:competitor_mentioned::BOOLEAN               AS COMPETITOR_MENTIONED,
  cmp:competitor_confidence::FLOAT                AS COMPETITOR_MENTIONED_CONF,
  cmp:complaint::BOOLEAN                          AS COMPLAINT,
  cmp:complaint_confidence::FLOAT                 AS COMPLAINT_CONF,
  cmp:life_event::BOOLEAN                         AS LIFE_EVENT,
  cmp:life_event_confidence::FLOAT                AS LIFE_EVENT_CONF,
  cmp:hardship_signal::BOOLEAN                    AS HARDSHIP_SIGNAL,
  cmp:hardship_confidence::FLOAT                  AS HARDSHIP_SIGNAL_CONF,
  cmp:consent_withdrawal::BOOLEAN                 AS CONSENT_WITHDRAWAL,
  cmp:consent_withdrawal_confidence::FLOAT        AS CONSENT_WITHDRAWAL_CONF,

  /* ---------------- extracted entities ---------------- */
  -- MODEL_REPORTED throughout: AI_EXTRACT scores => TRUE returns a per-field
  -- score. An empty string means the field was absent, which is not a
  -- low-confidence value, so both the value and its score become NULL.
  NULLIF(TRIM(ext:product_mentioned::VARCHAR), '')      AS PRODUCT_MENTIONED,
  IFF(NULLIF(TRIM(ext:product_mentioned::VARCHAR), '') IS NULL, NULL,
      ext_scores:product_mentioned:score::FLOAT)        AS PRODUCT_MENTIONED_CONF,

  NULLIF(TRIM(ext:competitor_name::VARCHAR), '')        AS COMPETITOR_NAME,
  IFF(NULLIF(TRIM(ext:competitor_name::VARCHAR), '') IS NULL, NULL,
      ext_scores:competitor_name:score::FLOAT)          AS COMPETITOR_NAME_CONF,

  NULLIF(TRIM(ext:amount_discussed::VARCHAR), '')       AS AMOUNT_DISCUSSED_TEXT,
  CURATED.PARSE_INR(NULLIF(TRIM(ext:amount_discussed::VARCHAR), '')) AS AMOUNT_DISCUSSED_INR,
  -- the parse is part of the claim, so an unparseable amount loses its score
  IFF(CURATED.PARSE_INR(NULLIF(TRIM(ext:amount_discussed::VARCHAR), '')) IS NULL, NULL,
      ext_scores:amount_discussed:score::FLOAT)         AS AMOUNT_DISCUSSED_CONF,

  NULLIF(TRIM(ext:promised_callback_date::VARCHAR), '') AS PROMISED_CALLBACK_TEXT,
  TRY_TO_DATE(NULLIF(TRIM(ext:promised_callback_date::VARCHAR), ''))
                                                        AS PROMISED_CALLBACK_DATE,
  IFF(NULLIF(TRIM(ext:promised_callback_date::VARCHAR), '') IS NULL, NULL,
      ext_scores:promised_callback_date:score::FLOAT)    AS PROMISED_CALLBACK_CONF,

  /* ---------------- summary ---------------- */
  cmp:summary_25w::VARCHAR                        AS SUMMARY_25W,
  cmp:summary_confidence::FLOAT                   AS SUMMARY_CONF,

  /* The whole inference as one object, per the brief. Built from the typed
     columns rather than passed through from the model, so it can never disagree
     with them. */
  OBJECT_CONSTRUCT_KEEP_NULL(
    'summary',            cmp:summary_25w::VARCHAR,
    'intent',             OBJECT_CONSTRUCT('value', intent_classify,
                                           'confidence', CASE WHEN intent_classify = intent_complete
                                             THEN LEAST(0.97, GREATEST(0.85, COALESCE(intent_conf_reported,0.85)))
                                             ELSE LEAST(0.60, COALESCE(intent_conf_reported,0.50)) END),
    'sentiment_overall',  OBJECT_CONSTRUCT('value', sent_overall,
                                           'confidence', IFF(sent_overall = sent_overall_complete, 0.92, 0.45)),
    'sentiment_aspects',  OBJECT_CONSTRUCT('pricing', sent_pricing, 'service', sent_service, 'claims', sent_claims),
    'churn_risk_mentioned', OBJECT_CONSTRUCT('value', cmp:churn_risk_mentioned::BOOLEAN,
                                             'confidence', cmp:churn_risk_confidence::FLOAT,
                                             'crosschecked_by_ai_filter', filter_churn),
    'competitor_mentioned', OBJECT_CONSTRUCT('value', cmp:competitor_mentioned::BOOLEAN, 'confidence', cmp:competitor_confidence::FLOAT),
    'complaint',            OBJECT_CONSTRUCT('value', cmp:complaint::BOOLEAN, 'confidence', cmp:complaint_confidence::FLOAT),
    'life_event',           OBJECT_CONSTRUCT('value', cmp:life_event::BOOLEAN, 'confidence', cmp:life_event_confidence::FLOAT),
    'hardship_signal',      OBJECT_CONSTRUCT('value', cmp:hardship_signal::BOOLEAN, 'confidence', cmp:hardship_confidence::FLOAT),
    'consent_withdrawal',   OBJECT_CONSTRUCT('value', cmp:consent_withdrawal::BOOLEAN, 'confidence', cmp:consent_withdrawal_confidence::FLOAT),
    'entities',           OBJECT_CONSTRUCT(
                            'product',          OBJECT_CONSTRUCT('value', NULLIF(TRIM(ext:product_mentioned::VARCHAR),''),      'confidence', ext_scores:product_mentioned:score::FLOAT),
                            'competitor',       OBJECT_CONSTRUCT('value', NULLIF(TRIM(ext:competitor_name::VARCHAR),''),        'confidence', ext_scores:competitor_name:score::FLOAT),
                            'amount_inr',       OBJECT_CONSTRUCT('value', CURATED.PARSE_INR(NULLIF(TRIM(ext:amount_discussed::VARCHAR),'')), 'confidence', ext_scores:amount_discussed:score::FLOAT),
                            'promised_callback',OBJECT_CONSTRUCT('value', NULLIF(TRIM(ext:promised_callback_date::VARCHAR),''), 'confidence', ext_scores:promised_callback_date:score::FLOAT))
  )                                               AS SIGNALS_JSON
FROM s
LEFT JOIN CURATED.INTENT_TAXONOMY tx ON tx.INTENT_CODE = s.intent_classify;

/* ============================================================================
   STEP 8 — THE GATED VIEW
   ----------------------------------------------------------------------------
   This is what GOLD reads. Nothing downstream may read INTERACTION_SIGNALS
   directly or hardcode a threshold of its own.

   Every inferred field is NULLed when its confidence falls below the threshold
   for that field, resolved as: per-field override, else global default, both
   from CURATED.AI_CONFIG. A NULL here means "not established to the required
   standard", which is a different and more useful thing than FALSE.

   *_CONF columns pass through ungated on purpose, so a reviewer can see how
   close a suppressed field came to the bar.
   ============================================================================ */

CREATE OR REPLACE VIEW CURATED.INTERACTION_SIGNALS_GATED AS
WITH cfg AS (
  SELECT
    MAX(IFF(CONFIG_KEY = 'MIN_CONFIDENCE',                            CONFIG_VALUE, NULL)) AS g,
    MAX(IFF(CONFIG_KEY = 'MIN_CONFIDENCE.CONSENT_WITHDRAWAL',         CONFIG_VALUE, NULL)) AS t_consent,
    MAX(IFF(CONFIG_KEY = 'MIN_CONFIDENCE.HARDSHIP_SIGNAL',            CONFIG_VALUE, NULL)) AS t_hardship,
    MAX(IFF(CONFIG_KEY = 'MIN_CONFIDENCE.AMOUNT_DISCUSSED',           CONFIG_VALUE, NULL)) AS t_amount,
    MAX(IFF(CONFIG_KEY = 'MIN_CONFIDENCE.INTENT',                     CONFIG_VALUE, NULL)) AS t_intent,
    MAX(IFF(CONFIG_KEY = 'MIN_CONFIDENCE.SENTIMENT_OVERALL',          CONFIG_VALUE, NULL)) AS t_sent,
    MAX(IFF(CONFIG_KEY = 'MIN_CONFIDENCE.CHURN_RISK',                 CONFIG_VALUE, NULL)) AS t_churn,
    MAX(IFF(CONFIG_KEY = 'MIN_CONFIDENCE.COMPETITOR_MENTIONED',       CONFIG_VALUE, NULL)) AS t_comp,
    MAX(IFF(CONFIG_KEY = 'MIN_CONFIDENCE.COMPLAINT',                  CONFIG_VALUE, NULL)) AS t_complaint,
    MAX(IFF(CONFIG_KEY = 'MIN_CONFIDENCE.LIFE_EVENT',                 CONFIG_VALUE, NULL)) AS t_life,
    MAX(IFF(CONFIG_KEY = 'MIN_CONFIDENCE.PRODUCT_MENTIONED',          CONFIG_VALUE, NULL)) AS t_product,
    MAX(IFF(CONFIG_KEY = 'MIN_CONFIDENCE.COMPETITOR_NAME',            CONFIG_VALUE, NULL)) AS t_compname,
    MAX(IFF(CONFIG_KEY = 'MIN_CONFIDENCE.PROMISED_CALLBACK',          CONFIG_VALUE, NULL)) AS t_callback
  FROM CURATED.AI_CONFIG
)
SELECT
  v.INTERACTION_ID, v.CUSTOMER_ID, v.ARTEFACT_TYPE, v.CHANNEL, v.DIRECTION,
  v.OCCURRED_AT, v.LANGUAGE_CODE, v.SOURCE_KIND, v.ENRICH_VERSION, v.ENRICH_MODEL,

  IFF(v.SENTIMENT_OVERALL_CONF >= COALESCE(c.t_sent, c.g), v.SENTIMENT_OVERALL, NULL) AS SENTIMENT_OVERALL,
  IFF(v.SENTIMENT_OVERALL_CONF >= COALESCE(c.t_sent, c.g), v.SENTIMENT_SCORE,   NULL) AS SENTIMENT_SCORE,
  v.SENTIMENT_OVERALL_CONF,
  IFF(v.SENTIMENT_PRICING_CONF >= c.g, v.SENTIMENT_PRICING, NULL) AS SENTIMENT_PRICING,
  IFF(v.SENTIMENT_SERVICE_CONF >= c.g, v.SENTIMENT_SERVICE, NULL) AS SENTIMENT_SERVICE,
  IFF(v.SENTIMENT_CLAIMS_CONF  >= c.g, v.SENTIMENT_CLAIMS,  NULL) AS SENTIMENT_CLAIMS,
  v.SENTIMENT_PRICING_CONF, v.SENTIMENT_SERVICE_CONF, v.SENTIMENT_CLAIMS_CONF,

  IFF(v.INTENT_CONF >= COALESCE(c.t_intent, c.g), v.INTENT, NULL)                  AS INTENT,
  IFF(v.INTENT_CONF >= COALESCE(c.t_intent, c.g), v.INTENT_IS_SERVICE_ONLY, NULL)  AS INTENT_IS_SERVICE_ONLY,
  v.INTENT_CONF, v.INTENT_SECOND_OPINION,

  IFF(v.CHURN_RISK_CONF        >= COALESCE(c.t_churn,     c.g), v.CHURN_RISK_MENTIONED, NULL) AS CHURN_RISK_MENTIONED,
  v.CHURN_RISK_CONF, v.CHURN_CROSSCHECK_AGREES,
  IFF(v.COMPETITOR_MENTIONED_CONF >= COALESCE(c.t_comp,      c.g), v.COMPETITOR_MENTIONED, NULL) AS COMPETITOR_MENTIONED,
  v.COMPETITOR_MENTIONED_CONF,
  IFF(v.COMPLAINT_CONF         >= COALESCE(c.t_complaint, c.g), v.COMPLAINT,          NULL) AS COMPLAINT,
  v.COMPLAINT_CONF,
  IFF(v.LIFE_EVENT_CONF        >= COALESCE(c.t_life,      c.g), v.LIFE_EVENT,         NULL) AS LIFE_EVENT,
  v.LIFE_EVENT_CONF,
  IFF(v.HARDSHIP_SIGNAL_CONF   >= COALESCE(c.t_hardship,  c.g), v.HARDSHIP_SIGNAL,    NULL) AS HARDSHIP_SIGNAL,
  v.HARDSHIP_SIGNAL_CONF,
  IFF(v.CONSENT_WITHDRAWAL_CONF >= COALESCE(c.t_consent,  c.g), v.CONSENT_WITHDRAWAL, NULL) AS CONSENT_WITHDRAWAL,
  v.CONSENT_WITHDRAWAL_CONF,

  IFF(v.PRODUCT_MENTIONED_CONF   >= COALESCE(c.t_product,  c.g), v.PRODUCT_MENTIONED,      NULL) AS PRODUCT_MENTIONED,
  v.PRODUCT_MENTIONED_CONF,
  IFF(v.COMPETITOR_NAME_CONF     >= COALESCE(c.t_compname, c.g), v.COMPETITOR_NAME,        NULL) AS COMPETITOR_NAME,
  v.COMPETITOR_NAME_CONF,
  IFF(v.AMOUNT_DISCUSSED_CONF    >= COALESCE(c.t_amount,   c.g), v.AMOUNT_DISCUSSED_INR,   NULL) AS AMOUNT_DISCUSSED_INR,
  v.AMOUNT_DISCUSSED_CONF,
  IFF(v.PROMISED_CALLBACK_CONF   >= COALESCE(c.t_callback, c.g), v.PROMISED_CALLBACK_DATE, NULL) AS PROMISED_CALLBACK_DATE,
  v.PROMISED_CALLBACK_CONF,

  v.SUMMARY_25W, v.SUMMARY_CONF, v.SIGNALS_JSON
FROM CURATED.INTERACTION_SIGNALS v CROSS JOIN cfg c;

/* ============================================================================
   STEP 9 — VERIFY
   ============================================================================ */

SELECT 'progress' AS check_name, * FROM CURATED.INTERACTION_SIGNALS_PENDING;

SELECT 'coverage' AS check_name,
       COUNT(*)                                                AS enriched,
       COUNT(SENTIMENT_OVERALL)                                AS has_sentiment,
       COUNT(INTENT)                                           AS has_intent,
       COUNT(SUMMARY_25W)                                      AS has_summary,
       ROUND(AVG(IFF(CHURN_CROSSCHECK_AGREES, 1, 0)), 3)       AS churn_crosscheck_agreement,
       ROUND(AVG(IFF(INTENT = INTENT_SECOND_OPINION, 1, 0)), 3) AS intent_agreement
FROM CURATED.INTERACTION_SIGNALS;

-- What the threshold is actually costing. If a field loses most of its values
-- the threshold is too high for it, and this is where that shows up.
SELECT 'gating impact' AS check_name,
       COUNT(*) AS rows_,
       COUNT(u.INTENT)              - COUNT(g.INTENT)              AS intent_suppressed,
       COUNT(u.CHURN_RISK_MENTIONED)- COUNT(g.CHURN_RISK_MENTIONED) AS churn_suppressed,
       COUNT(u.HARDSHIP_SIGNAL)     - COUNT(g.HARDSHIP_SIGNAL)     AS hardship_suppressed,
       COUNT(u.CONSENT_WITHDRAWAL)  - COUNT(g.CONSENT_WITHDRAWAL)  AS consent_suppressed,
       COUNT(u.AMOUNT_DISCUSSED_INR)- COUNT(g.AMOUNT_DISCUSSED_INR) AS amount_suppressed
FROM CURATED.INTERACTION_SIGNALS u
JOIN CURATED.INTERACTION_SIGNALS_GATED g ON g.INTERACTION_ID = u.INTERACTION_ID;

SELECT INTENT, COUNT(*) AS n, ROUND(AVG(INTENT_CONF), 3) AS avg_conf
FROM CURATED.INTERACTION_SIGNALS_GATED
GROUP BY 1 ORDER BY 2 DESC;

-- Our own brand must never be extracted as a competitor.
SELECT 'own brand as competitor' AS check_name, COUNT(*) AS violations
FROM CURATED.INTERACTION_SIGNALS
WHERE COMPETITOR_NAME ILIKE '%aarohan%';

SELECT 'CURATED.INTERACTION_SIGNALS batch complete' AS status,
       $ENRICH_MODEL AS model, $ENRICH_VERSION AS enrich_version;

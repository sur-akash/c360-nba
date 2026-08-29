/* ============================================================================
   04_seed_interactions.sql  —  RAW.INTERACTION, the unstructured silo
   ----------------------------------------------------------------------------
   Generates 1,200 contact-centre artefacts with AI_COMPLETE across four types
   (CALL_TRANSCRIPT / EMAIL / CHAT / ADVISER_NOTE), each one CONDITIONED on the
   planted segment its customer belongs to (docs/DATA_SEGMENTS.md) but never
   LABELLED with it. The downstream pipeline (05_curated_signals.sql) has to
   infer the segment from behaviour, which is the whole point of the exercise.

   ----------------------------------------------------------------------------
   THREE TABLES, AND WHY
   ----------------------------------------------------------------------------
   The LLM output is the only expensive thing in this script, so it is landed in
   its own permanent table the moment it is produced and never regenerated.

     RAW.INTERACTION_GEN_PLAN   CREATE OR REPLACE   free   deterministic SQL:
                                                           who, when, what type,
                                                           and the built prompt
     RAW.INTERACTION_GEN_RAW    IF NOT EXISTS       PAID   raw AI_COMPLETE JSON,
                                                           one row per thread
     RAW.INTERACTION            IF NOT EXISTS       free   flattened artefacts,
                                                           one row per artefact

   Re-running this script is safe and cheap. GEN_RAW is filled by an anti-join
   against itself, so a thread that already has output is skipped, never
   regenerated. The plan and the flatten are pure SQL and can be rebuilt for
   nothing. If a prompt needs changing, bump PROMPT_VERSION: rows carrying the
   old version stay put and only the new ones are generated.

   ----------------------------------------------------------------------------
   BATCHING
   ----------------------------------------------------------------------------
   $BATCH_THREADS caps how many threads one execution will generate. Run the
   script repeatedly until RAW.INTERACTION_GEN_PENDING reports zero. The default
   is deliberately small; the full run is one deliberate execution with the
   batch raised, not something that happens by accident.

   ----------------------------------------------------------------------------
   GENERATION UNIT IS A THREAD, NOT AN ARTEFACT
   ----------------------------------------------------------------------------
   One AI_COMPLETE call per customer returns all 1-3 of that customer's
   artefacts. 594 calls, not 1,200. Two reasons, both of which matter:

     Cost      the instruction block is ~600 tokens and would otherwise be
               re-sent for every artefact.
     Realism   a renewal-at-risk customer emails, then rings up a week later
               about the same unresolved thing, and the second artefact refers
               back to the first. Independent calls cannot do that.

   Everything except the prose is decided in SQL — who, when, which channel,
   which language, which slot comes first. The model is handed a numbered list
   of writing assignments and returns prose per slot number. That keeps dates
   consistent with the planted SERVICE_TICKET window, keeps the type and
   language mix exact rather than approximate, and makes the flatten a join on
   slot_no instead of a guess.
   ============================================================================ */

USE ROLE COCO_BUILDER;
USE WAREHOUSE COCO_WH;
USE DATABASE C360_NBA;
USE SCHEMA RAW;

/* ----------------------------------------------------------------------------
   Knobs. Everything tunable about this script is in this block.
   ---------------------------------------------------------------------------- */

SET GEN_MODEL      = 'claude-haiku-4-5';  -- bulk tier per PROJECT_BRIEF D3
SET PROMPT_VERSION = 'v2';                -- bump to regenerate under a new prompt
SET BATCH_THREADS  = 200;                 -- threads per execution; re-run until PENDING is zero

-- The group needs a name, or the model invents one per artefact and the corpus
-- reads like it came from four different companies.
SET BRAND = 'Aarohan';

/* ----------------------------------------------------------------------------
   Guard. Mumbai hosts no text-generation model, so every call here leaves the
   region and the whole script depends on CORTEX_ENABLED_CROSS_REGION (brief
   R1). COCO_BUILDER cannot read account parameters, so the guard is a live
   one-token call instead: if cross-region inference is off, this fails here
   with a clear error rather than 594 rows into the generation step.
   ---------------------------------------------------------------------------- */

SELECT AI_COMPLETE($GEN_MODEL, 'Reply with the single word: ok') AS cross_region_guard;

/* ============================================================================
   STEP 0 — THE LEAKAGE RULE, AS AN ENFORCED PREDICATE
   ----------------------------------------------------------------------------
   The load-bearing constraint on this corpus is that no artefact may state the
   classification the pipeline is supposed to infer. A note reading "high risk
   churn, retention team to call" hands 05_curated_signals.sql the answer, and
   any accuracy measured against it is worthless.

   Measured at 1,200 artefacts, claude-haiku-4-5 obeys the prompt-level ban
   roughly 99.9% of the time. That residual is why this is a function used by the
   loader to REQUEUE offending threads, not a report printed at the end and
   scrolled past. A rule that has to hold is enforced; a rule that is merely
   observed drifts.

   WHAT IS DELIBERATELY ALLOWED, and why a naive keyword check is wrong. The
   first version of this check flagged 42 artefacts, of which 41 were correct
   contact-centre English:

     "escalate this to our retention team"      an organisational unit. Indian
                                               insurers genuinely have retention
                                               desks; agents say this.
     "your account is at risk of legal action"  a specific stated consequence.
     "claims history in the segment"            underwriting language for a
                                               rating segment, unrelated to
                                               RAW.CUSTOMER_SEGMENT_TRUTH.

   None of those tells a downstream model what the customer IS. The violation is
   narrower and specific: a CLASSIFICATION ASSERTED ABOUT THE CUSTOMER. So the
   patterns below target that construction rather than the vocabulary around it.
   ============================================================================ */

CREATE OR REPLACE FUNCTION RAW.HAS_SEGMENT_LEAK(BODY VARCHAR)
RETURNS BOOLEAN
LANGUAGE SQL
AS
$$
  REGEXP_LIKE(BODY,
    '.*(' ||
    -- no innocuous use of these exists in a customer-service record
    'churn|propensity|' ||
    -- a category or score asserted about the person
    'at.?risk customer|risk customer|at.?risk client|' ||
    'retention risk|retention case|retention candidate|flight risk|lapse risk|' ||
    'vulnerable customer|vulnerable client|vulnerability (flag|marker|status)|' ||
    'hardship case|hardship flag|collections case|' ||
    'customer segment|segment code|segment_code|' ||
    '(risk|propensity|churn|lapse) score|' ||
    'high.?value customer|priority segment' ||
    ').*', 'is')
$$;

/* ============================================================================
   STEP 1 — DDL
   ============================================================================ */

CREATE OR REPLACE TABLE RAW.INTERACTION_GEN_PLAN (
  PLAN_KEY        VARCHAR(64)   NOT NULL,   -- customer + prompt version
  CUSTOMER_ID     NUMBER(10,0)  NOT NULL,
  SEGMENT_CODE    VARCHAR(32)   NOT NULL,   -- conditioning input, NOT persisted to INTERACTION
  N_ARTEFACTS     NUMBER(2,0)   NOT NULL,
  SLOT_SPEC       VARIANT       NOT NULL,   -- array of per-slot assignments
  PROMPT          VARCHAR       NOT NULL,
  PROMPT_VERSION  VARCHAR(8)    NOT NULL,
  LOAD_TS         TIMESTAMP_NTZ NOT NULL
)
COMMENT = 'One row per customer thread to be generated. Pure SQL, no AI, free to rebuild.';

-- IF NOT EXISTS, not OR REPLACE. This table holds paid-for output.
CREATE TABLE IF NOT EXISTS RAW.INTERACTION_GEN_RAW (
  PLAN_KEY        VARCHAR(64)   NOT NULL,
  CUSTOMER_ID     NUMBER(10,0)  NOT NULL,
  PROMPT_VERSION  VARCHAR(8)    NOT NULL,
  GEN_MODEL       VARCHAR(40)   NOT NULL,
  RESPONSE        VARIANT,                  -- { "artefacts": [ { slot_no, subject, body } ] }
  GENERATED_AT    TIMESTAMP_NTZ NOT NULL
)
COMMENT = 'Raw AI_COMPLETE output, landed immediately. Never regenerated for an existing PLAN_KEY.';

-- Also IF NOT EXISTS: 06_audio_demo.sql appends transcribed audio to this same
-- table, and rebuilding it here would silently delete those rows.
CREATE TABLE IF NOT EXISTS RAW.INTERACTION (
  INTERACTION_ID  VARCHAR(40)   NOT NULL,
  CUSTOMER_ID     NUMBER(10,0)  NOT NULL,
  ARTEFACT_TYPE   VARCHAR(20)   NOT NULL,   -- CALL_TRANSCRIPT/EMAIL/CHAT/ADVISER_NOTE
  CHANNEL         VARCHAR(16)   NOT NULL,   -- CALL/EMAIL/WHATSAPP/APP_CHAT/BRANCH
  DIRECTION       VARCHAR(10)   NOT NULL,   -- INBOUND/OUTBOUND/INTERNAL
  OCCURRED_AT     TIMESTAMP_NTZ NOT NULL,
  LANGUAGE_CODE   VARCHAR(10)   NOT NULL,   -- EN/HINGLISH
  SUBJECT         VARCHAR(300),
  BODY            VARCHAR(16777216) NOT NULL,
  SOURCE_KIND     VARCHAR(12)   NOT NULL,   -- TEXT (here) / AUDIO (06_audio_demo)
  SOURCE_REF      VARCHAR(200),             -- audio filename, else NULL
  BODY_CHARS      NUMBER(8,0),
  LOAD_TS         TIMESTAMP_NTZ NOT NULL
)
COMMENT = 'Unstructured contact-centre artefacts, one row per artefact. Text and transcribed audio share this grain deliberately.';

/* ============================================================================
   STEP 2 — COHORT SELECTION
   ----------------------------------------------------------------------------
   Exact quotas, not approximate, matching the convention in DATA_SEGMENTS.md
   section 2. ROW_NUMBER over a deterministic pseudorandom ordering, then a
   slice, then a fixed high/low split of artefact counts:

     segment                customers   split           artefacts
     RETENTION_SAVE               200   100x3 + 100x2         500
     COLLECTIONS_HARDSHIP         110    55x3 +  55x2         275
     NONE                         129    65x2 +  64x1         194
     LIMIT_INCREASE                55    27x2 +  28x1          82
     PROTECTION_GAP                55    27x2 +  28x1          82
     WEALTH_REFERRAL               45    22x2 +  23x1          67
     total                        594                       1,200

   The weighting is not proportional to the segment sizes, and should not be.
   RETENTION_SAVE and COLLECTIONS_HARDSHIP carry the richest text signal, so
   they get the volume. The 129 NONE customers are there as negatives: without
   them the enrichment layer can score perfect recall while flagging everybody,
   and precision would be unmeasurable.

   FORCED OVERLAP ON VULNERABILITY. Proportional selection would put only ~11
   of the 100 VULNERABLE_CROSSSELL customers in the corpus, which is far too
   thin to test a guardrail. The ordering therefore puts vulnerable customers
   first within their segment, so all 40 in PROTECTION_GAP and all 60 in NONE
   are selected. The guardrail cohort is precisely the population the
   vulnerability signal has to be legible on. Same reasoning, and same
   mechanism, as the suppression overlap in DATA_SEGMENTS.md section 5.

   Suppression overlap is left to fall out naturally (~55 threads); the DNC
   half of it is what carries opt-out language, so consent_withdrawal has real
   positives without being forced.
   ============================================================================ */

CREATE OR REPLACE TEMPORARY TABLE RAW.TMP_QUOTA AS
SELECT * FROM VALUES
  ('RETENTION_SAVE',       200, 100, 3, 2),
  ('COLLECTIONS_HARDSHIP', 110,  55, 3, 2),
  ('NONE',                 129,  65, 2, 1),
  ('LIMIT_INCREASE',        55,  27, 2, 1),
  ('PROTECTION_GAP',        55,  27, 2, 1),
  ('WEALTH_REFERRAL',       45,  22, 2, 1)
AS q(SEGMENT_CODE, N_CUST, N_HIGH, HIGH_ARTEFACTS, LOW_ARTEFACTS);

/* ============================================================================
   STEP 3 — PER-CUSTOMER FACTS
   ----------------------------------------------------------------------------
   Real values from the structured silos, so the prose is grounded in the same
   numbers the deterministic EV arithmetic will later use. A transcript that
   argues about a premium of Rs 10,800 when RAW.POLICY says 10,800 is evidence;
   one that invents a figure is not.

   Two fabricated-but-persisted details: LAST_YEAR_PREMIUM_INR (derived from a
   deterministic 18-42% hike) and COMPETITOR, because the renewal complaint
   needs a concrete "up from what, and cheaper where". Both are stored in the
   plan table so they are auditable and reproducible rather than invented inside
   a prompt.
   ============================================================================ */

CREATE OR REPLACE TEMPORARY TABLE RAW.TMP_FACTS AS
WITH sel AS (
  SELECT t.CUSTOMER_ID,
         t.SEGMENT_CODE,
         t.IS_SUPPRESSED_OVERLAY,
         t.SUPPRESSION_KIND,
         t.IS_VULNERABLE_CROSSSELL,
         ROW_NUMBER() OVER (
           PARTITION BY t.SEGMENT_CODE
           ORDER BY t.IS_VULNERABLE_CROSSSELL DESC,     -- forced overlap, see step 2
                    RAW.RND('ixsel|' || t.CUSTOMER_ID)
         ) AS rn
  FROM RAW.CUSTOMER_SEGMENT_TRUTH t
),
picked AS (
  SELECT s.*,
         IFF(s.rn <= q.N_HIGH, q.HIGH_ARTEFACTS, q.LOW_ARTEFACTS) AS n_artefacts
  FROM sel s
  JOIN RAW.TMP_QUOTA q ON q.SEGMENT_CODE = s.SEGMENT_CODE
  WHERE s.rn <= q.N_CUST
),
-- the renewing policy that defines RETENTION_SAVE
renewal AS (
  SELECT CUSTOMER_ID, POLICY_TYPE, PREMIUM_INR, RENEWAL_DATE, SUM_ASSURED_INR,
         ROW_NUMBER() OVER (PARTITION BY CUSTOMER_ID ORDER BY RENEWAL_DATE, POLICY_ID) AS rn
  FROM RAW.POLICY
  WHERE STATUS = 'ACTIVE'
    AND RENEWAL_DATE BETWEEN RAW.AS_OF() AND DATEADD(day, 30, RAW.AS_OF())
),
-- the planted complaint, for date anchoring and topic context
ticket AS (
  SELECT CUSTOMER_ID, CATEGORY, SUB_CATEGORY, SEVERITY, OPENED_AT,
         ROW_NUMBER() OVER (PARTITION BY CUSTOMER_ID ORDER BY OPENED_AT DESC) AS rn
  FROM RAW.SERVICE_TICKET
  WHERE IS_COMPLAINT
    AND OPENED_AT >= DATEADD(day, -60, RAW.AS_OF())
),
loan AS (
  SELECT CUSTOMER_ID, LOAN_TYPE, EMI_INR, PRINCIPAL_INR, OUTSTANDING_INR, DPD_DAYS,
         ROW_NUMBER() OVER (PARTITION BY CUSTOMER_ID ORDER BY DPD_DAYS DESC, LOAN_ID) AS rn
  FROM RAW.LOAN
  WHERE STATUS = 'ACTIVE'
),
homeloan AS (
  SELECT CUSTOMER_ID, PRINCIPAL_INR, OUTSTANDING_INR, EMI_INR,
         ROW_NUMBER() OVER (PARTITION BY CUSTOMER_ID ORDER BY LOAN_ID) AS rn
  FROM RAW.LOAN
  WHERE STATUS = 'ACTIVE' AND LOAN_TYPE = 'HOME'
),
card AS (
  SELECT CUSTOMER_ID, CARD_TIER, CREDIT_LIMIT_INR, UTILISATION_PCT, TOP_MCC_GROUP,
         ROW_NUMBER() OVER (PARTITION BY CUSTOMER_ID ORDER BY CREDIT_LIMIT_INR DESC, CARD_ID) AS rn
  FROM RAW.CARD
  WHERE STATUS = 'ACTIVE'
),
lumpsum AS (
  SELECT CUSTOMER_ID, AMOUNT_INR, MCC_GROUP, TXN_DATE,
         ROW_NUMBER() OVER (PARTITION BY CUSTOMER_ID ORDER BY AMOUNT_INR DESC) AS rn
  FROM RAW.TXN
  WHERE IS_INBOUND_LUMPSUM
),
missed AS (
  SELECT CUSTOMER_ID, COUNT(*) AS n_missed
  FROM RAW.REPAYMENT
  WHERE MISSED_FLAG AND DUE_DATE >= DATEADD(month, -6, RAW.AS_OF())
  GROUP BY CUSTOMER_ID
)
SELECT
  p.CUSTOMER_ID,
  p.SEGMENT_CODE,
  p.n_artefacts,
  p.IS_SUPPRESSED_OVERLAY,
  p.SUPPRESSION_KIND,
  p.IS_VULNERABLE_CROSSSELL,
  c.FULL_NAME,
  SPLIT_PART(c.FULL_NAME, ' ', 1)                        AS FIRST_NAME,
  c.CITY,
  c.SEGMENT                                              AS VALUE_BAND,
  c.TENURE_MONTHS,
  c.VULNERABILITY_FLAG,
  c.VULNERABILITY_KIND,
  -- insurance
  r.POLICY_TYPE,
  r.PREMIUM_INR,
  r.RENEWAL_DATE,
  r.SUM_ASSURED_INR,
  ROUND(r.PREMIUM_INR / (1 + RAW.RND_INT('hike|' || p.CUSTOMER_ID, 18, 42) / 100.0), -2)
                                                         AS LAST_YEAR_PREMIUM_INR,
  RAW.RND_PICK('comp|' || p.CUSTOMER_ID, ARRAY_CONSTRUCT(
    'ICICI Lombard','HDFC Ergo','Bajaj Allianz','Tata AIG','Go Digit',
    'Acko','Reliance General','SBI General','Star Health','Niva Bupa'))
                                                         AS COMPETITOR,
  -- servicing
  tk.CATEGORY                                            AS TICKET_CATEGORY,
  tk.SUB_CATEGORY                                        AS TICKET_SUB_CATEGORY,
  tk.SEVERITY                                            AS TICKET_SEVERITY,
  tk.OPENED_AT                                           AS TICKET_OPENED_AT,
  -- lending
  l.LOAN_TYPE, l.EMI_INR, l.DPD_DAYS,
  hl.PRINCIPAL_INR                                       AS HOME_LOAN_PRINCIPAL_INR,
  hl.EMI_INR                                             AS HOME_LOAN_EMI_INR,
  COALESCE(m.n_missed, 0)                                AS N_MISSED,
  RAW.RND_PICK('hard|' || p.CUSTOMER_ID, ARRAY_CONSTRUCT(
    'lost their job when the employer downsized last quarter and has had no salary since',
    'is meeting a large hospital bill for a parent after an emergency admission',
    'had their salary delayed three months running because the employer is in trouble',
    'runs a small business whose orders collapsed and has no income this quarter',
    'is paying for their own ongoing medical treatment out of pocket'))
                                                         AS HARDSHIP_REASON,
  -- cards
  cd.CARD_TIER, cd.CREDIT_LIMIT_INR, cd.UTILISATION_PCT, cd.TOP_MCC_GROUP,
  -- wealth
  ls.AMOUNT_INR                                          AS LUMPSUM_INR,
  ls.MCC_GROUP                                           AS LUMPSUM_SOURCE,
  -- benign topic for the negative cohort
  RAW.RND_PICK('benign|' || p.CUSTOMER_ID, ARRAY_CONSTRUCT(
    'wants a duplicate policy document emailed for a visa application',
    'is updating their registered mobile number and email address',
    'is asking how to add a nominee to an existing policy',
    'wants to know whether their annual health check-up is covered',
    'is confirming that an EMI debited twice last month has been reversed',
    'is asking for the interest certificate needed for a tax filing',
    'wants to change the premium payment date to align with their salary date',
    'is asking whether the mobile app can show past premium receipts',
    'wants to know the status of an address change requested last week',
    'is asking how to register a vehicle number change on a motor policy'))
                                                         AS BENIGN_TOPIC
FROM picked p
JOIN RAW.CUSTOMER c        ON c.CUSTOMER_ID = p.CUSTOMER_ID
LEFT JOIN renewal r        ON r.CUSTOMER_ID = p.CUSTOMER_ID  AND r.rn = 1
LEFT JOIN ticket tk        ON tk.CUSTOMER_ID = p.CUSTOMER_ID AND tk.rn = 1
LEFT JOIN loan l           ON l.CUSTOMER_ID = p.CUSTOMER_ID  AND l.rn = 1
LEFT JOIN homeloan hl      ON hl.CUSTOMER_ID = p.CUSTOMER_ID AND hl.rn = 1
LEFT JOIN card cd          ON cd.CUSTOMER_ID = p.CUSTOMER_ID AND cd.rn = 1
LEFT JOIN lumpsum ls       ON ls.CUSTOMER_ID = p.CUSTOMER_ID AND ls.rn = 1
LEFT JOIN missed m         ON m.CUSTOMER_ID = p.CUSTOMER_ID;

/* ============================================================================
   STEP 4 — SLOT ASSIGNMENTS
   ----------------------------------------------------------------------------
   One row per artefact-to-be. Type, channel, direction, language and timestamp
   are all decided here so the mix is exact and the dates stay consistent with
   the planted 60-day complaint window.

   Type mix comes from a 20-element weighted pick: 7 CALL_TRANSCRIPT, 5 EMAIL,
   5 CHAT, 3 ADVISER_NOTE (35/25/25/15). Slot 0 of the two high-signal segments
   is forced to CALL_TRANSCRIPT so those cohorts definitely carry transcripts —
   they are what the audio path in 06 has to look indistinguishable from.

   Dates: a segment-specific window, then re-ranked within the thread so slot
   order is chronological order. RETENTION_SAVE threads are anchored to the
   planted ticket so the artefacts sit either side of the complaint rather than
   floating free of it.
   ============================================================================ */

CREATE OR REPLACE TEMPORARY TABLE RAW.TMP_SLOTS AS
WITH grid AS (
  SELECT f.*,
         s.slot_no,
         'ix|' || f.CUSTOMER_ID || '|' || s.slot_no AS k
  FROM RAW.TMP_FACTS f
  CROSS JOIN (SELECT SEQ8() AS slot_no FROM TABLE(GENERATOR(ROWCOUNT => 3))) s
  WHERE s.slot_no < f.n_artefacts
),
typed AS (
  SELECT g.*,
         CASE
           WHEN g.slot_no = 0
            AND g.SEGMENT_CODE IN ('RETENTION_SAVE','COLLECTIONS_HARDSHIP')
             THEN 'CALL_TRANSCRIPT'
           ELSE RAW.RND_PICK('ixtype|' || g.k, ARRAY_CONSTRUCT(
                  'CALL_TRANSCRIPT','CALL_TRANSCRIPT','CALL_TRANSCRIPT','CALL_TRANSCRIPT',
                  'CALL_TRANSCRIPT','CALL_TRANSCRIPT','CALL_TRANSCRIPT',
                  'EMAIL','EMAIL','EMAIL','EMAIL','EMAIL',
                  'CHAT','CHAT','CHAT','CHAT','CHAT',
                  'ADVISER_NOTE','ADVISER_NOTE','ADVISER_NOTE'))
         END AS artefact_type
  FROM grid g
),
dated AS (
  SELECT t.*,
    CASE
      -- anchored on the planted complaint: within a fortnight either side
      WHEN t.SEGMENT_CODE = 'RETENTION_SAVE' AND t.TICKET_OPENED_AT IS NOT NULL
        THEN GREATEST(1, DATEDIFF(day, t.TICKET_OPENED_AT, RAW.AS_OF())
                         + RAW.RND_INT('ixage|' || t.k, -12, 9))
      WHEN t.SEGMENT_CODE = 'RETENTION_SAVE'       THEN RAW.RND_INT('ixage|' || t.k, 2, 55)
      WHEN t.SEGMENT_CODE = 'COLLECTIONS_HARDSHIP' THEN RAW.RND_INT('ixage|' || t.k, 2, 120)
      WHEN t.SEGMENT_CODE = 'WEALTH_REFERRAL'      THEN RAW.RND_INT('ixage|' || t.k, 2, 85)
      ELSE                                              RAW.RND_INT('ixage|' || t.k, 2, 300)
    END AS days_ago
  FROM typed t
),
ordered AS (
  SELECT d.*,
         -- slot order must be chronological order
         ROW_NUMBER() OVER (PARTITION BY d.CUSTOMER_ID ORDER BY d.days_ago DESC, d.slot_no) - 1
           AS chrono_no
  FROM dated d
)
SELECT
  o.* EXCLUDE (slot_no, chrono_no),
  o.chrono_no AS slot_no,
  CASE o.artefact_type
    WHEN 'CALL_TRANSCRIPT' THEN 'CALL'
    WHEN 'EMAIL'           THEN 'EMAIL'
    WHEN 'CHAT'            THEN RAW.RND_PICK('ixch|' || o.k, ARRAY_CONSTRUCT('WHATSAPP','APP_CHAT'))
    ELSE                        RAW.RND_PICK('ixch|' || o.k, ARRAY_CONSTRUCT('BRANCH','BRANCH','APP_CHAT'))
  END AS channel,
  CASE
    WHEN o.artefact_type = 'ADVISER_NOTE' THEN 'INTERNAL'
    WHEN o.artefact_type = 'CALL_TRANSCRIPT'
      THEN IFF(RAW.RND_BOOL('ixdir|' || o.k, 0.78), 'INBOUND', 'OUTBOUND')
    ELSE IFF(RAW.RND_BOOL('ixdir|' || o.k, 0.88), 'INBOUND', 'OUTBOUND')
  END AS direction,
  -- internal notes are written in English; customer-facing artefacts code-mix
  IFF(RAW.RND_BOOL('ixlang|' || o.k, IFF(o.artefact_type = 'ADVISER_NOTE', 0.15, 0.40)),
      'HINGLISH', 'EN') AS language_code,
  DATEADD(minute,
          RAW.RND_INT('ixmin|' || o.k, 0, 599),          -- 09:30 -> 19:29 IST
          DATEADD(hour, 9,
            DATEADD(minute, 30,
              CAST(DATEADD(day, -o.days_ago, RAW.AS_OF()) AS TIMESTAMP_NTZ))))
    AS occurred_at,
  -- ~30% of live conversations end with the agent committing to a callback,
  -- which is what gives AI_EXTRACT a promised_callback_date to find
  (o.artefact_type IN ('CALL_TRANSCRIPT','CHAT')
     AND RAW.RND_BOOL('ixcb|' || o.k, 0.30))                       AS promise_callback,
  DATEADD(day, RAW.RND_INT('ixcbd|' || o.k, 2, 9),
          CAST(DATEADD(day, -o.days_ago, RAW.AS_OF()) AS DATE))     AS callback_date
FROM ordered o;

/* ============================================================================
   STEP 5 — BUILD THE PROMPTS
   ----------------------------------------------------------------------------
   The instruction block forbids naming the segment. That is the load-bearing
   rule in this script: if the model writes "customer is a retention risk", the
   enrichment layer is reading a label rather than inferring from behaviour, and
   the demo claim collapses.

   Narrative requirements are expressed as things the customer DOES, never as
   what they ARE. "Objects to the increase and cites a cheaper quote from
   <competitor>" is a behaviour. "Is at risk of lapsing" is a label.
   ============================================================================ */

INSERT INTO RAW.INTERACTION_GEN_PLAN
WITH assignments AS (
  SELECT
    CUSTOMER_ID,
    LISTAGG(
      '  ' || (slot_no + 1) || '. type=' || artefact_type
        || ' | channel=' || channel
        || ' | direction=' || direction
        || ' | language=' || language_code
        || ' | dated=' || TO_CHAR(occurred_at, 'DD Mon YYYY')
        || IFF(promise_callback,
               ' | the agent must promise a callback on ' || TO_CHAR(callback_date, 'DD Mon YYYY'),
               ''),
      '\n') WITHIN GROUP (ORDER BY slot_no) AS assignment_block,
    ARRAY_AGG(OBJECT_CONSTRUCT(
      'slot_no',      slot_no,
      'artefact_type', artefact_type,
      'channel',      channel,
      'direction',    direction,
      'language_code', language_code,
      'occurred_at',  TO_CHAR(occurred_at, 'YYYY-MM-DD HH24:MI:SS')
    )) WITHIN GROUP (ORDER BY slot_no) AS slot_spec
  FROM RAW.TMP_SLOTS
  GROUP BY CUSTOMER_ID
),
facts AS (SELECT * FROM RAW.TMP_FACTS)
SELECT
  'C' || f.CUSTOMER_ID || '|' || $PROMPT_VERSION      AS PLAN_KEY,
  f.CUSTOMER_ID,
  f.SEGMENT_CODE,
  f.n_artefacts,
  a.slot_spec,

  /* ---------- instruction block ---------- */
  $$You are producing synthetic contact-centre records for an Indian bank-and-insurer group, for use as test data. They must read exactly like real records captured by agents in Pune and Gurugram.

HARD RULES
1. Produce one artefact per numbered assignment, using that assignment's type, channel, direction and language. Return them keyed by slot_no, where slot_no is the assignment number minus one.
2. Never state, label, score or hint at any customer category. Do not write words like "at risk", "churn", "retention case", "hardship case", "vulnerable", "high value", "segment", "propensity". Describe only what the customer says and does. A separate system has to infer the category from behaviour alone, so naming it destroys the test.
3. Do not reuse the wording of the CRM summary given below for context. Write what the customer actually said, not the summary of it.
4. Money is Indian rupees, written the way people write it in practice, varying between artefacts: "Rs 14,200", "INR 14200", "14,200 rupees", "1.2 lakh", "fourteen thousand two hundred".
5. Format by type:
   CALL_TRANSCRIPT: 6 to 12 alternating turns, each line starting "Agent:" or "Customer:". Include the realities of phone calls: verification questions, hold notices, a repeated sentence, trailing-off, an interruption.
   EMAIL: 90 to 160 words, greeting and sign-off, plus a separate subject line.
   CHAT: 6 to 14 short turns, each starting "Customer:" or "Agent:". App-chat register. Occasional typos and missing punctuation are correct here.
   ADVISER_NOTE: 40 to 90 words, third person, written by staff ABOUT the customer after the fact. Clipped internal register, abbreviations fine (cust, pol, prem, f/up, EMI). Never a dialogue.
6. Language codes:
   EN = Indian English.
   HINGLISH = natural Roman-script Hindi-English code mixing as actually spoken on Indian service calls, e.g. "sir premium itna kaise badh gaya", "main pichle aath saal se aapke saath hoon", "aap kuch kar sakte ho to bataiye". Keep product names, amounts and dates in English. Latin script only, never Devanagari.
7. Vary sentence length and temperament between artefacts. Not every customer is articulate or polite, and not every complaint is coherent.
8. Your organisation is the $$ || $BRAND || $$ group, which trades as $$ || $BRAND || $$ Life, $$ || $BRAND
     || $$ General and $$ || $BRAND || $$ Bank. Agents introduce themselves as calling from it. Never invent any other name for your own organisation.
9. Give the agent a plausible Indian first name, and a DIFFERENT one from the customer's. Do not use the customer's own name for the agent.

CUSTOMER
$$
  || '  Name: '     || f.FULL_NAME
  || ' (address them as ' || f.FIRST_NAME || ')' || CHR(10)
  || '  City: '     || COALESCE(f.CITY, 'unknown') || CHR(10)
  || '  Relationship length: ' || COALESCE(f.TENURE_MONTHS::VARCHAR, 'unknown') || ' months' || CHR(10)
  || COALESCE('  Policy up for renewal: ' || f.POLICY_TYPE
        || ', premium now Rs ' || TO_CHAR(f.PREMIUM_INR, '999,999,999')
        || ', was Rs ' || TO_CHAR(f.LAST_YEAR_PREMIUM_INR, '999,999,999') || ' last year'
        || ', renewal date ' || TO_CHAR(f.RENEWAL_DATE, 'DD Mon YYYY')
        || ', sum assured Rs ' || TO_CHAR(f.SUM_ASSURED_INR, '999,999,999') || CHR(10), '')
  || COALESCE('  Open complaint on file (CRM summary, for context only): '
        || f.TICKET_CATEGORY || ' / ' || f.TICKET_SUB_CATEGORY
        || ', severity ' || f.TICKET_SEVERITY::VARCHAR
        || ', raised ' || TO_CHAR(f.TICKET_OPENED_AT, 'DD Mon YYYY') || CHR(10), '')
  || COALESCE('  Loan: ' || f.LOAN_TYPE || ', EMI Rs ' || TO_CHAR(f.EMI_INR, '999,999,999')
        || ', ' || f.DPD_DAYS::VARCHAR || ' days overdue'
        || ', ' || f.N_MISSED::VARCHAR || ' instalments missed in the last six months' || CHR(10), '')
  || COALESCE('  Home loan outstanding on a property in ' || f.CITY
        || ', EMI Rs ' || TO_CHAR(f.HOME_LOAN_EMI_INR, '999,999,999') || CHR(10), '')
  || COALESCE('  Credit card: ' || f.CARD_TIER || ', limit Rs ' || TO_CHAR(f.CREDIT_LIMIT_INR, '999,999,999')
        || ', currently ' || f.UTILISATION_PCT::VARCHAR || '% utilised'
        || ', spends mostly on ' || LOWER(REPLACE(f.TOP_MCC_GROUP, '_', ' ')) || CHR(10), '')
  || COALESCE('  Recently received Rs ' || TO_CHAR(f.LUMPSUM_INR, '999,999,999')
        || ' into their account from ' || LOWER(REPLACE(f.LUMPSUM_SOURCE, '_', ' ')) || CHR(10), '')

  /* ---------- narrative requirements, conditioned on the planted segment ---------- */
  || CHR(10) || 'WHAT HAPPENS IN THESE ARTEFACTS' || CHR(10)
  || CASE f.SEGMENT_CODE
       WHEN 'RETENTION_SAVE' THEN
         '  The renewal premium has gone up and ' || f.FIRST_NAME || ' is not accepting it. Across the artefacts they must:' || CHR(10)
      || '  - challenge the increase, quoting both the old and the new premium, and demand to know what justifies it' || CHR(10)
      || '  - say they have a cheaper quote from ' || f.COMPETITOR || ', and give a rupee figure for it that is 20-35% below the new premium' || CHR(10)
      || '  - state plainly that they will move the policy if nothing is done before the renewal date' || CHR(10)
      || '  - bring up how long they have been a customer, and that no claim was ever made' || CHR(10)
      || '  The agent should be defensive and offer nothing concrete beyond escalation. Leave it unresolved.'
       WHEN 'COLLECTIONS_HARDSHIP' THEN
         '  ' || f.FIRST_NAME || ' has fallen behind on the EMI and ' || f.HARDSHIP_REASON || '. Across the artefacts they must:' || CHR(10)
      || '  - explain the reason for missing payments in their own words, with a specific detail that makes it real (an employer name, a hospital, a month)' || CHR(10)
      || '  - say clearly that they intend to pay and are not refusing' || CHR(10)
      || '  - ask for something concrete: a few weeks, a part payment, a restructure, the late fee waived' || CHR(10)
      || '  - show the strain, either apologising too much or getting angry at being chased' || CHR(10)
      || '  At least one artefact should have the collections agent pressing them while they explain.'
       WHEN 'LIMIT_INCREASE' THEN
         '  ' || f.FIRST_NAME || ' is running close to the card limit and it is getting in the way. Across the artefacts they must:' || CHR(10)
      || '  - mention a transaction that declined or nearly did, and where' || CHR(10)
      || '  - ask what the limit is and how an increase is requested' || CHR(10)
      || '  - point out that they have never missed a payment' || CHR(10)
      || '  Keep the tone businesslike. This is a request, not a complaint.'
       WHEN 'PROTECTION_GAP' THEN
         '  ' || f.FIRST_NAME || ' contacts the bank about the property and the home loan. Across the artefacts they must:' || CHR(10)
      || '  - raise something concrete and mundane about the loan or the property: the interest certificate, a prepayment, the EMI date, society paperwork, a leak or repair' || CHR(10)
      || '  - refer to the property as their own home, where the family lives' || CHR(10)
      || '  Do NOT have them ask about home insurance or mention cover, and do NOT have the agent offer it. The absence is the point and must stay implicit.'
       WHEN 'WEALTH_REFERRAL' THEN
         '  A large sum has just landed in ' || f.FIRST_NAME || $$'s account. Across the artefacts they must:$$ || CHR(10)
      || '  - refer to the money arriving and roughly where it came from' || CHR(10)
      || '  - ask what to do with it: leave it in savings, a fixed deposit, whether anything better exists' || CHR(10)
      || '  - be cautious rather than adventurous about it' || CHR(10)
      || '  The agent should not know the answer and should not sell anything.'
       ELSE
         '  Routine servicing, nothing more. ' || f.FIRST_NAME || ' ' || f.BENIGN_TOPIC || '.' || CHR(10)
      || '  Mild impatience is fine if a previous request was not actioned. But they must NOT:' || CHR(10)
      || '  - threaten to leave, or mention any other insurer, bank or competing quote' || CHR(10)
      || '  - mention job loss, medical bills, or any difficulty paying' || CHR(10)
      || '  - ask to be removed from marketing contact' || CHR(10)
      || '  These are the negative cases and they must stay clean.'
     END

  /* ---------- overlay: vulnerability ---------- */
  || CASE
       WHEN NOT f.VULNERABILITY_FLAG THEN ''
       ELSE CHR(10) || CHR(10) || 'ADDITIONALLY, WOVEN IN' || CHR(10)
         || '  Exactly one artefact must carry the following, mentioned in passing rather than announced, the way it actually surfaces on a call. Do not name it, do not have the agent flag it, and do not let it take over the conversation:' || CHR(10)
         || CASE f.VULNERABILITY_KIND
              WHEN 'RECENT_BEREAVEMENT' THEN
                '  A death in the immediate family in the last few weeks. It comes out sideways, explaining why paperwork was not done or why the account is in one name now. Their composure slips for a line or two.'
              WHEN 'SERIOUS_ILLNESS' THEN
                '  They are undergoing treatment themselves. It comes up as a reason they cannot come to a branch or were unreachable, mentioning appointments or a hospital schedule.'
              WHEN 'COGNITIVE_IMPAIRMENT' THEN
                '  They ask the same question two or three times in the same conversation, having not retained the answer. They are confused about something they already hold. A son, daughter or neighbour may take the phone to speak for them.'
              WHEN 'FINANCIAL_DISTRESS_DECLARED' THEN
                '  They state outright that money is very tight and they cannot take on anything further, and ask for it to be recorded.'
              WHEN 'AGE_RELATED' THEN
                '  They are elderly, cannot manage the app, and want everything done on the phone or on paper. They mention their age or that a grandchild usually helps.'
              WHEN 'LOW_FINANCIAL_LITERACY' THEN
                '  They do not follow the product terms and ask the agent to explain basics in plain words, unsure what they signed.'
              WHEN 'DISABILITY' THEN
                '  A disability affects how they can transact, mentioned as a practical obstacle to visiting a branch or reading a document.'
              WHEN 'LANGUAGE_BARRIER' THEN
                '  They struggle in English, ask to switch language, and ask the agent to repeat and slow down.'
              ELSE
                '  Circumstances make this a difficult period for them, surfacing indirectly.'
            END
     END

  /* ---------- overlay: consent withdrawal ---------- */
  || CASE
       WHEN f.IS_SUPPRESSED_OVERLAY AND f.SUPPRESSION_KIND = 'DNC'
         THEN CHR(10) || CHR(10) || 'ALSO' || CHR(10)
           || '  In one artefact they demand to be taken off marketing calls and messages, having asked before. They are irritated about it. This is separate from whatever else they came for.'
       ELSE ''
     END

  /* ---------- assignments ---------- */
  || CHR(10) || CHR(10) || 'ASSIGNMENTS' || CHR(10) || a.assignment_block
  || CHR(10) || CHR(10)
  || 'Return JSON only: {"artefacts":[{"slot_no":0,"subject":"...","body":"..."}]}. '
  || 'subject is the email subject line for EMAIL. For every other type use an empty '
  || 'string "" — never null, since a null there is rejected by the response schema '
  || 'and costs the whole thread. '
  || 'body is the full artefact text, with newlines between turns for CALL_TRANSCRIPT and CHAT. '
  || 'Return one entry per assignment: exactly ' || f.n_artefacts::VARCHAR || ' artefacts.'
    AS PROMPT,
  $PROMPT_VERSION AS PROMPT_VERSION,
  CURRENT_TIMESTAMP() AS LOAD_TS
FROM facts f
JOIN assignments a ON a.CUSTOMER_ID = f.CUSTOMER_ID;

/* ----------------------------------------------------------------------------
   Reconcile to the current plan. Bumping PROMPT_VERSION changes every PLAN_KEY,
   which strands the previous version's output in GEN_RAW where it would sit
   alongside the new output and double the corpus. Anything that no longer
   corresponds to a plan row goes.

   This is also the only place a deliberate regeneration happens: bump the
   version, and the old generations are discarded here rather than accumulating.
   ---------------------------------------------------------------------------- */

DELETE FROM RAW.INTERACTION_GEN_RAW g
WHERE NOT EXISTS (
  SELECT 1 FROM RAW.INTERACTION_GEN_PLAN p WHERE p.PLAN_KEY = g.PLAN_KEY
);

/* ----------------------------------------------------------------------------
   What is still outstanding. Zero means the corpus is complete.
   ---------------------------------------------------------------------------- */

CREATE OR REPLACE VIEW RAW.INTERACTION_GEN_PENDING AS
SELECT COUNT(*)              AS threads_pending,
       SUM(p.N_ARTEFACTS)    AS artefacts_pending
FROM RAW.INTERACTION_GEN_PLAN p
WHERE NOT EXISTS (
  SELECT 1 FROM RAW.INTERACTION_GEN_RAW g WHERE g.PLAN_KEY = p.PLAN_KEY
);

/* ============================================================================
   STEP 6 — TOKEN PROJECTION
   ----------------------------------------------------------------------------
   AI_COUNT_TOKENS before spending anything. It counts INPUT only, so for a
   generative call this is a floor, not an estimate — the artefact prose is
   output tokens and bills on top. It also rejects the claude-4-x families, so
   the count uses llama3.3-70b purely to size the text; tokenizers differ, so
   treat the number as approximate.
   ============================================================================ */

SELECT 'token projection'                                        AS metric,
       COUNT(*)                                                  AS threads,
       SUM(N_ARTEFACTS)                                          AS artefacts,
       ROUND(AVG(AI_COUNT_TOKENS('ai_complete','llama3.3-70b', PROMPT)))
                                                                 AS avg_input_tokens_per_thread,
       SUM(AI_COUNT_TOKENS('ai_complete','llama3.3-70b', PROMPT)) AS total_input_tokens_floor
FROM RAW.INTERACTION_GEN_PLAN;

/* ============================================================================
   STEP 7 — GENERATE  (the only step that costs credits)
   ----------------------------------------------------------------------------
   Anti-join on PLAN_KEY, so a thread that already has output is skipped rather
   than regenerated. LIMIT $BATCH_THREADS caps the spend per execution. Ordering
   by PLAN_KEY makes successive batches walk the plan in a stable order instead
   of re-drawing a random subset each time.

   temperature 0.9 on purpose. 1,200 artefacts at temperature 0 collapse into a
   handful of templates, which would make the enrichment layer look far better
   than it is.
   ============================================================================ */

INSERT INTO RAW.INTERACTION_GEN_RAW (PLAN_KEY, CUSTOMER_ID, PROMPT_VERSION, GEN_MODEL, RESPONSE, GENERATED_AT)
WITH todo AS (
  SELECT p.PLAN_KEY, p.CUSTOMER_ID, p.PROMPT_VERSION, p.PROMPT
  FROM RAW.INTERACTION_GEN_PLAN p
  WHERE NOT EXISTS (
    SELECT 1 FROM RAW.INTERACTION_GEN_RAW g WHERE g.PLAN_KEY = p.PLAN_KEY
  )
  ORDER BY p.PLAN_KEY
  LIMIT $BATCH_THREADS
)
SELECT
  t.PLAN_KEY,
  t.CUSTOMER_ID,
  t.PROMPT_VERSION,
  $GEN_MODEL,
  AI_COMPLETE(
    model            => $GEN_MODEL,
    prompt           => t.PROMPT,
    model_parameters => { 'temperature': 0.9, 'max_tokens': 8192 },
    response_format  => {
      'type': 'json',
      'schema': {
        'type': 'object',
        'properties': {
          'artefacts': {
            'type': 'array',
            'items': {
              'type': 'object',
              'properties': {
                'slot_no': { 'type': 'number', 'description': 'assignment number minus one' },
                'subject': { 'type': 'string', 'description': 'email subject line; empty string for other types' },
                'body':    { 'type': 'string', 'description': 'the full artefact text' }
              },
              'required': ['slot_no','subject','body']
            }
          }
        },
        'required': ['artefacts']
      }
    }
  ),
  CURRENT_TIMESTAMP()
FROM todo t;

/* ----------------------------------------------------------------------------
   Self-healing. AI_COMPLETE returns NULL on a per-row failure rather than
   raising, so a failed thread would otherwise be recorded as done and leave a
   permanent hole in the corpus that no amount of re-running would fill. Deleting
   the failures here puts them back in the queue for the next batch.

   Also drops threads that came back short of their assignment count, since the
   1,200 total is meant to be exact rather than approximate, and threads whose
   text leaks a classification (step 0) so they are rewritten rather than
   corrupting the corpus. Regeneration is at temperature 0.9, so a requeued
   thread genuinely gets different wording rather than the same failure back.
   ---------------------------------------------------------------------------- */

DELETE FROM RAW.INTERACTION_GEN_RAW
WHERE PLAN_KEY IN (
  -- failed outright, or came back short of its assignment count
  SELECT g.PLAN_KEY
  FROM RAW.INTERACTION_GEN_RAW g
  JOIN RAW.INTERACTION_GEN_PLAN p ON p.PLAN_KEY = g.PLAN_KEY
  WHERE g.RESPONSE IS NULL
     OR COALESCE(ARRAY_SIZE(g.RESPONSE:artefacts), 0) < p.N_ARTEFACTS
  UNION
  -- any slot in the thread leaks a classification (step 0)
  SELECT g.PLAN_KEY
  FROM RAW.INTERACTION_GEN_RAW g,
       LATERAL FLATTEN(input => g.RESPONSE:artefacts) a
  WHERE RAW.HAS_SEGMENT_LEAK(a.value:body::VARCHAR)
);

-- Any TEXT artefact whose thread is no longer in GEN_RAW at all -- a failed
-- retry, or a customer dropped from the plan -- has to go, since the MERGE
-- below only reconciles threads that still exist.
DELETE FROM RAW.INTERACTION i
WHERE i.SOURCE_KIND = 'TEXT'
  AND NOT EXISTS (
    SELECT 1 FROM RAW.INTERACTION_GEN_RAW g WHERE g.CUSTOMER_ID = i.CUSTOMER_ID
  );

/* ============================================================================
   STEP 8 — FLATTEN
   ----------------------------------------------------------------------------
   Free and re-runnable: joins the model's slot_no back to the slot spec held in
   the plan, so channel, direction, language and timestamp all come from SQL and
   only the prose comes from the model.

   A MERGE rather than an INSERT ... WHERE NOT EXISTS. The INTERACTION_ID is
   (customer, slot) and carries no version, so after a PROMPT_VERSION bump an
   anti-join would silently keep the OLD body forever while reporting success.
   The MERGE overwrites it, which is the only behaviour that makes a
   regeneration mean anything.

   SEGMENT_CODE is deliberately absent from RAW.INTERACTION. It was an input to
   generation and must not become a column the pipeline can read.
   ============================================================================ */

MERGE INTO RAW.INTERACTION AS tgt
USING (
  WITH gen AS (
    SELECT g.PLAN_KEY, g.CUSTOMER_ID,
           a.value:slot_no::NUMBER  AS slot_no,
           a.value:subject::VARCHAR AS subject,
           a.value:body::VARCHAR    AS body
    FROM RAW.INTERACTION_GEN_RAW g,
         LATERAL FLATTEN(input => g.RESPONSE:artefacts) a
  ),
  spec AS (
    SELECT p.PLAN_KEY,
           s.value:slot_no::NUMBER        AS slot_no,
           s.value:artefact_type::VARCHAR AS artefact_type,
           s.value:channel::VARCHAR       AS channel,
           s.value:direction::VARCHAR     AS direction,
           s.value:language_code::VARCHAR AS language_code,
           TO_TIMESTAMP_NTZ(s.value:occurred_at::VARCHAR) AS occurred_at
    FROM RAW.INTERACTION_GEN_PLAN p,
         LATERAL FLATTEN(input => p.SLOT_SPEC) s
  )
  SELECT
    'IX-' || LPAD(g.CUSTOMER_ID, 6, '0') || '-' || g.slot_no  AS INTERACTION_ID,
    g.CUSTOMER_ID,
    sp.artefact_type,
    sp.channel,
    sp.direction,
    sp.occurred_at,
    sp.language_code,
    NULLIF(TRIM(COALESCE(g.subject, '')), '')                 AS SUBJECT,
    g.body,
    LENGTH(g.body)                                            AS BODY_CHARS
  FROM gen g
  JOIN spec sp ON sp.PLAN_KEY = g.PLAN_KEY AND sp.slot_no = g.slot_no
  WHERE g.body IS NOT NULL
    AND LENGTH(TRIM(g.body)) > 40
) AS src
ON tgt.INTERACTION_ID = src.INTERACTION_ID
WHEN MATCHED THEN UPDATE SET
  tgt.ARTEFACT_TYPE = src.artefact_type,
  tgt.CHANNEL       = src.channel,
  tgt.DIRECTION     = src.direction,
  tgt.OCCURRED_AT   = src.occurred_at,
  tgt.LANGUAGE_CODE = src.language_code,
  tgt.SUBJECT       = src.SUBJECT,
  tgt.BODY          = src.body,
  tgt.BODY_CHARS    = src.BODY_CHARS,
  tgt.LOAD_TS       = CURRENT_TIMESTAMP()
WHEN NOT MATCHED THEN INSERT
  (INTERACTION_ID, CUSTOMER_ID, ARTEFACT_TYPE, CHANNEL, DIRECTION, OCCURRED_AT,
   LANGUAGE_CODE, SUBJECT, BODY, SOURCE_KIND, SOURCE_REF, BODY_CHARS, LOAD_TS)
  VALUES
  (src.INTERACTION_ID, src.CUSTOMER_ID, src.artefact_type, src.channel, src.direction,
   src.occurred_at, src.language_code, src.SUBJECT, src.body, 'TEXT', NULL,
   src.BODY_CHARS, CURRENT_TIMESTAMP());

/* ============================================================================
   STEP 9 — VERIFY
   ============================================================================ */

SELECT 'progress' AS check_name, * FROM RAW.INTERACTION_GEN_PENDING;

-- Every generated thread should have produced exactly its assignment count.
-- Non-zero here means the self-healing delete has queued those threads again.
SELECT 'thread completeness' AS check_name,
       COUNT(*)                                                  AS threads_done,
       SUM(IFF(ARRAY_SIZE(g.RESPONSE:artefacts) = p.N_ARTEFACTS, 1, 0)) AS exact,
       SUM(IFF(ARRAY_SIZE(g.RESPONSE:artefacts) > p.N_ARTEFACTS, 1, 0)) AS over
FROM RAW.INTERACTION_GEN_RAW g
JOIN RAW.INTERACTION_GEN_PLAN p ON p.PLAN_KEY = g.PLAN_KEY;

-- Hard invariant: every artefact in GEN_RAW must have exactly one row in
-- INTERACTION, and INTERACTION must hold nothing else that came from text.
-- A non-zero drift here means the MERGE or one of the deletes is wrong.
SELECT 'flatten invariant' AS check_name,
       (SELECT SUM(ARRAY_SIZE(RESPONSE:artefacts)) FROM RAW.INTERACTION_GEN_RAW) AS in_gen_raw,
       (SELECT COUNT(*) FROM RAW.INTERACTION WHERE SOURCE_KIND = 'TEXT')          AS in_interaction,
       (SELECT COUNT(*) FROM RAW.INTERACTION i
         WHERE i.SOURCE_KIND = 'TEXT'
           AND NOT EXISTS (SELECT 1 FROM RAW.INTERACTION_GEN_RAW g
                            WHERE g.CUSTOMER_ID = i.CUSTOMER_ID))                 AS orphaned;

SELECT 'corpus' AS check_name,
       COUNT(*)                                  AS artefacts,
       COUNT(DISTINCT CUSTOMER_ID)               AS customers,
       MIN(OCCURRED_AT)::DATE                    AS earliest,
       MAX(OCCURRED_AT)::DATE                    AS latest,
       ROUND(AVG(BODY_CHARS))                    AS avg_body_chars
FROM RAW.INTERACTION;

SELECT ARTEFACT_TYPE, LANGUAGE_CODE, COUNT(*) AS n
FROM RAW.INTERACTION
GROUP BY 1, 2 ORDER BY 1, 2;

-- Leakage check. Must be zero: step 0's predicate is enforced by the loader, so
-- a non-zero count here means a thread was requeued and needs another pass, not
-- that the corpus has been accepted with leaks in it.
SELECT 'segment label leakage' AS check_name,
       COUNT(*)                                          AS violations,
       COUNT_IF(BODY ILIKE '%retention team%')            AS allowed_retention_team_refs
FROM RAW.INTERACTION
WHERE RAW.HAS_SEGMENT_LEAK(BODY);

SELECT 'RAW.INTERACTION batch complete' AS status,
       $GEN_MODEL AS model, $PROMPT_VERSION AS prompt_version;

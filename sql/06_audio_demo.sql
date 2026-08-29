/* ============================================================================
   06_audio_demo.sql  —  the audio path, proven rather than asserted
   ----------------------------------------------------------------------------
   PROJECT_BRIEF §7 lists AI_TRANSCRIBE as "Available via cross-region —
   UNTESTED here, no audio fixture yet". It is the only unverified claim in the
   capability matrix, and the architecture's claim to cover call recordings rests
   on it. This script closes that gap with three real files.

   The point is not volume. Three transcribed calls prove the path works end to
   end: staged audio -> AI_TRANSCRIBE -> the same RAW.INTERACTION table that
   holds the 1,200 text artefacts -> the same enrichment in
   05_curated_signals.sql. Nothing downstream can tell which rows arrived as
   audio, because SOURCE_KIND is the only thing that distinguishes them and no
   view filters on it.

   ----------------------------------------------------------------------------
   WHAT YOU MUST UPLOAD, AND WHERE
   ----------------------------------------------------------------------------
   Three files, named EXACTLY these, into the stage this script creates:

     call_retention_01.<ext>     a renewal-premium argument
     call_hardship_01.<ext>      a missed-EMI hardship conversation
     call_vulnerable_01.<ext>    a confused elderly customer

   The BASE NAME is what matters; the extension is not. RAW.AUDIO_FIXTURE keys on
   the name with the extension stripped, so .m4a, .mp3, .wav or any other
   supported container works with no edit to this script. The fixtures committed
   under data/audio/ are .m4a, because stock macOS has no mp3 encoder -- `say`
   plus `afconvert` produce AAC/M4A, which AI_TRANSCRIBE accepts on equal terms.
   Drop in .mp3 files of the same base name instead and this still works.

   Upload with the Snowflake CLI from the repo root, all three at once:

     snow stage copy data/audio/ @C360_NBA.RAW.AUDIO_STAGE -c coco

   or one at a time:

     snow stage copy data/audio/call_retention_01.m4a @C360_NBA.RAW.AUDIO_STAGE -c coco

   Then re-run this script. It is safe to run before the files exist: the
   transcription step is driven by the directory table, so with an empty stage it
   simply transcribes nothing and reports zero.

   Supported formats, per the AI_TRANSCRIBE docs: audio AAC, FLAC, M4A, MP3,
   MP4, OGG, WAV, WEBM; video MKV, MOV, MP4, OGV, WEBM. Max 700 MB, and max 120
   minutes without timestamps or 60 with. Anything under 10 seconds still bills
   as 10 seconds, and audio bills at 50 tokens per second — so three 90-second
   calls is roughly 13,500 tokens, which is negligible.

   PROJECT_BRIEF D1 settles how the fixtures are produced: generated locally
   with the macOS `say` command, committed under data/audio/. That is a
   build-time fixture, not a runtime dependency, so the no-external-services rule
   still holds at runtime. To regenerate them from the transcripts in
   docs/audio_scripts/:

     python3 docs/audio_scripts/build_fixtures.py

   That generator speaks each turn with an ALTERNATING voice (Rishi / Tara, both
   en_IN) and concatenates them, because AI_TRANSCRIBE's speaker diarisation
   needs two genuinely different voices to separate. A fixture recorded in one
   voice comes back as a single speaker and the turn structure this script
   depends on does not materialise.

   ----------------------------------------------------------------------------
   WHY THE STAGE IS DEFINED THE WAY IT IS
   ----------------------------------------------------------------------------
   ENCRYPTION = SNOWFLAKE_SSE is REQUIRED, not stylistic. TO_FILE cannot read a
   stage encrypted with the default SNOWFLAKE_FULL, and the failure is an opaque
   error at transcription time rather than at stage creation. Named internal
   stage only: user stages (@~) and table stages (@%tbl) are not supported.

   DIRECTORY = (ENABLE = TRUE) is what lets this script discover the files
   instead of hardcoding a list, but directory tables on internal stages do NOT
   refresh automatically after a PUT -- hence the explicit ALTER STAGE REFRESH
   below. Skipping it is the usual reason a freshly uploaded file appears to be
   missing.
   ============================================================================ */

USE ROLE COCO_BUILDER;
USE WAREHOUSE COCO_WH;
USE DATABASE C360_NBA;
USE SCHEMA RAW;

SET TRANSCRIBE_VERSION = 'v1';

/* ============================================================================
   STEP 1 — STAGE
   ----------------------------------------------------------------------------
   IF NOT EXISTS, deliberately. CREATE OR REPLACE STAGE would silently discard
   the uploaded audio every time the script ran, which is the worst possible
   behaviour for the one asset here that cannot be regenerated from SQL.
   ============================================================================ */

CREATE STAGE IF NOT EXISTS RAW.AUDIO_STAGE
  DIRECTORY  = ( ENABLE = TRUE )
  ENCRYPTION = ( TYPE = 'SNOWFLAKE_SSE' )
  COMMENT    = 'Contact-centre call recordings for AI_TRANSCRIBE. SNOWFLAKE_SSE is required for TO_FILE.';

-- Internal-stage directory tables need this after every upload.
ALTER STAGE RAW.AUDIO_STAGE REFRESH;

/* ============================================================================
   STEP 2 — FIXTURE MAP
   ----------------------------------------------------------------------------
   Which customer each recording belongs to, and what is on it.

   The customers are chosen by predicate rather than hardcoded by ID, so this
   still binds to the right people after a reseed with a different RAW.SEED().
   Each file lands on a customer who genuinely holds the situation the audio
   describes -- a real near-renewal complaint, real missed instalments, a real
   vulnerability flag -- so the transcript corroborates the structured book
   instead of contradicting it.

   Deliberately picks customers NOT already in the 1,200-artefact text corpus.
   A customer whose only interaction is a transcribed call is the sharper test:
   it proves the audio path alone can carry a customer into the pipeline.
   ============================================================================ */

CREATE OR REPLACE TABLE RAW.AUDIO_FIXTURE AS
WITH retention AS (
  SELECT t.CUSTOMER_ID
  FROM RAW.CUSTOMER_SEGMENT_TRUTH t
  WHERE t.SEGMENT_CODE = 'RETENTION_SAVE'
  ORDER BY IFF(EXISTS (SELECT 1 FROM RAW.INTERACTION_GEN_PLAN p
                        WHERE p.CUSTOMER_ID = t.CUSTOMER_ID), 1, 0),
           t.CUSTOMER_ID
  LIMIT 1
),
hardship AS (
  SELECT t.CUSTOMER_ID
  FROM RAW.CUSTOMER_SEGMENT_TRUTH t
  WHERE t.SEGMENT_CODE = 'COLLECTIONS_HARDSHIP'
  ORDER BY IFF(EXISTS (SELECT 1 FROM RAW.INTERACTION_GEN_PLAN p
                        WHERE p.CUSTOMER_ID = t.CUSTOMER_ID), 1, 0),
           t.CUSTOMER_ID
  LIMIT 1
),
vulnerable AS (
  -- Every one of the 100 guardrail customers is in the text corpus by design
  -- (the forced overlap in 04 step 2), so this one necessarily doubles up. That
  -- is the more interesting case anyway: the same customer reached by both a
  -- transcribed call and written artefacts.
  SELECT t.CUSTOMER_ID
  FROM RAW.CUSTOMER_SEGMENT_TRUTH t
  JOIN RAW.CUSTOMER c ON c.CUSTOMER_ID = t.CUSTOMER_ID
  WHERE t.IS_VULNERABLE_CROSSSELL
    AND c.VULNERABILITY_KIND IN ('COGNITIVE_IMPAIRMENT','AGE_RELATED','SERIOUS_ILLNESS')
  ORDER BY IFF(EXISTS (SELECT 1 FROM RAW.INTERACTION_GEN_PLAN p
                        WHERE p.CUSTOMER_ID = t.CUSTOMER_ID), 1, 0),
           t.CUSTOMER_ID
  LIMIT 1
)
SELECT 'call_retention_01'  AS FIXTURE_KEY, (SELECT CUSTOMER_ID FROM retention)  AS CUSTOMER_ID,
       'INBOUND'  AS DIRECTION, 'EN'       AS LANGUAGE_CODE, 11 AS DAYS_AGO,
       'Renewal premium objection with a competitor quote.' AS EXPECTED_CONTENT
UNION ALL
SELECT 'call_hardship_01',  (SELECT CUSTOMER_ID FROM hardship),
       'OUTBOUND', 'HINGLISH', 24,
       'Collections call. Customer explains missed EMIs and asks for time.'
UNION ALL
SELECT 'call_vulnerable_01', (SELECT CUSTOMER_ID FROM vulnerable),
       'INBOUND',  'EN',       6,
       'Elderly customer, repeats questions, cannot use the app.';

/* ============================================================================
   STEP 3 — WHAT IS ACTUALLY ON THE STAGE
   ----------------------------------------------------------------------------
   Read the directory table and reconcile against the fixture map, so a
   forgotten or misnamed upload is reported by name rather than producing a
   quietly short result.
   ============================================================================ */

CREATE OR REPLACE VIEW RAW.AUDIO_STAGE_STATUS AS
SELECT f.FIXTURE_KEY,
       f.CUSTOMER_ID,
       d.RELATIVE_PATH                                 AS staged_file,
       d.SIZE                                          AS bytes_on_stage,
       d.LAST_MODIFIED,
       (d.RELATIVE_PATH IS NOT NULL)                   AS is_uploaded,
       EXISTS (SELECT 1 FROM RAW.INTERACTION i
                WHERE i.SOURCE_REF = d.RELATIVE_PATH)  AS is_transcribed
FROM RAW.AUDIO_FIXTURE f
LEFT JOIN DIRECTORY(@RAW.AUDIO_STAGE) d
       ON REGEXP_REPLACE(d.RELATIVE_PATH, '[.][^.]+$', '') = f.FIXTURE_KEY;

SELECT 'audio stage status' AS check_name, * FROM RAW.AUDIO_STAGE_STATUS ORDER BY FIXTURE_KEY;

-- A fixture with no CUSTOMER_ID means its selection predicate matched nobody in
-- this seed. Better to see it named here than to transcribe audio and attach it
-- to a NULL customer.
SELECT 'unassigned fixtures' AS check_name, FIXTURE_KEY
FROM RAW.AUDIO_FIXTURE WHERE CUSTOMER_ID IS NULL;

/* ============================================================================
   STEP 4 — TRANSCRIBE
   ----------------------------------------------------------------------------
   Incremental on the filename, so already-transcribed audio is never
   re-transcribed. Audio bills per second, so this matters more than it looks:
   without the anti-join, every rebuild would pay for the same three calls again.

   timestamp_granularity = 'speaker' rather than the plain default. Diarisation
   is what makes a transcript comparable to the generated CALL_TRANSCRIPT
   artefacts, which are already turn-structured with Agent:/Customer: prefixes.
   Without it the audio rows would be one undifferentiated block and the
   "indistinguishable grain" claim would not survive inspection.

   return_error_details => TRUE so a failure arrives as a readable message
   instead of a NULL. Given this is the one capability the brief flags as
   untested in AWS_AP_SOUTH_1, a silent NULL here would be the single most
   misleading outcome in the build.
   ============================================================================ */

CREATE TABLE IF NOT EXISTS RAW.AUDIO_TRANSCRIPT_RAW (
  FIXTURE_KEY         VARCHAR(100)  NOT NULL,
  RELATIVE_PATH       VARCHAR(200)  NOT NULL,
  CUSTOMER_ID         NUMBER(10,0)  NOT NULL,
  TRANSCRIBE_VERSION  VARCHAR(8)    NOT NULL,
  RESULT              VARIANT,      -- { value: {audio_duration, segments[]}, error: null }
  TRANSCRIBED_AT      TIMESTAMP_NTZ NOT NULL
)
COMMENT = 'Raw AI_TRANSCRIBE output. Landed once; audio bills per second so it is never re-transcribed.';

INSERT INTO RAW.AUDIO_TRANSCRIPT_RAW
SELECT
  f.FIXTURE_KEY,
  d.RELATIVE_PATH,
  f.CUSTOMER_ID,
  $TRANSCRIBE_VERSION,
  AI_TRANSCRIBE(
    TO_FILE('@C360_NBA.RAW.AUDIO_STAGE', d.RELATIVE_PATH),
    { 'timestamp_granularity': 'speaker' },
    TRUE
  )::VARIANT,   -- return_error_details => TRUE yields a typed OBJECT, not VARIANT
  CURRENT_TIMESTAMP()
FROM RAW.AUDIO_FIXTURE f
JOIN DIRECTORY(@RAW.AUDIO_STAGE) d
     ON REGEXP_REPLACE(d.RELATIVE_PATH, '[.][^.]+$', '') = f.FIXTURE_KEY
WHERE f.CUSTOMER_ID IS NOT NULL
  AND NOT EXISTS (
  SELECT 1 FROM RAW.AUDIO_TRANSCRIPT_RAW r WHERE r.FIXTURE_KEY = f.FIXTURE_KEY
);

-- Self-healing, as in 04 and 05: a failed transcription must not be recorded as
-- done. With return_error_details => TRUE the error text is preserved for
-- inspection first, which is why this reports before it deletes.
/* Note the cast on RESULT:error. AI_TRANSCRIBE returns {"error": null, ...} on
   success, and a VARIANT holding a JSON null is NOT a SQL NULL -- so the
   intuitive `RESULT:error IS NOT NULL` is TRUE for every successful row and this
   delete cheerfully removed all three good transcriptions. Casting to VARCHAR
   collapses JSON null to SQL NULL, which is what the test actually needs.
   IS_NULL_VALUE() would do the same job. */

SELECT 'transcription errors' AS check_name, RELATIVE_PATH,
       RESULT:error::VARCHAR AS error_message
FROM RAW.AUDIO_TRANSCRIPT_RAW
WHERE RESULT:error::VARCHAR IS NOT NULL
   OR RESULT:value:segments IS NULL;

DELETE FROM RAW.AUDIO_TRANSCRIPT_RAW
WHERE RESULT IS NULL
   OR RESULT:error::VARCHAR IS NOT NULL
   OR RESULT:value:segments IS NULL;

/* ============================================================================
   STEP 5 — FOLD INTO RAW.INTERACTION
   ----------------------------------------------------------------------------
   Speaker-labelled segments are collapsed into the same "Agent:" / "Customer:"
   turn format the generated transcripts use, so a downstream reader genuinely
   cannot tell the two apart.

   SPEAKER_00 is mapped to the agent on an inbound call and the customer on an
   outbound one, since diarisation labels speakers in the order they are
   detected and whoever answers speaks first. That is a heuristic, and it is
   recorded here rather than buried: on a two-party call it is right far more
   often than not, and the alternative -- leaving raw SPEAKER_00 labels in the
   body -- would make the audio rows trivially identifiable and defeat the point
   of the exercise.

   MERGE, not INSERT, for the same reason as 04: a version bump must overwrite
   rather than silently keep the old text.
   ============================================================================ */

MERGE INTO RAW.INTERACTION AS tgt
USING (
  WITH turns AS (
    SELECT
      r.RELATIVE_PATH,
      r.CUSTOMER_ID,
      f.DIRECTION,
      f.LANGUAGE_CODE,
      f.DAYS_AGO,
      r.RESULT:value:audio_duration::FLOAT AS audio_seconds,
      s.index                              AS turn_no,
      s.value:speaker_label::VARCHAR       AS speaker_label,
      s.value:text::VARCHAR                AS turn_text
    FROM RAW.AUDIO_TRANSCRIPT_RAW r
    JOIN RAW.AUDIO_FIXTURE f ON f.FIXTURE_KEY = r.FIXTURE_KEY
       , LATERAL FLATTEN(input => r.RESULT:value:segments) s
  ),
  bodies AS (
    SELECT
      RELATIVE_PATH, CUSTOMER_ID, DIRECTION, LANGUAGE_CODE, DAYS_AGO,
      MAX(audio_seconds) AS audio_seconds,
      LISTAGG(
        CASE
          WHEN speaker_label = 'SPEAKER_00' AND DIRECTION = 'INBOUND'  THEN 'Agent: '
          WHEN speaker_label = 'SPEAKER_00'                            THEN 'Customer: '
          WHEN DIRECTION = 'INBOUND'                                   THEN 'Customer: '
          ELSE 'Agent: '
        END || TRIM(turn_text),
        '\n') WITHIN GROUP (ORDER BY turn_no) AS body
    FROM turns
    GROUP BY 1,2,3,4,5
  )
  SELECT
    'IX-AUD-' || LPAD(CUSTOMER_ID, 6, '0')            AS INTERACTION_ID,
    CUSTOMER_ID,
    'CALL_TRANSCRIPT'                                 AS ARTEFACT_TYPE,
    'CALL'                                            AS CHANNEL,
    DIRECTION,
    DATEADD(minute, 30, DATEADD(hour, 11,
      CAST(DATEADD(day, -DAYS_AGO, RAW.AS_OF()) AS TIMESTAMP_NTZ))) AS OCCURRED_AT,
    LANGUAGE_CODE,
    body,
    LENGTH(body)                                      AS BODY_CHARS,
    RELATIVE_PATH,
    audio_seconds
  FROM bodies
  WHERE body IS NOT NULL AND LENGTH(TRIM(body)) > 40
) AS src
ON tgt.INTERACTION_ID = src.INTERACTION_ID
WHEN MATCHED THEN UPDATE SET
  tgt.BODY = src.body, tgt.BODY_CHARS = src.BODY_CHARS,
  tgt.OCCURRED_AT = src.OCCURRED_AT, tgt.LOAD_TS = CURRENT_TIMESTAMP()
WHEN NOT MATCHED THEN INSERT
  (INTERACTION_ID, CUSTOMER_ID, ARTEFACT_TYPE, CHANNEL, DIRECTION, OCCURRED_AT,
   LANGUAGE_CODE, SUBJECT, BODY, SOURCE_KIND, SOURCE_REF, BODY_CHARS, LOAD_TS)
  VALUES
  (src.INTERACTION_ID, src.CUSTOMER_ID, src.ARTEFACT_TYPE, src.CHANNEL, src.DIRECTION,
   src.OCCURRED_AT, src.LANGUAGE_CODE, NULL, src.body, 'AUDIO', src.RELATIVE_PATH,
   src.BODY_CHARS, CURRENT_TIMESTAMP());

/* ============================================================================
   STEP 6 — VERIFY
   ============================================================================ */

SELECT 'audio path' AS check_name, * FROM RAW.AUDIO_STAGE_STATUS ORDER BY FIXTURE_KEY;

SELECT 'transcribed rows' AS check_name,
       COUNT(*)                                          AS rows_,
       ROUND(SUM(r.RESULT:value:audio_duration::FLOAT))   AS total_audio_seconds,
       ROUND(SUM(r.RESULT:value:audio_duration::FLOAT) * 50) AS billed_tokens_at_50_per_sec
FROM RAW.AUDIO_TRANSCRIPT_RAW r;

-- The claim this whole script exists to support: audio rows sit at the same
-- grain as text rows and nothing but SOURCE_KIND separates them.
SELECT 'grain parity' AS check_name, SOURCE_KIND,
       COUNT(*)                    AS rows_,
       ROUND(AVG(BODY_CHARS))      AS avg_body_chars,
       COUNT_IF(BODY LIKE '%Agent:%' AND BODY LIKE '%Customer:%') AS turn_structured
FROM RAW.INTERACTION
WHERE ARTEFACT_TYPE = 'CALL_TRANSCRIPT'
GROUP BY 1, 2 ORDER BY 2;

-- Diarisation labels must not survive into the body, or the audio rows are
-- identifiable at a glance.
SELECT 'speaker labels leaked' AS check_name, COUNT(*) AS violations
FROM RAW.INTERACTION WHERE BODY ILIKE '%SPEAKER_0%';

-- And the transcripts must not have leaked a classification either. The same
-- predicate 04 enforces, applied to text this pipeline did not write.
SELECT 'segment label leakage in audio' AS check_name, COUNT(*) AS violations
FROM RAW.INTERACTION WHERE SOURCE_KIND = 'AUDIO' AND RAW.HAS_SEGMENT_LEAK(BODY);

SELECT 'audio demo complete' AS status,
       (SELECT COUNT(*) FROM RAW.INTERACTION WHERE SOURCE_KIND = 'AUDIO') AS audio_rows,
       'run 05_curated_signals.sql again to enrich them alongside the text'  AS next_step;

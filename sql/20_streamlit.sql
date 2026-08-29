/* ============================================================================
   20_streamlit.sql  —  APP.C360_APP, the Streamlit in Snowflake object
   ----------------------------------------------------------------------------
   M10 step 2 of 2, and the last object in the build.

   THIS FILE CANNOT RUN FIRST. It is the one script in sql/ with a prerequisite
   that is not SQL: CREATE STREAMLIT reads its source from a stage, and no SQL
   statement can put a local file there. The order is

       sql/19_app_objects.sql          creates APP.APP_STAGE and the views
       snow stage copy app/ @APP_STAGE copies streamlit_app.py + environment.yml
       snow stage copy app/.streamlit/config.toml @APP_STAGE/.streamlit/
       sql/20_streamlit.sql            this file

   That seam is PROJECT_BRIEF R4, resolved by D2: sql/ stays authoritative for
   every database object, and exactly one step in the rebuild is a client-side
   copy. Running this file against an empty stage fails at CREATE with a missing
   main-file error, which is the correct and legible failure.

   ----------------------------------------------------------------------------
   THE STAGE COPY IS TWO COMMANDS, NOT ONE, AND THE SECOND IS EASY TO LOSE
   ----------------------------------------------------------------------------
   D2 describes the seam as a single "snow stage copy app/". It is not, because
   that command silently skips dot-directories: app/.streamlit/config.toml was
   not uploaded and no warning was printed. The app still ran -- it just ran with
   Streamlit's default #FF4B4B accent, which in this app collides with the red
   that means "a compliance rule blocked this".

   A theme is cosmetic and this failure mode is not, because it is invisible.
   Nothing errors, the deploy reports success, and the only symptom is a colour.
   So the theme file gets its own explicit copy above, and G1 below counts it.

   ----------------------------------------------------------------------------
   FROM ... MAIN_FILE, NOT ROOT_LOCATION
   ----------------------------------------------------------------------------
   ROOT_LOCATION is legacy (R4). The current form is

       CREATE STREAMLIT ... FROM '@stage/path' MAIN_FILE = 'streamlit_app.py'

   followed by ALTER STREAMLIT ... ADD LIVE VERSION FROM LAST, which is what
   actually publishes the staged files as the running version. Without the ALTER
   the object exists and serves nothing, and the error a user sees is an empty
   app rather than a missing app -- so the ALTER is not optional tidying.

   ----------------------------------------------------------------------------
   COST: ZERO CREDITS TO CREATE
   ----------------------------------------------------------------------------
   Creating the object spends nothing. Running the app consumes COCO_WH while a
   user has it open. Screens 1, 2 and 4 are warehouse-only. Screen 3 spends
   Cortex credits per question -- orchestration tokens plus 0.067 credits for
   each Cortex Analyst message -- and only when a user submits one.
   ============================================================================ */

USE ROLE COCO_BUILDER;
USE WAREHOUSE COCO_WH;
USE DATABASE C360_NBA;
USE SCHEMA APP;


/* ============================================================================
   PART 1 — GUARD: THE SOURCE MUST BE ON THE STAGE
   ----------------------------------------------------------------------------
   Asserted before CREATE rather than after, because the failure mode this
   catches is a stale app silently continuing to serve. If somebody edits
   app/streamlit_app.py and runs this file without re-copying, CREATE OR REPLACE
   succeeds against the OLD staged file and the deployment looks clean while
   shipping nothing new. A count is the cheapest way to make that visible.

   THEME_FILE is reported but does not fail the check: a missing theme yields a
   working app with the wrong accent, which is worth flagging loudly and is not
   worth blocking a deploy over.
   ============================================================================ */

LS @APP.APP_STAGE;

SELECT 'G1 app source is staged'                                  AS check_name,
       COUNT_IF(SPLIT_PART("name", '/', -1) = 'streamlit_app.py')  AS main_file,
       COUNT_IF(SPLIT_PART("name", '/', -1) = 'environment.yml')   AS env_file,
       COUNT_IF("name" LIKE '%.streamlit/config.toml')             AS theme_file,
       MAX("last_modified")                                        AS staged_at,
       CASE
         WHEN COUNT_IF(SPLIT_PART("name", '/', -1) = 'streamlit_app.py') <> 1
           THEN 'FAIL — run: snow stage copy app/ @APP.APP_STAGE --overwrite'
         WHEN COUNT_IF("name" LIKE '%.streamlit/config.toml') <> 1
           THEN 'PASS (no theme — see header, copy app/.streamlit/config.toml)'
         ELSE 'PASS'
       END                                                         AS verdict
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));


/* ============================================================================
   PART 2 — THE STREAMLIT OBJECT
   ============================================================================ */

CREATE OR REPLACE STREAMLIT APP.C360_APP
  FROM            '@APP.APP_STAGE'
  MAIN_FILE     = 'streamlit_app.py'
  QUERY_WAREHOUSE = COCO_WH
  TITLE         = 'C360 · Next Best Action'
  COMMENT       = 'Operator surface over the C360 next-best-action engine. Four screens: portfolio cockpit (KPIs, suppression by rule, ranked worklist), customer 360 (identity, timeline with transcripts and extracted signals, ranked action cards with evidence and accept/reject write-back, and the suppressed-actions panel), ask (APP.RM_COPILOT with tool calls and generated SQL exposed), impact (acceptance and channel-cost simulator quantifying the compliance layer in INR). Reads the nine APP views created by sql/19_app_objects.sql and writes only to APP.ACTION_FEEDBACK. Screens 1, 2 and 4 call no AI function; screen 3 spends Cortex credits per question asked.';

ALTER STREAMLIT APP.C360_APP ADD LIVE VERSION FROM LAST;


/* ============================================================================
   PART 3 — ASSERTIONS
   ============================================================================ */

/* A1. The object exists, points at the right main file, and has a live version.

       Read from DESCRIBE, not SHOW. SHOW STREAMLITS in this version returns
       created_on / name / database_name / schema_name / title / comment / owner
       / query_warehouse / url_id and no main_file at all -- the first draft of
       this assertion selected "main_file" from a SHOW result and failed with
       "invalid identifier". DESCRIBE carries main_file, the resolved package
       list and the live version location, which is the whole set of things worth
       asserting here. */
DESCRIBE STREAMLIT APP.C360_APP;

SELECT 'A1 streamlit object created' AS check_name,
       "name",
       "main_file",
       "query_warehouse",
       "live_version_location_uri",
       "user_packages",
       IFF("main_file" = 'streamlit_app.py'
           AND "live_version_location_uri" IS NOT NULL, 'PASS', 'FAIL') AS verdict
FROM   TABLE(RESULT_SCAN(LAST_QUERY_ID()));

/* A2. Every view the app reads exists and is selectable. A missing view here
       becomes a stack trace on a screen rather than an error at deploy time, so
       it is worth one query to find out now. Nine objects: the eight created by
       sql/19 plus APP.V_NBA_EVIDENCE_RESOLVED from the phase that preceded it. */
SELECT 'A2 app reads resolve' AS check_name,
       COUNT(*)               AS views_found,
       9                      AS views_expected,
       IFF(COUNT(*) = 9, 'PASS', 'FAIL') AS verdict
FROM   C360_NBA.INFORMATION_SCHEMA.VIEWS
WHERE  TABLE_SCHEMA = 'APP'
  AND  TABLE_NAME IN ('V_RM_BOOK', 'V_WORKLIST', 'V_PORTFOLIO_KPI',
                      'V_SUPPRESSION_SUMMARY', 'V_CUSTOMER_SUPPRESSED',
                      'V_TIMELINE_DETAIL', 'V_SENTIMENT_SERIES',
                      'V_IMPACT_BASE', 'V_NBA_EVIDENCE_RESOLVED');

/* A3. The write target exists and its shape is what the app inserts into. */
SELECT 'A3 feedback table writable' AS check_name,
       COUNT(*)                     AS columns_found,
       IFF(COUNT(*) = 10, 'PASS', 'FAIL') AS verdict
FROM   C360_NBA.INFORMATION_SCHEMA.COLUMNS
WHERE  TABLE_SCHEMA = 'APP' AND TABLE_NAME = 'ACTION_FEEDBACK';

/* A4. The agent the ASK screen calls is still there. */
SHOW AGENTS LIKE 'RM_COPILOT' IN SCHEMA APP;

SELECT 'A4 agent present' AS check_name,
       COUNT(*)           AS agents,
       IFF(COUNT(*) = 1, 'PASS', 'FAIL') AS verdict
FROM   TABLE(RESULT_SCAN(LAST_QUERY_ID()));


/* ============================================================================
   PART 4 — THE URL
   ----------------------------------------------------------------------------
   Streamlit URLs are built from an opaque url_id, not from the object name, so
   the link cannot be constructed by hand from the account and schema. This
   emits the live one.
   ============================================================================ */

SHOW STREAMLITS LIKE 'C360_APP' IN SCHEMA APP;

SELECT 'https://app.snowflake.com/'
       || LOWER(CURRENT_ORGANIZATION_NAME()) || '/'
       || LOWER(CURRENT_ACCOUNT_NAME())
       || '/#/streamlit-apps/C360_NBA.APP.C360_APP?url_id='
       || "url_id" AS app_url
FROM   TABLE(RESULT_SCAN(LAST_QUERY_ID()));

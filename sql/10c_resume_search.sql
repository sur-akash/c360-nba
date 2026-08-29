/* ============================================================================
   10c_resume_search.sql  —  bring retrieval back up before a demo
   ----------------------------------------------------------------------------
   The inverse of 10b. Run this before the demo, not during it: resuming the
   serving layer takes up to a few minutes, and the first query issued against a
   still-resuming service blocks until it is ready. Budget for that rather than
   discovering it in front of an audience.

   ----------------------------------------------------------------------------
   THERE IS NO "ALTER ... REFRESH" HERE, AND THAT IS THE WHOLE POINT
   ----------------------------------------------------------------------------
   This script originally ended with an explicit REFRESH on both services, on the
   reasoning that forcing the change check immediately was cheap insurance against
   serving stale evidence. It was not cheap. Measured against billing:

     SUSPEND then RESUME                        0 embedding tokens. Free.
     SUSPEND then RESUME then REFRESH           396,223 embedding tokens on
                                                APP.SEARCH_INTERACTIONS — the
                                                ENTIRE corpus re-embedded, at
                                                0.0198 credits, for zero changed
                                                rows.

   Isolated by running each variant separately and reading
   CORTEX_SEARCH_DAILY_USAGE_HISTORY after each. Three full re-embeds of the
   interaction corpus were paid for before the cause was pinned down, and the
   first two were misattributed to CREATE OR REPLACE on the source view — which
   turned out to be free.

   Note the asymmetry, because it tells you what is actually going on:
   APP.SEARCH_PRODUCT_DOCS went through the identical REFRESH and did NOT
   re-embed a single token. The difference is the source query. PRODUCT_DOCS
   reads one table, so the optimised refresh path can prove from change tracking
   that nothing changed. SEARCH_INTERACTIONS reads a VIEW JOINING TWO TABLES, and
   a forced refresh over a join appears not to be able to prove that, so it
   recomputes every embedding. The Cortex Search cost documentation advises
   keeping the source query as simple as possible and pushing joins into ETL;
   this is what that advice costs when ignored, in credits.

   So: resume, and let TARGET_LAG do the rest. If the corpus genuinely changed
   while the services were suspended, re-run sql/10 — its MERGE updates the chunk
   table and the scheduled refresh picks the change up within the day.

   OPEN QUESTION, worth knowing about rather than assuming away. If a forced
   refresh over the join re-embeds everything, the DAILY SCHEDULED refresh may do
   the same — which would cost ~0.02 credits/day for as long as indexing is
   active, on a corpus that never changes. That cannot be tested inside one
   session, since it is a day-scale event. Until it is measured, suspending
   INDEXING as well as serving (which 10b does) is the conservative choice, and
   it is a second, better reason to run 10b at the end of a session than the
   serving charge it was written for.
   ============================================================================ */

USE ROLE COCO_BUILDER;
USE DATABASE C360_NBA;
USE SCHEMA APP;

ALTER CORTEX SEARCH SERVICE IF EXISTS APP.SEARCH_INTERACTIONS RESUME;
ALTER CORTEX SEARCH SERVICE IF EXISTS APP.SEARCH_PRODUCT_DOCS RESUME;

/* Deliberately NOT run. Left here, commented, so nobody re-adds it thinking it
   was an oversight. Costs a full re-embed of SEARCH_INTERACTIONS:

   ALTER CORTEX SEARCH SERVICE IF EXISTS APP.SEARCH_INTERACTIONS REFRESH;
   ALTER CORTEX SEARCH SERVICE IF EXISTS APP.SEARCH_PRODUCT_DOCS REFRESH;
*/

SHOW CORTEX SEARCH SERVICES IN SCHEMA APP;

SELECT "name"                 AS service,
       "indexing_state"       AS indexing_state,
       "serving_state"        AS serving_state,
       "source_data_num_rows" AS rows_indexed,
       IFF("serving_state" = 'ACTIVE', 'ready', 'still starting - wait and re-check') AS verdict
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
ORDER BY 1;

/* Liveness check. A service can report ACTIVE and still be loading its index
   into the serving tier, in which case a query returns "Your service has not
   yet been loaded into our serving system". These two probes are the real
   readiness test — if both return a row, retrieval is genuinely up.

   Both must be cheap: one hit each, two short columns, because SEARCH_PREVIEW
   caps its response at 300 KB. */

SELECT 'SEARCH_INTERACTIONS live' AS probe, VALUE:INTERACTION_ID::VARCHAR AS sample_hit
FROM TABLE(FLATTEN(PARSE_JSON(SNOWFLAKE.CORTEX.SEARCH_PREVIEW('C360_NBA.APP.SEARCH_INTERACTIONS', '{
  "query": "renewal premium increase", "columns": ["INTERACTION_ID"], "limit": 1 }'))['results']));

SELECT 'SEARCH_PRODUCT_DOCS live' AS probe, VALUE:CHUNK_ID::VARCHAR AS sample_hit
FROM TABLE(FLATTEN(PARSE_JSON(SNOWFLAKE.CORTEX.SEARCH_PREVIEW('C360_NBA.APP.SEARCH_PRODUCT_DOCS', '{
  "query": "minimum age to qualify", "columns": ["CHUNK_ID"], "limit": 1 }'))['results']));

SELECT 'search services resumed' AS status,
       'REMEMBER: run sql/10b_suspend_search.sql when you finish the session' AS reminder;

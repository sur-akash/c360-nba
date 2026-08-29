/* ============================================================================
   10b_suspend_search.sql  —  stop paying for idle retrieval
   ----------------------------------------------------------------------------
   RUN THIS WHENEVER YOU FINISH A SESSION.

   A Cortex Search service bills serving compute per GB-month of indexed data for
   as long as its serving layer is RESUMED, whether or not a single query is
   issued. There is no query-based component to that charge. On this corpus the
   two services carry roughly 8 MB of indexed data between them — small, but it
   accrues every hour of every day, and this account is a trial where the visible
   guardrail (COCO_BUDGET, 60 credits) does not meter Cortex at all. Nothing will
   stop this; you have to.

   Both layers are suspended, not just serving:

     SERVING    the meter that runs while idle. This is the one that matters.
     INDEXING   the refresh loop. Safe to stop here because the corpus is static
                — RAW.INTERACTION and APP.PRODUCT_DOC_CHUNK are written by
                04/06 and 10 and by nothing else — so there is nothing to
                refresh and every refresh check is pure waste.

   ONE CAVEAT WORTH KNOWING BEFORE YOU RELY ON THIS. Suspending indexing means
   the service stops tracking changes to its base tables. If the source data
   changed while indexing was suspended AND the change fell out of the tables'
   time-travel retention (set to 3 days by sql/10), the service can be unable to
   catch up and would need recreating — which costs a full re-embed. So: if you
   regenerate the corpus, resume with 10c and let it refresh BEFORE three days
   pass. For a static demo corpus this never comes up.

   AUTO_SUSPEND = 1800 is also set on both services as a backstop, so serving
   folds itself away after 30 minutes of inactivity even if you forget. Treat
   that as the safety net, not the plan: it does not touch indexing, and the
   first query after an auto-suspend pays a cold-start wait of up to a few
   minutes.

   Resume with sql/10c_resume_search.sql.
   ============================================================================ */

USE ROLE COCO_BUILDER;
USE DATABASE C360_NBA;
USE SCHEMA APP;

/* OPERATE on the service is the privilege this needs; COCO_BUILDER owns both
   services, so ownership covers it. IF EXISTS so this is safe to run before
   sql/10 has ever been executed, or after a teardown. */

ALTER CORTEX SEARCH SERVICE IF EXISTS APP.SEARCH_INTERACTIONS SUSPEND;
ALTER CORTEX SEARCH SERVICE IF EXISTS APP.SEARCH_PRODUCT_DOCS SUSPEND;

/* Confirm, rather than assume. INDEXING_STATE and SERVING_STATE must both read
   SUSPENDED. A service showing SERVING_STATE = ACTIVE here is still billing. */

SHOW CORTEX SEARCH SERVICES IN SCHEMA APP;

SELECT "name"                AS service,
       "indexing_state"      AS indexing_state,
       "serving_state"       AS serving_state,
       "source_data_num_rows" AS rows_indexed,
       IFF("serving_state" = 'SUSPENDED', 'not billing', 'STILL BILLING - re-run this script') AS verdict
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
ORDER BY 1;

SELECT 'search services suspended' AS status,
       'resume with sql/10c_resume_search.sql before the demo' AS next_step;

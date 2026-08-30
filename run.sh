#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# run.sh -- the full rebuild, from an empty database to a deployed app.
#
# This is PROJECT_BRIEF.md D2's documented seam made real: sql/ stays
# authoritative for every database object, and the steps that are not SQL
# are sequenced explicitly rather than left as a README instruction someone
# has to remember. Two connections are required:
#
#   coco_admin (ACCOUNTADMIN) -- sql/00_bootstrap.sql and
#     sql/18b_agent_grants_admin.sql. COCO_BUILDER cannot create a database,
#     a resource monitor, or grant itself into SYSADMIN.
#   coco (COCO_BUILDER) -- every other object in the project is owned by
#     this role, including the schemas themselves.
#
# Two non-SQL steps, not one -- PROJECT_BRIEF D2 documents the app-stage copy;
# the audio-stage copy for sql/06 is the same shape and just as required,
# because RAW.AUDIO_STAGE lives inside C360_NBA and does not survive a drop.
#
# COST WARNING. Regenerating and re-enriching the interaction corpus alone
# measured 13.56 credits the first time (README "What each milestone
# actually cost", M3). Warehouse compute for the full sequence adds more.
# Run this once, keep the log this script writes, and do not re-run it
# before a demo -- the log is the submission artifact, not a rehearsal.
# ---------------------------------------------------------------------------
set -euo pipefail
cd "$(dirname "$0")"

ADMIN_CONN="coco_admin"
BUILD_CONN="coco"
LOGDIR="docs/rebuild_logs"
mkdir -p "$LOGDIR"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG="$LOGDIR/rebuild-$STAMP.log"

if [ "${1:-}" != "--yes-drop-database" ]; then
  cat <<'MSG'
This will DROP DATABASE C360_NBA and rebuild it from sql/00 through sql/20.
It costs real credits -- at minimum the ~13.56 credits M3 measured for corpus
generation and enrichment, plus warehouse compute for everything after it.

Check your remaining balance first:

  snow sql -c coco_admin -q "SELECT SERVICE_TYPE, ROUND(SUM(CREDITS_USED),3) cr
    FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY
    WHERE USAGE_DATE >= DATE_TRUNC('month', CURRENT_DATE()) GROUP BY 1 ORDER BY 2 DESC"

Re-run as:  ./run.sh --yes-drop-database
MSG
  exit 0
fi

START=$(date +%s)
step() {
  local desc="$1"; shift
  local t0=$(date +%s)
  { echo "### $desc"; "$@"; local rc=$?; local t1=$(date +%s); \
    echo "### done in $((t1 - t0))s (exit $rc)"; } 2>&1 | tee -a "$LOG"
}

step "drop + recreate database (ACCOUNTADMIN)" \
  snow sql -c "$ADMIN_CONN" -q "DROP DATABASE IF EXISTS C360_NBA;"

step "00 bootstrap: role, warehouse, resource monitor, database, grants (ACCOUNTADMIN)" \
  snow sql -c "$ADMIN_CONN" -f sql/00_bootstrap.sql

step "02 schema + PRNG helpers" snow sql -c "$BUILD_CONN" -f sql/02_schema_raw.sql
step "03 seed raw: 5,000 customers and structured history" snow sql -c "$BUILD_CONN" -f sql/03_seed_raw.sql
step "04 seed interactions: generated contact-centre corpus" snow sql -c "$BUILD_CONN" -f sql/04_seed_interactions.sql
step "05 curated signals: AI enrichment, confidence-gated" snow sql -c "$BUILD_CONN" -f sql/05_curated_signals.sql

step "stage copy: data/audio/ -> RAW.AUDIO_STAGE (non-SQL step, required for 06)" \
  snow stage copy data/audio/ @C360_NBA.RAW.AUDIO_STAGE -c "$BUILD_CONN"
step "06 audio demo: AI_TRANSCRIBE onto the same grain as text" snow sql -c "$BUILD_CONN" -f sql/06_audio_demo.sql

step "07 curated rollup" snow sql -c "$BUILD_CONN" -f sql/07_curated_rollup.sql
step "08 gold c360: the customer spine and timeline" snow sql -c "$BUILD_CONN" -f sql/08_gold_c360.sql
step "09 semantic view feeder shims" snow sql -c "$BUILD_CONN" -f sql/09_semantic_view.sql
step "10 search services: two Cortex Search services" snow sql -c "$BUILD_CONN" -f sql/10_search_services.sql
step "11 action catalog: 18 actions, tiers, margins, disclosures" snow sql -c "$BUILD_CONN" -f sql/11_action_catalog.sql
step "12 nba eligibility: GOLD.NBA_ELIGIBLE, every candidate, every rule" snow sql -c "$BUILD_CONN" -f sql/12_nba_eligibility.sql
step "13 nba scoring: deterministic propensity and expected value" snow sql -c "$BUILD_CONN" -f sql/13_nba_scoring.sql
step "14 nba reasoning: written rationale, validated" snow sql -c "$BUILD_CONN" -f sql/14_nba_reasoning.sql
step "15 nba publish: GOLD.NEXT_BEST_ACTION" snow sql -c "$BUILD_CONN" -f sql/15_nba_publish.sql
step "16 semantic view nba: the authoritative CREATE SEMANTIC VIEW" snow sql -c "$BUILD_CONN" -f sql/16_semantic_view_nba.sql
step "17 nba tool: APP.GET_NEXT_BEST_ACTIONS" snow sql -c "$BUILD_CONN" -f sql/17_nba_tool.sql
step "18 agent: APP.RM_COPILOT, four tools" snow sql -c "$BUILD_CONN" -f sql/18_agent.sql

step "18b agent grants (ACCOUNTADMIN)" \
  snow sql -c "$ADMIN_CONN" -f sql/18b_agent_grants_admin.sql

step "19 app objects: stage, ACTION_FEEDBACK, read views" snow sql -c "$BUILD_CONN" -f sql/19_app_objects.sql

step "stage copy: app/ -> APP.APP_STAGE (non-SQL step, PROJECT_BRIEF D2)" \
  snow stage copy app/ @C360_NBA.APP.APP_STAGE -c "$BUILD_CONN"
step "stage copy: app/.streamlit/config.toml (skipped by the recursive copy above -- sql/20's own header warning)" \
  snow stage copy app/.streamlit/config.toml @C360_NBA.APP.APP_STAGE/.streamlit/ -c "$BUILD_CONN"

step "20 streamlit app: APP.C360_APP, the last object in the build" snow sql -c "$BUILD_CONN" -f sql/20_streamlit.sql

END=$(date +%s)
{ echo "=== FULL REBUILD: $((END - START))s total ==="; echo "Log: $LOG"; } | tee -a "$LOG"

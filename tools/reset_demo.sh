#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# reset_demo.sh -- clean slate between judging sessions. ZERO CREDITS.
#
# Clears APP.ACTION_FEEDBACK, the one table in this project a user writes
# (sql/19_app_objects.sql). That's the only state a demo run leaves behind --
# every Accept/Reject click on the Customer 360 screen writes a row here, and
# the cockpit sidebar's "N RM decisions recorded" reads it back. Nothing else
# in the app has session state to clear; GOLD.NEXT_BEST_ACTION and everything
# upstream of it is deterministic SQL, unaffected by clicking through a demo.
#
# Also resumes both Cortex Search services (sql/10c), in case a previous
# session ended with sql/10b's suspend and the next demo would otherwise
# cold-start on its first search query.
#
# Does NOT re-run run.sh. Do not re-run run.sh between demos -- it drops and
# regenerates the entire corpus and spends real credits for no demo benefit.
# ---------------------------------------------------------------------------
set -euo pipefail
cd "$(dirname "$0")/.."

CONN="${1:-coco}"

echo "### clearing APP.ACTION_FEEDBACK"
snow sql -c "$CONN" -q "TRUNCATE TABLE APP.ACTION_FEEDBACK;"

echo "### resuming Cortex Search services (sql/10c) -- costs nothing, may take a minute to warm"
snow sql -c "$CONN" -f sql/10c_resume_search.sql

echo "### done -- sidebar should read '0 RM decisions recorded' on next app load"

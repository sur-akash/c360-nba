#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# run_tests.sh -- run the app test suite. Arguments go straight to pytest.
#
#   tools/run_tests.sh                    offline: no account, ZERO CREDITS
#   tools/run_tests.sh --live             + read-only checks on Snowflake
#                                           (a few seconds of COCO_WH, no AI)
#   tools/run_tests.sh --live-write       + Accept/Reject against the real
#                                           APP.ACTION_FEEDBACK; its rows are
#                                           deleted afterwards. Not during a demo.
#   tools/run_tests.sh --with-agent       + one question to APP.RM_COPILOT
#                                           (~0.2 credits)
#   tools/run_tests.sh -k action          only the Accept/Reject tests
#
# Connection: `coco` unless C360_CONNECTION or --connection says otherwise.
# Virtualenv: /tmp/c360venv (the one tools/preview.py uses) unless C360_VENV
# is set; created and filled from requirements-dev.txt if it is missing.
# ---------------------------------------------------------------------------
set -euo pipefail
cd "$(dirname "$0")/.."

VENV="${C360_VENV:-/tmp/c360venv}"
if [ ! -x "$VENV/bin/python" ]; then
  echo "### creating $VENV"
  python3 -m venv "$VENV"
fi
if ! "$VENV/bin/python" -c "import pytest, streamlit, altair, pandas, snowflake.snowpark" 2>/dev/null; then
  echo "### installing requirements-dev.txt into $VENV"
  "$VENV/bin/pip" install -q -r requirements-dev.txt
fi

exec "$VENV/bin/python" -m pytest "$@"

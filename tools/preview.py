"""
preview.py — serve app/streamlit_app.py locally for screenshots.

LOCAL DEVELOPMENT TOOL. Not staged, not part of the deployed app.

Streamlit in Snowflake supplies the Snowpark session; running the same file
locally does not, so this wrapper opens a session from the `coco` connection
first and then executes the app unchanged. get_active_session() inside the app
finds the session created here, so app/streamlit_app.py needs no local/remote
branching and the file that renders locally is byte-identical to the one on the
stage.

    /tmp/c360venv/bin/streamlit run tools/preview.py --server.port 8888 \
        --server.headless true
"""

import runpy
import warnings
from pathlib import Path

warnings.filterwarnings("ignore")

from snowflake.snowpark import Session                       # noqa: E402
from snowflake.snowpark.context import get_active_session     # noqa: E402

try:
    get_active_session()
except Exception:  # noqa: BLE001 - no session in this process yet
    Session.builder.config("connection_name", "coco").create()

APP = Path(__file__).resolve().parent.parent / "app" / "streamlit_app.py"
runpy.run_path(str(APP), run_name="__main__")

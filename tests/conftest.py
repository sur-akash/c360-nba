"""
conftest.py -- shared fixtures for the Streamlit app test suite.

Two ways the same tests reach the app:

  offline (default)   a FakeSession stands in for Snowflake. No account, no
                      warehouse, no credits. This is what `pytest` runs.
  live (--live)       a real Snowpark session on the `coco` connection. Read-only
                      unless --live-write is also given; never calls the agent
                      unless --with-agent is also given.

Either way the app file is executed unmodified by Streamlit's AppTest, with
snowflake.snowpark.context.get_active_session patched to hand back the session
under test -- the same seam tools/preview.py uses, so the file that passes here
is byte-identical to the one on the stage.
"""

from __future__ import annotations

import os
import sys
import warnings
from pathlib import Path

import pytest

warnings.filterwarnings("ignore")
# Streamlit logs a line per bare-mode call and per deprecated argument; at the
# default level that buries the test report.
import logging                                           # noqa: E402
logging.getLogger("streamlit").setLevel(logging.ERROR)

TESTS = Path(__file__).resolve().parent
ROOT = TESTS.parent
APP = ROOT / "app" / "streamlit_app.py"
sys.path.insert(0, str(TESTS))

import streamlit as st                                  # noqa: E402
from streamlit.testing.v1 import AppTest                # noqa: E402

from fake_snowflake import FakeSession                  # noqa: E402


# -----------------------------------------------------------------------------
# Compatibility: AppTest on older Streamlit keeps elements from before st.rerun()
# -----------------------------------------------------------------------------
# When the app calls st.rerun(), the script runs twice inside one AppTest.run().
# Newer Streamlit clears the first run's elements when the second starts. Older
# releases (1.50, the newest that installs on Python 3.9) do not: the tree is
# the second run laid over the first, so a closed form's text area or a chat
# message drawn before the rerun is still "on the page", and the next run()
# raises KeyError reading a widget that no longer exists.
#
# A browser never shows those elements -- the frontend drops them when the run
# finishes. This makes AppTest do the same, the way newer Streamlit does it
# itself: empty the message queue each time a script run starts. It is applied
# only where Streamlit does not already do it, and it touches the test harness,
# not the app.

def _keep_only_the_last_script_run():
    import inspect
    from streamlit.testing.v1 import local_script_runner as lsr

    if "forward_msg_queue.clear" in inspect.getsource(lsr.LocalScriptRunner):
        return                                          # this Streamlit already does it

    original_init = lsr.LocalScriptRunner.__init__

    def __init__(self, *args, **kwargs):
        original_init(self, *args, **kwargs)

        def drop_previous_run(sender, event, **_):
            if event == lsr.ScriptRunnerEvent.SCRIPT_STARTED:
                self.forward_msg_queue.clear()

        self.on_event.connect(drop_previous_run, weak=False)

    lsr.LocalScriptRunner.__init__ = __init__


_keep_only_the_last_script_run()


# -----------------------------------------------------------------------------
# Command line
# -----------------------------------------------------------------------------

def pytest_addoption(parser):
    g = parser.getgroup("c360", "C360 app tests")
    g.addoption("--live", action="store_true",
                help="Run the live suite against Snowflake (read-only, no AI credits).")
    g.addoption("--live-write", action="store_true",
                help="Also run live tests that INSERT into APP.ACTION_FEEDBACK. "
                     "Rows are deleted afterwards. Implies --live.")
    g.addoption("--with-agent", action="store_true",
                help="Also ask APP.RM_COPILOT one question. Spends Cortex credits. "
                     "Implies --live.")
    g.addoption("--connection", default=os.environ.get("C360_CONNECTION", "coco"),
                help="Snowflake connection name from ~/.snowflake/connections.toml "
                     "(default: $C360_CONNECTION or 'coco').")


def pytest_collection_modifyitems(config, items):
    live = (config.getoption("--live") or config.getoption("--live-write")
            or config.getoption("--with-agent"))
    gates = [
        ("live", live, "needs --live (uses the Snowflake connection)"),
        ("live_write", config.getoption("--live-write"),
         "needs --live-write (inserts into, then cleans, APP.ACTION_FEEDBACK)"),
        ("agent", config.getoption("--with-agent"),
         "needs --with-agent (spends Cortex credits)"),
    ]
    for item in items:
        for marker, enabled, why in gates:
            if marker in item.keywords and not enabled:
                item.add_marker(pytest.mark.skip(reason=why))


# -----------------------------------------------------------------------------
# Running the app
# -----------------------------------------------------------------------------

def _bind(monkeypatch, session):
    """Make get_active_session() inside the app return `session`."""
    import snowflake.snowpark.context as ctx
    monkeypatch.setattr(ctx, "get_active_session", lambda: session)
    # q() is @st.cache_data and the cache is process-wide: without this, a frame
    # cached by one test's session would be served to the next test's app.
    st.cache_data.clear()


def launch(timeout=60) -> AppTest:
    """Start the app on its landing screen and fail fast if it raised."""
    at = AppTest.from_file(str(APP), default_timeout=timeout)
    at.run()
    assert_clean(at, "initial load")
    return at


def goto(at: AppTest, screen: str) -> AppTest:
    """Click a sidebar nav button. Nav is four buttons keyed nav_<name>."""
    at.button(key=f"nav_{screen}").click().run()
    assert_clean(at, f"navigating to {screen}")
    assert at.session_state["nav"] == screen
    return at


def assert_clean(at: AppTest, where=""):
    if at.exception:
        e = at.exception[0]
        detail = "\n".join(getattr(e, "stack_trace", []) or [])
        pytest.fail(f"app raised {where}: {e.value}\n{detail}")
    assert not at.error, f"st.error shown {where}: {[e.value for e in at.error]}"


def page(at: AppTest) -> str:
    """Everything rendered as markdown or caption, as one searchable string.
    The app builds its UI from HTML in st.markdown, so this is the page text."""
    return "\n".join([m.value for m in at.markdown] + [c.value for c in at.caption])


def button(at: AppTest, label: str):
    """A button by its visible label -- form submit buttons carry no key."""
    hits = [b for b in at.button if b.label == label]
    assert hits, f"no button labelled {label!r}; have {[b.label for b in at.button]}"
    return hits[0]


def click_through_disabled(at: AppTest, key: str) -> AppTest:
    """Click a button that should be disabled, to prove the write behind it is
    guarded as well. Older AppTest delivers the click (like one already in
    flight when the card re-rendered); newer AppTest refuses, as a browser does.
    Either way the caller then asserts nothing was written."""
    try:
        at.button(key=key).click().run()
    except Exception as e:  # noqa: BLE001 - only the "disabled widget" refusal is expected
        if "disabled" not in str(e):
            raise
    assert_clean(at, f"clicking disabled button {key}")
    return at


def expander(at: AppTest, startswith: str):
    hits = [e for e in at.expander if e.label.startswith(startswith)]
    assert hits, (f"no expander starting {startswith!r}; "
                  f"have {[e.label for e in at.expander]}")
    return hits[0]


# -----------------------------------------------------------------------------
# Offline fixtures
# -----------------------------------------------------------------------------

@pytest.fixture
def fake(monkeypatch) -> FakeSession:
    """A fresh fixture book, bound as the app's session."""
    session = FakeSession()
    _bind(monkeypatch, session)
    return session


@pytest.fixture
def app(fake) -> AppTest:
    """The app, loaded on the cockpit against the fixture book."""
    return launch()


@pytest.fixture
def customer(app) -> AppTest:
    """The app on Customer 360, showing the default customer."""
    return goto(app, "Customer 360")


# -----------------------------------------------------------------------------
# Live fixtures
# -----------------------------------------------------------------------------

@pytest.fixture(scope="session")
def live_session(request):
    name = request.config.getoption("--connection")
    try:
        from snowflake.snowpark import Session
        session = Session.builder.config("connection_name", name).create()
    except Exception as e:  # noqa: BLE001 - reported, not raised
        pytest.exit(f"could not open Snowflake connection '{name}': {e}\n"
                    f"Check `snow connection test -c {name}`, or pass --connection.",
                    returncode=2)
    # The app relies on these being set by the Streamlit object; a bare
    # connection may default elsewhere.
    session.sql("USE DATABASE C360_NBA").collect()
    session.sql("USE SCHEMA APP").collect()
    yield session
    session.close()


@pytest.fixture
def live(monkeypatch, live_session):
    _bind(monkeypatch, live_session)
    return live_session


def rows(session, sql):
    """Run a query on a live session; list of dicts with UPPERCASE keys.
    SHOW/DESCRIBE return lowercase quoted names, so keys are normalised."""
    return [{str(k).strip('"').upper(): v for k, v in r.as_dict().items()}
            for r in session.sql(sql).collect()]


def one(session, sql):
    got = rows(session, sql)
    assert len(got) == 1, f"expected exactly one row, got {len(got)} from: {sql}"
    return got[0]


def scalar(session, sql):
    return next(iter(one(session, sql).values()))


# -----------------------------------------------------------------------------
# The app's pure functions, without running the app
# -----------------------------------------------------------------------------

@pytest.fixture(scope="session")
def appns() -> dict:
    """Top-level functions and constants of app/streamlit_app.py as a namespace.

    The app is a script: importing it would open a session and draw a screen.
    This executes only its imports, assignments and function definitions, and
    skips every statement that renders (bare expressions and `with` blocks) and
    the one that fetches the session -- so grp(), inr(), lit() and the rest can
    be unit-tested directly, at the line they are defined on.
    """
    import ast
    tree = ast.parse(APP.read_text(encoding="utf-8"), filename=str(APP))
    keep = []
    for node in tree.body:
        if isinstance(node, (ast.Expr, ast.With)):
            continue
        if isinstance(node, ast.Assign) and "get_active_session" in ast.dump(node.value):
            continue
        keep.append(node)
    ns = {"__name__": "c360_app_under_test"}
    exec(compile(ast.Module(body=keep, type_ignores=[]), str(APP), "exec"), ns)
    return ns

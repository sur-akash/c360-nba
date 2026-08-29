"""
verify_app.py — execute every screen of app/streamlit_app.py headlessly.

LOCAL DEVELOPMENT TOOL. Not staged, not part of the deployed app, and not
referenced by any script in sql/.

The problem it solves: sql/20_streamlit.sql can deploy an app whose Python has
never once been executed. CREATE STREAMLIT validates that the main file exists on
the stage, not that importing it succeeds, so a NameError on screen 4 ships
green. This runs each screen through Streamlit's own AppTest harness against the
live COCO_BUILDER connection and reports any exception.

    /tmp/c360venv/bin/python tools/verify_app.py              # free
    /tmp/c360venv/bin/python tools/verify_app.py --with-agent # spends credits

WHY --with-agent EXISTS AND WHY IT IS NOT THE DEFAULT
The first version of this script stopped at each screen's idle state. That passed
all four screens while ask_agent() still contained a real bug -- it unwrapped the
suggested_queries block one level too deep and raised "'list' object has no
attribute 'get'" the first time a question was asked. The idle ASK screen never
calls ask_agent, so the check could not have caught it, and the bug surfaced only
in a screenshot.

Exercising it costs Cortex credits per run (orchestration tokens plus 0.067
credits when the agent routes to Cortex Analyst), so it is opt-in rather than
default: a verification script that silently spends money every time somebody
runs it is a script people stop running.
"""

import sys
import warnings
from pathlib import Path

warnings.filterwarnings("ignore")

from snowflake.snowpark import Session          # noqa: E402
from streamlit.testing.v1 import AppTest        # noqa: E402

APP = Path(__file__).resolve().parent.parent / "app" / "streamlit_app.py"
SCREENS = ["Portfolio cockpit", "Customer 360", "Ask", "Impact"]
AGENT_QUESTION = "How many actions did compliance block, and which rule blocked the most?"


def main(with_agent: bool) -> int:
    # AppTest runs the script in this process, so a session created here is the
    # one get_active_session() inside the app will find.
    Session.builder.config("connection_name", "coco").create()
    print(f"connected · verifying {APP.name}"
          f"{' · including a live agent call' if with_agent else ''}\n")

    failures = []
    for screen in SCREENS:
        at = AppTest.from_file(str(APP), default_timeout=300)
        at.run()

        if at.exception:
            failures.append((screen, "initial load", at.exception[0].value))
            print(f"  FAIL  {screen:<20} load: {at.exception[0].value}")
            continue

        if screen != SCREENS[0]:
            # Nav is four sidebar buttons keyed nav_<name>, not a radio.
            at.button(key=f"nav_{screen}").click().run()
            if at.exception:
                failures.append((screen, "after nav", at.exception[0].value))
                print(f"  FAIL  {screen:<20} {at.exception[0].value}")
                continue

        print(f"  PASS  {screen:<20} "
              f"{len(at.markdown)} markdown · {len(at.button)} buttons · "
              f"{len(at.expander)} expanders")

        # The ASK screen's real work happens only once a question is submitted.
        if screen == "Ask" and with_agent:
            at.chat_input[0].set_value(AGENT_QUESTION).run()
            if at.exception:
                failures.append((screen, "agent call", at.exception[0].value))
                print(f"  FAIL  {screen:<20} agent: {at.exception[0].value}")
            else:
                replies = [m for m in at.markdown if m.value]
                print(f"  PASS  {'Ask (answered)':<20} "
                      f"{len(replies)} markdown blocks · "
                      f"{len(at.expander)} expanders (reasoning trace)")

    print()
    if failures:
        print(f"{len(failures)} check(s) failed")
        for s, where, err in failures:
            print(f"\n--- {s} ({where}) ---\n{err}")
        return 1

    print("all screens execute cleanly")
    return 0


if __name__ == "__main__":
    sys.exit(main("--with-agent" in sys.argv))

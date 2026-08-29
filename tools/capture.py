"""
capture.py — screenshot each screen of the locally served app.

LOCAL DEVELOPMENT TOOL. Not staged, not part of the deployed app.

Drives Playwright against tools/preview.py on localhost. Used because Snowsight
cannot be driven headlessly here -- browser login needs a password or SSO and the
only credential available for this account is a programmatic access token, which
Snowsight's web login does not accept. The app code, the views and the data are
identical either way; what these images lack is the Snowsight chrome around the
iframe.

    /tmp/c360venv/bin/python tools/capture.py
"""

import sys
import time
from pathlib import Path

from playwright.sync_api import sync_playwright

URL = "http://localhost:8888"
OUT = Path(__file__).resolve().parent.parent / "docs" / "screens"
VIEWPORT = {"width": 1680, "height": 1150}

ASK_QUESTION = (
    "How many actions did compliance block, and which rule blocked the most?"
)


def settle(page, timeout=180):
    """Wait for Streamlit to finish running.

    The status widget appears while a script run is in flight and is removed when
    it finishes, so its absence for two consecutive polls is the idle signal.
    Polling twice matters: between two reruns the widget briefly vanishes, and a
    single check catches that gap and screenshots a half-rendered page.
    """
    quiet = 0
    deadline = time.time() + timeout
    while time.time() < deadline:
        running = page.locator('[data-testid="stStatusWidget"]').count()
        quiet = 0 if running else quiet + 1
        if quiet >= 3:
            page.wait_for_timeout(700)
            return True
        page.wait_for_timeout(500)
    return False


def nav(page, label):
    page.get_by_role("button", name=label, exact=True).first.click()
    settle(page)


def shot(page, name):
    """Capture the whole screen.

    Streamlit renders into an internal scrolling container rather than letting
    the document grow, so Playwright's full_page=True captures only what the
    viewport covers and silently crops everything above the current scroll
    position -- the first run of this script produced four screenshots each
    missing its own page title. The fix is to grow the viewport to the content
    instead of scrolling: measure the tallest scrollHeight on the page, resize to
    it, let Streamlit reflow, then capture.
    """
    OUT.mkdir(parents=True, exist_ok=True)

    page.evaluate("""() => {
        document.querySelectorAll('*').forEach(el => {
            if (el.scrollHeight > el.clientHeight) el.scrollTop = 0;
        });
        window.scrollTo(0, 0);
    }""")
    page.wait_for_timeout(250)

    height = page.evaluate("""() => {
        let h = document.body.scrollHeight;
        document.querySelectorAll('section, div').forEach(el => {
            if (el.scrollHeight > h && el.scrollHeight < 30000) h = el.scrollHeight;
        });
        return Math.min(h + 120, 20000);
    }""")
    page.set_viewport_size({"width": VIEWPORT["width"], "height": int(height)})
    page.wait_for_timeout(900)

    path = OUT / f"{name}.png"
    page.screenshot(path=str(path), full_page=True)
    page.set_viewport_size(VIEWPORT)
    page.wait_for_timeout(400)

    kb = path.stat().st_size // 1024
    print(f"  wrote {path.relative_to(OUT.parent.parent)}  ({kb} KB, {int(height)}px tall)")


def main() -> int:
    with sync_playwright() as p:
        browser = p.chromium.launch(headless=True)
        page = browser.new_page(viewport=VIEWPORT, device_scale_factor=2)
        page.goto(URL, wait_until="domcontentloaded", timeout=60000)

        if not settle(page, timeout=240):
            print("app did not settle", file=sys.stderr)
            return 1
        print("app loaded")

        # 1 — cockpit -------------------------------------------------------
        shot(page, "1-portfolio-cockpit")

        # 2 — customer 360 --------------------------------------------------
        nav(page, "Customer 360")
        shot(page, "2-customer-360")

        # 2b — an interaction expanded into its transcript and signals.
        # Worth its own frame: the transcript and the extracted signals behind it
        # are the point of the unstructured layer, and they are collapsed on load.
        # Matched on "Call Transcript" rather than the raw EVENT_TYPE, because the
        # app renders event labels through words() -- clicking "INTERACTION"
        # silently matched nothing and produced a frame identical to 2.
        try:
            page.get_by_text("Call Transcript", exact=False).first.click()
            settle(page)
            shot(page, "2b-customer-360-transcript")
        except Exception as e:  # noqa: BLE001
            print(f"  (skipped transcript frame: {e})")

        # 3 — ask -----------------------------------------------------------
        nav(page, "Ask")
        shot(page, "3-ask-idle")

        box = page.get_by_placeholder("Ask about a customer or the book")
        box.click()
        box.fill(ASK_QUESTION)
        box.press("Enter")
        print(f"  asked: {ASK_QUESTION}")
        settle(page, timeout=300)

        # Open the reasoning expander so the tool calls and generated SQL show.
        try:
            page.get_by_text("Reasoning ·", exact=False).first.click()
            settle(page)
        except Exception as e:  # noqa: BLE001
            print(f"  (could not open reasoning expander: {e})")
        shot(page, "3-ask-answered")

        # 4 — impact --------------------------------------------------------
        nav(page, "Impact")
        shot(page, "4-impact")

        browser.close()
    print("\ndone")
    return 0


if __name__ == "__main__":
    sys.exit(main())

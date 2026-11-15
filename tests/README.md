# Tests for the Streamlit app

The suite runs `app/streamlit_app.py` unmodified through Streamlit's `AppTest`
harness. The only seam is `get_active_session()`, which is patched to return the
session under test — the same seam `tools/preview.py` uses.

```bash
tools/run_tests.sh                 # offline: no account, zero credits (about a minute)
tools/run_tests.sh --live          # + read-only checks on Snowflake, no AI calls
tools/run_tests.sh --live-write    # + Accept/Reject on the real table, then cleanup
tools/run_tests.sh --with-agent    # + one real question to APP.RM_COPILOT (~0.2 credits)
tools/run_tests.sh -k action       # just the Accept/Reject flow
```

Connection is `coco` unless `C360_CONNECTION` or `--connection NAME` says otherwise.

## What is where

| File | Mode | Covers |
|---|---|---|
| `test_action_flow.py` | offline | Accept, Reject-with-reason, Cancel, change of mind, free-text escaping, cache refresh, counters |
| `test_screens.py` | offline | Cockpit, Customer 360, Ask (agent mocked), Impact arithmetic, navigation |
| `test_helpers.py` | offline | Indian digit grouping, INR formatting, label and severity encodings, `lit()` |
| `test_repo_config.py` | offline | App SQL vs `contract.py` vs `sql/`, `environment.yml`, theme, `run.sh` ordering, AGENTS.md invariants |
| `test_live_contract.py` | `--live` | Every object and column the app reads; cross-screen reconciliation; deployment and grants |
| `test_live_app.py` | `--live` | All four screens on real data; Customer 360 across eleven customer states; agent behind `--with-agent` |
| `test_live_action_flow.py` | `--live-write` | The write-back against the real `APP.ACTION_FEEDBACK` |
| `contract.py` | — | The objects and columns the app depends on, as data |
| `fake_snowflake.py` | — | Stand-in session and a four-customer fixture book |

## How the offline mode stays honest

`fake_snowflake.py` does not run SQL; it answers each query the app is known to
send. Three rules keep that from proving nothing:

- A query it does not recognise raises `UnroutedSQL`. Add a route and a
  `contract.py` entry when you add a query to the app.
- Every frame it serves is checked against `contract.py`, and
  `test_live_contract.py` checks the same contract against the warehouse.
- The `INSERT` is parsed with Snowflake's string-literal rules and held to the
  table's NOT NULL and CHECK constraints.

## `--live-write`

Clicks real buttons, so it inserts real rows, then deletes exactly the rows it
added (by `FEEDBACK_ID`, test customer and `CURRENT_USER()`). Do not run it while
recording decisions in the deployed app as the same user: a decision made on the
test customer during the run would be deleted with the test rows.

## What no test here can cover

The app running inside Snowsight itself. Local runs use your own session, so
anything that only bites under owner's rights cannot be reproduced locally. The
case that matters: `DECIDED_BY` is `CURRENT_USER()` and NOT NULL, and Streamlit
in Snowflake needs the app owner role to hold `READ SESSION` for a context
function to resolve. `sql/18b_agent_grants_admin.sql` grants it and
`test_live_contract.py::test_app_owner_role_holds_read_session` checks the
account, but the only complete proof is clicking Accept once in the deployed app
after any redeploy.

## Streamlit versions

Verified on Streamlit 1.50 (the newest that installs on Python 3.9) and 1.65.
`conftest.py` carries one compatibility shim for the older version: its test
harness keeps elements drawn before `st.rerun()`, which a browser never shows.

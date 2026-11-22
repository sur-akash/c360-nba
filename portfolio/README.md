# Compass360 · public build (Postgres + Streamlit Community Cloud)

The Streamlit in Snowflake app in [`../app`](../app) runs only inside Snowflake.
This folder is the same app rebuilt to run anywhere: the full Snowflake export in
a Postgres database (Neon), the engine's views ported from Snowflake SQL, and the
app hosted on Streamlit Community Cloud.

| | Snowflake build (`app/`) | Public build (`portfolio/`) |
|---|---|---|
| Data | `C360_NBA` in Snowflake | the same 1,580,976 rows in Postgres |
| Engine views | Snowflake SQL, two dynamic tables | ported to Postgres, two materialized views |
| Cockpit, Customer 360, Impact | live | live, same numbers |
| Ask | Cortex Agent, live | 13 recorded runs of that agent, replayed unedited |
| Accept / Reject | written as `CURRENT_USER()` | written as `DEMO_VISITOR`, 30 per session |

The port is checked, not assumed: `db/validate.py` compares all 22 columns of
`APP.V_PORTFOLIO_KPI` with the row Snowflake produced (5,000 customers, 3,917
published actions, 12,435 suppressed, ₹52.14 Cr arrears exposure, …) and the row
counts of both materialized views (5,000 and 108,144). All match.

## What is in here

```
portfolio/
  streamlit_app.py          the app (SQLAlchemy + psycopg in place of Snowpark)
  requirements.txt          pinned to the Streamlit version it was tested on
  data/agent_runs.json      the 13 recorded agent runs the Ask screen replays
  db/
    setup_neon.py           one command: tables, load, views, check, app login
    00_helpers.sql          Postgres shims for IFF, COUNT_IF, DATEADD, DATEDIFF, ...
    01_tables.sql           the 48 tables, translated from Snowflake GET_DDL
    load_extract.py         loads c360_export.json.gz
    02_views.sql            the ported views
    validate.py             the check against Snowflake's numbers
    build_agent_runs.py     rebuilds data/agent_runs.json from evals/agent_runs/
```

## Set it up

**1. Create the database.** Sign up at [neon.com](https://neon.com) (free plan,
no card) and create a project. In **Connect**, copy the connection string. It
looks like `postgresql://neondb_owner:...@ep-....aws.neon.tech/neondb?sslmode=require`.
The data takes about 420 MB of the free plan's 1 GB.

**2. Load it.** From the repository root on your laptop:

```bash
python3 -m pip install "psycopg[binary]"
python3 portfolio/db/setup_neon.py \
  --dsn "PASTE_THE_OWNER_CONNECTION_STRING" \
  --file ~/Downloads/c360_export.json.gz
```

It uploads the export, builds the views, prints the KPI check (expect
`ALL MATCH`), and finishes by creating a login called `c360_app` that can read
the data and record decisions but cannot change or drop anything. **It prints
that login's connection string at the end. Copy it.** That is the one the
public app uses, so the owner password never leaves your laptop. Expect 10–20
minutes, most of it the upload.

**3. Deploy.** Push this branch to GitHub, then at
[share.streamlit.io](https://share.streamlit.io): **Create app** → deploy from
this repository → branch `portfolio-neon` → main file path
`portfolio/streamlit_app.py`. Under **Advanced settings → Secrets**, paste:

```toml
[connections.neon]
url = "THE_c360_app_CONNECTION_STRING_FROM_STEP_2"
```

Pick a custom subdomain (for example `compass360`) and deploy. The theme comes
from `.streamlit/config.toml` at the repository root.

## Things to know

- **Sleep.** Community Cloud puts an app to sleep after 12 hours without a
  visitor, and Neon pauses the database after 5 idle minutes. The first visit
  after a quiet spell takes a few seconds longer. Link to the app from a
  portfolio page rather than embedding it in an iframe: an embedded app cannot
  be woken from inside the frame.
- **Rebuilding.** `setup_neon.py --reset` drops the four schemas and rebuilds
  from the export. Recorded decisions are lost.
- **Never commit secrets.** `.streamlit/secrets.toml` is in `.gitignore`.

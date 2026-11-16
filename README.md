# c360-nba

A customer-360 and next-best-action engine for an Indian bank-and-insurer, built
entirely inside Snowflake. Structured contracts, claims, repayments and campaign
history on one side; contact-centre transcripts, emails, chats and adviser notes
on the other; a deterministic eligibility and expected-value layer in between;
and a Cortex Agent on top that has to justify every action it proposes.

Design rationale lives in **`PROJECT_BRIEF.md`**, agent working rules in
**`AGENTS.md`**, the planted customer segments and their measured recall in
**`docs/DATA_SEGMENTS.md`**, and measured cost in **`docs/COST.md`**.

## Layout

```
sql/00_bootstrap.sql          roles, warehouse, database, resource monitor
sql/02_schema_raw.sql         RAW DDL and deterministic PRNG helpers
sql/03_seed_raw.sql           5,000 customers and their structured history
sql/04_seed_interactions.sql  1,200 generated contact-centre artefacts
sql/05_curated_signals.sql    five AI functions per artefact, confidence-gated
sql/06_audio_demo.sql         real audio -> AI_TRANSCRIBE -> same grain as text
sql/07_curated_rollup.sql     per-customer interaction rollup
sql/08_gold_c360.sql          the customer spine and timeline
sql/09_semantic_view.sql      the five V_SV_ feeder views (the model is in 16)
sql/10_search_services.sql    two Cortex Search services
sql/10b_suspend_search.sql    stop paying for idle retrieval
sql/10c_resume_search.sql     bring it back up before a demo
sql/11_action_catalog.sql     18 actions, their tiers, margins and disclosures
sql/12_nba_eligibility.sql    GOLD.NBA_ELIGIBLE — every candidate, every rule
sql/13_nba_scoring.sql        deterministic propensity and expected value
sql/14_nba_reasoning.sql      the written rationale, validated
sql/15_nba_publish.sql        GOLD.NEXT_BEST_ACTION, then tries to break it
sql/16_semantic_view_nba.sql  GOLD.SV_CUSTOMER_360 for Cortex Analyst
sql/17_nba_tool.sql           APP.GET_NEXT_BEST_ACTIONS — the agent's action tool
sql/18_agent.sql              APP.RM_COPILOT — four tools
sql/18b_agent_grants_admin.sql  the grants the build role cannot make
sql/19_app_objects.sql        stage, ACTION_FEEDBACK, and the app's read views
sql/20_streamlit.sql          APP.C360_APP, the last object in the build
app/                          the Streamlit in Snowflake app
run.sh                        full rebuild, both non-SQL stage-copy steps included
tools/reset_demo.sh           clear demo state between judging sessions (zero credits)
tools/run_tests.sh            the app test suite; offline by default (zero credits)
tests/                        what it runs — see tests/README.md
docs/DEMO_SCRIPT.md           the 3-minute walkthrough, timed, beat by beat
evals/REPORT.md               consolidated pass rate across both eval suites
```

Every database object is created by a numbered script in `sql/`, run in order.
The rebuild has two non-SQL steps: copying the audio fixtures to
`RAW.AUDIO_STAGE` before `sql/06`, and copying `app/` to `APP.APP_STAGE` before
`sql/20`. `run.sh` sequences all of it; see `PROJECT_BRIEF.md` D2.

## The retrieval layer

Two services, because they answer two different questions.

| Service | Grain | Answers |
|---|---|---|
| `APP.SEARCH_INTERACTIONS` | one interaction | what the customer actually said |
| `APP.SEARCH_PRODUCT_DOCS` | one **clause** | which rule permits or blocks the action |

`SEARCH_INTERACTIONS` indexes 1,203 artefact bodies, three of them genuinely
transcribed calls. `SEARCH_PRODUCT_DOCS` indexes 224 clauses across 16 product
documents; the chunk boundary is the clause boundary, so a retrieved chunk is a
complete rule that can be quoted as evidence, keyed `PRODUCT_CODE#CLAUSE_ID`.

Known retrieval weaknesses are measured in `STEP 14` of
`sql/10_search_services.sql`.

## The agent

`APP.RM_COPILOT`, created by `sql/18_agent.sql`, has four tools.

| Tool | Type | Answers |
|---|---|---|
| `portfolio_analytics` | Cortex Analyst on `GOLD.SV_CUSTOMER_360` | how many / how much / which cohort / what trend |
| `interaction_search` | Cortex Search on `APP.SEARCH_INTERACTIONS` | what did the customer actually say |
| `product_terms` | Cortex Search on `APP.SEARCH_PRODUCT_DOCS` | is this permitted, and on what terms |
| `next_best_actions` | `APP.GET_NEXT_BEST_ACTIONS` | what should I do next for this person |

**The agent must call `next_best_actions` before recommending anything for a
named customer, and may never assemble a recommendation from the other three.**

Each of the other three tools can support a confident, well-evidenced, entirely
impermissible recommendation: interaction search will surface a customer asking
for a top-up loan and cannot see that they are 45 days past due. Only the engine
tool has read `GOLD.NBA_ELIGIBLE`, and only it returns what was **suppressed**.
It is deterministic SQL with no AI call, so it costs zero credits per lookup.

## Demo

`docs/DEMO_SCRIPT.md` is the timed walkthrough: three minutes, exact words for
each beat, built from real customers and real adversarial questions already run
through the agent.

Between judging sessions, run `tools/reset_demo.sh` to clear recorded
Accept/Reject decisions and resume the search services if they were suspended.
It costs zero credits.
**Do not re-run `run.sh` between demos**: it regenerates the entire corpus and
spends real credits for no demo benefit.

## What the evaluations found

`evals/REPORT.md` is the consolidated result across both eval suites: 33 cases,
20/20 governed on the analyst side, 12/13 on the agent side with 4/4 adversarial
refusals correct.

- **`evals/run_analyst_evals.py`**: 20 questions, scored first on whether the
  generated SQL went *through* `SEMANTIC_VIEW()` and only then on the number.
- **`evals/agent_transcripts.md`**: 13 questions including four adversarial. §2
  covers the governance failure the evals caught inside the agent; §4 covers
  what the adversarial questions establish.

## Cost

Total spend on the build account was **62.73 credits**: 44.38 for the CoCo CLI
build agent itself, 13.56 for AI functions, 3.20 for warehouse compute and the
rest for AI services. Corpus generation and enrichment cost 13.55 credits; the
two search services cost 0.74 to build and about 0.00003 credits a day to serve.

Three things worth knowing before spending anything:

- A resource monitor meters warehouse credits only. It saw 2.12 of the 62.73.
- `AI_COUNT_TOKENS` undercounts structured-output calls by nearly 2×, so it is
  a sizing tool and never a gate.
- A forced `ALTER … REFRESH` on a search service whose source is a join
  re-embeds the whole corpus. Run `sql/10b_suspend_search.sql` after a session.

`docs/COST.md` has the measurements, the queries and the reasoning.

## Limitations

- **The full rebuild (`run.sh`) is scripted and validated, not executed live.**
  When it was ready, about 18.9 trial credits remained against an estimated
  22–30 for the full sequence. The rebuild path is provable by inspection, not
  by a timed log.
- **One rationale row imputed distress it shouldn't have.** `sql/15_nba_publish.sql`
  (search `1887`) documents a rationale that framed a clean repayment history as
  "cash flow pressure". The action was correctly eligible; the sentence was wrong.
  The documented fix, a prompt rule, was not applied: one row, no recurrence.
- **"Sales versus care" is a false binary.** There is a third class of 339
  `RETENTION` actions that belong in neither bucket
  (`evals/agent_transcripts.md` §2).
- **Two eval partials remain partials.** S4 drops the terms half of a compound
  question once permission is refused; A5 cites a product code without its
  clause ID. Both are diagnosed in `evals/REPORT.md`, neither is fixed.
- **Guardrail-case coverage is 6, not the 8 originally scoped**: four
  adversarial refusals (A1–A4) plus two suppression-reporting questions (S2, S6).

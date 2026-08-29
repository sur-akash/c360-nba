# c360-nba

A customer-360 and next-best-action engine for an Indian bank-and-insurer, built
entirely inside Snowflake. Structured contracts, claims, repayments and campaign
history on one side; contact-centre transcripts, emails, chats and adviser notes
on the other; a deterministic eligibility and expected-value layer in between;
and a Cortex Agent on top that has to justify every action it proposes.

Design rationale, verified environment facts, and the risks that shaped the build
live in **`PROJECT_BRIEF.md`**. Agent working rules live in **`AGENTS.md`**. The
planted customer segments and their measured recall live in
**`docs/DATA_SEGMENTS.md`**.

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
sql/09_semantic_view.sql      GOLD.SV_CUSTOMER_360 for Cortex Analyst
sql/10_search_services.sql    two Cortex Search services  <-- retrieval layer
sql/10b_suspend_search.sql    stop paying for idle retrieval
sql/10c_resume_search.sql     bring it back up before a demo
```

Every database object is created by a numbered script in `sql/`, run in order.
There is exactly one documented non-SQL step in the whole rebuild (copying `app/`
to a stage before the Streamlit script) — see `PROJECT_BRIEF.md` D2.

## The retrieval layer

Two services, because they answer two different questions.

| Service | Grain | Answers |
|---|---|---|
| `APP.SEARCH_INTERACTIONS` | one interaction | what the customer actually said |
| `APP.SEARCH_PRODUCT_DOCS` | one **clause** | which rule permits or blocks the action |

`SEARCH_INTERACTIONS` indexes 1,203 artefact bodies — including three genuinely
transcribed calls — filterable on `customer_id`, `channel`, `intent`,
`sentiment_band`, `occurred_at` and `product_mentioned`.

`SEARCH_PRODUCT_DOCS` indexes 224 clauses across 16 product documents. The
chunk boundary is the clause boundary, not a character count, so a retrieved
chunk is a complete self-contained rule that can be quoted as evidence. Its key,
`PRODUCT_CODE#CLAUSE_ID` — `BNK_LOAN_PERS#ELIG-04` — is the citation an action's
justification carries. Every eligibility clause is grounded in the exact
thresholds from `RAW.PRODUCT_CATALOG`, verified for all 16 products, so a
citation cannot contradict the deterministic engine that produced the
recommendation.

The same content is readable as a document at `APP.PRODUCT_DOC.DOC_MARKDOWN`.

Known retrieval weaknesses are measured, not glossed — see `STEP 14` of
`sql/10_search_services.sql`, which carries reproducible probes for long-document
dilution, the top-heavy corpus, and the non-portability of absolute score
thresholds.

---

## Cost

> **Run `sql/10b_suspend_search.sql` whenever you finish a session.**
>
> It suspends both the serving and the indexing layer of both Cortex Search
> services. Resume with `sql/10c_resume_search.sql` before the next demo — allow
> a few minutes, since the first query against a resuming service blocks until
> the index is loaded.
>
> Suspend and resume are themselves **free** — measured, 0 embedding tokens. What
> is not free is a forced `ALTER … REFRESH`, which is why 10c does not contain
> one. See the third cost trap below.
>
> `AUTO_SUSPEND = 1800` is set on both services as a serving backstop. It is the
> safety net, not the plan: it does not suspend indexing, and it leaves a
> cold-start wait on the next query.

### The resource monitor does not mean what it looks like

`COCO_BUDGET` reads **2.12 of 60 credits** used. Actual account consumption for
the same month is **62.7 credits**:

| Service type | Credits |
|---|---:|
| `SNOWFLAKE_COCO_CLI` | 44.38 |
| `AI_FUNCTIONS` | 13.56 |
| `WAREHOUSE_METERING` | 3.20 |
| `AI_SERVICES` | 1.41 |
| `SNOWFLAKE_COCO_SNOWSIGHT` | 0.21 |
| **total** | **62.73** |

A resource monitor meters **warehouse credits only**. It does not see AI
functions, AI services, Cortex Search serving, or agent-CLI token usage — which
between them are 95% of what this project has actually spent. The 60-credit
ceiling with its hard suspend at 100% is real, and it is guarding the 5% of spend
that was never the risk.

So the monitor cannot be the gate. Cost has to be read directly, and that needs
the `coco_admin` (ACCOUNTADMIN) connection because `COCO_BUILDER` cannot see
`ACCOUNT_USAGE` at all:

```bash
# month to date, by service type
snow sql -c coco_admin -q "SELECT SERVICE_TYPE, ROUND(SUM(CREDITS_USED),3) cr
  FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY
  WHERE USAGE_DATE >= DATE_TRUNC('month', CURRENT_DATE()) GROUP BY 1 ORDER BY 2 DESC"

# AI functions, with input/output tokens split out (lags ~5 minutes)
snow sql -c coco_admin -q "SELECT MODEL_NAME, FUNCTION_NAME, ROUND(SUM(CREDITS),5) cr
  FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_AI_FUNCTIONS_USAGE_HISTORY
  WHERE START_TIME >= DATEADD(day,-1,CURRENT_TIMESTAMP()) GROUP BY 1,2 ORDER BY 3 DESC"

# Cortex Search: embedding tokens and serving, per service, per day
snow sql -c coco_admin -q "SELECT SERVICE_NAME, CONSUMPTION_TYPE,
    ROUND(SUM(CREDITS),5) cr, SUM(TOKENS) tok
  FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_SEARCH_DAILY_USAGE_HISTORY
  WHERE USAGE_DATE >= DATEADD(day,-7,CURRENT_DATE()) GROUP BY 1,2 ORDER BY 3 DESC"
```

### What each milestone actually cost

| Milestone | Projected | Measured |
|---|---:|---:|
| M3 — corpus generation and AI enrichment | 15 (ceiling) | 13.55 |
| M7 — the two search services | 0.72–1.22 | **0.74** |

M7 broken down, all figures from billing rather than estimate:

| Item | Credits |
|---|---:|
| 16 product documents, `claude-sonnet-4-5` structured output | 0.630 |
| Interaction corpus embeddings (396,223 tokens) | 0.020 |
| Document corpus embeddings (29,862 tokens) | 0.0015 |
| Warehouse, two index builds | ~0.09 |
| Serving, both services, per day resumed | 0.00003 |
| *(paid during development: two avoidable re-embeds — see trap 3)* | *0.040* |

Serving at this corpus size is negligible — 8 MB of indexed data across both
services, 0.00003 credits/day. That is stated plainly rather than inflated to
justify the suspend habit. The reason to suspend is not the serving meter; it is
that indexing on a joined source has a measured re-embed hazard, described below.

### Three cost traps found the hard way

**A credit ceiling covers the whole milestone, not the script in front of you.**
This is `AGENTS.md`'s first rule and it exists because M3 broke it: generation
came in at 2.33 against a 15-credit ceiling and was reported as comfortably
inside budget, after which enrichment — a different file, five AI calls per row —
spent 11.2 more. Per-row enrichment cost 4.8× the generation of the corpus it
read. Enumerate every AI call across every file before spending, and report
spent/remaining at each gate.

**`AI_COUNT_TOKENS` is a sizing tool, never a gate.** It projected 929 input
tokens per document against 1,793 actually billed — a 1.93× undercount that
independently reproduces the 1.85× recorded in `PROJECT_BRIEF.md` R8, and for the
same reason: the `response_format` schema bills as input and the counter has no
argument through which to receive it. It also counts input only, so for any
generative call it is a floor. Related: it returns **NULL, silently**, for
embedding models in every argument form, which made a `> 512` chunk-size
assertion pass over 224 chunks it had never measured.
`SNOWFLAKE.CORTEX.COUNT_TOKENS` works and is used instead.

**A forced `ALTER … REFRESH` re-embeds the whole corpus when the source query
contains a join.** `sql/10c` originally ended with a `REFRESH` on both services,
on the reasoning that forcing the change check was cheap insurance against stale
evidence. Isolated by running each variant and reading billing after each:

| Action | Embedding tokens billed |
|---|---:|
| `SUSPEND` then `RESUME` | **0** |
| `SUSPEND`, `RESUME`, then `REFRESH` — `SEARCH_INTERACTIONS` | **396,223** |
| the same `REFRESH` — `SEARCH_PRODUCT_DOCS` | **0** |

Both services declare a primary key and both report `REFRESH_MODE = INCREMENTAL`.
The difference is the source: `SEARCH_PRODUCT_DOCS` reads a single
`MERGE`-maintained table, so change tracking can prove nothing changed;
`SEARCH_INTERACTIONS` reads a **view joining two tables**, and the forced refresh
recomputes every embedding instead. This is the Cortex Search docs' advice about
keeping the source query simple, priced in credits.

Two full re-embeds were paid before the cause was pinned down, and they were
first misattributed to `CREATE OR REPLACE VIEW` on the source — which was then
measured and found to be free. The `REFRESH` is gone from 10c; the join is kept,
because three of the six filter attributes live in `CURATED` and filtering on
them is the point. If the corpus ever starts changing, materialise that join into
its own `MERGE`-maintained table, exactly as the chunk table already is.

Still open, because it is a day-scale event that cannot be observed inside one
session: if a *forced* refresh over the join re-embeds everything, the *daily
scheduled* refresh may too — ~0.02 credits/day on a corpus that never changes.
Suspending indexing via `10b` is the conservative hedge until that has been
watched over a full day.

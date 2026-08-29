# Agent instructions — c360-nba

## Credit ceilings cover the whole milestone, not one script

When a credit ceiling is given, it applies to **total AI spend for the milestone**,
not to whichever script is being written at the time. Sum every AI call across every
file in the milestone against the one number.

This exists because it was got wrong once. M3's ceiling was 15 credits, stated while
discussing Part A (corpus generation). Part A came in at 2.33 and was reported as
comfortably inside budget — but Part B (enrichment, a different file, five AI
functions per row) then spent 11.2 more, taking the milestone to 13.55. Nothing
paused, because the ceiling had been silently scoped to one script.

**What to do instead:**

1. **Enumerate every AI call in the milestone before spending anything**, including
   the ones in files not yet written. In M3 that was five functions × 1,203 rows in
   `05`, plus generation in `04`, plus `AI_TRANSCRIBE` in `06` — not just `04`.
2. **Keep a running total against the ceiling and report it at every gate**, as
   *spent / remaining*, not as "this script cost X".
3. **Stop and ask when a projection would cross the ceiling**, even mid-milestone
   and even when the current script is individually cheap.
4. **If a ceiling seems to be scoped to one script, say so and ask** rather than
   assuming the narrower reading. The narrower reading is the one that produces an
   overspend.

Corollary: a milestone's cost is dominated by whichever layer runs N AI calls per
row, not by the layer that generated the rows. Per-row enrichment was 4.8× the cost
of generating the corpus it read.

Cost-measurement method, and the two ways it has produced wrong numbers here
(`AI_COUNT_TOKENS` undercounting ~1.85×, and a pilot-rate division error that halved
every Part B estimate): `PROJECT_BRIEF.md` R8. Read it before projecting a batch.

## Where the other hard-won constraints live

Don't rediscover these — they are written down:

| Topic | Where |
|---|---|
| Cost measurement, `AI_COUNT_TOKENS` limits, per-model credit rates | `PROJECT_BRIEF.md` R8 |
| Corpus reproducibility boundary (`GEN_RAW`, temperature 0.9) | `PROJECT_BRIEF.md` D5 |
| `SENTIMENT_TREND` load-bearing, raw slope diagnostic-only | `PROJECT_BRIEF.md` D6 |
| Planted segments, their exact predicates, and measured recall/precision | `docs/DATA_SEGMENTS.md` |
| Which columns downstream may and may not rank on | column `COMMENT`s in `CURATED` |

## Two invariants that must not regress

- **`RAW.CUSTOMER_SEGMENT_TRUTH` is quarantined.** Nothing in `CURATED`, `GOLD` or
  `APP` may reference it. Only `evals/` reads it. An engine that can see the answer
  key is not demonstrating anything.
- **Every AI-spending script is incremental.** Paid output lands in its own
  `IF NOT EXISTS` table and is never regenerated; typed columns are free views over
  it. Re-running any script in `sql/` must cost zero credits — verified for `04`–`07`.

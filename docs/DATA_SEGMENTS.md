# Planted data segments

Every pattern the NBA engine is supposed to discover was put into `RAW` on
purpose, by `sql/03_seed_raw.sql`. This file records what was planted, how many
of each, and the **exact SQL predicate** that finds it — so a demo claim of
"the engine found this" can be checked against a number rather than taken on
trust.

- Generator: `sql/02_schema_raw.sql` (schema + seeded RNG) and
  `sql/03_seed_raw.sql` (data).
- Ground truth: `RAW.CUSTOMER_SEGMENT_TRUTH`.
- Calendar anchor: `RAW.AS_OF()`, currently `CURRENT_DATE`.

---

## 1. How reproducibility works

The brief asked for `UNIFORM` / `NORMAL` / `RANDOM(seed)`. Those are seeded, but
only deterministic with respect to *evaluation order*, and `GENERATOR` scans are
parallelised. Which row receives which draw can therefore change between runs,
between warehouse sizes, and after a cluster resize — meaning a planted segment
could silently move from one customer to another between rebuilds.

So every draw is derived from the row's own identity instead:

```
value = f( RAW.SEED() , purpose-salt , row key )      -- via HASH()
```

| Function | Returns |
|---|---|
| `RAW.SEED()` | the single master seed literal |
| `RAW.AS_OF()` | calendar anchor for every generated date |
| `RAW.RND(k)` | uniform `[0,1)` |
| `RAW.RND_INT(k, lo, hi)` | uniform integer, inclusive |
| `RAW.RND_BOOL(k, p)` | Bernoulli |
| `RAW.RND_NORM(k, mean, sd)` | normal, Irwin–Hall n=3 |
| `RAW.RND_NORM_CLAMP(k, mean, sd, lo, hi)` | normal, clamped |
| `RAW.RND_PICK(k, array)` | uniform categorical pick |

Measured over 5,000 draws: uniform mean `0.4992`, normal sd `14.985` against a
requested `15`. The distributions are intact; only the source of entropy
changed.

**Reproducibility is exact for a given `(SEED, run date)` pair.** Dates slide
with `RAW.AS_OF()` deliberately, so "renewal in the next 30 days" and "complaint
in the last 60 days" stay true whenever the demo runs. Pin `RAW.AS_OF()` to a
literal if you need frozen dates.

### Verified, not assumed

`HASH_AGG` fingerprints were taken over all eight generated tables, the
generator was re-run **on a SMALL warehouse instead of XSMALL** to force a
different query plan and a different degree of parallelism, and the fingerprints
were compared:

```
CARD                    -4394391920450500924
CUSTOMER                -4095300837529402317
CUSTOMER_SEGMENT_TRUTH  -8074035385928569526
LOAN                     2344888806333417257
POLICY                  -2532634848670878626
REPAYMENT                4595681719552013977
SERVICE_TICKET          -6166947127814200572
TXN                      4394065264522709928
```

All eight identical before and after. `LOAD_TS` is the single volatile column
in every table — it is `CURRENT_TIMESTAMP()` by design, an audit stamp of when
the load ran — and is excluded from the fingerprints.

## 2. Segment counts are exact, not approximate

Primary segments are assigned by `ROW_NUMBER()` over a deterministic
pseudorandom ordering and then sliced, so 8% of 5,000 is exactly 400 — not
"about 400". `RAW.CUSTOMER_SEGMENT_TRUTH` is generated first and every other
generator conditions its output on it.

Ground truth is deliberately a **separate table**, not a `CUSTOMER` column, so
the NBA engine physically cannot pick it up as a feature. Nothing in `CURATED`,
`GOLD` or `APP` may reference it. Only `evals/` reads it.

## 3. The exactness contract

Each planted segment is engineered to be the **only** source of its identifying
predicate. Where realism and provability conflict, provability wins, because the
purpose of this dataset is to demonstrate that the engine found precisely what
was planted. The mechanism is documented per segment below; the pattern is
always the same — the counter-signal is made structurally impossible outside the
segment rather than merely unlikely.

Noise is added everywhere it does *not* touch a planted predicate: partial
channel DNC, non-monotonic card utilisation, isolated late payments, older
complaints, ordinary renewals falling inside 30 days, lapsed and surrendered
policies, rejected claims.

---

## 4. Primary segments — mutually exclusive

| Code | Target | Share | Expected action |
|---|---|---|---|
| `RETENTION_SAVE` | 400 | 8% | `RETENTION_SAVE_CALL` |
| `LIMIT_INCREASE` | 300 | 6% | `CARD_LIMIT_INCREASE` |
| `PROTECTION_GAP` | 250 | 5% | `HOME_PROTECTION_CROSS_SELL` |
| `COLLECTIONS_HARDSHIP` | 200 | 4% | `COLLECTIONS_HARDSHIP_OUTREACH` |
| `WEALTH_REFERRAL` | 150 | 3% | `WEALTH_REFERRAL` |
| `NONE` | 3,700 | 74% | — |

---

### S1 · `RETENTION_SAVE` — 400 customers (8%)

Policy renewal falls inside the next 30 days **and** a complaint was raised in
the last 60 days. This is a retention save, **not** a cross-sell: the correct
action is to keep the customer, and any cross-sell recommendation here is a
ranking failure.

```sql
SELECT DISTINCT p.CUSTOMER_ID
FROM RAW.POLICY p
JOIN RAW.SERVICE_TICKET t ON t.CUSTOMER_ID = p.CUSTOMER_ID
WHERE p.STATUS = 'ACTIVE'
  AND p.RENEWAL_DATE BETWEEN RAW.AS_OF() AND DATEADD(day, 30, RAW.AS_OF())
  AND t.IS_COMPLAINT
  AND t.OPENED_AT >= DATEADD(day, -60, RAW.AS_OF());
```

**How exactness is enforced.** Renewals inside 30 days occur naturally for
ordinary customers — roughly one policy in twelve — so the *renewal* half is
left alone and the *complaint* half is controlled (step 12). Complaints raised
by a near-renewal customer who is not in the segment are pushed to 61–400 days
old, emptying the 60-day window. The planted complaint itself is 3–58 days old,
severity 3–4, still `OPEN`, and attached to the renewing policy.

This leaves a real population of customers who renew soon and have an *older*
complaint. Those are the near-misses; a rule that fires on them is wrong, and
the count proves whether it did.

---

### S2 · `LIMIT_INCREASE` — 300 customers (6%)

Card utilisation rising monotonically across four consecutive readings, on a
completely clean repayment record.

```sql
SELECT DISTINCT c.CUSTOMER_ID
FROM RAW.CARD c
WHERE c.STATUS = 'ACTIVE'
  AND c.UTILISATION_PCT_M3 < c.UTILISATION_PCT_M2
  AND c.UTILISATION_PCT_M2 < c.UTILISATION_PCT_M1
  AND c.UTILISATION_PCT_M1 < c.UTILISATION_PCT
  AND NOT EXISTS (
    SELECT 1 FROM RAW.REPAYMENT r
    WHERE r.CUSTOMER_ID = c.CUSTOMER_ID
      AND (r.LATE_FLAG OR r.MISSED_FLAG)
  );
```

**How exactness is enforced.** For everyone else, `UTILISATION_PCT_M1` is
generated *above* `UTILISATION_PCT`, which breaks the chain at its final link
regardless of what M2 and M3 do. Utilisation still moves realistically month to
month; it just never climbs for four straight readings. Segment members are
forced to hold an `ACTIVE` card, current utilisation 55–85%, and zero late or
missed instalments anywhere in their book.

---

### S3 · `PROTECTION_GAP` — 250 customers (5%)

Active home loan with no home insurance. A product gap, and the clearest
cross-group action in the dataset: the lending silo knows about the loan, the
policy silo knows about the absent cover, and neither knows both.

```sql
SELECT DISTINCT l.CUSTOMER_ID
FROM RAW.LOAN l
WHERE l.LOAN_TYPE = 'HOME'
  AND l.STATUS = 'ACTIVE'
  AND NOT EXISTS (
    SELECT 1 FROM RAW.POLICY p
    WHERE p.CUSTOMER_ID = l.CUSTOMER_ID
      AND p.POLICY_TYPE = 'HOME'
      AND p.STATUS = 'ACTIVE'
  );
```

**How exactness is enforced.** Home-loan holdership is decided by a pure
function of customer identity — `segment = 'PROTECTION_GAP' OR
RND_BOOL('homeloan|'||id, 0.14)` — evaluated *identically* in the policy and
loan generators, so the two silos agree without a join. Policy slot 0 exists
only for home-loan holders **not** in `PROTECTION_GAP` and is always a `HOME`
policy; `HOME` is excluded from the general policy-type pick entirely.

Every home-loan holder therefore has home cover except the 250. In reality some
others would lack it too, but that would inflate the segment and make the count
unprovable.

---

### S4 · `COLLECTIONS_HARDSHIP` — 200 customers (4%)

Two or more missed instalments in the last six months, with DPD rising across
the last three monthly readings. Marketing must be **suppressed** for these
customers; the correct action is a hardship review, not a sale.

```sql
SELECT r.CUSTOMER_ID
FROM RAW.REPAYMENT r
WHERE r.MISSED_FLAG
  AND r.DUE_DATE >= DATEADD(month, -6, RAW.AS_OF())
GROUP BY r.CUSTOMER_ID
HAVING COUNT(*) >= 2
   AND EXISTS (
     SELECT 1 FROM RAW.LOAN l
     WHERE l.CUSTOMER_ID = r.CUSTOMER_ID
       AND l.DPD_DAYS_M2 < l.DPD_DAYS_M1
       AND l.DPD_DAYS_M1 < l.DPD_DAYS
   );
```

**How exactness is enforced.** Two independent guards:

- *Missed count.* The predicate is at customer grain, so a customer with two
  loans could reach two missed instalments by chance. Outside the segment,
  missed instalments are capped at exactly **one per customer across the whole
  book** via a candidate ranking (`cand_rn = 1` in step 11). Late payments are
  left unconstrained.
- *Rising DPD.* Segment members get `DPD_DAYS_M2 < DPD_DAYS_M1 < DPD_DAYS` with
  current DPD 35–85 days. For everyone else `DPD_DAYS_M1 >= DPD_DAYS` and
  `DPD_DAYS_M2 >= DPD_DAYS_M1` by construction, so the chain is non-increasing
  and cannot fire. Current DPD outside the segment is capped at 30 days.

Segment members are also forced to hold at least one active loan, and their
loans are floored at six months elapsed so the instalments due 1 and 3 months
back actually exist to be missed.

---

### S5 · `WEALTH_REFERRAL` — 150 customers (3%)

A large one-off inbound credit with no investment product held. A referral to
wealth, not a product push.

```sql
SELECT DISTINCT t.CUSTOMER_ID
FROM RAW.TXN t
WHERE t.DIRECTION = 'CREDIT'
  AND t.AMOUNT_INR >= 1000000
  AND t.TXN_DATE >= DATEADD(day, -90, RAW.AS_OF())
  AND NOT EXISTS (
    SELECT 1 FROM RAW.POLICY p
    WHERE p.CUSTOMER_ID = t.CUSTOMER_ID
      AND p.POLICY_TYPE = 'ULIP'
      AND p.STATUS = 'ACTIVE'
  );
```

`RAW.TXN.IS_INBOUND_LUMPSUM` is a convenience marker on exactly these rows.

**How exactness is enforced.** Every ordinary credit in `RAW.TXN` is
hard-clamped below ₹8,50,000, so nothing else in 1.2M transactions reaches the
₹10,00,000 threshold. The 150 lumpsums are injected by a separate statement at
₹10L–₹95L, dated 5–88 days back, with `MCC_GROUP` in `MATURITY_PROCEEDS`,
`PROPERTY_SALE`, `ESOP_LIQUIDATION`, `INHERITANCE`, `BONUS_PAYOUT`. `ULIP` is
remapped to `TERM` for these customers, so none of them holds an investment
product.

**On modelling ULIP as a policy.** A unit-linked plan is an insurance-wrapped
investment and is genuinely booked on the policy admin system in the Indian
market, so it belongs in `RAW.POLICY` rather than in a separate holdings table.
It also gives this segment a real "already invested" exclusion to test against.
`POLICY_TYPE` is therefore `MOTOR / HEALTH / TERM / HOME / ULIP`.

---

## 5. Overlay segments — deliberately intersecting

These are drawn on **independent** orderings so they cut across the primaries.

### S6 · `CONSENT_SUPPRESSED` — 250 customers (5%)

No contactable channel remains: either explicit DNC or consent that has expired.
Suppression must beat expected value however large.

```sql
SELECT c.CUSTOMER_ID
FROM RAW.CUSTOMER c
WHERE NOT EXISTS (
  SELECT 1 FROM RAW.CONSENT k
  WHERE k.CUSTOMER_ID = c.CUSTOMER_ID
    AND k.OPT_IN_FLAG
    AND NOT k.DNC_FLAG
    AND k.VALID_FROM <= RAW.AS_OF()
    AND (k.VALID_TO IS NULL OR k.VALID_TO >= RAW.AS_OF())
);
```

Split by kind (`RAW.CUSTOMER_SEGMENT_TRUTH.SUPPRESSION_KIND`): ~60% `DNC`
(`DNC_FLAG` true and `OPT_IN_FLAG` false on all four channels), ~40%
`EXPIRED_CONSENT` (opted in, but `VALID_TO` fell 10–200 days ago on all four).

**Why the predicate is framed this way.** "Has a DNC flag somewhere" is not the
question suppression logic has to answer — a customer with DNC on SMS is still
reachable by email. Framing it as *no channel remains* lets realistic partial
suppression coexist with an exact count: every non-suppressed customer has one
deterministically chosen **protected channel** that is always opted in, never
DNC, never expired, while their other three carry 18% DNC, 15% opt-out and 12%
expiry.

**Forced overlap.** Pure independence would put only ~20 suppressed customers
in `RETENTION_SAVE`, which is too thin to demonstrate anything. The first 110
suppression slots are therefore allocated deliberately — **60 to
`RETENTION_SAVE`, 50 to `LIMIT_INCREASE`** — the two highest-value cohorts, so
suppression provably kills a large expected value rather than a rounding error.
The remaining 140 are drawn from the whole population. Observed intersections:

| Primary segment | Also suppressed |
|---|---|
| `RETENTION_SAVE` | 71 |
| `LIMIT_INCREASE` | 58 |
| `NONE` | 108 |
| `PROTECTION_GAP` | 6 |
| `COLLECTIONS_HARDSHIP` | 4 |
| `WEALTH_REFERRAL` | 3 |

`RAW.CAMPAIGN_HISTORY` corroborates: `OPT_OUT` and `COMPLAINED` outcomes are
concentrated on this cohort, so the consent state has an audit trail behind it
rather than appearing from nowhere.

---

### S7 · `VULNERABLE_CROSSSELL` — 100 customers (2%) — the guardrail test

Customers flagged vulnerable who *also* look like excellent cross-sell targets.
Every purely commercial ranking will want to sell to them. The vulnerability
gate must route them to service actions only. This is the test case that should
fail loudly if the guardrail is missing.

```sql
SELECT CUSTOMER_ID
FROM RAW.CUSTOMER
WHERE VULNERABILITY_FLAG
  AND INCOME_BAND_RANK >= 4;
```

**How exactness is enforced.** There is an unrelated ~2.5% baseline of
vulnerable customers, and they would otherwise pollute this predicate. Baseline
vulnerable customers are therefore capped at `INCOME_BAND_RANK <= 3`, while the
100 guardrail customers are forced to rank 4 or 5. The conjunction is exact.

Composition, and why it bites:

- **40 sit inside `PROTECTION_GAP`** — a genuine, high-expected-value product
  gap that the engine correctly identifies and must still refuse to act on.
  These are the hardest cases: the commercial signal is real.
- **60 sit in `NONE`** with affluent, clean, under-penetrated profiles: income
  band rank 4–5, `KYC_STATUS = 'VERIFIED'`, zero DPD, at most one policy.

`VULNERABILITY_KIND` for the guardrail cohort is one of
`RECENT_BEREAVEMENT`, `SERIOUS_ILLNESS`, `COGNITIVE_IMPAIRMENT`,
`FINANCIAL_DISTRESS_DECLARED` — reasons that make an acquisition call plainly
inappropriate. The baseline cohort carries milder kinds
(`LOW_FINANCIAL_LITERACY`, `AGE_RELATED`, `DISABILITY`, `LANGUAGE_BARRIER`).

`RAW.PRODUCT_CATALOG.ALLOWED_FOR_VULNERABLE` is `FALSE` for every acquisition
product and `TRUE` only for `SVC_HARDSHIP`. That single column is what the
vulnerability gate reads.

---

## 6. Supporting design notes

**KYC is clean for planted segments.** `KYC_STATUS` is forced to `VERIFIED` for
every planted segment except `COLLECTIONS_HARDSHIP`, and for the guardrail
cohort. Otherwise a stray `EXPIRED` KYC would suppress a customer for the wrong
reason and muddy the compliance trace — the intended rule should be the one that
fires. Unplanted customers get the realistic mix (88% verified, 8% pending, 4%
expired).

**Cooling-off has data behind it.** ~12% of `RAW.CAMPAIGN_HISTORY` contacts
land inside the last 14 days, so the cooling-off rule has genuine violations to
find rather than an empty predicate.

**Household drift is intentional.** `RAW.HOUSEHOLD.CITY` comes from the
household head, while `RAW.CUSTOMER.CITY` is independent. Members whose own city
differs are left alone — that mismatch is realistic silo drift and gives
identity resolution at M2 something real to reconcile.

**`SEGMENT` vs `SEGMENT_CODE`.** `RAW.CUSTOMER.SEGMENT` is the *commercial*
value band (`MASS` / `MASS_AFFLUENT` / `AFFLUENT` / `PRIORITY` / `HNI`), derived
from income. The planted pattern is
`RAW.CUSTOMER_SEGMENT_TRUTH.SEGMENT_CODE`. They are unrelated; do not confuse
them downstream.

---

## 7. Deviations from the entity list in the milestone brief

| Change | Reason |
|---|---|
| `RAW.CUSTOMER_SEGMENT_TRUTH` added | Eval ground truth. Quarantined in its own table so the engine cannot use it as a feature. |
| `RAW.SERVICE_TICKET` added | S1 is defined partly by "a complaint in the last 60 days". Without a complaint table that predicate has nothing to bind to. Structured columns and a short templated note only; rich free text and call audio arrive at M1/M3. |
| `POLICY` / `LOAN` / `CARD` kept separate | `RAW` is as-received silo shape, and these arrive from three different systems of record. `CURATED.CONTRACT` unifies them at M2. |
| `POLICY_TYPE` gains `ULIP` | Gives S5 a real "already holds an investment product" exclusion. A ULIP is genuinely booked on the policy system. |
| `HOUSEHOLD` is the link table itself | Grain is one row per customer per household, per "HOUSEHOLD links customers". |
| `LOAN.DPD_DAYS_M1` / `_M2` added | Makes "rising DPD" a pure predicate rather than something S4 has to reconstruct from the ledger. |
| `CARD.UTILISATION_PCT_M1` / `_M2` / `_M3` added | Same, for "rising utilisation" in S2. |

## 8. File numbering

Settled: the `00` / `02` / `03` naming stands, and `PROJECT_BRIEF.md` §6 was
updated to match. Nothing on disk was renumbered. The brief's §6, §10 and D2 now
all reference the same 22 script names, and `run.sh` builds from `sql/00` through
`sql/31`, stages `app/`, then runs `sql/32_streamlit.sql`.

Two things about the scheme that are not obvious from the numbers:

- `19_search_service.sql` sits in the CURATED block rather than with the other
  `APP` objects, because `24_gold_nba_ranked.sql` cites evidence retrieved
  through it and therefore has to run after it.
- `02_schema_raw.sql` creates the `RAW` schema itself, duplicating one line of
  `01_schemas.sql`, so the RAW layer stays runnable standalone against an empty
  database. Both use `IF NOT EXISTS`.

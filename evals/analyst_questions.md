# Cortex Analyst evaluation — `GOLD.SV_CUSTOMER_360`

Fifteen questions a portfolio manager would actually ask, run through Cortex Analyst
against `GOLD.SV_CUSTOMER_360`, with the generated SQL set beside the SQL a data
engineer on this project would have written by hand.

**Method.** Each question was submitted verbatim via
`cortex analyst query "<question>" --view=C360_NBA.GOLD.SV_CUSTOMER_360`. The
hand-written column is plain SQL over `GOLD.CUSTOMER_360`, `GOLD.C360_ASOF` and the
`RAW` tables — deliberately *not* `SEMANTIC_VIEW()` syntax, so it is an independent
derivation rather than a restatement of the same model. That is the same baseline
that produced the reference values asserted in `sql/09_semantic_view.sql` §3.2.

**As-of anchor for every figure below: 2026-08-28** (`GOLD.C360_ASOF`). Four of the
fifteen answers move if the anchor moves; they are marked.

**Rule followed throughout: fix the semantic view, never the question.** Where
Analyst disagreed with the hand-written SQL, the model was changed and the question
re-run unaltered. Four questions failed or were weak on the first pass. All four
were caused by defects in the semantic view, three of them by things this file's
author had written into it. Section 3 lists the changes.

---

## 1. Scoreboard

| # | Question | First pass | After fixes |
|---|---|---|---|
| 1 | Customer count and average relationship value | PASS | PASS |
| 2 | Top five cities by total relationship value | PASS | PASS |
| 3 | Lapse rate overall and by policy type | PASS | PASS |
| 4 | Policies at risk in 30 days and premium at stake † | PASS | PASS |
| 5 | Total arrears exposure and share of the loan book | PASS | PASS |
| 6 | Arrears broken down by DPD bucket | **WEAK** — misleading zero | PASS |
| 7 | How many customers show churn signals | **FAIL** — wrong metric, wrong grain | PASS |
| 8 | Which channel converts best, which burns consent | PASS | PASS |
| 9 | Cross-sell gaps, and gaps that are actionable | PASS | PASS |
| 10 | Claim rejection rate by policy type | PASS | PASS |
| 11 | Top 10 customers by value who are in arrears | **WEAK** — predicate rebuilt from an enum | PASS |
| 12 | Hardship customers still being contacted | **FAIL** — abandoned the semantic view | PASS |
| 13 | Lapse rate by channel sold † | PASS | PASS |
| 14 | Loans with rising arrears and their exposure | PASS (redundant filter) | PASS |
| 15 | Average sum assured by policy type, active book | PASS | PASS |

† anchor-dependent. Q4, Q6, Q11 and Q14 also shift with the anchor via the arrears
and renewal-window predicates.

**11/15 correct unaided; 15/15 after four fixes to the model.**

---

## 2. Question by question

### Q1 — "How many customers do we have and what is the average relationship value?"

**Answer: 5,000 customers, average relationship value ₹56,574.36.**

| Hand-written | Generated |
|---|---|
| <pre>SELECT COUNT(\*) AS total_customers,<br>       AVG(EST_ANNUAL_MARGIN_INR) AS avg_relationship_value<br>FROM GOLD.CUSTOMER_360;</pre> | <pre>SELECT \*<br>FROM SEMANTIC_VIEW(<br>    C360_NBA.GOLD.SV_CUSTOMER_360<br>    METRICS total_customers, avg_relationship_value<br>)</pre> |

Identical semantics. Nothing to note beyond it picking `total_customers`
(`COUNT(DISTINCT …)`) rather than a fact count.

---

### Q2 — "Which five cities have the highest total relationship value?"

**Answer: Bengaluru ₹16.60m, Mysuru ₹16.06m, Pune ₹16.03m, Hyderabad ₹15.74m, Kochi ₹15.45m.**

| Hand-written | Generated |
|---|---|
| <pre>SELECT CITY,<br>       SUM(EST_ANNUAL_MARGIN_INR) AS total_value<br>FROM GOLD.CUSTOMER_360<br>GROUP BY CITY<br>ORDER BY total_value DESC<br>LIMIT 5;</pre> | <pre>SELECT \*<br>FROM SEMANTIC_VIEW(<br>    C360_NBA.GOLD.SV_CUSTOMER_360<br>    METRICS total_est_annual_margin_inr<br>    DIMENSIONS customers.city<br>)<br>ORDER BY total_est_annual_margin_inr DESC NULLS LAST<br>LIMIT 5</pre> |

Correct, and the interesting part is what it *didn't* do: "relationship value" is the
primary synonym on `avg_relationship_value`, but the word "total" moved it to
`total_est_annual_margin_inr`. The sum, not the average, is right for ranking cities.

---

### Q3 — "What is our lapse rate overall, and how does it vary by policy type?"

**Answer: 8.32% overall (675 of 8,116). TERM 9.91%, HEALTH 9.07%, MOTOR 8.84%, ULIP 8.26%, HOME 0.00%.**

| Hand-written | Generated |
|---|---|
| <pre>SELECT POLICY_TYPE,<br>       COUNT_IF(LAPSE_FLAG) AS lapsed,<br>       COUNT(\*)             AS policies,<br>       COUNT_IF(LAPSE_FLAG)<br>         / NULLIF(COUNT(\*),0) AS lapse_rate<br>FROM RAW.POLICY<br>GROUP BY ROLLUP(POLICY_TYPE)<br>ORDER BY lapse_rate DESC;</pre> | <pre>SELECT NULL AS policy_type, lapse_rate,<br>       lapsed_policy_count, policy_count<br>FROM SEMANTIC_VIEW(… METRICS lapse_rate,<br>     lapsed_policy_count, policy_count)<br>UNION ALL<br>SELECT policy_type, lapse_rate,<br>       lapsed_policy_count, policy_count<br>FROM SEMANTIC_VIEW(… METRICS lapse_rate,<br>     lapsed_policy_count, policy_count<br>     DIMENSIONS policies.policy_type)<br>ORDER BY policy_type NULLS LAST</pre> |

Semantically equivalent. `ROLLUP` is not available inside `SEMANTIC_VIEW()`, so
Analyst reached the same shape with `UNION ALL` of a grand total and a grouped query —
the correct workaround, and it volunteered the numerator and denominator alongside the
rate without being asked.

**Worth flagging to a human, which Analyst does not do:** HOME lapse rate is exactly
0.00% across 675 policies. That is a seeding artifact of `sql/03_seed_raw.sql`, not a
retention achievement. The semantic view has no way to express "this cell is
suspicious" and this eval is the right place to record it.

---

### Q4 — "How many policies are at risk in the next 30 days, and how much annual premium is at stake?" †

**Answer: 420 policies, ₹56,861,700 of annualised premium.**

| Hand-written | Generated |
|---|---|
| <pre>SELECT COUNT(\*) AS policies_at_risk,<br>       SUM(p.PREMIUM_INR \* CASE p.PREMIUM_FREQUENCY<br>             WHEN 'MONTHLY' THEN 12 WHEN 'QUARTERLY' THEN 4<br>             WHEN 'HALF_YEARLY' THEN 2 ELSE 1 END)<br>         AS premium_at_risk<br>FROM RAW.POLICY p CROSS JOIN GOLD.C360_ASOF a<br>WHERE p.STATUS = 'ACTIVE'<br>  AND p.RENEWAL_DATE BETWEEN a.AS_OF_DATE<br>      AND DATEADD(day,30,a.AS_OF_DATE)<br>  AND EXISTS (SELECT 1 FROM RAW.SERVICE_TICKET t<br>              WHERE t.CUSTOMER_ID = p.CUSTOMER_ID<br>                AND t.IS_COMPLAINT<br>                AND t.OPENED_AT >= DATEADD(day,-60,a.AS_OF_DATE));</pre> | <pre>SELECT \*<br>FROM SEMANTIC_VIEW(<br>    C360_NBA.GOLD.SV_CUSTOMER_360<br>    METRICS policies_at_risk_30d, premium_at_risk_30d<br>)</pre> |

The clearest case for the semantic view in the whole set: 14 lines of predicate,
including the 60-day complaint semi-join and the premium annualisation, collapse to
two metric names. It also picked up the `AI_SQL_GENERATION` instruction to pair the
count with the rupee stake — the premium figure was asked for here, but Analyst
volunteers it on bare "how many are at risk" too.

---

### Q5 — "What is our total arrears exposure and what share of the loan book does that represent?"

**Answer: ₹521,397,600 of ₹4,155,304,200 — 12.55% of the book by value.**

| Hand-written | Generated |
|---|---|
| <pre>SELECT SUM(IFF(DPD_DAYS>0, OUTSTANDING_INR, 0)) AS arrears_exposure,<br>       SUM(OUTSTANDING_INR)                     AS loan_book,<br>       SUM(IFF(DPD_DAYS>0, OUTSTANDING_INR, 0))<br>         / NULLIF(SUM(OUTSTANDING_INR),0)       AS exposure_rate<br>FROM RAW.LOAN;</pre> | <pre>SELECT \*<br>FROM SEMANTIC_VIEW(<br>    C360_NBA.GOLD.SV_CUSTOMER_360<br>    METRICS<br>        loans.arrears_exposure_inr  AS total_arrears_exposure_inr,<br>        loans.total_outstanding_inr AS total_loan_book_inr,<br>        ARREARS_EXPOSURE_RATE       AS arrears_exposure_rate<br>)</pre> |

Correct. It used the pre-declared `arrears_exposure_rate` derived metric rather than
dividing two metrics itself, which is the whole reason that metric exists.

---

### Q6 — "Break down arrears by DPD bucket — how many loans and how much exposure in each?"

**Answer:**

| DPD bucket | Loans | In arrears | Total outstanding | Arrears exposure |
|---|---|---|---|---|
| 1-30 | 300 | 300 | ₹337,739,000 | ₹337,739,000 |
| 31-60 | 137 | 137 | ₹98,673,000 | ₹98,673,000 |
| 61-90 | 128 | 128 | ₹84,985,600 | ₹84,985,600 |
| CURRENT | 2,654 | 0 | ₹3,633,906,600 | ₹0 |

#### First pass — WEAK

| Hand-written | Generated (first pass) |
|---|---|
| <pre>SELECT CASE WHEN DPD_BUCKET='0' THEN 'CURRENT'<br>            ELSE DPD_BUCKET END AS dpd_bucket,<br>       COUNT(\*)             AS loans,<br>       SUM(OUTSTANDING_INR) AS total_outstanding,<br>       SUM(IFF(DPD_DAYS>0, OUTSTANDING_INR,0))<br>                            AS arrears_exposure<br>FROM RAW.LOAN<br>GROUP BY 1 ORDER BY 1;</pre> | <pre>SELECT \*<br>FROM SEMANTIC_VIEW(<br>    C360_NBA.GOLD.SV_CUSTOMER_360<br>    METRICS loans.loan_count, loans.arrears_exposure_inr<br>    DIMENSIONS loans.dpd_bucket<br>)<br>ORDER BY dpd_bucket NULLS LAST</pre> |

Not *wrong* — every number it returned was right — but it omitted
`total_outstanding_inr`, and `arrears_exposure_inr` is zero by construction in the
`CURRENT` bucket. The output therefore read:

```
CURRENT   2654   0
```

which invites a portfolio manager to conclude that 2,654 loans carry no balance. They
carry ₹3.63 billion, 87% of the book. A metric that is correct and a presentation that
misleads is still a bad answer, and the model was what let it happen.

#### Fix and re-run — PASS

Added to the `dpd_bucket` dimension comment and to `AI_SQL_GENERATION`: when breaking
anything down by this bucket, select `total_outstanding_inr` as well, because arrears
exposure is zero in `CURRENT` by definition.

```sql
SELECT * FROM SEMANTIC_VIEW(
    C360_NBA.GOLD.SV_CUSTOMER_360
    METRICS loan_count, loans_in_arrears, total_outstanding_inr, arrears_exposure_inr
    DIMENSIONS loans.dpd_bucket
)
```

Now matches the hand-written query, and it added `loans_in_arrears` unprompted, which
makes the zero in the `CURRENT` row self-explaining.

---

### Q7 — "How many customers are showing churn signals?"

**Answer: 12 customers measurably deteriorating — out of 5,000, with 4,864 having no
measurable trend at all.**

#### First pass — FAIL

| Hand-written | Generated (first pass) |
|---|---|
| <pre>SELECT COUNT_IF(SENTIMENT_TREND='DETERIORATING') AS deteriorating,<br>       COUNT_IF(SENTIMENT_TREND IN<br>         ('INSUFFICIENT_DATA','NO_CONTACT_HISTORY')) AS unknown,<br>       COUNT(\*) AS total<br>FROM GOLD.CUSTOMER_360;<br>-- 12 / 4864 / 5000</pre> | <pre>SELECT \*<br>FROM SEMANTIC_VIEW(<br>    C360_NBA.GOLD.SV_CUSTOMER_360<br>    METRICS policies_at_risk_30d, premium_at_risk_30d<br>)<br>-- 420 / 56861700</pre> |

Wrong metric, wrong grain, wrong number: **420 instead of 12**, policies instead of
customers, and a forward-looking renewal predicate instead of a sentiment trend.

**Root cause was self-inflicted.** The synonym list on `policies.is_at_risk_30d`
included `'churn risk'`, and on `policies_at_risk_30d` it included
`'churn risk policies'`. Meanwhile the customer-level metric
`customers_deteriorating` carried `'customers at churn risk'` but nothing matching the
phrase *"churn signals"*. The strongest lexical pull for the word "churn" therefore
landed on the policy fact, and Analyst answered a question about people with a count of
contracts. This is the failure mode where over-generous synonyms on one object silently
steal traffic from another.

#### Fix and re-run — PASS

Three changes:
1. Removed `'churn risk'` / `'churn risk policies'` from the policy at-risk dimension
   and metric, leaving `'retention risk'`, `'renewal at risk'`, `'renewals in doubt'`.
2. Put the churn-signal vocabulary where it belongs — `'churn signal'`,
   `'churn signals'`, `'showing churn signals'`, `'customers showing churn signals'`,
   `'customers at risk of churning'` on `customers_deteriorating` — and stated in its
   comment that `customers_unknown_trend` must always be reported beside it.
3. Replaced the single "churn and lapse are the same thing" paragraph in
   `AI_SQL_GENERATION` with an explicit three-way split, because *churn* in this domain
   is three different questions:
   - **already happened** → `lapse_rate`, `lapsed_policy_count`
   - **customer showing a signal** → `customers_deteriorating` + `customers_unknown_trend`
   - **policy renewal in doubt** → `policies_at_risk_30d` + `premium_at_risk_30d`

```sql
SELECT * FROM SEMANTIC_VIEW(
    C360_NBA.GOLD.SV_CUSTOMER_360
    METRICS customers_deteriorating, customers_unknown_trend, total_customers
)
```

Exactly the hand-written query, including the unknown-trend companion. That companion
is not decoration: 12 of 5,000 reads as a pristine book, and 12 measurable out of 136
measurable is a different story. `PROJECT_BRIEF` D6 is the reason so few customers have
a trend, and this is the question where that decision becomes visible to a business
user.

---

### Q8 — "Which campaign channel converts best, and which one burns the most consent?"

**Answer:**

| Channel | Conversion | Opt-out | Contacts |
|---|---|---|---|
| WHATSAPP | 8.40% | 6.32% | 6,263 |
| CALL | 8.18% | 6.00% | 6,263 |
| SMS | 8.03% | 6.28% | 6,099 |
| EMAIL | 7.99% | 6.05% | 6,293 |

| Hand-written | Generated |
|---|---|
| <pre>SELECT CHANNEL,<br>       COUNT_IF(CONVERTED_FLAG)/COUNT(\*)        AS conv_rate,<br>       COUNT_IF(OUTCOME='OPT_OUT')/COUNT(\*)     AS opt_out_rate,<br>       COUNT(\*)                                 AS contacts<br>FROM RAW.CAMPAIGN_HISTORY<br>GROUP BY CHANNEL<br>ORDER BY conv_rate DESC;</pre> | <pre>SELECT \*<br>FROM SEMANTIC_VIEW(<br>    C360_NBA.GOLD.SV_CUSTOMER_360<br>    METRICS CAMPAIGN_CONVERSION_RATE, CAMPAIGN_OPT_OUT_RATE,<br>            contact_count, converted_count, opt_out_count<br>    DIMENSIONS campaigns.campaign_channel<br>)<br>ORDER BY CAMPAIGN_CONVERSION_RATE DESC NULLS LAST</pre> |

Correct, and it returned the raw counts alongside the two rates so the denominators are
visible. The spread here is narrow — 8.40% to 7.99% conversion on ~6,200 contacts per
channel is inside sampling noise for synthetic data, and no channel is meaningfully
better. Analyst reports the ordering without that caveat; the ranking should not be
acted on.

---

### Q9 — "How many cross-sell gaps do we have, and how many are in customers we can actually contact and whose KYC is current?"

**Answer: 7,855 gaps total; 6,723 in customers who are both reachable and KYC-current.**

| Hand-written | Generated |
|---|---|
| <pre>SELECT SUM(ARRAY_SIZE(PRODUCT_GAP)) AS total_gaps,<br>       SUM(IFF((CONSENT_CALL OR CONSENT_EMAIL OR CONSENT_SMS)<br>               AND KYC_CURRENT,<br>               ARRAY_SIZE(PRODUCT_GAP), 0)) AS actionable_gaps<br>FROM GOLD.CUSTOMER_360;</pre> | <pre>SELECT sv_all.total_cross_sell_gaps,<br>       sv_actionable.actionable_cross_sell_gaps<br>FROM (SELECT \* FROM SEMANTIC_VIEW(…<br>        METRICS cross_sell_gap_count AS total_cross_sell_gaps))<br>     AS sv_all<br>CROSS JOIN<br>     (SELECT \* FROM SEMANTIC_VIEW(…<br>        METRICS cross_sell_gap_count AS actionable_cross_sell_gaps<br>        WHERE customers.is_reachable_any_channel = TRUE<br>          AND customers.is_kyc_current = TRUE))<br>     AS sv_actionable</pre> |

The best unaided answer in the set. `SEMANTIC_VIEW()` cannot express a conditional
aggregate and an unconditional one in a single projection, so Analyst issued two scoped
queries and cross-joined them — the same decomposition a human would reach for.

The framing matters more than the SQL: the semantic view states repeatedly that a
product gap is a statement of need and *not* an eligibility verdict, and this question
is where that pays. 7,855 is the opportunity a naive read would quote; 6,723 is what
survives contact permission and KYC alone, before income band, vulnerability or product
suitability are applied in M5. The gap between the two numbers is the point.

---

### Q10 — "What is the claim rejection rate by policy type?"

**Answer: ULIP 16.67%, HEALTH 11.81%, MOTOR 11.79%, HOME 11.76%, TERM 10.64%.**

| Hand-written | Generated |
|---|---|
| <pre>SELECT p.POLICY_TYPE,<br>       COUNT_IF(c.STATUS='REJECTED')/COUNT(\*) AS rejection_rate<br>FROM RAW.CLAIM c<br>JOIN RAW.POLICY p ON p.POLICY_ID = c.POLICY_ID<br>GROUP BY p.POLICY_TYPE<br>ORDER BY rejection_rate DESC;</pre> | <pre>SELECT \*<br>FROM SEMANTIC_VIEW(<br>    C360_NBA.GOLD.SV_CUSTOMER_360<br>    METRICS CLAIM_REJECTION_RATE<br>    DIMENSIONS claims.claim_policy_type<br>)</pre> |

Correct. The join the hand-written version needs is gone because `V_SV_CLAIM`
denormalises `POLICY_TYPE` onto the claim row — done originally to avoid a multi-path
relationship (see the `09` header), and it pays off again here as a simpler query.

Analyst did not sort, despite "rate by type" implying a ranking. Cosmetic.

---

### Q11 — "Who are our top 10 customers by relationship value who are currently in arrears?"

**Answer:**

| Customer | DPD bucket | Relationship value |
|---|---|---|
| Pooja Naidu (2747) | 1-30 | ₹369,427 |
| Pooja Kulkarni (691) | 61-90 | ₹359,432 |
| Deepika Chauhan (3041) | 1-30 | ₹358,427 |
| Diya Singh (3997) | 1-30 | ₹296,054 |
| Ritu Chauhan (2361) | 1-30 | ₹270,863 |
| Rohan Joshi (3767) | 1-30 | ₹264,990 |
| Yusuf Malhotra (3392) | 61-90 | ₹261,763 |
| Aditya Naidu (1672) | 1-30 | ₹254,307 |
| Nandini Joshi (271) | 1-30 | ₹236,863 |
| Rajesh Malhotra (4339) | 1-30 | ₹236,052 |

#### First pass — WEAK

| Hand-written | Generated (first pass) |
|---|---|
| <pre>SELECT CUSTOMER_ID, CUSTOMER_NAME, DPD_BUCKET,<br>       EST_ANNUAL_MARGIN_INR<br>FROM GOLD.CUSTOMER_360<br>WHERE DPD_BUCKET NOT IN ('CURRENT','NO_CREDIT_OBLIGATION')<br>ORDER BY EST_ANNUAL_MARGIN_INR DESC<br>LIMIT 10;</pre> | <pre>SELECT \*<br>FROM SEMANTIC_VIEW(…<br>    DIMENSIONS customers.customer_id, customers.customer_name,<br>        customers.relationship_value_band,<br>        customers.worst_dpd_bucket, customers.city, customers.segment<br>    METRICS customers.avg_relationship_value,<br>            customers.total_est_annual_margin_inr<br>    WHERE customers.worst_dpd_bucket<br>          NOT IN ('CURRENT','NO_CREDIT_OBLIGATION'))<br>ORDER BY total_est_annual_margin_inr DESC NULLS LAST<br>LIMIT 10</pre> |

The right ten customers in the right order — it read the comment warning that
`NO_CREDIT_OBLIGATION` is not `CURRENT` and excluded both. But it got there by
reconstructing a `NOT IN` over a five-value enum, which is precisely where that trap
bites. It happened to enumerate correctly; a model that wrote
`WHERE worst_dpd_bucket <> 'CURRENT'` would have silently pulled in every customer with
no borrowing at all, and the answer would have looked entirely plausible.

#### Fix and re-run — PASS

Added `IS_IN_ARREARS_CUSTOMER` to `V_SV_CUSTOMER` and exposed it as the dimension
`customers.is_in_arrears_customer`, plus a `customers_in_arrears` metric for the
people-count version. The predicate is now stated once in the model instead of
re-derived per query.

```sql
… WHERE customers.is_in_arrears_customer = TRUE
```

Same ten customers. The point of the fix is not this answer — it was already right —
but that the class of error is now unreachable.

---

### Q12 — "How many customers with a hardship signal are we still contacting in campaigns?"

**Answer: 268 customers.**

#### First pass — FAIL

| Hand-written | Generated (first pass) |
|---|---|
| <pre>SELECT COUNT(DISTINCT c.CUSTOMER_ID)<br>FROM GOLD.CUSTOMER_360 c<br>WHERE c.HARDSHIP_SIGNAL<br>  AND EXISTS (SELECT 1 FROM RAW.CAMPAIGN_HISTORY h<br>              WHERE h.CUSTOMER_ID = c.CUSTOMER_ID);</pre> | <pre>WITH \_\_campaigns AS (<br>  SELECT customer_id FROM C360_NBA.GOLD.V_SV_CAMPAIGN<br>), \_\_customers AS (<br>  SELECT customer_id,<br>         hardship_signal AS has_hardship_signal<br>  FROM C360_NBA.GOLD.V_SV_CUSTOMER<br>)<br>SELECT COUNT(DISTINCT c.customer_id) AS …<br>FROM \_\_campaigns AS ca<br>LEFT OUTER JOIN \_\_customers AS c<br>  ON ca.customer_id = c.customer_id<br>WHERE c.has_hardship_signal = TRUE</pre> |

It abandoned the semantic view. The generated SQL reads the underlying `V_SV_*` views
directly and hand-rolls the join.

The arithmetic is right — 268 either way — but this is the worst outcome in the set,
worse than Q7's wrong number. Once Analyst is outside the semantic view it is outside
everything the semantic view enforces: the grain guidance, the comments about what
`NULL` means, the pairing rules, and any future access control on the model. It also
silently used physical column names (`hardship_signal`), so the query is coupled to the
shims rather than to the logical model, and a rename in `V_SV_CUSTOMER` would break it.

**Root cause was a genuine gap, not a synonym problem.** The question is a semi-join —
"customers matching an attribute who also appear in a fact" — and the model had no
metric at customer grain on the `campaigns` fact. `contact_count` counts attempts;
`customers_with_hardship` lives on the spine and cannot force the campaigns join.
There was no way to express the question inside the view, so Analyst correctly concluded
it had to leave.

#### Fix and re-run — PASS

Added `campaigns.customers_contacted AS COUNT(DISTINCT campaigns.CUSTOMER_ID)`, and a
paragraph in `AI_SQL_GENERATION` stating that questions crossing a customer attribute
with campaign activity use this metric filtered on the customer dimension, and that
dropping to raw SQL against the `V_SV_*` shims is not an acceptable fallback.

```sql
SELECT * FROM SEMANTIC_VIEW(
    C360_NBA.GOLD.SV_CUSTOMER_360
    METRICS campaigns.customers_contacted
    WHERE customers.has_hardship_signal = TRUE
)
```

Three lines, inside the model, 268.

**This is the finding with the most carry-over into M9.** The agent will route
questions to this view, and an agent that quietly writes its own SQL when the model
falls short is an agent whose answers are ungoverned. `customers_contacted` closed this
instance; the general lesson is that every fact needs a distinct-customer metric, and
`policies`, `loans` and `claims` should get one before the agent milestone.

---

### Q13 — "What is the lapse rate broken down by the channel the policy was sold through?"

**Answer: BROKER 8.99%, DIGITAL 8.98%, AGENT 8.48%, TELE 8.35%, BANCA 6.88%.**

| Hand-written | Generated |
|---|---|
| <pre>SELECT CHANNEL_SOLD,<br>       COUNT_IF(LAPSE_FLAG) AS lapsed,<br>       COUNT(\*)             AS policies,<br>       COUNT_IF(LAPSE_FLAG)/NULLIF(COUNT(\*),0) AS lapse_rate<br>FROM RAW.POLICY<br>GROUP BY CHANNEL_SOLD<br>ORDER BY lapse_rate DESC;</pre> | <pre>SELECT \*<br>FROM SEMANTIC_VIEW(<br>    C360_NBA.GOLD.SV_CUSTOMER_360<br>    METRICS lapse_rate, lapsed_policy_count, policy_count<br>    DIMENSIONS policies.channel_sold<br>)<br>ORDER BY lapse_rate DESC NULLS LAST</pre> |

Correct, and it did not confuse `channel_sold` (origination) with `campaign_channel`
(outbound contact) or `preferred_channel` (behaviour) — three channel-shaped
dimensions on three different tables. The comments distinguishing them earned their
keep.

BANCA at 6.88% against a ~8.5% field is the only spread here wide enough to be worth a
second look, and even that is 118 lapses on 1,714 policies.

---

### Q14 — "How many loans have rising arrears and what is their total outstanding exposure?"

**Answer: 265 loans, ₹183,658,600.**

| Hand-written | Generated |
|---|---|
| <pre>SELECT COUNT(\*)             AS rising_loans,<br>       SUM(OUTSTANDING_INR) AS exposure<br>FROM RAW.LOAN<br>WHERE DPD_DAYS_M2 &lt; DPD_DAYS_M1<br>  AND DPD_DAYS_M1 &lt; DPD_DAYS;</pre> | <pre>SELECT \*<br>FROM SEMANTIC_VIEW(<br>    C360_NBA.GOLD.SV_CUSTOMER_360<br>    METRICS loans.rising_dpd_loan_count AS loans_with_rising_arrears,<br>            loans.arrears_exposure_inr AS total_outstanding_exposure_inr<br>    WHERE loans.is_dpd_rising = TRUE<br>)</pre> |

Correct, with a redundancy: `rising_dpd_loan_count` already counts only rising loans, so
the `WHERE` narrows an already-narrowed metric. Harmless here — the predicate is
idempotent, and `arrears_exposure_inr` under that filter is right because
`DPD_M2 < DPD_M1 < DPD` forces `DPD >= 1`, so every rising loan is in arrears by
construction.

Left unfixed deliberately. Making `COUNT_IF`-style metrics refuse a redundant filter is
not something the model can express, and the alternative — dropping
`rising_dpd_loan_count` in favour of forcing a `WHERE` — would make the common case
harder to get right in order to tidy an uncommon case that is already correct.

---

### Q15 — "Compare the average sum assured by policy type for the active book only."

**Answer: TERM ₹10,053,021, HOME ₹4,547,431, ULIP ₹1,992,038, HEALTH ₹1,030,757, MOTOR ₹806,197.**

| Hand-written | Generated |
|---|---|
| <pre>SELECT POLICY_TYPE,<br>       AVG(SUM_ASSURED_INR) AS avg_sum_assured<br>FROM RAW.POLICY<br>WHERE STATUS = 'ACTIVE'<br>GROUP BY POLICY_TYPE<br>ORDER BY avg_sum_assured DESC;</pre> | <pre>SELECT \*<br>FROM SEMANTIC_VIEW(<br>    C360_NBA.GOLD.SV_CUSTOMER_360<br>    METRICS avg_sum_assured_inr<br>    DIMENSIONS policies.policy_type<br>    WHERE policies.is_active_policy = TRUE<br>)<br>ORDER BY avg_sum_assured_inr DESC NULLS LAST</pre> |

Correct. This question exists to test whether the "active book" filter survives being
mentioned in passing at the end of a sentence, because the `policies` table carries
lapsed, matured and surrendered rows and an unfiltered average is wrong by a wide
margin. It did.

---

## 3. Changes made to the semantic view

All four driven by the failures above. No question was reworded.

| # | Change | Driven by |
|---|---|---|
| 1 | Removed `'churn risk'` / `'churn risk policies'` from `policies.is_at_risk_30d` and `policies_at_risk_30d`; moved the churn-signal vocabulary to `customers_deteriorating`; replaced the churn paragraph in `AI_SQL_GENERATION` with an explicit three-way split (happened / signal / renewal in doubt) | Q7 |
| 2 | Added `campaigns.customers_contacted AS COUNT(DISTINCT CUSTOMER_ID)` plus guidance that customer-attribute × campaign-activity questions use it, and that falling back to raw SQL over the `V_SV_*` shims is not acceptable | Q12 |
| 3 | Added `IS_IN_ARREARS_CUSTOMER` to `V_SV_CUSTOMER`, exposed as `customers.is_in_arrears_customer` with a `customers_in_arrears` metric | Q11 |
| 4 | `loans.dpd_bucket` comment and `AI_SQL_GENERATION` now require `total_outstanding_inr` in any bucket breakdown, because arrears exposure is zero in `CURRENT` by construction | Q6 |

Post-fix, `sql/09_semantic_view.sql` §3 assertions A1–A5 all still pass: the six
headline metrics still match plain SQL, the quarantine holds, no fact orphans the
spine, and all six required synonyms resolve.

---

## 4. What this run says about the model

**Comment quality is the product.** Every unaided pass traces to a comment doing work:
Q15 filtered the active book, Q11 excluded `NO_CREDIT_OBLIGATION`, Q9 separated need
from eligibility, Q13 disambiguated three channel dimensions. None of that is inferable
from column names.

**Synonyms are a shared namespace and over-claiming is a real defect.** Q7 failed
because `'churn risk'` was attached to a policy metric out of enthusiasm, and it stole a
customer-grain question. Breadth on one object narrows every other object competing for
the same word. The `A5` assertion in `sql/09` checks that the six required synonyms
*resolve*; it does not and cannot check that they resolve to the right thing. That is
what this eval is for.

**The dangerous failure is not a wrong number, it is leaving the model.** Q7 returned
420 instead of 12 — visibly wrong to anyone who knows the book. Q12 returned the
correct 268 by writing its own SQL against the underlying views, which is invisible in
the output and forfeits every guarantee the semantic view exists to provide. Coverage
gaps do not produce errors; they produce ungoverned answers.

**Three carry-overs into M9 (agent) and M11 (verification):**
1. Give `policies`, `loans` and `claims` distinct-customer metrics before wiring the
   agent, so semi-join questions on those facts cannot push it out of the model the way
   Q12 pushed it out of `campaigns`.
2. Add an assertion that generated SQL contains `SEMANTIC_VIEW(` — a fallback to raw
   SQL should fail the eval, not pass it quietly.
3. Q3's HOME 0.00% lapse rate and Q8's flat channel spread are both seeding artifacts.
   Analyst reports them as findings because they are, in the data. Anything demoed off
   this view needs a human between the number and the conclusion.

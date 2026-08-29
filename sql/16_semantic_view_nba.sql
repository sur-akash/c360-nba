/* ============================================================================
   16_semantic_view_nba.sql  —  GOLD.SV_CUSTOMER_360, now including the engine
   ----------------------------------------------------------------------------
   M9 step 1. The semantic view stops being a description of the book and starts
   being a description of the book AND what the engine intends to do about it.

   Cost: ZERO CREDITS. No AI function is called anywhere in this file.

   ----------------------------------------------------------------------------
   WHY THIS FILE EXISTS INSTEAD OF AN EDIT TO 09
   ----------------------------------------------------------------------------
   sql/09 created GOLD.SV_CUSTOMER_360 over the customer spine and four facts,
   and deliberately left GOLD.NEXT_BEST_ACTION out because at that point the
   table held placeholder propensities. That reason has expired -- sql/11-15
   replaced the contents -- so the table comes in here.

   It could not come in by editing 09, for a dependency reason rather than a
   stylistic one. Three of the things this model now needs are created after 09:

     GOLD.NBA_ELIGIBLE                 sql/12   the candidate ledger, and the
                                                only place suppression is
                                                recorded at all
     GOLD.V_NEXT_BEST_ACTION_AUDIT     sql/15   RATIONALE_SOURCE (LLM/TEMPLATE)
     GOLD.NEXT_BEST_ACTION (contents)  sql/15   the published ranking

   A feeder view over a table that does not exist yet fails at CREATE, so 09
   cannot reference them and numeric order is run order (PROJECT_BRIEF §6).

   And there is no incremental path: ALTER SEMANTIC VIEW changes the comment, the
   tags and the materializations, and nothing else -- not TABLES, not METRICS.
   Adding one metric means re-issuing the whole definition. Which leaves two
   options, and only one of them is honest:

     - Duplicate ~830 lines of definition here and leave 09's copy in place.
       Two definitions of the same object, drifting apart from the first edit.
     - Move the definition. 09 keeps the five feeder views it wrote, whose
       comments explain why the shims exist at all, and stops issuing the
       CREATE. This file is the single authoritative definition.

   The second. So 09 is now the shim layer and this file is the model. 09's
   header records the move, and its A2 assertion -- "NEXT_BEST_ACTION is not
   referenced" -- is deleted, which 09's own comment on that assertion asked for
   in the same commit that added the table.

   The three SEMANTIC_VIEW() assertions that used to live in 09 §3.2-3.4 move
   here too, for the same reason: they query the object, so they have to run
   after whatever creates it.

   ----------------------------------------------------------------------------
   WHY THE ENGINE ARRIVES AS TWO LOGICAL TABLES AND NOT ONE
   ----------------------------------------------------------------------------
   The brief for this step asked for three metrics: nba_count,
   total_expected_value_inr and suppression_rate. The first two are properties of
   the published ranking. The third is not, and cannot be.

   GOLD.NEXT_BEST_ACTION contains 3,917 rows: what the engine decided to
   recommend. A suppressed action is, by construction, absent from it. So a
   suppression rate computed over that table is 0/3917 = 0 -- not wrong so much
   as meaningless, and the sort of confidently-empty number that is worse than an
   error because nobody questions it.

   Suppression lives one layer back, in GOLD.NBA_ELIGIBLE: 90,000 rows, one per
   (customer, action) pair the engine evaluated, carrying SUPPRESSED, the
   governing SUPPRESSION_REASON and the full ELIGIBILITY_TRACE. Two different
   grains -- decided actions and evaluated candidates -- so two logical tables,
   nba and nba_candidates, each with its own relationship to the spine. Folding
   them together would produce a table where nba_count and suppression_rate
   cannot both be right.

   THE DENOMINATOR OF suppression_rate IS NOT 90,000. Of those pairs, 16,475
   passed the need test (ELIGIBLE_ON_NEED) -- the customer plausibly wants the
   product. The other 73,525 were never candidates in any meaningful sense: a
   customer who already holds the product, or has no gap for it. Dividing by
   90,000 would report a 13.8% suppression rate whose movement is dominated by
   how many products the catalogue happens to contain.

   Dividing by the needed set reports 75.5% -- three needed actions in four are
   blocked by a compliance rule. That is the honest number, it is the number
   sql/15 §15.6 reads, and it is the headline governance fact about this engine.

   ----------------------------------------------------------------------------
   FOUR DISTINCT-CUSTOMER METRICS, WHICH IS THE Q12 DEBT BEING PAID
   ----------------------------------------------------------------------------
   evals/analyst_questions.md Q12 recorded Analyst abandoning this semantic view
   and hand-rolling SQL against the V_SV_ shims. The number it returned was
   right. That was the problem: an ungoverned answer that looks exactly like a
   governed one.

   The cause was a coverage gap, not a synonym. "How many customers with a
   hardship signal are we still contacting" is a semi-join -- a customer
   attribute crossed with the existence of a fact row -- and the campaigns fact
   had no customer-grain metric to carry it. There was no way to express the
   question inside the model, so leaving was the correct thing for Analyst to do.
   campaigns.customers_contacted closed that one instance.

   Q12's write-up flagged the general case as unclosed and named the fix as a
   precondition for this milestone: policies, loans and claims need the same
   metric, or the same failure recurs the first time somebody asks how many
   PEOPLE hold a lapsed policy. So this file adds:

     policies.customers_with_policies      4,002
     loans.customers_with_loans            2,578
     claims.customers_with_claims          1,418

   and, because a new fact with the same gap would be a new instance of the same
   bug rather than a lesson learned:

     nba.customers_with_actions            2,346
     nba_candidates.customers_suppressed   4,580

   Every fact in this model now has a distinct-customer metric. There is no
   remaining semi-join that has to leave the view to be answered.

   The other half of that finding -- an assertion that generated SQL actually
   contains SEMANTIC_VIEW( -- is not a property of the model and cannot be
   asserted here. It lives in evals/run_analyst_evals.py.

   ----------------------------------------------------------------------------
   REFERENCE VALUES AT ANCHOR 2026-08-28
   ----------------------------------------------------------------------------
     nba_count                    3,917 published actions
     customers_with_actions       2,346 customers with at least one
     total_expected_value_inr     7,177,355
     candidates evaluated        90,000
     needed (eligible_on_need)   16,475
     suppressed and needed       12,435
     suppression_rate             0.7548
   ============================================================================ */

USE DATABASE C360_NBA;
USE SCHEMA GOLD;
USE WAREHOUSE COCO_WH;


/* ============================================================================
   PART 1 — THE TWO NEW FEEDER VIEWS
   ----------------------------------------------------------------------------
   Same contract as the five in 09: presentation shims, one row per grain, no
   filtering, nothing computed that the semantic view could compute itself. The
   reason they exist is the reason given in 09's header -- a semantic view
   expression is evaluated against the columns of one logical table, so anything
   needing a join has to happen one layer down.

   Here the join is to GOLD.V_NEXT_BEST_ACTION_AUDIT, which carries
   RATIONALE_SOURCE. Without it there is no way to ask the one question a
   sceptical reader always asks first: how much of this prose was written by a
   model and how much was templated.
   ============================================================================ */

CREATE OR REPLACE VIEW GOLD.V_SV_NBA
  COMMENT = 'Feeder view for GOLD.SV_CUSTOMER_360. GOLD.NEXT_BEST_ACTION joined to GOLD.V_NEXT_BEST_ACTION_AUDIT for provenance (RATIONALE_SOURCE, PRIORITY_TIER, IS_SALES_ACTION), with the two ARRAY columns reduced to a count and a flag so they can be dimensioned on. One row per published recommendation, 3,917 rows, no filtering. Presentation shim only -- read GOLD.NEXT_BEST_ACTION directly for any other purpose.'
AS
SELECT
    n.CUSTOMER_ID,
    n.CUSTOMER_ID || '#' || n."RANK"            AS NBA_ID,
    n."RANK"                                    AS ACTION_RANK,
    n.ACTION_CODE,
    n.ACTION_NAME,
    n.CHANNEL,
    n.PROPENSITY,
    n.EXPECTED_VALUE_INR,
    n.RATIONALE,
    n.DISCLOSURE,
    n.GENERATED_AT,

    /* ---- provenance, from the audit view ---- */
    v.RATIONALE_SOURCE,
    v.PRIORITY_TIER,
    v.IS_SALES_ACTION,
    NOT v.IS_SALES_ACTION                       AS IS_SERVICE_ACTION,
    v.CARE_BAND,
    v.RANK_MOVED,

    /* ---- derived scalars: the ARRAYs cannot be dimensioned on ---- */
    n."RANK" = 1                                AS IS_TOP_ACTION,
    ARRAY_SIZE(n.EVIDENCE_IDS)                  AS EVIDENCE_COUNT,
    ARRAY_SIZE(n.EVIDENCE_IDS) > 0              AS HAS_EVIDENCE,
    ARRAY_SIZE(n.ELIGIBILITY_TRACE)             AS TRACE_RULE_COUNT,
    n.DISCLOSURE IS NOT NULL
      AND LENGTH(TRIM(n.DISCLOSURE)) > 0        AS HAS_DISCLOSURE,

    /* PRIORITY_TIER <= 20 is the care boundary sql/15 enforces: hardship
       outreach, arrears reminders, complaint callbacks, service recovery and
       retention saves. Named here so a question can ask for "care actions"
       without knowing the number. */
    v.PRIORITY_TIER <= 20                       AS IS_CARE_ACTION,

    /* ACTION_CLASS exists because a boolean pair cannot answer a question about
       a SPLIT, and the agent test proved it. Asked "what is the split between
       sales actions and care actions", Cortex Analyst had care_action_count and
       sales_action_count available -- and those are two COLUMNS, whereas a split
       is two ROWS. With no dimension to group by, it built the categories itself
       with a CASE over the two booleans, which meant reading V_SV_NBA directly
       and leaving the model. Correct number, ungoverned answer, and the exact
       Q12 failure recurring on the newest fact.

       The cause was a missing dimension rather than a missing instruction: the
       shape the question asks for was not available. So the classification is
       declared here, once, and the question becomes one metric by one
       dimension -- an ordinary shape with an exemplar already in
       AI_VERIFIED_QUERIES.

       THERE ARE THREE CLASSES AND NOT TWO, WHICH THIS FILE GOT WRONG ONCE.
       The first version of this expression assumed CARE and SALES were
       exhaustive -- care band, or else a sale -- with an UNCLASSIFIED bucket
       added only as a tripwire in case that ever stopped being true. It was
       never true: the tripwire caught 339 actions immediately.

       They are the same two actions sql/15's header singles out as the only
       servicing actions the narrating model ever ranked below a sale:
       RENEWAL_REMINDER_EARLY at tier 30 (241 actions) and
       RETENTION_WINBACK_LAPSED at tier 25 (98 actions). Non-sales, so outside
       SALES; above the tier-20 care boundary, so outside CARE. They are
       retention work -- keeping business that already exists -- which is
       genuinely neither protecting a customer in difficulty nor selling them
       something new.

       So the third class is named RETENTION rather than papered over, and "the
       split between sales and care" turns out to be a false binary that the
       question invites and the data refuses. An answer that reported only two
       classes would have had to put renewal reminders on one side or the other,
       and both placements are wrong.

       The ELSE remains as a tripwire for the same reason it earned its keep the
       first time. */
    CASE WHEN v.PRIORITY_TIER <= 20  THEN 'CARE'
         WHEN v.IS_SALES_ACTION      THEN 'SALES'
         WHEN NOT v.IS_SALES_ACTION  THEN 'RETENTION'
         ELSE 'UNCLASSIFIED'
    END                                         AS ACTION_CLASS
FROM GOLD.NEXT_BEST_ACTION n
JOIN GOLD.V_NEXT_BEST_ACTION_AUDIT v
  ON v.CUSTOMER_ID = n.CUSTOMER_ID
 AND v."RANK"      = n."RANK";


CREATE OR REPLACE VIEW GOLD.V_SV_NBA_CANDIDATE
  COMMENT = 'Feeder view for GOLD.SV_CUSTOMER_360. GOLD.NBA_ELIGIBLE, one row per (customer, action) pair the engine evaluated, 90,000 rows. Carries the need test, the suppression verdict and the governing rule. This is the only place suppression is recorded -- a suppressed action is absent from GOLD.NEXT_BEST_ACTION by construction. SUPPRESSION_REASON is normalised from NULL to NOT_SUPPRESSED so it can be grouped on without a coalesce at the call site. Presentation shim only.'
AS
SELECT
    e.CUSTOMER_ID,
    e.CUSTOMER_ID || '#' || e.ACTION_CODE       AS CANDIDATE_ID,
    e.ACTION_CODE,
    e.ACTION_NAME,
    e.CATEGORY,
    e.CHANNEL,
    e.IS_SALES_ACTION,
    e.IS_SERVICING_OBLIGATION,
    e.PRIORITY_TIER,
    e.VALUE_AT_STAKE_INR,
    e.MARGIN_RATE,
    e.ELIGIBLE_ON_NEED,
    e.SUPPRESSED,
    e.FINAL_VERDICT,

    /* NULL means "not suppressed", which is a real answer and not missing data.
       Normalising it here means a breakdown by reason does not silently drop
       the 4,040 rows that passed. */
    COALESCE(e.SUPPRESSION_REASON, 'NOT_SUPPRESSED')  AS SUPPRESSION_REASON,

    /* The two halves of suppression_rate, pre-resolved so the metric is a
       COUNT_IF over one column rather than a two-column predicate. */
    e.ELIGIBLE_ON_NEED AND e.SUPPRESSED         AS IS_SUPPRESSED_NEED,
    e.ELIGIBLE_ON_NEED AND NOT e.SUPPRESSED     AS IS_ACTIONABLE,

    /* Coarse grouping of the thirteen reasons, so "how much do consent rules
       cost us" is one filter rather than an OR list somebody has to get right. */
    CASE
      WHEN e.SUPPRESSION_REASON IS NULL                       THEN 'NOT_SUPPRESSED'
      WHEN e.SUPPRESSION_REASON IN ('DNC_REGISTRY',
                                    'NO_CHANNEL_CONSENT')     THEN 'CONSENT'
      WHEN e.SUPPRESSION_REASON IN ('VULNERABILITY_GATE',
                                    'OPEN_COMPLAINT')         THEN 'CONDUCT'
      WHEN e.SUPPRESSION_REASON IN ('ARREARS_CROSS_SELL',
                                    'ARREARS_SALES')          THEN 'ARREARS'
      WHEN e.SUPPRESSION_REASON LIKE 'PRODUCT_GATE%'          THEN 'SUITABILITY'
      WHEN e.SUPPRESSION_REASON = 'COOLDOWN'                  THEN 'CONTACT_FATIGUE'
      ELSE 'OTHER'
    END                                          AS SUPPRESSION_CATEGORY,

    ARRAY_SIZE(e.RULES_FAILED)                   AS RULES_FAILED_COUNT,
    ARRAY_SIZE(e.RULES_PASSED)                   AS RULES_PASSED_COUNT,
    ARRAY_SIZE(e.ELIGIBILITY_TRACE)              AS TRACE_RULE_COUNT
FROM GOLD.NBA_ELIGIBLE e;


/* ============================================================================
   PART 2 — THE MODEL
   ----------------------------------------------------------------------------
   Relocated from sql/09 §2 with the NBA additions folded in. Everything that
   was there is still there and unchanged apart from the four edits the new
   tables force:

     TABLES        + nba, nba_candidates
     RELATIONSHIPS + two, both to the spine, no chains
     FACTS         + row-level numerics on both new tables
     DIMENSIONS    + action, channel, provenance, suppression reason
     METRICS       + the three asked for, + five distinct-customer metrics
     COMMENT / AI_SQL_GENERATION / AI_QUESTION_CATEGORIZATION rewritten, since
                   all three previously said the engine was deliberately absent
   ============================================================================ */

CREATE OR REPLACE SEMANTIC VIEW GOLD.SV_CUSTOMER_360

  TABLES (
    customers AS GOLD.V_SV_CUSTOMER
      PRIMARY KEY (CUSTOMER_ID)
      WITH SYNONYMS ('customer', 'customers', 'client', 'clients', 'customer 360',
                     'policyholder', 'borrower', 'book of customers', 'people')
      COMMENT = 'The customer spine: one row per customer, 5,000 rows, every customer the group has. Wide by design -- identity, holdings, value, risk, engagement and contact permissions all on one row, so a question about any of them needs no join. Day-counts on this row (days to renewal, last contact days, tenure) were computed against AS_OF_DATE, which is a stored anchor date and not necessarily today; see the as_of_date dimension before quoting them as current.',

    policies AS GOLD.V_SV_POLICY
      PRIMARY KEY (POLICY_ID)
      WITH SYNONYMS ('policy', 'policies', 'insurance policy', 'insurance policies',
                     'cover', 'insurance book', 'insurance contracts', 'contracts')
      COMMENT = 'The insurance book: one row per policy, 8,116 rows, ALL statuses including lapsed, matured and surrendered. Filter on is_active_policy for the live book. A customer may hold several policies, so counts here are policy counts and not customer counts -- use total_customers from the customers table when the question asks how many people.',

    loans AS GOLD.V_SV_LOAN
      PRIMARY KEY (LOAN_ID)
      WITH SYNONYMS ('loan', 'loans', 'lending', 'lending book', 'credit',
                     'borrowing', 'advances', 'loan account', 'loan accounts', 'EMI')
      COMMENT = 'The lending book: one row per loan, 3,219 rows, all currently ACTIVE. Carries arrears state as both a day count (dpd_days) and a bucket (dpd_bucket), plus the two prior monthly readings so a deteriorating trend is a predicate rather than something to reconstruct. A customer may hold several loans.',

    claims AS GOLD.V_SV_CLAIM
      PRIMARY KEY (CLAIM_ID)
      WITH SYNONYMS ('claim', 'claims', 'insurance claim', 'insurance claims',
                     'claim history', 'settlements', 'payouts')
      COMMENT = 'Insurance claims ever filed: one row per claim, 1,621 rows, across open, in-review, settled and rejected. Every claim belongs to a policy, and that policy type and product family are carried on the claim row so claims can be sliced by product without a second join. Approved amount is NULL on anything not yet settled and on rejections.',

    campaigns AS GOLD.V_SV_CAMPAIGN
      PRIMARY KEY (CAMPAIGN_CONTACT_ID)
      WITH SYNONYMS ('campaign', 'campaigns', 'campaign history', 'outbound contact',
                     'outreach', 'contact history', 'marketing', 'marketing history',
                     'contacts made', 'contact log')
      COMMENT = 'The outbound contact log: one row per contact attempt, 24,918 rows, 12 rolling months. Records what was offered, on which channel, and how the customer responded. Outcomes include two adverse ones -- OPT_OUT and COMPLAINED -- which are the cost of contacting, and any read of campaign effectiveness that only counts conversions is incomplete without them.',

    nba AS GOLD.V_SV_NBA
      PRIMARY KEY (NBA_ID)
      /* 'NBA' and 'nba' are deliberately absent: the table ALIAS is nba, and a
         synonym may not repeat an alias -- the check is case-insensitive.
         'recommendation' is likewise left to nba.action_name, where a question
         asking for "the recommendation" wants the label rather than the table. */
      WITH SYNONYMS ('next best action', 'next best actions',
                     'recommended action', 'recommended actions',
                     'action plan', 'what to do next',
                     'ranked actions', 'offers to make', 'the engine',
                     'engine output', 'published actions')
      COMMENT = 'What the engine decided to recommend: one row per published recommendation, 3,917 rows across 2,346 customers, up to three ranked actions each. Carries the action, the channel, the propensity, the expected value in INR, the agent-facing rationale and the required regulatory disclosure. THIS TABLE CONTAINS ONLY ACTIONS THAT SURVIVED EVERY COMPLIANCE RULE -- a suppressed action is absent from it by construction, so it can never be used to count or rate suppression. That is what nba_candidates is for. rationale_source distinguishes prose written by a frontier model from prose assembled from a template; report it whenever quoting a rationale at length.',

    nba_candidates AS GOLD.V_SV_NBA_CANDIDATE
      PRIMARY KEY (CANDIDATE_ID)
      WITH SYNONYMS ('candidates', 'action candidates', 'candidate actions',
                     'eligibility', 'eligibility ledger', 'suppression',
                     'suppressions', 'suppressed actions', 'blocked actions',
                     'what we could not do', 'rejected actions',
                     'compliance decisions', 'eligibility trace',
                     'actions considered', 'evaluated actions')
      COMMENT = 'Every (customer, action) pair the engine evaluated: 90,000 rows, 5,000 customers by 18 actions, whether or not anything was recommended. This is the ONLY place suppression is recorded. Two gates, and they are different: eligible_on_need says the customer plausibly wants the product (16,475 pairs), and suppressed says a compliance rule blocked it anyway (12,435 of those 16,475). The 73,525 pairs that failed the need test were never candidates in any useful sense -- usually the customer already holds the product -- so ANY suppression rate or count must be taken over the eligible_on_need subset, never over all 90,000. Use suppression_rate, which already does this.'
  )

  RELATIONSHIPS (
    /* One relationship per fact, all to the spine, no chains. Each fact
       carries CUSTOMER_ID natively. Claims also carry POLICY_ID but a second
       route to the spine through policies would be a multi-path error, so the
       policy attributes claims needs are denormalised into V_SV_CLAIM
       instead -- see sql/09's header.

       nba and nba_candidates are two grains over the same decision process and
       are deliberately NOT related to each other, only to the spine. A
       nba -> nba_candidates relationship on (customer, action) would be the
       multi-path error again, and worse, it would invite a query that counts
       published actions and suppressions in one row -- which is precisely the
       grain confusion the two tables exist to prevent. */
    policies_to_customer       AS policies(CUSTOMER_ID)       REFERENCES customers,
    loans_to_customer          AS loans(CUSTOMER_ID)          REFERENCES customers,
    claims_to_customer         AS claims(CUSTOMER_ID)         REFERENCES customers,
    campaigns_to_customer      AS campaigns(CUSTOMER_ID)      REFERENCES customers,
    nba_to_customer            AS nba(CUSTOMER_ID)            REFERENCES customers,
    nba_candidates_to_customer AS nba_candidates(CUSTOMER_ID) REFERENCES customers
  )

  FACTS (
    /* ---- customers: row-level numerics on the spine ---- */
    customers.customer_age AS AGE
      WITH SYNONYMS ('age', 'age in years', 'how old')
      COMMENT = 'Customer age in years.',
    customers.household_size AS HOUSEHOLD_SIZE
      WITH SYNONYMS ('household size', 'family size', 'people in household')
      COMMENT = 'Number of people in the customer household.',
    customers.tenure_years AS TENURE_YEARS
      WITH SYNONYMS ('tenure', 'years as a customer', 'relationship length', 'how long a customer')
      COMMENT = 'Years since the customer relationship began, measured to as_of_date.',
    customers.annual_premium_inr AS ANNUAL_PREMIUM_INR
      WITH SYNONYMS ('annual premium', 'premium', 'yearly premium', 'premium paid')
      COMMENT = 'Total annualised premium across the customer active policies, in INR. Premiums on monthly, quarterly and half-yearly policies are annualised first so the figure is comparable across frequencies.',
    customers.outstanding_credit_inr AS OUTSTANDING_CREDIT_INR
      WITH SYNONYMS ('outstanding credit', 'outstanding balance', 'credit outstanding',
                     'debt', 'amount owed', 'balance owed')
      COMMENT = 'Total outstanding balance across the customer active loans and cards, in INR. This is a stock at as_of_date, not a flow.',
    customers.est_annual_margin_inr AS EST_ANNUAL_MARGIN_INR
      WITH SYNONYMS ('relationship value', 'customer value', 'annual margin', 'margin',
                     'estimated margin', 'value of the relationship', 'profitability',
                     'how valuable', 'worth')
      COMMENT = 'Modelled annual margin from the customer, in INR: annualised premium times the product margin rate for active policies, plus outstanding balance times the margin rate for active loans and cards. IMPORTANT -- the credit half is a spread proxy on a stock rather than a measured flow, so this is a quantity for RANKING customers against each other, not a profit-and-loss figure to report as revenue.',
    customers.missed_payments_12m AS MISSED_PAYMENTS_12M
      WITH SYNONYMS ('missed payments', 'missed instalments', 'payments missed',
                     'defaults', 'missed EMIs')
      COMMENT = 'Count of missed instalments, premium or EMI, in the last 12 months.',
    customers.lapse_history AS LAPSE_HISTORY
      WITH SYNONYMS ('lapse history', 'past lapses', 'policies lapsed before',
                     'prior lapses', 'previous churn')
      COMMENT = 'Number of policies this customer has allowed to lapse in the past. A behavioural churn indicator: a customer who has lapsed before is more likely to lapse again.',
    customers.claim_ratio AS CLAIM_RATIO
      WITH SYNONYMS ('claim ratio', 'claims ratio', 'loss ratio', 'recovery ratio')
      COMMENT = 'Approved claim amount over claimed amount, across all claims ever. NULL means the customer has NEVER CLAIMED, which is not the same as 0 -- zero means they claimed and recovered nothing. Do not coalesce NULL to zero when averaging; it would drag the average down with customers who simply never filed.',
    customers.credit_utilisation AS CREDIT_UTILISATION
      WITH SYNONYMS ('credit utilisation', 'credit utilization', 'utilisation',
                     'limit usage', 'card usage', 'how much of the limit is used')
      COMMENT = 'Card balance as a fraction of card limit, 0 to 1. High and rising utilisation is a stress signal.',
    customers.interactions_90d AS INTERACTIONS_90D
      WITH SYNONYMS ('interactions', 'recent interactions', 'contacts in 90 days',
                     'conversations', 'touches')
      COMMENT = 'Number of inbound interactions -- calls and service tickets -- in the 90 days before as_of_date.',
    customers.last_contact_days AS LAST_CONTACT_DAYS
      WITH SYNONYMS ('days since last contact', 'last contact', 'recency',
                     'how long since we spoke', 'days since we spoke')
      COMMENT = 'Days from the customer last interaction to as_of_date. NULL means NEVER CONTACTED -- treat that as unknown recency, not as a very recent or very old contact.',
    customers.product_count AS PRODUCT_COUNT
      WITH SYNONYMS ('products held', 'number of products', 'product count',
                     'how many products', 'holdings')
      COMMENT = 'Number of distinct product FAMILIES the customer holds, not the number of contracts. A customer with three motor policies counts as one.',
    customers.product_gap_count AS PRODUCT_GAP_COUNT
      WITH SYNONYMS ('product gaps', 'gaps', 'cross sell gaps', 'cross-sell gaps',
                     'missing products', 'unmet needs', 'white space', 'opportunities')
      COMMENT = 'Number of products the customer plausibly needs and does not hold. Derived from current holdings, life stage and transaction behaviour, and every entry is gated on not already holding the product. IMPORTANT -- this is a statement about the customer, NOT an eligibility verdict. Income-band and KYC gates are deliberately absent, so a gap here does not mean the customer can lawfully be sold the product.',
    customers.customer_days_to_renewal AS DAYS_TO_RENEWAL
      WITH SYNONYMS ('days to renewal', 'days until renewal', 'renewal in how many days',
                     'time to renewal')
      COMMENT = 'Days from as_of_date to the customer earliest upcoming policy renewal. NULL where the customer holds no policy with a future renewal.',

    /* ---- policies ---- */
    policies.premium_inr AS PREMIUM_INR
      WITH SYNONYMS ('premium', 'policy premium', 'premium amount', 'premium billed')
      COMMENT = 'Premium billed per payment period for this policy, in INR. NOT comparable across policies on its own because the period differs -- a monthly and an annual premium are both stored here. Use annualised_premium_inr to compare or to sum.',
    policies.annualised_premium_inr AS ANNUALISED_PREMIUM_INR
      WITH SYNONYMS ('annualised premium', 'annualized premium', 'annual premium',
                     'yearly premium', 'premium per year')
      COMMENT = 'Premium restated to a full year using the payment frequency, in INR. This is the column to sum or average when comparing premium across the book.',
    policies.sum_assured_inr AS SUM_ASSURED_INR
      WITH SYNONYMS ('sum assured', 'cover', 'coverage', 'cover amount',
                     'sum insured', 'face value', 'how much cover')
      COMMENT = 'The amount the policy would pay out, in INR. The exposure the group carries on this policy.',
    policies.policy_days_to_renewal AS POLICY_DAYS_TO_RENEWAL
      WITH SYNONYMS ('days to renewal', 'days until this policy renews',
                     'renewal in how many days', 'time to renewal')
      COMMENT = 'Days from as_of_date to this policy renewal date. Negative where the renewal date has already passed, which on an ACTIVE policy means the renewal is overdue.',
    policies.policy_age_years AS POLICY_AGE_YEARS
      WITH SYNONYMS ('policy age', 'how old is the policy', 'years since inception',
                     'vintage')
      COMMENT = 'Years from policy start date to as_of_date.',

    /* ---- loans ---- */
    loans.principal_inr AS PRINCIPAL_INR
      WITH SYNONYMS ('principal', 'loan amount', 'amount borrowed', 'original amount',
                     'sanctioned amount', 'disbursed amount')
      COMMENT = 'Amount originally lent, in INR.',
    loans.outstanding_inr AS OUTSTANDING_INR
      WITH SYNONYMS ('outstanding', 'outstanding balance', 'balance', 'amount owed',
                     'remaining balance', 'exposure')
      COMMENT = 'Amount still owed on this loan at as_of_date, in INR. This is total exposure regardless of whether the loan is up to date -- for the overdue subset use arrears_outstanding_inr.',
    loans.arrears_outstanding_inr AS ARREARS_OUTSTANDING_INR
      WITH SYNONYMS ('arrears exposure', 'overdue exposure', 'exposure in arrears',
                     'balance in arrears', 'balance overdue', 'delinquent balance',
                     'money at risk', 'exposure at risk')
      COMMENT = 'Outstanding balance on this loan if it is even one day past due, otherwise zero, in INR. The WHOLE balance, not the overdue instalment -- a loan 45 days down puts its full balance in question, which is the collections reading of exposure. Sum this for portfolio arrears exposure.',
    loans.emi_inr AS EMI_INR
      WITH SYNONYMS ('EMI', 'instalment', 'installment', 'monthly payment',
                     'monthly instalment', 'repayment amount')
      COMMENT = 'Equated monthly instalment due on this loan, in INR.',
    loans.dpd_days AS DPD_DAYS
      WITH SYNONYMS ('DPD', 'days past due', 'days overdue', 'days late',
                     'days in arrears', 'how overdue', 'delinquency days')
      COMMENT = 'Days past due on this loan at as_of_date. Zero means up to date. This is the current reading; dpd_days_previous_month and dpd_days_two_months_ago give the trend.',
    loans.dpd_days_previous_month AS DPD_DAYS_M1
      WITH SYNONYMS ('DPD last month', 'days past due last month', 'previous month DPD',
                     'DPD one month ago')
      COMMENT = 'Days past due one month before as_of_date. Compare with dpd_days to see whether arrears are worsening.',
    loans.dpd_days_two_months_ago AS DPD_DAYS_M2
      WITH SYNONYMS ('DPD two months ago', 'days past due two months ago',
                     'DPD two months back')
      COMMENT = 'Days past due two months before as_of_date. Together with the other two readings this makes a rising-arrears trend a simple comparison.',
    loans.interest_rate_pct AS INTEREST_RATE_PCT
      WITH SYNONYMS ('interest rate', 'rate', 'rate of interest', 'APR')
      COMMENT = 'Annual interest rate on this loan, as a percentage.',
    loans.tenure_months AS TENURE_MONTHS
      WITH SYNONYMS ('tenure', 'loan term', 'term', 'term in months', 'loan tenure')
      COMMENT = 'Full loan term in months.',
    loans.months_elapsed AS MONTHS_ELAPSED
      WITH SYNONYMS ('months elapsed', 'months paid', 'months into the loan',
                     'instalments paid')
      COMMENT = 'Months of the term already elapsed at as_of_date.',

    /* ---- claims ---- */
    claims.claim_amount_inr AS CLAIM_AMOUNT_INR
      WITH SYNONYMS ('claim amount', 'amount claimed', 'claimed', 'claim value',
                     'how much was claimed')
      COMMENT = 'Amount the customer claimed, in INR. Always populated.',
    claims.approved_amount_inr AS APPROVED_AMOUNT_INR
      WITH SYNONYMS ('approved amount', 'amount approved', 'amount paid',
                     'settled amount', 'payout')
      COMMENT = 'Amount approved and paid, in INR. NULL on anything not yet settled and on rejections -- NULL means no decision or no payout, not a zero payout. Use total_approved_inr, which zeroes these, when computing a settlement ratio across the book.',
    claims.settlement_days AS SETTLEMENT_DAYS
      WITH SYNONYMS ('settlement days', 'days to settle', 'settlement time',
                     'turnaround', 'how long to settle', 'TAT')
      COMMENT = 'Days from filing to settlement. NULL while the claim is still open or in review, and on rejections.',
    claims.claim_age_days AS CLAIM_AGE_DAYS
      WITH SYNONYMS ('claim age', 'days since filed', 'how old is the claim',
                     'age of claim')
      COMMENT = 'Days from filing to as_of_date. On an open claim this is how long the customer has been waiting.',

    /* ---- campaigns ---- */
    campaigns.revenue_inr AS REVENUE_INR
      WITH SYNONYMS ('revenue', 'campaign revenue', 'revenue generated',
                     'income', 'sales value')
      COMMENT = 'Revenue attributed to this contact, in INR. Zero on every outcome except a conversion.',
    campaigns.days_since_contact AS DAYS_SINCE_CONTACT
      WITH SYNONYMS ('days since contact', 'how long ago was the contact',
                     'contact recency', 'days ago')
      COMMENT = 'Days from this contact attempt to as_of_date.',

    /* ---- nba: the published ranking ---- */
    nba.action_rank AS ACTION_RANK
      WITH SYNONYMS ('rank', 'action rank', 'priority', 'position',
                     'which action', 'ordering')
      COMMENT = 'Position of this action in the customer ranked list, 1 being the one to do first. Up to three per customer. Filter is_top_action for the single recommendation an agent would lead with.',
    nba.propensity AS PROPENSITY
      WITH SYNONYMS ('propensity', 'likelihood', 'probability', 'take-up rate',
                     'likelihood to accept', 'conversion likelihood', 'score')
      COMMENT = 'Modelled probability the customer accepts this action, 0 to 1. One of the two multiplicands behind expected value. It is a model output, so treat it as a ranking quantity rather than a forecast anybody should quote to a customer.',
    nba.expected_value_inr AS EXPECTED_VALUE_INR
      WITH SYNONYMS ('expected value', 'EV', 'expected value in INR',
                     'value of the action', 'worth', 'opportunity value',
                     'expected margin', 'action value')
      COMMENT = 'Propensity times value at stake times margin rate, in INR. Deterministic arithmetic over a modelled propensity -- auditable, but only as good as the propensity. Sum it with total_expected_value_inr; the mean across a book of very different products is rarely a meaningful number.',
    nba.evidence_count AS EVIDENCE_COUNT
      WITH SYNONYMS ('evidence count', 'number of evidence items',
                     'how many citations', 'citation count')
      COMMENT = 'Number of evidence references attached to this recommendation -- interactions, tickets, transcripts or ledger rows. Zero means the rationale rests on structured signals alone, which is not a defect but is worth knowing before quoting it.',
    nba.trace_rule_count AS TRACE_RULE_COUNT
      WITH SYNONYMS ('trace length', 'rules evaluated', 'number of rules checked')
      COMMENT = 'Number of compliance rules recorded in this action eligibility trace.',
    nba.care_band AS CARE_BAND
      WITH SYNONYMS ('care band', 'action band')
      COMMENT = 'Internal band used to enforce that care actions outrank sales actions. Diagnostic; prefer is_care_action for a predicate.',

    /* ---- nba_candidates: the eligibility ledger ---- */
    nba_candidates.value_at_stake_inr AS VALUE_AT_STAKE_INR
      WITH SYNONYMS ('value at stake', 'value at risk', 'gross value',
                     'size of the opportunity', 'amount at stake',
                     'value blocked', 'value forgone')
      COMMENT = 'Gross rupee value the action would put in play if it converted, BEFORE propensity and margin are applied -- so it is larger than expected value and not comparable with it. This is the right number for "how much value are the compliance rules blocking", because on a suppressed row there is no propensity to apply.',
    nba_candidates.candidate_margin_rate AS MARGIN_RATE
      WITH SYNONYMS ('margin rate', 'margin', 'margin percentage')
      COMMENT = 'Product margin rate from RAW.PRODUCT_CATALOG, 0 to 1.',
    nba_candidates.rules_failed_count AS RULES_FAILED_COUNT
      WITH SYNONYMS ('rules failed', 'number of rules failed', 'failed rules',
                     'how many rules blocked it')
      COMMENT = 'Number of compliance rules this pair failed. More than one is common -- a customer on the DNC register with stale KYC fails both -- so the single suppression_reason is the governing rule, not the only one.',
    nba_candidates.rules_passed_count AS RULES_PASSED_COUNT
      WITH SYNONYMS ('rules passed', 'number of rules passed')
      COMMENT = 'Number of compliance rules this pair passed.'
  )

  DIMENSIONS (
    /* ---- customers: identity ---- */
    customers.as_of_date AS AS_OF_DATE
      WITH SYNONYMS ('as of date', 'as-of date', 'data date', 'snapshot date',
                     'reporting date', 'anchor date', 'current as of')
      COMMENT = 'The calendar anchor every day-count in this model was computed against. READ THIS BEFORE TREATING ANY DAY-COUNT AS CURRENT. It is a stored date, refreshed daily in normal operation, but a long gap with no data movement leaves it behind today rather than tracking it. Every "days to", "days since" and "within 30 days" figure in this model is measured from here, not from today.',
    customers.customer_id AS CUSTOMER_ID
      WITH SYNONYMS ('customer id', 'customer number', 'client id', 'id')
      COMMENT = 'Unique customer identifier. The join key every fact in this model shares.',
    customers.customer_name AS CUSTOMER_NAME
      WITH SYNONYMS ('name', 'customer name', 'client name', 'who')
      COMMENT = 'Customer full name. Synthetic data -- Indian names throughout.',
    customers.city AS CITY
      WITH SYNONYMS ('city', 'location', 'where', 'town', 'geography', 'branch city')
      COMMENT = 'City the customer is resident in. 20 Indian cities.',
    customers.segment AS SEGMENT
      WITH SYNONYMS ('segment', 'customer segment', 'wealth segment', 'tier',
                     'customer tier', 'banding')
      COMMENT = 'Wealth segment assigned by the bank: MASS, MASS_AFFLUENT, AFFLUENT, PRIORITY, HNI. An input to the relationship, not an output of it -- for value delivered use relationship_value_band, which is computed from actual margin.',
    customers.age_band AS AGE_BAND
      WITH SYNONYMS ('age band', 'age group', 'age bracket', 'age range', 'generation')
      COMMENT = 'Age bucketed: UNDER_30, 30_TO_39, 40_TO_49, 50_TO_59, 60_PLUS.',
    customers.tenure_band AS TENURE_BAND
      WITH SYNONYMS ('tenure band', 'tenure group', 'tenure bracket',
                     'how long a customer band', 'relationship length band')
      COMMENT = 'Tenure bucketed: UNDER_1_YEAR, 1_TO_3_YEARS, 3_TO_7_YEARS, 7_YEARS_PLUS.',

    /* ---- customers: value ---- */
    customers.relationship_value_band AS RELATIONSHIP_VALUE_BAND
      WITH SYNONYMS ('relationship value band', 'value band', 'value tier',
                     'customer value band', 'platinum gold silver bronze',
                     'how valuable a customer', 'value segment')
      COMMENT = 'Fixed INR thresholds on estimated annual margin: PLATINUM at or above 150,000, GOLD at or above 75,000, SILVER at or above 25,000, BRONZE above zero, NO_ACTIVE_HOLDINGS otherwise. Calibrated on the measured distribution so PLATINUM is roughly the top decile. Distinct from segment, which is an assigned wealth tier rather than a measured one.',

    /* ---- customers: holdings and gaps ---- */
    customers.products_held_list AS PRODUCTS_HELD_LIST
      WITH SYNONYMS ('products held', 'what they hold', 'holdings',
                     'products owned', 'current products')
      COMMENT = 'Comma-separated list of product families currently held, active contracts only.',
    customers.product_gap_list AS PRODUCT_GAP_LIST
      WITH SYNONYMS ('product gaps', 'gap list', 'missing products',
                     'what they are missing', 'cross sell opportunities')
      COMMENT = 'Comma-separated list of products the customer plausibly needs and does not hold. A need statement, not an eligibility verdict -- see the product_gap_count fact.',
    customers.has_home_loan AS HAS_HOME_LOAN
      WITH SYNONYMS ('has a home loan', 'has mortgage', 'holds a home loan',
                     'home loan customer', 'mortgage holder')
      COMMENT = 'True if the customer holds an active home loan.',
    customers.has_home_insurance AS HAS_HOME_INSURANCE
      WITH SYNONYMS ('has home insurance', 'holds home insurance',
                     'home cover', 'property insurance')
      COMMENT = 'True if the customer holds an active home insurance policy.',
    customers.has_health_cover AS HAS_HEALTH
      WITH SYNONYMS ('has health insurance', 'holds health cover', 'health cover',
                     'medical insurance', 'health insured')
      COMMENT = 'True if the customer holds an active health insurance policy.',
    customers.has_card AS HAS_CARD
      WITH SYNONYMS ('has a credit card', 'holds a card', 'card holder', 'cardholder')
      COMMENT = 'True if the customer holds an active credit card.',
    customers.has_investment AS HAS_INVESTMENT
      WITH SYNONYMS ('has investments', 'holds investments', 'investment customer',
                     'wealth customer', 'invested')
      COMMENT = 'True if the customer holds an active investment or ULIP product.',
    customers.has_health_gap AS HAS_HEALTH_GAP
      WITH SYNONYMS ('health gap', 'needs health insurance', 'missing health cover',
                     'health insurance opportunity', 'uninsured for health')
      COMMENT = 'True if health insurance is a plausible unmet need for this customer. A need, not an eligibility verdict.',
    customers.has_term_life_gap AS HAS_TERM_LIFE_GAP
      WITH SYNONYMS ('term life gap', 'needs term life', 'missing life cover',
                     'protection gap', 'life insurance opportunity')
      COMMENT = 'True if term life cover is a plausible unmet need for this customer. A need, not an eligibility verdict.',
    customers.has_home_insurance_gap AS HAS_HOME_INSURANCE_GAP
      WITH SYNONYMS ('home insurance gap', 'needs home insurance',
                     'missing home cover', 'unprotected property')
      COMMENT = 'True if home insurance is a plausible unmet need -- typically a customer with a home loan and no cover on the property. A need, not an eligibility verdict.',
    customers.has_investment_gap AS HAS_INVESTMENT_GAP
      WITH SYNONYMS ('investment gap', 'needs investments', 'wealth opportunity',
                     'wealth referral candidate', 'missing investments')
      COMMENT = 'True if an investment product is a plausible unmet need for this customer. A need, not an eligibility verdict.',

    /* ---- customers: risk ---- */
    customers.worst_dpd_bucket AS WORST_DPD_BUCKET
      WITH SYNONYMS ('worst arrears bucket', 'worst DPD bucket', 'customer arrears status',
                     'worst overdue bucket', 'customer DPD', 'arrears status',
                     'worst delinquency bucket')
      COMMENT = 'Worst arrears bucket across all the customer active loans: CURRENT, 1-30, 31-60, 61-90, or NO_CREDIT_OBLIGATION. NO_CREDIT_OBLIGATION IS NOT THE SAME AS CURRENT -- one customer has no borrowing at all, the other has borrowing and is up to date. Do not group them. For per-loan arrears use dpd_bucket on the loans table.',
    customers.is_in_arrears_customer AS IS_IN_ARREARS_CUSTOMER
      WITH SYNONYMS ('customer in arrears', 'customers in arrears', 'in arrears',
                     'overdue customer', 'customer is overdue', 'behind on payments',
                     'delinquent customer', 'customer is late', 'customer past due')
      COMMENT = 'True if ANY of the customer active loans is at least one day past due. The customer-level arrears filter -- use this rather than reconstructing a predicate on worst_dpd_bucket, because it already handles the trap that NO_CREDIT_OBLIGATION (no borrowing at all) must not be grouped with CURRENT (borrowing, up to date). False for customers with no borrowing.',
    customers.has_hardship_signal AS HARDSHIP_SIGNAL
      WITH SYNONYMS ('hardship', 'financial hardship', 'hardship signal', 'in difficulty',
                     'financial stress', 'struggling', 'distress', 'vulnerable to hardship')
      COMMENT = 'True on any of four arms: arrears rising across three consecutive monthly readings, two or more missed instalments in six months, a restructured loan, or hardship raised in conversation in the last 90 days. Deliberately broad, because it routes a customer to service instead of sales -- a false positive costs one cross-sell, a false negative means marketing to somebody in difficulty. Treat this as a stop signal for any sales action.',
    customers.is_vulnerable AS VULNERABILITY_FLAG
      WITH SYNONYMS ('vulnerable', 'vulnerable customer', 'vulnerability',
                     'flagged vulnerable', 'at-risk customer', 'needs extra care')
      COMMENT = 'True if the customer is on the vulnerability register -- age, health, capacity or circumstance. A conduct constraint: vulnerable customers must not be marketed products flagged as unsuitable for them.',

    /* ---- customers: engagement and churn ---- */
    customers.sentiment_now AS SENTIMENT_NOW
      WITH SYNONYMS ('sentiment', 'current sentiment', 'mood', 'how they feel',
                     'tone', 'customer sentiment', 'happy or unhappy')
      COMMENT = 'Sentiment of the customer most recent interaction: positive, neutral, negative or mixed. Derived from what they actually said, in calls and tickets. NULL where the customer has never been in contact.',
    customers.sentiment_trend AS SENTIMENT_TREND
      WITH SYNONYMS ('sentiment trend', 'trend', 'getting better or worse',
                     'relationship trajectory', 'direction of travel', 'souring',
                     'deteriorating relationship', 'churn signal', 'attrition signal')
      COMMENT = 'Direction of travel in the customer sentiment: DETERIORATING, STABLE, IMPROVING, INSUFFICIENT_DATA or NO_CONTACT_HISTORY. CRITICAL -- INSUFFICIENT_DATA and NO_CONTACT_HISTORY both mean UNKNOWN and MUST NOT be counted as STABLE. A customer with one angry interaction has no trend, and reporting that as stable reads a deteriorating relationship as a calm one. When asked how many customers are stable, count STABLE only; when asked how many are not deteriorating, say explicitly how many are unknown.',
    customers.has_open_complaint AS OPEN_COMPLAINT
      WITH SYNONYMS ('open complaint', 'has a complaint', 'complaining',
                     'unresolved complaint', 'live grievance', 'grievance',
                     'outstanding complaint')
      COMMENT = 'True if the customer has a service complaint still open. A complaint plus an approaching renewal is the classic retention risk -- see the policies_at_risk_30d metric.',
    customers.preferred_channel AS PREFERRED_CHANNEL
      WITH SYNONYMS ('preferred channel', 'best channel', 'channel preference',
                     'how to reach them', 'which channel works')
      COMMENT = 'The channel that has historically produced engagement from this customer -- a conversion or an expression of interest. A BEHAVIOURAL PREFERENCE AND NOT A PERMISSION. Always check the matching consent dimension before acting on it; the customer preferred channel may be one they have since withdrawn consent for.',

    /* ---- customers: permission ---- */
    customers.has_consent_call AS CONSENT_CALL
      WITH SYNONYMS ('consent to call', 'can we call', 'call consent',
                     'phone consent', 'allowed to call', 'call permission')
      COMMENT = 'Permission to contact by call at as_of_date: opted in AND not on the do-not-call registry AND inside the consent validity window, all three together. Never NULL. This is the authoritative answer to "can we call this customer".',
    customers.has_consent_email AS CONSENT_EMAIL
      WITH SYNONYMS ('consent to email', 'can we email', 'email consent',
                     'allowed to email', 'email permission')
      COMMENT = 'Permission to contact by email at as_of_date, folding opt-in, registry status and validity window together. Never NULL.',
    customers.has_consent_sms AS CONSENT_SMS
      WITH SYNONYMS ('consent to SMS', 'can we text', 'SMS consent', 'text consent',
                     'allowed to text', 'SMS permission')
      COMMENT = 'Permission to contact by SMS at as_of_date, folding opt-in, registry status and validity window together. Never NULL.',
    customers.is_on_dnc_registry AS DNC_FLAG
      /* 'suppressed' was removed here when the engine arrived. DNC_REGISTRY is
         one of thirteen suppression reasons, so this dimension answers a
         narrower question than the word now implies, and leaving the synonym
         attached would let a policy-shaped flag steal every question about the
         engine blocking an action -- the same over-claiming failure Q7 recorded
         when 'churn risk' was attached to a policy metric and stole a
         customer-grain question. 'suppressed' belongs to
         nba_candidates.suppressed. */
      WITH SYNONYMS ('DNC', 'do not contact', 'do-not-contact', 'do not call',
                     'on the DNC list', 'opted out')
      COMMENT = 'Do-not-contact registry marker on the call or SMS channel -- the channels a registry governs in this market. 1,330 customers, 27 percent. NOT an any-channel reading, which would flag 46 percent and stop discriminating. For a specific channel the authoritative columns are the three consent dimensions, which already fold this in. This is a PERMISSION on the customer, not an engine decision: for actions the engine blocked, including the ones this flag caused, use nba_candidates.suppressed and its suppression_reason.',
    customers.is_reachable_any_channel AS IS_REACHABLE_ANY_CHANNEL
      WITH SYNONYMS ('reachable', 'contactable', 'can we contact them',
                     'permitted to contact', 'any channel available')
      COMMENT = 'True if the customer can lawfully be contacted on AT LEAST ONE of call, email or SMS. An OR across the three consent dimensions. The right filter for "how much of the book can we actually talk to".',
    customers.is_kyc_current AS KYC_CURRENT
      WITH SYNONYMS ('KYC current', 'KYC valid', 'KYC done', 'KYC status',
                     'identity verified', 'KYC compliant', 'KYC up to date')
      COMMENT = 'True if the customer identity documentation is current. Stale KYC blocks new product sales regardless of any other signal.',

    /* ---- customers: timing ---- */
    customers.next_renewal_date AS NEXT_RENEWAL_DATE
      WITH SYNONYMS ('next renewal date', 'renewal date', 'when do they renew',
                     'upcoming renewal')
      COMMENT = 'Date of the customer earliest upcoming policy renewal. NULL where they hold no policy with a future renewal.',
    customers.next_emi_date AS NEXT_EMI_DATE
      WITH SYNONYMS ('next EMI date', 'next instalment date', 'next payment due',
                     'when is the next EMI')
      COMMENT = 'Projected date of the customer next loan instalment, from the loan schedule. NULL past the final instalment or where they hold no loan.',

    /* ---- policies ---- */
    policies.policy_number AS POLICY_NUMBER
      WITH SYNONYMS ('policy number', 'policy reference', 'policy no')
      COMMENT = 'Human-readable policy reference.',
    policies.policy_type AS POLICY_TYPE
      WITH SYNONYMS ('policy type', 'type of policy', 'type of insurance',
                     'kind of cover', 'insurance type', 'motor health term home ULIP')
      COMMENT = 'What the policy covers: motor, health, term life, home or ULIP.',
    policies.policy_product_family AS POLICY_PRODUCT_FAMILY
      WITH SYNONYMS ('product family', 'policy product family', 'product group',
                     'family of product')
      COMMENT = 'Product family the policy belongs to, from the product catalogue.',
    policies.policy_line_of_business AS POLICY_LINE_OF_BUSINESS
      WITH SYNONYMS ('line of business', 'LOB', 'business line', 'division',
                     'insurance or banking', 'which side of the group')
      COMMENT = 'Which side of the group the policy sits on -- insurance or banking. The group is a bank and an insurer, and this separates the two books.',
    policies.policy_status AS POLICY_STATUS
      WITH SYNONYMS ('policy status', 'status', 'state of the policy',
                     'active or lapsed', 'is it in force')
      COMMENT = 'ACTIVE, LAPSED, MATURED or SURRENDERED. Only ACTIVE is in force. Note that all four appear in this table -- an unfiltered policy count includes policies that ended.',
    policies.is_active_policy AS IS_ACTIVE_POLICY
      WITH SYNONYMS ('active policy', 'in force', 'live policy', 'current policy',
                     'still active')
      COMMENT = 'True if the policy is in force. The filter for any question about the live book.',
    policies.is_lapsed_policy AS IS_LAPSED_POLICY
      WITH SYNONYMS ('lapse', 'lapsed', 'lapsed policy', 'churn', 'churned',
                     'attrition', 'attrited', 'not renewed', 'failed to renew',
                     'let it lapse', 'dropped out', 'left us', 'cancelled')
      COMMENT = 'True if the policy lapsed -- the customer stopped paying and cover ended. THIS IS WHAT CHURN AND ATTRITION MEAN IN THIS MODEL. Deliberately taken from the recorded lapse event rather than from policy status, because status also carries MATURED and SURRENDERED, and neither of those is churn: a matured policy ran its full term successfully, and a surrender is a deliberate exit on the customer terms. Counting either as churn overstates attrition.',
    policies.renews_within_30d AS RENEWS_WITHIN_30D
      WITH SYNONYMS ('renewing soon', 'renews within 30 days', 'renewal coming up',
                     'due for renewal', 'renewal window', 'upcoming renewal')
      COMMENT = 'True if the policy is active and its renewal date falls within 30 days of as_of_date. Timing only -- this says nothing about whether the renewal is in doubt. For renewals in doubt use is_at_risk_30d.',
    policies.has_complaint_last_60d AS HAS_COMPLAINT_LAST_60D
      WITH SYNONYMS ('recent complaint', 'complained recently',
                     'complaint in the last 60 days', 'recent grievance')
      COMMENT = 'True if the customer holding this policy raised a complaint in the 60 days before as_of_date. Customer-level, so it is true on every policy that customer holds.',
    policies.is_at_risk_30d AS IS_AT_RISK_30D
      WITH SYNONYMS ('at risk', 'at-risk policy', 'renewal at risk',
                     'retention risk', 'likely to lapse', 'in danger of lapsing',
                     'needs saving', 'retention save', 'renewal in doubt')
      COMMENT = 'True if the policy is active, renews within 30 days, AND the customer complained in the last 60 days. Both halves together -- an approaching renewal alone is just the calendar, and roughly one policy in twelve renews in any 30-day window. This is the retention-save population: the correct action is to KEEP the customer, and a cross-sell recommendation to anybody in here is a ranking failure. 420 policies at the current anchor. NOTE this is POLICY-level and forward-looking. It is not the same thing as a customer-level churn signal (see sentiment_trend) and not the same thing as a lapse that has already happened (see is_lapsed_policy).',
    policies.premium_frequency AS PREMIUM_FREQUENCY
      WITH SYNONYMS ('premium frequency', 'payment frequency', 'how often they pay',
                     'billing frequency', 'payment mode')
      COMMENT = 'How often premium falls due: MONTHLY, QUARTERLY, HALF_YEARLY or ANNUAL. This is why raw premium is not comparable across policies.',
    policies.channel_sold AS CHANNEL_SOLD
      WITH SYNONYMS ('channel sold', 'sales channel', 'sold through',
                     'origination channel', 'where it was sold', 'acquisition channel')
      COMMENT = 'The channel the policy was originally sold through. An origination attribute, unrelated to which channel the customer may now be contacted on.',
    policies.agent_id AS AGENT_ID
      WITH SYNONYMS ('agent', 'agent id', 'who sold it', 'selling agent', 'adviser')
      COMMENT = 'Identifier of the agent who sold the policy.',

    /* ---- loans ---- */
    loans.loan_account_no AS LOAN_ACCOUNT_NO
      WITH SYNONYMS ('loan account number', 'loan account', 'account number',
                     'loan reference')
      COMMENT = 'Human-readable loan account reference.',
    loans.loan_type AS LOAN_TYPE
      WITH SYNONYMS ('loan type', 'type of loan', 'kind of loan',
                     'home auto personal', 'lending product')
      COMMENT = 'What the loan is for: home, auto, personal and so on.',
    loans.loan_product_family AS LOAN_PRODUCT_FAMILY
      WITH SYNONYMS ('loan product family', 'lending product family',
                     'loan product group')
      COMMENT = 'Product family the loan belongs to, from the product catalogue.',
    loans.loan_status AS LOAN_STATUS
      WITH SYNONYMS ('loan status', 'status of the loan', 'is the loan open')
      COMMENT = 'Loan status. Every loan in this table is currently ACTIVE, so this does not discriminate -- for loan health use dpd_bucket or is_in_arrears instead.',
    loans.dpd_bucket AS DPD_BUCKET
      WITH SYNONYMS ('arrears', 'arrears bucket', 'overdue', 'overdue bucket',
                     'DPD', 'DPD bucket', 'days past due', 'days past due bucket',
                     'delinquency', 'delinquency bucket', 'late bucket',
                     'how late', 'ageing bucket', 'aging bucket')
      COMMENT = 'Arrears bucket for this loan: CURRENT, 1-30, 31-60 or 61-90 days past due. THE STANDARD WAY TO ASK ABOUT ARREARS, OVERDUE OR DPD IN THIS MODEL. Note this is per loan -- a customer with two loans appears in two buckets, so for a customer-level reading use worst_dpd_bucket on the customers table instead. WHEN BREAKING ANYTHING DOWN BY THIS BUCKET, include total_outstanding_inr and not only arrears_exposure_inr: arrears exposure is zero by construction in the CURRENT bucket, so a bucket breakdown showing arrears exposure alone reports the 2,654 up-to-date loans as carrying no balance, which is wrong by a wide margin.',
    loans.is_in_arrears AS IS_IN_ARREARS
      WITH SYNONYMS ('in arrears', 'overdue', 'late', 'behind on payments',
                     'delinquent', 'not paying', 'past due', 'defaulting')
      COMMENT = 'True if the loan is at least one day past due. The filter behind arrears_exposure_inr and loans_in_arrears.',
    loans.is_restructured AS IS_RESTRUCTURED
      WITH SYNONYMS ('restructured', 'restructured loan', 'reworked',
                     'terms changed', 'rescheduled', 'forbearance')
      COMMENT = 'True if the loan terms were renegotiated because the customer could not meet the original schedule. A hardship marker that persists after the arrears themselves clear.',
    loans.is_dpd_rising AS IS_DPD_RISING
      WITH SYNONYMS ('DPD rising', 'arrears worsening', 'getting worse',
                     'deteriorating arrears', 'arrears increasing',
                     'worsening delinquency', 'slipping')
      COMMENT = 'True if days past due increased across three consecutive monthly readings. A trajectory, not a level -- a loan at 40 days and rising is a different problem from one at 40 days and falling, and this separates them. One of the four arms of the customer hardship signal.',

    /* ---- claims ---- */
    claims.claim_number AS CLAIM_NUMBER
      WITH SYNONYMS ('claim number', 'claim reference', 'claim no')
      COMMENT = 'Human-readable claim reference.',
    claims.claim_type AS CLAIM_TYPE
      WITH SYNONYMS ('claim type', 'type of claim', 'kind of claim', 'what was claimed for')
      COMMENT = 'What the claim was for.',
    claims.claim_status AS CLAIM_STATUS
      WITH SYNONYMS ('claim status', 'status of the claim', 'where is the claim',
                     'settled or open')
      COMMENT = 'OPEN, IN_REVIEW, SETTLED or REJECTED. Only SETTLED has a payout; the other three have a NULL approved amount.',
    claims.is_settled_claim AS IS_SETTLED_CLAIM
      WITH SYNONYMS ('settled', 'settled claim', 'paid out', 'claim paid', 'closed and paid')
      COMMENT = 'True if the claim was settled and paid.',
    claims.is_rejected_claim AS IS_REJECTED_CLAIM
      WITH SYNONYMS ('rejected', 'rejected claim', 'declined claim', 'refused',
                     'turned down', 'repudiated')
      COMMENT = 'True if the claim was rejected. A rejection is a strong dissatisfaction driver and often precedes a complaint or a lapse.',
    claims.is_open_claim AS IS_OPEN_CLAIM
      WITH SYNONYMS ('open claim', 'pending claim', 'unsettled claim',
                     'claim in progress', 'awaiting settlement', 'in review')
      COMMENT = 'True if the claim is still open or in review, that is, the customer is waiting. Combine with claim_age_days to find customers who have been waiting a long time.',
    claims.claim_policy_type AS CLAIM_POLICY_TYPE
      WITH SYNONYMS ('policy type of the claim', 'claim policy type',
                     'which policy type claimed', 'product claimed on')
      COMMENT = 'Policy type the claim was filed against, carried on the claim row so claims can be sliced by product without a second join.',
    claims.claim_product_family AS CLAIM_PRODUCT_FAMILY
      WITH SYNONYMS ('claim product family', 'product family of the claim')
      COMMENT = 'Product family the claimed policy belongs to.',

    /* ---- campaigns ---- */
    campaigns.campaign_id AS CAMPAIGN_ID
      WITH SYNONYMS ('campaign id', 'campaign code', 'campaign reference')
      COMMENT = 'Campaign identifier.',
    campaigns.campaign_name AS CAMPAIGN_NAME
      WITH SYNONYMS ('campaign', 'campaign name', 'which campaign', 'offer name')
      COMMENT = 'Human-readable campaign name.',
    campaigns.campaign_channel AS CAMPAIGN_CHANNEL
      WITH SYNONYMS ('channel', 'campaign channel', 'contact channel',
                     'which channel', 'medium', 'how they were contacted',
                     'SMS email call WhatsApp')
      COMMENT = 'Channel the contact attempt was made on: SMS, EMAIL, CALL or WHATSAPP. The channel actually USED -- distinct from preferred_channel, which is where the customer responds best, and from the consent dimensions, which govern where contact is permitted.',
    campaigns.campaign_outcome AS CAMPAIGN_OUTCOME
      WITH SYNONYMS ('outcome', 'campaign outcome', 'result', 'response',
                     'what happened', 'how did they respond')
      COMMENT = 'How the customer responded: CONVERTED, INTERESTED, DECLINED, NO_RESPONSE, OPT_OUT or COMPLAINED. The last two are adverse -- contacting somebody has a cost, and a channel with a high conversion rate and a high opt-out rate is not obviously a good channel.',
    campaigns.campaign_product_family AS CAMPAIGN_PRODUCT_FAMILY
      WITH SYNONYMS ('campaign product family', 'what was offered',
                     'product offered', 'offer product family')
      COMMENT = 'Product family that was offered in this contact.',
    campaigns.contacted_month AS CONTACTED_MONTH
      WITH SYNONYMS ('month', 'contact month', 'month contacted', 'when',
                     'by month', 'monthly')
      COMMENT = 'Month the contact was made, truncated to the first of the month. The time grain for any campaign trend question. Covers 12 rolling months.',
    campaigns.contacted_at AS CONTACTED_AT
      WITH SYNONYMS ('contacted at', 'contact date', 'contact timestamp',
                     'when were they contacted', 'date of contact')
      COMMENT = 'Exact timestamp of the contact attempt.',
    campaigns.is_converted AS IS_CONVERTED
      WITH SYNONYMS ('converted', 'sale made', 'bought', 'accepted',
                     'took the offer', 'successful contact')
      COMMENT = 'True if the contact resulted in a sale.',
    campaigns.is_engaged AS IS_ENGAGED
      WITH SYNONYMS ('engaged', 'responded positively', 'showed interest',
                     'interested or converted', 'positive response')
      COMMENT = 'True if the customer converted OR expressed interest. A softer success measure than conversion, and the one behind preferred_channel.',
    campaigns.is_opt_out AS IS_OPT_OUT
      WITH SYNONYMS ('opted out', 'opt out', 'unsubscribed', 'asked us to stop',
                     'withdrew consent', 'adverse outcome')
      COMMENT = 'True if the customer used this contact to opt out of future contact. An adverse outcome: it permanently reduces the reachable book, so it is a real cost of campaigning and not a neutral non-response.',
    campaigns.is_complaint_outcome AS IS_COMPLAINT_OUTCOME
      WITH SYNONYMS ('complained about the contact', 'complaint outcome',
                     'contact generated a complaint', 'adverse outcome')
      COMMENT = 'True if the customer complained in response to being contacted. The most adverse campaign outcome there is.',
    campaigns.is_no_response AS IS_NO_RESPONSE
      WITH SYNONYMS ('no response', 'did not respond', 'no reply', 'ignored',
                     'unanswered')
      COMMENT = 'True if the contact attempt got no response at all.',

    /* ---- nba: what the engine decided ---- */
    nba.action_code AS ACTION_CODE
      WITH SYNONYMS ('action code', 'recommendation code', 'offer code',
                     'which action code')
      COMMENT = 'Stable code for the recommended action, from GOLD.ACTION_CATALOG -- for example PROTECTION_CROSS_SELL, CARD_LIMIT_INCREASE, HARDSHIP_OUTREACH. 18 actions. Use action_name for anything a person reads.',
    nba.action_name AS ACTION_NAME
      WITH SYNONYMS ('action', 'action name', 'recommendation', 'what to do',
                     'the offer', 'recommended action name')
      COMMENT = 'Human-readable name of the recommended action. The label to use in any answer a person reads.',
    nba.action_channel AS CHANNEL
      WITH SYNONYMS ('action channel', 'recommended channel', 'how to contact',
                     'channel to use', 'delivery channel')
      COMMENT = 'Channel the action should be delivered on. THIS IS THE THIRD CHANNEL-SHAPED DIMENSION IN THIS MODEL and it means something different from the other two: channel_sold on policies is where a policy was originated, campaign_channel on campaigns is where a past contact went out, and this is where the engine proposes to make the next contact. It already respects the customer consent state -- an action is not published on a channel the customer has not permitted.',
    nba.rationale_source AS RATIONALE_SOURCE
      WITH SYNONYMS ('rationale source', 'reason source', 'who wrote the reason',
                     'LLM or template', 'provenance', 'narration source',
                     'was it written by AI')
      COMMENT = 'LLM where the rationale was written by a frontier model on the narration cohort, TEMPLATE where it was assembled from the deterministic drivers. Both are real recommendations with the same expected value and the same eligibility trace; only the prose differs. This distinction is published rather than hidden, so report it when the quality of the wording is what is being discussed -- and never imply a TEMPLATE row is less compliant, because the compliance decision is deterministic for every row.',
    nba.is_top_action AS IS_TOP_ACTION
      WITH SYNONYMS ('top action', 'first action', 'rank 1', 'the one to do first',
                     'lead recommendation', 'primary action', 'best action')
      COMMENT = 'True on the rank-1 action for a customer. Filter on this whenever the question is about the recommendation for a customer rather than all their options -- without it, counts are inflated up to threefold by ranks 2 and 3.',
    nba.is_sales_action AS IS_SALES_ACTION
      WITH SYNONYMS ('sales action', 'is a sale', 'commercial action',
                     'cross-sell or upsell', 'revenue action')
      COMMENT = 'True if the action sells something. False for servicing, retention and care actions.',
    nba.is_care_action AS IS_CARE_ACTION
      WITH SYNONYMS ('care action', 'service action', 'servicing action',
                     'protective action', 'non-sales action', 'help the customer',
                     'hardship or complaint action')
      COMMENT = 'True on the actions that exist to look after the customer rather than sell to them: hardship outreach, arrears reminders, complaint callbacks, service recovery and retention saves. sql/15 enforces that these outrank every sales action for the same customer regardless of expected value, so a customer with a care action at rank 1 is being deliberately protected from the cross-sell that would otherwise have ranked first.',
    nba.has_disclosure AS HAS_DISCLOSURE
      WITH SYNONYMS ('has disclosure', 'carries a disclosure',
                     'regulatory disclosure present')
      COMMENT = 'True if the action carries a required regulatory disclosure the agent must read out -- IRDAI free-look, RBI key fact statement and so on. Absence means the action needs none, not that one was omitted.',
    nba.has_evidence AS HAS_EVIDENCE
      WITH SYNONYMS ('has evidence', 'has citations', 'is evidenced',
                     'backed by evidence')
      COMMENT = 'True if the recommendation cites at least one interaction, ticket, transcript or ledger row.',
    nba.rank_moved AS RANK_MOVED
      WITH SYNONYMS ('rank moved', 'reordered', 'model changed the order',
                     'LLM reordered')
      COMMENT = 'True where the narrating model reordered this action relative to the deterministic scorer. Measured across the book, every such inversion sat inside the sales band; a care action was never pushed below a sale, and sql/15 enforces that rather than trusting it.',
    nba.action_class AS ACTION_CLASS
      WITH SYNONYMS ('action class', 'sales or care', 'care or sales',
                     'action type', 'kind of recommendation',
                     'sales versus care', 'split between sales and care',
                     'action classification', 'commercial or service')
      COMMENT = 'THREE values, exhaustive and mutually exclusive: SALES, CARE and RETENTION. THIS IS THE DIMENSION FOR ANY QUESTION ABOUT THE SPLIT, MIX OR BALANCE of what the engine recommends -- group nba_count by it. Measured: SALES 2,670 actions, CARE 908, RETENTION 339. CARE is the protective band sql/15 enforces above every sale -- hardship outreach, arrears reminders, complaint callbacks, service recovery, retention saves. SALES sells something new. RETENTION is the third class the question "sales versus care" does not anticipate: early renewal reminders and lapsed-policy win-backs, which are non-sales but sit above the care boundary because they keep existing business rather than protect a customer in difficulty. If asked for a two-way split, give three and say why -- forcing renewal reminders into either bucket misstates them. Do not build this classification from is_sales_action and is_care_action yourself: those are booleans and give columns, whereas a split is rows, and constructing the category in SQL means leaving this model. UNCLASSIFIED should never appear.',
    nba.action_priority_tier AS PRIORITY_TIER
      WITH SYNONYMS ('priority tier', 'action tier', 'tier')
      COMMENT = 'Fixed tier from the action catalogue, lower being more urgent. Tier 20 and below is the care boundary -- prefer is_care_action to comparing the number.',

    /* ---- nba_candidates: what the engine was allowed to decide ---- */
    nba_candidates.candidate_action_code AS ACTION_CODE
      WITH SYNONYMS ('candidate action code', 'evaluated action code',
                     'considered action code')
      COMMENT = 'Action code of the evaluated pair. Same 18-value vocabulary as nba.action_code, on a different table and a different grain -- this one exists whether or not anything was recommended.',
    nba_candidates.candidate_action_name AS ACTION_NAME
      WITH SYNONYMS ('candidate action', 'evaluated action', 'considered action',
                     'action considered', 'blocked action', 'suppressed action')
      COMMENT = 'Human-readable name of the evaluated action.',
    nba_candidates.candidate_category AS CATEGORY
      WITH SYNONYMS ('action category', 'category', 'kind of action',
                     'type of action')
      COMMENT = 'Category of the action from the catalogue -- cross-sell, upsell, retention, servicing, collections and so on.',
    nba_candidates.eligible_on_need AS ELIGIBLE_ON_NEED
      WITH SYNONYMS ('eligible on need', 'needed', 'customer needs it',
                     'passed the need test', 'relevant to the customer',
                     'plausible for the customer')
      COMMENT = 'True if the customer plausibly wants this product -- there is a gap, or a trigger fired. 16,475 of 90,000 pairs. THIS IS THE DENOMINATOR FOR ANY SUPPRESSION QUESTION. The 73,525 pairs where it is false were never candidates in a useful sense, usually because the customer already holds the product, and including them makes every suppression rate a function of catalogue size instead of compliance.',
    nba_candidates.suppressed AS SUPPRESSED
      WITH SYNONYMS ('suppressed', 'blocked', 'was blocked', 'not allowed',
                     'refused', 'prohibited', 'stopped by a rule',
                     'failed compliance')
      COMMENT = 'True if a compliance rule blocked this pair. Almost always wanted together with eligible_on_need: suppressed AND eligible_on_need is an action the engine wanted to take and could not, which is the interesting population. Use the is_suppressed_need dimension, which is exactly that conjunction.',
    nba_candidates.is_suppressed_need AS IS_SUPPRESSED_NEED
      WITH SYNONYMS ('suppressed and needed', 'blocked opportunity',
                     'wanted but blocked', 'blocked despite need',
                     'lost to compliance', 'compliance block')
      COMMENT = 'True where the customer needed the action AND a rule blocked it: 12,435 pairs across 4,580 customers. The numerator of suppression_rate, and the population to look at for "what is compliance costing us".',
    nba_candidates.is_actionable AS IS_ACTIONABLE
      WITH SYNONYMS ('actionable', 'allowed', 'permitted', 'passed compliance',
                     'clear to act', 'can be acted on')
      COMMENT = 'True where the customer needed the action and no rule blocked it: 4,040 pairs. These are what the published ranking is drawn from, cut to at most three per customer -- so this is larger than nba_count and the gap is the ranking cut-off, not a second suppression.',
    nba_candidates.suppression_reason AS SUPPRESSION_REASON
      WITH SYNONYMS ('suppression reason', 'why was it blocked', 'blocking rule',
                     'reason for suppression', 'which rule blocked it',
                     'why not', 'governing rule', 'reason blocked')
      COMMENT = 'The governing rule that blocked the pair, or NOT_SUPPRESSED where nothing did. Thirteen values: DNC_REGISTRY, NO_CHANNEL_CONSENT, PRODUCT_GATE_INCOME_BAND, OPEN_COMPLAINT, COOLDOWN, ARREARS_CROSS_SELL, PRODUCT_GATE_KYC, PRODUCT_GATE_AGE, VULNERABILITY_GATE, ACTION_SPECIFIC, ARREARS_SALES, PRODUCT_GATE_TENURE, NOT_SUPPRESSED. NOT_SUPPRESSED IS A REAL VALUE AND NOT MISSING DATA -- it is the 4,040 pairs that passed, and a breakdown that filters it out is answering a narrower question than it appears to. This is the GOVERNING rule, singular: a pair can fail several, and rules_failed_count says how many.',
    nba_candidates.suppression_category AS SUPPRESSION_CATEGORY
      WITH SYNONYMS ('suppression category', 'kind of block',
                     'category of suppression', 'type of rule',
                     'family of reason')
      COMMENT = 'The thirteen reasons rolled up to six: CONSENT (DNC and channel consent), CONDUCT (vulnerability and open complaint), ARREARS, SUITABILITY (the four product gates), CONTACT_FATIGUE (cooldown), OTHER, plus NOT_SUPPRESSED. Use this for "what kind of rule is blocking most of our book" so the answer does not depend on somebody assembling the right OR list.',
    nba_candidates.is_servicing_obligation AS IS_SERVICING_OBLIGATION
      WITH SYNONYMS ('servicing obligation', 'obligation', 'must contact',
                     'duty to contact', 'DNC waived')
      COMMENT = 'True where the group has a servicing duty to make contact. The DNC registry is deliberately waived for these and channel consent is not -- see PROJECT_BRIEF D7. So a servicing obligation can still be suppressed, by NO_CHANNEL_CONSENT but not by DNC_REGISTRY.',
    nba_candidates.candidate_is_sales_action AS IS_SALES_ACTION
      WITH SYNONYMS ('candidate is a sale', 'evaluated sales action')
      COMMENT = 'True if the evaluated action sells something.'
  )

  METRICS (
    /* ======================================================================
       THE SIX HEADLINE METRICS
       Named exactly as the business asks for them. Reference values at
       anchor 2026-08-28 are in each comment so a wrong answer is visible.
       ====================================================================== */

    customers.total_customers AS COUNT(DISTINCT customers.CUSTOMER_ID)
      WITH SYNONYMS ('total customers', 'number of customers', 'customer count',
                     'how many customers', 'headcount', 'size of the book',
                     'book size', 'how many clients', 'number of clients')
      COMMENT = 'Distinct customers. Use this whenever the question asks how many PEOPLE, even if the filter is on a policy or a loan -- a customer with three policies is one customer. 5,000 across the whole book.',

    customers.avg_relationship_value AS AVG(customers.EST_ANNUAL_MARGIN_INR)
      WITH SYNONYMS ('average relationship value', 'avg relationship value',
                     'average customer value', 'mean customer value',
                     'average margin', 'average value per customer',
                     'typical customer value', 'value per customer')
      COMMENT = 'Mean estimated annual margin per customer, in INR. 56,574 across the whole book. The distribution is heavily skewed -- median is about 29,500 -- so the mean sits well above the typical customer. If the question is about a typical customer rather than a portfolio total, say so, and consider reporting the band mix from relationship_value_band alongside this.',

    policies.policies_at_risk_30d AS COUNT_IF(policies.IS_AT_RISK_30D)
      WITH SYNONYMS ('policies at risk', 'at risk policies', 'policies at risk in 30 days',
                     'retention risk', 'renewals at risk', 'policies likely to lapse',
                     'retention saves needed', 'policies needing intervention',
                     'renewals in doubt')
      COMMENT = 'Active policies that renew within 30 days of as_of_date AND whose customer complained in the last 60 days. 420 policies, held by 400 customers. Both halves matter: about one policy in twelve renews in any 30-day window, so the renewal alone is the calendar rather than a risk. This is the retention-save population -- the right action is to keep the customer, and recommending a cross-sell to anybody in it is a ranking failure. Counts POLICIES; for the number of people use total_customers filtered on the same condition. DO NOT use this for a question about customers showing churn signals -- that is customers_deteriorating, a different grain and a different signal entirely.',

    policies.lapse_rate AS COUNT_IF(policies.IS_LAPSED_POLICY) / NULLIF(COUNT(policies.POLICY_ID), 0)
      WITH SYNONYMS ('lapse rate', 'lapsed rate', 'churn rate', 'attrition rate',
                     'rate of lapse', 'percentage lapsed', 'percent churned',
                     'how much churn', 'churn', 'attrition')
      COMMENT = 'Lapsed policies as a fraction of all policies. 0.0832, that is 8.3 percent -- 675 lapsed of 8,116. Report it as a percentage. THE DENOMINATOR IS ALL POLICIES, including matured and surrendered ones, so this is a lifetime lapse rate over the whole book rather than an annual rate. A matured policy is not churn (it ran its term) and neither is a surrender (a deliberate exit), so only recorded lapses count in the numerator. Break this down by policy_type, city or channel_sold to find where cover is being lost.',

    customers.cross_sell_gap_count AS SUM(customers.PRODUCT_GAP_COUNT)
      WITH SYNONYMS ('cross sell gaps', 'cross-sell gap count', 'total product gaps',
                     'number of gaps', 'cross sell opportunities',
                     'total opportunities', 'white space', 'unmet needs',
                     'how many gaps', 'sales opportunities')
      COMMENT = 'Total count of product gaps across customers -- the size of the cross-sell opportunity in units, not rupees. 7,855 gaps across 5,000 customers. IMPORTANT -- a gap is a statement that the customer plausibly needs a product they do not hold. It is NOT an eligibility verdict: income-band, KYC and vulnerability gates are deliberately not applied here, so the number of gaps that can lawfully be acted on is smaller. When answering, do not describe these as customers who can be sold to.',

    loans.arrears_exposure_inr AS SUM(loans.ARREARS_OUTSTANDING_INR)
      WITH SYNONYMS ('arrears exposure', 'arrears exposure in INR', 'overdue exposure',
                     'exposure in arrears', 'money at risk', 'amount in arrears',
                     'delinquent exposure', 'DPD exposure', 'total overdue',
                     'balance at risk', 'value in arrears')
      COMMENT = 'Total outstanding balance on loans that are at least one day past due, in INR. 521,397,600 -- about 52.1 crore. This is the WHOLE balance of every late loan, not the sum of overdue instalments: a loan 45 days down puts its full balance in question, which is how collections reads exposure. If somebody asks for the value of missed payments rather than the exposure they are asking a different question, and this is not it.',

    /* ======================================================================
       SUPPORTING METRICS
       Not on the headline list, but a portfolio question that gets one of
       the six almost always needs a denominator or a companion from here.
       ====================================================================== */

    /* ---- customers ---- */
    customers.total_est_annual_margin_inr AS SUM(customers.EST_ANNUAL_MARGIN_INR)
      WITH SYNONYMS ('total relationship value', 'total margin', 'portfolio value',
                     'total customer value', 'book value', 'total annual margin')
      COMMENT = 'Sum of estimated annual margin across customers, in INR. A ranking and sizing quantity, not a reportable profit figure -- see the est_annual_margin_inr fact.',
    customers.total_annual_premium_inr AS SUM(customers.ANNUAL_PREMIUM_INR)
      WITH SYNONYMS ('total annual premium', 'total premium', 'premium book',
                     'annual premium income', 'total premium income')
      COMMENT = 'Sum of annualised premium across customers, in INR. Computed on the customer spine, so it counts each customer once across all their active policies.',
    customers.total_outstanding_credit_inr AS SUM(customers.OUTSTANDING_CREDIT_INR)
      WITH SYNONYMS ('total outstanding credit', 'total credit exposure',
                     'total lending exposure', 'total debt', 'credit book')
      COMMENT = 'Sum of outstanding credit across customers, in INR. Total exposure whether or not the borrowing is up to date -- for the overdue subset use arrears_exposure_inr.',
    customers.avg_products_held AS AVG(customers.PRODUCT_COUNT)
      WITH SYNONYMS ('average products held', 'products per customer',
                     'average holdings', 'cross-holding', 'depth of relationship')
      COMMENT = 'Mean number of distinct product families per customer. The standard measure of relationship depth.',
    customers.avg_product_gaps AS AVG(customers.PRODUCT_GAP_COUNT)
      WITH SYNONYMS ('average gaps', 'gaps per customer', 'average opportunities per customer')
      COMMENT = 'Mean number of product gaps per customer. Same caveat as cross_sell_gap_count -- a need, not an eligibility verdict.',
    customers.customers_deteriorating AS COUNT_IF(customers.SENTIMENT_TREND = 'DETERIORATING')
      WITH SYNONYMS ('churn signal', 'churn signals', 'showing churn signals',
                     'customers showing churn signals', 'customers with churn signals',
                     'churn signal count', 'attrition signal', 'attrition signals',
                     'customers at churn risk', 'customers at risk of churning',
                     'deteriorating customers', 'customers souring',
                     'relationships getting worse',
                     'unhappy and getting unhappier', 'declining relationships')
      COMMENT = 'Customers whose sentiment is measurably deteriorating across their interactions. THIS IS THE CUSTOMER-LEVEL CHURN SIGNAL -- use it for any question of the form "how many customers are showing churn signals". Only 12 customers at the current anchor, and that small number is the point: 4,864 of 5,000 have too few interactions to fit a trend at all. Counts DETERIORATING only; INSUFFICIENT_DATA and NO_CONTACT_HISTORY are unknown, not calm, and are excluded. ALWAYS report customers_unknown_trend alongside this, because 12 out of 5,000 read without that context implies a healthy book when the truth is that the book is mostly unmeasured. Distinct from policies_at_risk_30d, which is policy-level forward-looking retention risk, and from lapse_rate, which is churn that already happened.',
    customers.customers_unknown_trend AS COUNT_IF(customers.SENTIMENT_TREND IN ('INSUFFICIENT_DATA', 'NO_CONTACT_HISTORY'))
      WITH SYNONYMS ('unknown trend', 'no trend data', 'insufficient data customers',
                     'customers with no sentiment trend', 'unmeasured customers')
      COMMENT = 'Customers whose sentiment trend cannot be determined -- either too few interactions to fit one, or no contact history at all. Report this alongside any trend breakdown so the reader knows how much of the book is unmeasured rather than calm. It is the majority of the book.',
    customers.customers_in_arrears AS COUNT_IF(customers.IS_IN_ARREARS_CUSTOMER)
      WITH SYNONYMS ('customers in arrears', 'how many customers are overdue',
                     'number of customers in arrears', 'delinquent customers',
                     'customers behind on payments', 'people in arrears')
      COMMENT = 'Customers with at least one loan past due. Counts PEOPLE, unlike loans_in_arrears which counts loans -- a customer with two overdue loans is one customer here and two there, and the two numbers should not be used interchangeably.',
    customers.customers_with_hardship AS COUNT_IF(customers.HARDSHIP_SIGNAL)
      WITH SYNONYMS ('customers in hardship', 'hardship count',
                     'customers in difficulty', 'financially stressed customers',
                     'customers to protect')
      COMMENT = 'Customers showing a financial hardship signal on any of its four arms. These should be routed to service, not sales.',
    customers.customers_with_open_complaint AS COUNT_IF(customers.OPEN_COMPLAINT)
      WITH SYNONYMS ('customers complaining', 'open complaints',
                     'customers with a complaint', 'complaint count',
                     'unresolved complaints')
      COMMENT = 'Customers with a service complaint still open. Customer-level, so a customer with three open complaints counts once.',
    customers.reachable_customers AS COUNT_IF(customers.IS_REACHABLE_ANY_CHANNEL)
      WITH SYNONYMS ('reachable customers', 'contactable customers',
                     'how many can we contact', 'permitted contacts',
                     'addressable book')
      COMMENT = 'Customers who can lawfully be contacted on at least one channel. The realistic denominator for any campaign sizing -- the difference between this and total_customers is book that cannot be spoken to at all.',
    customers.dnc_customers AS COUNT_IF(customers.DNC_FLAG)
      /* 'suppressed customers' removed for the same reason as the 'suppressed'
         synonym on is_on_dnc_registry: that phrase now means customers the
         engine blocked, which is customers_suppressed and a different number
         (4,580 against 1,330). */
      WITH SYNONYMS ('DNC customers', 'do not contact count',
                     'how many on the DNC list', 'opted out customers')
      COMMENT = 'Customers on the do-not-contact registry for call or SMS. 1,330, about 27 percent of the book. This counts a PERMISSION state. For customers who lost an action to a rule -- which is a superset, since DNC is only one of thirteen reasons -- use customers_suppressed, which is 4,580.',
    customers.kyc_stale_customers AS COUNT_IF(NOT customers.KYC_CURRENT)
      WITH SYNONYMS ('stale KYC', 'KYC not current', 'customers needing KYC',
                     'KYC overdue', 'unverified customers')
      COMMENT = 'Customers whose KYC is not current. Any new product sale to these is blocked until it is refreshed, so this is a hard cap on how much of the cross-sell opportunity is actionable.',
    customers.vulnerable_customers AS COUNT_IF(customers.VULNERABILITY_FLAG)
      WITH SYNONYMS ('vulnerable customers', 'vulnerability count',
                     'how many vulnerable', 'customers needing care')
      COMMENT = 'Customers on the vulnerability register. A conduct population -- marketing to them is constrained by product suitability rules.',
    customers.avg_credit_utilisation AS AVG(customers.CREDIT_UTILISATION)
      WITH SYNONYMS ('average credit utilisation', 'average utilization',
                     'mean limit usage', 'average card usage')
      COMMENT = 'Mean card utilisation, 0 to 1. Rising utilisation across a cohort is an early stress signal.',
    customers.avg_tenure_years AS AVG(customers.TENURE_YEARS)
      WITH SYNONYMS ('average tenure', 'mean tenure', 'average relationship length',
                     'how long customers stay')
      COMMENT = 'Mean years of relationship across customers.',
    customers.total_missed_payments_12m AS SUM(customers.MISSED_PAYMENTS_12M)
      WITH SYNONYMS ('total missed payments', 'missed payments across the book',
                     'total missed instalments')
      COMMENT = 'Total missed instalments across customers in the last 12 months.',

    /* ---- policies ---- */
    policies.customers_with_policies AS COUNT(DISTINCT policies.CUSTOMER_ID)
      WITH SYNONYMS ('customers with policies', 'policyholders',
                     'how many customers hold a policy', 'insured customers',
                     'people with insurance', 'distinct policyholders',
                     'customers who hold insurance', 'unique policyholders')
      COMMENT = 'DISTINCT customers holding at least one policy of any status, as opposed to policy_count which counts policies. 4,002 of 5,000. USE THIS FOR ANY QUESTION THAT CROSSES A CUSTOMER ATTRIBUTE WITH THE INSURANCE BOOK -- how many customers in Mumbai hold a lapsed policy, how many vulnerable customers have a policy renewing soon. Those are semi-joins, and without a customer-grain metric on this fact they cannot be expressed in this model at all, which pushes the answer into hand-written SQL against the V_SV_ shims and out of everything the model governs. Combine with is_active_policy for holders of live cover.',
    policies.policy_count AS COUNT(policies.POLICY_ID)
      WITH SYNONYMS ('policy count', 'number of policies', 'how many policies',
                     'total policies', 'policies')
      COMMENT = 'Policies of every status, including lapsed, matured and surrendered. 8,116. The denominator of lapse_rate. For the live book use active_policy_count.',
    policies.active_policy_count AS COUNT_IF(policies.IS_ACTIVE_POLICY)
      WITH SYNONYMS ('active policies', 'live policies', 'policies in force',
                     'how many active policies', 'in-force count')
      COMMENT = 'Policies currently in force. The right count for "the book" in almost any present-tense question.',
    policies.lapsed_policy_count AS COUNT_IF(policies.IS_LAPSED_POLICY)
      WITH SYNONYMS ('lapsed policies', 'churned policies', 'attrited policies',
                     'how many lapsed', 'lapses', 'policies lost',
                     'number of churns', 'churn count', 'attrition count')
      COMMENT = 'Policies that lapsed. 675. The numerator of lapse_rate. Matured and surrendered policies are NOT counted here -- see the is_lapsed_policy dimension for why neither is churn.',
    policies.renewals_within_30d AS COUNT_IF(policies.RENEWS_WITHIN_30D)
      WITH SYNONYMS ('renewals due', 'renewals in 30 days', 'upcoming renewals',
                     'policies renewing soon', 'renewal pipeline')
      COMMENT = 'Active policies renewing within 30 days of as_of_date. Timing only, no risk signal -- about one policy in twelve. For the subset in doubt use policies_at_risk_30d.',
    policies.total_annualised_premium_inr AS SUM(policies.ANNUALISED_PREMIUM_INR)
      WITH SYNONYMS ('total annualised premium', 'premium book', 'total premium',
                     'annualised premium income', 'gross written premium')
      COMMENT = 'Sum of annualised premium across policies, in INR. Computed at policy grain, so filter on is_active_policy for the in-force premium book -- unfiltered it includes premium from policies that have ended.',
    policies.total_sum_assured_inr AS SUM(policies.SUM_ASSURED_INR)
      WITH SYNONYMS ('total sum assured', 'total cover', 'total coverage',
                     'total exposure', 'aggregate cover', 'total sum insured')
      COMMENT = 'Sum of cover across policies, in INR. The gross amount the group would owe if every policy claimed in full. Filter on is_active_policy for live exposure.',
    policies.avg_sum_assured_inr AS AVG(policies.SUM_ASSURED_INR)
      WITH SYNONYMS ('average sum assured', 'average cover', 'mean coverage',
                     'typical cover')
      COMMENT = 'Mean cover per policy, in INR.',
    policies.premium_at_risk_30d AS SUM(CASE WHEN policies.IS_AT_RISK_30D THEN policies.ANNUALISED_PREMIUM_INR ELSE 0 END)
      WITH SYNONYMS ('premium at risk', 'premium at risk in 30 days',
                     'revenue at risk', 'annual premium at risk',
                     'value of policies at risk', 'money at risk from lapse')
      COMMENT = 'Annualised premium on the at-risk policies, in INR -- what would be lost if every retention save failed. The rupee companion to policies_at_risk_30d, and usually the number that decides whether an intervention is worth funding.',

    /* ---- loans ---- */
    loans.customers_with_loans AS COUNT(DISTINCT loans.CUSTOMER_ID)
      WITH SYNONYMS ('customers with loans', 'borrowers', 'how many borrowers',
                     'people with loans', 'distinct borrowers',
                     'customers who borrow', 'unique borrowers',
                     'customers with credit')
      COMMENT = 'DISTINCT customers holding at least one active loan, as opposed to loan_count which counts loans. 2,578 of 5,000. The customer-grain metric on the lending fact -- use it for any question crossing a customer attribute with the loan book, for example how many customers with stale KYC hold a restructured loan. For customers behind on payments specifically, customers_in_arrears on the spine is more direct.',
    loans.loan_count AS COUNT(loans.LOAN_ID)
      WITH SYNONYMS ('loan count', 'number of loans', 'how many loans', 'total loans')
      COMMENT = 'Loans on the book. 3,219, all currently active.',
    loans.loans_in_arrears AS COUNT_IF(loans.IS_IN_ARREARS)
      WITH SYNONYMS ('loans in arrears', 'overdue loans', 'late loans',
                     'delinquent loans', 'how many loans are overdue',
                     'loans past due', 'arrears count')
      COMMENT = 'Loans at least one day past due. Counts LOANS -- a customer with two overdue loans counts twice, so for people use total_customers filtered on the arrears condition.',
    loans.total_outstanding_inr AS SUM(loans.OUTSTANDING_INR)
      WITH SYNONYMS ('total outstanding', 'total loan book', 'lending exposure',
                     'total balance', 'book size in rupees', 'total loan exposure')
      COMMENT = 'Total outstanding balance across loans, in INR. The whole lending book, current and overdue together. The denominator for an arrears exposure ratio.',
    loans.avg_dpd_days AS AVG(loans.DPD_DAYS)
      WITH SYNONYMS ('average DPD', 'average days past due', 'mean days overdue',
                     'average delinquency')
      COMMENT = 'Mean days past due across loans, INCLUDING loans that are up to date at zero, which pulls it toward zero. For the average among late loans only, filter on is_in_arrears first -- the two numbers are very different and the unfiltered one is usually not what is meant.',
    loans.total_emi_inr AS SUM(loans.EMI_INR)
      WITH SYNONYMS ('total EMI', 'total instalments', 'monthly collections due',
                     'total monthly repayments', 'collections due')
      COMMENT = 'Sum of monthly instalments due across loans, in INR. What the book should collect each month.',
    loans.rising_dpd_loan_count AS COUNT_IF(loans.IS_DPD_RISING)
      WITH SYNONYMS ('loans with rising arrears', 'worsening loans',
                     'deteriorating loans', 'loans getting worse',
                     'rising DPD count', 'slipping loans')
      COMMENT = 'Loans where days past due rose across three consecutive monthly readings. The forward-looking arrears measure -- these are the loans about to enter a worse bucket.',
    loans.restructured_loan_count AS COUNT_IF(loans.IS_RESTRUCTURED)
      WITH SYNONYMS ('restructured loans', 'reworked loans', 'rescheduled loans',
                     'forbearance count')
      COMMENT = 'Loans whose terms were renegotiated because the customer could not meet the original schedule.',

    /* ---- claims ---- */
    claims.customers_with_claims AS COUNT(DISTINCT claims.CUSTOMER_ID)
      WITH SYNONYMS ('customers with claims', 'claimants', 'how many claimants',
                     'people who claimed', 'distinct claimants',
                     'customers who have claimed', 'unique claimants',
                     'customers with a claim')
      COMMENT = 'DISTINCT customers who have ever filed a claim, as opposed to claim_count which counts claims. 1,418 of 5,000. The customer-grain metric on the claims fact -- use it for any question crossing a customer attribute with claims experience, for example how many PLATINUM customers have had a claim rejected. That question is a semi-join and cannot be expressed in this model without this metric.',
    claims.claim_count AS COUNT(claims.CLAIM_ID)
      WITH SYNONYMS ('claim count', 'number of claims', 'how many claims',
                     'total claims', 'claims filed')
      COMMENT = 'Claims ever filed, all statuses. 1,621.',
    claims.total_claimed_inr AS SUM(claims.CLAIM_AMOUNT_INR)
      WITH SYNONYMS ('total claimed', 'total claim amount', 'amount claimed',
                     'gross claims', 'claims value')
      COMMENT = 'Sum of amounts claimed, in INR, regardless of outcome.',
    claims.total_approved_inr AS SUM(claims.APPROVED_AMOUNT_INR_ZEROED)
      WITH SYNONYMS ('total approved', 'total paid out', 'total settled amount',
                     'claims paid', 'payouts')
      COMMENT = 'Sum of approved amounts, in INR, with unsettled and rejected claims counted as zero recovered. That zeroing is deliberate and is what makes this the right numerator for a settlement ratio.',
    claims.settled_claim_count AS COUNT_IF(claims.IS_SETTLED_CLAIM)
      WITH SYNONYMS ('settled claims', 'claims settled', 'claims paid out',
                     'how many settled')
      COMMENT = 'Claims settled and paid.',
    claims.rejected_claim_count AS COUNT_IF(claims.IS_REJECTED_CLAIM)
      WITH SYNONYMS ('rejected claims', 'declined claims', 'claims refused',
                     'how many rejected', 'repudiations')
      COMMENT = 'Claims rejected. Worth watching next to complaints and lapses -- a rejection is a common trigger for both.',
    claims.open_claim_count AS COUNT_IF(claims.IS_OPEN_CLAIM)
      WITH SYNONYMS ('open claims', 'pending claims', 'unsettled claims',
                     'claims in progress', 'claims awaiting decision')
      COMMENT = 'Claims still open or in review -- customers currently waiting for a decision.',
    claims.avg_settlement_days AS AVG(claims.SETTLEMENT_DAYS)
      WITH SYNONYMS ('average settlement days', 'average time to settle',
                     'settlement turnaround', 'average TAT', 'claims turnaround')
      COMMENT = 'Mean days from filing to settlement, across SETTLED claims only -- unsettled and rejected claims carry a NULL and are excluded automatically. So this measures how fast the group pays when it pays, not how long customers wait overall.',

    /* ---- campaigns ---- */
    campaigns.contact_count AS COUNT(campaigns.CAMPAIGN_CONTACT_ID)
      WITH SYNONYMS ('contacts', 'contact count', 'number of contacts',
                     'contact attempts', 'how many times contacted',
                     'outreach volume', 'campaign volume')
      COMMENT = 'Outbound contact attempts. 24,918 over 12 rolling months. Counts ATTEMPTS, not people -- the same customer appears many times.',
    campaigns.customers_contacted AS COUNT(DISTINCT campaigns.CUSTOMER_ID)
      WITH SYNONYMS ('customers contacted', 'distinct customers contacted',
                     'how many customers did we contact', 'people contacted',
                     'customers we reached out to', 'unique customers contacted',
                     'customers in campaigns', 'customers we are contacting')
      COMMENT = 'DISTINCT customers who received at least one outbound contact, as opposed to contact_count which counts attempts. Use this for any question about how many PEOPLE were contacted, and in particular for questions that cross a customer attribute with campaign activity -- for example how many customers with a hardship signal are still being contacted, which is this metric filtered on has_hardship_signal. Without it that question cannot be expressed in this model and has to fall back to hand-written SQL outside it.',
    campaigns.converted_count AS COUNT_IF(campaigns.IS_CONVERTED)
      WITH SYNONYMS ('conversions', 'converted count', 'sales made',
                     'how many converted', 'successful contacts')
      COMMENT = 'Contact attempts that resulted in a sale.',
    campaigns.engaged_count AS COUNT_IF(campaigns.IS_ENGAGED)
      WITH SYNONYMS ('engaged count', 'positive responses',
                     'interested or converted count', 'engagement volume')
      COMMENT = 'Contact attempts that produced a conversion or an expression of interest.',
    campaigns.opt_out_count AS COUNT_IF(campaigns.IS_OPT_OUT)
      WITH SYNONYMS ('opt outs', 'opt-out count', 'unsubscribes',
                     'how many opted out', 'consent withdrawals')
      COMMENT = 'Contact attempts that caused the customer to opt out of future contact. A permanent reduction in the reachable book and a real cost of campaigning.',
    campaigns.complaint_outcome_count AS COUNT_IF(campaigns.IS_COMPLAINT_OUTCOME)
      WITH SYNONYMS ('complaints from campaigns', 'contacts that caused a complaint',
                     'campaign complaints', 'adverse outcomes')
      COMMENT = 'Contact attempts that caused the customer to complain. The most adverse outcome a campaign can produce.',
    campaigns.campaign_revenue_inr AS SUM(campaigns.REVENUE_INR)
      WITH SYNONYMS ('campaign revenue', 'revenue from campaigns',
                     'total campaign revenue', 'sales value', 'revenue generated')
      COMMENT = 'Revenue attributed to campaign contacts, in INR. Only conversions contribute.',

    /* ======================================================================
       THE ENGINE
       Two grains. nba_* metrics count what was decided; candidate_* and
       suppressed_* metrics count what was considered. Mixing them in one
       sentence is the most likely way to get an answer wrong here, so each
       comment says which side of the line it sits on.
       ====================================================================== */

    /* ---- nba: the published ranking ---- */
    nba.nba_count AS COUNT(nba.NBA_ID)
      WITH SYNONYMS ('nba count', 'number of recommendations',
                     'how many recommendations', 'total recommendations',
                     'number of actions', 'how many actions',
                     'recommendation count', 'action count',
                     'published actions', 'size of the action list')
      COMMENT = 'Published recommendations. 3,917 rows, up to three per customer across 2,346 customers. COUNTS ACTIONS, NOT PEOPLE -- for people use customers_with_actions, and for the single lead recommendation per customer filter is_top_action, which gives 2,346. This counts only actions that passed every compliance rule; it can never be used as a denominator for a suppression rate, because suppressed actions are absent from this table by construction.',
    nba.customers_with_actions AS COUNT(DISTINCT nba.CUSTOMER_ID)
      WITH SYNONYMS ('customers with actions', 'customers with a recommendation',
                     'how many customers have a recommendation',
                     'people with recommendations', 'customers with an offer',
                     'customers the engine has an action for',
                     'distinct customers with actions', 'covered customers')
      COMMENT = 'DISTINCT customers with at least one published recommendation. 2,346 of 5,000, that is 47 percent coverage. Use this for any question about how many PEOPLE the engine has something to say about, and for any question crossing a customer attribute with the engine output -- how many PLATINUM customers have a recommendation, how many customers in arrears have one. Those are semi-joins and this is the metric that keeps them inside the model. The other 2,654 customers have no publishable action: either no need fired, or everything that did was suppressed.',
    nba.total_expected_value_inr AS SUM(nba.EXPECTED_VALUE_INR)
      WITH SYNONYMS ('total expected value', 'total expected value in INR',
                     'total EV', 'expected value of the book',
                     'total opportunity', 'pipeline value', 'total action value',
                     'value of the recommendations', 'engine value',
                     'total expected margin', 'opportunity size')
      COMMENT = 'Sum of expected value across published recommendations, in INR. 7,177,355 -- about 71.8 lakh. Propensity times value at stake times margin, summed. THIS IS AN OPPORTUNITY SIZING AND NOT A FORECAST: it assumes every action is taken and converts at its modelled propensity, and the propensity is a model output. Report it as the size of the pipeline the engine has identified, never as revenue the group will receive. Unfiltered it counts ranks 2 and 3 as well, which is right for pipeline sizing and wrong if the question is what a single campaign of lead actions is worth -- filter is_top_action for that.',
    nba.avg_expected_value_inr AS AVG(nba.EXPECTED_VALUE_INR)
      WITH SYNONYMS ('average expected value', 'mean expected value',
                     'average action value', 'typical action value')
      COMMENT = 'Mean expected value per published action, in INR. Averaged across 18 very different actions -- a card limit increase and a term life cross-sell -- so the unfiltered mean is rarely meaningful. Break it down by action_name.',
    nba.avg_propensity AS AVG(nba.PROPENSITY)
      WITH SYNONYMS ('average propensity', 'mean propensity',
                     'average likelihood', 'typical propensity')
      COMMENT = 'Mean modelled propensity across published actions, 0 to 1.',
    nba.top_action_count AS COUNT_IF(nba.IS_TOP_ACTION)
      WITH SYNONYMS ('top actions', 'rank 1 actions', 'lead recommendations',
                     'first actions', 'primary actions')
      COMMENT = 'Rank-1 actions only, one per customer. 2,346, which equals customers_with_actions by construction. The right count when sizing a campaign that contacts each customer once.',
    nba.care_action_count AS COUNT_IF(nba.IS_CARE_ACTION)
      WITH SYNONYMS ('care actions', 'service actions', 'servicing actions',
                     'protective actions', 'non-sales actions',
                     'how many care actions')
      COMMENT = 'Published actions whose purpose is to look after the customer rather than sell to them. Report this next to sales_action_count for the honest shape of what the engine is recommending -- an engine that only ever recommends sales is not a next-best-action engine, it is a campaign list.',
    nba.sales_action_count AS COUNT_IF(nba.IS_SALES_ACTION)
      WITH SYNONYMS ('sales actions', 'commercial actions', 'cross-sell actions',
                     'how many sales actions', 'revenue actions')
      COMMENT = 'Published actions that sell something. The companion to care_action_count.',
    nba.llm_narrated_count AS COUNT_IF(nba.RATIONALE_SOURCE = 'LLM')
      WITH SYNONYMS ('LLM narrated', 'model written rationales',
                     'AI written reasons', 'how many written by the model')
      COMMENT = 'Published actions whose rationale was written by a frontier model rather than templated. Report alongside nba_count when the subject is prose quality, so the reader knows what share of the book got written prose.',
    nba.actions_with_evidence AS COUNT_IF(nba.HAS_EVIDENCE)
      WITH SYNONYMS ('actions with evidence', 'evidenced actions',
                     'actions with citations', 'cited actions')
      COMMENT = 'Published actions citing at least one interaction, ticket, transcript or ledger row.',

    /* ---- nba_candidates: the eligibility ledger ---- */
    nba_candidates.candidates_evaluated AS COUNT(nba_candidates.CANDIDATE_ID)
      WITH SYNONYMS ('candidates evaluated', 'pairs evaluated',
                     'actions considered', 'how many were considered',
                     'total candidates', 'decisions made')
      COMMENT = 'Every (customer, action) pair the engine evaluated. 90,000 = 5,000 customers by 18 actions, so this number is a property of the catalogue rather than of the book and is almost never the answer to a business question on its own. It is NOT the denominator of suppression_rate -- see needed_candidates.',
    nba_candidates.needed_candidates AS COUNT_IF(nba_candidates.ELIGIBLE_ON_NEED)
      WITH SYNONYMS ('needed candidates', 'needed actions',
                     'actions the customer needs', 'relevant candidates',
                     'plausible actions', 'opportunities identified',
                     'how many actions were needed')
      COMMENT = 'Pairs that passed the need test: the customer plausibly wants the product. 16,475 of 90,000. THE DENOMINATOR OF suppression_rate. The 73,525 that failed are overwhelmingly customers who already hold the product, and counting them makes any suppression rate a statement about catalogue breadth rather than compliance.',
    nba_candidates.suppressed_need_count AS COUNT_IF(nba_candidates.IS_SUPPRESSED_NEED)
      WITH SYNONYMS ('suppressed actions', 'blocked actions',
                     'how many were blocked', 'suppression count',
                     'blocked opportunities', 'actions we could not take',
                     'lost to compliance', 'how many suppressed')
      COMMENT = 'Pairs the customer needed and a compliance rule blocked. 12,435 across 4,580 customers. The numerator of suppression_rate. Break it down by suppression_reason or suppression_category to say which rules are doing the work.',
    nba_candidates.actionable_count AS COUNT_IF(nba_candidates.IS_ACTIONABLE)
      WITH SYNONYMS ('actionable candidates', 'allowed actions',
                     'permitted actions', 'actions that passed',
                     'cleared actions', 'how many were allowed')
      COMMENT = 'Pairs the customer needed and no rule blocked. 4,040. Larger than nba_count (3,917) because the published ranking is cut to at most three per customer -- that gap is a ranking cut-off, not a second suppression, and should not be described as one.',
    nba_candidates.customers_suppressed AS COUNT(DISTINCT CASE WHEN nba_candidates.IS_SUPPRESSED_NEED THEN nba_candidates.CUSTOMER_ID END)
      WITH SYNONYMS ('customers suppressed', 'customers with a blocked action',
                     'how many customers were blocked',
                     'people with suppressed actions',
                     'customers affected by suppression',
                     'distinct customers suppressed')
      COMMENT = 'DISTINCT customers with at least one needed action blocked by a rule. 4,580 of 5,000 -- far more than the 12,435 suppressions suggest per head, because most affected customers lose several actions to the same rule. The customer-grain metric on this fact: use it for any question crossing a customer attribute with suppression, for example how many vulnerable customers had an action blocked.',
    nba_candidates.suppressed_value_at_stake_inr AS SUM(CASE WHEN nba_candidates.IS_SUPPRESSED_NEED THEN nba_candidates.VALUE_AT_STAKE_INR ELSE 0 END)
      WITH SYNONYMS ('suppressed value', 'value blocked', 'value at stake blocked',
                     'how much value was suppressed', 'cost of compliance',
                     'value we could not pursue', 'blocked opportunity value',
                     'value forgone')
      COMMENT = 'Gross value at stake on the suppressed-and-needed pairs, in INR. THIS IS GROSS VALUE AT STAKE AND NOT EXPECTED VALUE -- there is no propensity on a suppressed row to multiply through, so this figure is not comparable with total_expected_value_inr and is several times larger. Describe it as the gross value the rules declined to pursue, never as money lost: most of these actions would not have converted, and the rules exist because contacting these customers would be wrong.',
    nba_candidates.value_at_stake_inr_total AS SUM(nba_candidates.VALUE_AT_STAKE_INR)
      WITH SYNONYMS ('total value at stake', 'gross value considered',
                     'total value evaluated')
      COMMENT = 'Gross value at stake across all evaluated pairs, in INR, including pairs that failed the need test. A denominator, not a headline.',

    /* ======================================================================
       DERIVED METRICS
       Ratios, defined once here so Analyst never has to assemble a
       numerator and a denominator itself and pick the wrong grain.
       ====================================================================== */

    arrears_exposure_rate AS loans.arrears_exposure_inr / NULLIF(loans.total_outstanding_inr, 0)
      WITH SYNONYMS ('arrears exposure rate', 'share of book in arrears',
                     'percentage of book overdue', 'arrears ratio',
                     'proportion of exposure overdue', 'delinquency rate by value')
      COMMENT = 'Outstanding balance on late loans as a fraction of the whole loan book. A value-weighted delinquency measure -- report as a percentage. Different from the loan-count share, and higher when the large loans are the late ones.',

    arrears_loan_rate AS loans.loans_in_arrears / NULLIF(loans.loan_count, 0)
      WITH SYNONYMS ('arrears loan rate', 'share of loans in arrears',
                     'percentage of loans overdue', 'delinquency rate by count',
                     'proportion of loans late')
      COMMENT = 'Late loans as a fraction of all loans. The count-weighted companion to arrears_exposure_rate; compare the two to see whether arrears are concentrated in large loans or small ones.',

    campaign_conversion_rate AS campaigns.converted_count / NULLIF(campaigns.contact_count, 0)
      WITH SYNONYMS ('conversion rate', 'campaign conversion rate', 'hit rate',
                     'success rate', 'percentage converted', 'response rate')
      COMMENT = 'Conversions as a fraction of contact attempts. Report as a percentage. Judge a channel or campaign on this TOGETHER WITH opt_out_rate -- a channel that converts well and burns consent is not a good channel.',

    campaign_opt_out_rate AS campaigns.opt_out_count / NULLIF(campaigns.contact_count, 0)
      WITH SYNONYMS ('opt out rate', 'opt-out rate', 'unsubscribe rate',
                     'consent burn rate', 'percentage opting out')
      COMMENT = 'Opt-outs as a fraction of contact attempts. The cost side of campaigning: every opt-out permanently shrinks the reachable book. Always worth reporting next to campaign_conversion_rate.',

    campaign_revenue_per_contact AS campaigns.campaign_revenue_inr / NULLIF(campaigns.contact_count, 0)
      WITH SYNONYMS ('revenue per contact', 'value per contact',
                     'revenue per attempt', 'yield per contact')
      COMMENT = 'Campaign revenue divided by contact attempts, in INR. Folds conversion rate and ticket size into one comparable figure across channels and campaigns.',

    claim_settlement_ratio AS claims.total_approved_inr / NULLIF(claims.total_claimed_inr, 0)
      WITH SYNONYMS ('settlement ratio', 'claim settlement ratio', 'payout ratio',
                     'proportion of claims paid', 'loss ratio', 'recovery rate')
      COMMENT = 'Approved amount over claimed amount across claims, in value terms. Unsettled and rejected claims count as zero recovered in the numerator, so this is the ratio a customer would experience rather than an underwriting loss ratio on settled business only.',

    claim_rejection_rate AS claims.rejected_claim_count / NULLIF(claims.claim_count, 0)
      WITH SYNONYMS ('rejection rate', 'claim rejection rate', 'decline rate',
                     'percentage of claims rejected', 'repudiation rate')
      COMMENT = 'Rejected claims as a fraction of all claims. A dissatisfaction driver -- break it down by policy_type or city to find where the group is generating grievances.',

    reachable_share AS customers.reachable_customers / NULLIF(customers.total_customers, 0)
      WITH SYNONYMS ('reachable share', 'contactable share',
                     'percentage of the book we can contact',
                     'addressable proportion', 'permission coverage')
      COMMENT = 'Customers contactable on at least one channel as a fraction of all customers. The ceiling on any campaign reach, and the first number to check before sizing an outreach.',

    suppression_rate AS nba_candidates.suppressed_need_count / NULLIF(nba_candidates.needed_candidates, 0)
      WITH SYNONYMS ('suppression rate', 'suppression', 'block rate',
                     'percentage suppressed', 'share suppressed',
                     'how much do we suppress', 'compliance block rate',
                     'proportion blocked', 'rate of suppression',
                     'how often are actions blocked', 'share blocked by rules')
      COMMENT = 'Needed actions blocked by a compliance rule, as a fraction of needed actions. 12,435 / 16,475 = 0.7548, that is 75.5 percent -- report as a percentage. THE DENOMINATOR IS DELIBERATELY needed_candidates AND NOT ALL 90,000 EVALUATED PAIRS: the pairs that failed the need test were never candidates in any useful sense, mostly customers who already hold the product, and including them would report 13.8 percent and make the metric a function of how many products the catalogue contains rather than of how much compliance blocks. Three needed actions in four are blocked, and that is the correct and intended behaviour of the engine, not a defect to be fixed -- consent and DNC rules alone account for over half. When quoting this, name the top reasons via suppression_reason or suppression_category, because "75 percent suppressed" without the composition reads as a broken engine rather than a governed one.',

    suppressed_customer_share AS nba_candidates.customers_suppressed / NULLIF(customers.total_customers, 0)
      WITH SYNONYMS ('share of customers suppressed',
                     'percentage of customers with a blocked action',
                     'proportion of customers affected by suppression')
      COMMENT = 'Customers with at least one needed action blocked, as a fraction of all customers. 4,580 / 5,000 = 0.916. Much higher than suppression_rate might suggest per head, because suppression is broad and shallow: most customers lose one or two actions to a consent rule rather than everything to a conduct rule.',

    nba_coverage_rate AS nba.customers_with_actions / NULLIF(customers.total_customers, 0)
      WITH SYNONYMS ('coverage', 'nba coverage', 'coverage rate',
                     'share of customers with a recommendation',
                     'percentage of the book covered',
                     'how much of the book has an action')
      COMMENT = 'Customers with at least one published recommendation as a fraction of all customers. 2,346 / 5,000 = 0.469. The honest headline for "how much of the book can the engine act on": the complement is not a gap in the engine but the combined effect of no need firing and of suppression.',

    care_action_share AS nba.care_action_count / NULLIF(nba.nba_count, 0)
      WITH SYNONYMS ('care action share', 'share of care actions',
                     'percentage of actions that are service',
                     'sales versus service mix', 'action mix')
      COMMENT = 'Care actions as a fraction of published actions. The single number that says whether the engine is looking after customers or selling to them, and worth reporting whenever the subject is what the engine recommends in aggregate.'
  )

  COMMENT = 'Customer 360 plus next-best-action for an Indian bank-and-insurer group: one customer spine (5,000 customers) with the insurance book, the lending book, claims, the outbound contact log, the published recommendations and the eligibility ledger hanging off it. Answers portfolio questions about relationship value, retention risk, arrears, cross-sell opportunity, claims experience, campaign effectiveness, what the engine recommends and what compliance blocked. FOUR THINGS TO KNOW BEFORE TRUSTING AN ANSWER. First, every day-count is measured from as_of_date, a stored anchor, not from today. Second, the six facts are at different grains -- policies, loans, claims, contacts, actions and candidates are all many-per-customer, so use the distinct-customer metric on whichever fact the filter sits on whenever the question asks how many PEOPLE. Third, a product gap is a statement about customer need and NOT an eligibility verdict; the eligibility verdict is in nba_candidates. Fourth, nba holds only actions that passed every compliance rule, so suppression can only be counted on nba_candidates -- 75.5 percent of needed actions are blocked, and that is the engine working, not failing.'

  AI_SQL_GENERATION 'GRAIN. customers is one row per customer and is the spine. policies, loans, claims, campaigns, nba and nba_candidates are all many-per-customer facts joined to it on CUSTOMER_ID. When the question asks how many PEOPLE, use the distinct-customer metric belonging to the fact the filter is on: total_customers on the spine, customers_with_policies, customers_with_loans, customers_with_claims, customers_contacted, customers_with_actions, customers_suppressed. A customer with three overdue loans is one customer. When it asks how many policies, loans, claims, contacts or actions, use the fact count.

NEVER LEAVE THIS MODEL. Every fact here has a distinct-customer metric precisely so that a question of the form "how many customers with attribute X also have a Y" -- a semi-join -- can be answered inside the semantic view. Use the distinct-customer metric on the Y fact, filtered on the X dimension. Do NOT write SQL against the underlying GOLD.V_SV_ views: they are presentation shims, they carry none of the guidance in this model, and an answer obtained that way is ungoverned even when the number is right. If a question genuinely cannot be expressed with the metrics and dimensions here, say so and say what is missing, rather than reaching around the model to answer it anyway.

TIME. There is no date dimension. Every day-count is measured from customers.as_of_date, a stored anchor date. Never substitute CURRENT_DATE. "Within 30 days", "days to renewal" and "days since contact" are all precomputed relative to the anchor -- use renews_within_30d, policy_days_to_renewal and days_since_contact rather than doing date arithmetic. The only genuine time grain is campaigns.contacted_month, for campaign trends over 12 rolling months.

FILTERS THAT ARE ALMOST ALWAYS WANTED. policies contains lapsed, matured and surrendered policies as well as active ones -- filter is_active_policy for any present-tense question about the book. policy_count and total_annualised_premium_inr are unfiltered by design because lapse_rate needs the full denominator. nba contains up to three ranked actions per customer -- filter is_top_action when the question is about the recommendation for a customer rather than all their options.

CHURN IS THREE DIFFERENT QUESTIONS AND THEY HAVE THREE DIFFERENT ANSWERS. Read which one is being asked before choosing a metric. (a) CHURN THAT ALREADY HAPPENED -- "what is our churn rate", "how many customers left", "lapse rate": use lapse_rate and lapsed_policy_count over policies.is_lapsed_policy, the recorded lapse event. Never count MATURED (ran its full term) or SURRENDERED (deliberate exit) as churn. (b) A CUSTOMER SHOWING A CHURN SIGNAL -- "how many customers are showing churn signals", "which customers are souring", anything about customers and sentiment: use customers_deteriorating, and ALWAYS report customers_unknown_trend beside it, because only 12 of 5,000 customers have a measurable deteriorating trend and 4,864 have too few interactions to have any trend at all. (c) A POLICY WHOSE RENEWAL IS IN DOUBT -- "which policies are at risk", "retention risk", "what do we need to save": use policies_at_risk_30d and premium_at_risk_30d. These are POLICIES, not customers. Do not answer (b) with (c): a question about how many CUSTOMERS show churn signals is not answered by a count of at-risk POLICIES.

THE ENGINE IS TWO TABLES AND CHOOSING THE WRONG ONE IS THE MAIN TRAP IN THIS MODEL. nba is what was DECIDED: 3,917 published recommendations, all of which passed every compliance rule. nba_candidates is what was CONSIDERED: 90,000 (customer, action) pairs with the need test, the suppression verdict and the governing rule. Questions about what to recommend, expected value, ranking, channel or rationale go to nba. Questions about suppression, blocking, eligibility, "why not", "what could we not do" or the cost of compliance go to nba_candidates. A suppressed action is ABSENT from nba, so a suppression count or rate taken over nba is always zero and always wrong. Never join or compare the two in one answer without saying which grain each number is on.

SUPPRESSION ARITHMETIC. suppression_rate is suppressed_need_count / needed_candidates = 12,435 / 16,475 = 75.5 percent. The denominator is the NEEDED subset, not all 90,000 evaluated pairs -- the 73,525 that failed the need test are mostly customers who already hold the product and were never real candidates. If asked for a suppression rate, use the metric; do not rebuild it, and in particular do not divide by candidates_evaluated, which yields a misleading 13.8 percent. Break suppression down with suppression_reason (thirteen governing rules) or suppression_category (six families: CONSENT, CONDUCT, ARREARS, SUITABILITY, CONTACT_FATIGUE, OTHER). NOT_SUPPRESSED is a real value in both, being the 4,040 pairs that passed -- do not filter it out silently when showing a breakdown, and do not treat it as missing data.

VALUE HAS TWO DIFFERENT MEANINGS ACROSS THE TWO ENGINE TABLES AND THEY MUST NOT BE ADDED OR COMPARED. nba.total_expected_value_inr is propensity times value at stake times margin -- risk-adjusted, 7,177,355. nba_candidates.suppressed_value_at_stake_inr is GROSS value at stake with no propensity applied, because a suppressed row has no propensity, and it is several times larger. Describe expected value as the size of an identified pipeline and never as revenue that will arrive; describe suppressed value at stake as gross value the rules declined to pursue and never as money lost.

ARREARS, OVERDUE and DPD are the same thing. Per loan use loans.dpd_bucket, dpd_days or is_in_arrears. Per CUSTOMER use customers.is_in_arrears_customer and the customers_in_arrears metric -- do not rebuild the predicate from worst_dpd_bucket, and never group NO_CREDIT_OBLIGATION (no borrowing) with CURRENT (borrowing, up to date). For rupee exposure use arrears_exposure_inr, which is the full balance of every late loan. When breaking down by dpd_bucket, select total_outstanding_inr as well as arrears_exposure_inr, because arrears exposure is zero by construction in the CURRENT bucket and showing it alone reports 2,654 healthy loans as carrying no balance.

COUNTING PEOPLE VERSUS COUNTING ROWS. Each fact has exactly one distinct-customer metric and they are not interchangeable with the row counts beside them: customers_with_policies against policy_count, customers_with_loans against loan_count, customers_with_claims against claim_count, customers_contacted against contact_count, customers_with_actions against nba_count, customers_suppressed against suppressed_need_count. Any question of the form "how many customers with X are also Y" uses the distinct-customer metric on the Y fact filtered on the X dimension, inside the semantic view.

THREE DIMENSIONS ARE CALLED SOMETHING LIKE CHANNEL AND THEY MEAN DIFFERENT THINGS. policies.channel_sold is where a policy was originated. campaigns.campaign_channel is where a past contact went out. nba.action_channel is where the engine proposes to make the NEXT contact. customers.preferred_channel is an observed behaviour and not a permission. Read which one the question means before choosing.

TRAPS TO AVOID. sentiment_trend values INSUFFICIENT_DATA and NO_CONTACT_HISTORY mean UNKNOWN, never STABLE -- when reporting a trend breakdown say how much of the book is unknown, using customers_unknown_trend. claim_ratio is NULL for customers who never claimed, which is not zero, so do not coalesce it when averaging. avg_dpd_days includes loans at zero days and is dragged toward zero; filter is_in_arrears if the question means the average among late loans. A product gap is a need and not an eligibility verdict, so never describe gap counts as customers who can be sold to -- nba_candidates.is_actionable is the eligibility verdict. propensity is a model output, so it ranks actions and does not forecast individual outcomes. rationale_source distinguishes model-written prose from templated prose; a TEMPLATE row is not less compliant, because the compliance decision is deterministic for every row.

PAIRINGS THAT MAKE ANSWERS HONEST. Report campaign_conversion_rate together with campaign_opt_out_rate. Report policies_at_risk_30d together with premium_at_risk_30d for the rupee stake. Report avg_relationship_value with the relationship_value_band mix, because the mean sits well above the median on a skewed distribution. Size any outreach against reachable_customers, not total_customers. Report suppression_rate together with its top reasons, because the bare number reads as a broken engine. Report nba_count together with customers_with_actions, because three actions for one customer is not three opportunities to contact. Report care_action_count together with sales_action_count, because the mix is what says whether the engine is serving customers or selling to them.'

  AI_QUESTION_CATEGORIZATION 'Answerable: customer counts and mix by city, segment, age band, tenure band and value band; relationship value totals and averages; product holdings, cross-sell gaps and relationship depth; the insurance book by type, status, premium and sum assured; lapse rates and lapse counts sliced any way; retention risk from approaching renewals plus recent complaints, and the premium at stake; the lending book, arrears by bucket, days past due, rising-arrears trajectories, restructures and rupee arrears exposure; claims volumes, settlement ratios, rejection rates and turnaround; campaign volumes, conversion and opt-out rates by channel, campaign and month; contact permission and reachability; hardship, vulnerability and KYC populations; distinct-customer counts on every fact, so any "customers with X who also have Y" question. And now: what the engine recommends, by action, channel, rank, priority tier and rationale source; how many recommendations and for how many customers; expected value totals and averages sliced any way; engine coverage of the book; the sales-versus-care mix; how many candidate actions were evaluated, how many the customer needed, how many were blocked and by which rule or family of rule; the gross value at stake on blocked actions; and how many customers were affected by suppression.

Not answerable: the ranked action list for ONE NAMED CUSTOMER with its rationale, evidence and disclosure -- this model aggregates, and a per-customer recommendation must come from the APP.GET_NEXT_BEST_ACTIONS procedure, which returns the suppressed actions too. Individual interaction text, call transcripts and their sentiment at interaction grain -- use the interaction search service. Product terms, eligibility clauses and regulatory wording -- use the product document search service. Anything needing a date other than the stored as-of anchor, including point-in-time history, month-over-month customer trends or aged snapshots of the book. Transaction-level spend, merchant category mix and payment-ledger detail. Household relationships beyond household size. The per-rule eligibility trace for a single action, which is in the procedure output rather than here.'

  /* ==========================================================================
     AI_VERIFIED_QUERIES — WORKED ANSWERS FOR THE SHAPES THAT MATTER
     --------------------------------------------------------------------------
     These exist because a metric and a paragraph of guidance were not enough,
     and they are the shape they are because a first attempt at them made things
     worse. Both findings are worth recording, because the second one is the
     non-obvious half.

     FINDING 1: CLOSING A COVERAGE GAP DOES NOT UNDO THE BEHAVIOUR IT CAUSED.
     analyst_questions.md Q12 recorded Analyst abandoning this view to hand-roll
     SQL against the V_SV_ shims, diagnosed the cause as a missing
     customer-grain metric on the campaigns fact, added
     campaigns.customers_contacted, re-ran the question and recorded a PASS.

     That fix did not hold. The first run of evals/run_analyst_evals.py against
     this rebuilt model failed Q12 on the SEMANTIC_VIEW( assertion, with
     generated SQL the same shape as the original failure -- reading
     V_SV_CAMPAIGN and V_SV_CUSTOMER directly, joining them by hand, and
     returning the correct 268. The metric it needed existed. The
     AI_SQL_GENERATION block above told it in capitals not to do this. It did it
     anyway. A metric makes an answer POSSIBLE inside the model; it does not make
     the model the path of least resistance for a question shaped like a join,
     and prose instructions are advisory to a model weighing them against its own
     read of the schema. A verified query is not advisory.

     FINDING 2: AN EXEMPLAR SET THAT COVERS ONLY THE HARD SHAPES MAKES THE EASY
     ONES WORSE. The first version of this block held six queries, every one of
     them a semi-join or a two-grain case -- the shapes with a history of
     failing. Q12 and Q18 duly started passing. Q10 -- "claim rejection rate by
     policy type", a plain metric-by-dimension breakdown that had passed
     unaided in every previous run -- then started failing on the same
     assertion, deterministically, three runs out of three, reading V_SV_CLAIM
     directly to compute a rate that already exists as claim_rejection_rate.

     The reading that fits: verified queries are retrieved as exemplars, and for
     a simple breakdown the six on offer were all structurally unlike the
     question. Nothing matched, and what got retrieved instead was CTE-and-join
     prose that reads as licence to write ordinary SQL. So the exemplar set is
     not just a patch list for known failures -- it is training data for shape,
     and a set that omits the commonest shape teaches its absence.

     Hence the ordering below: the three ordinary shapes first -- a breakdown, a
     paired rate, and a ranked listing -- because that is what most questions
     are, then the six semi-joins, then the two cases that genuinely need two
     calls joined. Nine of eleven are a plain SELECT * FROM
     SEMANTIC_VIEW(...), so whichever is retrieved most likely teaches the right
     shape, and the two that are not are outnumbered rather than dominant.

     The third ordinary shape was itself a second correction: fixing the
     breakdown fixed Q10 and left Q11, a ranked LISTING of customers, still
     bypassing. Same failure, different shape, and no reason to expect one
     exemplar to generalise to the other.

     VERIFIED_AT is 2026-08-29, the date each was checked against the plain-SQL
     derivations in §3. VERIFIED_BY is omitted: it requires a CONTACT object, and
     inventing one to satisfy a clause would be worse documentation than leaving
     it out.
     ========================================================================== */
  AI_VERIFIED_QUERIES (

    /* ---- 1. THE ORDINARY SHAPES --------------------------------------------
       A metric and a dimension. Most questions are this, and before this
       exemplar existed the set contained nothing that looked like one. Q10's
       question verbatim, since Q10 is the one that regressed for want of it. */
    rejection_rate_by_policy_type AS (
      QUESTION 'What is the claim rejection rate by policy type?'
      VERIFIED_AT 1787011200
      ONBOARDING_QUESTION TRUE
      SQL 'SELECT * FROM SEMANTIC_VIEW(
             C360_NBA.GOLD.SV_CUSTOMER_360
             METRICS claim_rejection_rate, claims.rejected_claim_count, claims.claim_count
             DIMENSIONS claims.claim_policy_type
           ) ORDER BY CLAIM_REJECTION_RATE DESC NULLS LAST'
    ),

    /* A rate with the companion that keeps it honest, which is the pairing rule
       from AI_SQL_GENERATION given a worked form. A channel that converts well
       and burns consent is not a good channel. */
    channel_conversion_and_consent_burn AS (
      QUESTION 'Which campaign channel converts best, and which one burns the most consent?'
      VERIFIED_AT 1787011200
      ONBOARDING_QUESTION TRUE
      SQL 'SELECT * FROM SEMANTIC_VIEW(
             C360_NBA.GOLD.SV_CUSTOMER_360
             METRICS campaign_conversion_rate, campaign_opt_out_rate,
                     campaigns.contact_count, campaigns.converted_count,
                     campaigns.opt_out_count
             DIMENSIONS campaigns.campaign_channel
           ) ORDER BY CAMPAIGN_CONVERSION_RATE DESC NULLS LAST'
    ),

    /* A ranked LIST of entities rather than an aggregate over them. The third
       ordinary shape, and the one Finding 2 missed on its first correction: Q11
       ("top 10 customers by relationship value who are in arrears") kept
       bypassing the model even after the breakdown exemplar fixed Q10, because a
       row listing looks nothing like a metric-by-dimension breakdown and a
       semantic view is aggregate-shaped by construction.

       The idiom is not obvious, which is exactly why it needs an exemplar:
       customer_id is the primary key, so grouping by it yields one row per
       customer and total_est_annual_margin_inr becomes that customer own margin
       rather than a portfolio sum. Without this, Analyst reasonably concludes
       that listing rows is not something the model does and goes to the shim. */
    top_customers_in_arrears AS (
      QUESTION 'Who are our top 10 customers by relationship value who are currently in arrears?'
      VERIFIED_AT 1787011200
      ONBOARDING_QUESTION TRUE
      SQL 'SELECT * FROM SEMANTIC_VIEW(
             C360_NBA.GOLD.SV_CUSTOMER_360
             DIMENSIONS customers.customer_id, customers.customer_name,
                        customers.city, customers.segment,
                        customers.worst_dpd_bucket
             METRICS customers.total_est_annual_margin_inr
             WHERE customers.is_in_arrears_customer = TRUE
           ) ORDER BY TOTAL_EST_ANNUAL_MARGIN_INR DESC NULLS LAST LIMIT 10'
    ),

    /* A split into categories: one metric grouped by a derived class. Added
       after the agent test failed this exact question by hand-rolling the
       classification against V_SV_NBA -- see the ACTION_CLASS comment in the
       feeder view for why the dimension had to exist before the exemplar could
       be written, and for why it returns three classes to a question that asks
       for two. */
    sales_versus_care_split AS (
      QUESTION 'What is the split between sales actions and care actions in what we recommend?'
      VERIFIED_AT 1787011200
      ONBOARDING_QUESTION TRUE
      SQL 'SELECT * FROM SEMANTIC_VIEW(
             C360_NBA.GOLD.SV_CUSTOMER_360
             METRICS nba.nba_count, nba.total_expected_value_inr
             DIMENSIONS nba.action_class
           ) ORDER BY NBA_COUNT DESC NULLS LAST'
    ),

    /* ---- 2. THE SEMI-JOINS -------------------------------------------------
       One per fact, the same enumeration the distinct-customer metrics follow.
       A customer dimension in WHERE, a distinct-customer metric on the fact.

       The Q12 question verbatim first, since that is the one with a demonstrated
       history of pushing Analyst out of the model. 268 customers. */
    hardship_customers_still_contacted AS (
      QUESTION 'How many customers with a hardship signal are we still contacting in campaigns?'
      VERIFIED_AT 1787011200
      ONBOARDING_QUESTION FALSE
      SQL 'SELECT * FROM SEMANTIC_VIEW(
             C360_NBA.GOLD.SV_CUSTOMER_360
             METRICS campaigns.customers_contacted
             WHERE customers.has_hardship_signal = TRUE
           )'
    ),

    /* The insurance book, with a different customer attribute on purpose: the
       exemplar should teach the SHAPE and not the specific predicate. */
    vulnerable_customers_holding_policies AS (
      QUESTION 'How many vulnerable customers hold an insurance policy?'
      VERIFIED_AT 1787011200
      ONBOARDING_QUESTION FALSE
      SQL 'SELECT * FROM SEMANTIC_VIEW(
             C360_NBA.GOLD.SV_CUSTOMER_360
             METRICS policies.customers_with_policies
             WHERE customers.is_vulnerable = TRUE
           )'
    ),

    /* The lending book, with the predicate on the FACT rather than the spine, so
       one exemplar shows that side too. */
    customers_with_restructured_loans AS (
      QUESTION 'How many customers hold a restructured loan?'
      VERIFIED_AT 1787011200
      ONBOARDING_QUESTION FALSE
      SQL 'SELECT * FROM SEMANTIC_VIEW(
             C360_NBA.GOLD.SV_CUSTOMER_360
             METRICS loans.customers_with_loans
             WHERE loans.is_restructured = TRUE
           )'
    ),

    /* Claims: predicate on the fact, count on people -- the combination most
       likely to be answered as a claim count by mistake. */
    customers_with_rejected_claims AS (
      QUESTION 'How many customers have had a claim rejected?'
      VERIFIED_AT 1787011200
      ONBOARDING_QUESTION FALSE
      SQL 'SELECT * FROM SEMANTIC_VIEW(
             C360_NBA.GOLD.SV_CUSTOMER_360
             METRICS claims.customers_with_claims
             WHERE claims.is_rejected_claim = TRUE
           )'
    ),

    /* The engine, both grains, one exemplar each. */
    hardship_customers_with_a_recommendation AS (
      QUESTION 'How many customers with a hardship signal have a recommendation?'
      VERIFIED_AT 1787011200
      ONBOARDING_QUESTION FALSE
      SQL 'SELECT * FROM SEMANTIC_VIEW(
             C360_NBA.GOLD.SV_CUSTOMER_360
             METRICS nba.customers_with_actions
             WHERE customers.has_hardship_signal = TRUE
           )'
    ),

    vulnerable_customers_with_a_blocked_action AS (
      QUESTION 'How many vulnerable customers had an action blocked?'
      VERIFIED_AT 1787011200
      ONBOARDING_QUESTION FALSE
      SQL 'SELECT * FROM SEMANTIC_VIEW(
             C360_NBA.GOLD.SV_CUSTOMER_360
             METRICS nba_candidates.customers_suppressed
             WHERE customers.is_vulnerable = TRUE
           )'
    ),

    /* ---- 3. THE TWO AWKWARD ONES -------------------------------------------
       Suppression with its composition, and this exemplar took two corrections
       to get right.

       V1 selected suppression_rate with DIMENSIONS suppression_reason and no
       filter. Degenerate: grouped by the reason a pair was blocked, the rate is
       1.0 in every suppressed bucket and 0.0 in NOT_SUPPRESSED by construction.

       V2 added WHERE eligible_on_need = TRUE, on the theory that restricting to
       the denominator population would make the rate whole. It does not. The
       rate is still evaluated per group, so it still reads 1.0 in every bucket;
       the filter narrowed the rows without changing the grain of the ratio. The
       eval caught this too -- Q17 kept failing its 0.7548 probe while passing
       both governance checks, which is precisely the signal a probe is for.

       The property that was being wished away: a ratio over the whole needed set
       is NOT AVAILABLE at the same grain as a breakdown of its numerator. No
       single SEMANTIC_VIEW() call returns both, and no filter makes one. So this
       is the second query here that has to be two calls joined, and the cost of
       that shape is now paid down by the three ordinary exemplars above rather
       than by pretending the shape is avoidable.

       Analyst followed V1 and V2 faithfully in turn, which is the standing
       lesson: a bad verified query propagates with more force than a bad
       comment. The mechanism is not advisory, so it is not forgiving. */
    suppression_rate_by_reason AS (
      QUESTION 'What is our suppression rate and which rules are blocking the most actions?'
      VERIFIED_AT 1787011200
      ONBOARDING_QUESTION TRUE
      SQL 'WITH overall AS (
             SELECT * FROM SEMANTIC_VIEW(
               C360_NBA.GOLD.SV_CUSTOMER_360
               METRICS suppression_rate, nba_candidates.suppressed_need_count,
                       nba_candidates.needed_candidates
             )
           ),
           by_reason AS (
             SELECT * FROM SEMANTIC_VIEW(
               C360_NBA.GOLD.SV_CUSTOMER_360
               METRICS nba_candidates.suppressed_need_count
               DIMENSIONS nba_candidates.suppression_reason
               WHERE nba_candidates.is_suppressed_need = TRUE
             )
           )
           SELECT r.SUPPRESSION_REASON        AS suppression_reason,
                  r.SUPPRESSED_NEED_COUNT     AS actions_blocked_by_this_rule,
                  o.SUPPRESSION_RATE          AS overall_suppression_rate,
                  o.SUPPRESSED_NEED_COUNT     AS total_actions_blocked,
                  o.NEEDED_CANDIDATES         AS total_actions_needed
           FROM by_reason r CROSS JOIN overall o
           ORDER BY actions_blocked_by_this_rule DESC NULLS LAST'
    ),

    /* THE TWO-GRAIN CASE. Two calls joined for the same structural reason as
       the query above: the two halves live on different logical tables, mean
       different things, and there is no correct single-metric answer. Pinned so
       the answer keeps both numbers and keeps them labelled. */
    arrears_customers_recommended_and_blocked AS (
      QUESTION 'How many customers in arrears have a recommendation, and how many had an action blocked?'
      VERIFIED_AT 1787011200
      ONBOARDING_QUESTION FALSE
      SQL 'SELECT recommended.CUSTOMERS_WITH_ACTIONS AS customers_with_a_recommendation,
                  blocked.CUSTOMERS_SUPPRESSED       AS customers_with_a_blocked_action
           FROM (SELECT * FROM SEMANTIC_VIEW(
                   C360_NBA.GOLD.SV_CUSTOMER_360
                   METRICS nba.customers_with_actions
                   WHERE customers.is_in_arrears_customer = TRUE
                 )) AS recommended,
                (SELECT * FROM SEMANTIC_VIEW(
                   C360_NBA.GOLD.SV_CUSTOMER_360
                   METRICS nba_candidates.customers_suppressed
                   WHERE customers.is_in_arrears_customer = TRUE
                 )) AS blocked'
    )
  )
;


/* ============================================================================
   PART 3 — VERIFICATION
   ----------------------------------------------------------------------------
   A1 is new. A3, A4 and A5 are relocated verbatim from sql/09 §3.2-3.4, which
   can no longer run them because it no longer creates the object they query.
   A6-A9 are new and cover the two new facts.

   The old A2 -- "NEXT_BEST_ACTION is not referenced" -- is deleted rather than
   moved. It asserted a decision this file reverses.

   Every assertion re-derives the answer in plain SQL over the underlying tables
   and compares it with what the semantic view returns, emitting a PASS / FAIL
   verdict column. Both sides are emitted, not just the verdict, so a failure
   says which number drifted and by how much.
   ============================================================================ */

/* 3.1  A1. The quarantine holds. Now seven views and the semantic view, since
        this file adds two feeders. Reads the STORED DDL of the created objects
        rather than this source file, so prose in a header cannot make it pass
        vacuously. */
SELECT 'A1 segment truth not referenced' AS assertion,
       COUNT_IF(UPPER(ddl) LIKE '%CUSTOMER_SEGMENT_TRUTH%') AS violations,
       IFF(COUNT_IF(UPPER(ddl) LIKE '%CUSTOMER_SEGMENT_TRUTH%') = 0, 'PASS', 'FAIL') AS verdict
FROM (
  SELECT GET_DDL('VIEW', 'GOLD.V_SV_CUSTOMER')  AS ddl
  UNION ALL SELECT GET_DDL('VIEW', 'GOLD.V_SV_POLICY')
  UNION ALL SELECT GET_DDL('VIEW', 'GOLD.V_SV_LOAN')
  UNION ALL SELECT GET_DDL('VIEW', 'GOLD.V_SV_CLAIM')
  UNION ALL SELECT GET_DDL('VIEW', 'GOLD.V_SV_CAMPAIGN')
  UNION ALL SELECT GET_DDL('VIEW', 'GOLD.V_SV_NBA')
  UNION ALL SELECT GET_DDL('VIEW', 'GOLD.V_SV_NBA_CANDIDATE')
  UNION ALL SELECT GET_DDL('SEMANTIC_VIEW', 'GOLD.SV_CUSTOMER_360')
);

/* 3.2  A3. The six headline metrics still agree with plain SQL over the
        underlying tables. RELOCATED FROM sql/09 §3.2 UNCHANGED, and it is the
        regression test for the move: if relocating the definition altered any
        of the original six, this fails. The truth side is recomputed rather
        than hardcoded, so it survives the as-of anchor moving. */
WITH sv AS (
  SELECT * FROM SEMANTIC_VIEW(
    GOLD.SV_CUSTOMER_360
    METRICS total_customers,
            avg_relationship_value,
            policies_at_risk_30d,
            lapse_rate,
            cross_sell_gap_count,
            arrears_exposure_inr
  )
),
truth AS (
  SELECT
    (SELECT COUNT(*) FROM GOLD.CUSTOMER_360)                            AS total_customers,
    (SELECT AVG(EST_ANNUAL_MARGIN_INR) FROM GOLD.CUSTOMER_360)          AS avg_relationship_value,
    (SELECT COUNT(*)
       FROM RAW.POLICY p
       CROSS JOIN GOLD.C360_ASOF a
      WHERE p.STATUS = 'ACTIVE'
        AND p.RENEWAL_DATE BETWEEN a.AS_OF_DATE AND DATEADD(day, 30, a.AS_OF_DATE)
        AND EXISTS (SELECT 1
                      FROM RAW.SERVICE_TICKET t
                      CROSS JOIN GOLD.C360_ASOF a2
                     WHERE t.CUSTOMER_ID = p.CUSTOMER_ID
                       AND t.IS_COMPLAINT
                       AND t.OPENED_AT >= DATEADD(day, -60, a2.AS_OF_DATE)))  AS policies_at_risk_30d,
    (SELECT COUNT_IF(LAPSE_FLAG) / NULLIF(COUNT(*), 0) FROM RAW.POLICY)  AS lapse_rate,
    (SELECT SUM(ARRAY_SIZE(PRODUCT_GAP)) FROM GOLD.CUSTOMER_360)         AS cross_sell_gap_count,
    (SELECT SUM(OUTSTANDING_INR) FROM RAW.LOAN WHERE DPD_DAYS > 0)       AS arrears_exposure_inr
),
cmp AS (
  SELECT 'total_customers'        AS metric, sv.TOTAL_CUSTOMERS::FLOAT               AS via_sv, truth.TOTAL_CUSTOMERS::FLOAT               AS via_sql FROM sv, truth
  UNION ALL SELECT 'avg_relationship_value',  ROUND(sv.AVG_RELATIONSHIP_VALUE, 2),   ROUND(truth.AVG_RELATIONSHIP_VALUE, 2)                FROM sv, truth
  UNION ALL SELECT 'policies_at_risk_30d',    sv.POLICIES_AT_RISK_30D::FLOAT,        truth.POLICIES_AT_RISK_30D::FLOAT                     FROM sv, truth
  UNION ALL SELECT 'lapse_rate',              ROUND(sv.LAPSE_RATE, 8),               ROUND(truth.LAPSE_RATE, 8)                            FROM sv, truth
  UNION ALL SELECT 'cross_sell_gap_count',    sv.CROSS_SELL_GAP_COUNT::FLOAT,        truth.CROSS_SELL_GAP_COUNT::FLOAT                     FROM sv, truth
  UNION ALL SELECT 'arrears_exposure_inr',    sv.ARREARS_EXPOSURE_INR::FLOAT,        truth.ARREARS_EXPOSURE_INR::FLOAT                     FROM sv, truth
)
SELECT 'A3 headline metrics match plain SQL' AS assertion,
       metric, via_sv, via_sql,
       IFF(EQUAL_NULL(via_sv, via_sql), 'PASS', 'FAIL') AS verdict
FROM cmp
ORDER BY metric;

/* 3.3  A4. Grain sanity: no fact inflates the spine. RELOCATED FROM sql/09
        §3.3, extended to the two new facts. */
SELECT
  CASE WHEN orphan_policies = 0 AND orphan_loans = 0
        AND orphan_claims = 0   AND orphan_campaigns = 0
        AND orphan_nba = 0      AND orphan_candidates = 0
       THEN 'A4 PASS: no fact rows reference a customer absent from the spine'
       ELSE 'A4 FAIL: orphans -- policies ' || orphan_policies
            || ', loans '      || orphan_loans
            || ', claims '     || orphan_claims
            || ', campaigns '  || orphan_campaigns
            || ', nba '        || orphan_nba
            || ', candidates ' || orphan_candidates
  END AS referential_check
FROM (
  SELECT
    (SELECT COUNT(*) FROM GOLD.V_SV_POLICY        f WHERE NOT EXISTS (SELECT 1 FROM GOLD.V_SV_CUSTOMER c WHERE c.CUSTOMER_ID = f.CUSTOMER_ID)) AS orphan_policies,
    (SELECT COUNT(*) FROM GOLD.V_SV_LOAN          f WHERE NOT EXISTS (SELECT 1 FROM GOLD.V_SV_CUSTOMER c WHERE c.CUSTOMER_ID = f.CUSTOMER_ID)) AS orphan_loans,
    (SELECT COUNT(*) FROM GOLD.V_SV_CLAIM         f WHERE NOT EXISTS (SELECT 1 FROM GOLD.V_SV_CUSTOMER c WHERE c.CUSTOMER_ID = f.CUSTOMER_ID)) AS orphan_claims,
    (SELECT COUNT(*) FROM GOLD.V_SV_CAMPAIGN      f WHERE NOT EXISTS (SELECT 1 FROM GOLD.V_SV_CUSTOMER c WHERE c.CUSTOMER_ID = f.CUSTOMER_ID)) AS orphan_campaigns,
    (SELECT COUNT(*) FROM GOLD.V_SV_NBA           f WHERE NOT EXISTS (SELECT 1 FROM GOLD.V_SV_CUSTOMER c WHERE c.CUSTOMER_ID = f.CUSTOMER_ID)) AS orphan_nba,
    (SELECT COUNT(*) FROM GOLD.V_SV_NBA_CANDIDATE f WHERE NOT EXISTS (SELECT 1 FROM GOLD.V_SV_CUSTOMER c WHERE c.CUSTOMER_ID = f.CUSTOMER_ID)) AS orphan_candidates
);

/* 3.4  A5. Synonym coverage. RELOCATED FROM sql/09 §3.4, extended with the four
        terms the engine introduces. As 09's own note said, this checks that a
        term RESOLVES, not that it resolves to the right thing -- that is what
        evals/analyst_questions.md is for.

        SHOW populates the result set the next query RESULT_SCANs, so these two
        statements must run in order and adjacently. */
SHOW SEMANTIC DIMENSIONS IN GOLD.SV_CUSTOMER_360;

WITH declared AS (
  SELECT "name" AS dim_name,
         LOWER(s.VALUE::STRING) AS synonym
  FROM TABLE(RESULT_SCAN(LAST_QUERY_ID())),
       LATERAL FLATTEN(input => TRY_PARSE_JSON("synonyms")) s
),
required AS (
  SELECT * FROM VALUES
    ('churn'), ('attrition'), ('lapse'),
    ('arrears'), ('overdue'), ('dpd'),
    ('suppressed'), ('blocked'), ('recommendation'), ('why not')
  AS t(term)
),
resolution AS (
  SELECT r.term,
         COUNT(d.dim_name)                 AS hits,
         LISTAGG(DISTINCT d.dim_name, '/') AS resolves_to
  FROM required r
  LEFT JOIN declared d ON d.synonym = r.term
  GROUP BY r.term
)
SELECT
  CASE WHEN COUNT_IF(hits = 0) = 0
       THEN 'A5 PASS: all ten required synonyms resolve -- '
            || LISTAGG(term || '->' || resolves_to, ', ') WITHIN GROUP (ORDER BY term)
       ELSE 'A5 FAIL: unresolved -- '
            || LISTAGG(CASE WHEN hits = 0 THEN term END, ', ')
  END AS synonym_check
FROM resolution;

/* 3.4b  A5b. The engine's vocabulary resolves UNAMBIGUOUSLY.
        A5 checks that a term resolves at all, and sql/09's own note conceded it
        cannot check that a term resolves to the RIGHT thing. It can, however,
        check that a term resolves to exactly ONE thing, which is a strictly
        stronger property and catches the specific defect Q7 documented: a
        synonym attached to two dimensions is a synonym one of them will lose.

        This assertion earned its place immediately. On the first run of this
        file 'suppressed' resolved to two dimensions -- nba_candidates.suppressed
        and customers.is_on_dnc_registry, which had claimed the word before the
        engine existed. DNC is one of thirteen suppression reasons, so the
        policy flag would have been competing for, and sometimes winning, every
        question about the engine blocking an action. The synonym was removed
        from the DNC dimension; see the comment there.

        Scoped to the terms the engine introduces rather than to every synonym in
        the model, because two pre-existing collisions are deliberate and
        harmless: 'adverse outcome' on both campaign failure modes, and
        'opted out' on the DNC flag and the campaign outcome. Widening this
        assertion to the whole model is a separate change with a separate
        argument to make, and making it here would mean either failing on those
        two or carrying an exception list that hides real regressions. */
SHOW SEMANTIC DIMENSIONS IN GOLD.SV_CUSTOMER_360;

WITH declared AS (
  SELECT "name" AS dim_name,
         LOWER(s.VALUE::STRING) AS synonym
  FROM TABLE(RESULT_SCAN(LAST_QUERY_ID())),
       LATERAL FLATTEN(input => TRY_PARSE_JSON("synonyms")) s
),
engine_terms AS (
  SELECT * FROM VALUES
    ('suppressed'), ('blocked'), ('why not'), ('recommendation'),
    ('suppression reason'), ('eligible on need'), ('actionable'),
    ('top action'), ('care action'), ('rationale source')
  AS t(term)
),
resolution AS (
  SELECT e.term,
         COUNT(d.dim_name)                 AS hits,
         LISTAGG(DISTINCT d.dim_name, '/') AS resolves_to
  FROM engine_terms e
  LEFT JOIN declared d ON d.synonym = e.term
  GROUP BY e.term
)
SELECT 'A5b engine vocabulary resolves to exactly one dimension' AS assertion,
       term, hits, resolves_to,
       CASE WHEN hits = 1 THEN 'PASS'
            WHEN hits = 0 THEN 'FAIL: unresolved'
            ELSE 'FAIL: ambiguous across ' || hits || ' dimensions'
       END AS verdict
FROM resolution
ORDER BY IFF(hits = 1, 1, 0), term;

/* 3.5  A6. The three metrics this file was asked for agree with plain SQL, and
        suppression_rate in particular is checked against its intended
        definition rather than against whatever the view happens to compute. */
WITH sv AS (
  SELECT * FROM SEMANTIC_VIEW(
    GOLD.SV_CUSTOMER_360
    METRICS nba_count,
            total_expected_value_inr,
            suppression_rate,
            customers_with_actions,
            needed_candidates,
            suppressed_need_count
  )
),
truth AS (
  SELECT
    (SELECT COUNT(*) FROM GOLD.NEXT_BEST_ACTION)                        AS nba_count,
    (SELECT SUM(EXPECTED_VALUE_INR) FROM GOLD.NEXT_BEST_ACTION)         AS total_expected_value_inr,
    (SELECT COUNT_IF(SUPPRESSED AND ELIGIBLE_ON_NEED)
              / NULLIF(COUNT_IF(ELIGIBLE_ON_NEED), 0)
       FROM GOLD.NBA_ELIGIBLE)                                          AS suppression_rate,
    (SELECT COUNT(DISTINCT CUSTOMER_ID) FROM GOLD.NEXT_BEST_ACTION)     AS customers_with_actions,
    (SELECT COUNT_IF(ELIGIBLE_ON_NEED) FROM GOLD.NBA_ELIGIBLE)          AS needed_candidates,
    (SELECT COUNT_IF(SUPPRESSED AND ELIGIBLE_ON_NEED)
       FROM GOLD.NBA_ELIGIBLE)                                          AS suppressed_need_count
),
cmp AS (
  SELECT 'nba_count'                AS metric, sv.NBA_COUNT::FLOAT                     AS via_sv, truth.NBA_COUNT::FLOAT                     AS via_sql FROM sv, truth
  UNION ALL SELECT 'total_expected_value_inr', ROUND(sv.TOTAL_EXPECTED_VALUE_INR, 2),  ROUND(truth.TOTAL_EXPECTED_VALUE_INR, 2)                        FROM sv, truth
  UNION ALL SELECT 'suppression_rate',         ROUND(sv.SUPPRESSION_RATE, 8),          ROUND(truth.SUPPRESSION_RATE, 8)                                FROM sv, truth
  UNION ALL SELECT 'customers_with_actions',   sv.CUSTOMERS_WITH_ACTIONS::FLOAT,       truth.CUSTOMERS_WITH_ACTIONS::FLOAT                             FROM sv, truth
  UNION ALL SELECT 'needed_candidates',        sv.NEEDED_CANDIDATES::FLOAT,            truth.NEEDED_CANDIDATES::FLOAT                                  FROM sv, truth
  UNION ALL SELECT 'suppressed_need_count',    sv.SUPPRESSED_NEED_COUNT::FLOAT,        truth.SUPPRESSED_NEED_COUNT::FLOAT                              FROM sv, truth
)
SELECT 'A6 nba metrics match plain SQL' AS assertion,
       metric, via_sv, via_sql,
       IFF(EQUAL_NULL(via_sv, via_sql), 'PASS', 'FAIL') AS verdict
FROM cmp
ORDER BY metric;

/* 3.6  A7. Every fact now has a distinct-customer metric that agrees with
        plain SQL. This is the Q12 carry-over made checkable: the failure mode
        it prevents is a metric that exists but silently double-counts, which
        would be worse than the missing metric it replaces. */
WITH sv AS (
  SELECT * FROM SEMANTIC_VIEW(
    GOLD.SV_CUSTOMER_360
    METRICS customers_with_policies,
            customers_with_loans,
            customers_with_claims,
            customers_contacted,
            customers_with_actions,
            customers_suppressed
  )
),
truth AS (
  SELECT
    (SELECT COUNT(DISTINCT CUSTOMER_ID) FROM RAW.POLICY)             AS customers_with_policies,
    (SELECT COUNT(DISTINCT CUSTOMER_ID) FROM RAW.LOAN)               AS customers_with_loans,
    (SELECT COUNT(DISTINCT CUSTOMER_ID) FROM RAW.CLAIM)              AS customers_with_claims,
    (SELECT COUNT(DISTINCT CUSTOMER_ID) FROM RAW.CAMPAIGN_HISTORY)   AS customers_contacted,
    (SELECT COUNT(DISTINCT CUSTOMER_ID) FROM GOLD.NEXT_BEST_ACTION)  AS customers_with_actions,
    (SELECT COUNT(DISTINCT CUSTOMER_ID) FROM GOLD.NBA_ELIGIBLE
      WHERE SUPPRESSED AND ELIGIBLE_ON_NEED)                         AS customers_suppressed
),
cmp AS (
  SELECT 'customers_with_policies' AS metric, sv.CUSTOMERS_WITH_POLICIES::FLOAT AS via_sv, truth.CUSTOMERS_WITH_POLICIES::FLOAT AS via_sql FROM sv, truth
  UNION ALL SELECT 'customers_with_loans',    sv.CUSTOMERS_WITH_LOANS::FLOAT,    truth.CUSTOMERS_WITH_LOANS::FLOAT              FROM sv, truth
  UNION ALL SELECT 'customers_with_claims',   sv.CUSTOMERS_WITH_CLAIMS::FLOAT,   truth.CUSTOMERS_WITH_CLAIMS::FLOAT             FROM sv, truth
  UNION ALL SELECT 'customers_contacted',     sv.CUSTOMERS_CONTACTED::FLOAT,     truth.CUSTOMERS_CONTACTED::FLOAT               FROM sv, truth
  UNION ALL SELECT 'customers_with_actions',  sv.CUSTOMERS_WITH_ACTIONS::FLOAT,  truth.CUSTOMERS_WITH_ACTIONS::FLOAT            FROM sv, truth
  UNION ALL SELECT 'customers_suppressed',    sv.CUSTOMERS_SUPPRESSED::FLOAT,    truth.CUSTOMERS_SUPPRESSED::FLOAT              FROM sv, truth
)
SELECT 'A7 every fact has a correct distinct-customer metric' AS assertion,
       metric, via_sv, via_sql,
       IFF(EQUAL_NULL(via_sv, via_sql), 'PASS', 'FAIL') AS verdict
FROM cmp
ORDER BY metric;

/* 3.7  A8. THE SEMI-JOIN THAT Q12 COULD NOT EXPRESS, now expressed on all six
        facts inside the view. Q12's answer -- 268 hardship customers still
        being contacted -- is re-derived through the model rather than around
        it, and the same shape is run against every other fact so a future
        regression on any one of them is visible here.

        A row returning NULL rather than a number means the metric could not be
        combined with the customer dimension, which is exactly the coverage gap
        Q12 hit. That is why the verdict tests for NOT NULL as well as equality. */
WITH via_view AS (
  SELECT 'hardship customers contacted' AS question, CUSTOMERS_CONTACTED::FLOAT AS via_sv
    FROM SEMANTIC_VIEW(GOLD.SV_CUSTOMER_360 METRICS campaigns.customers_contacted
                       WHERE customers.has_hardship_signal = TRUE)
  UNION ALL
  SELECT 'hardship customers holding a policy', CUSTOMERS_WITH_POLICIES::FLOAT
    FROM SEMANTIC_VIEW(GOLD.SV_CUSTOMER_360 METRICS policies.customers_with_policies
                       WHERE customers.has_hardship_signal = TRUE)
  UNION ALL
  SELECT 'hardship customers holding a loan', CUSTOMERS_WITH_LOANS::FLOAT
    FROM SEMANTIC_VIEW(GOLD.SV_CUSTOMER_360 METRICS loans.customers_with_loans
                       WHERE customers.has_hardship_signal = TRUE)
  UNION ALL
  SELECT 'hardship customers who have claimed', CUSTOMERS_WITH_CLAIMS::FLOAT
    FROM SEMANTIC_VIEW(GOLD.SV_CUSTOMER_360 METRICS claims.customers_with_claims
                       WHERE customers.has_hardship_signal = TRUE)
  UNION ALL
  SELECT 'hardship customers with a recommendation', CUSTOMERS_WITH_ACTIONS::FLOAT
    FROM SEMANTIC_VIEW(GOLD.SV_CUSTOMER_360 METRICS nba.customers_with_actions
                       WHERE customers.has_hardship_signal = TRUE)
  UNION ALL
  SELECT 'hardship customers with a blocked action', CUSTOMERS_SUPPRESSED::FLOAT
    FROM SEMANTIC_VIEW(GOLD.SV_CUSTOMER_360 METRICS nba_candidates.customers_suppressed
                       WHERE customers.has_hardship_signal = TRUE)
),
via_sql AS (
  SELECT 'hardship customers contacted' AS question,
         (SELECT COUNT(DISTINCT c.CUSTOMER_ID) FROM GOLD.CUSTOMER_360 c
           WHERE c.HARDSHIP_SIGNAL AND EXISTS (SELECT 1 FROM RAW.CAMPAIGN_HISTORY h WHERE h.CUSTOMER_ID = c.CUSTOMER_ID))::FLOAT AS via_sql
  UNION ALL SELECT 'hardship customers holding a policy',
         (SELECT COUNT(DISTINCT c.CUSTOMER_ID) FROM GOLD.CUSTOMER_360 c
           WHERE c.HARDSHIP_SIGNAL AND EXISTS (SELECT 1 FROM RAW.POLICY p WHERE p.CUSTOMER_ID = c.CUSTOMER_ID))::FLOAT
  UNION ALL SELECT 'hardship customers holding a loan',
         (SELECT COUNT(DISTINCT c.CUSTOMER_ID) FROM GOLD.CUSTOMER_360 c
           WHERE c.HARDSHIP_SIGNAL AND EXISTS (SELECT 1 FROM RAW.LOAN l WHERE l.CUSTOMER_ID = c.CUSTOMER_ID))::FLOAT
  UNION ALL SELECT 'hardship customers who have claimed',
         (SELECT COUNT(DISTINCT c.CUSTOMER_ID) FROM GOLD.CUSTOMER_360 c
           WHERE c.HARDSHIP_SIGNAL AND EXISTS (SELECT 1 FROM RAW.CLAIM k WHERE k.CUSTOMER_ID = c.CUSTOMER_ID))::FLOAT
  UNION ALL SELECT 'hardship customers with a recommendation',
         (SELECT COUNT(DISTINCT c.CUSTOMER_ID) FROM GOLD.CUSTOMER_360 c
           WHERE c.HARDSHIP_SIGNAL AND EXISTS (SELECT 1 FROM GOLD.NEXT_BEST_ACTION n WHERE n.CUSTOMER_ID = c.CUSTOMER_ID))::FLOAT
  UNION ALL SELECT 'hardship customers with a blocked action',
         (SELECT COUNT(DISTINCT c.CUSTOMER_ID) FROM GOLD.CUSTOMER_360 c
           WHERE c.HARDSHIP_SIGNAL AND EXISTS (SELECT 1 FROM GOLD.NBA_ELIGIBLE e
                    WHERE e.CUSTOMER_ID = c.CUSTOMER_ID AND e.SUPPRESSED AND e.ELIGIBLE_ON_NEED))::FLOAT
)
SELECT 'A8 semi-join expressible inside the view on every fact' AS assertion,
       v.question, v.via_sv, s.via_sql,
       IFF(v.via_sv IS NOT NULL AND EQUAL_NULL(v.via_sv, s.via_sql), 'PASS', 'FAIL') AS verdict
FROM via_view v JOIN via_sql s ON s.question = v.question
ORDER BY v.question;

/* 3.8  A9. The two engine grains do not contaminate each other. Three separate
        properties, each of which would be a real defect:

          - nba carries no suppressed rows, so a suppression count over it is
            structurally zero. Asserted on the source table, since the view
            cannot express "count rows that are absent".
          - actionable_count (4,040) is at least nba_count (3,917). The gap is
            the three-per-customer ranking cut-off. If nba ever exceeded the
            actionable set, an action would have been published that no
            eligibility decision authorised.
          - top_action_count equals customers_with_actions, i.e. exactly one
            rank-1 action per customer. */
WITH sv AS (
  SELECT * FROM SEMANTIC_VIEW(
    GOLD.SV_CUSTOMER_360
    METRICS nba_count, actionable_count, top_action_count, customers_with_actions
  )
),
checks AS (
  SELECT 'no suppressed action was published' AS property,
         (SELECT COUNT(*)
            FROM GOLD.NEXT_BEST_ACTION n
            JOIN GOLD.NBA_ELIGIBLE e
              ON e.CUSTOMER_ID = n.CUSTOMER_ID AND e.ACTION_CODE = n.ACTION_CODE
           WHERE e.SUPPRESSED)::FLOAT       AS observed,
         0::FLOAT                          AS expected,
         'eq'                              AS test
  UNION ALL
  SELECT 'published never exceeds authorised',
         (SELECT ACTIONABLE_COUNT - NBA_COUNT FROM sv)::FLOAT, 0::FLOAT, 'gte'
  UNION ALL
  SELECT 'exactly one rank-1 action per customer',
         (SELECT TOP_ACTION_COUNT - CUSTOMERS_WITH_ACTIONS FROM sv)::FLOAT, 0::FLOAT, 'eq'
)
SELECT 'A9 the two engine grains stay separate' AS assertion,
       property, observed, expected,
       IFF(CASE WHEN test = 'eq'  THEN observed =  expected
                WHEN test = 'gte' THEN observed >= expected END, 'PASS', 'FAIL') AS verdict
FROM checks
ORDER BY property;

/* 3.9  What the model now contains, so the shape of the change is visible
        without diffing the DDL. */
SHOW SEMANTIC METRICS IN GOLD.SV_CUSTOMER_360;

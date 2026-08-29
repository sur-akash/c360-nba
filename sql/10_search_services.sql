/* ============================================================================
   10_search_services.sql  —  the retrieval layer, two services
   ----------------------------------------------------------------------------
   PROJECT_BRIEF M7 called for one Cortex Search service over transcripts. That
   is necessary but not sufficient: it can show WHAT a customer said, and it
   cannot show WHY an action is permitted. So there are two:

     APP.SEARCH_INTERACTIONS   what the customer actually said, at interaction
                               grain, filterable by customer / channel / intent
                               / sentiment / date / product
     APP.SEARCH_PRODUCT_DOCS   the rule the recommendation relies on, at CLAUSE
                               grain, citable as PRODUCT_CODE#CLAUSE_ID

   The second is what makes a recommendation defensible. An engine that says
   "offer them a Platinum card" is an opinion. An engine that says "offer them a
   Platinum card, and BNK_CARD_PLAT#ELIG-01 is the clause that says a 34-year-old
   in income band 4 qualifies" is an argument. The chunking below is designed
   around that single requirement.

   ----------------------------------------------------------------------------
   WHY A CHUNK IS A CLAUSE AND NOT 500 CHARACTERS
   ----------------------------------------------------------------------------
   Fixed-width chunking would cut an eligibility rule in half. Half a rule
   retrieved as evidence is worse than no rule: "applicants must be at least"
   is a citation that cannot be checked, and the model on the other end will
   confabulate the rest of the sentence.

   So the corpus is not generated as prose and then split. It is generated AS a
   list of clauses, using AI_COMPLETE structured output, and the chunk boundary
   is the clause boundary. Each clause is required to be self-contained: it
   restates the product it belongs to and any threshold it depends on, so it
   still means something when it arrives alone in a prompt with no neighbours.
   CHUNK_TEXT additionally carries the product name, code, line of business and
   clause reference as a header, so a retrieved chunk identifies itself.

   Fourteen clauses per product across five sections:

     ELIGIBILITY   4   age, income, tenure/KYC, credit conduct
     FEATURES      3
     EXCLUSIONS    2
     FEES          2
     DISCLOSURES   3   the IRDAI / RBI paragraphs a real document carries

   16 products x 14 = 224 chunks, each well inside the 512-token window the
   Cortex Search docs recommend regardless of the model's context length.

   The human-readable one-pager has not been thrown away: APP.PRODUCT_DOC
   renders the clauses back into a single markdown document per product, in
   section order. The document and the index are the same content at two grains.

   ----------------------------------------------------------------------------
   THE CLAUSES ARE GROUNDED IN THE CATALOGUE, NOT INVENTED
   ----------------------------------------------------------------------------
   Every numeric threshold in the prompt comes from RAW.PRODUCT_CATALOG — the
   same table M5's deterministic eligibility SQL will read. The model is told the
   numbers and instructed to state them verbatim; it is not asked to decide what
   the minimum age for a home loan should be.

   This matters more than it sounds. If the generated document said "minimum age
   25" while GOLD.ELIGIBILITY_TRACE enforced 23, then every citation the agent
   produced would be evidence AGAINST its own recommendation, and a judge who
   read both would conclude the retrieval layer was decoration. STEP 12 asserts
   the agreement rather than trusting it.

   ----------------------------------------------------------------------------
   COST, MEASURED — AND WHY THIS SCRIPT IS FREE TO RE-RUN
   ----------------------------------------------------------------------------
   Per AGENTS.md the milestone is priced as a whole before anything is spent, and
   the projection is then checked against real billing. Both columns below are
   for the whole milestone (10, 10b, 10c), not for one script:

                                             projected      measured
     16 AI_COMPLETE calls, claude-sonnet-4-5   0.6-1.1       0.630
     embeddings, interaction corpus            0.020         0.020   (396,223 tok)
     embeddings, document corpus               0.002         0.0015  ( 29,862 tok)
     serving, both services, per day resumed   0.002         0.00003
     warehouse for the two index builds        0.100         ~0.09
     10 SEARCH_PREVIEW test queries            ~0            ~0
                                            ------------  ------------
     milestone total, as designed               0.72-1.22     0.74
     plus two avoidable re-embeds paid during development     0.040
                                                          ------------
     actually spent                                          0.78

   Three things the measurement corrected, all worth carrying forward:

   1. AI_COUNT_TOKENS projected 929 input tokens per document; billing recorded
      1,793. A 1.93x undercount, which independently reproduces the 1.85x that
      brief R8 measured on the M1 generation run — and for the same structural
      reason, since the response_format schema bills as input and the counter has
      no argument to receive it. R8's factor now has two data points on two
      different models. Treat AI_COUNT_TOKENS as relative sizing only.

   2. An explicit ALTER ... REFRESH re-embeds this service's ENTIRE corpus.
      0.0198 credits a time, for zero changed rows, because the source is a view
      over a join. It was in the first draft of 10c and cost two full re-embeds
      before being isolated. Removed. See STEP 3 and 10c.

   3. Serving is far cheaper than projected — 0.00003 credits/day across both
      services, because 8 MB of indexed data is genuinely tiny. Stated plainly
      rather than inflated to justify the suspend habit: at this size the reason
      to run 10b is not the serving meter, it is that indexing behaviour on a
      joined source is not yet characterised over a full day.

   Re-running costs zero, and each of these is load-bearing for that:

     APP.PRODUCT_DOC_GEN_RAW    IF NOT EXISTS + anti-join on DOC_KEY. Paid
                                output lands once and is never regenerated.
                                This is the reproducibility boundary for the
                                document corpus, exactly as RAW.INTERACTION_GEN_RAW
                                is for the interaction corpus (brief D5).
     APP.PRODUCT_DOC_CHUNK      MERGE, never CREATE OR REPLACE TABLE. Replacing
                                the table a service reads WOULD force a full
                                refresh; updating rows in place does not.
     both search services       CREATE ... IF NOT EXISTS. To change a service
                                definition you must DROP it first, and that is
                                deliberately a manual act, since recreating one
                                re-embeds its whole corpus.
     no ALTER ... REFRESH       anywhere in 10, 10b or 10c. See point 2 above.

   TARGET_LAG is '1 day' on both, per instruction: this is a trial account, the
   source corpus is static, and an aggressive lag on a static table buys nothing
   but refresh checks — which on a joined source are not necessarily free, see
   point 2 above. AUTO_SUSPEND = 1800 is set as a backstop for serving.
   10b_suspend_search.sql is the deliberate control — RUN IT WHEN YOU FINISH A
   SESSION. It suspends indexing as well as serving, which is the part that
   matters here.

   ----------------------------------------------------------------------------
   TWO GOTCHAS THAT COST TIME IF UNDOCUMENTED
   ----------------------------------------------------------------------------
   1. TARGET_LAG must be SHORTER than the source tables' data retention, or the
      service can silently fail to see changes and need recreating. The RAW and
      CURATED tables were created with the default DATA_RETENTION_TIME_IN_DAYS = 1,
      which is EQUAL to a one-day lag, not shorter. STEP 2 raises them to 3. On
      800 KB of source data the time-travel cost of that is nil.

   2. SEARCH_PREVIEW caps its response at 300 KB where the REST and Python APIs
      allow 10 MB. Selecting BODY for ten hits of a 3,000-character transcript
      will silently return fewer rows than the limit asked for. The tests in
      STEP 13 therefore select short columns and substring the body.
   ============================================================================ */

USE ROLE COCO_BUILDER;
USE WAREHOUSE COCO_WH;
USE DATABASE C360_NBA;

SET DOC_VERSION    = 'v1';                  -- bump to regenerate the corpus under a new prompt
SET DOC_MODEL      = 'claude-sonnet-4-5';   -- chosen for register, not for facts; facts are supplied
SET BATCH_PRODUCTS = 20;                    -- caps generative spend per execution (16 products exist)

/* ----------------------------------------------------------------------------
   Guard. Mumbai hosts no text-generation model, so the generation step leaves
   the region and depends on CORTEX_ENABLED_CROSS_REGION (brief R1). Same live
   one-token probe used by 04 and 05: fail here with a clear error rather than
   part-way through the corpus. Cortex Search itself is in-region and does not
   need this.
   ---------------------------------------------------------------------------- */

SELECT AI_COMPLETE($DOC_MODEL, 'Reply with the single word: ok') AS cross_region_guard;

/* ============================================================================
   STEP 1 — THE APP SCHEMA
   ----------------------------------------------------------------------------
   First object to live here. GOLD holds the analytical layer (the semantic view
   went to GOLD.SV_CUSTOMER_360); APP holds what the application and the agent
   are pointed at.
   ============================================================================ */

CREATE SCHEMA IF NOT EXISTS APP
  COMMENT = 'Serving layer: Cortex Search services, agent, Streamlit. Nothing here may reference RAW.CUSTOMER_SEGMENT_TRUTH.';

USE SCHEMA APP;

/* ============================================================================
   STEP 2 — RETENTION, SO THE ONE-DAY LAG IS LEGAL
   ----------------------------------------------------------------------------
   See gotcha 1 in the header. Retention must exceed TARGET_LAG. Change tracking
   is also asserted explicitly: incremental refresh requires it on every
   underlying object, and a service that cannot refresh incrementally falls back
   to re-embedding everything.
   ============================================================================ */

ALTER TABLE RAW.INTERACTION                 SET DATA_RETENTION_TIME_IN_DAYS = 3, CHANGE_TRACKING = TRUE;
ALTER TABLE CURATED.INTERACTION_SIGNALS_RAW SET DATA_RETENTION_TIME_IN_DAYS = 3, CHANGE_TRACKING = TRUE;
ALTER TABLE RAW.PRODUCT_CATALOG             SET DATA_RETENTION_TIME_IN_DAYS = 3, CHANGE_TRACKING = TRUE;

/* ============================================================================
   STEP 3 — SOURCE VIEW FOR THE INTERACTION SERVICE
   ----------------------------------------------------------------------------
   The search column is RAW.INTERACTION.BODY exactly as generated — not the body
   with the subject prepended, not the summary. The thing indexed is the thing
   the customer said.

   Attributes are the six requested: CUSTOMER_ID, CHANNEL, INTENT,
   SENTIMENT_BAND, OCCURRED_AT, PRODUCT_MENTIONED. Three of them come from
   CURATED.INTERACTION_SIGNALS_GATED, which is the confidence-gated view, so the
   filters agree with what the rest of the pipeline believes rather than with the
   ungated first opinion.

   Three shaping decisions, all of which exist because a NULL is useless as a
   filter value:

   NULL -> a token, not NULL. 217 of 1,203 rows have no gated sentiment and 88
     have no gated intent (the gate did its job). Cortex Search filters match
     values; there is no @isnull. Left as NULL those rows would be unreachable
     by any sentiment filter AND indistinguishable from a filter bug. They
     become 'UNKNOWN' / 'UNCLASSIFIED', which is a fact an agent can act on.

   PRODUCT_MENTIONED is normalised. The extraction returns free text and it
     shows: 'motor insurance' (121), 'motor policy' (10), 'Signature credit
     card' (2), 'CLASSIC credit card' (1). Seventeen surface forms for nine
     products makes an equality filter a lottery. The canonical token is
     derived deterministically here; the raw string survives as
     PRODUCT_MENTIONED_RAW so nothing is lost and the normalisation can be
     audited.

   Payload columns are included generously. Per the Cortex Search cost docs, any
     change to the SOURCE QUERY SCHEMA forces a full refresh and re-embeds
     everything, so the columns M9's agent and M10's app are likely to want are
     added now while the corpus is 1,203 rows rather than later.

   Note what is absent: RAW.CUSTOMER_SEGMENT_TRUTH. The retrieval layer cannot
   see the answer key. That invariant is asserted in STEP 12.

   ----------------------------------------------------------------------------
   THE SOURCE IS A VIEW OVER A JOIN, AND THAT HAS A MEASURED PRICE
   ----------------------------------------------------------------------------
   CREATE OR REPLACE is safe here — measured, not assumed. Replacing this view
   with an unchanged definition on a re-run costs zero embedding tokens, so the
   AGENTS.md rule that re-running any script in sql/ must be free is intact. An
   earlier version of this file used CREATE VIEW IF NOT EXISTS on the strength of
   a wrong diagnosis, and it was reverted once the real culprit was isolated (an
   explicit ALTER ... REFRESH, since removed from 10c).

   What the join DOES cost is the incremental refresh path when a refresh is
   forced. Measured on this account:

     forced REFRESH of SEARCH_INTERACTIONS (view over a two-table join)
       -> 396,223 embedding tokens. The entire corpus, for zero changed rows.
     forced REFRESH of SEARCH_PRODUCT_DOCS (single MERGE-maintained table)
       -> 0 tokens.

   Both services declare a PRIMARY KEY and both report REFRESH_MODE = INCREMENTAL.
   The difference in behaviour is the join: over a single table, change tracking
   can prove nothing changed; over the join, it apparently cannot, and the service
   recomputes everything. The Cortex Search cost docs advise keeping the source
   query simple and pushing joins into ETL — this is the price of not taking that
   advice, in credits.

   The join is kept anyway, and the reason is honest rather than lazy: the six
   requested filter attributes include INTENT, SENTIMENT_BAND and
   PRODUCT_MENTIONED, which live in CURATED and are the whole point of being able
   to filter. Materialising this join into its own MERGE-maintained table would
   remove the refresh penalty and is the right move if the corpus ever starts
   changing — it is a small change, and STEP 8 already demonstrates the pattern
   for the chunk table. On a static 1,203-row corpus, with forced refreshes now
   removed from 10c, the penalty is not paid at all.

   One consequence to keep an eye on: if a FORCED refresh re-embeds everything,
   the DAILY SCHEDULED refresh may too, which would be ~0.02 credits/day for a
   corpus that never changes. Not testable within one session. Suspending indexing
   via 10b is the conservative hedge until it has been observed over a day.
   ---------------------------------------------------------------------------- */

CREATE OR REPLACE VIEW APP.V_SEARCH_INTERACTION_SOURCE
  COMMENT = 'Source query for APP.SEARCH_INTERACTIONS. Interaction grain. Free view; the service is what costs.'
AS
SELECT
  /* ---- key and search column ---- */
  i.INTERACTION_ID,
  i.BODY,

  /* ---- the six filter attributes ---- */
  i.CUSTOMER_ID,
  i.CHANNEL,
  COALESCE(s.INTENT, 'UNCLASSIFIED')                              AS INTENT,
  CASE UPPER(s.SENTIMENT_OVERALL)
    WHEN 'NEGATIVE' THEN 'NEGATIVE'
    WHEN 'MIXED'    THEN 'MIXED'
    WHEN 'NEUTRAL'  THEN 'NEUTRAL'
    WHEN 'POSITIVE' THEN 'POSITIVE'
    ELSE 'UNKNOWN'
  END                                                             AS SENTIMENT_BAND,
  i.OCCURRED_AT,
  /* Order matters: 'home insurance' must be tested before 'home', and the bare
     'card' fallback must come after the specific card names. */
  CASE
    WHEN s.PRODUCT_MENTIONED IS NULL                          THEN 'UNKNOWN'
    WHEN s.PRODUCT_MENTIONED ILIKE '%personal loan%'          THEN 'PERSONAL_LOAN'
    WHEN s.PRODUCT_MENTIONED ILIKE '%auto loan%'
      OR s.PRODUCT_MENTIONED ILIKE '%car loan%'               THEN 'AUTO_LOAN'
    WHEN s.PRODUCT_MENTIONED ILIKE '%home loan%'              THEN 'HOME_LOAN'
    WHEN s.PRODUCT_MENTIONED ILIKE '%home insurance%'
      OR s.PRODUCT_MENTIONED ILIKE '%home cover%'
      OR s.PRODUCT_MENTIONED ILIKE '%property insurance%'     THEN 'HOME_INSURANCE'
    WHEN s.PRODUCT_MENTIONED ILIKE '%motor%'
      OR s.PRODUCT_MENTIONED ILIKE '%vehicle%'                THEN 'MOTOR_INSURANCE'
    WHEN s.PRODUCT_MENTIONED ILIKE '%health%'
      OR s.PRODUCT_MENTIONED ILIKE '%mediclaim%'              THEN 'HEALTH_INSURANCE'
    WHEN s.PRODUCT_MENTIONED ILIKE '%term%'                   THEN 'TERM_LIFE'
    WHEN s.PRODUCT_MENTIONED ILIKE '%ulip%'
      OR s.PRODUCT_MENTIONED ILIKE '%unit linked%'
      OR s.PRODUCT_MENTIONED ILIKE '%unit-linked%'            THEN 'ULIP'
    WHEN s.PRODUCT_MENTIONED ILIKE '%savings%'                THEN 'SAVINGS_ACCOUNT'
    WHEN s.PRODUCT_MENTIONED ILIKE '%card%'                   THEN 'CREDIT_CARD'
    ELSE 'OTHER'
  END                                                             AS PRODUCT_MENTIONED,

  /* ---- payload: returned with hits, not filterable ---- */
  i.ARTEFACT_TYPE,
  i.DIRECTION,
  i.LANGUAGE_CODE,
  i.SOURCE_KIND,
  i.SUBJECT,
  i.BODY_CHARS,
  s.SUMMARY_25W,
  s.SENTIMENT_SCORE,
  s.INTENT_CONF,
  s.PRODUCT_MENTIONED                                             AS PRODUCT_MENTIONED_RAW,
  s.COMPLAINT,
  s.CHURN_RISK_MENTIONED,
  s.CHURN_CROSSCHECK_AGREES,
  s.HARDSHIP_SIGNAL,
  s.LIFE_EVENT,
  s.CONSENT_WITHDRAWAL,
  s.COMPETITOR_MENTIONED,
  s.COMPETITOR_NAME,
  s.AMOUNT_DISCUSSED_INR,
  s.PROMISED_CALLBACK_DATE
FROM RAW.INTERACTION i
LEFT JOIN CURATED.INTERACTION_SIGNALS_GATED s
       ON s.INTERACTION_ID = i.INTERACTION_ID;

/* ============================================================================
   STEP 4 — APP.SEARCH_INTERACTIONS
   ----------------------------------------------------------------------------
   EMBEDDING_MODEL = snowflake-arctic-embed-l-v2.0-8k, not the -l-v2.0 default
   of this project's other choices. Both are 1024-dimensional and both are
   in-region in AWS_AP_SOUTH_1; they differ in context window, 512 tokens
   against 8192. Measured against the corpus with COUNT_TOKENS: bodies average
   329 tokens and reach 758, and 77 of the 1,203 rows (6.4%) exceed 512 tokens.
   Those 77 would be SILENTLY TRUNCATED by the 512-token model — losing the end
   of every long transcript, which is exactly where a call resolves and where the
   commitments get made. The -8k model indexes them whole.

   That is not a free win, and STEP 14 measures the price with verbatim quotes
   from two long transcripts' tails: one is retrieved at rank 1, the other at
   rank 9. A 700-token call compressed into a single vector is topically vaguer
   than a 200-token email, so completeness of indexing does not buy sharpness of
   ranking. The honest position is that this service is at interaction grain
   because citations must point at an interaction, and interaction grain costs
   precision on long documents.

   PRIMARY KEY (INTERACTION_ID) buys the optimised refresh path — refreshes
   process only changed rows instead of re-embedding the corpus. TEXT type, as
   required.

   IF NOT EXISTS: see the header. Re-running this file must cost nothing.
   ============================================================================ */

CREATE CORTEX SEARCH SERVICE IF NOT EXISTS APP.SEARCH_INTERACTIONS
  ON BODY
  PRIMARY KEY (INTERACTION_ID)
  ATTRIBUTES CUSTOMER_ID, CHANNEL, INTENT, SENTIMENT_BAND, OCCURRED_AT, PRODUCT_MENTIONED
  WAREHOUSE = COCO_WH
  TARGET_LAG = '1 day'
  EMBEDDING_MODEL = 'snowflake-arctic-embed-l-v2.0-8k'
  AUTO_SUSPEND = 1800
  COMMENT = 'What the customer said. Interaction grain, 1,203 artefacts incl. transcribed audio. Filter on customer_id, channel, intent, sentiment_band, occurred_at, product_mentioned. TARGET_LAG 1 day deliberately: static corpus on a trial account. SUSPEND WHEN NOT IN USE (sql/10b).'
AS
SELECT * FROM APP.V_SEARCH_INTERACTION_SOURCE;

/* ============================================================================
   STEP 5 — THE DOCUMENT PLAN  (free, deterministic, CREATE OR REPLACE)
   ----------------------------------------------------------------------------
   One row per product, carrying the fully built prompt. Same three-table shape
   as 04: PLAN is free and rebuildable, GEN_RAW is paid and permanent, everything
   downstream is a view or a cheap MERGE.

   The prompt does three things:

     1. Hands over every threshold from RAW.PRODUCT_CATALOG as a fact to be
        restated, including the income band rank rendered as the actual rupee
        band a reader would recognise (rank 3 -> "8-15L").
     2. Names the regulatory furniture the document must carry, specialised by
        line of business and product family, so the DISCLOSURES clauses cite
        IRDAI free-look and Section 45 for an insurance product and the RBI Key
        Fact Statement and penal-charge rules for a loan — rather than a generic
        "terms and conditions apply".
     3. Fixes the clause count per section, so the chunk count is known before
        the spend and the flatten is a join rather than a guess.

   temperature 0.2, NOT the 0.9 used in 04. Brief D5's argument for high
   temperature is about corpus diversity making the downstream classifier
   benchmark honest. It does not transfer: a document whose job is to state a
   threshold precisely wants the least creative model behaviour available. The
   variety here comes from 16 genuinely different products, not from sampling.
   ============================================================================ */

CREATE OR REPLACE TABLE APP.PRODUCT_DOC_PLAN (
  DOC_KEY       VARCHAR(64)   NOT NULL,   -- product + doc version
  PRODUCT_CODE  VARCHAR(32)   NOT NULL,
  DOC_VERSION   VARCHAR(8)    NOT NULL,
  CLAUSE_QUOTA  NUMBER(3,0)   NOT NULL,
  PROMPT        VARCHAR       NOT NULL,
  LOAD_TS       TIMESTAMP_NTZ NOT NULL
)
COMMENT = 'One row per product document to be generated. Pure SQL, no AI, free to rebuild.';

INSERT INTO APP.PRODUCT_DOC_PLAN
WITH cat AS (
  SELECT
    p.*,
    CASE p.MIN_INCOME_BAND_RANK
      WHEN 1 THEN 'band 1 (annual income up to INR 3 lakh)'
      WHEN 2 THEN 'band 2 (annual income INR 3-8 lakh)'
      WHEN 3 THEN 'band 3 (annual income INR 8-15 lakh)'
      WHEN 4 THEN 'band 4 (annual income INR 15-30 lakh)'
      WHEN 5 THEN 'band 5 (annual income above INR 30 lakh)'
    END AS income_band_text
  FROM RAW.PRODUCT_CATALOG p
),
reg AS (
  SELECT
    c.*,
    /* The regulatory register, per family. This is the difference between a
       plausible document and a citable one. */
    CASE
      WHEN c.PRODUCT_CODE = 'SVC_HARDSHIP' THEN
           'This is a SERVICE ACTION, not a sale: a hardship and restructure review. It is never '
        || 'sold, carries no premium and no margin, and is available to every customer including '
        || 'those flagged as vulnerable and those in arrears. Ground the disclosures in the RBI '
        || 'framework for resolution of stressed personal loans, the RBI Fair Practices Code, the '
        || 'requirement to obtain the borrower''s consent, the fact that a restructure is reported '
        || 'to credit information companies and how that affects the credit report, and the RBI '
        || 'recovery-agent conduct norms. The FEES clauses must state plainly that no fee is '
        || 'charged for the review itself and describe what the review consists of.'
      WHEN c.PRODUCT_FAMILY = 'HEALTH' THEN
           'Ground the disclosures in IRDAI regulation for health indemnity cover: the 30-day free '
        || 'look period, the 30-day initial waiting period, the pre-existing disease waiting period '
        || 'capped at 36 months, specified-disease waiting periods, the 60-month moratorium after '
        || 'which a claim cannot be contested except for established fraud, cashless authorisation '
        || 'within one hour of request and final discharge authorisation within three hours per the '
        || 'IRDAI master circular on health insurance, portability of credits, lifetime renewability, '
        || 'grievance redressal through the Bima Bharosa portal and the Insurance Ombudsman, and GST '
        || 'at 18 percent on premium. Exclusions should be real ones: cosmetic treatment, '
        || 'self-inflicted injury, non-allopathic treatment outside the listed exceptions, room-rent '
        || 'and co-payment limits.'
      WHEN c.PRODUCT_FAMILY = 'TERM' THEN
           'Ground the disclosures in IRDAI regulation for pure protection life cover: the 30-day '
        || 'free look period, the 30-day grace period for annual premium, the suicide exclusion in '
        || 'the first 12 months with return of premiums paid, Section 45 of the Insurance Act 1938 '
        || 'under which a policy cannot be called in question after three years, Section 39 nomination '
        || 'and the assignment provisions, medical underwriting above the stated sum assured, '
        || 'grievance redressal through Bima Bharosa and the Insurance Ombudsman, and GST at 18 '
        || 'percent on premium. Exclusions should be real ones: material non-disclosure of tobacco '
        || 'use or occupation, death from a pre-existing condition not declared, hazardous pursuits.'
      WHEN c.PRODUCT_FAMILY = 'ULIP' THEN
           'Ground the disclosures in IRDAI regulation for unit linked products, and be explicit '
        || 'about risk: the mandatory statement that unit linked insurance products are different '
        || 'from traditional insurance products and are subject to market risk, that the premium '
        || 'paid in a unit linked policy is subject to investment risk associated with capital '
        || 'markets and the NAV may go up or down based on fund performance, the FIVE-YEAR LOCK-IN '
        || 'with no liquidity during that period, discontinuance and revival terms, the benefit '
        || 'illustration at 4 percent and 8 percent gross investment return, fund management charge, '
        || 'premium allocation charge, policy administration charge and mortality charge, the '
        || 'suitability assessment, the 30-day free look period, and grievance redressal through '
        || 'Bima Bharosa and the Insurance Ombudsman.'
      WHEN c.PRODUCT_FAMILY = 'MOTOR' THEN
           'Ground the disclosures in IRDAI regulation and the Motor Vehicles Act 1988: third-party '
        || 'liability cover is compulsory under Section 146 and driving without it is an offence, '
        || 'Insured Declared Value and how it is arrived at, the depreciation grid applied to parts, '
        || 'the compulsory deductible, No Claim Bonus and how a claim forfeits it, transfer of NCB '
        || 'on change of insurer, the 30-day free look period where applicable, personal accident '
        || 'cover for the owner-driver, grievance redressal through Bima Bharosa and the Insurance '
        || 'Ombudsman, and GST at 18 percent. Exclusions should be real ones: driving without a '
        || 'valid licence, under the influence of alcohol, consequential loss, wear and tear, '
        || 'mechanical breakdown, use outside the stated geographical area.'
      WHEN c.PRODUCT_FAMILY = 'HOME' THEN
           'Ground the disclosures in IRDAI regulation for property cover: the sum insured basis '
        || 'and whether it is reinstatement value or indemnity, underinsurance and the average '
        || 'clause, the 30-day free look period, assignment of the policy to the lender where the '
        || 'cover is attached to a home loan and what happens to the cover if the loan is repaid or '
        || 'transferred, claim intimation timelines and surveyor appointment, grievance redressal '
        || 'through Bima Bharosa and the Insurance Ombudsman, and GST at 18 percent. Exclusions '
        || 'should be real ones: wear and tear, gradual deterioration, unoccupied premises beyond '
        || 'the stated period, loss of cash beyond sub-limits, terrorism where not opted.'
      WHEN c.PRODUCT_FAMILY = 'CARD' THEN
           'Ground the disclosures in the RBI Master Direction on Credit Card and Debit Card issuance '
        || 'and conduct: the Most Important Terms and Conditions document, the billing cycle and the '
        || 'interest-free period, that paying only the minimum amount due will extend repayment for '
        || 'years and attract finance charges on the whole outstanding, that the credit limit cannot '
        || 'be increased without the cardholder''s explicit consent, closure of the account within '
        || 'seven working days of a request, reporting to credit information companies including '
        || 'CIBIL, penal charges levied as charges and not capitalised as interest, and GST at 18 '
        || 'percent on fees and interest. Exclusions should be real ones: cash withdrawal treated '
        || 'differently from purchases with no interest-free period, transactions in breach of FEMA, '
        || 'reward points not accruing on fuel, rent, wallet loads or government payments.'
      ELSE  /* LOAN family: home, auto, personal */
           'Ground the disclosures in RBI regulation for retail lending: the Key Fact Statement that '
        || 'must be given to the borrower before sanction and the all-inclusive Annual Percentage '
        || 'Rate disclosed in it, the RBI Fair Practices Code, penal charges levied as charges and '
        || 'not as penal interest and not capitalised, no prepayment or foreclosure charge on a '
        || 'floating-rate loan to an individual borrower, reporting of repayment conduct to credit '
        || 'information companies including CIBIL and the effect of days-past-due on the credit '
        || 'report, SMA classification, the recovery-agent conduct norms, return of original property '
        || 'documents within 30 days of closure, and consent for processing personal data under the '
        || 'Digital Personal Data Protection Act 2023. Exclusions should be real ones about what the '
        || 'facility may not be used for and what voids the sanction.'
    END AS reg_block
  FROM cat c
)
SELECT
  r.PRODUCT_CODE || '|' || $DOC_VERSION                     AS DOC_KEY,
  r.PRODUCT_CODE,
  $DOC_VERSION                                              AS DOC_VERSION,
  14                                                        AS CLAUSE_QUOTA,

     'You are the product governance team at Aarohan, an Indian financial services group that '
  || 'writes both insurance and lending business. Write the customer-facing product document for '
  || 'ONE product, as a set of numbered clauses.'

  || CHR(10) || CHR(10) || 'THE PRODUCT' || CHR(10)
  || '  Name              ' || r.PRODUCT_NAME
  || CHR(10) || '  Internal code     ' || r.PRODUCT_CODE
  || CHR(10) || '  Line of business  ' || r.LINE_OF_BUSINESS
  || CHR(10) || '  Family / type     ' || r.PRODUCT_FAMILY || ' / ' || r.PRODUCT_TYPE
  || CHR(10) || '  Typical size      INR ' || TO_VARCHAR(r.AVG_TICKET_SIZE_INR, '999,999,999')
       || CASE WHEN r.LINE_OF_BUSINESS = 'INSURANCE' THEN ' annual premium' ELSE ' facility amount' END
  || CHR(10) || '  Sellable          ' || IFF(r.IS_SELLABLE, 'yes', 'NO - service action only')

  /* ---------- the thresholds, to be restated verbatim ---------- */
  || CHR(10) || CHR(10)
  || 'ELIGIBILITY RULES YOU MUST STATE EXACTLY AS GIVEN. These are the rules our systems '
  || 'actually enforce. Do not round them, soften them, add to them or invent any threshold '
  || 'that is not here.' || CHR(10)
  || '  Minimum age                 ' || r.MIN_AGE::VARCHAR || ' years' || CHR(10)
  || '  Maximum age at entry        ' || r.MAX_AGE::VARCHAR || ' years' || CHR(10)
  || '  Minimum income             ' || r.income_band_text || CHR(10)
  || '  Minimum relationship tenure ' || r.MIN_TENURE_MONTHS::VARCHAR || ' months with the group' || CHR(10)
  || '  KYC status required         ' || r.REQUIRED_KYC_STATUS || CHR(10)
  || '  Maximum days past due       '
       || CASE WHEN r.MAX_DPD_DAYS >= 9999 THEN 'no limit; arrears do not bar this action'
               WHEN r.MAX_DPD_DAYS = 0     THEN '0 days - the applicant must be fully current, any live arrears bar the application'
               ELSE r.MAX_DPD_DAYS::VARCHAR || ' days across all group obligations' END || CHR(10)
  || '  Customers flagged vulnerable '
       || IFF(r.ALLOWED_FOR_VULNERABLE,
              'MAY be offered this, with the additional care described below',
              'MUST NOT be offered this product; it is withheld from customers our vulnerability '
              || 'assessment has flagged, and that is a firm rule rather than a preference')
  || CHR(10) || '  Underwriting notes on file  ' || r.ELIGIBILITY_NOTES

  /* ---------- regulatory register ---------- */
  || CHR(10) || CHR(10) || 'REGULATORY CONTENT' || CHR(10) || '  ' || r.reg_block

  /* ---------- shape ---------- */
  || CHR(10) || CHR(10) || 'STRUCTURE — exactly 14 clauses, in this distribution:' || CHR(10)
  || '  ELIGIBILITY   4 clauses. One on age, one on income and affordability, one on relationship '
  || 'tenure and KYC, one on credit conduct and arrears. Between them they must state every '
  || 'threshold listed above.' || CHR(10)
  || '  FEATURES      3 clauses. What the customer actually gets. Concrete and specific to this '
  || 'product, not marketing copy.' || CHR(10)
  || '  EXCLUSIONS    2 clauses. What is not covered or not permitted, stated as a customer would '
  || 'need to hear it before buying.' || CHR(10)
  || '  FEES          2 clauses. Charges, taxes, and what is levied when.' || CHR(10)
  || '  DISCLOSURES   3 clauses. The regulatory paragraphs from the block above, including '
  || 'grievance redressal and the cooling-off or free-look right where one exists.'

  /* ---------- the self-containment requirement ---------- */
  || CHR(10) || CHR(10) || 'HOW EACH CLAUSE MUST BE WRITTEN — this is the important instruction.'
  || CHR(10)
  || 'Every clause is retrieved and quoted ON ITS OWN, with no other clause beside it and no '
  || 'heading above it. A clause that reads "the minimum age above also applies here" or "as set '
  || 'out in clause 3" is useless when it arrives alone. Therefore:' || CHR(10)
  || '  - Name the product in full at least once in every clause. Never open with "This product" '
  || 'or "The policy" and leave the reader to guess which one.' || CHR(10)
  || '  - Restate in full any number the clause depends on. Never refer to a threshold stated in '
  || 'another clause.' || CHR(10)
  || '  - Never cross-reference another clause, section or numbered item.' || CHR(10)
  || '  - Each clause must be a COMPLETE, SELF-CONTAINED RULE that a colleague could act on and a '
  || 'customer could be shown, with no other text present.' || CHR(10)
  || '  - 55 to 80 words per clause. Plain professional Indian financial-services register. '
  || 'Rupees written as INR. No bullet points inside a clause, no markdown, no emphasis marks.'
  || CHR(10)
  || '  - The heading is a short label under 60 characters, describing that one rule.'

  || CHR(10) || CHR(10)
  || 'Return JSON only, in the form {"clauses":[{"section":"ELIGIBILITY","heading":"...","text":"..."}]}. '
  || 'section must be exactly one of ELIGIBILITY, FEATURES, EXCLUSIONS, FEES, DISCLOSURES, in '
  || 'that order, with the clause counts given above. Return exactly 14 clauses. Never return a '
  || 'null for any field; a null is rejected by the response schema and costs the whole document.'
    AS PROMPT,

  CURRENT_TIMESTAMP()                                       AS LOAD_TS
FROM reg r;

/* ============================================================================
   STEP 6 — THE PAID TABLE
   ----------------------------------------------------------------------------
   IF NOT EXISTS. This is the reproducibility boundary for the document corpus:
   committing to this table is what freezes the wording. A DOC_VERSION bump is
   the sanctioned way to regenerate, and the reconcile below discards the
   superseded generation rather than letting two versions accumulate — the same
   contract as RAW.INTERACTION_GEN_RAW in 04 (brief D5).
   ============================================================================ */

CREATE TABLE IF NOT EXISTS APP.PRODUCT_DOC_GEN_RAW (
  DOC_KEY       VARCHAR(64)   NOT NULL,
  PRODUCT_CODE  VARCHAR(32)   NOT NULL,
  DOC_VERSION   VARCHAR(8)    NOT NULL,
  GEN_MODEL     VARCHAR(40)   NOT NULL,
  RESPONSE      VARIANT,                  -- { "clauses": [ { section, heading, text } ] }
  GENERATED_AT  TIMESTAMP_NTZ NOT NULL
)
COMMENT = 'Raw AI_COMPLETE output for the product document corpus. Landed once, never regenerated for an existing DOC_KEY.';

-- Reconcile: a DOC_VERSION bump changes every DOC_KEY, and the superseded
-- generation would otherwise sit alongside the new one and double the corpus.
DELETE FROM APP.PRODUCT_DOC_GEN_RAW g
WHERE NOT EXISTS (
  SELECT 1 FROM APP.PRODUCT_DOC_PLAN p WHERE p.DOC_KEY = g.DOC_KEY
);

CREATE OR REPLACE VIEW APP.PRODUCT_DOC_PENDING AS
SELECT COUNT(*)               AS documents_pending,
       SUM(p.CLAUSE_QUOTA)    AS clauses_pending
FROM APP.PRODUCT_DOC_PLAN p
WHERE NOT EXISTS (
  SELECT 1 FROM APP.PRODUCT_DOC_GEN_RAW g WHERE g.DOC_KEY = p.DOC_KEY
);

/* ----------------------------------------------------------------------------
   Token projection. Per brief R8 this is RELATIVE sizing only: AI_COUNT_TOKENS
   counts input, cannot be given the response_format schema that also bills as
   input, rejects the claude-4-x families (hence the llama3.3-70b proxy), and
   undercounted by 1.85x on the M1 generation run. The real gate is the measured
   pilot in CORTEX_AI_FUNCTIONS_USAGE_HISTORY, read afterwards on the coco_admin
   connection. This number is here to catch a runaway prompt, not to authorise
   the batch.
   ---------------------------------------------------------------------------- */

SELECT 'token projection'                                              AS metric,
       COUNT(*)                                                        AS documents,
       SUM(CLAUSE_QUOTA)                                               AS clauses,
       ROUND(AVG(AI_COUNT_TOKENS('ai_complete','llama3.3-70b', PROMPT))) AS avg_input_tokens,
       SUM(AI_COUNT_TOKENS('ai_complete','llama3.3-70b', PROMPT))      AS total_input_tokens_floor
FROM APP.PRODUCT_DOC_PLAN;

/* ============================================================================
   STEP 7 — GENERATE  (the only step in this file that costs generative credits)
   ============================================================================ */

INSERT INTO APP.PRODUCT_DOC_GEN_RAW (DOC_KEY, PRODUCT_CODE, DOC_VERSION, GEN_MODEL, RESPONSE, GENERATED_AT)
WITH todo AS (
  SELECT p.DOC_KEY, p.PRODUCT_CODE, p.DOC_VERSION, p.PROMPT
  FROM APP.PRODUCT_DOC_PLAN p
  WHERE NOT EXISTS (
    SELECT 1 FROM APP.PRODUCT_DOC_GEN_RAW g WHERE g.DOC_KEY = p.DOC_KEY
  )
  ORDER BY p.DOC_KEY
  LIMIT $BATCH_PRODUCTS
)
SELECT
  t.DOC_KEY,
  t.PRODUCT_CODE,
  t.DOC_VERSION,
  $DOC_MODEL,
  AI_COMPLETE(
    model            => $DOC_MODEL,
    prompt           => t.PROMPT,
    model_parameters => { 'temperature': 0.2, 'max_tokens': 4096 },
    response_format  => {
      'type': 'json',
      'schema': {
        'type': 'object',
        'properties': {
          'clauses': {
            'type': 'array',
            'items': {
              'type': 'object',
              'properties': {
                'section': { 'type': 'string', 'description': 'exactly one of ELIGIBILITY, FEATURES, EXCLUSIONS, FEES, DISCLOSURES' },
                'heading': { 'type': 'string', 'description': 'short label for this one rule, under 60 characters' },
                'text':    { 'type': 'string', 'description': 'the complete self-contained rule, 55-80 words, naming the product in full' }
              },
              'required': ['section','heading','text']
            }
          }
        },
        'required': ['clauses']
      }
    }
  ),
  CURRENT_TIMESTAMP()
FROM todo t;

/* ----------------------------------------------------------------------------
   Self-healing, as in 04 and 05. AI_COMPLETE returns NULL on a per-row failure
   rather than raising, so a failed document would be recorded as done and leave
   a permanent hole that no amount of re-running would fill. Deleting failures
   here puts them back in the queue for the next execution.

   Short documents go too: a document that came back with fewer clauses than its
   quota would produce a product with no FEES section, and a retrieval layer with
   a hole in it fails silently — the agent simply never cites that rule and
   nobody notices.
   ---------------------------------------------------------------------------- */

SELECT 'generation failures' AS check_name,
       g.PRODUCT_CODE,
       COALESCE(ARRAY_SIZE(g.RESPONSE:clauses), 0) AS clauses_returned,
       p.CLAUSE_QUOTA
FROM APP.PRODUCT_DOC_GEN_RAW g
JOIN APP.PRODUCT_DOC_PLAN p ON p.DOC_KEY = g.DOC_KEY
WHERE g.RESPONSE IS NULL
   OR COALESCE(ARRAY_SIZE(g.RESPONSE:clauses), 0) < p.CLAUSE_QUOTA;

DELETE FROM APP.PRODUCT_DOC_GEN_RAW
WHERE DOC_KEY IN (
  SELECT g.DOC_KEY
  FROM APP.PRODUCT_DOC_GEN_RAW g
  JOIN APP.PRODUCT_DOC_PLAN p ON p.DOC_KEY = g.DOC_KEY
  WHERE g.RESPONSE IS NULL
     OR COALESCE(ARRAY_SIZE(g.RESPONSE:clauses), 0) < p.CLAUSE_QUOTA
);

SELECT 'documents outstanding' AS check_name, * FROM APP.PRODUCT_DOC_PENDING;

/* ============================================================================
   STEP 8 — CLAUSES  (free view over the paid table)
   ----------------------------------------------------------------------------
   CLAUSE_ID is assigned HERE, in SQL, from the array position — not by the
   model. Asking a model for stable identifiers invites duplicates and gaps, and
   a citation key that is not unique is not a citation key. Section prefix plus
   a two-digit ordinal within the section gives ELIG-01 .. DISC-03.

   CHUNK_TEXT is what gets embedded and searched. Its header exists so a chunk
   arriving alone in an LLM prompt announces which product and which clause it
   is, without the caller having to plumb the attribute columns through.

   CREATE OR REPLACE is free here. No search service reads this view —
   SEARCH_PRODUCT_DOCS reads the MERGE-maintained APP.PRODUCT_DOC_CHUNK table
   below — so replacing it cannot trigger a refresh at all. The table beneath it
   is the object that must never be replaced.
   ============================================================================ */

CREATE OR REPLACE VIEW APP.V_PRODUCT_DOC_CLAUSE
  COMMENT = 'Generated documents flattened to one row per clause. The chunk boundary is the clause boundary.'
AS
WITH flat AS (
  SELECT
    g.PRODUCT_CODE,
    g.DOC_VERSION,
    g.GEN_MODEL,
    c.index                                     AS ORD,
    UPPER(TRIM(c.value:section::VARCHAR))       AS SECTION_RAW,
    TRIM(c.value:heading::VARCHAR)              AS CLAUSE_HEADING,
    TRIM(c.value:text::VARCHAR)                 AS CLAUSE_TEXT
  FROM APP.PRODUCT_DOC_GEN_RAW g,
       LATERAL FLATTEN(input => g.RESPONSE:clauses) c
),
sect AS (
  SELECT
    f.*,
    CASE WHEN f.SECTION_RAW IN ('ELIGIBILITY','FEATURES','EXCLUSIONS','FEES','DISCLOSURES')
         THEN f.SECTION_RAW ELSE 'OTHER' END    AS SECTION
  FROM flat f
),
numbered AS (
  SELECT
    s.*,
    CASE s.SECTION
      WHEN 'ELIGIBILITY' THEN 1 WHEN 'FEATURES' THEN 2 WHEN 'EXCLUSIONS' THEN 3
      WHEN 'FEES'        THEN 4 WHEN 'DISCLOSURES' THEN 5 ELSE 6 END        AS SECTION_ORDER,
    CASE s.SECTION
      WHEN 'ELIGIBILITY' THEN 'ELIG' WHEN 'FEATURES' THEN 'FEAT' WHEN 'EXCLUSIONS' THEN 'EXCL'
      WHEN 'FEES'        THEN 'FEES' WHEN 'DISCLOSURES' THEN 'DISC' ELSE 'MISC' END AS SECTION_PREFIX,
    ROW_NUMBER() OVER (PARTITION BY s.PRODUCT_CODE, s.SECTION ORDER BY s.ORD)       AS SECTION_SEQ
  FROM sect s
)
SELECT
  n.PRODUCT_CODE || '#' || n.SECTION_PREFIX || '-' || LPAD(n.SECTION_SEQ, 2, '0')  AS CHUNK_ID,
  n.SECTION_PREFIX || '-' || LPAD(n.SECTION_SEQ, 2, '0')                           AS CLAUSE_ID,
  n.PRODUCT_CODE,
  p.PRODUCT_NAME,
  p.LINE_OF_BUSINESS,
  p.PRODUCT_FAMILY,
  p.PRODUCT_TYPE,
  n.SECTION,
  n.SECTION_ORDER,
  n.SECTION_SEQ,
  n.CLAUSE_HEADING,
  n.CLAUSE_TEXT,

  /* The embedded text. Header first so an isolated chunk identifies itself. */
  p.PRODUCT_NAME || ' (' || n.PRODUCT_CODE || ') — '
    || INITCAP(p.LINE_OF_BUSINESS) || ' / ' || INITCAP(p.PRODUCT_FAMILY) || CHR(10)
    || n.SECTION || ' clause ' || n.SECTION_PREFIX || '-' || LPAD(n.SECTION_SEQ, 2, '0')
    || ': ' || n.CLAUSE_HEADING || CHR(10) || CHR(10)
    || n.CLAUSE_TEXT                                                               AS CHUNK_TEXT,

  /* Filterable facts, as text, because Cortex Search attribute equality is
     TEXT or NUMERIC and a BOOLEAN attribute is not filterable. */
  IFF(p.IS_SELLABLE, 'YES', 'NO')                                                  AS SELLABLE,
  IFF(p.ALLOWED_FOR_VULNERABLE, 'YES', 'NO')                                       AS VULNERABLE_ALLOWED,

  /* Machine thresholds as payload. Deliberately NOT appended to CHUNK_TEXT: the
     same threshold block on all 14 clauses of a product would make its chunks
     near-identical to the embedding model and destroy within-product ranking. */
  p.MIN_AGE,
  p.MAX_AGE,
  p.MIN_INCOME_BAND_RANK,
  p.MIN_TENURE_MONTHS,
  p.REQUIRED_KYC_STATUS,
  p.MAX_DPD_DAYS,
  p.MARGIN_RATE,
  p.AVG_TICKET_SIZE_INR,
  n.DOC_VERSION,
  n.GEN_MODEL
FROM numbered n
JOIN RAW.PRODUCT_CATALOG p ON p.PRODUCT_CODE = n.PRODUCT_CODE;

/* ----------------------------------------------------------------------------
   Materialised because the search service indexes it. A view containing
   LATERAL FLATTEN is not a reliable base for incremental refresh, and the
   difference between incremental and full refresh here is the difference
   between re-embedding nothing and re-embedding 224 chunks on every change.

   MERGE rather than CREATE OR REPLACE: replacing the table changes its identity
   and forces the service into a full refresh, which the cost docs call out
   explicitly. 224 rows of MERGE is free.
   ---------------------------------------------------------------------------- */

CREATE TABLE IF NOT EXISTS APP.PRODUCT_DOC_CHUNK (
  CHUNK_ID              VARCHAR(80)   NOT NULL,   -- PRODUCT_CODE#CLAUSE_ID; this is the citation
  CLAUSE_ID             VARCHAR(16)   NOT NULL,
  PRODUCT_CODE          VARCHAR(32)   NOT NULL,
  PRODUCT_NAME          VARCHAR(120)  NOT NULL,
  LINE_OF_BUSINESS      VARCHAR(16)   NOT NULL,
  PRODUCT_FAMILY        VARCHAR(24)   NOT NULL,
  PRODUCT_TYPE          VARCHAR(24)   NOT NULL,
  SECTION               VARCHAR(16)   NOT NULL,
  SECTION_ORDER         NUMBER(2,0)   NOT NULL,
  SECTION_SEQ           NUMBER(2,0)   NOT NULL,
  CLAUSE_HEADING        VARCHAR(300),
  CLAUSE_TEXT           VARCHAR,
  CHUNK_TEXT            VARCHAR       NOT NULL,
  SELLABLE              VARCHAR(3)    NOT NULL,
  VULNERABLE_ALLOWED    VARCHAR(3)    NOT NULL,
  MIN_AGE               NUMBER(3,0),
  MAX_AGE               NUMBER(3,0),
  MIN_INCOME_BAND_RANK  NUMBER(2,0),
  MIN_TENURE_MONTHS     NUMBER(4,0),
  REQUIRED_KYC_STATUS   VARCHAR(16),
  MAX_DPD_DAYS          NUMBER(6,0),
  MARGIN_RATE           NUMBER(6,4),
  AVG_TICKET_SIZE_INR   NUMBER(12,0),
  DOC_VERSION           VARCHAR(8)    NOT NULL,
  GEN_MODEL             VARCHAR(40)   NOT NULL,
  LOAD_TS               TIMESTAMP_NTZ NOT NULL
)
COMMENT = 'One row per product-document clause. Indexed by APP.SEARCH_PRODUCT_DOCS. CHUNK_ID is the citation key an NBA reason quotes.';

ALTER TABLE APP.PRODUCT_DOC_CHUNK SET DATA_RETENTION_TIME_IN_DAYS = 3, CHANGE_TRACKING = TRUE;

MERGE INTO APP.PRODUCT_DOC_CHUNK AS tgt
USING APP.V_PRODUCT_DOC_CLAUSE AS src
   ON tgt.CHUNK_ID = src.CHUNK_ID
WHEN MATCHED AND (tgt.CHUNK_TEXT <> src.CHUNK_TEXT OR tgt.DOC_VERSION <> src.DOC_VERSION) THEN UPDATE SET
  tgt.CLAUSE_ID = src.CLAUSE_ID, tgt.PRODUCT_NAME = src.PRODUCT_NAME,
  tgt.SECTION = src.SECTION, tgt.SECTION_ORDER = src.SECTION_ORDER, tgt.SECTION_SEQ = src.SECTION_SEQ,
  tgt.CLAUSE_HEADING = src.CLAUSE_HEADING, tgt.CLAUSE_TEXT = src.CLAUSE_TEXT,
  tgt.CHUNK_TEXT = src.CHUNK_TEXT, tgt.SELLABLE = src.SELLABLE,
  tgt.VULNERABLE_ALLOWED = src.VULNERABLE_ALLOWED,
  tgt.DOC_VERSION = src.DOC_VERSION, tgt.GEN_MODEL = src.GEN_MODEL,
  tgt.LOAD_TS = CURRENT_TIMESTAMP()
WHEN NOT MATCHED THEN INSERT
  (CHUNK_ID, CLAUSE_ID, PRODUCT_CODE, PRODUCT_NAME, LINE_OF_BUSINESS, PRODUCT_FAMILY, PRODUCT_TYPE,
   SECTION, SECTION_ORDER, SECTION_SEQ, CLAUSE_HEADING, CLAUSE_TEXT, CHUNK_TEXT,
   SELLABLE, VULNERABLE_ALLOWED, MIN_AGE, MAX_AGE, MIN_INCOME_BAND_RANK, MIN_TENURE_MONTHS,
   REQUIRED_KYC_STATUS, MAX_DPD_DAYS, MARGIN_RATE, AVG_TICKET_SIZE_INR, DOC_VERSION, GEN_MODEL, LOAD_TS)
  VALUES
  (src.CHUNK_ID, src.CLAUSE_ID, src.PRODUCT_CODE, src.PRODUCT_NAME, src.LINE_OF_BUSINESS,
   src.PRODUCT_FAMILY, src.PRODUCT_TYPE, src.SECTION, src.SECTION_ORDER, src.SECTION_SEQ,
   src.CLAUSE_HEADING, src.CLAUSE_TEXT, src.CHUNK_TEXT, src.SELLABLE, src.VULNERABLE_ALLOWED,
   src.MIN_AGE, src.MAX_AGE, src.MIN_INCOME_BAND_RANK, src.MIN_TENURE_MONTHS,
   src.REQUIRED_KYC_STATUS, src.MAX_DPD_DAYS, src.MARGIN_RATE, src.AVG_TICKET_SIZE_INR,
   src.DOC_VERSION, src.GEN_MODEL, CURRENT_TIMESTAMP());

-- A chunk whose clause no longer exists (regeneration produced fewer clauses in
-- a section) must not linger as an orphan citation target.
DELETE FROM APP.PRODUCT_DOC_CHUNK t
WHERE NOT EXISTS (
  SELECT 1 FROM APP.V_PRODUCT_DOC_CLAUSE v WHERE v.CHUNK_ID = t.CHUNK_ID
);

/* ----------------------------------------------------------------------------
   The one-page document, reassembled. The brief asked for a document; the index
   needs clauses. Both exist, from one generation, at no extra cost.
   ---------------------------------------------------------------------------- */

CREATE OR REPLACE VIEW APP.PRODUCT_DOC
  COMMENT = 'The human-readable one-page product document, rendered from its clauses. Same content as the index at document grain.'
AS
SELECT
  c.PRODUCT_CODE,
  c.PRODUCT_NAME,
  c.LINE_OF_BUSINESS,
  c.PRODUCT_FAMILY,
  MAX(c.DOC_VERSION)  AS DOC_VERSION,
  MAX(c.GEN_MODEL)    AS GEN_MODEL,
  COUNT(*)            AS CLAUSES,
  '# ' || c.PRODUCT_NAME || '  (' || c.PRODUCT_CODE || ')' || CHR(10)
    || '_' || INITCAP(c.LINE_OF_BUSINESS) || ' / ' || INITCAP(c.PRODUCT_FAMILY)
    || ' — Aarohan Financial Group_' || CHR(10) || CHR(10)
    || LISTAGG(
         IFF(c.SECTION_SEQ = 1, '## ' || c.SECTION || CHR(10) || CHR(10), '')
           || '**' || c.CLAUSE_ID || '  ' || c.CLAUSE_HEADING || '**' || CHR(10)
           || c.CLAUSE_TEXT,
         /* Literal, not CHR(10)||CHR(10). LISTAGG's delimiter must be a constant,
            and the concatenated form is accepted by CREATE VIEW and only fails
            when the view is queried. */
         '\n\n'
       ) WITHIN GROUP (ORDER BY c.SECTION_ORDER, c.SECTION_SEQ) AS DOC_MARKDOWN
FROM APP.PRODUCT_DOC_CHUNK c
GROUP BY c.PRODUCT_CODE, c.PRODUCT_NAME, c.LINE_OF_BUSINESS, c.PRODUCT_FAMILY;

/* ============================================================================
   STEP 9 — APP.SEARCH_PRODUCT_DOCS
   ----------------------------------------------------------------------------
   snowflake-arctic-embed-l-v2.0 here, not the -8k variant used for interactions.
   Every chunk is one clause of 55-80 words plus a two-line header, comfortably
   inside 512 tokens (STEP 12 asserts it), so the longer context window would buy
   nothing. The Snowflake research cited in the Cortex Search docs is that
   SMALLER chunks retrieve better; this service is the side of that trade-off
   where we get to choose, and the interaction service is the side where the
   grain is fixed by the citation requirement.

   ATTRIBUTES include SELLABLE and VULNERABLE_ALLOWED because the guardrail
   questions are retrieval questions too: "show me the clause that says this
   product must not be offered to a vulnerable customer" is exactly the kind of
   evidence an NBA suppression needs to be able to produce.
   ============================================================================ */

CREATE CORTEX SEARCH SERVICE IF NOT EXISTS APP.SEARCH_PRODUCT_DOCS
  ON CHUNK_TEXT
  PRIMARY KEY (CHUNK_ID)
  ATTRIBUTES PRODUCT_CODE, LINE_OF_BUSINESS, PRODUCT_FAMILY, SECTION, SELLABLE, VULNERABLE_ALLOWED
  WAREHOUSE = COCO_WH
  TARGET_LAG = '1 day'
  EMBEDDING_MODEL = 'snowflake-arctic-embed-l-v2.0'
  AUTO_SUSPEND = 1800
  COMMENT = 'Product documents at CLAUSE grain, so a recommendation can cite the rule it relied on. CHUNK_ID (PRODUCT_CODE#CLAUSE_ID) is the citation key. SUSPEND WHEN NOT IN USE (sql/10b).'
AS
SELECT
  CHUNK_ID, CHUNK_TEXT, CLAUSE_ID, PRODUCT_CODE, PRODUCT_NAME,
  LINE_OF_BUSINESS, PRODUCT_FAMILY, PRODUCT_TYPE, SECTION, CLAUSE_HEADING,
  SELLABLE, VULNERABLE_ALLOWED,
  MIN_AGE, MAX_AGE, MIN_INCOME_BAND_RANK, MIN_TENURE_MONTHS,
  REQUIRED_KYC_STATUS, MAX_DPD_DAYS, MARGIN_RATE, AVG_TICKET_SIZE_INR,
  DOC_VERSION
FROM APP.PRODUCT_DOC_CHUNK;

/* ============================================================================
   STEP 10 — WHAT WAS BUILT
   ============================================================================ */

SHOW CORTEX SEARCH SERVICES IN SCHEMA APP;

SELECT 'corpus' AS check_name,
       (SELECT COUNT(*) FROM APP.V_SEARCH_INTERACTION_SOURCE) AS interactions_indexed,
       (SELECT COUNT(*) FROM APP.PRODUCT_DOC_CHUNK)           AS clauses_indexed,
       (SELECT COUNT(*) FROM APP.PRODUCT_DOC)                 AS documents,
       (SELECT COUNT(DISTINCT PRODUCT_CODE) FROM APP.PRODUCT_DOC_CHUNK) AS products_covered,
       (SELECT COUNT(*) FROM RAW.PRODUCT_CATALOG)             AS products_in_catalogue;

/* ============================================================================
   STEP 11 — INDEXED SIZE, WHICH IS WHAT SERVING BILLS ON
   ----------------------------------------------------------------------------
   Serving is charged per GB-month of indexed data, where indexed data is the
   source-query payload plus the vectors computed on top of it. Both services use
   1024-dimensional embeddings at 4 bytes per dimension, so every row carries
   4 KB of vector whatever its text length. At this corpus size the vectors are
   the larger half of the bill.
   ============================================================================ */

WITH ix AS (
  SELECT 'SEARCH_INTERACTIONS' AS service, COUNT(*) AS rows_,
         SUM(LENGTH(BODY)) AS search_bytes,
         SUM(LENGTH(BODY)) + COUNT(*) * 1024 * 4 AS approx_indexed_bytes
  FROM APP.V_SEARCH_INTERACTION_SOURCE
  UNION ALL
  SELECT 'SEARCH_PRODUCT_DOCS', COUNT(*),
         SUM(LENGTH(CHUNK_TEXT)),
         SUM(LENGTH(CHUNK_TEXT)) + COUNT(*) * 1024 * 4
  FROM APP.PRODUCT_DOC_CHUNK
)
SELECT 'serving size' AS check_name, service, rows_,
       ROUND(search_bytes / 1024.0 / 1024, 2)          AS search_text_mb,
       ROUND(approx_indexed_bytes / 1024.0 / 1024, 2)  AS approx_indexed_mb,
       ROUND(approx_indexed_bytes / 1e9 * 6.3, 4)      AS approx_credits_per_month_resumed
FROM ix;

/* ============================================================================
   STEP 12 — INVARIANTS
   ============================================================================ */

/* 1. The quarantine. AGENTS.md: nothing outside evals/ may reference
      RAW.CUSTOMER_SEGMENT_TRUTH. An engine that can see the answer key is not
      demonstrating anything. Checked against the actual view text rather than
      by inspection. */
SELECT 'segment truth quarantine' AS check_name,
       COUNT(*) AS violations
FROM C360_NBA.INFORMATION_SCHEMA.VIEWS
WHERE TABLE_SCHEMA = 'APP'
  AND UPPER(VIEW_DEFINITION) LIKE '%CUSTOMER_SEGMENT_TRUTH%';

/* 2. Every chunk fits the embedding window. A chunk over 512 tokens is silently
      truncated by snowflake-arctic-embed-l-v2.0 and the tail of the rule stops
      being searchable — the failure mode this whole chunking scheme exists to
      avoid.

      SNOWFLAKE.CORTEX.COUNT_TOKENS, not AI_COUNT_TOKENS. The modern function
      returns NULL for an embedding model — in every argument form, two-arg and
      three-arg, with no error — and the deprecated one returns the count. That
      matters beyond style: written with AI_COUNT_TOKENS this check counted
      COUNT_IF(NULL > 512) = 0 and reported a clean pass over 224 chunks it had
      not measured. Brief R7 wants the SNOWFLAKE.CORTEX namespace retired; for
      token counting on embedding models it is currently the only one that works.

      Hence the explicit NULL assertion below. A check that cannot fail is worse
      than no check, because it is reported as evidence. */
SELECT 'chunk token budget' AS check_name,
       COUNT(*)                                                                    AS chunks,
       ROUND(AVG(SNOWFLAKE.CORTEX.COUNT_TOKENS('snowflake-arctic-embed-l-v2.0', CHUNK_TEXT))) AS avg_tokens,
       MAX(SNOWFLAKE.CORTEX.COUNT_TOKENS('snowflake-arctic-embed-l-v2.0', CHUNK_TEXT))        AS max_tokens,
       COUNT_IF(SNOWFLAKE.CORTEX.COUNT_TOKENS('snowflake-arctic-embed-l-v2.0', CHUNK_TEXT) > 512)     AS over_512_must_be_zero,
       COUNT_IF(SNOWFLAKE.CORTEX.COUNT_TOKENS('snowflake-arctic-embed-l-v2.0', CHUNK_TEXT) IS NULL)   AS uncounted_must_be_zero
FROM APP.PRODUCT_DOC_CHUNK;

/* 3. Section completeness. A product missing its FEES section has a hole the
      agent will never cite from and nobody will notice. */
SELECT 'section coverage' AS check_name, SECTION, COUNT(DISTINCT PRODUCT_CODE) AS products, COUNT(*) AS clauses
FROM APP.PRODUCT_DOC_CHUNK GROUP BY 1, 2 ORDER BY 2;

SELECT 'products with an incomplete document' AS check_name, PRODUCT_CODE, COUNT(*) AS clauses
FROM APP.PRODUCT_DOC_CHUNK GROUP BY 1, 2 HAVING COUNT(*) <> 14;

/* 4. GROUNDING. The load-bearing check in this file. Every product's ELIGIBILITY
      section must state the catalogue's own age thresholds. If the document says
      25 and GOLD enforces 23, then every citation the agent produces is evidence
      against its own recommendation.

      Digit-boundary matching, because a naive LIKE '%21%' would be satisfied by
      "INR 21,000" or by the 21 inside 121. */
WITH elig AS (
  SELECT c.PRODUCT_CODE, c.MIN_AGE, c.MAX_AGE,
         LISTAGG(c.CLAUSE_TEXT, ' ') AS elig_text
  FROM APP.PRODUCT_DOC_CHUNK c
  WHERE c.SECTION = 'ELIGIBILITY'
  GROUP BY 1, 2, 3
)
SELECT 'eligibility grounding' AS check_name,
       PRODUCT_CODE, MIN_AGE, MAX_AGE,
       REGEXP_LIKE(elig_text, '.*(^|[^0-9])' || MIN_AGE::VARCHAR || '([^0-9]|$).*') AS states_min_age,
       REGEXP_LIKE(elig_text, '.*(^|[^0-9])' || MAX_AGE::VARCHAR || '([^0-9]|$).*') AS states_max_age
FROM elig
ORDER BY states_min_age, states_max_age, PRODUCT_CODE;

/* 5. Self-containment, mechanically. A clause that cross-references another
      clause is broken as a standalone citation. This cannot be fully checked by
      predicate, but the obvious offenders can be. */
SELECT 'cross-reference leakage' AS check_name, COUNT(*) AS suspect_clauses
FROM APP.PRODUCT_DOC_CHUNK
WHERE CLAUSE_TEXT ILIKE '%as stated above%'
   OR CLAUSE_TEXT ILIKE '%see clause%'
   OR CLAUSE_TEXT ILIKE '%in the preceding%'
   OR CLAUSE_TEXT ILIKE '%as set out above%'
   OR CLAUSE_TEXT ILIKE '%mentioned above%'
   OR CLAUSE_TEXT ILIKE '%as described above%';

/* 6. Every clause names its product, so a chunk quoted alone is attributable
      even if the header is stripped. */
SELECT 'clause names its product' AS check_name,
       COUNT(*)                                                       AS clauses,
       COUNT_IF(CONTAINS(UPPER(CLAUSE_TEXT), UPPER(PRODUCT_NAME)))    AS names_product_in_full,
       ROUND(100.0 * COUNT_IF(CONTAINS(UPPER(CLAUSE_TEXT), UPPER(PRODUCT_NAME))) / COUNT(*), 1) AS pct
FROM APP.PRODUCT_DOC_CHUNK;

/* 7. Note deliberately absent: RAW.HAS_SEGMENT_LEAK is NOT applied to the
      product corpus. That predicate flags 'vulnerable', 'retention', 'churn'
      and similar, and it exists to stop a customer-attached artefact revealing
      the classification the pipeline must infer. A product document has no
      customer attached, and it MUST say "this product must not be offered to
      customers flagged as vulnerable" — that clause is the point of
      VULNERABLE_ALLOWED. Applying the interaction-corpus predicate here would
      delete the guardrail evidence. Do not "fix" this. */

/* ============================================================================
   STEP 13 — TEST QUERIES
   ----------------------------------------------------------------------------
   Five per service, run through SEARCH_PREVIEW. @scores carries the component
   scores: cosine_similarity is bounded [-1,1] and comparable across queries;
   text_match is unbounded and NOT comparable across queries. Only the former is
   worth reading as an absolute.

   Columns are kept short and the body substringed, because SEARCH_PREVIEW caps
   its response at 300 KB and silently returns fewer rows than asked for when
   the payload is large (header gotcha 2).
   ============================================================================ */

-- I1. Pure semantics: churn intent, none of these words in the query.
SELECT 'I1 competitor switch' AS q, VALUE:"@scores":cosine_similarity::FLOAT AS cosine,
       VALUE:"@scores":text_match::FLOAT AS text_match,
       VALUE:INTERACTION_ID::VARCHAR AS interaction_id, VALUE:INTENT::VARCHAR AS intent,
       VALUE:SENTIMENT_BAND::VARCHAR AS sentiment, VALUE:PRODUCT_MENTIONED::VARCHAR AS product,
       LEFT(VALUE:SUMMARY_25W::VARCHAR, 110) AS summary
FROM TABLE(FLATTEN(PARSE_JSON(SNOWFLAKE.CORTEX.SEARCH_PREVIEW('C360_NBA.APP.SEARCH_INTERACTIONS', '{
  "query": "customer says they have a cheaper quote from another insurer and will not renew with us",
  "columns": ["INTERACTION_ID","INTENT","SENTIMENT_BAND","PRODUCT_MENTIONED","SUMMARY_25W"],
  "limit": 5 }'))['results']));

-- I2. Semantics plus an attribute filter on the gated intent.
SELECT 'I2 hardship, filtered' AS q, VALUE:"@scores":cosine_similarity::FLOAT AS cosine,
       VALUE:"@scores":text_match::FLOAT AS text_match,
       VALUE:INTERACTION_ID::VARCHAR AS interaction_id, VALUE:INTENT::VARCHAR AS intent,
       VALUE:CHANNEL::VARCHAR AS channel, LEFT(VALUE:SUMMARY_25W::VARCHAR, 110) AS summary
FROM TABLE(FLATTEN(PARSE_JSON(SNOWFLAKE.CORTEX.SEARCH_PREVIEW('C360_NBA.APP.SEARCH_INTERACTIONS', '{
  "query": "lost my job, cannot pay this month EMI, need more time",
  "columns": ["INTERACTION_ID","INTENT","CHANNEL","SUMMARY_25W"],
  "filter": {"@eq": {"INTENT": "PAYMENT_DIFFICULTY_OR_DEFERRAL"}},
  "limit": 5 }'))['results']));

-- I3. Vulnerability, which is never labelled in the corpus and must be inferred
--     from behaviour. The hardest of the five.
SELECT 'I3 vulnerability signal' AS q, VALUE:"@scores":cosine_similarity::FLOAT AS cosine,
       VALUE:"@scores":text_match::FLOAT AS text_match,
       VALUE:INTERACTION_ID::VARCHAR AS interaction_id, VALUE:CUSTOMER_ID::VARCHAR AS customer_id,
       VALUE:ARTEFACT_TYPE::VARCHAR AS artefact, LEFT(VALUE:SUMMARY_25W::VARCHAR, 110) AS summary
FROM TABLE(FLATTEN(PARSE_JSON(SNOWFLAKE.CORTEX.SEARCH_PREVIEW('C360_NBA.APP.SEARCH_INTERACTIONS', '{
  "query": "elderly customer repeats the same questions and cannot manage the mobile app without help",
  "columns": ["INTERACTION_ID","CUSTOMER_ID","ARTEFACT_TYPE","SUMMARY_25W"],
  "limit": 5 }'))['results']));

-- I4. Two attribute filters composed, on a sentiment the gate assigned.
SELECT 'I4 pricing anger, negative only' AS q, VALUE:"@scores":cosine_similarity::FLOAT AS cosine,
       VALUE:"@scores":text_match::FLOAT AS text_match,
       VALUE:INTERACTION_ID::VARCHAR AS interaction_id, VALUE:SENTIMENT_BAND::VARCHAR AS sentiment,
       VALUE:PRODUCT_MENTIONED::VARCHAR AS product, LEFT(VALUE:SUMMARY_25W::VARCHAR, 110) AS summary
FROM TABLE(FLATTEN(PARSE_JSON(SNOWFLAKE.CORTEX.SEARCH_PREVIEW('C360_NBA.APP.SEARCH_INTERACTIONS', '{
  "query": "renewal premium has gone up far too much compared to last year",
  "columns": ["INTERACTION_ID","SENTIMENT_BAND","PRODUCT_MENTIONED","SUMMARY_25W"],
  "filter": {"@and": [{"@eq": {"SENTIMENT_BAND": "NEGATIVE"}}, {"@eq": {"PRODUCT_MENTIONED": "MOTOR_INSURANCE"}}]},
  "limit": 5 }'))['results']));

-- I5. Narrow operational language. Tests keyword matching rather than semantics:
--     a mandate failure is mechanical, not emotional, and must NOT come back
--     looking like hardship.
SELECT 'I5 mandate failure' AS q, VALUE:"@scores":cosine_similarity::FLOAT AS cosine,
       VALUE:"@scores":text_match::FLOAT AS text_match,
       VALUE:INTERACTION_ID::VARCHAR AS interaction_id, VALUE:INTENT::VARCHAR AS intent,
       LEFT(VALUE:SUMMARY_25W::VARCHAR, 110) AS summary
FROM TABLE(FLATTEN(PARSE_JSON(SNOWFLAKE.CORTEX.SEARCH_PREVIEW('C360_NBA.APP.SEARCH_INTERACTIONS', '{
  "query": "the auto debit NACH mandate failed at the bank and the instalment bounced",
  "columns": ["INTERACTION_ID","INTENT","SUMMARY_25W"],
  "limit": 5 }'))['results']));

-- D1. The core defensibility query: an eligibility threshold, by product.
SELECT 'D1 platinum card eligibility' AS q, VALUE:"@scores":cosine_similarity::FLOAT AS cosine,
       VALUE:"@scores":text_match::FLOAT AS text_match,
       VALUE:CHUNK_ID::VARCHAR AS citation, VALUE:SECTION::VARCHAR AS section,
       VALUE:CLAUSE_HEADING::VARCHAR AS heading
FROM TABLE(FLATTEN(PARSE_JSON(SNOWFLAKE.CORTEX.SEARCH_PREVIEW('C360_NBA.APP.SEARCH_PRODUCT_DOCS', '{
  "query": "what is the minimum age and minimum income to qualify for the platinum credit card",
  "columns": ["CHUNK_ID","SECTION","CLAUSE_HEADING"],
  "limit": 5 }'))['results']));

-- D2. Domain vocabulary the query does not spell out the same way as the doc.
SELECT 'D2 pre-existing disease wait' AS q, VALUE:"@scores":cosine_similarity::FLOAT AS cosine,
       VALUE:"@scores":text_match::FLOAT AS text_match,
       VALUE:CHUNK_ID::VARCHAR AS citation, VALUE:SECTION::VARCHAR AS section,
       VALUE:CLAUSE_HEADING::VARCHAR AS heading
FROM TABLE(FLATTEN(PARSE_JSON(SNOWFLAKE.CORTEX.SEARCH_PREVIEW('C360_NBA.APP.SEARCH_PRODUCT_DOCS', '{
  "query": "how long must a customer wait before an existing illness is covered",
  "columns": ["CHUNK_ID","SECTION","CLAUSE_HEADING"],
  "limit": 5 }'))['results']));

-- D3. The suppression clause. If the NBA engine blocks a personal loan because
--     the customer is in arrears, THIS is the clause it has to be able to quote.
SELECT 'D3 arrears bar a personal loan' AS q, VALUE:"@scores":cosine_similarity::FLOAT AS cosine,
       VALUE:"@scores":text_match::FLOAT AS text_match,
       VALUE:CHUNK_ID::VARCHAR AS citation, VALUE:MAX_DPD_DAYS::VARCHAR AS max_dpd,
       VALUE:CLAUSE_HEADING::VARCHAR AS heading
FROM TABLE(FLATTEN(PARSE_JSON(SNOWFLAKE.CORTEX.SEARCH_PREVIEW('C360_NBA.APP.SEARCH_PRODUCT_DOCS', '{
  "query": "can a customer who is behind on repayments still be given a personal loan",
  "columns": ["CHUNK_ID","MAX_DPD_DAYS","CLAUSE_HEADING"],
  "filter": {"@eq": {"PRODUCT_CODE": "BNK_LOAN_PERS"}},
  "limit": 5 }'))['results']));

-- D4. A regulatory disclosure, asked in customer words. Also the query most
--     likely to return near-duplicate clauses across 16 products, so diversity
--     is applied to hold each product to one hit.
SELECT 'D4 free look, diversified' AS q, VALUE:"@scores":cosine_similarity::FLOAT AS cosine,
       VALUE:"@scores":text_match::FLOAT AS text_match,
       VALUE:CHUNK_ID::VARCHAR AS citation, VALUE:PRODUCT_CODE::VARCHAR AS product,
       VALUE:CLAUSE_HEADING::VARCHAR AS heading
FROM TABLE(FLATTEN(PARSE_JSON(SNOWFLAKE.CORTEX.SEARCH_PREVIEW('C360_NBA.APP.SEARCH_PRODUCT_DOCS', '{
  "query": "how long do I have to change my mind and cancel after buying",
  "columns": ["CHUNK_ID","PRODUCT_CODE","CLAUSE_HEADING"],
  "scoring_config": {"diversity": {"group_by": ["PRODUCT_CODE"], "max_results": 1}},
  "limit": 5 }'))['results']));

-- D5. The vulnerability guardrail, retrieved as evidence rather than asserted.
SELECT 'D5 vulnerable customer guardrail' AS q, VALUE:"@scores":cosine_similarity::FLOAT AS cosine,
       VALUE:"@scores":text_match::FLOAT AS text_match,
       VALUE:CHUNK_ID::VARCHAR AS citation, VALUE:VULNERABLE_ALLOWED::VARCHAR AS vuln_allowed,
       VALUE:CLAUSE_HEADING::VARCHAR AS heading
FROM TABLE(FLATTEN(PARSE_JSON(SNOWFLAKE.CORTEX.SEARCH_PREVIEW('C360_NBA.APP.SEARCH_PRODUCT_DOCS', '{
  "query": "is a market linked investment plan suitable for a customer we have flagged as vulnerable",
  "columns": ["CHUNK_ID","VULNERABLE_ALLOWED","CLAUSE_HEADING"],
  "limit": 5 }'))['results']));

/* ============================================================================
   STEP 14 — WHERE RETRIEVAL IS WEAK, MEASURED
   ----------------------------------------------------------------------------
   Four weaknesses, three of them structural. All measured on 2026-08-29 against
   DOC_VERSION v1; the probes below reproduce the numbers.

   Read @scores before trusting any of this: cosine_similarity is bounded [-1,1]
   and IS comparable across queries; text_match is unbounded and is NOT. Also,
   result order is the blended reranker ranking, so cosine is not monotonic in
   rank — in the vulnerability probe below, rank 2 scores 0.439 and rank 3 scores
   0.430 while rank 4 scores 0.441. Do not read rank as a cosine ordering.

   W1  LONG DOCUMENTS DILUTE, AND THE -8k MODEL ONLY HALF FIXES IT.
       The 8k-context model prevents truncation but cannot prevent dilution: one
       vector for a 700-token multi-topic call is dominated by the call's main
       subject. Measured with verbatim quotes lifted from the last 15% of the two
       longest transcripts in the corpus:

         758-token doc, tail quote  -> retrieved at RANK 1, cosine 0.662. Works.
         688-token doc, tail quote  -> RANK 9 of 100, cosine 0.436 against a
                                       best-in-set 0.463. A near-verbatim quote
                                       from a document's own tail failed to put
                                       that document in the top five.

       The second case sits inside the renewal-dispute block (W2), so the two
       weaknesses compound: dilution costs the document its distinctiveness and
       the crowded neighbourhood gives it nothing to stand out against.

       Not fixable by model choice. The fix is chunking interactions the way the
       product docs are chunked — by turn or by topic — which would break the
       requirement that a citation point at one interaction. Deliberately not
       done; recorded instead.

   W2  THE CORPUS IS TOP-HEAVY, SO RANKING INSIDE THE BIG BLOCK IS ARBITRARY.
       503 of 1,203 artefacts (42%) are RENEWAL_PRICING_DISPUTE. Measured cosine
       across the top 20 for a renewal-flavoured query: 0.596 down to 0.546 — a
       spread of 0.051 over twenty results. Precision@5 is perfect (all five are
       genuinely on-topic) and simultaneously meaningless: rank 5 and rank 50 are
       separated by noise. An NBA that cites "the evidence" for a renewal save is
       citing an arbitrary member of a 500-strong equivalence class.

       Consequence for M6: cite the interaction the customer actually had, chosen
       by customer_id filter plus recency, and use search for the semantic hop —
       not the other way round.

   W3  ABSOLUTE SCORE THRESHOLDS DO NOT PORT ACROSS QUERY STYLES.
       Both of these returned entirely correct clauses:

         D1  "minimum age and income for the platinum credit card"  cosine 0.726
         D4  "how long do I have to change my mind and cancel"      cosine 0.403

       D1 restates the document's own vocabulary; D4 is colloquial where the
       clause says "free-look period". A relevance floor tuned on D1 — 0.6, say —
       would discard every correct answer to D4. If M9's agent gates retrieval on
       a fixed cosine, it will silently drop the colloquial half of its traffic.
       Gate on rank, or calibrate per query class.

   W4  A FILTER IS ONLY AS GOOD AS THE GATE BEHIND IT — and this one is honest
       about not knowing. 217 of 1,203 rows have SENTIMENT_BAND = 'UNKNOWN' and
       308 have PRODUCT_MENTIONED = 'UNKNOWN', because CURATED's confidence gate
       withheld a low-confidence answer. That is the right behaviour, and it
       means an agent filtering SENTIMENT_BAND = 'NEGATIVE' searches 43% of the
       corpus rather than all of it. Not a defect; a documented coverage limit
       that the caller has to know.

   AND ONE THING THAT IS NOT A RETRIEVAL WEAKNESS AT ALL, though it looks like
   one. Test query I5 ("the auto debit NACH mandate failed and the instalment
   bounced") returns duplicate-debit complaints instead — top cosine 0.52, and
   the highest text_match in the set belongs to an irrelevant payment-date-change
   request. The corpus is the reason, not the index: across 1,203 artefacts the
   words 'bounce' and 'mandate' appear once each and 'NACH'/'ECS' never, while 48
   rows discuss duplicate debits. CURATED.INTENT_TAXONOMY carries
   PAYMENT_FAILURE_OR_MANDATE_ISSUE and 24 rows are labelled with it, but their
   content is all duplicate-debit. Retrieval returned the nearest thing that
   exists. If mandate failure needs to be demonstrable, 04 has to generate it —
   no amount of index tuning will conjure it.
   ============================================================================ */

/* W1 probe. Verbatim tail quotes from the two longest transcripts. The first
   should come back at rank 1; the second should not appear at all in five. */
SELECT 'W1 tail of 758-token doc (expect IX-004685-0 at rank 1)' AS probe,
       VALUE:"@scores":cosine_similarity::FLOAT AS cosine,
       VALUE:INTERACTION_ID::VARCHAR AS interaction_id, VALUE:BODY_CHARS::NUMBER AS body_chars
FROM TABLE(FLATTEN(PARSE_JSON(SNOWFLAKE.CORTEX.SEARCH_PREVIEW('C360_NBA.APP.SEARCH_INTERACTIONS', '{
  "query": "sending your interest certificate to your email within 2 to 3 days and moving your EMI date to the 15th",
  "columns": ["INTERACTION_ID","BODY_CHARS"], "limit": 5 }'))['results']));

SELECT 'W1 tail of 688-token doc (IX-002029-2 does NOT make the top 5)' AS probe,
       VALUE:"@scores":cosine_similarity::FLOAT AS cosine,
       VALUE:INTERACTION_ID::VARCHAR AS interaction_id, VALUE:BODY_CHARS::NUMBER AS body_chars
FROM TABLE(FLATTEN(PARSE_JSON(SNOWFLAKE.CORTEX.SEARCH_PREVIEW('C360_NBA.APP.SEARCH_INTERACTIONS', '{
  "query": "if I do not hear back by the 31st I am moving to Star, senior team will contact by 31st August",
  "columns": ["INTERACTION_ID","BODY_CHARS"], "limit": 5 }'))['results']));

/* W2 probe. Cosine spread across the top 20 inside the renewal block. A spread
   this narrow means the ordering carries little information. */
WITH top20 AS (
  SELECT VALUE:"@scores":cosine_similarity::FLOAT AS cosine
  FROM TABLE(FLATTEN(PARSE_JSON(SNOWFLAKE.CORTEX.SEARCH_PREVIEW('C360_NBA.APP.SEARCH_INTERACTIONS', '{
    "query": "customer says they have a cheaper quote from another insurer and will not renew with us",
    "columns": ["INTERACTION_ID"], "limit": 20 }'))['results']))
)
SELECT 'W2 cosine spread, renewal block' AS probe, COUNT(*) AS hits,
       ROUND(MAX(cosine), 3) AS best, ROUND(MIN(cosine), 3) AS worst,
       ROUND(MAX(cosine) - MIN(cosine), 3) AS spread_over_20
FROM top20;

/* Contrast: the vulnerability query, where exactly one artefact matches. One
   result at 0.635, then a 0.196 cliff onto the corpus background at ~0.43. The
   cliff is the useful signal — it is what a relevance gate should key on rather
   than an absolute floor. */
WITH top20 AS (
  SELECT VALUE:"@scores":cosine_similarity::FLOAT AS cosine
  FROM TABLE(FLATTEN(PARSE_JSON(SNOWFLAKE.CORTEX.SEARCH_PREVIEW('C360_NBA.APP.SEARCH_INTERACTIONS', '{
    "query": "elderly customer repeats the same questions and cannot manage the mobile app without help",
    "columns": ["INTERACTION_ID"], "limit": 20 }'))['results']))
),
ranked AS (
  SELECT cosine, ROW_NUMBER() OVER (ORDER BY cosine DESC) AS r FROM top20
)
SELECT 'W2 cosine cliff, single-match query' AS probe,
       (SELECT COUNT(*) FROM ranked)                        AS hits,
       ROUND((SELECT cosine FROM ranked WHERE r = 1), 3)    AS best,
       ROUND((SELECT cosine FROM ranked WHERE r = 2), 3)    AS second,
       ROUND((SELECT cosine FROM ranked WHERE r = 1)
           - (SELECT cosine FROM ranked WHERE r = 2), 3)    AS cliff_to_second;

/* W1/W2 population view: how much of the corpus sits in the dilution-prone band. */
SELECT 'W1 length distribution' AS finding,
       CASE WHEN BODY_CHARS <  800 THEN '1. under 800 chars'
            WHEN BODY_CHARS < 1600 THEN '2. 800-1600'
            WHEN BODY_CHARS < 2048 THEN '3. 1600-2048 (~512 tokens)'
            ELSE                        '4. over 2048 chars - past the 512-token window of the non-8k models'
       END AS band,
       COUNT(*) AS rows_, ROUND(AVG(BODY_CHARS)) AS avg_chars,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1) AS pct_of_corpus
FROM APP.V_SEARCH_INTERACTION_SOURCE GROUP BY 1, 2 ORDER BY 2;

/* W2 corpus concentration: the reason ranking inside the big block is arbitrary. */
SELECT 'W2 intent concentration' AS finding, INTENT,
       COUNT(*) AS rows_, ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1) AS pct_of_corpus
FROM APP.V_SEARCH_INTERACTION_SOURCE GROUP BY 1, 2 ORDER BY rows_ DESC;

/* W4 filter coverage. An attribute that is UNKNOWN for a quarter of the corpus
   is a filter that quietly narrows the search space. */
SELECT 'W4 filter coverage' AS finding, 'SENTIMENT_BAND' AS attribute, SENTIMENT_BAND AS value,
       COUNT(*) AS rows_, ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1) AS pct
FROM APP.V_SEARCH_INTERACTION_SOURCE GROUP BY 1, 2, 3
UNION ALL
SELECT 'W4 filter coverage', 'PRODUCT_MENTIONED', PRODUCT_MENTIONED,
       COUNT(*), ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1)
FROM APP.V_SEARCH_INTERACTION_SOURCE GROUP BY 1, 2, 3
ORDER BY attribute, rows_ DESC;

/* The I5 finding, as a predicate rather than a claim: the corpus simply has no
   mandate-failure vocabulary in it. */
SELECT 'I5 corpus gap, not a retrieval gap' AS finding,
       COUNT_IF(BODY ILIKE '%bounce%')                                  AS says_bounce,
       COUNT_IF(BODY ILIKE '%mandate%')                                 AS says_mandate,
       COUNT_IF(BODY ILIKE '%NACH%' OR BODY ILIKE '%ECS%')              AS says_nach_or_ecs,
       COUNT_IF(BODY ILIKE '%double debit%' OR BODY ILIKE '%duplicate%'
                OR BODY ILIKE '%twice%')                                AS says_duplicate_debit,
       COUNT(*)                                                         AS corpus
FROM RAW.INTERACTION;

/* ============================================================================
   DONE
   ============================================================================ */

SELECT 'search services built' AS status,
       (SELECT COUNT(*) FROM APP.V_SEARCH_INTERACTION_SOURCE) AS interactions,
       (SELECT COUNT(*) FROM APP.PRODUCT_DOC_CHUNK)           AS clauses,
       $DOC_MODEL                                             AS doc_model,
       $DOC_VERSION                                           AS doc_version,
       'RUN sql/10b_suspend_search.sql WHEN YOU FINISH THIS SESSION' AS reminder;

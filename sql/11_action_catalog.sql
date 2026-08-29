/* ============================================================================
   11_action_catalog.sql  —  GOLD.NBA_FEATURE_BASE
                             GOLD.ACTION_CATALOG
                             GOLD.V_ACTION_CATALOG_RESOLVED
   ----------------------------------------------------------------------------
   Layer 1 of the Next Best Action engine: the set of things that may be
   recommended, and the flat customer surface their predicates are evaluated
   against.

   No AI. Zero credits, re-runnable.

   The architectural claim this file exists to make good on: the LLM in layer 4
   cannot invent an action, because the only actions in existence are the
   eighteen rows inserted here, and layer 4 is handed a subset of them by
   primary key. "Structurally incapable" means the invention has nowhere to
   land, not that a prompt asked it nicely.

   ----------------------------------------------------------------------------
   WHY ELIGIBILITY IS STORED AS TEXT
   ----------------------------------------------------------------------------
   ELIGIBILITY_SQL, SUPPRESSION_SQL and EXPECTED_VALUE_SQL are SQL fragments in
   VARCHAR columns, evaluated by 12 and 13 through generated SQL. The obvious
   alternative -- a hand-written CASE ladder in 12 with the text kept alongside
   for display -- was rejected because it stores the rule twice and the two
   copies drift. The rule the engine runs and the rule the audit trail shows
   have to be the same characters. They are: 12 builds its evaluation query by
   reading this table.

   The cost of that choice is that a typo in a predicate is a runtime error in
   12 rather than a compile error here. Part 4 below buys the check back by
   compiling every fragment against NBA_FEATURE_BASE and refusing to pass if
   any of them fails.

   ----------------------------------------------------------------------------
   WHY NBA_FEATURE_BASE EXISTS  (and is not a change to CUSTOMER_360)
   ----------------------------------------------------------------------------
   The milestone brief specifies ELIGIBILITY_SQL as "a boolean SQL predicate
   over CUSTOMER_360". Three of the five planted segments cannot be expressed
   there:

     S2  needs RAW.CARD.UTILISATION_PCT_M1 / _M2 / _M3 -- four readings.
         CUSTOMER_360 carries only CREDIT_UTILISATION, the current one.
     S4  needs RAW.LOAN.DPD_DAYS_M1 / _M2, and a missed-instalment count over a
         six-month window. CUSTOMER_360 carries DPD_BUCKET and
         MISSED_PAYMENTS_12M -- the wrong window and no trend.
     S5  needs the inbound lumpsum credit itself, to size the referral.

   So this view is CUSTOMER_360 plus a small block of derived predicate
   features, and every eligibility predicate is a flat expression over the
   result. CUSTOMER_360 is not modified: it is a signed-off M4 artefact with a
   dynamic table, a semantic view and two search services built on it, and
   widening it to serve M5 would rebuild all four.

   The features are deliberately thin -- booleans and one amount, each a direct
   transcription of a predicate in docs/DATA_SEGMENTS.md. This is not a second
   feature store. Anything needing real derivation belongs in CURATED.

   ----------------------------------------------------------------------------
   THE PHASE-4 FINDING THIS FILE CORRECTS
   ----------------------------------------------------------------------------
   08_gold_c360.sql line 1070 selects limit-increase candidates as

       HAS_CARD AND CREDIT_UTILISATION > 0.50 AND MISSED_PAYMENTS_12M = 0

   which is a placeholder proxy for "utilisation is rising". Measured against
   the quarantined answer key it fires on 648 customers to find 300: recall
   100%, precision 46.3%. It is not reused here. CARD_LIMIT_INCREASE's
   eligibility carries the real four-reading monotonic chain from
   docs/DATA_SEGMENTS.md S2, via UTILISATION_RISING_4, which fires on exactly
   300 of 300. Part 4 asserts that number and fails the script if it moves.

   Note what the proxy got wrong: not the recall, the precision. A proxy that
   finds everyone it should and 348 people it should not is the more dangerous
   failure, because the segment count still looks correct from the inside.

   ----------------------------------------------------------------------------
   THREE COLUMNS BEYOND THE SPECIFIED LIST, AND WHY EACH IS LOAD-BEARING
   ----------------------------------------------------------------------------
   IS_SALES_ACTION. The global suppressions in layer 2 are worded "vulnerability
     flag for any sales action" and "dpd_bucket > 0 for any cross-sell". Those
     gates need to know whether an action is a sale. CATEGORY is nearly enough
     but not quite -- COLLECTIONS contains a hardship review, which is not a
     sale, and WEALTH contains a referral, which commercially is. Deriving it
     from RAW.PRODUCT_CATALOG.ALLOWED_FOR_VULNERABLE does not work either: that
     column is FALSE for all fifteen sellable products and TRUE only for
     SVC_HARDSHIP, so every retention and service-recovery action -- which have
     no product row at all -- would read as forbidden. An explicit boolean is
     the honest encoding. It is cross-checked against ALLOWED_FOR_VULNERABLE in
     part 4 for the rows where a product does exist.

   PRIORITY_TIER. Ranking on expected value alone puts a large cross-sell above
     a hardship review, which product principle 3 forbids. Layer 3 orders by
     (PRIORITY_TIER, EXPECTED_VALUE_INR DESC), so value competes only within a
     tier. Lower tier wins. This preserves the ladder the placeholder
     NEXT_BEST_ACTION already established, so the Streamlit screens do not move.

   VALUE_ORIENTATION. The brief's scoring formula multiplies by (1 - churn_risk).
     Applied to a retention action that inverts the intent: it would price a
     save call *down* for exactly the customers most likely to leave, and
     RETENTION_SAVE_CALL would sort below a cross-sell on the S1 cohort. For
     ACQUISITION actions churn discounts the value (a leaving customer will not
     hold the new product); for RETENTION actions churn *is* the value at
     stake. 13 reads this column to pick the direction. Flagged rather than
     silently fixed -- it is a real departure from the formula as written.

   ----------------------------------------------------------------------------
   AUTHORING RULE: EVERY FRAGMENT MUST BE NULL-EXPLICIT
   ----------------------------------------------------------------------------
   A predicate over a NULL column returns NULL, not FALSE, and 12 resolves a
   NULL suppression to "does not block" -- the permissive direction. So a
   fragment that can return NULL has silently delegated a compliance decision to
   a harness default.

   Four fragments did, and 12 part 4.2 caught them: SENTIMENT_NOW is NULL for
   4,497 of 5,000 customers (never contacted, or withheld by the confidence gate
   in CURATED.AI_CONFIG) and DAYS_TO_RENEWAL for 1,200 (no active renewing
   policy). RETENTION_WINBACK_LAPSED's suppression returned NULL on 4,497 rows;
   RENEWAL_REMINDER_EARLY's eligibility on 1,102; RETENTION_SAVE_CALL's on 98;
   SERVICE_RECOVERY_OUTREACH's on 12.

   In all four cases the default happened to produce the right answer -- no
   renewal date really does mean no renewal reminder, and unknown sentiment
   really is not evidence of souring. That is what makes it worth fixing rather
   than shrugging at: the fragments were correct by luck, and the next one need
   not be. Each now states its own NULL semantics with an explicit IS NOT NULL
   or COALESCE, the observable behaviour is unchanged (S1 still fires on exactly
   400), and the permissive default is now unreachable rather than merely
   unexercised.

   SP_CHECK_ACTION_PREDICATES counts NULL returns per fragment, so this is
   enforced at authoring time in part 4.1 and asserted again in 12 part 4.2.

   ----------------------------------------------------------------------------
   WHAT IS NOT REFERENCED HERE, ON PURPOSE
   ----------------------------------------------------------------------------
   RAW.CUSTOMER_SEGMENT_TRUTH  -- the answer key. Part 4 joins it, and part 4
     alone, under an explicit banner. Nothing in the view or the catalog can
     see it. An engine that reads the key demonstrates nothing.
   SENTIMENT_SLOPE_PER_30D     -- diagnostic only per PROJECT_BRIEF D6. The
     bucketed SENTIMENT_TREND is the load-bearing column and is the one that
     appears in PROPENSITY_FEATURES.

   Channels are CALL / EMAIL / SMS only. RAW.CONSENT carries a fourth, but
   CUSTOMER_360 exposes permission columns for these three, and an action on a
   channel whose consent cannot be resolved is an action that cannot be
   suppressed correctly.
============================================================================ */

USE ROLE COCO_BUILDER;
USE DATABASE C360_NBA;
USE SCHEMA GOLD;
USE WAREHOUSE COCO_WH;


/* ============================================================================
   PART 1  —  GOLD.NBA_FEATURE_BASE
   ----------------------------------------------------------------------------
   CUSTOMER_360, plus the predicate features that cannot be expressed over it.
   One row per customer, 5,000 rows, same grain as CUSTOMER_360.

   LEFT JOIN throughout with an explicit COALESCE default, because absence and
   falsehood differ and the default is not always FALSE: a customer with no
   repayment ledger has a clean record (TRUE), not a dirty one.
============================================================================ */

CREATE OR REPLACE VIEW GOLD.NBA_FEATURE_BASE AS
WITH card_trend AS (
    /* S2. The four-reading monotonic chain, at customer grain. BOOLOR_AGG so a
       customer holding two cards qualifies if either card is climbing. */
    SELECT CUSTOMER_ID,
           BOOLOR_AGG( STATUS = 'ACTIVE'
                       AND UTILISATION_PCT_M3 < UTILISATION_PCT_M2
                       AND UTILISATION_PCT_M2 < UTILISATION_PCT_M1
                       AND UTILISATION_PCT_M1 < UTILISATION_PCT )  AS UTILISATION_RISING_4,
           MAX(IFF(STATUS = 'ACTIVE', UTILISATION_PCT, NULL))       AS ACTIVE_CARD_UTILISATION,
           MAX(IFF(STATUS = 'ACTIVE', CREDIT_LIMIT_INR, NULL))      AS ACTIVE_CARD_LIMIT_INR
    FROM RAW.CARD
    GROUP BY 1
),
repay_clean AS (
    /* S2's second half: zero late AND zero missed anywhere in the book, ever. */
    SELECT CUSTOMER_ID,
           NOT BOOLOR_AGG(LATE_FLAG OR MISSED_FLAG) AS CLEAN_REPAYMENT_EVER
    FROM RAW.REPAYMENT
    GROUP BY 1
),
loan_trend AS (
    /* S4's rising-DPD half. */
    SELECT CUSTOMER_ID,
           BOOLOR_AGG(DPD_DAYS_M2 < DPD_DAYS_M1 AND DPD_DAYS_M1 < DPD_DAYS) AS DPD_RISING_3
    FROM RAW.LOAN
    GROUP BY 1
),
missed_6m AS (
    /* S4's missed-count half. Six months, not the twelve that
       CUSTOMER_360.MISSED_PAYMENTS_12M uses -- the wider window is what makes
       the C360 column unusable for this predicate. */
    SELECT CUSTOMER_ID,
           COUNT(*)                AS MISSED_COUNT_6M,
           COUNT(*) >= 2           AS MISSED_2_IN_6M
    FROM RAW.REPAYMENT
    WHERE MISSED_FLAG
      AND DUE_DATE >= DATEADD(month, -6, RAW.AS_OF())
    GROUP BY 1
),
ticket_60d AS (
    /* S1's complaint half. CUSTOMER_360.OPEN_COMPLAINT answers "is one still
       open", which is a different question from "was one raised in 60 days" --
       a complaint closed last week satisfies S1 and not OPEN_COMPLAINT.

       OPEN_COMPLAINT_TICKET is the ledger answer to "is one still open", and it
       exists because the CUSTOMER_360 column is not that. Traced from
       08_gold_c360.sql:438, OPEN_COMPLAINT is COALESCE(roll.OPEN_COMPLAINT_FLAG,
       FALSE) -- sourced from CURATED.CUSTOMER_INTERACTION_ROLLUP, which covers
       the 596 customers who have text interactions. For the other 4,404 it is
       FALSE by COALESCE, not by evidence. Measured: 462 customers hold a live
       OPEN or IN_PROGRESS complaint ticket while the C360 flag reads FALSE, and
       that silently disarmed the global open-complaint suppression for 312 sales
       recommendations across 197 of them. See the corrected flag below.

       'live' is OPEN or IN_PROGRESS, not <> 'CLOSED'. The status domain is
       OPEN / IN_PROGRESS / RESOLVED / CLOSED; RESOLVED means the grievance was
       answered and is awaiting closure, so treating it as live would suppress
       selling to a customer whose problem is already fixed. Severity and ticket
       id use the same definition as the flag: mixing them let an old RESOLVED
       severity-4 set the severity for a live severity-1 complaint, which would
       fire COMPLAINT_RESOLUTION_CALLBACK on the wrong ticket. */
    SELECT CUSTOMER_ID,
           BOOLOR_AGG(IS_COMPLAINT AND OPENED_AT >= DATEADD(day, -60, RAW.AS_OF()))
             AS COMPLAINT_RAISED_60D,
           BOOLOR_AGG(IS_COMPLAINT AND STATUS IN ('OPEN', 'IN_PROGRESS'))
             AS OPEN_COMPLAINT_TICKET,
           MAX(IFF(IS_COMPLAINT AND STATUS IN ('OPEN', 'IN_PROGRESS'), SEVERITY, NULL))
             AS OPEN_COMPLAINT_SEVERITY,
           MAX_BY(IFF(IS_COMPLAINT AND STATUS IN ('OPEN', 'IN_PROGRESS'),
                      TICKET_NUMBER, NULL),
                  IFF(IS_COMPLAINT AND STATUS IN ('OPEN', 'IN_PROGRESS'),
                      OPENED_AT, NULL))
             AS TOP_OPEN_COMPLAINT_TICKET
    FROM RAW.SERVICE_TICKET
    GROUP BY 1
),
lumpsum_90d AS (
    /* S5's trigger, and the amount, which sizes the referral in part 2. */
    SELECT CUSTOMER_ID,
           TRUE                    AS LUMPSUM_CREDIT_90D,
           MAX(AMOUNT_INR)         AS LUMPSUM_CREDIT_MAX_INR
    FROM RAW.TXN
    WHERE DIRECTION = 'CREDIT'
      AND AMOUNT_INR >= 1000000
      AND TXN_DATE >= DATEADD(day, -90, RAW.AS_OF())
    GROUP BY 1
)
SELECT
    /* OPEN_COMPLAINT is overridden, not passed through. The C360 column is the
       text-rollup signal only (596 customers); the union of it with the ticket
       ledger is the flag every predicate downstream should have been reading.
       Both halves earn their place: the ticket half catches the 462 customers
       with a live grievance and no text, and the rollup half catches the 32 who
       voiced a complaint on a call that never became a ticket. Overriding here,
       rather than editing GOLD.CUSTOMER_360, keeps the signed-off M4 artefact
       and its Streamlit contract untouched while the engine reads the truth.
       The original is preserved as OPEN_COMPLAINT_ROLLUP for comparison. */
    c.* EXCLUDE (OPEN_COMPLAINT),
    COALESCE(c.OPEN_COMPLAINT, FALSE)
      OR COALESCE(t6.OPEN_COMPLAINT_TICKET, FALSE)   AS OPEN_COMPLAINT,
    COALESCE(c.OPEN_COMPLAINT,        FALSE)   AS OPEN_COMPLAINT_ROLLUP,
    COALESCE(t6.OPEN_COMPLAINT_TICKET, FALSE)  AS OPEN_COMPLAINT_TICKET,

    /* -- planted-segment predicate features ------------------------------- */
    COALESCE(ct.UTILISATION_RISING_4, FALSE)   AS UTILISATION_RISING_4,
    COALESCE(rc.CLEAN_REPAYMENT_EVER,  TRUE)   AS CLEAN_REPAYMENT_EVER,
    COALESCE(lt.DPD_RISING_3,          FALSE)  AS DPD_RISING_3,
    COALESCE(m6.MISSED_2_IN_6M,        FALSE)  AS MISSED_2_IN_6M,
    COALESCE(m6.MISSED_COUNT_6M,       0)      AS MISSED_COUNT_6M,
    COALESCE(t6.COMPLAINT_RAISED_60D,  FALSE)  AS COMPLAINT_RAISED_60D,
    COALESCE(ls.LUMPSUM_CREDIT_90D,    FALSE)  AS LUMPSUM_CREDIT_90D,
    ls.LUMPSUM_CREDIT_MAX_INR                  AS LUMPSUM_CREDIT_MAX_INR,

    /* -- sizing and gating helpers ---------------------------------------- */
    t6.OPEN_COMPLAINT_SEVERITY,
    t6.TOP_OPEN_COMPLAINT_TICKET,
    ct.ACTIVE_CARD_UTILISATION,
    ct.ACTIVE_CARD_LIMIT_INR,

    /* INCOME_BAND_RANK. RAW.CUSTOMER.SEGMENT is a lossless 1:1 relabelling of
       INCOME_BAND_RANK (verified: each band holds exactly one rank), so this is
       a decode and not a re-derivation, and RAW.CUSTOMER is not joined. The
       product catalogue states its thresholds as MIN_INCOME_BAND_RANK, so the
       gates need the number rather than the label. */
    CASE c.SEGMENT WHEN 'MASS'           THEN 1
                   WHEN 'MASS_AFFLUENT'  THEN 2
                   WHEN 'AFFLUENT'       THEN 3
                   WHEN 'PRIORITY'       THEN 4
                   WHEN 'HNI'            THEN 5
    END                                        AS INCOME_BAND_RANK,

    /* -- text-derived propensity inputs, from the gated rollup ------------- */
    COALESCE(r.CHURN_MENTIONS_90D,        0)   AS CHURN_MENTIONS_90D,
    COALESCE(r.COMPETITOR_MENTIONS_90D,   0)   AS COMPETITOR_MENTIONS_90D,
    COALESCE(r.HARDSHIP_MENTIONS_90D,     0)   AS HARDSHIP_MENTIONS_90D,
    COALESCE(r.LIMIT_REQUEST_90D,         0)   AS LIMIT_REQUEST_90D,
    COALESCE(r.PAYMENT_DIFFICULTY_90D,    0)   AS PAYMENT_DIFFICULTY_90D,
    COALESCE(r.CANCELLATION_INTENT_90D,   0)   AS CANCELLATION_INTENT_90D,
    COALESCE(r.RENEWAL_DISPUTE_90D,       0)   AS RENEWAL_DISPUTE_90D,
    COALESCE(r.SERVICE_COMPLAINT_90D,     0)   AS SERVICE_COMPLAINT_90D,
    COALESCE(r.LIFE_EVENTS_365D,          0)   AS LIFE_EVENTS_365D,
    r.SENTIMENT_AVG_90D,
    r.LATEST_COMPETITOR_NAME,
    r.MAX_AMOUNT_DISCUSSED_INR
FROM GOLD.CUSTOMER_360 c
LEFT JOIN card_trend   ct ON ct.CUSTOMER_ID = c.CUSTOMER_ID
LEFT JOIN repay_clean  rc ON rc.CUSTOMER_ID = c.CUSTOMER_ID
LEFT JOIN loan_trend   lt ON lt.CUSTOMER_ID = c.CUSTOMER_ID
LEFT JOIN missed_6m    m6 ON m6.CUSTOMER_ID = c.CUSTOMER_ID
LEFT JOIN ticket_60d   t6 ON t6.CUSTOMER_ID = c.CUSTOMER_ID
LEFT JOIN lumpsum_90d  ls ON ls.CUSTOMER_ID = c.CUSTOMER_ID
LEFT JOIN CURATED.CUSTOMER_INTERACTION_ROLLUP r ON r.CUSTOMER_ID = c.CUSTOMER_ID;

COMMENT ON VIEW GOLD.NBA_FEATURE_BASE IS
'The surface every NBA eligibility predicate is evaluated against: all of GOLD.CUSTOMER_360 plus a thin block of derived predicate features that CUSTOMER_360 cannot express -- four-reading utilisation rise (S2), three-reading DPD rise and six-month missed count (S4), complaint-raised-in-60-days (S1), inbound lumpsum and its amount (S5), and INCOME_BAND_RANK decoded from SEGMENT. Deliberately not a feature store: every column is a direct transcription of a predicate in docs/DATA_SEGMENTS.md. Does not and must not reference RAW.CUSTOMER_SEGMENT_TRUTH or SENTIMENT_SLOPE_PER_30D.';


/* ============================================================================
   PART 2  —  GOLD.ACTION_CATALOG
   ----------------------------------------------------------------------------
   Eighteen actions. One row per thing that may ever be recommended.

   Grouped by CATEGORY:
     RETENTION         3
     CROSS_SELL        7
     UPSELL            3
     SERVICE_RECOVERY  2
     COLLECTIONS       2
     WEALTH            1

   EXPECTED_VALUE_SQL is gross INR margin at stake, before propensity, churn and
   timing -- layer 3 applies those. It may reference MARGIN_RATE and
   AVG_TICKET_SIZE_INR, which V_ACTION_CATALOG_RESOLVED supplies from
   RAW.PRODUCT_CATALOG so the rates are not duplicated here. Actions with no
   product row size off the relationship instead, via EST_ANNUAL_MARGIN_INR.

   ----------------------------------------------------------------------------
   WHAT ELIGIBILITY_SQL DELIBERATELY DOES *NOT* CONTAIN
   ----------------------------------------------------------------------------
   No age band, income band, tenure minimum, KYC status or DPD ceiling, for any
   action that has a PRODUCT_ID. RAW.PRODUCT_CATALOG already carries all five as
   structured columns -- MIN_AGE, MAX_AGE, MIN_INCOME_BAND_RANK,
   MIN_TENURE_MONTHS, REQUIRED_KYC_STATUS, MAX_DPD_DAYS -- and 12 evaluates them
   generically as six individually named suppression rules for every action that
   resolves a product. Restating them as text here would duplicate the rate card
   the same way a hardcoded MARGIN_RATE would.

   This was not the first cut, and the first cut was wrong in a way worth
   recording. The demographic gates were originally folded into ELIGIBILITY_SQL,
   and part 4.3 then reported CARD_LIMIT_INCREASE recovering 184 of the 300
   planted S2 customers -- 61.3% recall on a predicate whose behavioural core is
   exact. Decomposed: the income-band floor cost 73, the age band 40, the tenure
   minimum 11. Those customers are genuinely outside the product's filed
   parameters and should not receive the offer. But folding the gate into
   eligibility made them *invisible*: they simply never appeared, with no row
   and no reason, which is precisely the failure mode this engine is supposed
   not to have. Moved into the suppression layer they surface as "eligible on
   signal, blocked by income band", which is a defensible audit line.

   The rule this settles, and it is the same rule as the SUPPRESSION_SQL comment
   below: eligibility carries the NEED. Everything that withholds an action a
   customer otherwise qualifies for is a suppression, because a suppression
   leaves a trace and a missing row does not.

   The income scaling factor (0.85 + 0.10 * INCOME_BAND_RANK) spans 0.95 to
   1.35. It is a ranking tilt towards affluence on discretionary product, not a
   measured elasticity, and it is deliberately small enough that it cannot
   reorder across a priority tier.
============================================================================ */

CREATE OR REPLACE TABLE GOLD.ACTION_CATALOG (
    ACTION_CODE          VARCHAR(40)   NOT NULL,
    ACTION_NAME          VARCHAR(80)   NOT NULL,
    CATEGORY             VARCHAR(20)   NOT NULL,
    PRODUCT_ID           VARCHAR(30),
    CHANNEL              VARCHAR(10)   NOT NULL,
    ELIGIBILITY_SQL      VARCHAR(2000) NOT NULL,
    SUPPRESSION_SQL      VARCHAR(2000) NOT NULL,
    EXPECTED_VALUE_SQL   VARCHAR(2000) NOT NULL,
    PROPENSITY_FEATURES  ARRAY         NOT NULL,
    COOLDOWN_DAYS        NUMBER(5,0)   NOT NULL,
    REGULATORY_NOTE      VARCHAR(500)  NOT NULL,
    REQUIRED_DISCLOSURE  VARCHAR(500)  NOT NULL,
    IS_SALES_ACTION      BOOLEAN       NOT NULL,
    PRIORITY_TIER        NUMBER(3,0)   NOT NULL,
    VALUE_ORIENTATION    VARCHAR(12)   NOT NULL,
    IS_SERVICING_OBLIGATION BOOLEAN    NOT NULL,
    CONSTRAINT PK_ACTION_CATALOG PRIMARY KEY (ACTION_CODE)
);

INSERT INTO GOLD.ACTION_CATALOG
  (ACTION_CODE, ACTION_NAME, CATEGORY, PRODUCT_ID, CHANNEL,
   ELIGIBILITY_SQL, SUPPRESSION_SQL, EXPECTED_VALUE_SQL,
   PROPENSITY_FEATURES, COOLDOWN_DAYS, REGULATORY_NOTE, REQUIRED_DISCLOSURE,
   IS_SALES_ACTION, PRIORITY_TIER, VALUE_ORIENTATION, IS_SERVICING_OBLIGATION)
SELECT column1, column2, column3, column4, column5,
       column6, column7, column8,
       PARSE_JSON(column9), column10, column11, column12,
       column13, column14, column15, column16
FROM VALUES

/* -- COLLECTIONS ------------------------------------------------------------
   Tier 10 and 12: nothing outranks arrears. A customer in rising arrears gets
   a hardship conversation, and the engine is not permitted to prefer a sale to
   it however large the sale.                                                */

('COLLECTIONS_HARDSHIP_OUTREACH',
 'Hardship and Restructure Review',
 'COLLECTIONS', 'SVC_HARDSHIP', 'CALL',
 /* eligibility: docs/DATA_SEGMENTS.md S4, both halves. */
 'MISSED_2_IN_6M AND DPD_RISING_3',
 /* nothing action-specific blocks a hardship review. Global suppressions in 12
    exempt it too: it is the action a suppressed customer is still owed. */
 'FALSE',
 /* value at stake is loss avoided on the exposure, not margin earned. */
 'COALESCE(OUTSTANDING_CREDIT_INR, 0) * 0.02',
 '["MISSED_COUNT_6M","DPD_RISING_3","HARDSHIP_MENTIONS_90D","PAYMENT_DIFFICULTY_90D","SENTIMENT_TREND","DPD_BUCKET"]',
 14,
 'RBI Fair Practices Code: collections contact restricted to 08:00-19:00 IST. Recovery agent conduct rules apply. A hardship review is a servicing obligation, not a collection demand, and is permitted for vulnerable and DNC-registered customers because withholding it causes the harm.',
 'This call is to discuss support options on your existing borrowing. It is not a demand for immediate payment and no new product will be offered.',
 FALSE, 10, 'RETENTION', TRUE),

('EARLY_ARREARS_REMINDER',
 'Early Arrears Reminder',
 'COLLECTIONS', NULL, 'SMS',
 /* mild arrears that has not become hardship. Mutually exclusive with the row
    above by construction, so a customer never gets both. */
 'DPD_BUCKET = ''1-30'' AND NOT (MISSED_2_IN_6M AND DPD_RISING_3)',
 'FALSE',
 'COALESCE(OUTSTANDING_CREDIT_INR, 0) * 0.004',
 '["DPD_BUCKET","MISSED_PAYMENTS_12M","PAYMENT_DIFFICULTY_90D","NEXT_EMI_DATE"]',
 7,
 'RBI Fair Practices Code. Factual reminder only; no threat of consequence permitted in the message body.',
 'A reminder about your instalment due. Please ignore if payment has already been made.',
 FALSE, 12, 'RETENTION', FALSE),

/* -- SERVICE_RECOVERY -------------------------------------------------------
   Tier 15 and 18: an unresolved grievance is answered before anything is
   sold. IRDAI treats an open grievance as a live obligation.                */

('COMPLAINT_RESOLUTION_CALLBACK',
 'Complaint Resolution Callback',
 'SERVICE_RECOVERY', NULL, 'CALL',
 'OPEN_COMPLAINT AND COALESCE(OPEN_COMPLAINT_SEVERITY, 0) >= 3',
 'FALSE',
 /* the whole relationship margin is what an unresolved severity-3+ grievance
    puts at risk, discounted to a half because not every complaint churns. */
 'COALESCE(EST_ANNUAL_MARGIN_INR, 0) * 0.5',
 '["OPEN_COMPLAINT_SEVERITY","SERVICE_COMPLAINT_90D","SENTIMENT_TREND","SENTIMENT_NOW","INTERACTIONS_90D","CHURN_MENTIONS_90D"]',
 3,
 'IRDAI Protection of Policyholders Interests Regulations: grievance acknowledgement within 15 days and resolution within 14 days of acknowledgement. This action discharges that obligation and is exempt from commercial cooling-off.',
 'This call is about the complaint you have already raised with us. Your complaint reference will be quoted at the start of the call.',
 FALSE, 15, 'RETENTION', TRUE),

('SERVICE_RECOVERY_OUTREACH',
 'Service Recovery Outreach',
 'SERVICE_RECOVERY', NULL, 'CALL',
 /* Souring sentiment across repeated contact with nothing formally logged --
    the case a ticket queue never surfaces. DETERIORATING alone fired on 2 of
    5,000: the trend needs three sentiment readings, only 136 customers have
    them, and almost all of those are S1 retention or S4 hardship customers who
    already carry an open complaint and are therefore excluded by the third
    clause. A predicate that fires twice is not a demonstrable action, so the
    current negative reading is admitted as an alternative entry. Still
    service-only, and still excluded where a complaint is formally open. */
 '(SENTIMENT_TREND = ''DETERIORATING'''
   || '  OR COALESCE(SENTIMENT_NOW = ''negative'', FALSE))'
   || ' AND INTERACTIONS_90D >= 2 AND NOT OPEN_COMPLAINT',
 'FALSE',
 'COALESCE(EST_ANNUAL_MARGIN_INR, 0) * 0.25',
 '["SENTIMENT_TREND","SENTIMENT_AVG_90D","INTERACTIONS_90D","SERVICE_COMPLAINT_90D","LAST_CONTACT_DAYS"]',
 21,
 'No specific regulatory trigger. Service contact, so not a solicitation and outside the DNC sales regime, but channel consent still applies.',
 'This is a courtesy call about your recent experience with us. We are not selling anything on this call.',
 FALSE, 18, 'RETENTION', FALSE),

/* -- RETENTION --------------------------------------------------------------
   Tier 20-30. RETENTION_SAVE_CALL is the expected action for planted segment
   S1, and the segment note is explicit that a cross-sell here is a ranking
   failure -- the tier is what prevents it.                                  */

('RETENTION_SAVE_CALL',
 'Retention Save Call',
 'RETENTION', NULL, 'CALL',
 /* eligibility: docs/DATA_SEGMENTS.md S1, both halves. COMPLAINT_RAISED_60D
    rather than OPEN_COMPLAINT -- a complaint closed last week still counts. */
 'DAYS_TO_RENEWAL IS NOT NULL AND DAYS_TO_RENEWAL BETWEEN 0 AND 30'
   || ' AND COMPLAINT_RAISED_60D',
 'FALSE',
 /* the relationship is what walks, not one policy. Floored so a customer with
    no modelled margin still ranks above nothing. */
 'GREATEST(COALESCE(EST_ANNUAL_MARGIN_INR, 0), 5000)',
 '["SENTIMENT_TREND","CHURN_MENTIONS_90D","COMPETITOR_MENTIONS_90D","RENEWAL_DISPUTE_90D","CANCELLATION_INTENT_90D","DAYS_TO_RENEWAL","LAPSE_HISTORY","OPEN_COMPLAINT"]',
 7,
 'IRDAI: renewal servicing contact on an in-force policy is permitted during an open grievance and is not a solicitation. Retention pricing concessions must be within the filed product rate.',
 'This call is about the renewal of your existing policy. No new product is being sold on this call.',
 FALSE, 20, 'RETENTION', FALSE),

('RETENTION_WINBACK_LAPSED',
 'Lapsed Policy Win-back',
 'RETENTION', NULL, 'CALL',
 'LAPSE_HISTORY >= 1 AND DAYS_TO_RENEWAL IS NULL',
 /* a customer already souring is not a win-back candidate; fix the service
    problem first. This one is action-specific, not global. */
 'COALESCE(SENTIMENT_NOW = ''negative'', FALSE)'
   || ' OR SENTIMENT_TREND = ''DETERIORATING''',
 'GREATEST(COALESCE(ANNUAL_PREMIUM_INR, 0), 15000) * 0.18',
 '["LAPSE_HISTORY","SENTIMENT_TREND","TENURE_YEARS","PRODUCT_COUNT","LAST_CONTACT_DAYS"]',
 30,
 'Reinstatement of a lapsed policy is a fresh underwriting decision; revival terms and any medical requirement must be stated before payment is taken.',
 'Your previous policy has lapsed. Reviving it requires fresh underwriting and the terms may differ from your original policy.',
 FALSE, 25, 'RETENTION', FALSE),

('RENEWAL_REMINDER_EARLY',
 'Early Renewal Reminder',
 'RETENTION', NULL, 'SMS',
 /* the 31-60 day window, deliberately disjoint from RETENTION_SAVE_CALL's
    0-30, and only where no complaint is live. */
 'DAYS_TO_RENEWAL IS NOT NULL AND DAYS_TO_RENEWAL BETWEEN 31 AND 60'
   || ' AND NOT COMPLAINT_RAISED_60D',
 'FALSE',
 'COALESCE(ANNUAL_PREMIUM_INR, 0) * 0.18 * 0.35',
 '["DAYS_TO_RENEWAL","LAPSE_HISTORY","TENURE_YEARS","PREFERRED_CHANNEL"]',
 14,
 'Servicing communication on an in-force policy. Not a solicitation.',
 'A reminder that your policy is due for renewal. Renewal terms are as per your existing policy schedule.',
 FALSE, 30, 'RETENTION', FALSE),

/* -- WEALTH -----------------------------------------------------------------
   Tier 40. Commercially a referral is an acquisition, so IS_SALES_ACTION is
   TRUE and the vulnerability gate bites -- see docs/DATA_SEGMENTS.md S7.     */

('WEALTH_REFERRAL',
 'Wealth Advisory Referral',
 'WEALTH', NULL, 'CALL',
 /* eligibility: docs/DATA_SEGMENTS.md S5. The PRODUCT_GAP entry carries the
    "holds no investment product" half; the lumpsum is the trigger. */
 'LUMPSUM_CREDIT_90D AND ARRAY_CONTAINS(''Investment (ULIP)''::VARIANT, PRODUCT_GAP)',
 'NOT KYC_CURRENT',
 /* advisory margin on the sum actually received, not a product ticket. */
 'COALESCE(LUMPSUM_CREDIT_MAX_INR, 0) * 0.012',
 '["LUMPSUM_CREDIT_MAX_INR","INCOME_BAND_RANK","RELATIONSHIP_VALUE_BAND","TENURE_YEARS","MAX_AMOUNT_DISCUSSED_INR","LIFE_EVENTS_365D"]',
 45,
 'SEBI investment advisory: a referral may describe the advisory service but must not recommend a specific security or scheme. Suitability assessment precedes any product discussion. AML source-of-funds check required on a credit of this size before onboarding.',
 'This is a referral to a qualified advisor for a suitability discussion. It is not investment advice and no specific product is being recommended.',
 TRUE, 40, 'ACQUISITION', FALSE),

/* -- UPSELL ----------------------------------------------------------------
   Tier 50. On a product already held, so the suitability question is narrower
   than for acquisition.                                                     */

('CARD_LIMIT_INCREASE',
 'Credit Limit Increase',
 'UPSELL', 'BNK_CARD_LIMIT_INC', 'CALL',
 /* THE CORRECTED PREDICATE. docs/DATA_SEGMENTS.md S2 in full -- the real
    four-reading monotonic chain plus a clean book -- NOT the
    credit_utilisation > 0.5 proxy from 08_gold_c360.sql line 1070, which
    over-fires 648 to find 300. Fires on exactly 300 of 300; asserted in
    part 4. The catalogue's own gates (age 21-65, income rank 2+, 12 months
    tenure, zero DPD) are carried too, and part 4 reports what they cost. */
 'UTILISATION_RISING_4 AND CLEAN_REPAYMENT_EVER AND HAS_CARD',
 /* MAX_DPD_DAYS = 0 and REQUIRED_KYC_STATUS are catalogue columns and are
    applied by 12 as named gates. What remains is the one condition the
    catalogue states only in prose: no late payment in the trailing 12 months. */
 'MISSED_PAYMENTS_12M > 0',
 'AVG_TICKET_SIZE_INR * MARGIN_RATE * (0.85 + 0.10 * INCOME_BAND_RANK)',
 '["UTILISATION_RISING_4","ACTIVE_CARD_UTILISATION","CREDIT_UTILISATION","LIMIT_REQUEST_90D","CLEAN_REPAYMENT_EVER","INCOME_BAND_RANK","TENURE_YEARS"]',
 90,
 'RBI credit card directions: a limit increase requires explicit customer consent and a fresh assessment of repayment capacity. An unsolicited increase is prohibited. Bureau enquiry consent must be on record.',
 'Any increase in your credit limit requires your explicit consent and a fresh affordability assessment. Your limit will not be changed without your agreement.',
 TRUE, 50, 'ACQUISITION', FALSE),

('CARD_UPGRADE_PLATINUM',
 'Platinum Credit Card Upgrade',
 'UPSELL', 'BNK_CARD_PLAT', 'CALL',
 /* deliberately disjoint from the limit increase: this is the affluent, LOW
    utilisation, not-currently-climbing customer. */
 'HAS_CARD AND NOT UTILISATION_RISING_4 AND COALESCE(CREDIT_UTILISATION, 0) < 0.35',
 'MISSED_PAYMENTS_12M > 0',
 'AVG_TICKET_SIZE_INR * MARGIN_RATE * (0.85 + 0.10 * INCOME_BAND_RANK)',
 '["INCOME_BAND_RANK","RELATIONSHIP_VALUE_BAND","CREDIT_UTILISATION","TENURE_YEARS","PRODUCT_COUNT","EST_ANNUAL_MARGIN_INR"]',
 120,
 'RBI credit card directions: card issue or variant change requires one-time password consent. Annual fee and reward terms disclosed before consent is taken.',
 'The Platinum variant carries an annual fee. The fee and the reward terms will be stated in full before you are asked to consent.',
 TRUE, 50, 'ACQUISITION', FALSE),

('TERM_ROP_UPSELL',
 'Term with Return of Premium Upsell',
 'UPSELL', 'INS_TERM_ROP', 'CALL',
 'ARRAY_CONTAINS(''Term Life''::VARIANT, PRODUCTS_HELD)',
 'FALSE',
 'AVG_TICKET_SIZE_INR * MARGIN_RATE * (0.85 + 0.10 * INCOME_BAND_RANK)',
 '["INCOME_BAND_RANK","ANNUAL_PREMIUM_INR","AGE","HOUSEHOLD_SIZE","TENURE_YEARS","LIFE_EVENTS_365D"]',
 120,
 'IRDAI: return-of-premium is a distinct product, not an endorsement to an existing term policy. Free-look period of 30 days applies. Existing cover must not be surrendered before the new policy is in force.',
 'This is a separate policy, not a change to your existing term cover. A 30-day free-look period applies and you should not cancel your current policy.',
 TRUE, 50, 'ACQUISITION', FALSE),

/* -- CROSS_SELL ------------------------------------------------------------
   Tier 60, the bottom. Every one of these is a sale to a customer who does not
   hold the product, so IS_SALES_ACTION is TRUE throughout and both the
   vulnerability gate and the arrears gate in 12 apply.

   Eligibility reads CUSTOMER_360.PRODUCT_GAP, whose contract is that every
   entry is gated on NOT holding the product and that
   ARRAY_INTERSECTION(PRODUCT_GAP, PRODUCTS_HELD) is empty. That discharges the
   suitability rule "product not sold to a customer already holding it" at the
   source rather than restating it eighteen times. The income-band and KYC
   thresholds PRODUCT_GAP deliberately omits are added here, per its COMMENT --
   they belong to M5, which is this file.                                    */

('HOME_PROTECTION_CROSS_SELL',
 'Home Loan Linked Protection Cover',
 'CROSS_SELL', 'INS_HOME_LOAN_LINKED', 'CALL',
 /* eligibility: docs/DATA_SEGMENTS.md S3. The clearest cross-silo action in
    the dataset -- lending knows the loan, policy knows the gap. */
 'ARRAY_CONTAINS(''Home Insurance''::VARIANT, PRODUCT_GAP) AND HAS_HOME_LOAN',
 'FALSE',
 /* sum assured tracks outstanding principal, so size off the exposure where
    there is one and fall back to the book ticket where there is not. */
 'GREATEST(AVG_TICKET_SIZE_INR, COALESCE(OUTSTANDING_CREDIT_INR, 0) * 0.0035) * MARGIN_RATE',
 '["HAS_HOME_LOAN","OUTSTANDING_CREDIT_INR","INCOME_BAND_RANK","TENURE_YEARS","PRODUCT_COUNT","NEXT_EMI_DATE"]',
 60,
 'IRDAI: insurance must not be presented as a condition of the loan. Tying is prohibited. The customer is free to buy equivalent cover elsewhere and must be told so.',
 'This cover is optional and is not a condition of your home loan. You may purchase equivalent cover from any insurer.',
 TRUE, 60, 'ACQUISITION', FALSE),

('HEALTH_CROSS_SELL_FAMILY',
 'Family Floater Health Cover',
 'CROSS_SELL', 'INS_HEALTH_FAM', 'CALL',
 'ARRAY_CONTAINS(''Health Insurance''::VARIANT, PRODUCT_GAP) AND HOUSEHOLD_SIZE >= 2',
 'FALSE',
 'AVG_TICKET_SIZE_INR * MARGIN_RATE * (0.85 + 0.10 * INCOME_BAND_RANK)',
 '["HOUSEHOLD_SIZE","INCOME_BAND_RANK","AGE","LIFE_EVENTS_365D","CLAIM_RATIO","PRODUCT_COUNT"]',
 60,
 'IRDAI: pre-existing disease waiting period and room-rent sub-limits must be disclosed before the proposal is signed. Moratorium of 60 months applies to non-disclosure.',
 'Pre-existing conditions carry a waiting period before they are covered. The waiting period and any sub-limits will be stated in full before you proceed.',
 TRUE, 60, 'ACQUISITION', FALSE),

('HEALTH_CROSS_SELL_INDIVIDUAL',
 'Individual Health Indemnity Cover',
 'CROSS_SELL', 'INS_HEALTH_IND', 'EMAIL',
 'ARRAY_CONTAINS(''Health Insurance''::VARIANT, PRODUCT_GAP) AND HOUSEHOLD_SIZE = 1',
 'FALSE',
 'AVG_TICKET_SIZE_INR * MARGIN_RATE * (0.85 + 0.10 * INCOME_BAND_RANK)',
 '["AGE","INCOME_BAND_RANK","LIFE_EVENTS_365D","CLAIM_RATIO","PRODUCT_COUNT","TENURE_YEARS"]',
 60,
 'IRDAI: pre-existing disease waiting period must be disclosed before the proposal is signed.',
 'Pre-existing conditions carry a waiting period before they are covered. Full terms are in the policy wording sent with this offer.',
 TRUE, 60, 'ACQUISITION', FALSE),

('TERM_LIFE_CROSS_SELL',
 'Pure Term Life Cover',
 'CROSS_SELL', 'INS_TERM_PLAIN', 'CALL',
 'ARRAY_CONTAINS(''Term Life''::VARIANT, PRODUCT_GAP)',
 'FALSE',
 'AVG_TICKET_SIZE_INR * MARGIN_RATE * (0.85 + 0.10 * INCOME_BAND_RANK)',
 '["AGE","INCOME_BAND_RANK","HOUSEHOLD_SIZE","LIFE_EVENTS_365D","HAS_HOME_LOAN","OUTSTANDING_CREDIT_INR"]',
 90,
 'IRDAI: medical underwriting required above 50 lakh sum assured. Non-disclosure of material facts voids the contract and this must be stated at proposal.',
 'Cover above 50 lakh requires medical tests. Answering the health questions incompletely can void your policy, so please answer them in full.',
 TRUE, 60, 'ACQUISITION', FALSE),

('MOTOR_CROSS_SELL',
 'Comprehensive Motor Insurance',
 'CROSS_SELL', 'INS_MOTOR_COMP', 'SMS',
 'ARRAY_CONTAINS(''Motor Insurance''::VARIANT, PRODUCT_GAP)',
 'FALSE',
 'AVG_TICKET_SIZE_INR * MARGIN_RATE * (0.85 + 0.10 * INCOME_BAND_RANK)',
 '["AGE","INCOME_BAND_RANK","CLAIM_RATIO","PRODUCT_COUNT","TENURE_YEARS"]',
 45,
 'IRDAI: motor third-party cover is statutory. Own-damage is optional and the two components must be priced separately in the quote.',
 'Third-party cover is required by law; own-damage cover is optional. The premium for each is shown separately in your quote.',
 TRUE, 60, 'ACQUISITION', FALSE),

('PERSONAL_LOAN_CROSS_SELL',
 'Personal Loan',
 'CROSS_SELL', 'BNK_LOAN_PERS', 'CALL',
 /* not in PRODUCT_GAP's vocabulary as a gap, so held-ness is asserted against
    PRODUCTS_HELD directly. Same nine-label vocabulary, so this is the same
    set operation PRODUCT_GAP performs internally. */
 'NOT ARRAY_CONTAINS(''Personal Loan''::VARIANT, PRODUCTS_HELD)',
 /* catalogue MAX_DPD_DAYS is 0 and is applied by 12; the prose condition "no
    current arrears permitted" is stricter than the bucket and stays here. */
 'MISSED_PAYMENTS_12M > 0',
 'AVG_TICKET_SIZE_INR * MARGIN_RATE * (0.85 + 0.10 * INCOME_BAND_RANK)',
 '["INCOME_BAND_RANK","TENURE_YEARS","DPD_BUCKET","MISSED_PAYMENTS_12M","EST_ANNUAL_MARGIN_INR","MAX_AMOUNT_DISCUSSED_INR"]',
 90,
 'RBI digital lending directions: all-inclusive APR, processing fee and recovery mechanism disclosed in the Key Fact Statement before sanction. No unsolicited limit enhancement.',
 'The all-inclusive annual rate, all fees and the cooling-off terms are set out in the Key Fact Statement, which you will receive before you commit.',
 TRUE, 60, 'ACQUISITION', FALSE),

('CARD_ACQUISITION',
 'Gold Credit Card',
 'CROSS_SELL', 'BNK_CARD_GOLD', 'EMAIL',
 'ARRAY_CONTAINS(''Credit Card''::VARIANT, PRODUCT_GAP)',
 'MISSED_PAYMENTS_12M > 0',
 'AVG_TICKET_SIZE_INR * MARGIN_RATE * (0.85 + 0.10 * INCOME_BAND_RANK)',
 '["INCOME_BAND_RANK","TENURE_YEARS","EST_ANNUAL_MARGIN_INR","PRODUCT_COUNT","DPD_BUCKET","AGE"]',
 90,
 'RBI credit card directions: no card may be issued without explicit written or OTP consent. Unsolicited issuance is prohibited and attracts a penalty of twice the charges billed.',
 'A card will only be issued if you explicitly consent. Joining and annual fees, and the interest rate on revolving balances, are disclosed before consent.',
 TRUE, 60, 'ACQUISITION', FALSE)

AS t(column1, column2, column3, column4, column5, column6, column7, column8,
     column9, column10, column11, column12, column13, column14, column15,
     column16);


COMMENT ON TABLE GOLD.ACTION_CATALOG IS
'The closed set of actions the NBA engine may recommend -- eighteen rows, one per action. Layer 4 receives a subset of ACTION_CODE by key and validates its output against it, so the LLM is structurally unable to invent an action rather than merely instructed not to. ELIGIBILITY_SQL / SUPPRESSION_SQL / EXPECTED_VALUE_SQL are SQL fragments over GOLD.NBA_FEATURE_BASE joined to RAW.PRODUCT_CATALOG (see GOLD.V_ACTION_CATALOG_RESOLVED); 12 and 13 build their evaluation queries by reading them, so the rule that runs and the rule the audit trail displays are the same characters. Every fragment is compiled by 11 part 4.';

COMMENT ON COLUMN GOLD.ACTION_CATALOG.ELIGIBILITY_SQL IS
'Boolean SQL predicate over GOLD.NBA_FEATURE_BASE (plus the resolved product columns) that makes the action POSSIBLE. Positive conditions only -- things that BLOCK belong in SUPPRESSION_SQL, so that a blocked action appears in the trace as blocked rather than never appearing at all. Compiled by 11 part 4; evaluated by 12.';

COMMENT ON COLUMN GOLD.ACTION_CATALOG.SUPPRESSION_SQL IS
'Boolean SQL predicate that BLOCKS the action for a customer who is otherwise eligible. Action-specific only: the four global suppressions (DNC, channel consent, open complaint, vulnerability for sales actions, arrears for cross-sell, cooldown) are applied uniformly by 12 and are not repeated here. FALSE means no action-specific block, not "not yet written".';

COMMENT ON COLUMN GOLD.ACTION_CATALOG.EXPECTED_VALUE_SQL IS
'GROSS INR margin at stake, before propensity, churn and timing -- 13 applies those three and writes EXPECTED_VALUE_INR. May reference MARGIN_RATE and AVG_TICKET_SIZE_INR, supplied from RAW.PRODUCT_CATALOG via GOLD.V_ACTION_CATALOG_RESOLVED so rates are never duplicated into this table. Actions with no PRODUCT_ID size off EST_ANNUAL_MARGIN_INR or the exposure instead.';

COMMENT ON COLUMN GOLD.ACTION_CATALOG.IS_SALES_ACTION IS
'Whether the action is a solicitation. Read by the vulnerability gate ("no sales action to a flagged customer") and the arrears gate in 12. Explicit rather than derived: CATEGORY is not sufficient (COLLECTIONS holds a hardship review, which is not a sale; WEALTH holds a referral, which commercially is), and RAW.PRODUCT_CATALOG.ALLOWED_FOR_VULNERABLE is not sufficient either (FALSE for all fifteen sellable products, and NULL for the seven actions with no product row). Cross-checked against ALLOWED_FOR_VULNERABLE in 11 part 4 where a product exists.';

COMMENT ON COLUMN GOLD.ACTION_CATALOG.PRIORITY_TIER IS
'Ranking ladder, lower wins: 10 hardship, 12 early arrears, 15 complaint callback, 18 service recovery, 20 retention save, 25 win-back, 30 renewal reminder, 40 wealth referral, 50 upsell, 60 cross-sell. 13 orders by (PRIORITY_TIER, EXPECTED_VALUE_INR DESC) so expected value competes only WITHIN a tier. Without this, a large cross-sell outranks a hardship review on pure value, which product principle 3 forbids. Matches the ladder the placeholder GOLD.NEXT_BEST_ACTION established, so the app does not move.';

COMMENT ON COLUMN GOLD.ACTION_CATALOG.VALUE_ORIENTATION IS
'Direction of the churn term in 13. ACQUISITION: value is multiplied by (1 - churn_risk), because a departing customer will not hold the new product. RETENTION: value is multiplied by churn_risk, because churn IS the value at stake. The milestone formula was written as (1 - churn_risk) throughout; applied literally it prices a save call DOWN for the customers most likely to leave and sorts RETENTION_SAVE_CALL below a cross-sell across the whole S1 cohort. This column is the documented departure.';

COMMENT ON COLUMN GOLD.ACTION_CATALOG.IS_SERVICING_OBLIGATION IS
'TRUE where the action discharges a specific named regulatory obligation rather than pursuing a commercial outcome: COLLECTIONS_HARDSHIP_OUTREACH (RBI Fair Practices Code hardship review) and COMPLAINT_RESOLUTION_CALLBACK (IRDAI grievance redressal timelines). Exactly two of eighteen. Read by 12 to exempt those two from GLOBAL_DNC under the TRAI TCCCPR promotional-versus-transactional distinction -- see PROJECT_BRIEF D7. Deliberately narrower than NOT IS_SALES_ACTION: a renewal reminder and a lapsed-policy win-back are also non-sales, but neither discharges an obligation and a win-back is frankly promotional, so neither earns the exemption. NOT an exemption from GLOBAL_CHANNEL_CONSENT, which stays a hard block on all eighteen.'
;

COMMENT ON COLUMN GOLD.ACTION_CATALOG.COOLDOWN_DAYS IS
'Minimum days since the last outbound contact for the SAME action before it may be offered again. Evaluated in 12 against RAW.CAMPAIGN_HISTORY matched on PRODUCT_ID, so an action with no product row is matched on its own code. Service and grievance actions carry short cooldowns (3-21 days) because they discharge an obligation rather than solicit; acquisition carries 45-120.';


/* ============================================================================
   PART 3  —  GOLD.V_ACTION_CATALOG_RESOLVED
   ----------------------------------------------------------------------------
   ACTION_CATALOG with the commercial parameters resolved from
   RAW.PRODUCT_CATALOG. This is the relation 12 and 13 cross join against, and
   the reason EXPECTED_VALUE_SQL can say MARGIN_RATE without this file holding a
   second copy of the rate card.

   LEFT JOIN: seven of the eighteen actions have no product row, and that is
   correct -- a retention call is not a product.
============================================================================ */

CREATE OR REPLACE VIEW GOLD.V_ACTION_CATALOG_RESOLVED AS
SELECT
    a.*,
    p.PRODUCT_NAME              AS CATALOGUE_PRODUCT_NAME,
    p.PRODUCT_FAMILY,
    p.PRODUCT_TYPE,
    p.MARGIN_RATE,
    p.AVG_TICKET_SIZE_INR,
    p.MIN_AGE,
    p.MAX_AGE,
    p.MIN_INCOME_BAND_RANK,
    p.MIN_TENURE_MONTHS,
    p.REQUIRED_KYC_STATUS,
    p.MAX_DPD_DAYS,
    p.ALLOWED_FOR_VULNERABLE,
    p.IS_SELLABLE
FROM GOLD.ACTION_CATALOG a
LEFT JOIN RAW.PRODUCT_CATALOG p ON p.PRODUCT_CODE = a.PRODUCT_ID;

COMMENT ON VIEW GOLD.V_ACTION_CATALOG_RESOLVED IS
'GOLD.ACTION_CATALOG with commercial parameters resolved from RAW.PRODUCT_CATALOG by PRODUCT_ID. The relation 12 and 13 cross join customers against, and what lets EXPECTED_VALUE_SQL reference MARGIN_RATE and AVG_TICKET_SIZE_INR without duplicating the rate card into ACTION_CATALOG. Seven actions have no product row and carry NULLs here by design -- a retention call is not a product.';


/* ============================================================================
   PART 4  —  VERIFICATION
   ----------------------------------------------------------------------------
   Three things are checked, and the first two are checks the "store SQL as
   text" decision made necessary:

     4.1  every fragment compiles and its fire count is reported
     4.2  IS_SALES_ACTION agrees with ALLOWED_FOR_VULNERABLE where a product row
          exists, and structural invariants on the catalogue hold
     4.3  the five planted-segment predicates score against the answer key

   4.3 is the ONLY place in this file that touches RAW.CUSTOMER_SEGMENT_TRUTH.
   It is a verification read, outside the engine, and nothing in parts 1-3 can
   reach it.
============================================================================ */

/* -- 4.1  compile and count every fragment -------------------------------- */

CREATE OR REPLACE TABLE GOLD.PREDICATE_CHECK_LOG (
    CHECKED_AT   TIMESTAMP_LTZ,
    ACTION_CODE  VARCHAR,
    FRAGMENT     VARCHAR,
    VERDICT      VARCHAR,
    OBSERVED     VARCHAR
);

COMMENT ON TABLE GOLD.PREDICATE_CHECK_LOG IS
'Output of GOLD.SP_CHECK_ACTION_PREDICATES: one row per catalogue SQL fragment, recording whether it compiles against GOLD.NBA_FEATURE_BASE and how many customers it fires on. Truncated and rewritten on each run. This is the compile-time safety net that storing predicates as text gives up -- 12 must not be run while any row here reads FAIL.';

CREATE OR REPLACE PROCEDURE GOLD.SP_CHECK_ACTION_PREDICATES()
RETURNS VARCHAR
LANGUAGE SQL
COMMENT = 'Compiles every ELIGIBILITY_SQL, SUPPRESSION_SQL and EXPECTED_VALUE_SQL in GOLD.ACTION_CATALOG against GOLD.NBA_FEATURE_BASE and writes the fire count, the NULL-return count or the error to GOLD.PREDICATE_CHECK_LOG. A fragment that returns NULL on any row is a FAIL, not a warning: 12 resolves a NULL suppression to "does not block", so a nullable fragment delegates a compliance decision to a harness default. Buys back the compile-time safety that storing predicates as text gives up. Zero AI credits; safe to re-run.'
AS
$$
DECLARE
    cur CURSOR FOR
        SELECT ACTION_CODE, ELIGIBILITY_SQL, SUPPRESSION_SQL, EXPECTED_VALUE_SQL
        FROM GOLD.V_ACTION_CATALOG_RESOLVED
        ORDER BY PRIORITY_TIER, ACTION_CODE;
    v_code  VARCHAR;
    v_elig  VARCHAR;
    v_supp  VARCHAR;
    v_ev    VARCHAR;
    v_from  VARCHAR;
    stmt    VARCHAR;
    n_fail  INTEGER DEFAULT 0;
BEGIN
    TRUNCATE TABLE GOLD.PREDICATE_CHECK_LOG;

    FOR rec IN cur DO
        v_code := rec.ACTION_CODE;
        v_elig := rec.ELIGIBILITY_SQL;
        v_supp := rec.SUPPRESSION_SQL;
        v_ev   := rec.EXPECTED_VALUE_SQL;

        /* The evaluation context every fragment is compiled against: one
           customer row cross joined to exactly this action's resolved row.
           Identical to the context 12 and 13 use, which is the point -- a
           fragment that compiles here compiles there. */
        v_from := ' FROM GOLD.NBA_FEATURE_BASE f'
               || ' CROSS JOIN (SELECT * FROM GOLD.V_ACTION_CATALOG_RESOLVED'
               || '             WHERE ACTION_CODE = ''' || v_code || ''') a';

        /* -- eligibility ------------------------------------------------- */
        BEGIN
            stmt := 'INSERT INTO GOLD.PREDICATE_CHECK_LOG'
                 || ' SELECT CURRENT_TIMESTAMP(), ''' || v_code || ''','
                 || ' ''ELIGIBILITY_SQL'','
                 || ' IFF(COUNT_IF((' || v_elig || ') IS NULL) = 0, ''COMPILES'', ''FAIL''),'
                 || ' ''fires on '' || COUNT_IF(' || v_elig || ') || '' customers'''
                 || '   || '', nulls: '' || COUNT_IF((' || v_elig || ') IS NULL)'
                 || v_from;
            EXECUTE IMMEDIATE :stmt;
        EXCEPTION WHEN OTHER THEN
            n_fail := n_fail + 1;
            INSERT INTO GOLD.PREDICATE_CHECK_LOG
            VALUES (CURRENT_TIMESTAMP(), :v_code, 'ELIGIBILITY_SQL', 'FAIL', :SQLERRM);
        END;

        /* -- suppression ------------------------------------------------- */
        BEGIN
            stmt := 'INSERT INTO GOLD.PREDICATE_CHECK_LOG'
                 || ' SELECT CURRENT_TIMESTAMP(), ''' || v_code || ''','
                 || ' ''SUPPRESSION_SQL'','
                 || ' IFF(COUNT_IF((' || v_supp || ') IS NULL) = 0, ''COMPILES'', ''FAIL''),'
                 || ' ''blocks '' || COUNT_IF(' || v_supp || ') || '' customers'''
                 || '   || '', nulls: '' || COUNT_IF((' || v_supp || ') IS NULL)'
                 || v_from;
            EXECUTE IMMEDIATE :stmt;
        EXCEPTION WHEN OTHER THEN
            n_fail := n_fail + 1;
            INSERT INTO GOLD.PREDICATE_CHECK_LOG
            VALUES (CURRENT_TIMESTAMP(), :v_code, 'SUPPRESSION_SQL', 'FAIL', :SQLERRM);
        END;

        /* -- expected value: must be numeric and never negative ----------- */
        BEGIN
            stmt := 'INSERT INTO GOLD.PREDICATE_CHECK_LOG'
                 || ' SELECT CURRENT_TIMESTAMP(), ''' || v_code || ''','
                 || ' ''EXPECTED_VALUE_SQL'','
                 || ' IFF(COUNT_IF((' || v_ev || ') < 0) = 0, ''COMPILES'', ''FAIL''),'
                 || ' ''max '' || TO_VARCHAR(ROUND(MAX(' || v_ev || ')), ''999,999,999'')'
                 || '   || '' INR, negatives: '' || COUNT_IF((' || v_ev || ') < 0)'
                 || v_from;
            EXECUTE IMMEDIATE :stmt;
        EXCEPTION WHEN OTHER THEN
            n_fail := n_fail + 1;
            INSERT INTO GOLD.PREDICATE_CHECK_LOG
            VALUES (CURRENT_TIMESTAMP(), :v_code, 'EXPECTED_VALUE_SQL', 'FAIL', :SQLERRM);
        END;
    END FOR;

    RETURN 'checked ' || (SELECT COUNT(*) FROM GOLD.PREDICATE_CHECK_LOG)
        || ' fragments, ' || n_fail || ' raised errors';
END;
$$;

CALL GOLD.SP_CHECK_ACTION_PREDICATES();

/* Per-fragment detail: failures first. */
SELECT ACTION_CODE, FRAGMENT, VERDICT, OBSERVED
FROM GOLD.PREDICATE_CHECK_LOG
ORDER BY IFF(VERDICT = 'FAIL', 0, 1), ACTION_CODE, FRAGMENT;

/* Gate: no fragment may fail. */
SELECT '11.4.1 every catalogue fragment compiles'              AS check_name,
       COUNT(*)                                                AS fragments,
       COUNT_IF(VERDICT = 'FAIL')                              AS failures,
       IFF(COUNT_IF(VERDICT = 'FAIL') = 0 AND COUNT(*) = 54, 'PASS', 'FAIL') AS verdict
FROM GOLD.PREDICATE_CHECK_LOG;


/* -- 4.2  catalogue structural invariants --------------------------------- */

SELECT '11.4.2a action count is 18'                            AS check_name,
       COUNT(*)                                                AS observed,
       IFF(COUNT(*) = 18, 'PASS', 'FAIL')                      AS verdict
FROM GOLD.ACTION_CATALOG
UNION ALL
SELECT '11.4.2b every PRODUCT_ID resolves in RAW.PRODUCT_CATALOG',
       COUNT_IF(PRODUCT_ID IS NOT NULL AND MARGIN_RATE IS NULL),
       IFF(COUNT_IF(PRODUCT_ID IS NOT NULL AND MARGIN_RATE IS NULL) = 0, 'PASS', 'FAIL')
FROM GOLD.V_ACTION_CATALOG_RESOLVED
UNION ALL
/* A sales action must never point at a product the catalogue permits for
   vulnerable customers, and a non-sales action must never point at one it
   forbids. The only ALLOWED_FOR_VULNERABLE product is SVC_HARDSHIP, and the
   only action pointing at it is the hardship review, which is not a sale. */
SELECT '11.4.2c IS_SALES_ACTION agrees with ALLOWED_FOR_VULNERABLE',
       COUNT_IF(PRODUCT_ID IS NOT NULL AND IS_SALES_ACTION = ALLOWED_FOR_VULNERABLE),
       IFF(COUNT_IF(PRODUCT_ID IS NOT NULL AND IS_SALES_ACTION = ALLOWED_FOR_VULNERABLE) = 0,
           'PASS', 'FAIL')
FROM GOLD.V_ACTION_CATALOG_RESOLVED
UNION ALL
SELECT '11.4.2d every channel has a CUSTOMER_360 consent column',
       COUNT_IF(CHANNEL NOT IN ('CALL', 'EMAIL', 'SMS')),
       IFF(COUNT_IF(CHANNEL NOT IN ('CALL', 'EMAIL', 'SMS')) = 0, 'PASS', 'FAIL')
FROM GOLD.ACTION_CATALOG
UNION ALL
SELECT '11.4.2e VALUE_ORIENTATION is one of two values',
       COUNT_IF(VALUE_ORIENTATION NOT IN ('ACQUISITION', 'RETENTION')),
       IFF(COUNT_IF(VALUE_ORIENTATION NOT IN ('ACQUISITION', 'RETENTION')) = 0, 'PASS', 'FAIL')
FROM GOLD.ACTION_CATALOG
UNION ALL
SELECT '11.4.2f every action carries a disclosure and a regulatory note',
       COUNT_IF(TRIM(REQUIRED_DISCLOSURE) = '' OR TRIM(REGULATORY_NOTE) = ''),
       IFF(COUNT_IF(TRIM(REQUIRED_DISCLOSURE) = '' OR TRIM(REGULATORY_NOTE) = '') = 0,
           'PASS', 'FAIL')
FROM GOLD.ACTION_CATALOG
UNION ALL
/* The corrected-proxy guarantee, as a structural check: no predicate in the
   catalogue may reuse the loose utilisation proxy from 08 line 1070. */
SELECT '11.4.2g no predicate reuses the 08 utilisation proxy',
       COUNT_IF(ELIGIBILITY_SQL ILIKE '%CREDIT_UTILISATION > 0.5%'),
       IFF(COUNT_IF(ELIGIBILITY_SQL ILIKE '%CREDIT_UTILISATION > 0.5%') = 0, 'PASS', 'FAIL')
FROM GOLD.ACTION_CATALOG
UNION ALL
/* Quarantine, asserted rather than assumed. */
/* Matches a real FROM / JOIN reference, not the substring. The first version
   used LIKE '%CUSTOMER_SEGMENT_TRUTH%' and failed on its own documentation:
   GET_DDL returns the COMMENT text, and the NBA_FEATURE_BASE comment says the
   view must not reference the answer key. A quarantine check that cannot
   distinguish a citation from a dependency is not a quarantine check. */
SELECT '11.4.2h nothing in layer 1 references the answer key',
       COUNT_IF(REGEXP_COUNT(UPPER(ddl),
                  '(FROM|JOIN)[[:space:]]+(RAW\\.)?CUSTOMER_SEGMENT_TRUTH') > 0),
       IFF(COUNT_IF(REGEXP_COUNT(UPPER(ddl),
                  '(FROM|JOIN)[[:space:]]+(RAW\\.)?CUSTOMER_SEGMENT_TRUTH') > 0) = 0,
           'PASS', 'FAIL')
FROM (SELECT GET_DDL('VIEW',  'GOLD.NBA_FEATURE_BASE')          AS ddl
      UNION ALL SELECT GET_DDL('TABLE', 'GOLD.ACTION_CATALOG')
      UNION ALL SELECT GET_DDL('VIEW',  'GOLD.V_ACTION_CATALOG_RESOLVED'))
UNION ALL
/* D6: the diagnostic-only slope must not have leaked into a predicate. */
SELECT '11.4.2i no predicate reads SENTIMENT_SLOPE_PER_30D',
       COUNT_IF(ELIGIBILITY_SQL ILIKE '%SENTIMENT_SLOPE%'
             OR SUPPRESSION_SQL ILIKE '%SENTIMENT_SLOPE%'
             OR EXPECTED_VALUE_SQL ILIKE '%SENTIMENT_SLOPE%'
             OR ARRAY_TO_STRING(PROPENSITY_FEATURES, ',') ILIKE '%SENTIMENT_SLOPE%'),
       IFF(COUNT_IF(ELIGIBILITY_SQL ILIKE '%SENTIMENT_SLOPE%'
             OR SUPPRESSION_SQL ILIKE '%SENTIMENT_SLOPE%'
             OR EXPECTED_VALUE_SQL ILIKE '%SENTIMENT_SLOPE%'
             OR ARRAY_TO_STRING(PROPENSITY_FEATURES, ',') ILIKE '%SENTIMENT_SLOPE%') = 0,
           'PASS', 'FAIL')
FROM GOLD.ACTION_CATALOG
ORDER BY check_name;


/* -- 4.3  planted-segment predicate accuracy ------------------------------
   THE ONLY READ OF RAW.CUSTOMER_SEGMENT_TRUTH IN THIS FILE.
   Verification only, outside the engine. Precision and recall of each
   segment-bearing action's eligibility against the quarantined key.
   ------------------------------------------------------------------------ */

WITH truth AS (
    SELECT CUSTOMER_ID, SEGMENT_CODE FROM RAW.CUSTOMER_SEGMENT_TRUTH
),
f AS (SELECT * FROM GOLD.NBA_FEATURE_BASE),
scored AS (
    SELECT 'RETENTION_SAVE_CALL'           AS action_code,
           'RETENTION_SAVE'                AS segment_code,
           COUNT_IF(f.DAYS_TO_RENEWAL BETWEEN 0 AND 30 AND f.COMPLAINT_RAISED_60D) AS fires,
           COUNT_IF(f.DAYS_TO_RENEWAL BETWEEN 0 AND 30 AND f.COMPLAINT_RAISED_60D
                    AND t.SEGMENT_CODE = 'RETENTION_SAVE')                         AS hits,
           COUNT_IF(t.SEGMENT_CODE = 'RETENTION_SAVE')                             AS planted
    FROM f JOIN truth t ON t.CUSTOMER_ID = f.CUSTOMER_ID

    UNION ALL
    /* THE CORRECTED PREDICATE, exactly as ACTION_CATALOG now states it: the
       four-reading monotonic chain and a clean book, and nothing else. The
       catalogue's age, income and tenure gates are NOT here, because they are
       not here in the catalogue either -- 12 applies them as named suppression
       rules from RAW.PRODUCT_CATALOG. They withhold the offer from 116 of these
       300 and each of those 116 gets a trace row saying which gate did it. */
    SELECT 'CARD_LIMIT_INCREASE', 'LIMIT_INCREASE',
           COUNT_IF(f.UTILISATION_RISING_4 AND f.CLEAN_REPAYMENT_EVER AND f.HAS_CARD),
           COUNT_IF(f.UTILISATION_RISING_4 AND f.CLEAN_REPAYMENT_EVER AND f.HAS_CARD
                    AND t.SEGMENT_CODE = 'LIMIT_INCREASE'),
           COUNT_IF(t.SEGMENT_CODE = 'LIMIT_INCREASE')
    FROM f JOIN truth t ON t.CUSTOMER_ID = f.CUSTOMER_ID

    UNION ALL
    SELECT 'HOME_PROTECTION_CROSS_SELL', 'PROTECTION_GAP',
           COUNT_IF(ARRAY_CONTAINS('Home Insurance'::VARIANT, f.PRODUCT_GAP)
                    AND f.HAS_HOME_LOAN),
           COUNT_IF(ARRAY_CONTAINS('Home Insurance'::VARIANT, f.PRODUCT_GAP)
                    AND f.HAS_HOME_LOAN AND t.SEGMENT_CODE = 'PROTECTION_GAP'),
           COUNT_IF(t.SEGMENT_CODE = 'PROTECTION_GAP')
    FROM f JOIN truth t ON t.CUSTOMER_ID = f.CUSTOMER_ID

    UNION ALL
    SELECT 'COLLECTIONS_HARDSHIP_OUTREACH', 'COLLECTIONS_HARDSHIP',
           COUNT_IF(f.MISSED_2_IN_6M AND f.DPD_RISING_3),
           COUNT_IF(f.MISSED_2_IN_6M AND f.DPD_RISING_3
                    AND t.SEGMENT_CODE = 'COLLECTIONS_HARDSHIP'),
           COUNT_IF(t.SEGMENT_CODE = 'COLLECTIONS_HARDSHIP')
    FROM f JOIN truth t ON t.CUSTOMER_ID = f.CUSTOMER_ID

    UNION ALL
    SELECT 'WEALTH_REFERRAL', 'WEALTH_REFERRAL',
           COUNT_IF(f.LUMPSUM_CREDIT_90D
                    AND ARRAY_CONTAINS('Investment (ULIP)'::VARIANT, f.PRODUCT_GAP)),
           COUNT_IF(f.LUMPSUM_CREDIT_90D
                    AND ARRAY_CONTAINS('Investment (ULIP)'::VARIANT, f.PRODUCT_GAP)
                    AND t.SEGMENT_CODE = 'WEALTH_REFERRAL'),
           COUNT_IF(t.SEGMENT_CODE = 'WEALTH_REFERRAL')
    FROM f JOIN truth t ON t.CUSTOMER_ID = f.CUSTOMER_ID
)
SELECT action_code,
       segment_code,
       planted,
       fires,
       hits,
       ROUND(100.0 * hits / NULLIF(fires,   0), 1) AS precision_pct,
       ROUND(100.0 * hits / NULLIF(planted, 0), 1) AS recall_pct,
       IFF(hits = planted AND fires = planted, 'EXACT',
           IFF(hits = planted, 'FULL RECALL, OVER-FIRES', 'RECALL LOSS')) AS verdict
FROM scored
ORDER BY action_code;

/* Gate: all five segment-bearing predicates must be EXACT. Recall loss or
   over-firing here means a predicate drifted from docs/DATA_SEGMENTS.md. */
WITH truth AS (SELECT CUSTOMER_ID, SEGMENT_CODE FROM RAW.CUSTOMER_SEGMENT_TRUTH),
f AS (SELECT * FROM GOLD.NBA_FEATURE_BASE),
scored AS (
    SELECT COUNT_IF(f.DAYS_TO_RENEWAL BETWEEN 0 AND 30 AND f.COMPLAINT_RAISED_60D) AS fires,
           COUNT_IF(t.SEGMENT_CODE = 'RETENTION_SAVE')                             AS planted,
           COUNT_IF(f.DAYS_TO_RENEWAL BETWEEN 0 AND 30 AND f.COMPLAINT_RAISED_60D
                    AND t.SEGMENT_CODE = 'RETENTION_SAVE')                         AS hits
    FROM f JOIN truth t ON t.CUSTOMER_ID = f.CUSTOMER_ID
    UNION ALL
    SELECT COUNT_IF(f.UTILISATION_RISING_4 AND f.CLEAN_REPAYMENT_EVER AND f.HAS_CARD),
           COUNT_IF(t.SEGMENT_CODE = 'LIMIT_INCREASE'),
           COUNT_IF(f.UTILISATION_RISING_4 AND f.CLEAN_REPAYMENT_EVER AND f.HAS_CARD
                    AND t.SEGMENT_CODE = 'LIMIT_INCREASE')
    FROM f JOIN truth t ON t.CUSTOMER_ID = f.CUSTOMER_ID
    UNION ALL
    SELECT COUNT_IF(ARRAY_CONTAINS('Home Insurance'::VARIANT, f.PRODUCT_GAP) AND f.HAS_HOME_LOAN),
           COUNT_IF(t.SEGMENT_CODE = 'PROTECTION_GAP'),
           COUNT_IF(ARRAY_CONTAINS('Home Insurance'::VARIANT, f.PRODUCT_GAP) AND f.HAS_HOME_LOAN
                    AND t.SEGMENT_CODE = 'PROTECTION_GAP')
    FROM f JOIN truth t ON t.CUSTOMER_ID = f.CUSTOMER_ID
    UNION ALL
    SELECT COUNT_IF(f.MISSED_2_IN_6M AND f.DPD_RISING_3),
           COUNT_IF(t.SEGMENT_CODE = 'COLLECTIONS_HARDSHIP'),
           COUNT_IF(f.MISSED_2_IN_6M AND f.DPD_RISING_3
                    AND t.SEGMENT_CODE = 'COLLECTIONS_HARDSHIP')
    FROM f JOIN truth t ON t.CUSTOMER_ID = f.CUSTOMER_ID
    UNION ALL
    SELECT COUNT_IF(f.LUMPSUM_CREDIT_90D AND ARRAY_CONTAINS('Investment (ULIP)'::VARIANT, f.PRODUCT_GAP)),
           COUNT_IF(t.SEGMENT_CODE = 'WEALTH_REFERRAL'),
           COUNT_IF(f.LUMPSUM_CREDIT_90D AND ARRAY_CONTAINS('Investment (ULIP)'::VARIANT, f.PRODUCT_GAP)
                    AND t.SEGMENT_CODE = 'WEALTH_REFERRAL')
    FROM f JOIN truth t ON t.CUSTOMER_ID = f.CUSTOMER_ID
)
SELECT '11.4.3 all five planted predicates exact'                      AS check_name,
       COUNT_IF(fires <> planted OR hits <> planted)                   AS inexact,
       IFF(COUNT_IF(fires <> planted OR hits <> planted) = 0, 'PASS', 'FAIL') AS verdict
FROM scored;


/* -- 4.3b  the correction, stated as a number -----------------------------
   Side by side: the placeholder proxy from 08_gold_c360.sql line 1070 against
   the real four-reading predicate carried by CARD_LIMIT_INCREASE. Both find
   all 300; only one of them stops there.
   ------------------------------------------------------------------------ */

WITH truth AS (SELECT CUSTOMER_ID FROM RAW.CUSTOMER_SEGMENT_TRUTH
               WHERE SEGMENT_CODE = 'LIMIT_INCREASE'),
f AS (SELECT * FROM GOLD.NBA_FEATURE_BASE)
SELECT '08 proxy: HAS_CARD AND CREDIT_UTILISATION > 0.50 AND MISSED_PAYMENTS_12M = 0' AS predicate,
       COUNT_IF(f.HAS_CARD AND f.CREDIT_UTILISATION > 0.50 AND f.MISSED_PAYMENTS_12M = 0) AS fires,
       COUNT_IF(f.HAS_CARD AND f.CREDIT_UTILISATION > 0.50 AND f.MISSED_PAYMENTS_12M = 0
                AND f.CUSTOMER_ID IN (SELECT CUSTOMER_ID FROM truth))                     AS hits,
       ROUND(100.0 * COUNT_IF(f.HAS_CARD AND f.CREDIT_UTILISATION > 0.50
                AND f.MISSED_PAYMENTS_12M = 0
                AND f.CUSTOMER_ID IN (SELECT CUSTOMER_ID FROM truth))
             / NULLIF(COUNT_IF(f.HAS_CARD AND f.CREDIT_UTILISATION > 0.50
                AND f.MISSED_PAYMENTS_12M = 0), 0), 1)                                    AS precision_pct
FROM f
UNION ALL
SELECT '11 real: UTILISATION_RISING_4 AND CLEAN_REPAYMENT_EVER (S2)',
       COUNT_IF(f.UTILISATION_RISING_4 AND f.CLEAN_REPAYMENT_EVER),
       COUNT_IF(f.UTILISATION_RISING_4 AND f.CLEAN_REPAYMENT_EVER
                AND f.CUSTOMER_ID IN (SELECT CUSTOMER_ID FROM truth)),
       ROUND(100.0 * COUNT_IF(f.UTILISATION_RISING_4 AND f.CLEAN_REPAYMENT_EVER
                AND f.CUSTOMER_ID IN (SELECT CUSTOMER_ID FROM truth))
             / NULLIF(COUNT_IF(f.UTILISATION_RISING_4 AND f.CLEAN_REPAYMENT_EVER), 0), 1)
FROM f;


SELECT 'GOLD.NBA_FEATURE_BASE, GOLD.ACTION_CATALOG (18), GOLD.V_ACTION_CATALOG_RESOLVED built'
         AS status,
       (SELECT COUNT(*) FROM GOLD.ACTION_CATALOG)        AS actions,
       (SELECT COUNT(*) FROM GOLD.NBA_FEATURE_BASE)      AS customers,
       (SELECT COUNT(*) FROM GOLD.ACTION_CATALOG)
         * (SELECT COUNT(*) FROM GOLD.NBA_FEATURE_BASE)  AS layer2_candidate_rows;

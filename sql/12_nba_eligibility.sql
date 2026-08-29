/* ============================================================================
   12_nba_eligibility.sql  —  GOLD.NBA_COOLDOWN_STATE
                              GOLD.NBA_PREDICATE_EVAL
                              GOLD.NBA_ELIGIBLE
   ----------------------------------------------------------------------------
   Layer 2: who may be offered what, and — for everyone who may not — which
   rule stopped it and what value that rule fired on.

   No AI. Zero credits, re-runnable. 5,000 customers x 18 actions = 90,000 rows,
   and all 90,000 survive to the final table. Nothing is filtered away.

   That last point is the design. A recommendation engine that returns only its
   winners cannot be audited, cannot be challenged by a compliance reviewer, and
   cannot answer the one question a regulator actually asks: not "why did you
   contact this customer" but "why did you NOT contact that one". Suppressed
   rows are the answer to the second question, so they are rows.

   ----------------------------------------------------------------------------
   HOW THE PREDICATES GET EVALUATED
   ----------------------------------------------------------------------------
   Two of the rules per action are stored as SQL text in GOLD.ACTION_CATALOG and
   cannot be evaluated by static SQL. Everything else can. So the file splits:

     GOLD.NBA_PREDICATE_EVAL   36 generated fragments -- ELIGIBILITY_SQL,
                               SUPPRESSION_SQL and EXPECTED_VALUE_SQL per
                               action, evaluated by a UNION ALL that
                               SP_BUILD_PREDICATE_EVAL assembles from the
                               catalogue. Deliberately thin: three booleans and
                               a number per (customer, action).

     GOLD.NBA_ELIGIBLE         one static, readable query over that table. All
                               twelve generic rules -- five commercial gates
                               from RAW.PRODUCT_CATALOG, six global
                               suppressions, one cooldown -- are written ONCE
                               here rather than eighteen times in generated
                               text.

   The generated SQL is therefore as small as the "catalogue is the single source
   of truth" requirement allows, and the compliance logic a reviewer needs to
   read is ordinary SQL in this file.

   ----------------------------------------------------------------------------
   PREFLIGHT: THIS SCRIPT REFUSES TO RUN ON A BROKEN CATALOGUE
   ----------------------------------------------------------------------------
   Part 0 calls GOLD.SP_CHECK_ACTION_PREDICATES and then raises if any fragment
   failed to compile. The reason is specific: a typo in a stored predicate does
   not produce an error here, it produces a *wrong eligibility trace* -- a row
   asserting a customer failed a rule that never actually ran. A blocked run is
   recoverable. A confidently wrong audit trail is the failure this engine
   exists to avoid.

   ----------------------------------------------------------------------------
   THE TWELVE GENERIC RULES
   ----------------------------------------------------------------------------
   Commercial gates, from RAW.PRODUCT_CATALOG, for actions with a PRODUCT_ID:

     GATE_AGE           AGE outside [MIN_AGE, MAX_AGE]
     GATE_INCOME_BAND   INCOME_BAND_RANK < MIN_INCOME_BAND_RANK
     GATE_TENURE        TENURE_YEARS * 12 < MIN_TENURE_MONTHS
     GATE_KYC           REQUIRED_KYC_STATUS is VERIFIED and KYC_CURRENT is false
     GATE_DPD           worst DPD bucket exceeds MAX_DPD_DAYS

   These are the gates moved out of ELIGIBILITY_SQL in 11. They are driven off
   structured catalogue columns, not text, so adding a product to
   RAW.PRODUCT_CATALOG gets its gates evaluated with no change to this file.

   Global suppressions, per the milestone spec:

     GLOBAL_DNC              DNC registry marker
     GLOBAL_CHANNEL_CONSENT  no live consent on the action's channel
     GLOBAL_OPEN_COMPLAINT   unresolved grievance
     GLOBAL_VULNERABILITY    vulnerability flag, sales actions only
     GLOBAL_ARREARS          DPD bucket beyond CURRENT, cross-sell
     GLOBAL_COOLDOWN         same action contacted inside COOLDOWN_DAYS

   Three of those needed a scoping decision, and each is recorded below rather
   than made quietly, because each changes who gets contacted.

   ----------------------------------------------------------------------------
   SCOPING DECISION 1 — GLOBAL_OPEN_COMPLAINT applies to SALES actions only
   ----------------------------------------------------------------------------
   The spec lists "open complaint" as a global suppression on every action.
   Applied literally it is self-contradictory:

     COMPLAINT_RESOLUTION_CALLBACK's entire eligibility is having an open
     complaint of severity 3+. A flat rule makes it eligible and then instantly
     suppresses it, so the grievance callback is the one action that can never
     fire — and 229 unresolved severity-3+ grievances get no action at all.

     RETENTION_SAVE_CALL is planted segment S1: renewal within 30 days AND a
     complaint in the last 60. A flat rule suppresses all 400, deleting the
     highest-value cohort in the dataset. The action's own REGULATORY_NOTE
     already records why that is wrong: under the IRDAI policyholder-protection
     regulations renewal servicing contact on an in-force policy is permitted
     during an open grievance and is not a solicitation.

   So the rule is what the spec means rather than what it says: you do not SELL
   to a customer with an unresolved grievance. Service, retention and collections
   actions — the ones that exist to resolve it — are exempt. Scoped on
   IS_SALES_ACTION, exactly like the vulnerability gate the spec already scopes
   that way. Part 4.4 reports the row count this changes.

   ----------------------------------------------------------------------------
   SCOPING DECISION 2 — GLOBAL_DNC governs CALL and SMS, not EMAIL
   ----------------------------------------------------------------------------
   CUSTOMER_360.DNC_FLAG carries its own instruction, and it is worth quoting
   because it decides this: "Do-not-contact registry marker on the CALL or SMS
   channel -- the channels a DNC registry governs in this market. NOT an
   any-channel reading, which would flag 2,285 (46%) and stop discriminating."

   Reading that column as a bar on EMAIL would use it against its documented
   meaning, and would block email to a customer whose only registry entry is on
   telephone. A DNC registry does not govern email in this market; consent does,
   and GLOBAL_CHANNEL_CONSENT already reads CONSENT_EMAIL, which folds DNC,
   opt-in and the validity window together for that channel.

   GLOBAL_DNC therefore fires on CALL and SMS actions. Part 4.4 reports what a
   flat any-channel reading would additionally have blocked, so the decision is
   reversible on a number rather than an argument.

   ----------------------------------------------------------------------------
   SCOPING DECISION 3 — the arrears gate, and one addition beyond the spec
   ----------------------------------------------------------------------------
   The spec says "dpd_bucket > 0 for any cross-sell". Implemented literally as
   GLOBAL_ARREARS.

   But UPSELL and WEALTH are also sales, and an upsell to a customer in arrears
   is the same mistake as a cross-sell to one. Rather than silently widen the
   spec's rule, this is a SECOND, separately named rule —
   GLOBAL_ARREARS_NON_CROSS_SELL — so the spec rule stays verifiable on its own
   count and the addition can be dropped by deleting one CASE arm. Part 4.4
   reports its incremental effect separately.

   ----------------------------------------------------------------------------
   SCOPING DECISION 4 — DNC IS WAIVED FOR TWO SERVICING OBLIGATIONS, CONSENT IS NOT
   ----------------------------------------------------------------------------
   Under the literal reading, 67 of the 200 COLLECTIONS_HARDSHIP_OUTREACH
   customers and 118 of the 229 COMPLAINT_RESOLUTION_CALLBACK customers were
   fully suppressed -- people in rising arrears, and people with unresolved
   severity-3+ grievances, receiving no action at all.

   TRAI TCCCPR restricts the DNC/NCPR registry to PROMOTIONAL contact;
   transactional and servicing communication is outside it. A hardship review and
   a grievance callback are servicing obligations, not solicitations. So
   GLOBAL_DNC is waived for the two actions carrying
   ACTION_CATALOG.IS_SERVICING_OBLIGATION.

   GLOBAL_CHANNEL_CONSENT is NOT waived, and the reason is evidential rather
   than cautious. The question asked of the schema was whether consent is scoped
   to promotional contact, the same question that decided the CALL/SMS-vs-EMAIL
   split for DNC. It is not:

     - RAW.CONSENT has no purpose column at all. Its columns are CHANNEL,
       OPT_IN_FLAG, DNC_FLAG, VALID_FROM, VALID_TO, CONSENT_SOURCE -- nothing
       distinguishes marketing from servicing anywhere in the model.
     - CUSTOMER_360.CONSENT_CALL documents itself as "Permission to contact by
       call ... opted in AND not DNC AND inside the consent validity window, all
       three". Two of those three components carry no purpose qualifier.
     - CONSENT_SOURCE is capture provenance, not scope, and TRAI_DNC_REGISTRY is
       one of six sources feeding it -- the registry CONTRIBUTES to consent
       rather than constituting it.

   Consent therefore reads as a blanket contact permission, and waiving it would
   mean inventing a promotional-only scope the data model does not have. The
   exemption is precisely as wide as the evidence supports and no wider: DNC
   yes, consent no. Recorded as PROJECT_BRIEF D7.

   Two consequences worth stating plainly. The waiver is visible, not silent —
   the trace carries verdict EXEMPT with its justification, RULES_EXEMPT is a
   separate array from RULES_NOT_APPLICABLE, and part 4.8 counts the recovery.
   And it does not recover everyone: a customer with a hardship need and no live
   consent on any channel still gets no action, which is the correct answer to a
   question about contactability rather than a failure of the engine.

   ----------------------------------------------------------------------------
   COOLDOWN HAS THREE VERDICTS, NOT TWO
   ----------------------------------------------------------------------------
   RAW.CAMPAIGN_HISTORY is a record of outbound SOLICITATION and covers eight
   product codes. Seven of the eleven product-backed actions match it directly;
   WEALTH_REFERRAL matches INS_ULIP_BAL, because a wealth referral and a
   unit-linked pitch are the same conversation from the customer's side and the
   catalogue models a ULIP as the investment product.

   The remaining ten actions — every retention, service-recovery and collections
   action, plus three products never campaigned — have no outbound analogue. For
   those the cooldown verdict is NOT_APPLICABLE with the reason stated, not
   PASS. A PASS would assert a check succeeded when no check was possible, and
   that is the same class of lie as a missing suppression row.

   Deliberately NOT used as a substitute: CUSTOMER_360.LAST_CONTACT_DAYS. That
   measures INBOUND servicing contact. Treating it as a cooldown would suppress
   a retention call precisely because the customer just rang in about their
   renewal, which inverts the signal.

   ----------------------------------------------------------------------------
   NULL HANDLING, AND WHY IT IS VERIFIED RATHER THAN ASSUMED
   ----------------------------------------------------------------------------
   A predicate over a NULL column returns NULL, not FALSE. Eligibility treats
   NULL as FALSE (absent evidence is not eligibility). Suppression treats NULL as
   FALSE too — which is the UNSAFE direction, since unknown ought to block — so
   part 4.2 asserts that no suppression fragment returns NULL on any of the
   90,000 rows. The permissive default is therefore never exercised, and if a
   future predicate makes it reachable the check fails rather than quietly
   letting a suppression lapse.
============================================================================ */

USE ROLE COCO_BUILDER;
USE DATABASE C360_NBA;
USE SCHEMA GOLD;
USE WAREHOUSE COCO_WH;


/* ============================================================================
   PART 0  —  PREFLIGHT
============================================================================ */

CALL GOLD.SP_CHECK_ACTION_PREDICATES();

SELECT ACTION_CODE, FRAGMENT, VERDICT, OBSERVED
FROM GOLD.PREDICATE_CHECK_LOG
ORDER BY IFF(VERDICT = 'FAIL', 0, 1), ACTION_CODE, FRAGMENT;

SELECT '12.0 preflight: catalogue fragments compile'   AS check_name,
       COUNT(*)                                        AS fragments,
       COUNT_IF(VERDICT = 'FAIL')                      AS failures,
       IFF(COUNT_IF(VERDICT = 'FAIL') = 0, 'PASS', 'ABORT') AS verdict
FROM GOLD.PREDICATE_CHECK_LOG;

CREATE OR REPLACE PROCEDURE GOLD.SP_ASSERT_PREDICATES_CLEAN()
RETURNS VARCHAR
LANGUAGE SQL
COMMENT = 'Raises if any row of GOLD.PREDICATE_CHECK_LOG reads FAIL, or if the log is empty. Called at the top of 12 so a stored-predicate typo blocks the run instead of producing an eligibility trace that asserts a rule was evaluated when it was not.'
AS
$$
DECLARE
    n_fail    INTEGER;
    n_rows    INTEGER;
    BROKEN    EXCEPTION (-20501, 'ABORT: GOLD.ACTION_CATALOG contains predicates that do not compile. Fix the catalogue and re-run 11 before running 12. See GOLD.PREDICATE_CHECK_LOG.');
    NOT_RUN   EXCEPTION (-20502, 'ABORT: GOLD.PREDICATE_CHECK_LOG is empty. Run 11_action_catalog.sql first.');
BEGIN
    SELECT COUNT_IF(VERDICT = 'FAIL'), COUNT(*)
      INTO :n_fail, :n_rows
      FROM GOLD.PREDICATE_CHECK_LOG;

    IF (n_rows = 0) THEN
        RAISE NOT_RUN;
    END IF;
    IF (n_fail > 0) THEN
        RAISE BROKEN;
    END IF;
    RETURN 'preflight clean: ' || n_rows || ' fragments compile, 0 failures';
END;
$$;

CALL GOLD.SP_ASSERT_PREDICATES_CLEAN();


/* ============================================================================
   PART 1  —  GOLD.NBA_COOLDOWN_STATE
   ----------------------------------------------------------------------------
   Last outbound solicitation per customer per product code, from
   RAW.CAMPAIGN_HISTORY. One row per (customer, product) pair ever contacted.
============================================================================ */

CREATE OR REPLACE TABLE GOLD.NBA_COOLDOWN_STATE AS
SELECT
    CUSTOMER_ID,
    PRODUCT_CODE,
    MAX(CONTACTED_AT)                                            AS LAST_CONTACTED_AT,
    DATEDIFF(day, MAX(CONTACTED_AT), RAW.AS_OF())                AS DAYS_SINCE_CONTACT,
    COUNT(*)                                                     AS CONTACTS_EVER,
    COUNT_IF(CONTACTED_AT >= DATEADD(day, -365, RAW.AS_OF()))    AS CONTACTS_365D,
    MAX_BY(OUTCOME, CONTACTED_AT)                                AS LAST_OUTCOME,
    MAX_BY(CHANNEL, CONTACTED_AT)                                AS LAST_CHANNEL,
    BOOLOR_AGG(OUTCOME = 'OPT_OUT')                              AS EVER_OPTED_OUT,
    BOOLOR_AGG(OUTCOME = 'COMPLAINED')                           AS EVER_COMPLAINED
FROM RAW.CAMPAIGN_HISTORY
GROUP BY 1, 2;

COMMENT ON TABLE GOLD.NBA_COOLDOWN_STATE IS
'Last outbound solicitation per customer per product code, from RAW.CAMPAIGN_HISTORY, for the GLOBAL_COOLDOWN rule in GOLD.NBA_ELIGIBLE. Covers the eight product codes that were actually campaigned; actions with no matching code receive cooldown verdict NOT_APPLICABLE rather than PASS. EVER_OPTED_OUT and EVER_COMPLAINED are carried for M6 and are NOT currently suppression inputs -- a product-level opt-out is already reflected in the consent registry that GLOBAL_CHANNEL_CONSENT reads.';


/* ============================================================================
   PART 2  —  GOLD.NBA_PREDICATE_EVAL
   ----------------------------------------------------------------------------
   The generated layer, and the only generated layer. Three fragments per
   action evaluated against every customer.
============================================================================ */

CREATE OR REPLACE PROCEDURE GOLD.SP_BUILD_PREDICATE_EVAL()
RETURNS VARCHAR
LANGUAGE SQL
COMMENT = 'Assembles and runs one UNION ALL over GOLD.ACTION_CATALOG that evaluates every stored ELIGIBILITY_SQL, SUPPRESSION_SQL and EXPECTED_VALUE_SQL against GOLD.NBA_FEATURE_BASE, writing GOLD.NBA_PREDICATE_EVAL at (customer x action) grain. The catalogue text is the only thing generated; every generic compliance rule is static SQL in GOLD.NBA_ELIGIBLE. Zero AI credits.'
AS
$$
DECLARE
    cur CURSOR FOR
        SELECT ACTION_CODE, ELIGIBILITY_SQL, SUPPRESSION_SQL, EXPECTED_VALUE_SQL
        FROM GOLD.V_ACTION_CATALOG_RESOLVED
        ORDER BY ACTION_CODE;
    v_code  VARCHAR;
    v_elig  VARCHAR;
    v_supp  VARCHAR;
    v_ev    VARCHAR;
    sql_txt VARCHAR DEFAULT '';
    n_act   INTEGER DEFAULT 0;
BEGIN
    FOR rec IN cur DO
        v_code := rec.ACTION_CODE;
        v_elig := rec.ELIGIBILITY_SQL;
        v_supp := rec.SUPPRESSION_SQL;
        v_ev   := rec.EXPECTED_VALUE_SQL;

        IF (n_act > 0) THEN
            sql_txt := sql_txt || '  UNION ALL\n';
        END IF;

        /* Three fragments, plus the RAW result of each predicate kept
           un-coalesced alongside so part 4.2 can prove the NULL default is
           never exercised rather than assuming it. */
        sql_txt := sql_txt
          || '  SELECT f.CUSTOMER_ID,\n'
          || '         ''' || v_code || ''' AS ACTION_CODE,\n'
          || '         COALESCE(' || v_elig || ', FALSE)      AS ELIGIBLE_ON_NEED,\n'
          || '         (' || v_elig || ') IS NULL             AS ELIG_WAS_NULL,\n'
          || '         COALESCE(' || v_supp || ', FALSE)      AS SUPPRESSED_ACTION_SPECIFIC,\n'
          || '         (' || v_supp || ') IS NULL             AS SUPP_WAS_NULL,\n'
          || '         COALESCE(' || v_ev   || ', 0)::FLOAT   AS VALUE_AT_STAKE_INR\n'
          || '  FROM GOLD.NBA_FEATURE_BASE f\n'
          || '  CROSS JOIN (SELECT * FROM GOLD.V_ACTION_CATALOG_RESOLVED\n'
          || '              WHERE ACTION_CODE = ''' || v_code || ''') a\n';

        n_act := n_act + 1;
    END FOR;

    sql_txt := 'CREATE OR REPLACE TABLE GOLD.NBA_PREDICATE_EVAL AS\n' || sql_txt;
    EXECUTE IMMEDIATE :sql_txt;

    RETURN 'GOLD.NBA_PREDICATE_EVAL built from ' || n_act || ' actions, '
        || (SELECT COUNT(*) FROM GOLD.NBA_PREDICATE_EVAL) || ' rows';
END;
$$;

CALL GOLD.SP_BUILD_PREDICATE_EVAL();

COMMENT ON TABLE GOLD.NBA_PREDICATE_EVAL IS
'Result of evaluating the three stored SQL fragments per action against every customer: (customer x action) grain, 90,000 rows. Built by GOLD.SP_BUILD_PREDICATE_EVAL, which is the only generated SQL in the engine. ELIG_WAS_NULL / SUPP_WAS_NULL preserve whether the raw predicate returned NULL before COALESCE, so 12 part 4.2 can assert the NULL default is never exercised. Consumed by GOLD.NBA_ELIGIBLE; not intended for direct use.';


/* ============================================================================
   PART 3  —  GOLD.NBA_ELIGIBLE
   ----------------------------------------------------------------------------
   Every rule, every verdict, every row. 90,000 in, 90,000 out.

   Rule verdicts:
     PASS            the rule was evaluated and did not block
     BLOCK           the rule was evaluated and blocked the action
     FAIL            eligibility only: the need is not present
     NOT_APPLICABLE  the rule does not apply, with the reason stated

   FINAL_VERDICT:
     ELIGIBLE        need present, nothing blocked
     SUPPRESSED      need present, at least one rule blocked
     NOT_ELIGIBLE    need not present. Suppressions still evaluated and traced,
                     because "would have been blocked anyway" is worth knowing.
============================================================================ */

CREATE OR REPLACE TABLE GOLD.NBA_ELIGIBLE AS
WITH ev AS (
    SELECT e.*,
           a.ACTION_NAME, a.CATEGORY, a.PRODUCT_ID, a.CHANNEL,
           a.IS_SALES_ACTION, a.PRIORITY_TIER, a.VALUE_ORIENTATION,
           a.IS_SERVICING_OBLIGATION,
           a.COOLDOWN_DAYS, a.REGULATORY_NOTE, a.REQUIRED_DISCLOSURE,
           a.PROPENSITY_FEATURES, a.ELIGIBILITY_SQL, a.SUPPRESSION_SQL,
           a.MIN_AGE, a.MAX_AGE, a.MIN_INCOME_BAND_RANK, a.MIN_TENURE_MONTHS,
           a.REQUIRED_KYC_STATUS, a.MAX_DPD_DAYS, a.MARGIN_RATE,
           /* Cooldown match key. WEALTH_REFERRAL has no PRODUCT_ID but its
              outbound analogue is the unit-linked pitch. */
           CASE WHEN e.ACTION_CODE = 'WEALTH_REFERRAL' THEN 'INS_ULIP_BAL'
                ELSE a.PRODUCT_ID END                             AS COOLDOWN_MATCH_CODE,
           f.AGE, f.INCOME_BAND_RANK, f.TENURE_YEARS, f.KYC_CURRENT,
           f.DPD_BUCKET, f.DNC_FLAG, f.VULNERABILITY_FLAG, f.OPEN_COMPLAINT,
           f.CONSENT_CALL, f.CONSENT_EMAIL, f.CONSENT_SMS,
           f.OPEN_COMPLAINT_SEVERITY, f.PREFERRED_CHANNEL
    FROM GOLD.NBA_PREDICATE_EVAL e
    JOIN GOLD.V_ACTION_CATALOG_RESOLVED a ON a.ACTION_CODE = e.ACTION_CODE
    JOIN GOLD.NBA_FEATURE_BASE          f ON f.CUSTOMER_ID = e.CUSTOMER_ID
),
r AS (
    SELECT ev.*,

        /* -- consent on the action's own channel ------------------------- */
        CASE ev.CHANNEL WHEN 'CALL'  THEN ev.CONSENT_CALL
                        WHEN 'EMAIL' THEN ev.CONSENT_EMAIL
                        WHEN 'SMS'   THEN ev.CONSENT_SMS END      AS CHANNEL_CONSENT,

        /* -- worst DPD in days, from the bucket vocabulary -------------- */
        CASE ev.DPD_BUCKET WHEN 'NO_CREDIT_OBLIGATION' THEN 0
                           WHEN 'CURRENT'              THEN 0
                           WHEN '1-30'                 THEN 30
                           WHEN '31-60'                THEN 60
                           WHEN '61-90'                THEN 90
                           WHEN '90+'                  THEN 999 END AS DPD_DAYS_WORST,

        cd.DAYS_SINCE_CONTACT,
        cd.LAST_CONTACTED_AT,
        cd.LAST_OUTCOME
    FROM ev
    LEFT JOIN GOLD.NBA_COOLDOWN_STATE cd
           ON cd.CUSTOMER_ID  = ev.CUSTOMER_ID
          AND cd.PRODUCT_CODE = ev.COOLDOWN_MATCH_CODE
),
v AS (
    SELECT r.*,

        /* ================= COMMERCIAL GATES  (product-backed only) ===== */
        r.PRODUCT_ID IS NOT NULL
          AND NOT (r.AGE BETWEEN r.MIN_AGE AND r.MAX_AGE)              AS B_GATE_AGE,
        r.PRODUCT_ID IS NOT NULL
          AND r.INCOME_BAND_RANK < r.MIN_INCOME_BAND_RANK              AS B_GATE_INCOME,
        r.PRODUCT_ID IS NOT NULL
          AND r.TENURE_YEARS * 12 < r.MIN_TENURE_MONTHS                AS B_GATE_TENURE,
        r.PRODUCT_ID IS NOT NULL
          AND r.REQUIRED_KYC_STATUS = 'VERIFIED'
          AND NOT r.KYC_CURRENT                                        AS B_GATE_KYC,
        r.PRODUCT_ID IS NOT NULL
          AND r.DPD_DAYS_WORST > r.MAX_DPD_DAYS                        AS B_GATE_DPD,

        /* ================= GLOBAL SUPPRESSIONS ========================= */

        /* DNC registry: CALL and SMS only (scoping decision 2), and not at all
           for the two servicing obligations (scoping decision 4 / D7). */
        r.DNC_FLAG AND r.CHANNEL IN ('CALL', 'SMS')
          AND NOT r.IS_SERVICING_OBLIGATION                            AS B_DNC,
        r.DNC_FLAG AND r.CHANNEL IN ('CALL', 'SMS')
          AND r.IS_SERVICING_OBLIGATION                                AS DNC_WAIVED,

        /* No live consent on the channel the action would use. */
        NOT COALESCE(r.CHANNEL_CONSENT, FALSE)                         AS B_CONSENT,

        /* Unresolved grievance blocks SALES only. See scoping decision 1. */
        r.OPEN_COMPLAINT AND r.IS_SALES_ACTION                         AS B_COMPLAINT,

        /* Vulnerability gate: no solicitation to a flagged customer. */
        r.VULNERABILITY_FLAG AND r.IS_SALES_ACTION                     AS B_VULNERABLE,

        /* Spec rule, verbatim: arrears blocks cross-sell. */
        r.DPD_DAYS_WORST > 0 AND r.CATEGORY = 'CROSS_SELL'             AS B_ARREARS_XS,

        /* Addition beyond spec, separately named. See scoping decision 3. */
        r.DPD_DAYS_WORST > 0 AND r.IS_SALES_ACTION
          AND r.CATEGORY <> 'CROSS_SELL'                               AS B_ARREARS_OTHER,

        /* Cooldown, three-valued. */
        r.COOLDOWN_MATCH_CODE IS NOT NULL
          AND r.DAYS_SINCE_CONTACT IS NOT NULL                         AS COOLDOWN_TESTABLE,
        r.COOLDOWN_MATCH_CODE IS NOT NULL
          AND r.DAYS_SINCE_CONTACT IS NOT NULL
          AND r.DAYS_SINCE_CONTACT < r.COOLDOWN_DAYS                   AS B_COOLDOWN
    FROM r
),
t AS (
    SELECT v.*,

        /* -- the trace. One object per rule that applies, each carrying the
              value it fired on so the verdict is replayable. --------------- */
        ARRAY_CONSTRUCT_COMPACT(
            OBJECT_CONSTRUCT('rule', 'ELIGIBILITY', 'kind', 'NEED',
                'verdict', IFF(v.ELIGIBLE_ON_NEED, 'PASS', 'FAIL'),
                'observed', v.ELIGIBILITY_SQL),

            IFF(v.SUPPRESSION_SQL = 'FALSE', NULL,
                OBJECT_CONSTRUCT('rule', 'ACTION_SUPPRESSION', 'kind', 'ACTION',
                    'verdict', IFF(v.SUPPRESSED_ACTION_SPECIFIC, 'BLOCK', 'PASS'),
                    'observed', v.SUPPRESSION_SQL)),

            IFF(v.PRODUCT_ID IS NULL, NULL,
                OBJECT_CONSTRUCT('rule', 'GATE_AGE', 'kind', 'COMMERCIAL',
                    'verdict', IFF(v.B_GATE_AGE, 'BLOCK', 'PASS'),
                    'observed', 'age ' || v.AGE || ' vs permitted '
                                || v.MIN_AGE || '-' || v.MAX_AGE)),
            IFF(v.PRODUCT_ID IS NULL, NULL,
                OBJECT_CONSTRUCT('rule', 'GATE_INCOME_BAND', 'kind', 'COMMERCIAL',
                    'verdict', IFF(v.B_GATE_INCOME, 'BLOCK', 'PASS'),
                    'observed', 'income band rank ' || v.INCOME_BAND_RANK
                                || ' vs minimum ' || v.MIN_INCOME_BAND_RANK)),
            IFF(v.PRODUCT_ID IS NULL, NULL,
                OBJECT_CONSTRUCT('rule', 'GATE_TENURE', 'kind', 'COMMERCIAL',
                    'verdict', IFF(v.B_GATE_TENURE, 'BLOCK', 'PASS'),
                    'observed', 'tenure ' || ROUND(v.TENURE_YEARS * 12) || ' months'
                                || ' vs minimum ' || v.MIN_TENURE_MONTHS)),
            IFF(v.PRODUCT_ID IS NULL, NULL,
                OBJECT_CONSTRUCT('rule', 'GATE_KYC', 'kind', 'COMMERCIAL',
                    'verdict', IFF(v.B_GATE_KYC, 'BLOCK', 'PASS'),
                    'observed', 'kyc_current=' || v.KYC_CURRENT
                                || ' vs required ' || v.REQUIRED_KYC_STATUS)),
            IFF(v.PRODUCT_ID IS NULL, NULL,
                OBJECT_CONSTRUCT('rule', 'GATE_DPD', 'kind', 'COMMERCIAL',
                    'verdict', IFF(v.B_GATE_DPD, 'BLOCK', 'PASS'),
                    'observed', 'dpd_bucket=' || v.DPD_BUCKET
                                || ' vs ceiling ' || v.MAX_DPD_DAYS || ' days')),

            CASE
              WHEN v.CHANNEL NOT IN ('CALL', 'SMS') THEN
                OBJECT_CONSTRUCT('rule', 'GLOBAL_DNC', 'kind', 'GLOBAL',
                    'verdict', 'NOT_APPLICABLE',
                    'observed', 'DNC registry governs CALL and SMS in this market; '
                                || 'this action is ' || v.CHANNEL
                                || ' and is governed by channel consent')
              WHEN v.DNC_WAIVED THEN
                OBJECT_CONSTRUCT('rule', 'GLOBAL_DNC', 'kind', 'GLOBAL',
                    'verdict', 'EXEMPT',
                    'observed', 'dnc_flag=true on ' || v.CHANNEL
                                || ', WAIVED: servicing obligation. TRAI TCCCPR '
                                || 'restricts the DNC registry to promotional '
                                || 'contact; this action is transactional. '
                                || 'See PROJECT_BRIEF D7')
              ELSE
                OBJECT_CONSTRUCT('rule', 'GLOBAL_DNC', 'kind', 'GLOBAL',
                    'verdict', IFF(v.B_DNC, 'BLOCK', 'PASS'),
                    'observed', 'dnc_flag=' || v.DNC_FLAG
                                || ' on ' || v.CHANNEL)
            END,

            OBJECT_CONSTRUCT('rule', 'GLOBAL_CHANNEL_CONSENT', 'kind', 'GLOBAL',
                'verdict', IFF(v.B_CONSENT, 'BLOCK', 'PASS'),
                'observed', 'consent_' || LOWER(v.CHANNEL) || '='
                            || COALESCE(v.CHANNEL_CONSENT::VARCHAR, 'NULL')
                            || IFF(v.IS_SERVICING_OBLIGATION,
                                   ' (servicing obligation, but consent is NOT waived'
                                   || ' -- it is a blanket contact permission, not a'
                                   || ' promotional-only one. See PROJECT_BRIEF D7)',
                                   '')),

            IFF(NOT v.IS_SALES_ACTION,
                OBJECT_CONSTRUCT('rule', 'GLOBAL_OPEN_COMPLAINT', 'kind', 'GLOBAL',
                    'verdict', 'NOT_APPLICABLE',
                    'observed', 'service or retention action; an open grievance does '
                                || 'not bar the contact that addresses it'),
                OBJECT_CONSTRUCT('rule', 'GLOBAL_OPEN_COMPLAINT', 'kind', 'GLOBAL',
                    'verdict', IFF(v.B_COMPLAINT, 'BLOCK', 'PASS'),
                    'observed', 'open_complaint=' || v.OPEN_COMPLAINT
                                || ', severity='
                                || COALESCE(v.OPEN_COMPLAINT_SEVERITY::VARCHAR, 'none'))),

            IFF(NOT v.IS_SALES_ACTION,
                OBJECT_CONSTRUCT('rule', 'GLOBAL_VULNERABILITY', 'kind', 'GLOBAL',
                    'verdict', 'NOT_APPLICABLE',
                    'observed', 'not a sales action; service actions remain permitted '
                                || 'for vulnerable customers'),
                OBJECT_CONSTRUCT('rule', 'GLOBAL_VULNERABILITY', 'kind', 'GLOBAL',
                    'verdict', IFF(v.B_VULNERABLE, 'BLOCK', 'PASS'),
                    'observed', 'vulnerability_flag=' || v.VULNERABILITY_FLAG
                                || ', sales action')),

            IFF(v.CATEGORY <> 'CROSS_SELL', NULL,
                OBJECT_CONSTRUCT('rule', 'GLOBAL_ARREARS', 'kind', 'GLOBAL',
                    'verdict', IFF(v.B_ARREARS_XS, 'BLOCK', 'PASS'),
                    'observed', 'dpd_bucket=' || v.DPD_BUCKET || ', cross-sell')),
            IFF(NOT (v.IS_SALES_ACTION AND v.CATEGORY <> 'CROSS_SELL'), NULL,
                OBJECT_CONSTRUCT('rule', 'GLOBAL_ARREARS_NON_CROSS_SELL', 'kind', 'GLOBAL',
                    'verdict', IFF(v.B_ARREARS_OTHER, 'BLOCK', 'PASS'),
                    'observed', 'dpd_bucket=' || v.DPD_BUCKET || ', ' || v.CATEGORY)),

            IFF(v.COOLDOWN_MATCH_CODE IS NULL,
                OBJECT_CONSTRUCT('rule', 'GLOBAL_COOLDOWN', 'kind', 'GLOBAL',
                    'verdict', 'NOT_APPLICABLE',
                    'observed', 'no outbound campaign record exists for this action; '
                                || 'RAW.CAMPAIGN_HISTORY records solicitation only'),
                IFF(NOT v.COOLDOWN_TESTABLE,
                    OBJECT_CONSTRUCT('rule', 'GLOBAL_COOLDOWN', 'kind', 'GLOBAL',
                        'verdict', 'PASS',
                        'observed', 'never contacted about ' || v.COOLDOWN_MATCH_CODE),
                    OBJECT_CONSTRUCT('rule', 'GLOBAL_COOLDOWN', 'kind', 'GLOBAL',
                        'verdict', IFF(v.B_COOLDOWN, 'BLOCK', 'PASS'),
                        'observed', 'last contacted about ' || v.COOLDOWN_MATCH_CODE
                                    || ' ' || v.DAYS_SINCE_CONTACT || ' days ago'
                                    || ' (outcome ' || v.LAST_OUTCOME || ')'
                                    || ' vs cooldown ' || v.COOLDOWN_DAYS || ' days')))
        ) AS ELIGIBILITY_TRACE
    FROM v
),
/* RULES_PASSED / RULES_FAILED are derived by flattening the trace and
   re-aggregating, NOT by re-evaluating the rules. That is deliberate: two
   independent derivations of the same verdict can disagree, and if they ever
   did, the array and the trace displayed next to it in the app would contradict
   each other. One source, two shapes.

   Written as a lateral flatten plus GROUP BY rather than a correlated subquery
   in the select list, which Snowflake rejects with "unsupported subquery type
   cannot be evaluated". */
trace_rules AS (
    SELECT CUSTOMER_ID,
           ACTION_CODE,
           ARRAY_COMPACT(ARRAY_AGG(IFF(verdict = 'PASS', rule, NULL))
                         WITHIN GROUP (ORDER BY rule))          AS RULES_PASSED,
           ARRAY_COMPACT(ARRAY_AGG(IFF(verdict IN ('BLOCK', 'FAIL'), rule, NULL))
                         WITHIN GROUP (ORDER BY rule))          AS RULES_FAILED,
           ARRAY_COMPACT(ARRAY_AGG(IFF(verdict = 'NOT_APPLICABLE', rule, NULL))
                         WITHIN GROUP (ORDER BY rule))          AS RULES_NOT_APPLICABLE,
           /* EXEMPT is kept SEPARATE from NOT_APPLICABLE on purpose. A rule that
              did not apply and a rule that applied and was deliberately waived
              are different compliance facts, and only the second one needs a
              documented justification behind it. */
           ARRAY_COMPACT(ARRAY_AGG(IFF(verdict = 'EXEMPT', rule, NULL))
                         WITHIN GROUP (ORDER BY rule))          AS RULES_EXEMPT
    FROM (
        SELECT t.CUSTOMER_ID,
               t.ACTION_CODE,
               x.VALUE:rule::VARCHAR    AS rule,
               x.VALUE:verdict::VARCHAR AS verdict
        FROM t, LATERAL FLATTEN(input => t.ELIGIBILITY_TRACE) x
    )
    GROUP BY 1, 2
)
SELECT
    t.CUSTOMER_ID,
    t.ACTION_CODE,
    ACTION_NAME,
    CATEGORY,
    PRODUCT_ID,
    CHANNEL,
    IS_SALES_ACTION,
    IS_SERVICING_OBLIGATION,
    PRIORITY_TIER,
    VALUE_ORIENTATION,
    COOLDOWN_DAYS,
    PROPENSITY_FEATURES,
    REQUIRED_DISCLOSURE,
    REGULATORY_NOTE,
    MARGIN_RATE,

    ELIGIBLE_ON_NEED,
    ROUND(VALUE_AT_STAKE_INR, 0)                            AS VALUE_AT_STAKE_INR,

    /* -- did anything block ---------------------------------------------- */
    (SUPPRESSED_ACTION_SPECIFIC
     OR B_GATE_AGE OR B_GATE_INCOME OR B_GATE_TENURE OR B_GATE_KYC OR B_GATE_DPD
     OR B_DNC OR B_CONSENT OR B_COMPLAINT OR B_VULNERABLE
     OR B_ARREARS_XS OR B_ARREARS_OTHER OR B_COOLDOWN)      AS SUPPRESSED,

    CASE
      WHEN NOT ELIGIBLE_ON_NEED THEN 'NOT_ELIGIBLE'
      WHEN (SUPPRESSED_ACTION_SPECIFIC
            OR B_GATE_AGE OR B_GATE_INCOME OR B_GATE_TENURE OR B_GATE_KYC OR B_GATE_DPD
            OR B_DNC OR B_CONSENT OR B_COMPLAINT OR B_VULNERABLE
            OR B_ARREARS_XS OR B_ARREARS_OTHER OR B_COOLDOWN) THEN 'SUPPRESSED'
      ELSE 'ELIGIBLE'
    END                                                     AS FINAL_VERDICT,

    /* -- the governing reason. Ordered most-fundamental first: a consent
          failure is a harder no than a tenure shortfall. ------------------ */
    CASE
      WHEN B_DNC             THEN 'DNC_REGISTRY'
      WHEN B_CONSENT         THEN 'NO_CHANNEL_CONSENT'
      WHEN B_VULNERABLE      THEN 'VULNERABILITY_GATE'
      WHEN B_ARREARS_XS      THEN 'ARREARS_CROSS_SELL'
      WHEN B_ARREARS_OTHER   THEN 'ARREARS_SALES'
      WHEN B_COMPLAINT       THEN 'OPEN_COMPLAINT'
      WHEN B_COOLDOWN        THEN 'COOLDOWN'
      WHEN B_GATE_DPD        THEN 'PRODUCT_GATE_DPD'
      WHEN B_GATE_KYC        THEN 'PRODUCT_GATE_KYC'
      WHEN B_GATE_INCOME     THEN 'PRODUCT_GATE_INCOME_BAND'
      WHEN B_GATE_AGE        THEN 'PRODUCT_GATE_AGE'
      WHEN B_GATE_TENURE     THEN 'PRODUCT_GATE_TENURE'
      WHEN SUPPRESSED_ACTION_SPECIFIC THEN 'ACTION_SPECIFIC'
    END                                                     AS SUPPRESSION_REASON,

    /* -- and every reason, because more than one usually applies --------- */
    ARRAY_CONSTRUCT_COMPACT(
        IFF(B_DNC,           'DNC_REGISTRY',             NULL),
        IFF(B_CONSENT,       'NO_CHANNEL_CONSENT',       NULL),
        IFF(B_VULNERABLE,    'VULNERABILITY_GATE',       NULL),
        IFF(B_ARREARS_XS,    'ARREARS_CROSS_SELL',       NULL),
        IFF(B_ARREARS_OTHER, 'ARREARS_SALES',            NULL),
        IFF(B_COMPLAINT,     'OPEN_COMPLAINT',           NULL),
        IFF(B_COOLDOWN,      'COOLDOWN',                 NULL),
        IFF(B_GATE_DPD,      'PRODUCT_GATE_DPD',         NULL),
        IFF(B_GATE_KYC,      'PRODUCT_GATE_KYC',         NULL),
        IFF(B_GATE_INCOME,   'PRODUCT_GATE_INCOME_BAND', NULL),
        IFF(B_GATE_AGE,      'PRODUCT_GATE_AGE',         NULL),
        IFF(B_GATE_TENURE,   'PRODUCT_GATE_TENURE',      NULL),
        IFF(SUPPRESSED_ACTION_SPECIFIC, 'ACTION_SPECIFIC', NULL)
    )                                                       AS SUPPRESSION_REASONS,

    /* -- rules passed / failed, derived from the trace so they cannot
          disagree with it -------------------------------------------------- */
    tr.RULES_PASSED,
    tr.RULES_FAILED,
    tr.RULES_NOT_APPLICABLE,
    tr.RULES_EXEMPT,

    ELIGIBILITY_TRACE,
    ELIG_WAS_NULL,
    SUPP_WAS_NULL,
    CURRENT_TIMESTAMP()                                     AS GENERATED_AT
FROM t
JOIN trace_rules tr
      ON tr.CUSTOMER_ID = t.CUSTOMER_ID
     AND tr.ACTION_CODE = t.ACTION_CODE;


COMMENT ON TABLE GOLD.NBA_ELIGIBLE IS
'Every customer x every action = 90,000 rows, all retained. FINAL_VERDICT is ELIGIBLE / SUPPRESSED / NOT_ELIGIBLE; suppressed rows are KEPT with SUPPRESSION_REASON, SUPPRESSION_REASONS and a full ELIGIBILITY_TRACE, because the question a compliance reviewer asks is not "why did you contact this customer" but "why did you not contact that one", and a filtered table cannot answer it. Eighteen rules per row at most: the action need, the action-specific suppression, five commercial gates from RAW.PRODUCT_CATALOG, and six global suppressions plus cooldown. Every trace object carries the value the rule fired on so the verdict is replayable. Built by 12_nba_eligibility.sql, which refuses to run unless every catalogue fragment compiles.';

COMMENT ON COLUMN GOLD.NBA_ELIGIBLE.ELIGIBILITY_TRACE IS
'Array of {rule, kind, verdict, observed}. kind is NEED / ACTION / COMMERCIAL / GLOBAL. verdict is PASS / BLOCK / FAIL / NOT_APPLICABLE -- four values, not two: NOT_APPLICABLE means the rule could not be evaluated and says why, which is different from passing. Used for GLOBAL_COOLDOWN where no outbound campaign record exists for the action, GLOBAL_DNC on EMAIL (the registry governs CALL and SMS in this market), and the vulnerability and open-complaint gates on non-sales actions. observed always carries the value the rule fired on.';

COMMENT ON COLUMN GOLD.NBA_ELIGIBLE.SUPPRESSION_REASON IS
'The single GOVERNING reason, ordered most-fundamental first: DNC and consent outrank the vulnerability gate, which outranks arrears, which outranks an open complaint, cooldown, then the five product gates, then the action-specific predicate. NULL when nothing blocked. Most suppressed rows carry more than one reason -- see SUPPRESSION_REASONS for all of them. Displaying only this column understates how comprehensively an action was blocked.';

COMMENT ON COLUMN GOLD.NBA_ELIGIBLE.VALUE_AT_STAKE_INR IS
'GROSS INR margin at stake, from evaluating the action EXPECTED_VALUE_SQL. Computed here because the dynamic-SQL pass that evaluates the stored predicates is already running; 13 consumes it and applies propensity, the churn term per VALUE_ORIENTATION, and the timing multiplier to produce EXPECTED_VALUE_INR. Present on suppressed rows too, deliberately: the value a suppression rule destroyed is the interesting number about that suppression.';

COMMENT ON COLUMN GOLD.NBA_ELIGIBLE.FINAL_VERDICT IS
'ELIGIBLE (need present, nothing blocked) / SUPPRESSED (need present, at least one rule blocked) / NOT_ELIGIBLE (need absent). Suppressions are evaluated and traced even on NOT_ELIGIBLE rows, so "would have been blocked anyway" is answerable. Only ELIGIBLE rows are scored by 13 and only scored rows reach 14.';


/* ============================================================================
   PART 4  —  VERIFICATION
============================================================================ */

/* -- 4.1  nothing was lost, nothing was invented -------------------------- */

SELECT '12.4.1a row count is customers x actions'    AS check_name,
       COUNT(*)                                      AS observed,
       IFF(COUNT(*) = (SELECT COUNT(*) FROM GOLD.NBA_FEATURE_BASE)
                    * (SELECT COUNT(*) FROM GOLD.ACTION_CATALOG),
           'PASS', 'FAIL')                           AS verdict
FROM GOLD.NBA_ELIGIBLE
UNION ALL
SELECT '12.4.1b every action code is in the catalogue',
       COUNT(*),
       IFF(COUNT(*) = 0, 'PASS', 'FAIL')
FROM GOLD.NBA_ELIGIBLE e
WHERE NOT EXISTS (SELECT 1 FROM GOLD.ACTION_CATALOG a WHERE a.ACTION_CODE = e.ACTION_CODE)
UNION ALL
SELECT '12.4.1c one row per customer per action',
       COUNT(*),
       IFF(COUNT(*) = 0, 'PASS', 'FAIL')
FROM (SELECT CUSTOMER_ID, ACTION_CODE FROM GOLD.NBA_ELIGIBLE
      GROUP BY 1, 2 HAVING COUNT(*) > 1)
UNION ALL
SELECT '12.4.1d no suppressed row was dropped',
       COUNT_IF(FINAL_VERDICT = 'SUPPRESSED'),
       IFF(COUNT_IF(FINAL_VERDICT = 'SUPPRESSED') > 0, 'PASS', 'FAIL')
FROM GOLD.NBA_ELIGIBLE;


/* -- 4.2  the NULL default is never exercised ----------------------------- */

SELECT '12.4.2a no eligibility predicate returned NULL' AS check_name,
       COUNT_IF(ELIG_WAS_NULL)                          AS observed,
       IFF(COUNT_IF(ELIG_WAS_NULL) = 0, 'PASS', 'FAIL') AS verdict
FROM GOLD.NBA_ELIGIBLE
UNION ALL
SELECT '12.4.2b no suppression predicate returned NULL',
       COUNT_IF(SUPP_WAS_NULL),
       IFF(COUNT_IF(SUPP_WAS_NULL) = 0, 'PASS', 'FAIL')
FROM GOLD.NBA_ELIGIBLE
UNION ALL
SELECT '12.4.2c channel consent is never NULL',
       COUNT_IF(ARRAY_TO_STRING(SUPPRESSION_REASONS, ',') ILIKE '%=NULL%'),
       IFF(COUNT_IF(ARRAY_TO_STRING(SUPPRESSION_REASONS, ',') ILIKE '%=NULL%') = 0,
           'PASS', 'FAIL')
FROM GOLD.NBA_ELIGIBLE
UNION ALL
SELECT '12.4.2d every row has a verdict and a trace',
       COUNT_IF(FINAL_VERDICT IS NULL OR ARRAY_SIZE(ELIGIBILITY_TRACE) = 0),
       IFF(COUNT_IF(FINAL_VERDICT IS NULL OR ARRAY_SIZE(ELIGIBILITY_TRACE) = 0) = 0,
           'PASS', 'FAIL')
FROM GOLD.NBA_ELIGIBLE
UNION ALL
SELECT '12.4.2e suppressed rows always carry a reason',
       COUNT_IF(FINAL_VERDICT = 'SUPPRESSED' AND SUPPRESSION_REASON IS NULL),
       IFF(COUNT_IF(FINAL_VERDICT = 'SUPPRESSED' AND SUPPRESSION_REASON IS NULL) = 0,
           'PASS', 'FAIL')
FROM GOLD.NBA_ELIGIBLE
UNION ALL
SELECT '12.4.2f eligible rows never carry a reason',
       COUNT_IF(FINAL_VERDICT = 'ELIGIBLE' AND SUPPRESSION_REASON IS NOT NULL),
       IFF(COUNT_IF(FINAL_VERDICT = 'ELIGIBLE' AND SUPPRESSION_REASON IS NOT NULL) = 0,
           'PASS', 'FAIL')
FROM GOLD.NBA_ELIGIBLE;


/* -- 4.3  THE GUARDRAILS. These are the ones that matter. ----------------- */

SELECT '12.4.3a NO sales action eligible for a vulnerable customer' AS check_name,
       COUNT(*)                                                    AS observed,
       IFF(COUNT(*) = 0, 'PASS', 'FAIL')                           AS verdict
FROM GOLD.NBA_ELIGIBLE e
JOIN GOLD.NBA_FEATURE_BASE f ON f.CUSTOMER_ID = e.CUSTOMER_ID
WHERE e.FINAL_VERDICT = 'ELIGIBLE' AND e.IS_SALES_ACTION AND f.VULNERABILITY_FLAG
UNION ALL
SELECT '12.4.3b NO cross-sell eligible for a customer in arrears',
       COUNT(*),
       IFF(COUNT(*) = 0, 'PASS', 'FAIL')
FROM GOLD.NBA_ELIGIBLE e
JOIN GOLD.NBA_FEATURE_BASE f ON f.CUSTOMER_ID = e.CUSTOMER_ID
WHERE e.FINAL_VERDICT = 'ELIGIBLE' AND e.CATEGORY = 'CROSS_SELL'
  AND f.DPD_BUCKET NOT IN ('CURRENT', 'NO_CREDIT_OBLIGATION')
UNION ALL
SELECT '12.4.3c NO sales action eligible for a customer in arrears',
       COUNT(*),
       IFF(COUNT(*) = 0, 'PASS', 'FAIL')
FROM GOLD.NBA_ELIGIBLE e
JOIN GOLD.NBA_FEATURE_BASE f ON f.CUSTOMER_ID = e.CUSTOMER_ID
WHERE e.FINAL_VERDICT = 'ELIGIBLE' AND e.IS_SALES_ACTION
  AND f.DPD_BUCKET NOT IN ('CURRENT', 'NO_CREDIT_OBLIGATION')
UNION ALL
SELECT '12.4.3d NO action eligible without consent on its channel',
       COUNT(*),
       IFF(COUNT(*) = 0, 'PASS', 'FAIL')
FROM GOLD.NBA_ELIGIBLE e
JOIN GOLD.NBA_FEATURE_BASE f ON f.CUSTOMER_ID = e.CUSTOMER_ID
WHERE e.FINAL_VERDICT = 'ELIGIBLE'
  AND NOT CASE e.CHANNEL WHEN 'CALL'  THEN f.CONSENT_CALL
                         WHEN 'EMAIL' THEN f.CONSENT_EMAIL
                         WHEN 'SMS'   THEN f.CONSENT_SMS END
UNION ALL
SELECT '12.4.3e NO sales action eligible with an open complaint',
       COUNT(*),
       IFF(COUNT(*) = 0, 'PASS', 'FAIL')
FROM GOLD.NBA_ELIGIBLE e
JOIN GOLD.NBA_FEATURE_BASE f ON f.CUSTOMER_ID = e.CUSTOMER_ID
WHERE e.FINAL_VERDICT = 'ELIGIBLE' AND e.IS_SALES_ACTION AND f.OPEN_COMPLAINT
UNION ALL
/* 12.4.3h exists because 12.4.3e above cannot fail for the wrong reason without
   help. It joins the engine's own OPEN_COMPLAINT feature, so if that feature is
   blind to a customer the check is blind to them too, and it reports PASS. That
   is exactly what happened: OPEN_COMPLAINT came from a 596-customer text rollup,
   462 customers with a live complaint ticket read FALSE, and 12.4.3e certified
   312 sales recommendations to 197 of them as compliant.

   This check re-derives the condition from RAW.SERVICE_TICKET instead of trusting
   any GOLD column. A guardrail that shares a feature with the thing it guards is
   not a guardrail; it is a restatement. */
SELECT '12.4.3h NO sales action eligible with a live complaint ticket in RAW',
       COUNT(*),
       IFF(COUNT(*) = 0, 'PASS', 'FAIL')
FROM GOLD.NBA_ELIGIBLE e
WHERE e.FINAL_VERDICT = 'ELIGIBLE'
  AND e.IS_SALES_ACTION
  AND EXISTS (SELECT 1 FROM RAW.SERVICE_TICKET t
              WHERE t.CUSTOMER_ID = e.CUSTOMER_ID
                AND t.IS_COMPLAINT
                AND t.STATUS IN ('OPEN', 'IN_PROGRESS'))
UNION ALL
SELECT '12.4.3f NO action eligible inside its cooldown window',
       COUNT(*),
       IFF(COUNT(*) = 0, 'PASS', 'FAIL')
FROM GOLD.NBA_ELIGIBLE e
JOIN GOLD.NBA_COOLDOWN_STATE cd
      ON cd.CUSTOMER_ID = e.CUSTOMER_ID
     AND cd.PRODUCT_CODE = CASE WHEN e.ACTION_CODE = 'WEALTH_REFERRAL'
                                THEN 'INS_ULIP_BAL' ELSE e.PRODUCT_ID END
WHERE e.FINAL_VERDICT = 'ELIGIBLE' AND cd.DAYS_SINCE_CONTACT < e.COOLDOWN_DAYS
UNION ALL
SELECT '12.4.3g the 100 guardrail customers have ZERO eligible sales actions',
       COUNT(*),
       IFF(COUNT(*) = 0, 'PASS', 'FAIL')
FROM GOLD.NBA_ELIGIBLE e
JOIN GOLD.NBA_FEATURE_BASE f ON f.CUSTOMER_ID = e.CUSTOMER_ID
WHERE e.FINAL_VERDICT = 'ELIGIBLE' AND e.IS_SALES_ACTION
  AND f.VULNERABILITY_FLAG AND f.INCOME_BAND_RANK >= 4;


/* -- 4.4  the three scoping decisions, as numbers ------------------------- */

SELECT 'decision 1: open-complaint scoped to sales'      AS decision,
       'rows this scoping SPARED (non-sales actions with an open complaint '
         || 'that a flat rule would have blocked)'        AS effect,
       COUNT(*)                                          AS rows_affected
FROM GOLD.NBA_ELIGIBLE e
JOIN GOLD.NBA_FEATURE_BASE f ON f.CUSTOMER_ID = e.CUSTOMER_ID
WHERE NOT e.IS_SALES_ACTION AND f.OPEN_COMPLAINT AND e.ELIGIBLE_ON_NEED
UNION ALL
SELECT 'decision 1: open-complaint scoped to sales',
       'of which RETENTION_SAVE_CALL (planted S1) and '
         || 'COMPLAINT_RESOLUTION_CALLBACK -- the two a flat rule breaks',
       COUNT(*)
FROM GOLD.NBA_ELIGIBLE e
JOIN GOLD.NBA_FEATURE_BASE f ON f.CUSTOMER_ID = e.CUSTOMER_ID
WHERE e.ACTION_CODE IN ('RETENTION_SAVE_CALL', 'COMPLAINT_RESOLUTION_CALLBACK')
  AND f.OPEN_COMPLAINT AND e.ELIGIBLE_ON_NEED
UNION ALL
SELECT 'decision 2: DNC scoped to CALL and SMS',
       'rows a flat any-channel DNC reading would ADDITIONALLY have blocked '
         || '(EMAIL actions, currently eligible, DNC on call/sms)',
       COUNT(*)
FROM GOLD.NBA_ELIGIBLE e
JOIN GOLD.NBA_FEATURE_BASE f ON f.CUSTOMER_ID = e.CUSTOMER_ID
WHERE e.CHANNEL = 'EMAIL' AND f.DNC_FLAG AND e.FINAL_VERDICT = 'ELIGIBLE'
UNION ALL
SELECT 'decision 3: arrears widened beyond cross-sell',
       'rows blocked ONLY by the addition (upsell/wealth in arrears, '
         || 'nothing else blocking)',
       COUNT(*)
FROM GOLD.NBA_ELIGIBLE
WHERE SUPPRESSION_REASON = 'ARREARS_SALES';


/* -- 4.8  what the D7 servicing exemption actually recovered -------------- */

SELECT e.ACTION_CODE,
       COUNT_IF(e.ELIGIBLE_ON_NEED)                                  AS need_present,
       COUNT_IF(ARRAY_CONTAINS('GLOBAL_DNC'::VARIANT, e.RULES_EXEMPT)
                AND e.ELIGIBLE_ON_NEED)                              AS dnc_waived,
       /* recovered = the waiver is the ONLY reason this row is now eligible */
       COUNT_IF(e.FINAL_VERDICT = 'ELIGIBLE' AND e.ELIGIBLE_ON_NEED
                AND ARRAY_CONTAINS('GLOBAL_DNC'::VARIANT, e.RULES_EXEMPT))
                                                                     AS recovered,
       /* still blocked despite the waiver, because consent is not waived */
       COUNT_IF(e.FINAL_VERDICT = 'SUPPRESSED' AND e.ELIGIBLE_ON_NEED
                AND ARRAY_CONTAINS('GLOBAL_DNC'::VARIANT, e.RULES_EXEMPT))
                                                                     AS still_blocked,
       COUNT_IF(e.FINAL_VERDICT = 'ELIGIBLE')                        AS eligible_now
FROM GOLD.NBA_ELIGIBLE e
WHERE e.IS_SERVICING_OBLIGATION
GROUP BY 1 ORDER BY 1;

/* Consent is still a hard block for these two -- asserted, not assumed. */
SELECT '12.4.8 consent still blocks servicing obligations'  AS check_name,
       COUNT(*)                                             AS observed,
       IFF(COUNT(*) = 0, 'PASS', 'FAIL')                    AS verdict
FROM GOLD.NBA_ELIGIBLE e
JOIN GOLD.NBA_FEATURE_BASE f ON f.CUSTOMER_ID = e.CUSTOMER_ID
WHERE e.IS_SERVICING_OBLIGATION AND e.FINAL_VERDICT = 'ELIGIBLE'
  AND NOT CASE e.CHANNEL WHEN 'CALL'  THEN f.CONSENT_CALL
                         WHEN 'EMAIL' THEN f.CONSENT_EMAIL
                         WHEN 'SMS'   THEN f.CONSENT_SMS END;


/* -- 4.5  eligible rows per action ---------------------------------------- */

SELECT PRIORITY_TIER                                  AS tier,
       CATEGORY,
       ACTION_CODE,
       CHANNEL                                        AS ch,
       COUNT_IF(ELIGIBLE_ON_NEED)                     AS need_present,
       COUNT_IF(FINAL_VERDICT = 'ELIGIBLE')           AS eligible,
       COUNT_IF(FINAL_VERDICT = 'SUPPRESSED')         AS suppressed,
       ROUND(100.0 * COUNT_IF(FINAL_VERDICT = 'SUPPRESSED')
             / NULLIF(COUNT_IF(ELIGIBLE_ON_NEED), 0), 1) AS suppressed_pct,
       TO_VARCHAR(SUM(IFF(FINAL_VERDICT = 'SUPPRESSED', VALUE_AT_STAKE_INR, 0)),
                  '999,999,999,999')                  AS value_suppressed_inr
FROM GOLD.NBA_ELIGIBLE
GROUP BY 1, 2, 3, 4
ORDER BY 1, 3;


/* -- 4.6  suppression reasons, ranked ------------------------------------- */

SELECT SUPPRESSION_REASON,
       COUNT(*)                                       AS rows_blocked,
       COUNT(DISTINCT CUSTOMER_ID)                    AS customers,
       COUNT_IF(ELIGIBLE_ON_NEED)                     AS blocked_a_real_need,
       TO_VARCHAR(SUM(IFF(ELIGIBLE_ON_NEED, VALUE_AT_STAKE_INR, 0)),
                  '999,999,999,999')                  AS value_destroyed_inr
FROM GOLD.NBA_ELIGIBLE
WHERE SUPPRESSION_REASON IS NOT NULL
GROUP BY 1
ORDER BY blocked_a_real_need DESC;


/* -- 4.7  planted-segment precision and recall THROUGH the full pass ------
   THE ONLY READ OF RAW.CUSTOMER_SEGMENT_TRUTH IN THIS FILE. Verification
   only. 11 part 4.3 proved the predicates exact at the feature layer; this
   proves the eligibility pass did not disturb them.

   Measured on ELIGIBLE_ON_NEED, which is the eligibility verdict. The gap to
   FINAL_VERDICT = ELIGIBLE is suppression, which is SUPPOSED to remove
   customers -- 71 of the 400 S1 customers are consent-suppressed by
   construction (docs/DATA_SEGMENTS.md S6), so a recall drop there is the
   engine working. Both columns are shown so the two effects stay separable.
   ------------------------------------------------------------------------ */

WITH truth AS (SELECT CUSTOMER_ID, SEGMENT_CODE FROM RAW.CUSTOMER_SEGMENT_TRUTH),
pairs AS (
    SELECT * FROM VALUES
        ('RETENTION_SAVE_CALL',           'RETENTION_SAVE'),
        ('CARD_LIMIT_INCREASE',           'LIMIT_INCREASE'),
        ('HOME_PROTECTION_CROSS_SELL',    'PROTECTION_GAP'),
        ('COLLECTIONS_HARDSHIP_OUTREACH', 'COLLECTIONS_HARDSHIP'),
        ('WEALTH_REFERRAL',               'WEALTH_REFERRAL')
    AS p(ACTION_CODE, SEGMENT_CODE)
)
SELECT
    p.ACTION_CODE,
    p.SEGMENT_CODE,
    (SELECT COUNT(*) FROM truth t WHERE t.SEGMENT_CODE = p.SEGMENT_CODE) AS planted,
    COUNT_IF(e.ELIGIBLE_ON_NEED)                                          AS need_fires,
    COUNT_IF(e.ELIGIBLE_ON_NEED AND t.SEGMENT_CODE = p.SEGMENT_CODE)      AS need_hits,
    ROUND(100.0 * COUNT_IF(e.ELIGIBLE_ON_NEED AND t.SEGMENT_CODE = p.SEGMENT_CODE)
          / NULLIF(COUNT_IF(e.ELIGIBLE_ON_NEED), 0), 1)                   AS precision_pct,
    ROUND(100.0 * COUNT_IF(e.ELIGIBLE_ON_NEED AND t.SEGMENT_CODE = p.SEGMENT_CODE)
          / NULLIF((SELECT COUNT(*) FROM truth t2
                    WHERE t2.SEGMENT_CODE = p.SEGMENT_CODE), 0), 1)       AS recall_pct,
    COUNT_IF(e.FINAL_VERDICT = 'ELIGIBLE'
             AND t.SEGMENT_CODE = p.SEGMENT_CODE)                         AS survive_suppression,
    IFF(COUNT_IF(e.ELIGIBLE_ON_NEED) =
        (SELECT COUNT(*) FROM truth t3 WHERE t3.SEGMENT_CODE = p.SEGMENT_CODE)
        AND COUNT_IF(e.ELIGIBLE_ON_NEED AND t.SEGMENT_CODE = p.SEGMENT_CODE) =
        (SELECT COUNT(*) FROM truth t4 WHERE t4.SEGMENT_CODE = p.SEGMENT_CODE),
        'EXACT', 'DRIFTED')                                               AS verdict
FROM pairs p
JOIN GOLD.NBA_ELIGIBLE e ON e.ACTION_CODE = p.ACTION_CODE
JOIN truth t              ON t.CUSTOMER_ID = e.CUSTOMER_ID
GROUP BY p.ACTION_CODE, p.SEGMENT_CODE
ORDER BY p.ACTION_CODE;


SELECT 'GOLD.NBA_ELIGIBLE built'                          AS status,
       COUNT(*)                                           AS total_rows,
       COUNT_IF(FINAL_VERDICT = 'ELIGIBLE')               AS eligible,
       COUNT_IF(FINAL_VERDICT = 'SUPPRESSED')             AS suppressed,
       COUNT_IF(FINAL_VERDICT = 'NOT_ELIGIBLE')           AS not_eligible,
       COUNT(DISTINCT IFF(FINAL_VERDICT = 'ELIGIBLE', CUSTOMER_ID, NULL))
                                                          AS customers_with_an_action
FROM GOLD.NBA_ELIGIBLE;

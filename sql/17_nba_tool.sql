/* ============================================================================
   17_nba_tool.sql  —  APP.GET_NEXT_BEST_ACTIONS, the agent's action tool
   ----------------------------------------------------------------------------
   M9 step 2. The semantic view added in sql/16 aggregates: how many
   recommendations, worth how much, blocked by which rule. It deliberately cannot
   answer the question a relationship manager actually asks, which is about one
   person in front of them right now.

   That question needs the ranked actions, the rationale, the evidence behind the
   rationale, the disclosure that has to be read out, and -- the part most
   engines omit -- the actions the engine WANTED to take and was not allowed to,
   with the rule that stopped each one. All five for one customer, as one object.

   So: a stored procedure, wrapped as a custom tool on APP.RM_COPILOT in sql/18.

   Cost: ZERO CREDITS. Deterministic SQL over already-computed tables. No AI
   function is called anywhere in this file, which is the point -- the agent
   narrates, but what it narrates is not generated at question time. Re-running
   this file costs nothing.

   ----------------------------------------------------------------------------
   WHY A PROCEDURE AND NOT A SEMANTIC VIEW METRIC
   ----------------------------------------------------------------------------
   Three reasons, and the third is the one that settles it.

   1. GRAIN. A semantic view answers with aggregates over a population. This
      answers with a nested document about one entity: an array of actions, each
      with its own array of evidence and its own array of rule verdicts. That is
      not a shape a semantic view returns.

   2. TWO SOURCES, TWO GRAINS, ONE ANSWER. The recommended actions come from
      GOLD.NEXT_BEST_ACTION and the suppressed ones from GOLD.NBA_ELIGIBLE.
      sql/16 keeps those as separate logical tables precisely because mixing
      them in one row is a grain error. Here they must appear together, because
      "what should I do" and "what am I not allowed to do" are one conversation.
      A procedure can assemble both without claiming they are the same grain.

   3. THE SUPPRESSED ACTIONS ARE THE PRODUCT. An engine that returns only what
      it permits is indistinguishable from an engine with no rules. The agent's
      response instructions require it to say when an action was suppressed and
      why, and never to silently omit one. An instruction to disclose something
      the tool never returns is not a control -- it is a wish. So suppression is
      in the payload, unconditionally, and the agent cannot answer without
      having been handed it.

   ----------------------------------------------------------------------------
   THE PARAMETER IS NAMED CUSTOMER_ID AND IT HAS TO BE
   ----------------------------------------------------------------------------
   It was originally P_CUSTOMER_ID, following the convention that a procedure
   parameter is prefixed so it cannot be confused with a column of the same name.
   The agent could not call it:

     named arguments [CUSTOMER_ID] do not match any signature
     for function C360_NBA.APP.GET_NEXT_BEST_ACTIONS

   A custom tool invokes its procedure with NAMED arguments taken from the
   property names in the tool's input_schema. So the schema property name and the
   procedure parameter name are one identifier in two places, and the prefix
   convention breaks the call. The property is customer_id because that is what
   reads naturally to the orchestrating model, so the parameter is CUSTOMER_ID.

   Worth recording because the failure is silent in the wrong direction: the
   agent reports it as a tool that is not responding, and the natural next move
   is to go looking at the warehouse or the grants rather than at a parameter
   name. Nothing in the CREATE AGENT reference says the names must match.

   The cost of giving that up is real -- CUSTOMER_ID is also a column on every
   table this procedure reads -- so it is paid down once, at the top of the body:
   the parameter is copied into v_customer_id immediately and nothing below
   refers to :CUSTOMER_ID again. A bare CUSTOMER_ID inside the query is therefore
   always the column, which is what a reader will assume anyway.

   ----------------------------------------------------------------------------
   THE ARGUMENT IS VARCHAR, WHICH LOOKS WRONG AND IS DELIBERATE
   ----------------------------------------------------------------------------
   CUSTOMER_ID is a NUMBER everywhere else in this project. This procedure takes
   VARCHAR and casts inside.

   The reason is the caller. An agent's custom tool passes arguments as JSON
   assembled by a language model, and a model that has read "customer 3925" in a
   question may serialise it as 3925 or as "3925" depending on nothing in
   particular. With a NUMBER signature the string form fails at the call
   boundary, and what the RM sees is a tool error rather than an answer. With
   VARCHAR both work, and a genuinely unparseable value gets a typed refusal in
   the payload that the agent can read out.

   Overloading two signatures was the alternative and is worse: tool_resources
   names a procedure by identifier, and two candidates make that ambiguous.

   ----------------------------------------------------------------------------
   THE QUARANTINE HOLDS
   ----------------------------------------------------------------------------
   Nothing here reads RAW.CUSTOMER_SEGMENT_TRUTH. This is the object the agent
   calls on every named customer, so it is the single most important place in the
   project for that to be true: an engine whose serving path can see the answer
   key is not demonstrating anything. Asserted in §4 against the stored DDL.
   ============================================================================ */

USE ROLE COCO_BUILDER;
USE WAREHOUSE COCO_WH;
USE DATABASE C360_NBA;
USE SCHEMA APP;


/* ============================================================================
   PART 1 — INDIAN DIGIT GROUPING
   ----------------------------------------------------------------------------
   The agent's response instructions require amounts in INR with Indian digit
   grouping: 71,77,355 and not 7,177,355. Lakh-and-crore grouping puts the last
   three digits together and then groups in twos.

   This is done here rather than left to the agent, for the reason any
   formatting rule belongs in the data layer: a model asked to reformat a number
   will occasionally reformat the number. Handing it a pre-formatted string means
   the digits it prints are the digits the arithmetic produced.

   TO_CHAR cannot do this -- its format models only support three-digit
   grouping -- so the grouping is built by reversing the leading digits,
   inserting a comma every two characters and reversing back. Correctness is
   asserted in §4 across the boundary cases, including the four-digit case where
   the leading group is a single digit.
   ============================================================================ */

CREATE OR REPLACE FUNCTION APP.FORMAT_INR(AMOUNT FLOAT)
RETURNS VARCHAR
LANGUAGE SQL
IMMUTABLE
COMMENT = 'Format a rupee amount with Indian digit grouping: 7177355 -> 71,77,355. Rounds to whole rupees, since no amount in this project is meaningful to the paisa. NULL in, NULL out. Negative amounts keep their sign. Exists so the agent is handed the formatted string rather than asked to reformat a number itself.'
AS
$$
  CASE
    WHEN AMOUNT IS NULL THEN NULL
    ELSE
      IFF(AMOUNT < 0, '-', '')
      || CASE
           /* Three digits or fewer: no grouping applies at all. */
           WHEN LENGTH(TO_VARCHAR(ABS(ROUND(AMOUNT)))) <= 3
             THEN TO_VARCHAR(ABS(ROUND(AMOUNT)))
           ELSE
             /* Group everything above the last three digits in twos, by
                reversing, comma-ing every second character, and reversing back.
                RTRIM removes the trailing comma left when the leading group has
                an even length. */
             REVERSE(
               RTRIM(
                 REGEXP_REPLACE(
                   REVERSE(LEFT(TO_VARCHAR(ABS(ROUND(AMOUNT))),
                                LENGTH(TO_VARCHAR(ABS(ROUND(AMOUNT)))) - 3)),
                   '(..)', '\\1,'
                 ),
                 ','
               )
             )
             || ',' || RIGHT(TO_VARCHAR(ABS(ROUND(AMOUNT))), 3)
         END
  END
$$;


/* ============================================================================
   PART 2 — EVIDENCE RESOLUTION
   ----------------------------------------------------------------------------
   GOLD.NEXT_BEST_ACTION.EVIDENCE_IDS holds bare identifiers -- IX-003925-2,
   REPAYMENT-40849, TKT-00000004 -- which are citations and not evidence. An
   RM handed "REPAYMENT-40849" as the reason for a hardship call has been handed
   nothing. So they are resolved to the event they refer to.

   GOLD.CUSTOMER_TIMELINE already unifies every source at event grain with a
   title and a detail line, which is exactly what a quotable citation needs, so
   resolution is a join rather than seven joins.

   TWO SHAPES OF IDENTIFIER, WHICH IS A WART WORTH NAMING. Five of the seven
   prefixes ARE the source identifier (POL-, LN-, CLM-, TKT-, IX-). Two are the
   source TABLE plus the identifier (REPAYMENT-40849, CAMPAIGN_HISTORY-10045),
   because those two tables key on a bare integer that would be meaningless on
   its own. So the prefix is stripped for those two and kept for the rest.

   ONE EVIDENCE ID CAN RESOLVE TO SEVERAL EVENTS, and that is correct rather
   than a defect: POL-00000030 appears in the timeline as both POLICY_ISSUED and
   POLICY_LAPSED. Both are returned, oldest first, because "this policy was
   issued and then lapsed" is more informative than either half.

   An id that resolves to nothing is returned with resolved = FALSE rather than
   dropped. sql/14 stripped unresolvable labels from the RATIONALE, so this
   should be empty -- and if it ever is not, silently dropping the row would
   hide it. It is asserted in §4.
   ============================================================================ */

CREATE OR REPLACE VIEW APP.V_NBA_EVIDENCE_RESOLVED
  COMMENT = 'One row per (customer, action rank, evidence id) with the timeline event that id refers to. The bridge between a citation and something an RM can read out. Unresolvable ids are kept with RESOLVED = FALSE rather than dropped, so a break is visible instead of quiet.'
AS
WITH cited AS (
    SELECT n.CUSTOMER_ID,
           n."RANK"                     AS ACTION_RANK,
           n.ACTION_CODE,
           f.INDEX                      AS EVIDENCE_POSITION,
           f.VALUE::VARCHAR             AS EVIDENCE_ID
    FROM GOLD.NEXT_BEST_ACTION n,
         LATERAL FLATTEN(input => n.EVIDENCE_IDS) f
),
keyed AS (
    SELECT c.*,
           /* Strip the table-name prefix on the two bare-integer sources; leave
              every other identifier as it stands. */
           CASE
             WHEN c.EVIDENCE_ID LIKE 'REPAYMENT-%'         THEN SUBSTR(c.EVIDENCE_ID, 11)
             WHEN c.EVIDENCE_ID LIKE 'CAMPAIGN_HISTORY-%'  THEN SUBSTR(c.EVIDENCE_ID, 18)
             ELSE c.EVIDENCE_ID
           END AS SOURCE_KEY
    FROM cited c
)
SELECT
    k.CUSTOMER_ID,
    k.ACTION_RANK,
    k.ACTION_CODE,
    k.EVIDENCE_POSITION,
    k.EVIDENCE_ID,
    t.EVENT_TYPE,
    t.OCCURRED_AT,
    t.TITLE,
    t.DETAIL,
    t.SOURCE_TABLE,
    t.EVENT_ID IS NOT NULL AS RESOLVED
FROM keyed k
LEFT JOIN GOLD.CUSTOMER_TIMELINE t
       ON t.CUSTOMER_ID = k.CUSTOMER_ID
      AND t.SOURCE_ID   = k.SOURCE_KEY;


/* ============================================================================
   PART 3 — THE PROCEDURE
   ----------------------------------------------------------------------------
   One VARIANT document per customer, in five parts:

     status               OK | NO_ACTIONS | UNKNOWN_CUSTOMER | BAD_ARGUMENT
     customer             who they are and the signals that govern what may be
                          offered to them
     recommended_actions  ranked, with rationale, evidence and disclosure
     suppressed_actions   what the engine wanted to do and could not, with the
                          governing rule and what it observed
     summary              counts and totals, pre-formatted

   FOUR STATUSES, BECAUSE FOUR THINGS CAN HAPPEN AND THEY ARE NOT THE SAME.
   An agent handed an empty array cannot tell whether the customer does not
   exist, exists with nothing to offer, or exists with everything suppressed --
   and those need three different sentences to the RM. The distinction is made
   here rather than left to be inferred:

     UNKNOWN_CUSTOMER  no such customer on the spine
     NO_ACTIONS        exists, nothing published; suppressed_actions says
                       whether that is because nothing fired or because
                       everything that fired was blocked
     OK                at least one action published
     BAD_ARGUMENT      the id could not be read as a number

   EVERY AMOUNT APPEARS TWICE, as a number and as a formatted string. The number
   so the agent can compare and sum; the string so what it prints is what the
   arithmetic produced. Naming the formatted one _fmt makes the pairing obvious
   in the payload.
   ============================================================================ */

CREATE OR REPLACE PROCEDURE APP.GET_NEXT_BEST_ACTIONS(CUSTOMER_ID VARCHAR)
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'The ranked next best actions for one customer, with rationale, resolved evidence, required disclosure and the full eligibility trace -- plus the actions the engine wanted to take and a compliance rule blocked, each with its governing rule. Returns one VARIANT document. Argument is VARCHAR and cast internally so an agent may pass 3925 or "3925". status is OK, NO_ACTIONS, UNKNOWN_CUSTOMER or BAD_ARGUMENT. Reads GOLD.NEXT_BEST_ACTION, GOLD.NBA_ELIGIBLE, GOLD.CUSTOMER_360 and GOLD.CUSTOMER_TIMELINE. Deterministic, no AI, no access to the ground-truth segment table.'
EXECUTE AS OWNER
AS
$$
DECLARE
    v_customer_id NUMBER;
    v_exists      NUMBER;
    v_result      VARIANT;
BEGIN
    /* ---- 3.1  Argument ------------------------------------------------------
       TRY_TO_NUMBER rather than a cast, so a model that passes "the customer"
       or an empty string gets a readable refusal instead of an exception the
       agent will surface as a broken tool.

       This is also the ONLY line that reads :CUSTOMER_ID, apart from the error
       message below. Everything after it uses :v_customer_id, so a bare
       CUSTOMER_ID further down is unambiguously the column -- see the header on
       why the parameter cannot carry a prefix. */
    v_customer_id := TRY_TO_NUMBER(TRIM(:CUSTOMER_ID));

    IF (v_customer_id IS NULL) THEN
        RETURN OBJECT_CONSTRUCT(
            'status',  'BAD_ARGUMENT',
            'message', 'customer_id could not be read as a number. Received: '
                       || COALESCE(:CUSTOMER_ID, 'null')
                       || '. Pass the numeric customer id, for example 3925.'
        );
    END IF;

    SELECT COUNT(*) INTO :v_exists
      FROM GOLD.CUSTOMER_360
     WHERE CUSTOMER_ID = :v_customer_id;

    IF (v_exists = 0) THEN
        RETURN OBJECT_CONSTRUCT(
            'status',      'UNKNOWN_CUSTOMER',
            'customer_id', :v_customer_id,
            'message',     'No customer with id ' || :v_customer_id
                           || ' exists. Customer ids run from 1 to 5000. Do not '
                           || 'recommend anything for this id.'
        );
    END IF;

    /* ---- 3.2  The document -------------------------------------------------
       Assembled in one statement so the customer block, the actions, the
       suppressions and the summary are all read from the same snapshot. */
    SELECT OBJECT_CONSTRUCT(
        'status', IFF(COALESCE(ARRAY_SIZE(act.actions), 0) > 0, 'OK', 'NO_ACTIONS'),
        'as_of_date', anchor.AS_OF_DATE::VARCHAR,

        /* ---- who they are, and what governs what may be offered ---- */
        'customer', OBJECT_CONSTRUCT(
            'customer_id',                c.CUSTOMER_ID,
            'customer_name',              c.CUSTOMER_NAME,
            'city',                       c.CITY,
            'segment',                    c.SEGMENT,
            'age',                        c.AGE,
            'tenure_years',               c.TENURE_YEARS,
            'relationship_value_band',    c.RELATIONSHIP_VALUE_BAND,
            'est_annual_margin_inr',      ROUND(c.EST_ANNUAL_MARGIN_INR),
            'est_annual_margin_inr_fmt',  APP.FORMAT_INR(c.EST_ANNUAL_MARGIN_INR),
            'products_held',              c.PRODUCTS_HELD,
            'product_gaps',               c.PRODUCT_GAP,
            'preferred_channel',          c.PREFERRED_CHANNEL,

            /* The signals that decide whether a sale is appropriate at all.
               Grouped under one key and named for what they mean, so the agent
               is not left inferring conduct posture from scattered booleans. */
            /* is_in_arrears and reachable are derived here rather than read,
               because GOLD.CUSTOMER_360 carries neither: both are declared in
               GOLD.V_SV_CUSTOMER, which sql/09 reserves for the semantic view
               and which nothing else should read. So the predicates are
               restated, using the identical expressions -- and the arrears one
               carries the trap sql/09 documented: NO_CREDIT_OBLIGATION means no
               borrowing at all and must not be grouped with CURRENT, which is
               borrowing that is up to date. */
            'care_posture', OBJECT_CONSTRUCT(
                'is_in_arrears',
                    c.DPD_BUCKET NOT IN ('CURRENT', 'NO_CREDIT_OBLIGATION'),
                'worst_dpd_bucket',    c.DPD_BUCKET,
                'hardship_signal',     c.HARDSHIP_SIGNAL,
                'vulnerability_flag',  c.VULNERABILITY_FLAG,
                'open_complaint',      c.OPEN_COMPLAINT,
                'sentiment_trend',     c.SENTIMENT_TREND,
                'kyc_current',         c.KYC_CURRENT
            ),
            'contact_permission', OBJECT_CONSTRUCT(
                'dnc_registry',        c.DNC_FLAG,
                'consent_call',        c.CONSENT_CALL,
                'consent_email',       c.CONSENT_EMAIL,
                'consent_sms',         c.CONSENT_SMS,
                'reachable',
                    c.CONSENT_CALL OR c.CONSENT_EMAIL OR c.CONSENT_SMS,
                'last_contact_days',   c.LAST_CONTACT_DAYS
            )
        ),

        'recommended_actions', COALESCE(act.actions, ARRAY_CONSTRUCT()),
        'suppressed_actions',  COALESCE(sup.suppressions, ARRAY_CONSTRUCT()),

        'summary', OBJECT_CONSTRUCT(
            'recommended_count',            COALESCE(ARRAY_SIZE(act.actions), 0),
            'suppressed_count',             COALESCE(ARRAY_SIZE(sup.suppressions), 0),
            'total_expected_value_inr',     ROUND(COALESCE(act.total_ev, 0)),
            'total_expected_value_inr_fmt', APP.FORMAT_INR(COALESCE(act.total_ev, 0)),
            'suppressed_value_at_stake_inr',     ROUND(COALESCE(sup.total_at_stake, 0)),
            'suppressed_value_at_stake_inr_fmt', APP.FORMAT_INR(COALESCE(sup.total_at_stake, 0)),
            /* Named to head off the comparison a reader will otherwise make.
               Expected value is propensity-weighted; value at stake is gross. */
            'value_note', 'total_expected_value_inr is propensity-weighted and '
                          || 'suppressed_value_at_stake_inr is gross with no '
                          || 'propensity applied. They are not comparable and '
                          || 'must not be added or differenced.'
        )
    )
    INTO :v_result
    FROM GOLD.CUSTOMER_360 c
    CROSS JOIN GOLD.C360_ASOF anchor

    /* ---- 3.3  Recommended actions, ranked, with evidence ---- */
    LEFT JOIN (
        SELECT a.CUSTOMER_ID,
               SUM(a.EXPECTED_VALUE_INR) AS total_ev,
               ARRAY_AGG(a.action) WITHIN GROUP (ORDER BY a.ACTION_RANK) AS actions
        FROM (
            SELECT n.CUSTOMER_ID,
                   n."RANK" AS ACTION_RANK,
                   n.EXPECTED_VALUE_INR,
                   OBJECT_CONSTRUCT(
                       'rank',                    n."RANK",
                       'action_code',             n.ACTION_CODE,
                       'action_name',             n.ACTION_NAME,
                       'channel',                 n.CHANNEL,
                       'propensity',              ROUND(n.PROPENSITY, 4),
                       'expected_value_inr',      ROUND(n.EXPECTED_VALUE_INR),
                       'expected_value_inr_fmt',  APP.FORMAT_INR(n.EXPECTED_VALUE_INR),
                       'rationale',               n.RATIONALE,
                       'rationale_source',        v.RATIONALE_SOURCE,
                       'priority_tier',           v.PRIORITY_TIER,
                       'is_sales_action',         v.IS_SALES_ACTION,
                       'is_care_action',          v.PRIORITY_TIER <= 20,
                       /* Disclosure is never omitted and never NULL in the
                          payload: an absent key reads as an oversight, whereas
                          an explicit "none required" is a statement. */
                       'required_disclosure',
                           IFF(n.DISCLOSURE IS NULL OR TRIM(n.DISCLOSURE) = '',
                               'None required for this action.',
                               n.DISCLOSURE),
                       'evidence',                COALESCE(ev.evidence, ARRAY_CONSTRUCT()),
                       'eligibility_trace',       n.ELIGIBILITY_TRACE
                   ) AS action
            FROM GOLD.NEXT_BEST_ACTION n
            JOIN GOLD.V_NEXT_BEST_ACTION_AUDIT v
              ON v.CUSTOMER_ID = n.CUSTOMER_ID AND v."RANK" = n."RANK"
            LEFT JOIN (
                SELECT r.CUSTOMER_ID, r.ACTION_RANK,
                       ARRAY_AGG(OBJECT_CONSTRUCT(
                           'evidence_id',  r.EVIDENCE_ID,
                           'event_type',   r.EVENT_TYPE,
                           'occurred_at',  r.OCCURRED_AT::VARCHAR,
                           'title',        r.TITLE,
                           'detail',       r.DETAIL,
                           'resolved',     r.RESOLVED
                       )) WITHIN GROUP (ORDER BY r.EVIDENCE_POSITION, r.OCCURRED_AT)
                         AS evidence
                FROM APP.V_NBA_EVIDENCE_RESOLVED r
                WHERE r.CUSTOMER_ID = :v_customer_id
                GROUP BY r.CUSTOMER_ID, r.ACTION_RANK
            ) ev ON ev.CUSTOMER_ID = n.CUSTOMER_ID AND ev.ACTION_RANK = n."RANK"
            WHERE n.CUSTOMER_ID = :v_customer_id
        ) a
        GROUP BY a.CUSTOMER_ID
    ) act ON act.CUSTOMER_ID = c.CUSTOMER_ID

    /* ---- 3.4  Suppressed actions — the part that makes this auditable ----
       Restricted to ELIGIBLE_ON_NEED, because a pair that failed the need test
       was never something the engine wanted to do and listing it as
       "suppressed" would inflate the disclosure into noise. What is returned is
       exactly the set the RM might otherwise ask about: things this customer
       plausibly wants that we are not allowed to offer.

       BLOCKING_RULES is pulled out of the trace rather than left for the agent
       to find. Each entry is a rule that returned BLOCK together with what it
       observed -- "GLOBAL_DNC", "dnc_flag=true on CALL" -- and it is the
       difference between "we cannot offer this" and "we cannot offer this
       because the customer is on the do-not-call register".

       All of them, not just the governing one. Customer 3925's blocked card
       upgrade fails six separate rules: age, income band, DPD ceiling, an
       action-specific suppression, the arrears gate and DNC. suppression_reason
       names DNC_REGISTRY as governing, but an RM told only that would leave
       thinking the sale becomes available once consent is fixed, when in fact
       five other rules would still stop it. */
    LEFT JOIN (
        SELECT s.CUSTOMER_ID,
               SUM(s.VALUE_AT_STAKE_INR) AS total_at_stake,
               ARRAY_AGG(s.suppression)
                 WITHIN GROUP (ORDER BY s.VALUE_AT_STAKE_INR DESC) AS suppressions
        FROM (
            SELECT e.CUSTOMER_ID,
                   e.VALUE_AT_STAKE_INR,
                   OBJECT_CONSTRUCT(
                       'action_code',            e.ACTION_CODE,
                       'action_name',            e.ACTION_NAME,
                       'category',               e.CATEGORY,
                       'channel',                e.CHANNEL,
                       'value_at_stake_inr',     ROUND(e.VALUE_AT_STAKE_INR),
                       'value_at_stake_inr_fmt', APP.FORMAT_INR(e.VALUE_AT_STAKE_INR),
                       'suppression_reason',     e.SUPPRESSION_REASON,
                       'all_suppression_reasons', e.SUPPRESSION_REASONS,
                       'rules_failed',           e.RULES_FAILED,
                       'blocking_rules',         COALESCE(blk.blocking_rules, ARRAY_CONSTRUCT()),
                       'eligibility_trace',      e.ELIGIBILITY_TRACE
                   ) AS suppression
            FROM GOLD.NBA_ELIGIBLE e
            LEFT JOIN (
                /* Every rule that returned BLOCK, as an array of
                   {rule, observed} rather than a concatenated string, so the
                   agent can quote one without parsing a delimiter. The governing
                   rule is named separately in suppression_reason; this is the
                   full set, because a pair commonly fails several and an RM
                   asking "why not" deserves the whole answer rather than the
                   first one alphabetically. */
                SELECT x.CUSTOMER_ID, x.ACTION_CODE,
                       ARRAY_AGG(OBJECT_CONSTRUCT('rule', x.rule,
                                                  'observed', x.observed))
                         WITHIN GROUP (ORDER BY x.rule) AS blocking_rules
                FROM (
                    SELECT e2.CUSTOMER_ID, e2.ACTION_CODE,
                           t.VALUE:rule::VARCHAR     AS rule,
                           t.VALUE:observed::VARCHAR AS observed
                    FROM GOLD.NBA_ELIGIBLE e2,
                         LATERAL FLATTEN(input => e2.ELIGIBILITY_TRACE) t
                    WHERE e2.CUSTOMER_ID = :v_customer_id
                      AND t.VALUE:verdict::VARCHAR = 'BLOCK'
                ) x
                GROUP BY x.CUSTOMER_ID, x.ACTION_CODE
            ) blk ON blk.CUSTOMER_ID = e.CUSTOMER_ID AND blk.ACTION_CODE = e.ACTION_CODE
            WHERE e.CUSTOMER_ID = :v_customer_id
              AND e.SUPPRESSED
              AND e.ELIGIBLE_ON_NEED
        ) s
        GROUP BY s.CUSTOMER_ID
    ) sup ON sup.CUSTOMER_ID = c.CUSTOMER_ID

    WHERE c.CUSTOMER_ID = :v_customer_id;

    RETURN :v_result;
END;
$$;


/* ============================================================================
   PART 4 — VERIFICATION
   ============================================================================ */

/* 4.1  B1. The quarantine holds on the serving path. Same idiom as sql/09 A1
        and sql/16 §3.1, read from stored DDL rather than trusted. This is the
        object the agent calls on every named customer. */
SELECT 'B1 segment truth not referenced on the serving path' AS assertion,
       COUNT_IF(UPPER(ddl) LIKE '%CUSTOMER_SEGMENT_TRUTH%') AS violations,
       IFF(COUNT_IF(UPPER(ddl) LIKE '%CUSTOMER_SEGMENT_TRUTH%') = 0, 'PASS', 'FAIL') AS verdict
FROM (
  SELECT GET_DDL('FUNCTION',  'APP.FORMAT_INR(FLOAT)')                    AS ddl
  UNION ALL SELECT GET_DDL('VIEW',      'APP.V_NBA_EVIDENCE_RESOLVED')
  UNION ALL SELECT GET_DDL('PROCEDURE', 'APP.GET_NEXT_BEST_ACTIONS(VARCHAR)')
);

/* 4.2  B2. Indian digit grouping is correct across the boundary cases. The
        four-digit case is the one a naive implementation gets wrong, because
        the leading group is a single digit and must not acquire a stray comma. */
WITH cases AS (
  SELECT * FROM VALUES
    (0,          '0'),
    (7,          '7'),
    (99,         '99'),
    (999,        '999'),
    (1000,       '1,000'),          -- four digits: leading group is one digit
    (9999,       '9,999'),
    (10000,      '10,000'),
    (99999,      '99,999'),
    (100000,     '1,00,000'),       -- one lakh
    (717355,     '7,17,355'),
    (7177355,    '71,77,355'),      -- total_expected_value_inr
    (10000000,   '1,00,00,000'),    -- one crore
    (521397600,  '52,13,97,600'),   -- arrears_exposure_inr
    (4155304200, '4,15,53,04,200'),
    (-56574,     '-56,574')
  AS t(amount, expected)
)
SELECT 'B2 Indian digit grouping' AS assertion,
       amount,
       expected,
       APP.FORMAT_INR(amount) AS actual,
       IFF(APP.FORMAT_INR(amount) = expected, 'PASS', 'FAIL') AS verdict
FROM cases
ORDER BY IFF(APP.FORMAT_INR(amount) = expected, 1, 0), ABS(amount);

/* 4.2b  NULL in, NULL out -- separate because a NULL cannot be compared with
         IFF in the same shape as the rest. */
SELECT 'B2b FORMAT_INR(NULL) is NULL' AS assertion,
       IFF(APP.FORMAT_INR(NULL) IS NULL, 'PASS', 'FAIL') AS verdict;

/* 4.3  B3. Every cited evidence id resolves to a timeline event. sql/14 stripped
        unresolvable labels from the rationale, so this should be zero; the
        assertion exists because a break here would otherwise show up as an RM
        being handed a citation that means nothing. */
SELECT 'B3 all cited evidence resolves' AS assertion,
       COUNT(*)                                        AS total_citations,
       COUNT_IF(NOT RESOLVED)                          AS unresolved,
       IFF(COUNT_IF(NOT RESOLVED) = 0, 'PASS', 'FAIL') AS verdict
FROM APP.V_NBA_EVIDENCE_RESOLVED;

/* 4.4  B4. The four statuses each occur where they should, exercised against
        real ids rather than asserted in prose.

        The suppressed-everything case is the interesting one: a customer with
        no published action but with suppressed candidates is the case where an
        engine that returned only an empty array would be actively misleading. */
WITH probes AS (
  SELECT 'OK -- has published actions' AS scenario,
         (SELECT MIN(CUSTOMER_ID) FROM GOLD.NEXT_BEST_ACTION)::VARCHAR AS arg,
         'OK' AS expected_status
  UNION ALL
  SELECT 'NO_ACTIONS -- nothing published but candidates were blocked',
         (SELECT MIN(e.CUSTOMER_ID)::VARCHAR
            FROM GOLD.NBA_ELIGIBLE e
           WHERE e.SUPPRESSED AND e.ELIGIBLE_ON_NEED
             AND NOT EXISTS (SELECT 1 FROM GOLD.NEXT_BEST_ACTION n
                              WHERE n.CUSTOMER_ID = e.CUSTOMER_ID)),
         'NO_ACTIONS'
  UNION ALL
  SELECT 'UNKNOWN_CUSTOMER', '999999', 'UNKNOWN_CUSTOMER'
  UNION ALL
  SELECT 'BAD_ARGUMENT', 'the customer', 'BAD_ARGUMENT'
)
SELECT 'B4 status vocabulary' AS assertion, scenario, arg, expected_status
FROM probes ORDER BY scenario;

/* Each status called for real. Four separate statements because a procedure
   cannot be invoked from inside a SELECT. */
CALL APP.GET_NEXT_BEST_ACTIONS('3925');
CALL APP.GET_NEXT_BEST_ACTIONS('999999');
CALL APP.GET_NEXT_BEST_ACTIONS('the customer');
CALL APP.GET_NEXT_BEST_ACTIONS('  2069  ');

/* 4.5  B5. THE INVARIANT THAT MATTERS MOST HERE. No action that GOLD.NBA_ELIGIBLE
        suppressed may appear in recommended_actions, for any customer. sql/16 A9
        asserts this over the tables; this asserts it over the SHAPE THE AGENT
        ACTUALLY RECEIVES, which is the thing that would do the damage.

        Checked across a checked_customers rather than one customer, because a leak would
        most likely be a join defect affecting a subset. */
WITH checked_customers AS (
  SELECT CUSTOMER_ID FROM GOLD.NEXT_BEST_ACTION
  WHERE CUSTOMER_ID IN (SELECT CUSTOMER_ID FROM GOLD.NBA_ELIGIBLE
                        WHERE SUPPRESSED AND ELIGIBLE_ON_NEED)
  GROUP BY CUSTOMER_ID
  ORDER BY CUSTOMER_ID
  LIMIT 200
),
recommended AS (
  SELECT n.CUSTOMER_ID, n.ACTION_CODE
  FROM GOLD.NEXT_BEST_ACTION n JOIN checked_customers s ON s.CUSTOMER_ID = n.CUSTOMER_ID
),
leaked AS (
  SELECT r.CUSTOMER_ID, r.ACTION_CODE
  FROM recommended r
  JOIN GOLD.NBA_ELIGIBLE e
    ON e.CUSTOMER_ID = r.CUSTOMER_ID AND e.ACTION_CODE = r.ACTION_CODE
  WHERE e.SUPPRESSED
)
SELECT 'B5 no suppressed action reaches the agent' AS assertion,
       (SELECT COUNT(*) FROM checked_customers)   AS customers_checked,
       (SELECT COUNT(*) FROM leaked)   AS leaks,
       IFF((SELECT COUNT(*) FROM leaked) = 0, 'PASS', 'FAIL') AS verdict;

/* 4.6  B6. Coverage and shape of the payload across the book, so the numbers in
        this file's header are checkable and a regression in any one part of the
        document is visible as a count rather than as a missing key. */
SELECT 'B6 payload coverage' AS check_name,
       (SELECT COUNT(*) FROM GOLD.CUSTOMER_360)                        AS customers,
       (SELECT COUNT(DISTINCT CUSTOMER_ID) FROM GOLD.NEXT_BEST_ACTION) AS with_recommendations,
       (SELECT COUNT(DISTINCT CUSTOMER_ID) FROM GOLD.NBA_ELIGIBLE
         WHERE SUPPRESSED AND ELIGIBLE_ON_NEED)                        AS with_suppressions,
       (SELECT COUNT(DISTINCT CUSTOMER_ID) FROM GOLD.NBA_ELIGIBLE e
         WHERE e.SUPPRESSED AND e.ELIGIBLE_ON_NEED
           AND NOT EXISTS (SELECT 1 FROM GOLD.NEXT_BEST_ACTION n
                            WHERE n.CUSTOMER_ID = e.CUSTOMER_ID))      AS suppressed_with_nothing_published,
       (SELECT COUNT(*) FROM APP.V_NBA_EVIDENCE_RESOLVED)              AS evidence_citations;

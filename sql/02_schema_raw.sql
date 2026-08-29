/* ============================================================================
   02_schema_raw.sql — RAW schema, seeded RNG, and landed-silo table DDL
   ----------------------------------------------------------------------------
   Idempotent. CREATE OR REPLACE throughout. Safe against an empty database.

   RAW holds the silos in as-received shape. Deliberately NOT conformed:
   POLICY, LOAN and CARD stay separate here because that is how they arrive
   from three different systems of record. CURATED.CONTRACT unifies them at M2.

   ----------------------------------------------------------------------------
   ON REPRODUCIBILITY  (read this before changing the generators)
   ----------------------------------------------------------------------------
   The brief calls for UNIFORM / NORMAL / RANDOM(seed). There is a catch:
   RANDOM(seed) is deterministic only with respect to *evaluation order*.
   GENERATOR scans are parallelised, so which row receives which draw from the
   sequence can shift between runs, between warehouse sizes, and after a
   cluster resize. Row values would therefore not be stable across rebuilds,
   and a planted segment could quietly move from one customer to another.

   So the RNG here derives every draw from the row's own identity:

       value = f( SEED , purpose-salt , row key )

   via HASH(). This is order-independent, parallel-safe, and byte-stable: the
   same SEED always produces the same value for the same customer, no matter
   how the query is scheduled. RND_NORM reproduces a normal distribution from
   three independent uniforms (Irwin-Hall, n=3), so distributional shape is
   preserved without giving up determinism.

   Dates are anchored to RAW.AS_OF() = CURRENT_DATE on purpose. The planted
   temporal segments ("renewal in the next 30 days", "complaint in the last
   60 days") must stay true whenever the demo is run, so the calendar slides
   with the run date. Reproducibility is therefore exact for a given
   (SEED, run date) pair. Pin AS_OF() to a literal if you need frozen dates.
   ============================================================================ */

USE ROLE COCO_BUILDER;
USE WAREHOUSE COCO_WH;
USE DATABASE C360_NBA;

CREATE SCHEMA IF NOT EXISTS RAW
  COMMENT = 'Landed source silos in as-received shape. No conforming here.';

USE SCHEMA RAW;

/* ============================================================================
   1. Seeded, parallel-safe RNG
   ============================================================================ */

-- Single point of control for the whole synthetic dataset.
-- Change this string and every table regenerates to a different but equally
-- reproducible universe.
CREATE OR REPLACE FUNCTION RAW.SEED()
RETURNS VARCHAR
LANGUAGE SQL
IMMUTABLE
COMMENT = 'Master seed. One literal governs the entire synthetic dataset.'
AS $$ 'c360-nba-seed-v1' $$;

-- Calendar anchor. Everything temporal is expressed relative to this.
CREATE OR REPLACE FUNCTION RAW.AS_OF()
RETURNS DATE
LANGUAGE SQL
COMMENT = 'Calendar anchor for all generated dates. Pin to a literal to freeze.'
AS $$ CURRENT_DATE $$;

-- Uniform [0,1). K must uniquely identify (purpose, row).
CREATE OR REPLACE FUNCTION RAW.RND(K VARCHAR)
RETURNS FLOAT
LANGUAGE SQL
IMMUTABLE
COMMENT = 'Deterministic uniform [0,1) keyed on SEED + purpose + row identity.'
AS $$ ((ABS(HASH(RAW.SEED() || '~' || K)) % 1000000007) / 1000000007.0)::FLOAT $$;

CREATE OR REPLACE FUNCTION RAW.RND_INT(K VARCHAR, LO NUMBER, HI NUMBER)
RETURNS NUMBER
LANGUAGE SQL
IMMUTABLE
COMMENT = 'Deterministic uniform integer in [LO,HI] inclusive.'
AS $$ (LO + FLOOR(RAW.RND(K) * (HI - LO + 1)))::NUMBER $$;

CREATE OR REPLACE FUNCTION RAW.RND_BOOL(K VARCHAR, P FLOAT)
RETURNS BOOLEAN
LANGUAGE SQL
IMMUTABLE
COMMENT = 'Deterministic Bernoulli draw, TRUE with probability P.'
AS $$ RAW.RND(K) < P $$;

-- Normal via Irwin-Hall (sum of 3 independent uniforms).
-- mean 1.5, variance 3/12 = 0.25, sd 0.5  ->  z = (u1+u2+u3 - 1.5) / 0.5
CREATE OR REPLACE FUNCTION RAW.RND_NORM(K VARCHAR, MEAN FLOAT, SD FLOAT)
RETURNS FLOAT
LANGUAGE SQL
IMMUTABLE
COMMENT = 'Deterministic normal draw. Irwin-Hall n=3 keeps shape without RANDOM().'
AS $$
  (MEAN + SD * ((RAW.RND(K || '#a') + RAW.RND(K || '#b') + RAW.RND(K || '#c') - 1.5) / 0.5))::FLOAT
$$;

-- Normal, clamped and floored to a sane positive range. Used for money.
CREATE OR REPLACE FUNCTION RAW.RND_NORM_CLAMP(K VARCHAR, MEAN FLOAT, SD FLOAT, LO FLOAT, HI FLOAT)
RETURNS FLOAT
LANGUAGE SQL
IMMUTABLE
COMMENT = 'Deterministic normal draw clamped to [LO,HI].'
AS $$ LEAST(HI, GREATEST(LO, RAW.RND_NORM(K, MEAN, SD)))::FLOAT $$;

CREATE OR REPLACE FUNCTION RAW.RND_PICK(K VARCHAR, A ARRAY)
RETURNS VARCHAR
LANGUAGE SQL
IMMUTABLE
COMMENT = 'Deterministic uniform pick from an array.'
AS $$ GET(A, RAW.RND_INT(K, 0, ARRAY_SIZE(A) - 1)::INT)::VARCHAR $$;

/* ============================================================================
   2. Eval ground truth  (quarantined)
   ----------------------------------------------------------------------------
   Generated FIRST. Every other generator reads this table and conditions its
   output on it, which is what makes the planted patterns land with exact
   counts instead of relying on random draws happening to coincide.

   It lives in its own table rather than as a CUSTOMER column so the NBA
   engine physically cannot pick it up as a feature. Only evals/ reads it.
   Nothing in CURATED, GOLD or APP may reference this table.
   ============================================================================ */

CREATE OR REPLACE TABLE RAW.CUSTOMER_SEGMENT_TRUTH (
  CUSTOMER_ID              NUMBER(10,0)  NOT NULL,
  -- Mutually exclusive primary planted pattern. NONE = ordinary noise profile.
  SEGMENT_CODE             VARCHAR(32)   NOT NULL,
  SEGMENT_NAME             VARCHAR(120)  NOT NULL,
  -- Expected next best action, for eval scoring.
  EXPECTED_ACTION          VARCHAR(48),
  -- Overlay 1: consent suppression, drawn to deliberately cut across the
  -- primaries so suppression logic has high-value targets to kill.
  IS_SUPPRESSED_OVERLAY    BOOLEAN       NOT NULL DEFAULT FALSE,
  SUPPRESSION_KIND         VARCHAR(32),
  -- Overlay 2: vulnerable customer who also looks like a great cross-sell.
  -- The guardrail test case.
  IS_VULNERABLE_CROSSSELL  BOOLEAN       NOT NULL DEFAULT FALSE,
  PLANT_NOTES              VARCHAR(500),
  LOAD_TS                  TIMESTAMP_NTZ NOT NULL
)
COMMENT = 'EVAL GROUND TRUTH — do not reference from CURATED/GOLD/APP.';

/* ============================================================================
   3. Party silo
   ============================================================================ */

CREATE OR REPLACE TABLE RAW.CUSTOMER (
  CUSTOMER_ID        NUMBER(10,0)  NOT NULL,
  PARTY_ID           VARCHAR(20)   NOT NULL,   -- source-system natural key
  FULL_NAME          VARCHAR(120)  NOT NULL,
  GENDER             VARCHAR(1),
  DOB                DATE          NOT NULL,
  AGE_YEARS          NUMBER(3,0),
  CITY               VARCHAR(60),
  STATE              VARCHAR(60),
  PINCODE            VARCHAR(6),
  -- Commercial value segment. NOT the planted segment; that lives in
  -- CUSTOMER_SEGMENT_TRUTH.SEGMENT_CODE.
  SEGMENT            VARCHAR(20),
  INCOME_BAND        VARCHAR(20),
  INCOME_BAND_RANK   NUMBER(2,0),              -- 1 low .. 5 high, for eligibility
  ANNUAL_INCOME_INR  NUMBER(12,0),
  TENURE_START       DATE,
  TENURE_MONTHS      NUMBER(5,0),
  KYC_STATUS         VARCHAR(20),
  VULNERABILITY_FLAG BOOLEAN,
  VULNERABILITY_KIND VARCHAR(40),
  EMAIL              VARCHAR(120),
  MOBILE             VARCHAR(15),
  PRIMARY_HOUSEHOLD_ID VARCHAR(20),
  LOAD_TS            TIMESTAMP_NTZ NOT NULL
)
COMMENT = 'Customer master as received from the party system.';

CREATE OR REPLACE TABLE RAW.HOUSEHOLD (
  HOUSEHOLD_ID   VARCHAR(20)   NOT NULL,
  CUSTOMER_ID    NUMBER(10,0)  NOT NULL,
  MEMBER_SEQ     NUMBER(3,0)   NOT NULL,
  RELATIONSHIP   VARCHAR(20)   NOT NULL,       -- SELF/SPOUSE/CHILD/PARENT/SIBLING
  IS_HEAD        BOOLEAN       NOT NULL,
  HOUSEHOLD_SIZE NUMBER(3,0),
  CITY           VARCHAR(60),
  STATE          VARCHAR(60),
  LOAD_TS        TIMESTAMP_NTZ NOT NULL
)
COMMENT = 'Household membership link. Grain = one row per customer per household.';

CREATE OR REPLACE TABLE RAW.CONSENT (
  CONSENT_ID    VARCHAR(24)   NOT NULL,
  CUSTOMER_ID   NUMBER(10,0)  NOT NULL,
  CHANNEL       VARCHAR(10)   NOT NULL,        -- CALL/SMS/EMAIL/WHATSAPP
  OPT_IN_FLAG   BOOLEAN       NOT NULL,
  DNC_FLAG      BOOLEAN       NOT NULL,
  VALID_FROM    DATE          NOT NULL,
  VALID_TO      DATE,                          -- NULL = open-ended
  CONSENT_SOURCE VARCHAR(30),
  CAPTURED_AT   TIMESTAMP_NTZ,
  LOAD_TS       TIMESTAMP_NTZ NOT NULL
)
COMMENT = 'Consent registry. One row per customer per channel.';

/* ============================================================================
   4. Product catalogue
   ============================================================================ */

CREATE OR REPLACE TABLE RAW.PRODUCT_CATALOG (
  PRODUCT_CODE          VARCHAR(24)   NOT NULL,
  PRODUCT_NAME          VARCHAR(120)  NOT NULL,
  LINE_OF_BUSINESS      VARCHAR(20)   NOT NULL, -- INSURANCE / BANKING
  PRODUCT_FAMILY        VARCHAR(24)   NOT NULL, -- MOTOR/HEALTH/TERM/HOME/ULIP/LOAN/CARD
  PRODUCT_TYPE          VARCHAR(24)   NOT NULL, -- PROTECTION/INVESTMENT/CREDIT
  MARGIN_RATE           NUMBER(5,4)   NOT NULL, -- feeds GOLD EV arithmetic
  AVG_TICKET_SIZE_INR   NUMBER(12,0)  NOT NULL,
  -- Minimum eligibility rules, evaluated deterministically in GOLD
  MIN_AGE               NUMBER(3,0),
  MAX_AGE               NUMBER(3,0),
  MIN_INCOME_BAND_RANK  NUMBER(2,0),
  MIN_TENURE_MONTHS     NUMBER(5,0),
  REQUIRED_KYC_STATUS   VARCHAR(20),
  MAX_DPD_DAYS          NUMBER(4,0),            -- arrears gate
  ALLOWED_FOR_VULNERABLE BOOLEAN,               -- vulnerability gate
  IS_SELLABLE           BOOLEAN       NOT NULL,
  ELIGIBILITY_NOTES     VARCHAR(400),
  LOAD_TS               TIMESTAMP_NTZ NOT NULL
)
COMMENT = 'Every sellable product with margin and minimum eligibility rules.';

/* ============================================================================
   5. Insurance silo
   ----------------------------------------------------------------------------
   POLICY_TYPE includes ULIP alongside MOTOR/HEALTH/TERM/HOME. A ULIP is an
   insurance-wrapped investment and is genuinely booked on the policy system
   in the Indian market, so it belongs here rather than in a separate table.
   It also gives the wealth-referral segment a real "already holds an
   investment product" exclusion to test against.
   ============================================================================ */

CREATE OR REPLACE TABLE RAW.POLICY (
  POLICY_ID         NUMBER(10,0)  NOT NULL,
  POLICY_NUMBER     VARCHAR(24)   NOT NULL,
  CUSTOMER_ID       NUMBER(10,0)  NOT NULL,
  PRODUCT_CODE      VARCHAR(24)   NOT NULL,
  POLICY_TYPE       VARCHAR(12)   NOT NULL,     -- MOTOR/HEALTH/TERM/HOME/ULIP
  PREMIUM_INR       NUMBER(12,0)  NOT NULL,
  PREMIUM_FREQUENCY VARCHAR(12)   NOT NULL,     -- MONTHLY/QUARTERLY/ANNUAL
  SUM_ASSURED_INR   NUMBER(14,0)  NOT NULL,
  START_DATE        DATE          NOT NULL,
  RENEWAL_DATE      DATE          NOT NULL,
  STATUS            VARCHAR(16)   NOT NULL,     -- ACTIVE/LAPSED/SURRENDERED/MATURED
  LAPSE_FLAG        BOOLEAN       NOT NULL,
  CHANNEL_SOLD      VARCHAR(20),                -- AGENT/BANCA/DIGITAL/BROKER/TELE
  AGENT_ID          VARCHAR(16),
  LOAD_TS           TIMESTAMP_NTZ NOT NULL
)
COMMENT = 'Policy book of business as received from the policy admin system.';

CREATE OR REPLACE TABLE RAW.CLAIM (
  CLAIM_ID            NUMBER(10,0)  NOT NULL,
  CLAIM_NUMBER        VARCHAR(24)   NOT NULL,
  POLICY_ID           NUMBER(10,0)  NOT NULL,
  CUSTOMER_ID         NUMBER(10,0)  NOT NULL,
  CLAIM_TYPE          VARCHAR(20)   NOT NULL,
  CLAIM_AMOUNT_INR    NUMBER(12,0)  NOT NULL,
  APPROVED_AMOUNT_INR NUMBER(12,0),
  STATUS              VARCHAR(16)   NOT NULL,   -- SETTLED/REJECTED/IN_REVIEW/OPEN
  FILED_AT            TIMESTAMP_NTZ NOT NULL,
  SETTLED_AT          TIMESTAMP_NTZ,
  SETTLEMENT_DAYS     NUMBER(5,0),
  LOAD_TS             TIMESTAMP_NTZ NOT NULL
)
COMMENT = 'Claims as received from the claims system.';

/* ============================================================================
   6. Lending silo
   ----------------------------------------------------------------------------
   DPD_DAYS_M1 / _M2 are last month's and the month before's DPD, carried
   explicitly so "rising DPD" is a pure predicate rather than something the
   collections segment has to reconstruct from the ledger.
   ============================================================================ */

CREATE OR REPLACE TABLE RAW.LOAN (
  LOAN_ID           NUMBER(10,0)  NOT NULL,
  LOAN_ACCOUNT_NO   VARCHAR(24)   NOT NULL,
  CUSTOMER_ID       NUMBER(10,0)  NOT NULL,
  PRODUCT_CODE      VARCHAR(24)   NOT NULL,
  LOAN_TYPE         VARCHAR(12)   NOT NULL,     -- HOME/AUTO/PERSONAL
  PRINCIPAL_INR     NUMBER(14,0)  NOT NULL,
  INTEREST_RATE_PCT NUMBER(5,2)   NOT NULL,
  EMI_INR           NUMBER(12,0)  NOT NULL,
  TENURE_MONTHS     NUMBER(4,0)   NOT NULL,
  MONTHS_ELAPSED    NUMBER(4,0)   NOT NULL,
  OUTSTANDING_INR   NUMBER(14,0)  NOT NULL,
  DISBURSAL_DATE    DATE          NOT NULL,
  FIRST_EMI_DATE    DATE          NOT NULL,
  DPD_DAYS          NUMBER(4,0)   NOT NULL,     -- current
  DPD_DAYS_M1       NUMBER(4,0)   NOT NULL,     -- one month ago
  DPD_DAYS_M2       NUMBER(4,0)   NOT NULL,     -- two months ago
  DPD_BUCKET        VARCHAR(10)   NOT NULL,     -- 0/1-30/31-60/61-90/90+
  RESTRUCTURE_FLAG  BOOLEAN       NOT NULL,
  STATUS            VARCHAR(16)   NOT NULL,     -- ACTIVE/CLOSED/WRITTEN_OFF
  LOAD_TS           TIMESTAMP_NTZ NOT NULL
)
COMMENT = 'Loan book as received from the lending system.';

/* ============================================================================
   7. Cards silo
   ----------------------------------------------------------------------------
   Four utilisation points (current + three trailing months) so "rising
   utilisation" is expressible as a chain of inequalities.
   ============================================================================ */

CREATE OR REPLACE TABLE RAW.CARD (
  CARD_ID             NUMBER(10,0)  NOT NULL,
  CARD_NUMBER_MASKED  VARCHAR(20)   NOT NULL,
  CUSTOMER_ID         NUMBER(10,0)  NOT NULL,
  PRODUCT_CODE        VARCHAR(24)   NOT NULL,
  CARD_TIER           VARCHAR(16)   NOT NULL,   -- CLASSIC/GOLD/PLATINUM/SIGNATURE
  CREDIT_LIMIT_INR    NUMBER(12,0)  NOT NULL,
  CURRENT_BALANCE_INR NUMBER(12,0)  NOT NULL,
  UTILISATION_PCT     NUMBER(5,2)   NOT NULL,   -- current
  UTILISATION_PCT_M1  NUMBER(5,2)   NOT NULL,
  UTILISATION_PCT_M2  NUMBER(5,2)   NOT NULL,
  UTILISATION_PCT_M3  NUMBER(5,2)   NOT NULL,
  MCC_MIX             VARIANT,                  -- {mcc_group: share_pct}
  TOP_MCC_GROUP       VARCHAR(30),
  ISSUED_DATE         DATE          NOT NULL,
  STATUS              VARCHAR(16)   NOT NULL,   -- ACTIVE/BLOCKED/CLOSED
  LOAD_TS             TIMESTAMP_NTZ NOT NULL
)
COMMENT = 'Credit card holdings with trailing utilisation and MCC mix.';

/* ============================================================================
   8. Transactions
   ============================================================================ */

CREATE OR REPLACE TABLE RAW.TXN (
  TXN_ID        NUMBER(12,0)  NOT NULL,
  CUSTOMER_ID   NUMBER(10,0)  NOT NULL,
  ACCOUNT_TYPE  VARCHAR(10)   NOT NULL,         -- SAVINGS/CARD
  CARD_ID       NUMBER(10,0),
  TXN_TS        TIMESTAMP_NTZ NOT NULL,
  TXN_DATE      DATE          NOT NULL,
  DIRECTION     VARCHAR(6)    NOT NULL,         -- DEBIT/CREDIT
  MCC           VARCHAR(4)    NOT NULL,
  MCC_GROUP     VARCHAR(30)   NOT NULL,
  AMOUNT_INR    NUMBER(12,2)  NOT NULL,
  CHANNEL       VARCHAR(16),                    -- UPI/POS/ECOM/ATM/NEFT/IMPS/RTGS
  MERCHANT_NAME VARCHAR(80),
  CITY          VARCHAR(60),
  IS_INBOUND_LUMPSUM BOOLEAN,                   -- convenience marker, >= 10 lakh credit
  LOAD_TS       TIMESTAMP_NTZ NOT NULL
)
COMMENT = '12 rolling months of transactions per customer.';

/* ============================================================================
   9. Repayment ledger
   ============================================================================ */

CREATE OR REPLACE TABLE RAW.REPAYMENT (
  REPAYMENT_ID     NUMBER(12,0)  NOT NULL,
  CUSTOMER_ID      NUMBER(10,0)  NOT NULL,
  OBLIGATION_TYPE  VARCHAR(16)   NOT NULL,      -- LOAN_EMI/POLICY_PREMIUM
  OBLIGATION_ID    NUMBER(10,0)  NOT NULL,      -- LOAN_ID or POLICY_ID
  INSTALMENT_NO    NUMBER(4,0)   NOT NULL,
  DUE_DATE         DATE          NOT NULL,
  DUE_AMOUNT_INR   NUMBER(12,0)  NOT NULL,
  PAID_DATE        DATE,
  PAID_AMOUNT_INR  NUMBER(12,0),
  DAYS_LATE        NUMBER(5,0)   NOT NULL DEFAULT 0,
  LATE_FLAG        BOOLEAN       NOT NULL,
  MISSED_FLAG      BOOLEAN       NOT NULL,
  PAYMENT_MODE     VARCHAR(16),                 -- NACH/UPI/NETBANKING/CHEQUE/CASH
  LOAD_TS          TIMESTAMP_NTZ NOT NULL
)
COMMENT = 'EMI and premium payment history with late and missed flags.';

/* ============================================================================
   10. Servicing silo
   ----------------------------------------------------------------------------
   Structured columns plus a short templated note. The retention-save segment
   is defined partly by "a complaint in the last 60 days", so this table has
   to exist at seed time. Rich free text and call audio arrive at M1/M3.
   ============================================================================ */

CREATE OR REPLACE TABLE RAW.SERVICE_TICKET (
  TICKET_ID           NUMBER(10,0)  NOT NULL,
  TICKET_NUMBER       VARCHAR(24)   NOT NULL,
  CUSTOMER_ID         NUMBER(10,0)  NOT NULL,
  RELATED_OBJECT_TYPE VARCHAR(12),              -- POLICY/LOAN/CARD/NONE
  RELATED_OBJECT_ID   NUMBER(10,0),
  CHANNEL             VARCHAR(12)   NOT NULL,   -- CALL/EMAIL/BRANCH/APP/WHATSAPP
  CATEGORY            VARCHAR(30)   NOT NULL,
  SUB_CATEGORY        VARCHAR(40),
  SEVERITY            NUMBER(1,0)   NOT NULL,   -- 1 low .. 4 critical
  IS_COMPLAINT        BOOLEAN       NOT NULL,
  STATUS              VARCHAR(16)   NOT NULL,   -- OPEN/IN_PROGRESS/RESOLVED/CLOSED
  OPENED_AT           TIMESTAMP_NTZ NOT NULL,
  CLOSED_AT           TIMESTAMP_NTZ,
  RESOLUTION_HOURS    NUMBER(6,1),
  NOTE_TEXT           VARCHAR(1000),
  LOAD_TS             TIMESTAMP_NTZ NOT NULL
)
COMMENT = 'Servicing tickets: complaints, requests, grievances.';

/* ============================================================================
   11. Campaign history
   ============================================================================ */

CREATE OR REPLACE TABLE RAW.CAMPAIGN_HISTORY (
  CAMPAIGN_CONTACT_ID NUMBER(12,0)  NOT NULL,
  CAMPAIGN_ID         VARCHAR(20)   NOT NULL,
  CAMPAIGN_NAME       VARCHAR(120)  NOT NULL,
  CUSTOMER_ID         NUMBER(10,0)  NOT NULL,
  PRODUCT_CODE        VARCHAR(24),
  CHANNEL             VARCHAR(10)   NOT NULL,   -- CALL/SMS/EMAIL/WHATSAPP
  CONTACTED_AT        TIMESTAMP_NTZ NOT NULL,
  OUTCOME             VARCHAR(20)   NOT NULL,   -- NO_RESPONSE/INTERESTED/CONVERTED/
                                                -- DECLINED/OPT_OUT/COMPLAINED
  CONVERTED_FLAG      BOOLEAN       NOT NULL,
  REVENUE_INR         NUMBER(12,0),
  LOAD_TS             TIMESTAMP_NTZ NOT NULL
)
COMMENT = 'Outbound contact history. Feeds the cooling-off compliance rule.';

SELECT 'RAW schema + 12 tables + 7 seeded RNG functions created' AS status;

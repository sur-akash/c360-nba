/* ============================================================================
   03_seed_raw.sql — synthetic data generation for the RAW silos
   ----------------------------------------------------------------------------
   Pure SQL. GENERATOR + the seeded RNG from 02_schema_raw.sql. No Python,
   no LLM. Fully re-runnable: every step TRUNCATEs then INSERTs, so running
   this twice produces the same tables, not double the rows.

   ORDER MATTERS. CUSTOMER_SEGMENT_TRUTH is built first and every subsequent
   generator conditions its output on it. That is what makes the planted
   patterns land with exact counts.

   ----------------------------------------------------------------------------
   EXACTNESS CONTRACT
   ----------------------------------------------------------------------------
   Each planted segment is engineered to be the ONLY source of its identifying
   predicate. Where realism and provability conflict, provability wins, because
   the point of this dataset is to demonstrate that the NBA engine found
   precisely what was planted. Two examples:

     - Every home-loan holder who is NOT in PROTECTION_GAP is given home
       cover. In life some would lack it; here that would inflate the segment
       and make the count unprovable.
     - Non-COLLECTIONS customers are capped at one missed instalment across
       their whole book, so "2+ missed" cannot fire outside the segment.

   Noise is added everywhere it does not touch a planted predicate: partial
   channel DNC, non-monotonic card utilisation, single late payments, older
   complaints, ordinary renewals falling inside 30 days.

   Every predicate is documented in docs/DATA_SEGMENTS.md.

   ----------------------------------------------------------------------------
   TWO EXPRESSIONS SHARED ACROSS SCRIPTS
   ----------------------------------------------------------------------------
   Because POLICY is generated before LOAN, the home-loan decision has to be
   knowable in both. It is a pure function of customer identity:

       HAS_HOME_LOAN(c) := segment = 'PROTECTION_GAP'
                           OR RAW.RND_BOOL('homeloan|' || c, 0.14)

   and evaluated identically in both places. Same for HAS_CARD.
   ============================================================================ */

USE ROLE COCO_BUILDER;
USE WAREHOUSE COCO_WH;
USE DATABASE C360_NBA;
USE SCHEMA RAW;

/* ============================================================================
   STEP 1 — CUSTOMER_SEGMENT_TRUTH   (5,000 rows)
   ----------------------------------------------------------------------------
   Exact counts, not probabilistic. ROW_NUMBER over a deterministic
   pseudorandom ordering, then sliced. 8% of 5,000 is exactly 400, so that is
   exactly what gets planted.

     RETENTION_SAVE        400   8%   ranks    1- 400
     LIMIT_INCREASE        300   6%   ranks  401- 700
     PROTECTION_GAP        250   5%   ranks  701- 950
     COLLECTIONS_HARDSHIP  200   4%   ranks  951-1150
     WEALTH_REFERRAL       150   3%   ranks 1151-1300
     NONE                 3700  74%   ranks 1301-5000

   Overlays are drawn on independent orderings so they cut ACROSS the
   primaries. Pure independence would put only ~20 suppressed customers in
   RETENTION_SAVE, which is thin for a demo, so the first 110 suppression
   slots are allocated deliberately: 60 to RETENTION_SAVE and 50 to
   LIMIT_INCREASE. Those are the two highest-value cohorts, so suppression
   provably beats a large expected value rather than a rounding error.
   ============================================================================ */

TRUNCATE TABLE RAW.CUSTOMER_SEGMENT_TRUTH;

INSERT INTO RAW.CUSTOMER_SEGMENT_TRUTH
WITH ids AS (
  SELECT SEQ8() + 1 AS customer_id
  FROM TABLE(GENERATOR(ROWCOUNT => 5000))
),
ranked AS (
  SELECT customer_id,
         ROW_NUMBER() OVER (ORDER BY RAW.RND('primseg|' || customer_id), customer_id) AS r
  FROM ids
),
seg AS (
  SELECT customer_id,
         CASE
           WHEN r <=  400 THEN 'RETENTION_SAVE'
           WHEN r <=  700 THEN 'LIMIT_INCREASE'
           WHEN r <=  950 THEN 'PROTECTION_GAP'
           WHEN r <= 1150 THEN 'COLLECTIONS_HARDSHIP'
           WHEN r <= 1300 THEN 'WEALTH_REFERRAL'
           ELSE 'NONE'
         END AS segment_code
  FROM ranked
),
-- Suppression overlay: 250 customers (5%), 110 of them forced onto the two
-- highest-value primaries so suppression has something worth killing.
sup_ret AS (
  SELECT customer_id FROM seg WHERE segment_code = 'RETENTION_SAVE'
  QUALIFY ROW_NUMBER() OVER (ORDER BY RAW.RND('sup|' || customer_id), customer_id) <= 60
),
sup_lim AS (
  SELECT customer_id FROM seg WHERE segment_code = 'LIMIT_INCREASE'
  QUALIFY ROW_NUMBER() OVER (ORDER BY RAW.RND('sup|' || customer_id), customer_id) <= 50
),
sup_forced AS (
  SELECT customer_id FROM sup_ret
  UNION ALL
  SELECT customer_id FROM sup_lim
),
sup_topup AS (
  SELECT customer_id FROM seg
  WHERE customer_id NOT IN (SELECT customer_id FROM sup_forced)
  QUALIFY ROW_NUMBER() OVER (ORDER BY RAW.RND('suptop|' || customer_id), customer_id) <= 140
),
sup AS (
  SELECT customer_id FROM sup_forced
  UNION ALL
  SELECT customer_id FROM sup_topup
),
-- Vulnerability guardrail overlay: 100 customers (2%) who are flagged
-- vulnerable AND engineered to look like excellent cross-sell targets.
-- 40 sit inside PROTECTION_GAP (a genuine, high-EV product gap the engine
-- must still refuse to act on) and 60 sit in NONE with affluent, clean,
-- under-penetrated profiles.
vul_gap AS (
  SELECT customer_id FROM seg WHERE segment_code = 'PROTECTION_GAP'
  QUALIFY ROW_NUMBER() OVER (ORDER BY RAW.RND('vul|' || customer_id), customer_id) <= 40
),
vul_none AS (
  SELECT customer_id FROM seg WHERE segment_code = 'NONE'
  QUALIFY ROW_NUMBER() OVER (ORDER BY RAW.RND('vul|' || customer_id), customer_id) <= 60
),
vul AS (
  SELECT customer_id FROM vul_gap
  UNION ALL
  SELECT customer_id FROM vul_none
)
SELECT
  s.customer_id,
  s.segment_code,
  CASE s.segment_code
    WHEN 'RETENTION_SAVE'       THEN 'Renewal due within 30 days with an open complaint in the last 60 days'
    WHEN 'LIMIT_INCREASE'       THEN 'Rising card utilisation on a clean repayment record'
    WHEN 'PROTECTION_GAP'       THEN 'Active home loan with no home insurance cover'
    WHEN 'COLLECTIONS_HARDSHIP' THEN 'Two or more missed instalments with rising DPD'
    WHEN 'WEALTH_REFERRAL'      THEN 'Large one-off inbound credit and no investment product'
    ELSE                             'No planted pattern - ordinary noise profile'
  END                                                          AS segment_name,
  CASE s.segment_code
    WHEN 'RETENTION_SAVE'       THEN 'RETENTION_SAVE_CALL'
    WHEN 'LIMIT_INCREASE'       THEN 'CARD_LIMIT_INCREASE'
    WHEN 'PROTECTION_GAP'       THEN 'HOME_PROTECTION_CROSS_SELL'
    WHEN 'COLLECTIONS_HARDSHIP' THEN 'COLLECTIONS_HARDSHIP_OUTREACH'
    WHEN 'WEALTH_REFERRAL'      THEN 'WEALTH_REFERRAL'
    ELSE NULL
  END                                                          AS expected_action,
  (sup.customer_id IS NOT NULL)                                AS is_suppressed_overlay,
  CASE
    WHEN sup.customer_id IS NULL THEN NULL
    WHEN RAW.RND_BOOL('supkind|' || s.customer_id, 0.60) THEN 'DNC'
    ELSE 'EXPIRED_CONSENT'
  END                                                          AS suppression_kind,
  (vul.customer_id IS NOT NULL)                                AS is_vulnerable_crosssell,
  ARRAY_TO_STRING(ARRAY_COMPACT(ARRAY_CONSTRUCT(
    'primary=' || s.segment_code,
    IFF(sup.customer_id IS NOT NULL, 'overlay=CONSENT_SUPPRESSED', NULL),
    IFF(vul.customer_id IS NOT NULL, 'overlay=VULNERABLE_CROSSSELL_GUARDRAIL', NULL)
  )), ' ; ')                                                   AS plant_notes,
  CURRENT_TIMESTAMP()                                          AS load_ts
FROM seg s
LEFT JOIN sup ON sup.customer_id = s.customer_id
LEFT JOIN vul ON vul.customer_id = s.customer_id;

/* ============================================================================
   STEP 2 — CUSTOMER   (5,000 rows)
   ----------------------------------------------------------------------------
   Reference data (names, cities) is inlined as VALUES and joined by a
   deterministic index rather than held in arrays, so the SQL stays readable.

   Two deliberate constraints, both so that the intended rule is the one that
   fires in GOLD and not an unrelated one:

     - KYC_STATUS is forced to VERIFIED for every planted segment except
       COLLECTIONS_HARDSHIP. Otherwise a stray EXPIRED KYC would suppress a
       customer for the wrong reason and muddy the compliance trace.
     - Baseline (unplanted) vulnerable customers are capped at
       INCOME_BAND_RANK <= 3, while the 100 guardrail customers are 4 or 5.
       That makes  VULNERABILITY_FLAG AND INCOME_BAND_RANK >= 4  an exact
       identifier for the guardrail cohort.
   ============================================================================ */

TRUNCATE TABLE RAW.CUSTOMER;

INSERT INTO RAW.CUSTOMER
WITH first_names AS (
  SELECT $1::INT AS idx, $2::VARCHAR AS nm, $3::VARCHAR AS gender FROM VALUES
    (0,'Aarav','M'),(1,'Vivaan','M'),(2,'Aditya','M'),(3,'Rohan','M'),(4,'Karthik','M'),
    (5,'Siddharth','M'),(6,'Rajesh','M'),(7,'Suresh','M'),(8,'Imran','M'),(9,'Nikhil','M'),
    (10,'Manish','M'),(11,'Pranav','M'),(12,'Yusuf','M'),(13,'Ganesh','M'),(14,'Abhishek','M'),
    (15,'Ananya','F'),(16,'Diya','F'),(17,'Priya','F'),(18,'Meera','F'),(19,'Kavya','F'),
    (20,'Lakshmi','F'),(21,'Sneha','F'),(22,'Fatima','F'),(23,'Ritu','F'),(24,'Deepika','F'),
    (25,'Anjali','F'),(26,'Shreya','F'),(27,'Nandini','F'),(28,'Pooja','F'),(29,'Sunita','F')
),
last_names AS (
  SELECT $1::INT AS idx, $2::VARCHAR AS nm FROM VALUES
    (0,'Sharma'),(1,'Verma'),(2,'Iyer'),(3,'Nair'),(4,'Reddy'),(5,'Patel'),(6,'Desai'),
    (7,'Mehta'),(8,'Gupta'),(9,'Singh'),(10,'Chatterjee'),(11,'Bose'),(12,'Rao'),
    (13,'Kulkarni'),(14,'Joshi'),(15,'Khan'),(16,'Pillai'),(17,'Menon'),(18,'Agarwal'),
    (19,'Bhatt'),(20,'Chauhan'),(21,'Naidu'),(22,'Shetty'),(23,'Trivedi'),(24,'Malhotra')
),
cities AS (
  SELECT $1::INT AS idx, $2::VARCHAR AS city, $3::VARCHAR AS state, $4::VARCHAR AS pin3 FROM VALUES
    (0,'Mumbai','Maharashtra','400'),      (1,'Pune','Maharashtra','411'),
    (2,'Bengaluru','Karnataka','560'),     (3,'Mysuru','Karnataka','570'),
    (4,'Chennai','Tamil Nadu','600'),      (5,'Coimbatore','Tamil Nadu','641'),
    (6,'Hyderabad','Telangana','500'),     (7,'Warangal','Telangana','506'),
    (8,'Delhi','Delhi','110'),             (9,'Gurugram','Haryana','122'),
    (10,'Noida','Uttar Pradesh','201'),    (11,'Lucknow','Uttar Pradesh','226'),
    (12,'Kolkata','West Bengal','700'),    (13,'Durgapur','West Bengal','713'),
    (14,'Ahmedabad','Gujarat','380'),      (15,'Surat','Gujarat','395'),
    (16,'Jaipur','Rajasthan','302'),       (17,'Indore','Madhya Pradesh','452'),
    (18,'Kochi','Kerala','682'),           (19,'Bhubaneswar','Odisha','751')
),
base AS (
  SELECT
    t.customer_id,
    t.segment_code,
    t.is_vulnerable_crosssell,
    -- age 22..72, skewed to the working population
    RAW.RND_INT('age|' || t.customer_id, 22, 72)                       AS age_years,
    RAW.RND_INT('tenm|' || t.customer_id, 4, 240)                      AS tenure_months,
    RAW.RND_INT('fn|' || t.customer_id, 0, 29)                         AS fn_idx,
    RAW.RND_INT('ln|' || t.customer_id, 0, 24)                         AS ln_idx,
    RAW.RND_INT('city|' || t.customer_id, 0, 19)                       AS city_idx,
    -- Income band rank 1..5. Guardrail cohort forced affluent; baseline
    -- vulnerable customers capped at 3 so the guardrail predicate is exact.
    CASE
      WHEN t.is_vulnerable_crosssell THEN RAW.RND_INT('inc|' || t.customer_id, 4, 5)
      WHEN RAW.RND_BOOL('vulbase|' || t.customer_id, 0.025)
        THEN RAW.RND_INT('inc|' || t.customer_id, 1, 3)
      ELSE
        CASE
          WHEN RAW.RND('inc|' || t.customer_id) < 0.28 THEN 1
          WHEN RAW.RND('inc|' || t.customer_id) < 0.55 THEN 2
          WHEN RAW.RND('inc|' || t.customer_id) < 0.78 THEN 3
          WHEN RAW.RND('inc|' || t.customer_id) < 0.93 THEN 4
          ELSE 5
        END
    END                                                                AS income_band_rank,
    -- Vulnerable = guardrail cohort, plus a ~2.5% unrelated baseline.
    (t.is_vulnerable_crosssell OR RAW.RND_BOOL('vulbase|' || t.customer_id, 0.025))
                                                                       AS vulnerability_flag
  FROM RAW.CUSTOMER_SEGMENT_TRUTH t
)
SELECT
  b.customer_id,
  'PTY-' || LPAD(b.customer_id::VARCHAR, 7, '0')                       AS party_id,
  fn.nm || ' ' || ln.nm                                                AS full_name,
  fn.gender                                                            AS gender,
  DATEADD(day, -RAW.RND_INT('dobd|' || b.customer_id, 0, 364),
          DATEADD(year, -b.age_years, RAW.AS_OF()))                    AS dob,
  b.age_years,
  c.city,
  c.state,
  c.pin3 || LPAD(RAW.RND_INT('pin|' || b.customer_id, 1, 99)::VARCHAR, 3, '0') AS pincode,
  -- Commercial value segment, driven by income band. Not the planted segment.
  CASE b.income_band_rank
    WHEN 1 THEN 'MASS' WHEN 2 THEN 'MASS_AFFLUENT' WHEN 3 THEN 'AFFLUENT'
    WHEN 4 THEN 'PRIORITY' ELSE 'HNI'
  END                                                                  AS segment,
  CASE b.income_band_rank
    WHEN 1 THEN '0-3L' WHEN 2 THEN '3-8L' WHEN 3 THEN '8-15L'
    WHEN 4 THEN '15-30L' ELSE '30L+'
  END                                                                  AS income_band,
  b.income_band_rank,
  ROUND(RAW.RND_NORM_CLAMP('inca|' || b.customer_id,
        CASE b.income_band_rank
          WHEN 1 THEN 220000 WHEN 2 THEN 550000 WHEN 3 THEN 1150000
          WHEN 4 THEN 2200000 ELSE 4800000 END,
        CASE b.income_band_rank
          WHEN 1 THEN 45000 WHEN 2 THEN 110000 WHEN 3 THEN 200000
          WHEN 4 THEN 400000 ELSE 1400000 END,
        120000, 12000000), -3)                                         AS annual_income_inr,
  DATEADD(month, -b.tenure_months, RAW.AS_OF())                        AS tenure_start,
  b.tenure_months,
  -- Planted segments other than collections get clean KYC so the intended
  -- rule is the one that fires downstream.
  CASE
    WHEN b.segment_code IN ('RETENTION_SAVE','LIMIT_INCREASE','PROTECTION_GAP','WEALTH_REFERRAL')
      THEN 'VERIFIED'
    WHEN b.is_vulnerable_crosssell THEN 'VERIFIED'
    WHEN RAW.RND('kyc|' || b.customer_id) < 0.88 THEN 'VERIFIED'
    WHEN RAW.RND('kyc|' || b.customer_id) < 0.96 THEN 'PENDING'
    ELSE 'EXPIRED'
  END                                                                  AS kyc_status,
  b.vulnerability_flag,
  CASE
    WHEN NOT b.vulnerability_flag THEN NULL
    WHEN b.is_vulnerable_crosssell
      THEN RAW.RND_PICK('vk|' || b.customer_id,
             ARRAY_CONSTRUCT('RECENT_BEREAVEMENT','SERIOUS_ILLNESS','COGNITIVE_IMPAIRMENT',
                             'FINANCIAL_DISTRESS_DECLARED'))
    ELSE RAW.RND_PICK('vk|' || b.customer_id,
             ARRAY_CONSTRUCT('LOW_FINANCIAL_LITERACY','AGE_RELATED','DISABILITY',
                             'LANGUAGE_BARRIER'))
  END                                                                  AS vulnerability_kind,
  LOWER(REPLACE(fn.nm || '.' || ln.nm, ' ', '')) || b.customer_id::VARCHAR || '@example.in'
                                                                       AS email,
  '+919' || LPAD(RAW.RND_INT('mob|' || b.customer_id, 0, 999999999)::VARCHAR, 9, '0')
                                                                       AS mobile,
  NULL                                                                 AS primary_household_id,
  CURRENT_TIMESTAMP()                                                  AS load_ts
FROM base b
JOIN first_names fn ON fn.idx = b.fn_idx
JOIN last_names  ln ON ln.idx = b.ln_idx
JOIN cities      c  ON c.idx  = b.city_idx;

/* ============================================================================
   STEP 3 — HOUSEHOLD
   ----------------------------------------------------------------------------
   ~62% of customers head their own household; the rest attach to a
   deterministically chosen head. Household city/state comes from the head, so
   a member whose own CUSTOMER.CITY differs is left as-is. That mismatch is
   realistic silo drift and gives identity resolution at M2 something to do.
   ============================================================================ */

TRUNCATE TABLE RAW.HOUSEHOLD;

INSERT INTO RAW.HOUSEHOLD
WITH flagged AS (
  SELECT customer_id, city, state,
         RAW.RND_BOOL('hhhead|' || customer_id, 0.62) AS is_head
  FROM RAW.CUSTOMER
),
heads AS (
  SELECT customer_id AS head_id, city, state,
         ROW_NUMBER() OVER (ORDER BY customer_id) AS rn
  FROM flagged WHERE is_head
),
head_count AS (SELECT COUNT(*) AS n FROM heads),
assigned AS (
  -- heads point at themselves
  SELECT f.customer_id, f.customer_id AS head_id, TRUE AS is_head
  FROM flagged f WHERE f.is_head
  UNION ALL
  -- non-heads pick a head by deterministic index
  SELECT f.customer_id, h.head_id, FALSE AS is_head
  FROM flagged f
  CROSS JOIN head_count hc
  JOIN heads h ON h.rn = RAW.RND_INT('hhpick|' || f.customer_id, 1, hc.n)
  WHERE NOT f.is_head
),
sized AS (
  SELECT a.*,
         COUNT(*)     OVER (PARTITION BY a.head_id) AS household_size,
         ROW_NUMBER() OVER (PARTITION BY a.head_id
                            ORDER BY a.is_head DESC, a.customer_id) AS member_seq
  FROM assigned a
)
SELECT
  'HH-' || LPAD(s.head_id::VARCHAR, 7, '0')  AS household_id,
  s.customer_id,
  s.member_seq,
  CASE
    WHEN s.is_head THEN 'SELF'
    ELSE RAW.RND_PICK('rel|' || s.customer_id,
           ARRAY_CONSTRUCT('SPOUSE','CHILD','PARENT','SIBLING'))
  END                                        AS relationship,
  s.is_head,
  s.household_size,
  h.city,
  h.state,
  CURRENT_TIMESTAMP()                        AS load_ts
FROM sized s
JOIN heads h ON h.head_id = s.head_id;

UPDATE RAW.CUSTOMER c
SET PRIMARY_HOUSEHOLD_ID = h.HOUSEHOLD_ID
FROM RAW.HOUSEHOLD h
WHERE h.CUSTOMER_ID = c.CUSTOMER_ID;

/* ============================================================================
   STEP 4 — CONSENT   (20,000 rows = 5,000 x 4 channels)
   ----------------------------------------------------------------------------
   The suppression segment is defined at CUSTOMER level as "no contactable
   channel remains", not as "has a DNC flag somewhere". That is the question
   suppression logic actually has to answer, and it lets ordinary noise
   coexist with an exact segment count:

     - Every NON-suppressed customer has one deterministically chosen
       protected channel that is always opt-in, never DNC, never expired.
       Their other three channels carry realistic partial DNC and expiry.
     - Every SUPPRESSED customer has all four channels blocked, by kind:
         DNC             -> DNC_FLAG TRUE, OPT_IN FALSE on all four
         EXPIRED_CONSENT -> opted in, but VALID_TO fell in the past
   ============================================================================ */

TRUNCATE TABLE RAW.CONSENT;

INSERT INTO RAW.CONSENT
WITH channels AS (
  SELECT $1::INT AS ch_idx, $2::VARCHAR AS channel FROM VALUES
    (0,'CALL'),(1,'SMS'),(2,'EMAIL'),(3,'WHATSAPP')
),
grid AS (
  SELECT
    t.customer_id,
    t.is_suppressed_overlay,
    t.suppression_kind,
    ch.ch_idx,
    ch.channel,
    -- the one channel a non-suppressed customer is guaranteed to keep
    RAW.RND_INT('protch|' || t.customer_id, 0, 3) AS protected_ch,
    'k|' || t.customer_id || '|' || ch.channel    AS k
  FROM RAW.CUSTOMER_SEGMENT_TRUTH t
  CROSS JOIN channels ch
),
resolved AS (
  SELECT g.*,
    (g.ch_idx = g.protected_ch) AS is_protected,
    CASE
      WHEN g.is_suppressed_overlay AND g.suppression_kind = 'DNC'             THEN 'BLOCK_DNC'
      WHEN g.is_suppressed_overlay AND g.suppression_kind = 'EXPIRED_CONSENT' THEN 'BLOCK_EXPIRED'
      WHEN g.ch_idx = g.protected_ch                                         THEN 'CLEAN'
      WHEN RAW.RND_BOOL('cdnc|' || g.k, 0.18)                                THEN 'NOISE_DNC'
      WHEN RAW.RND_BOOL('copt|' || g.k, 0.15)                                THEN 'NOISE_OPTOUT'
      WHEN RAW.RND_BOOL('cexp|' || g.k, 0.12)                                THEN 'NOISE_EXPIRED'
      ELSE 'CLEAN'
    END AS state
  FROM grid g
)
SELECT
  'CNS-' || LPAD(r.customer_id::VARCHAR, 7, '0') || '-' || r.ch_idx::VARCHAR  AS consent_id,
  r.customer_id,
  r.channel,
  (r.state IN ('CLEAN','NOISE_EXPIRED','BLOCK_EXPIRED'))                      AS opt_in_flag,
  (r.state IN ('NOISE_DNC','BLOCK_DNC'))                                      AS dnc_flag,
  DATEADD(day, -RAW.RND_INT('cvf|' || r.k, 400, 1800), RAW.AS_OF())           AS valid_from,
  CASE
    -- expired: window closed in the past
    WHEN r.state IN ('NOISE_EXPIRED','BLOCK_EXPIRED')
      THEN DATEADD(day, -RAW.RND_INT('cvt|' || r.k, 10, 200), RAW.AS_OF())
    -- open-ended for most, an explicit future end date for some
    WHEN RAW.RND_BOOL('cvtn|' || r.k, 0.70) THEN NULL
    ELSE DATEADD(day, RAW.RND_INT('cvt2|' || r.k, 120, 900), RAW.AS_OF())
  END                                                                         AS valid_to,
  RAW.RND_PICK('csrc|' || r.k,
    ARRAY_CONSTRUCT('ONBOARDING_FORM','MOBILE_APP','BRANCH_KIOSK','TELE_VERIFICATION',
                    'WEB_PREFERENCE_CENTRE','TRAI_DNC_REGISTRY'))              AS consent_source,
  DATEADD(day, -RAW.RND_INT('ccap|' || r.k, 5, 400),
          CURRENT_TIMESTAMP()::TIMESTAMP_NTZ)                                 AS captured_at,
  CURRENT_TIMESTAMP()                                                         AS load_ts
FROM resolved r;

/* ============================================================================
   STEP 5 — PRODUCT_CATALOG   (16 rows)
   ----------------------------------------------------------------------------
   Hand-authored, not generated: margins and eligibility thresholds are
   business inputs to the GOLD expected-value arithmetic, so they need to be
   inspectable and stable rather than random.

   ALLOWED_FOR_VULNERABLE is FALSE for every acquisition product and TRUE only
   for service and hardship actions. That single column is what the
   vulnerability gate reads.
   ============================================================================ */

TRUNCATE TABLE RAW.PRODUCT_CATALOG;

INSERT INTO RAW.PRODUCT_CATALOG
SELECT
  $1::VARCHAR, $2::VARCHAR, $3::VARCHAR, $4::VARCHAR, $5::VARCHAR,
  $6::NUMBER(5,4), $7::NUMBER(12,0), $8::NUMBER(3,0), $9::NUMBER(3,0),
  $10::NUMBER(2,0), $11::NUMBER(5,0), $12::VARCHAR, $13::NUMBER(4,0),
  $14::BOOLEAN, $15::BOOLEAN, $16::VARCHAR, CURRENT_TIMESTAMP()
FROM VALUES
  -- code            name                              LOB        family  type        margin ticket   minA maxA rank tenure kyc      maxdpd vuln sellable notes
  ('INS_MOTOR_COMP','Comprehensive Motor Insurance',   'INSURANCE','MOTOR','PROTECTION',0.1400,  18000, 18, 75, 1,   0, 'VERIFIED', 90, FALSE, TRUE,
   'Age 18-75. Any income band. Vehicle must be registered to the proposer.'),
  ('INS_HEALTH_IND','Individual Health Indemnity',     'INSURANCE','HEALTH','PROTECTION',0.1800,  26000, 18, 65, 2,   0, 'VERIFIED', 60, FALSE, TRUE,
   'Age 18-65. Income band rank 2+. Pre-existing disease waiting period applies.'),
  ('INS_HEALTH_FAM','Family Floater Health',           'INSURANCE','HEALTH','PROTECTION',0.1900,  42000, 21, 60, 3,   6, 'VERIFIED', 60, FALSE, TRUE,
   'Age 21-60. Income band rank 3+. Requires at least two household members.'),
  ('INS_TERM_PLAIN','Pure Term Life Cover',            'INSURANCE','TERM', 'PROTECTION',0.2200,  22000, 21, 60, 2,   3, 'VERIFIED', 60, FALSE, TRUE,
   'Age 21-60. Income band rank 2+. Medicals above 50 lakh sum assured.'),
  ('INS_TERM_ROP',  'Term with Return of Premium',     'INSURANCE','TERM', 'PROTECTION',0.2400,  38000, 21, 55, 3,   6, 'VERIFIED', 60, FALSE, TRUE,
   'Age 21-55. Income band rank 3+.'),
  ('INS_HOME_STRUCT','Home Structure and Contents',    'INSURANCE','HOME', 'PROTECTION',0.1600,  14000, 21, 70, 2,   0, 'VERIFIED', 90, FALSE, TRUE,
   'Age 21-70. Mandatory-attachable to a home loan. Income band rank 2+.'),
  ('INS_HOME_LOAN_LINKED','Home Loan Linked Cover',    'INSURANCE','HOME', 'PROTECTION',0.1500,   9500, 21, 70, 1,   0, 'VERIFIED', 90, FALSE, TRUE,
   'Attaches to an active home loan. Sum assured tracks outstanding principal.'),
  ('INS_ULIP_BAL',  'Unit Linked Balanced Plan',       'INSURANCE','ULIP', 'INVESTMENT',0.0900,  95000, 21, 55, 4,  12, 'VERIFIED', 30, FALSE, TRUE,
   'Age 21-55. Income band rank 4+. Five-year lock-in. Not for vulnerable customers.'),
  ('INS_ULIP_EQ',   'Unit Linked Equity Growth',       'INSURANCE','ULIP', 'INVESTMENT',0.0850, 145000, 25, 50, 5,  18, 'VERIFIED', 30, FALSE, TRUE,
   'Age 25-50. Income band rank 5. Suitability assessment mandatory.'),
  ('BNK_LOAN_HOME', 'Home Loan',                       'BANKING',  'LOAN', 'CREDIT',    0.0320,4500000, 23, 60, 3,  12, 'VERIFIED', 30, FALSE, TRUE,
   'Age 23-60. Income band rank 3+. Minimum 12 months relationship tenure.'),
  ('BNK_LOAN_AUTO', 'Auto Loan',                       'BANKING',  'LOAN', 'CREDIT',    0.0400, 850000, 21, 62, 2,   6, 'VERIFIED', 30, FALSE, TRUE,
   'Age 21-62. Income band rank 2+.'),
  ('BNK_LOAN_PERS', 'Personal Loan',                   'BANKING',  'LOAN', 'CREDIT',    0.0680, 420000, 23, 58, 2,  12, 'VERIFIED',  0, FALSE, TRUE,
   'Age 23-58. Income band rank 2+. No current arrears permitted.'),
  ('BNK_CARD_GOLD', 'Gold Credit Card',                'BANKING',  'CARD', 'CREDIT',    0.0550, 120000, 21, 65, 2,   6, 'VERIFIED', 30, FALSE, TRUE,
   'Age 21-65. Income band rank 2+.'),
  ('BNK_CARD_PLAT', 'Platinum Credit Card',            'BANKING',  'CARD', 'CREDIT',    0.0600, 320000, 25, 65, 4,  12, 'VERIFIED', 30, FALSE, TRUE,
   'Age 25-65. Income band rank 4+.'),
  ('BNK_CARD_LIMIT_INC','Credit Limit Increase',       'BANKING',  'CARD', 'CREDIT',    0.0450,  90000, 21, 65, 2,  12, 'VERIFIED',  0, FALSE, TRUE,
   'Existing card required. No late payment in trailing 12 months. Zero DPD.'),
  ('SVC_HARDSHIP',  'Hardship and Restructure Review', 'BANKING',  'LOAN', 'CREDIT',    0.0000,      0, 18, 99, 1,   0, 'PENDING', 9999, TRUE,  FALSE,
   'Service action, not a sale. Always permitted, including vulnerable customers.');

/* ============================================================================
   STEP 6 — POLICY
   ----------------------------------------------------------------------------
   Slot-based generation: a grid of customer x slot, filtered to a
   per-customer policy count.

   Home cover is handled by an explicit rule rather than by chance, because
   PROTECTION_GAP must be the only source of "home loan with no home cover":

     slot 0  exists only for home-loan holders NOT in PROTECTION_GAP, and is
             always a HOME policy. PROTECTION_GAP customers never get one.
     slots 1..3  MOTOR / HEALTH / TERM / ULIP only. HOME is excluded from the
             general pick entirely, so home cover exists only via slot 0.

   ULIP is remapped to TERM for WEALTH_REFERRAL customers, so "holds no
   investment product" is true for all 150 of them.

   RENEWAL_DATE is left to fall naturally across the year, so roughly 8% of
   ordinary customers also renew inside 30 days. Those are the near-misses the
   retention rule has to distinguish from a genuine save, and the complaint
   generator in step 12 is what keeps them out of the segment.
   ============================================================================ */

TRUNCATE TABLE RAW.POLICY;

INSERT INTO RAW.POLICY
WITH cust AS (
  SELECT c.CUSTOMER_ID, c.AGE_YEARS, c.INCOME_BAND_RANK, c.TENURE_MONTHS,
         t.SEGMENT_CODE, t.IS_VULNERABLE_CROSSSELL,
         -- shared with LOAN generation; must stay identical in both places
         (t.SEGMENT_CODE = 'PROTECTION_GAP'
          OR RAW.RND_BOOL('homeloan|' || c.CUSTOMER_ID, 0.14)) AS has_home_loan
  FROM RAW.CUSTOMER c
  JOIN RAW.CUSTOMER_SEGMENT_TRUTH t ON t.CUSTOMER_ID = c.CUSTOMER_ID
),
counts AS (
  SELECT cu.*,
    CASE
      -- must hold at least one renewable policy
      WHEN cu.SEGMENT_CODE = 'RETENTION_SAVE'  THEN 1 + RAW.RND_INT('npol|' || cu.CUSTOMER_ID, 0, 2)
      -- engineered to look under-penetrated
      WHEN cu.IS_VULNERABLE_CROSSSELL          THEN RAW.RND_INT('npol|' || cu.CUSTOMER_ID, 0, 1)
      WHEN cu.SEGMENT_CODE = 'PROTECTION_GAP'  THEN RAW.RND_INT('npol|' || cu.CUSTOMER_ID, 0, 2)
      WHEN cu.SEGMENT_CODE = 'WEALTH_REFERRAL' THEN RAW.RND_INT('npol|' || cu.CUSTOMER_ID, 0, 2)
      ELSE RAW.RND_INT('npol|' || cu.CUSTOMER_ID, 0, 3)
    END AS n_pol
  FROM cust cu
),
slots AS (
  SELECT SEQ8() AS slot FROM TABLE(GENERATOR(ROWCOUNT => 4))   -- slots 0..3
),
grid AS (
  SELECT c.*, s.slot, 'p|' || c.CUSTOMER_ID || '|' || s.slot AS k
  FROM counts c
  CROSS JOIN slots s
  WHERE (s.slot = 0 AND c.has_home_loan AND c.SEGMENT_CODE <> 'PROTECTION_GAP')
     OR (s.slot >= 1 AND s.slot <= c.n_pol)
),
typed AS (
  SELECT g.*,
    CASE
      WHEN g.slot = 0 THEN 'HOME'
      ELSE
        CASE
          WHEN RAW.RND('ptype|' || g.k) < 0.34 THEN 'MOTOR'
          WHEN RAW.RND('ptype|' || g.k) < 0.64 THEN 'HEALTH'
          WHEN RAW.RND('ptype|' || g.k) < 0.86 THEN 'TERM'
          ELSE 'ULIP'
        END
    END AS raw_type
  FROM grid g
),
final_type AS (
  SELECT t.*,
    -- WEALTH_REFERRAL must hold no investment product
    IFF(t.raw_type = 'ULIP' AND t.SEGMENT_CODE = 'WEALTH_REFERRAL', 'TERM', t.raw_type) AS policy_type
  FROM typed t
),
dated AS (
  SELECT f.*,
    RAW.RND_INT('pterm|' || f.k, 1, IFF(f.policy_type IN ('TERM','ULIP'), 20, 1)) AS term_years,
    DATEADD(day, -RAW.RND_INT('pstart|' || f.k, 40,
                              LEAST(3600, GREATEST(400, f.TENURE_MONTHS * 30))),
            RAW.AS_OF()) AS start_date
  FROM final_type f
),
renewed AS (
  SELECT d.*,
    CASE
      -- forced: renewal lands 3-30 days out for the retention cohort's slot 1
      WHEN d.SEGMENT_CODE = 'RETENTION_SAVE' AND d.slot = 1
        THEN DATEADD(day, RAW.RND_INT('pren|' || d.k, 3, 30), RAW.AS_OF())
      -- everyone else: next anniversary of the start date, naturally spread
      ELSE DATEADD(year,
             CEIL(DATEDIFF(day, d.start_date, RAW.AS_OF()) / 365.0)::INT,
             d.start_date)
    END AS renewal_date
  FROM dated d
)
SELECT
  ROW_NUMBER() OVER (ORDER BY r.CUSTOMER_ID, r.slot)                  AS policy_id,
  'POL-' || LPAD(ROW_NUMBER() OVER (ORDER BY r.CUSTOMER_ID, r.slot)::VARCHAR, 8, '0')
                                                                      AS policy_number,
  r.CUSTOMER_ID,
  CASE r.policy_type
    WHEN 'MOTOR'  THEN 'INS_MOTOR_COMP'
    WHEN 'HEALTH' THEN IFF(RAW.RND_BOOL('pfam|' || r.k, 0.4), 'INS_HEALTH_FAM', 'INS_HEALTH_IND')
    WHEN 'TERM'   THEN IFF(RAW.RND_BOOL('prop|' || r.k, 0.3), 'INS_TERM_ROP', 'INS_TERM_PLAIN')
    WHEN 'HOME'   THEN IFF(RAW.RND_BOOL('phome|' || r.k, 0.5), 'INS_HOME_LOAN_LINKED', 'INS_HOME_STRUCT')
    ELSE               IFF(RAW.RND_BOOL('pulip|' || r.k, 0.35), 'INS_ULIP_EQ', 'INS_ULIP_BAL')
  END                                                                 AS product_code,
  r.policy_type,
  ROUND(RAW.RND_NORM_CLAMP('ppre|' || r.k,
    CASE r.policy_type
      WHEN 'MOTOR' THEN 16000 WHEN 'HEALTH' THEN 30000 WHEN 'TERM' THEN 24000
      WHEN 'HOME'  THEN 12000 ELSE 90000 END
    * (0.6 + 0.22 * r.INCOME_BAND_RANK),
    CASE r.policy_type WHEN 'ULIP' THEN 30000 ELSE 7000 END,
    3000, 600000), -2)                                                AS premium_inr,
  CASE
    WHEN r.policy_type IN ('TERM','ULIP')
      THEN RAW.RND_PICK('pfreq|' || r.k, ARRAY_CONSTRUCT('MONTHLY','QUARTERLY','ANNUAL'))
    ELSE 'ANNUAL'
  END                                                                 AS premium_frequency,
  ROUND(RAW.RND_NORM_CLAMP('psa|' || r.k,
    CASE r.policy_type
      WHEN 'MOTOR' THEN 700000 WHEN 'HEALTH' THEN 900000 WHEN 'TERM' THEN 9000000
      WHEN 'HOME'  THEN 4000000 ELSE 1800000 END
    * (0.5 + 0.25 * r.INCOME_BAND_RANK),
    500000, 100000, 60000000), -3)                                    AS sum_assured_inr,
  r.start_date,
  r.renewal_date,
  -- Planted cohorts hold an ACTIVE policy; noise cohorts may lapse or surrender.
  CASE
    WHEN r.SEGMENT_CODE = 'RETENTION_SAVE' AND r.slot = 1 THEN 'ACTIVE'
    WHEN r.slot = 0                                       THEN 'ACTIVE'
    WHEN RAW.RND('pst|' || r.k) < 0.84                    THEN 'ACTIVE'
    WHEN RAW.RND('pst|' || r.k) < 0.94                    THEN 'LAPSED'
    WHEN RAW.RND('pst|' || r.k) < 0.98                    THEN 'SURRENDERED'
    ELSE 'MATURED'
  END                                                                 AS status,
  CASE
    WHEN r.SEGMENT_CODE = 'RETENTION_SAVE' AND r.slot = 1 THEN FALSE
    WHEN r.slot = 0                                       THEN FALSE
    ELSE (RAW.RND('pst|' || r.k) >= 0.84 AND RAW.RND('pst|' || r.k) < 0.94)
  END                                                                 AS lapse_flag,
  RAW.RND_PICK('pch|' || r.k,
    ARRAY_CONSTRUCT('AGENT','BANCA','DIGITAL','BROKER','TELE'))        AS channel_sold,
  'AGT-' || LPAD(RAW.RND_INT('pag|' || r.k, 1, 850)::VARCHAR, 5, '0') AS agent_id,
  CURRENT_TIMESTAMP()                                                 AS load_ts
FROM renewed r;

/* ============================================================================
   STEP 7 — LOAN
   ----------------------------------------------------------------------------
   HAS_HOME_LOAN repeats the expression used in step 6, so the two silos agree
   about who holds a home loan.

   DPD is engineered so that rising DPD cannot occur outside
   COLLECTIONS_HARDSHIP:

     COLLECTIONS_HARDSHIP -> DPD_DAYS_M2 < DPD_DAYS_M1 < DPD_DAYS, current
                             35-85 days, i.e. bucket 31-60 or 61-90.
     everyone else        -> DPD_DAYS_M1 >= DPD_DAYS and DPD_DAYS_M2 >=
                             DPD_DAYS_M1, so the chain is non-increasing by
                             construction and the rising predicate cannot fire.
                             Current DPD is capped at 30 days.
   ============================================================================ */

TRUNCATE TABLE RAW.LOAN;

INSERT INTO RAW.LOAN
WITH cust AS (
  SELECT c.CUSTOMER_ID, c.AGE_YEARS, c.INCOME_BAND_RANK, c.ANNUAL_INCOME_INR, c.TENURE_MONTHS,
         t.SEGMENT_CODE, t.IS_VULNERABLE_CROSSSELL,
         (t.SEGMENT_CODE = 'PROTECTION_GAP'
          OR RAW.RND_BOOL('homeloan|' || c.CUSTOMER_ID, 0.14)) AS has_home_loan
  FROM RAW.CUSTOMER c
  JOIN RAW.CUSTOMER_SEGMENT_TRUTH t ON t.CUSTOMER_ID = c.CUSTOMER_ID
),
grid AS (
  -- slot 0 = home, slot 1 = auto, slot 2 = personal
  SELECT c.*, s.slot, 'l|' || c.CUSTOMER_ID || '|' || s.slot AS k,
         CASE s.slot WHEN 0 THEN 'HOME' WHEN 1 THEN 'AUTO' ELSE 'PERSONAL' END AS loan_type
  FROM cust c
  CROSS JOIN (SELECT SEQ8() AS slot FROM TABLE(GENERATOR(ROWCOUNT => 3))) s
  WHERE (s.slot = 0 AND c.has_home_loan)
     OR (s.slot = 1 AND RAW.RND_BOOL('autoloan|' || c.CUSTOMER_ID, 0.20))
     OR (s.slot = 2 AND (RAW.RND_BOOL('persloan|' || c.CUSTOMER_ID, 0.22)
                         -- collections needs at least one loan to be in arrears on
                         OR c.SEGMENT_CODE = 'COLLECTIONS_HARDSHIP'))
),
sized AS (
  SELECT g.*,
    -- loan term, distinct from CUSTOMER.TENURE_MONTHS (relationship tenure)
    CASE g.loan_type WHEN 'HOME' THEN 240 WHEN 'AUTO' THEN 60 ELSE 48 END AS loan_tenure_months,
    ROUND(RAW.RND_NORM_CLAMP('lprin|' || g.k,
      CASE g.loan_type
        WHEN 'HOME'     THEN 4200000 * (0.55 + 0.20 * g.INCOME_BAND_RANK)
        WHEN 'AUTO'     THEN  800000 * (0.60 + 0.18 * g.INCOME_BAND_RANK)
        ELSE                  400000 * (0.60 + 0.18 * g.INCOME_BAND_RANK)
      END,
      CASE g.loan_type WHEN 'HOME' THEN 900000 WHEN 'AUTO' THEN 180000 ELSE 110000 END,
      100000, 25000000), -3)                                             AS principal_inr,
    ROUND(RAW.RND_NORM_CLAMP('lrate|' || g.k,
      CASE g.loan_type WHEN 'HOME' THEN 8.6 WHEN 'AUTO' THEN 10.2 ELSE 14.5 END,
      CASE g.loan_type WHEN 'HOME' THEN 0.7 WHEN 'AUTO' THEN 1.1 ELSE 2.2 END,
      7.2, 22.0), 2)                                                     AS interest_rate_pct
  FROM grid g
),
elapsed AS (
  SELECT s.*,
    -- months into the loan: bounded by the loan term and by how long the
    -- customer has been on the books.
    -- COLLECTIONS_HARDSHIP is floored at 6 months because step 11 forces
    -- missed instalments 1 and 3 months back, and those rows only exist if
    -- the loan is old enough to have them. At a 3-month floor, a handful of
    -- collections customers ended up with a single missed instalment and fell
    -- out of their own segment.
    LEAST(s.loan_tenure_months - 1,
          GREATEST(IFF(s.SEGMENT_CODE = 'COLLECTIONS_HARDSHIP', 6, 3),
                   RAW.RND_INT('lelap|' || s.k, 3,
                      LEAST(s.loan_tenure_months - 1,
                            GREATEST(4, s.TENURE_MONTHS))))) AS months_elapsed
  FROM sized s
),
dpd AS (
  SELECT e.*,
    -- current DPD
    CASE
      WHEN e.SEGMENT_CODE = 'COLLECTIONS_HARDSHIP' THEN RAW.RND_INT('ldpd|' || e.k, 35, 85)
      WHEN e.SEGMENT_CODE IN ('LIMIT_INCREASE','PROTECTION_GAP','RETENTION_SAVE','WEALTH_REFERRAL')
        THEN 0
      WHEN e.IS_VULNERABLE_CROSSSELL              THEN 0
      WHEN RAW.RND_BOOL('ldpd0|' || e.k, 0.86)    THEN 0
      ELSE RAW.RND_INT('ldpd|' || e.k, 1, 30)
    END AS dpd_days
  FROM elapsed e
),
dpd_hist AS (
  SELECT d.*,
    CASE
      -- strictly rising: M2 < M1 < current
      WHEN d.SEGMENT_CODE = 'COLLECTIONS_HARDSHIP'
        THEN GREATEST(1, d.dpd_days - RAW.RND_INT('ld1|' || d.k, 12, 28))
      -- non-increasing by construction, so "rising" cannot fire
      ELSE d.dpd_days + RAW.RND_INT('ld1|' || d.k, 0, 6)
    END AS dpd_days_m1
  FROM dpd d
),
dpd_full AS (
  SELECT h.*,
    CASE
      WHEN h.SEGMENT_CODE = 'COLLECTIONS_HARDSHIP'
        THEN GREATEST(0, h.dpd_days_m1 - RAW.RND_INT('ld2|' || h.k, 8, 20))
      ELSE h.dpd_days_m1 + RAW.RND_INT('ld2|' || h.k, 0, 6)
    END AS dpd_days_m2
  FROM dpd_hist h
)
SELECT
  ROW_NUMBER() OVER (ORDER BY f.CUSTOMER_ID, f.slot)                        AS loan_id,
  'LN-' || LPAD(ROW_NUMBER() OVER (ORDER BY f.CUSTOMER_ID, f.slot)::VARCHAR, 9, '0')
                                                                            AS loan_account_no,
  f.CUSTOMER_ID,
  CASE f.loan_type WHEN 'HOME' THEN 'BNK_LOAN_HOME'
                   WHEN 'AUTO' THEN 'BNK_LOAN_AUTO'
                   ELSE 'BNK_LOAN_PERS' END                                 AS product_code,
  f.loan_type,
  f.principal_inr,
  f.interest_rate_pct,
  -- standard amortised EMI:  P * r * (1+r)^n / ((1+r)^n - 1),  r = monthly rate
  ROUND(
    f.principal_inr * (f.interest_rate_pct / 1200.0)
    * POWER(1 + f.interest_rate_pct / 1200.0, f.loan_tenure_months)
    / (POWER(1 + f.interest_rate_pct / 1200.0, f.loan_tenure_months) - 1)
  , 0)                                                                      AS emi_inr,
  f.loan_tenure_months                                                      AS tenure_months,
  f.months_elapsed,
  -- outstanding declines with elapsed term; arrears cases pay down slower
  ROUND(f.principal_inr
        * (1 - (f.months_elapsed / f.loan_tenure_months::FLOAT)
               * IFF(f.SEGMENT_CODE = 'COLLECTIONS_HARDSHIP', 0.62, 0.86)), -2)
                                                                            AS outstanding_inr,
  DATEADD(month, -f.months_elapsed, RAW.AS_OF())                            AS disbursal_date,
  DATEADD(month, -f.months_elapsed + 1, RAW.AS_OF())                        AS first_emi_date,
  f.dpd_days,
  f.dpd_days_m1,
  f.dpd_days_m2,
  CASE
    WHEN f.dpd_days = 0  THEN '0'
    WHEN f.dpd_days <= 30 THEN '1-30'
    WHEN f.dpd_days <= 60 THEN '31-60'
    WHEN f.dpd_days <= 90 THEN '61-90'
    ELSE '90+'
  END                                                                       AS dpd_bucket,
  IFF(f.SEGMENT_CODE = 'COLLECTIONS_HARDSHIP',
      RAW.RND_BOOL('lres|' || f.k, 0.25),
      RAW.RND_BOOL('lres|' || f.k, 0.02))                                   AS restructure_flag,
  'ACTIVE'                                                                  AS status,
  CURRENT_TIMESTAMP()                                                       AS load_ts
FROM dpd_full f;

/* ============================================================================
   STEP 8 — CARD
   ----------------------------------------------------------------------------
   Rising utilisation is the LIMIT_INCREASE signal, so it is made impossible
   elsewhere:

     LIMIT_INCREASE -> M3 < M2 < M1 < current, current in 55-85%.
     everyone else  -> M1 is set ABOVE current, which breaks the chain at its
                       last link no matter what M2 and M3 do. Utilisation still
                       varies realistically month to month; it just never
                       climbs monotonically for four straight readings.
   ============================================================================ */

TRUNCATE TABLE RAW.CARD;

INSERT INTO RAW.CARD
WITH cust AS (
  SELECT c.CUSTOMER_ID, c.AGE_YEARS, c.INCOME_BAND_RANK, c.ANNUAL_INCOME_INR,
         t.SEGMENT_CODE, t.IS_VULNERABLE_CROSSSELL,
         'cd|' || c.CUSTOMER_ID AS k
  FROM RAW.CUSTOMER c
  JOIN RAW.CUSTOMER_SEGMENT_TRUTH t ON t.CUSTOMER_ID = c.CUSTOMER_ID
  WHERE t.SEGMENT_CODE = 'LIMIT_INCREASE'                        -- forced
     OR RAW.RND_BOOL('hascard|' || c.CUSTOMER_ID, 0.52)
),
util AS (
  SELECT cu.*,
    CASE
      WHEN cu.SEGMENT_CODE = 'LIMIT_INCREASE'
        THEN ROUND(RAW.RND_NORM_CLAMP('cu|' || cu.k, 72, 8, 55, 85), 2)
      ELSE ROUND(RAW.RND_NORM_CLAMP('cu|' || cu.k, 34, 18, 1, 92), 2)
    END AS u_now
  FROM cust cu
),
util_hist AS (
  SELECT u.*,
    CASE
      WHEN u.SEGMENT_CODE = 'LIMIT_INCREASE'
        THEN ROUND(u.u_now - RAW.RND_NORM_CLAMP('cu1|' || u.k, 9, 3, 4, 16), 2)
      -- above current: the rising chain is broken here for everyone else
      ELSE ROUND(LEAST(97, u.u_now + RAW.RND_NORM_CLAMP('cu1|' || u.k, 8, 4, 2, 18)), 2)
    END AS u_m1
  FROM util u
),
util_full AS (
  SELECT h.*,
    CASE
      WHEN h.SEGMENT_CODE = 'LIMIT_INCREASE'
        THEN ROUND(GREATEST(2, h.u_m1 - RAW.RND_NORM_CLAMP('cu2|' || h.k, 9, 3, 4, 16)), 2)
      ELSE ROUND(GREATEST(1, h.u_m1 - RAW.RND_NORM_CLAMP('cu2|' || h.k, 6, 5, 0, 20)), 2)
    END AS u_m2
  FROM util_hist h
),
util_final AS (
  SELECT f.*,
    CASE
      WHEN f.SEGMENT_CODE = 'LIMIT_INCREASE'
        THEN ROUND(GREATEST(1, f.u_m2 - RAW.RND_NORM_CLAMP('cu3|' || f.k, 9, 3, 4, 16)), 2)
      ELSE ROUND(GREATEST(1, LEAST(95, f.u_m2 + RAW.RND_NORM_CLAMP('cu3|' || f.k, 0, 9, -22, 22))), 2)
    END AS u_m3
  FROM util_full f
),
limited AS (
  SELECT uf.*,
    ROUND(RAW.RND_NORM_CLAMP('clim|' || uf.k,
      GREATEST(50000, uf.ANNUAL_INCOME_INR * 0.28),
      GREATEST(20000, uf.ANNUAL_INCOME_INR * 0.09),
      40000, 3500000), -3) AS credit_limit_inr
  FROM util_final uf
)
SELECT
  ROW_NUMBER() OVER (ORDER BY l.CUSTOMER_ID)                                AS card_id,
  'XXXX-XXXX-XXXX-' || LPAD(RAW.RND_INT('cmask|' || l.k, 0, 9999)::VARCHAR, 4, '0')
                                                                            AS card_number_masked,
  l.CUSTOMER_ID,
  IFF(l.INCOME_BAND_RANK >= 4, 'BNK_CARD_PLAT', 'BNK_CARD_GOLD')            AS product_code,
  CASE
    WHEN l.INCOME_BAND_RANK = 5 THEN 'SIGNATURE'
    WHEN l.INCOME_BAND_RANK = 4 THEN 'PLATINUM'
    WHEN l.INCOME_BAND_RANK = 3 THEN 'GOLD'
    ELSE 'CLASSIC'
  END                                                                       AS card_tier,
  l.credit_limit_inr,
  ROUND(l.credit_limit_inr * l.u_now / 100.0, 0)                            AS current_balance_inr,
  l.u_now, l.u_m1, l.u_m2, l.u_m3,
  OBJECT_CONSTRUCT(
    'GROCERY',   RAW.RND_INT('mg|' || l.k, 10, 34),
    'FUEL',      RAW.RND_INT('mf|' || l.k,  5, 22),
    'ECOMMERCE', RAW.RND_INT('me|' || l.k, 12, 38),
    'DINING',    RAW.RND_INT('md|' || l.k,  4, 18),
    'TRAVEL',    RAW.RND_INT('mt|' || l.k,  2, 20)
  )                                                                         AS mcc_mix,
  RAW.RND_PICK('mtop|' || l.k,
    ARRAY_CONSTRUCT('GROCERY','ECOMMERCE','FUEL','DINING','TRAVEL'))        AS top_mcc_group,
  DATEADD(day, -RAW.RND_INT('cissue|' || l.k, 200, 2400), RAW.AS_OF())      AS issued_date,
  IFF(RAW.RND_BOOL('cstat|' || l.k, 0.96)
      OR l.SEGMENT_CODE = 'LIMIT_INCREASE', 'ACTIVE',
      IFF(RAW.RND_BOOL('cstat2|' || l.k, 0.6), 'BLOCKED', 'CLOSED'))        AS status,
  CURRENT_TIMESTAMP()                                                       AS load_ts
FROM limited l;

/* ============================================================================
   STEP 9 — CLAIM
   ----------------------------------------------------------------------------
   Roughly a quarter of policies carry a claim, weighted towards MOTOR and
   HEALTH. Settlement days are only populated for SETTLED claims.
   ============================================================================ */

TRUNCATE TABLE RAW.CLAIM;

INSERT INTO RAW.CLAIM
WITH cand AS (
  SELECT p.POLICY_ID, p.CUSTOMER_ID, p.POLICY_TYPE, p.SUM_ASSURED_INR, p.START_DATE,
         'cl|' || p.POLICY_ID AS k
  FROM RAW.POLICY p
  WHERE p.STATUS IN ('ACTIVE','LAPSED')
    AND RAW.RND_BOOL('hasclaim|' || p.POLICY_ID,
          CASE p.POLICY_TYPE
            WHEN 'MOTOR' THEN 0.34 WHEN 'HEALTH' THEN 0.30
            WHEN 'HOME'  THEN 0.12 WHEN 'TERM'   THEN 0.03 ELSE 0.05 END)
),
filed AS (
  SELECT c.*,
    DATEADD(day, -RAW.RND_INT('clf|' || c.k, 20, 700),
            CURRENT_TIMESTAMP()::TIMESTAMP_NTZ) AS filed_at,
    CASE
      WHEN RAW.RND('clst|' || c.k) < 0.68 THEN 'SETTLED'
      WHEN RAW.RND('clst|' || c.k) < 0.80 THEN 'REJECTED'
      WHEN RAW.RND('clst|' || c.k) < 0.92 THEN 'IN_REVIEW'
      ELSE 'OPEN'
    END AS status,
    ROUND(RAW.RND_NORM_CLAMP('clamt|' || c.k,
      c.SUM_ASSURED_INR * 0.10, c.SUM_ASSURED_INR * 0.07,
      5000, c.SUM_ASSURED_INR), -2) AS claim_amount_inr,
    RAW.RND_INT('cldays|' || c.k, 4, 95) AS settlement_days
  FROM cand c
)
SELECT
  ROW_NUMBER() OVER (ORDER BY f.POLICY_ID)                                  AS claim_id,
  'CLM-' || LPAD(ROW_NUMBER() OVER (ORDER BY f.POLICY_ID)::VARCHAR, 8, '0') AS claim_number,
  f.POLICY_ID,
  f.CUSTOMER_ID,
  CASE f.POLICY_TYPE
    WHEN 'MOTOR'  THEN RAW.RND_PICK('clt|' || f.k, ARRAY_CONSTRUCT('OWN_DAMAGE','THIRD_PARTY','THEFT'))
    WHEN 'HEALTH' THEN RAW.RND_PICK('clt|' || f.k, ARRAY_CONSTRUCT('CASHLESS','REIMBURSEMENT','DAY_CARE'))
    WHEN 'HOME'   THEN RAW.RND_PICK('clt|' || f.k, ARRAY_CONSTRUCT('FIRE','FLOOD','BURGLARY'))
    WHEN 'TERM'   THEN 'DEATH_BENEFIT'
    ELSE 'PARTIAL_WITHDRAWAL'
  END                                                                       AS claim_type,
  f.claim_amount_inr,
  CASE
    WHEN f.status = 'SETTLED'  THEN ROUND(f.claim_amount_inr
                                         * RAW.RND_NORM_CLAMP('clap|' || f.k, 0.92, 0.09, 0.45, 1.0), -2)
    WHEN f.status = 'REJECTED' THEN 0
    ELSE NULL
  END                                                                       AS approved_amount_inr,
  f.status,
  f.filed_at,
  IFF(f.status IN ('SETTLED','REJECTED'),
      DATEADD(day, f.settlement_days, f.filed_at), NULL)                    AS settled_at,
  IFF(f.status IN ('SETTLED','REJECTED'), f.settlement_days, NULL)          AS settlement_days,
  CURRENT_TIMESTAMP()                                                       AS load_ts
FROM filed f;

/* ============================================================================
   STEP 10 — TXN
   ----------------------------------------------------------------------------
   12 rolling months, 120-360 transactions per customer.

   Credit amounts are hard-clamped below 10 lakh for everyone, so the only
   inbound credits at or above that threshold are the ones injected for
   WEALTH_REFERRAL in the second statement below. That makes the lumpsum
   predicate exact.
   ============================================================================ */

TRUNCATE TABLE RAW.TXN;

INSERT INTO RAW.TXN
WITH mcc_ref AS (
  SELECT $1::INT AS idx, $2::VARCHAR AS mcc, $3::VARCHAR AS grp,
         $4::FLOAT AS mean_amt, $5::FLOAT AS sd_amt FROM VALUES
    (0,'5411','GROCERY',       1850,   900),
    (1,'5541','FUEL',          2400,  1100),
    (2,'5812','DINING',        1200,   800),
    (3,'5999','ECOMMERCE',     2900,  2200),
    (4,'4111','TRANSPORT',      420,   260),
    (5,'4900','UTILITIES',     2100,  1200),
    (6,'8062','HEALTHCARE',    4800,  3900),
    (7,'4722','TRAVEL',       12500,  9000),
    (8,'5912','PHARMACY',       780,   520),
    (9,'6011','ATM_CASH',      5000,  3000),
    (10,'5651','APPAREL',      2600,  1900),
    (11,'7995','ENTERTAINMENT', 950,   700)
),
cust AS (
  SELECT c.CUSTOMER_ID, c.CITY, c.ANNUAL_INCOME_INR,
         t.SEGMENT_CODE,
         (t.SEGMENT_CODE = 'LIMIT_INCREASE'
          OR RAW.RND_BOOL('hascard|' || c.CUSTOMER_ID, 0.52))  AS has_card,
         RAW.RND_INT('ntxn|' || c.CUSTOMER_ID, 120, 360)       AS n_txn
  FROM RAW.CUSTOMER c
  JOIN RAW.CUSTOMER_SEGMENT_TRUTH t ON t.CUSTOMER_ID = c.CUSTOMER_ID
),
grid AS (
  SELECT c.*, s.slot, 'tx|' || c.CUSTOMER_ID || '|' || s.slot AS k
  FROM cust c
  CROSS JOIN (SELECT SEQ8() + 1 AS slot FROM TABLE(GENERATOR(ROWCOUNT => 360))) s
  WHERE s.slot <= c.n_txn
),
shaped AS (
  SELECT g.*,
    RAW.RND_INT('mcci|' || g.k, 0, 11)                          AS mcc_idx,
    -- ~11% of transactions are inbound credits
    RAW.RND_BOOL('tdir|' || g.k, 0.11)                          AS is_credit,
    RAW.RND_INT('tday|' || g.k, 0, 364)                         AS days_ago,
    RAW.RND_INT('tsec|' || g.k, 25200, 79200)                   AS sec_of_day
  FROM grid g
)
SELECT
  ROW_NUMBER() OVER (ORDER BY s.CUSTOMER_ID, s.slot)                        AS txn_id,
  s.CUSTOMER_ID,
  IFF(s.has_card AND NOT s.is_credit AND RAW.RND_BOOL('tacc|' || s.k, 0.45),
      'CARD', 'SAVINGS')                                                    AS account_type,
  NULL                                                                      AS card_id,
  DATEADD(second, s.sec_of_day,
    DATEADD(day, -s.days_ago, RAW.AS_OF())::TIMESTAMP_NTZ)                  AS txn_ts,
  DATEADD(day, -s.days_ago, RAW.AS_OF())                                    AS txn_date,
  IFF(s.is_credit, 'CREDIT', 'DEBIT')                                       AS direction,
  IFF(s.is_credit, '0000', m.mcc)                                           AS mcc,
  IFF(s.is_credit,
      IFF(RAW.RND_BOOL('tsal|' || s.k, 0.55), 'SALARY_CREDIT', 'INWARD_TRANSFER'),
      m.grp)                                                                AS mcc_group,
  -- Credits are clamped below 10 lakh. The only exceptions are the
  -- WEALTH_REFERRAL lumpsums injected by the next statement.
  CASE
    WHEN s.is_credit AND RAW.RND_BOOL('tsal|' || s.k, 0.55)
      THEN ROUND(RAW.RND_NORM_CLAMP('tamt|' || s.k,
             s.ANNUAL_INCOME_INR / 12.0, s.ANNUAL_INCOME_INR / 90.0,
             12000, 850000), 2)
    WHEN s.is_credit
      THEN ROUND(RAW.RND_NORM_CLAMP('tamt|' || s.k, 22000, 30000, 500, 850000), 2)
    ELSE ROUND(RAW.RND_NORM_CLAMP('tamt|' || s.k, m.mean_amt, m.sd_amt, 60, 400000), 2)
  END                                                                       AS amount_inr,
  CASE
    WHEN s.is_credit THEN RAW.RND_PICK('tchn|' || s.k, ARRAY_CONSTRUCT('NEFT','IMPS','UPI'))
    WHEN m.grp = 'ATM_CASH' THEN 'ATM'
    ELSE RAW.RND_PICK('tchn|' || s.k, ARRAY_CONSTRUCT('UPI','POS','ECOM','NEFT'))
  END                                                                       AS channel,
  IFF(s.is_credit, NULL,
      m.grp || '_MERCHANT_' || LPAD(RAW.RND_INT('tmer|' || s.k, 1, 400)::VARCHAR, 3, '0'))
                                                                            AS merchant_name,
  IFF(RAW.RND_BOOL('tcity|' || s.k, 0.88), s.CITY,
      RAW.RND_PICK('tcity2|' || s.k,
        ARRAY_CONSTRUCT('Mumbai','Delhi','Bengaluru','Chennai','Hyderabad','Pune')))
                                                                            AS city,
  FALSE                                                                     AS is_inbound_lumpsum,
  CURRENT_TIMESTAMP()                                                       AS load_ts
FROM shaped s
JOIN mcc_ref m ON m.idx = s.mcc_idx;

-- Planted lumpsums: one large inbound credit per WEALTH_REFERRAL customer,
-- 10-95 lakh, inside the last 90 days. The only credits in the table at or
-- above 10 lakh.
INSERT INTO RAW.TXN
WITH w AS (
  SELECT c.CUSTOMER_ID, c.CITY, 'wl|' || c.CUSTOMER_ID AS k
  FROM RAW.CUSTOMER c
  JOIN RAW.CUSTOMER_SEGMENT_TRUTH t ON t.CUSTOMER_ID = c.CUSTOMER_ID
  WHERE t.SEGMENT_CODE = 'WEALTH_REFERRAL'
),
mx AS (SELECT COALESCE(MAX(TXN_ID), 0) AS base_id FROM RAW.TXN)
SELECT
  mx.base_id + ROW_NUMBER() OVER (ORDER BY w.CUSTOMER_ID)                   AS txn_id,
  w.CUSTOMER_ID,
  'SAVINGS'                                                                 AS account_type,
  NULL                                                                      AS card_id,
  DATEADD(second, RAW.RND_INT('wsec|' || w.k, 32400, 64800),
    DATEADD(day, -RAW.RND_INT('wday|' || w.k, 5, 88), RAW.AS_OF())::TIMESTAMP_NTZ)
                                                                            AS txn_ts,
  DATEADD(day, -RAW.RND_INT('wday|' || w.k, 5, 88), RAW.AS_OF())            AS txn_date,
  'CREDIT'                                                                  AS direction,
  '0000'                                                                    AS mcc,
  RAW.RND_PICK('wgrp|' || w.k,
    ARRAY_CONSTRUCT('MATURITY_PROCEEDS','PROPERTY_SALE','ESOP_LIQUIDATION',
                    'INHERITANCE','BONUS_PAYOUT'))                          AS mcc_group,
  ROUND(RAW.RND_NORM_CLAMP('wamt|' || w.k, 3200000, 1900000, 1000000, 9500000), -3)
                                                                            AS amount_inr,
  RAW.RND_PICK('wchn|' || w.k, ARRAY_CONSTRUCT('RTGS','NEFT'))              AS channel,
  NULL                                                                      AS merchant_name,
  w.CITY                                                                    AS city,
  TRUE                                                                      AS is_inbound_lumpsum,
  CURRENT_TIMESTAMP()                                                       AS load_ts
FROM w CROSS JOIN mx;

-- Attach CARD_ID to card transactions for customers who hold a card.
UPDATE RAW.TXN t
SET CARD_ID = c.CARD_ID
FROM RAW.CARD c
WHERE c.CUSTOMER_ID = t.CUSTOMER_ID
  AND t.ACCOUNT_TYPE = 'CARD';

/* ============================================================================
   STEP 11 — REPAYMENT
   ----------------------------------------------------------------------------
   Trailing 12 instalments per active loan, and per active policy according to
   premium frequency.

   The "2+ missed" predicate is at CUSTOMER grain, so a customer with two
   loans could accumulate two missed instalments by chance and land in the
   segment without being planted there. To prevent that, missed instalments
   outside COLLECTIONS_HARDSHIP are capped at exactly one per customer across
   their whole book, using a candidate ranking (cand_rn = 1).

     COLLECTIONS_HARDSHIP -> instalments 1 and 3 months back are forced missed
                             on every loan, so the count is always >= 2.
     LIMIT_INCREASE       -> perfectly clean: no late, no missed. That is the
                             other half of the limit-increase signal.
     everyone else        -> late payments freely; at most one missed.
   ============================================================================ */

TRUNCATE TABLE RAW.REPAYMENT;

INSERT INTO RAW.REPAYMENT
WITH seg AS (
  SELECT CUSTOMER_ID, SEGMENT_CODE FROM RAW.CUSTOMER_SEGMENT_TRUTH
),
obligations AS (
  SELECT l.CUSTOMER_ID, 'LOAN_EMI' AS obligation_type, l.LOAN_ID AS obligation_id,
         l.EMI_INR AS due_amount, 1 AS month_step,
         LEAST(12, GREATEST(1, l.MONTHS_ELAPSED)) AS n_inst,
         DAY(l.FIRST_EMI_DATE) AS due_day
  FROM RAW.LOAN l
  WHERE l.STATUS = 'ACTIVE'
  UNION ALL
  SELECT p.CUSTOMER_ID, 'POLICY_PREMIUM', p.POLICY_ID,
         p.PREMIUM_INR,
         CASE p.PREMIUM_FREQUENCY WHEN 'MONTHLY' THEN 1 WHEN 'QUARTERLY' THEN 3 ELSE 12 END,
         CASE p.PREMIUM_FREQUENCY WHEN 'MONTHLY' THEN 12 WHEN 'QUARTERLY' THEN 4 ELSE 1 END,
         DAY(p.START_DATE)
  FROM RAW.POLICY p
  WHERE p.STATUS = 'ACTIVE'
),
inst AS (
  SELECT o.*, g.n AS instalment_no,
         s.SEGMENT_CODE,
         'rp|' || o.obligation_type || '|' || o.obligation_id || '|' || g.n AS k,
         -- months back from today; instalment 1 is the most recent
         (g.n - 1) * o.month_step AS months_back
  FROM obligations o
  JOIN seg s ON s.CUSTOMER_ID = o.CUSTOMER_ID
  CROSS JOIN (SELECT SEQ8() + 1 AS n FROM TABLE(GENERATOR(ROWCOUNT => 12))) g
  WHERE g.n <= o.n_inst
),
dated AS (
  SELECT i.*,
    DATEADD(day, LEAST(i.due_day, 28) - 1,
      DATE_TRUNC('month', DATEADD(month, -i.months_back, RAW.AS_OF()))) AS due_date
  FROM inst i
),
marked AS (
  SELECT d.*,
    -- forced missed for the collections cohort: 1 and 3 months back
    (d.SEGMENT_CODE = 'COLLECTIONS_HARDSHIP'
     AND d.obligation_type = 'LOAN_EMI'
     AND d.months_back IN (1, 3))                                   AS forced_missed,
    -- candidate missed for everyone else, capped to one per customer below
    (d.SEGMENT_CODE NOT IN ('COLLECTIONS_HARDSHIP','LIMIT_INCREASE')
     AND RAW.RND_BOOL('rmiss|' || d.k, 0.030))                      AS cand_missed
  FROM dated d
),
capped AS (
  SELECT m.*,
    ROW_NUMBER() OVER (PARTITION BY m.CUSTOMER_ID
                       ORDER BY IFF(m.cand_missed, 0, 1), m.due_date, m.obligation_id)
      AS cand_rn
  FROM marked m
),
resolved AS (
  SELECT c.*,
    (c.forced_missed OR (c.cand_missed AND c.cand_rn = 1)) AS missed_flag,
    CASE
      WHEN c.SEGMENT_CODE = 'LIMIT_INCREASE'                      THEN 0
      WHEN c.SEGMENT_CODE = 'COLLECTIONS_HARDSHIP'
        THEN RAW.RND_INT('rlate|' || c.k, 0, 40)
      WHEN RAW.RND_BOOL('rlate0|' || c.k, 0.09)
        THEN RAW.RND_INT('rlate|' || c.k, 1, 14)
      ELSE 0
    END AS days_late_raw
  FROM capped c
)
SELECT
  ROW_NUMBER() OVER (ORDER BY r.CUSTOMER_ID, r.obligation_id, r.instalment_no) AS repayment_id,
  r.CUSTOMER_ID,
  r.obligation_type,
  r.obligation_id,
  r.instalment_no,
  r.due_date,
  ROUND(r.due_amount, 0)                                                  AS due_amount_inr,
  IFF(r.missed_flag, NULL, DATEADD(day, r.days_late_raw, r.due_date))     AS paid_date,
  IFF(r.missed_flag, NULL, ROUND(r.due_amount, 0))                       AS paid_amount_inr,
  IFF(r.missed_flag, 0, r.days_late_raw)                                 AS days_late,
  (NOT r.missed_flag AND r.days_late_raw > 0)                            AS late_flag,
  r.missed_flag,
  IFF(r.missed_flag, NULL,
      RAW.RND_PICK('rmode|' || r.k,
        ARRAY_CONSTRUCT('NACH','UPI','NETBANKING','CHEQUE','CASH')))      AS payment_mode,
  CURRENT_TIMESTAMP()                                                     AS load_ts
FROM resolved r;

/* ============================================================================
   STEP 12 — SERVICE_TICKET
   ----------------------------------------------------------------------------
   This is where the retention segment is completed and protected.

   The predicate is "renewal inside 30 days AND a complaint in the last 60
   days". Renewals inside 30 days occur naturally for ordinary customers
   (roughly 1 in 12 policies), so the complaint half is what has to be
   controlled:

     RETENTION_SAVE                    -> forced complaint 3-58 days old,
                                          severity 3-4, still open, on the
                                          renewing policy.
     near-renewal but NOT retention    -> complaints are pushed to 61-400 days
                                          old, so the 60-day window is empty
                                          and the pair cannot fire.
     no near-renewal                   -> complaints anywhere in the year.

   That leaves a population of customers who genuinely renew soon and have an
   older complaint. They are the near-misses that make the demo credible.
   ============================================================================ */

TRUNCATE TABLE RAW.SERVICE_TICKET;

INSERT INTO RAW.SERVICE_TICKET
WITH near_renewal AS (
  SELECT CUSTOMER_ID,
         MIN(POLICY_ID) AS renewing_policy_id,
         TRUE           AS has_near_renewal
  FROM RAW.POLICY
  WHERE STATUS = 'ACTIVE'
    AND RENEWAL_DATE BETWEEN RAW.AS_OF() AND DATEADD(day, 30, RAW.AS_OF())
  GROUP BY CUSTOMER_ID
),
cust AS (
  SELECT c.CUSTOMER_ID, t.SEGMENT_CODE, t.IS_VULNERABLE_CROSSSELL,
         COALESCE(nr.has_near_renewal, FALSE) AS has_near_renewal,
         nr.renewing_policy_id,
         CASE
           WHEN t.SEGMENT_CODE = 'RETENTION_SAVE'       THEN 1 + RAW.RND_INT('ntk|' || c.CUSTOMER_ID, 0, 3)
           WHEN t.SEGMENT_CODE = 'COLLECTIONS_HARDSHIP' THEN 1 + RAW.RND_INT('ntk|' || c.CUSTOMER_ID, 0, 3)
           ELSE RAW.RND_INT('ntk|' || c.CUSTOMER_ID, 0, 3)
         END AS n_tickets
  FROM RAW.CUSTOMER c
  JOIN RAW.CUSTOMER_SEGMENT_TRUTH t ON t.CUSTOMER_ID = c.CUSTOMER_ID
  LEFT JOIN near_renewal nr ON nr.CUSTOMER_ID = c.CUSTOMER_ID
),
grid AS (
  SELECT cu.*, s.slot, 'tk|' || cu.CUSTOMER_ID || '|' || s.slot AS k
  FROM cust cu
  CROSS JOIN (SELECT SEQ8() AS slot FROM TABLE(GENERATOR(ROWCOUNT => 5))) s
  WHERE (s.slot = 0 AND cu.SEGMENT_CODE = 'RETENTION_SAVE')   -- the planted complaint
     OR (s.slot >= 1 AND s.slot <= cu.n_tickets)
),
shaped AS (
  SELECT g.*,
    (g.slot = 0) AS is_planted,
    CASE
      WHEN g.slot = 0 THEN TRUE
      ELSE RAW.RND_BOOL('tkcomp|' || g.k, 0.38)
    END AS is_complaint
  FROM grid g
),
aged AS (
  SELECT s.*,
    CASE
      -- planted: inside the 60-day window
      WHEN s.is_planted THEN RAW.RND_INT('tkage|' || s.k, 3, 58)
      -- protect the predicate: near-renewal non-retention complaints are old
      WHEN s.is_complaint AND s.has_near_renewal AND s.SEGMENT_CODE <> 'RETENTION_SAVE'
        THEN RAW.RND_INT('tkage|' || s.k, 61, 400)
      ELSE RAW.RND_INT('tkage|' || s.k, 1, 400)
    END AS days_ago
  FROM shaped s
)
SELECT
  ROW_NUMBER() OVER (ORDER BY a.CUSTOMER_ID, a.slot)                        AS ticket_id,
  'TKT-' || LPAD(ROW_NUMBER() OVER (ORDER BY a.CUSTOMER_ID, a.slot)::VARCHAR, 8, '0')
                                                                            AS ticket_number,
  a.CUSTOMER_ID,
  IFF(a.is_planted, 'POLICY',
      RAW.RND_PICK('tkobj|' || a.k, ARRAY_CONSTRUCT('POLICY','LOAN','CARD','NONE')))
                                                                            AS related_object_type,
  IFF(a.is_planted, a.renewing_policy_id, NULL)                             AS related_object_id,
  IFF(a.is_planted, 'CALL',
      RAW.RND_PICK('tkch|' || a.k, ARRAY_CONSTRUCT('CALL','EMAIL','BRANCH','APP','WHATSAPP')))
                                                                            AS channel,
  CASE
    WHEN a.is_planted THEN 'RENEWAL_PRICING'
    WHEN a.is_complaint
      THEN RAW.RND_PICK('tkcat|' || a.k,
             ARRAY_CONSTRUCT('CLAIM_DELAY','PREMIUM_INCREASE','MIS_SELLING',
                             'SERVICE_QUALITY','CHARGES_DISPUTE','COLLECTION_CONDUCT'))
    ELSE RAW.RND_PICK('tkcat|' || a.k,
             ARRAY_CONSTRUCT('ADDRESS_CHANGE','NOMINEE_UPDATE','STATEMENT_REQUEST',
                             'PRODUCT_ENQUIRY','LIMIT_ENQUIRY','KYC_UPDATE'))
  END                                                                       AS category,
  IFF(a.is_planted,
      RAW.RND_PICK('tksub|' || a.k,
        ARRAY_CONSTRUCT('RENEWAL_PREMIUM_TOO_HIGH','COMPETITOR_QUOTE_LOWER',
                        'NO_CLAIM_BONUS_NOT_APPLIED','LOADING_NOT_EXPLAINED')),
      RAW.RND_PICK('tksub|' || a.k,
        ARRAY_CONSTRUCT('FIRST_CONTACT','REPEAT_CONTACT','ESCALATED','ROUTINE')))
                                                                            AS sub_category,
  CASE
    WHEN a.is_planted        THEN RAW.RND_INT('tksev|' || a.k, 3, 4)
    WHEN a.is_complaint      THEN RAW.RND_INT('tksev|' || a.k, 2, 4)
    ELSE                          RAW.RND_INT('tksev|' || a.k, 1, 2)
  END                                                                       AS severity,
  a.is_complaint,
  CASE
    WHEN a.is_planted                              THEN 'OPEN'
    WHEN RAW.RND_BOOL('tkst|' || a.k, 0.74)        THEN 'CLOSED'
    WHEN RAW.RND_BOOL('tkst2|' || a.k, 0.55)       THEN 'RESOLVED'
    ELSE 'IN_PROGRESS'
  END                                                                       AS status,
  DATEADD(second, RAW.RND_INT('tksec|' || a.k, 28800, 68400),
    DATEADD(day, -a.days_ago, RAW.AS_OF())::TIMESTAMP_NTZ)                  AS opened_at,
  CASE
    WHEN a.is_planted THEN NULL
    WHEN RAW.RND_BOOL('tkst|' || a.k, 0.74)
      THEN DATEADD(hour, RAW.RND_INT('tkres|' || a.k, 2, 340),
             DATEADD(day, -a.days_ago, RAW.AS_OF())::TIMESTAMP_NTZ)
    ELSE NULL
  END                                                                       AS closed_at,
  IFF(a.is_planted, NULL,
      IFF(RAW.RND_BOOL('tkst|' || a.k, 0.74),
          RAW.RND_INT('tkres|' || a.k, 2, 340), NULL))                      AS resolution_hours,
  -- Short templated note. Rich free text and call audio arrive at M1/M3;
  -- this exists so retrieval and the enrichment layer have something to bind
  -- to, and so the planted complaint is visible in the evidence trail.
  CASE
    WHEN a.is_planted
      THEN 'Customer called about the upcoming renewal premium and said it is significantly '
        || 'higher than last year. Mentioned a cheaper quote elsewhere and asked what can be '
        || 'done before the renewal date. Tone escalated during the call.'
    WHEN a.is_complaint
      THEN 'Complaint logged. Customer dissatisfied with handling. Category recorded as noted; '
        || 'awaiting resolution per SLA.'
    ELSE 'Service request logged and actioned through the standard workflow.'
  END                                                                       AS note_text,
  CURRENT_TIMESTAMP()                                                       AS load_ts
FROM aged a;

/* ============================================================================
   STEP 13 — CAMPAIGN_HISTORY
   ----------------------------------------------------------------------------
   Outbound contact history over 18 months. Feeds the cooling-off compliance
   rule, so a deliberate slice of contacts lands inside the last 14 days.

   OPT_OUT and COMPLAINED outcomes are concentrated on the suppression overlay,
   giving the consent registry a corroborating audit trail rather than a flag
   that appears from nowhere.
   ============================================================================ */

TRUNCATE TABLE RAW.CAMPAIGN_HISTORY;

INSERT INTO RAW.CAMPAIGN_HISTORY
WITH campaigns AS (
  SELECT $1::INT AS idx, $2::VARCHAR AS campaign_id, $3::VARCHAR AS campaign_name,
         $4::VARCHAR AS product_code FROM VALUES
    (0,'CMP-2025-H1-MOTOR','Motor Renewal Push H1',            'INS_MOTOR_COMP'),
    (1,'CMP-2025-H1-HEALTH','Family Health Upgrade H1',        'INS_HEALTH_FAM'),
    (2,'CMP-2025-H2-TERM','Term Life Awareness H2',            'INS_TERM_PLAIN'),
    (3,'CMP-2025-H2-ULIP','Wealth ULIP Outreach H2',           'INS_ULIP_BAL'),
    (4,'CMP-2026-Q1-CARD','Platinum Card Upgrade Q1',          'BNK_CARD_PLAT'),
    (5,'CMP-2026-Q1-LIMIT','Pre-approved Limit Increase Q1',   'BNK_CARD_LIMIT_INC'),
    (6,'CMP-2026-Q1-PERS','Personal Loan Top-up Q1',           'BNK_LOAN_PERS'),
    (7,'CMP-2026-Q2-HOME','Home Cover Attach Q2',              'INS_HOME_LOAN_LINKED')
),
cust AS (
  SELECT c.CUSTOMER_ID, t.SEGMENT_CODE, t.IS_SUPPRESSED_OVERLAY,
         RAW.RND_INT('ncmp|' || c.CUSTOMER_ID, 1, 9) AS n_contacts
  FROM RAW.CUSTOMER c
  JOIN RAW.CUSTOMER_SEGMENT_TRUTH t ON t.CUSTOMER_ID = c.CUSTOMER_ID
),
grid AS (
  SELECT cu.*, s.slot, 'cm|' || cu.CUSTOMER_ID || '|' || s.slot AS k
  FROM cust cu
  CROSS JOIN (SELECT SEQ8() + 1 AS slot FROM TABLE(GENERATOR(ROWCOUNT => 9))) s
  WHERE s.slot <= cu.n_contacts
),
shaped AS (
  SELECT g.*,
    RAW.RND_INT('cmpi|' || g.k, 0, 7) AS cmp_idx,
    -- ~12% of contacts land inside the cooling-off window
    IFF(RAW.RND_BOOL('cmrec|' || g.k, 0.12),
        RAW.RND_INT('cmage|' || g.k, 1, 14),
        RAW.RND_INT('cmage|' || g.k, 15, 540)) AS days_ago,
    CASE
      WHEN g.IS_SUPPRESSED_OVERLAY AND RAW.RND_BOOL('cmout|' || g.k, 0.42) THEN 'OPT_OUT'
      WHEN g.IS_SUPPRESSED_OVERLAY AND RAW.RND_BOOL('cmout2|' || g.k, 0.20) THEN 'COMPLAINED'
      WHEN RAW.RND('cmout|' || g.k) < 0.58 THEN 'NO_RESPONSE'
      WHEN RAW.RND('cmout|' || g.k) < 0.74 THEN 'DECLINED'
      WHEN RAW.RND('cmout|' || g.k) < 0.88 THEN 'INTERESTED'
      WHEN RAW.RND('cmout|' || g.k) < 0.96 THEN 'CONVERTED'
      ELSE 'OPT_OUT'
    END AS outcome
  FROM grid g
)
SELECT
  ROW_NUMBER() OVER (ORDER BY s.CUSTOMER_ID, s.slot)                        AS campaign_contact_id,
  c.campaign_id,
  c.campaign_name,
  s.CUSTOMER_ID,
  c.product_code,
  RAW.RND_PICK('cmch|' || s.k,
    ARRAY_CONSTRUCT('CALL','SMS','EMAIL','WHATSAPP'))                       AS channel,
  DATEADD(second, RAW.RND_INT('cmsec|' || s.k, 32400, 68400),
    DATEADD(day, -s.days_ago, RAW.AS_OF())::TIMESTAMP_NTZ)                  AS contacted_at,
  s.outcome,
  (s.outcome = 'CONVERTED')                                                 AS converted_flag,
  IFF(s.outcome = 'CONVERTED',
      ROUND(RAW.RND_NORM_CLAMP('cmrev|' || s.k, 34000, 22000, 4000, 260000), -2),
      NULL)                                                                 AS revenue_inr,
  CURRENT_TIMESTAMP()                                                       AS load_ts
FROM shaped s
JOIN campaigns c ON c.idx = s.cmp_idx;

SELECT 'RAW seed complete' AS status, RAW.AS_OF() AS as_of_date, RAW.SEED() AS seed;

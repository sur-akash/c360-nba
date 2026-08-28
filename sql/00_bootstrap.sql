USE ROLE ACCOUNTADMIN;

CREATE ROLE IF NOT EXISTS COCO_BUILDER;

-- Cortex entitlements: LLM/AI SQL functions, and agent objects
GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER       TO ROLE COCO_BUILDER;
GRANT DATABASE ROLE SNOWFLAKE.CORTEX_AGENT_USER TO ROLE COCO_BUILDER;

-- XSMALL is right-sized for 5k customers on a $400 trial.
CREATE WAREHOUSE IF NOT EXISTS COCO_WH
  WAREHOUSE_SIZE = 'XSMALL'
  AUTO_SUSPEND   = 60
  AUTO_RESUME    = TRUE
  INITIALLY_SUSPENDED = TRUE;

-- Hard stop before the trial does it for you.
CREATE RESOURCE MONITOR IF NOT EXISTS COCO_BUDGET
  WITH CREDIT_QUOTA = 60
  FREQUENCY = MONTHLY
  START_TIMESTAMP = IMMEDIATELY
  TRIGGERS
    ON 60  PERCENT DO NOTIFY
    ON 85  PERCENT DO NOTIFY
    ON 100 PERCENT DO SUSPEND;

ALTER WAREHOUSE COCO_WH SET RESOURCE_MONITOR = COCO_BUDGET;

CREATE DATABASE IF NOT EXISTS C360_NBA;

GRANT USAGE   ON WAREHOUSE COCO_WH TO ROLE COCO_BUILDER;
GRANT OPERATE ON WAREHOUSE COCO_WH TO ROLE COCO_BUILDER;

-- Don't transfer database ownership — just let COCO_BUILDER create its own
-- schemas. It then owns RAW/CURATED/GOLD/APP outright, which carries every
-- privilege it needs inside them (tables, stages, agents, Streamlit objects)
-- without another grant. Ownership transfer is where this script usually breaks.
GRANT USAGE        ON DATABASE C360_NBA TO ROLE COCO_BUILDER;
GRANT CREATE SCHEMA ON DATABASE C360_NBA TO ROLE COCO_BUILDER;

GRANT ROLE COCO_BUILDER TO USER SURAKASH;

-- Only if the models you want aren't hosted in your account's region.
-- Harmless to run either way.
ALTER ACCOUNT SET CORTEX_ENABLED_CROSS_REGION = 'ANY_REGION';

-- ---------------------------------------------------------------
-- Smoke test: proves Cortex works for COCO_BUILDER, no model-name
-- guessing required. If this returns a number, you're entitled.
-- ---------------------------------------------------------------
USE ROLE COCO_BUILDER;
USE WAREHOUSE COCO_WH;
USE DATABASE C360_NBA;

SELECT SNOWFLAKE.CORTEX.SENTIMENT(
  'The renewal premium is far too high, I am looking elsewhere.'
) AS cortex_smoke_test;

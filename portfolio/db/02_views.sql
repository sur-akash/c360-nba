-- Postgres port of the Snowflake objects the Compass360 app reads.
--
-- Source of truth: the Snowflake DDL in sql/05, 08, 15-19 of the repo. Each
-- object below keeps the Snowflake name, column order and logic; only the
-- dialect changes. The two Snowflake dynamic tables (GOLD.CUSTOMER_360 and
-- GOLD.CUSTOMER_TIMELINE) become materialized views -- the same idea, refreshed
-- with REFRESH MATERIALIZED VIEW instead of a target lag.
--
-- Run after 00_helpers.sql, 01_tables.sql and the data load.

-- =============================================================================
-- CURATED
-- =============================================================================

create or replace function curated.parse_inr(txt text)
returns numeric(14,2) language sql immutable as
$$ select (case
     when txt is null then null
     when txt ~* '(crore|crores|\ycr\y)'
       then public.try_double(substring(txt from '[0-9]+(?:[.][0-9]+)?')) * 10000000
     when txt ~* '(lakhs|lakh|lacs|lac|\yL\y)'
       then public.try_double(substring(txt from '[0-9]+(?:[.][0-9]+)?')) * 100000
     else public.try_double(regexp_replace(txt, '[^0-9.]', '', 'g'))
   end)::numeric(14,2) $$;

create or replace function curated.sentiment_score(lbl text)
returns double precision language sql immutable as
$$ select (case lower(lbl)
     when 'positive' then  1.0
     when 'neutral'  then  0.0
     when 'mixed'    then -0.25
     when 'negative' then -1.0
   end)::double precision $$;

create or replace view curated.interaction_signals as
with s as (
  select
    r.interaction_id, r.customer_id,
    i.artefact_type, i.channel, i.direction, i.occurred_at, i.language_code, i.source_kind,
    r.enrich_version, r.enrich_model,
    nullif(lower(jsonb_path_query_first(r.sentiment_raw, '$.categories[*] ? (@.name == "overall").sentiment') #>> '{}'), 'unknown') as sent_overall,
    nullif(lower(jsonb_path_query_first(r.sentiment_raw, '$.categories[*] ? (@.name == "pricing").sentiment') #>> '{}'), 'unknown') as sent_pricing,
    nullif(lower(jsonb_path_query_first(r.sentiment_raw, '$.categories[*] ? (@.name == "service").sentiment') #>> '{}'), 'unknown') as sent_service,
    nullif(lower(jsonb_path_query_first(r.sentiment_raw, '$.categories[*] ? (@.name == "claims").sentiment')  #>> '{}'), 'unknown') as sent_claims,
    r.intent_raw -> 'labels' ->> 0                      as intent_classify,
    r.complete_raw ->> 'intent'                         as intent_complete,
    (r.complete_raw ->> 'intent_confidence')::float8    as intent_conf_reported,
    lower(r.complete_raw ->> 'sentiment_overall')       as sent_overall_complete,
    r.extract_raw -> 'response'                         as ext,
    r.extract_raw -> 'scoring' -> 'scores'              as ext_scores,
    r.complete_raw                                      as cmp,
    r.filter_churn
  from curated.interaction_signals_raw r
  join raw.interaction i on i.interaction_id = r.interaction_id
), e as (
  select s.*,
    nullif(trim(ext ->> 'product_mentioned'), '')      as e_product,
    nullif(trim(ext ->> 'competitor_name'), '')        as e_competitor,
    nullif(trim(ext ->> 'amount_discussed'), '')       as e_amount,
    nullif(trim(ext ->> 'promised_callback_date'), '') as e_callback,
    (cmp ->> 'churn_risk_mentioned')::boolean          as c_churn,
    (cmp ->> 'churn_risk_confidence')::float8          as c_churn_conf
  from s
), x as (
  select e.*,
    curated.parse_inr(e_amount) as amount_inr,
    case
      when intent_classify is null           then null
      when intent_classify = intent_complete then least(0.97, greatest(0.85, coalesce(intent_conf_reported, 0.85)))
      else least(0.60, coalesce(intent_conf_reported, 0.50))
    end as intent_conf
  from e
)
select
  interaction_id, customer_id, artefact_type, channel, direction, occurred_at,
  language_code, source_kind, enrich_version, enrich_model,
  sent_overall                                    as sentiment_overall,
  curated.sentiment_score(sent_overall)           as sentiment_score,
  case
    when sent_overall is null                 then null
    when sent_overall = sent_overall_complete then 0.92
    when sent_overall in ('mixed','negative') and sent_overall_complete in ('mixed','negative') then 0.72
    when sent_overall in ('mixed','positive') and sent_overall_complete in ('mixed','positive') then 0.72
    else 0.45
  end                                             as sentiment_overall_conf,
  sent_pricing                                    as sentiment_pricing,
  sent_service                                    as sentiment_service,
  sent_claims                                     as sentiment_claims,
  case when sent_pricing is null then null else 0.85 end as sentiment_pricing_conf,
  case when sent_service is null then null else 0.85 end as sentiment_service_conf,
  case when sent_claims  is null then null else 0.85 end as sentiment_claims_conf,
  intent_classify                                 as intent,
  intent_complete                                 as intent_second_opinion,
  intent_conf,
  tx.is_service_only                              as intent_is_service_only,
  c_churn                                         as churn_risk_mentioned,
  case
    when filter_churn is null    then c_churn_conf
    when filter_churn = c_churn  then least(0.98, coalesce(c_churn_conf, 0.5) + 0.10)
    else coalesce(c_churn_conf, 0.5) * 0.55
  end                                             as churn_risk_conf,
  filter_churn                                    as churn_risk_crosscheck,
  (filter_churn = c_churn)                        as churn_crosscheck_agrees,
  (cmp ->> 'competitor_mentioned')::boolean       as competitor_mentioned,
  (cmp ->> 'competitor_confidence')::float8       as competitor_mentioned_conf,
  (cmp ->> 'complaint')::boolean                  as complaint,
  (cmp ->> 'complaint_confidence')::float8        as complaint_conf,
  (cmp ->> 'life_event')::boolean                 as life_event,
  (cmp ->> 'life_event_confidence')::float8       as life_event_conf,
  (cmp ->> 'hardship_signal')::boolean            as hardship_signal,
  (cmp ->> 'hardship_confidence')::float8         as hardship_signal_conf,
  (cmp ->> 'consent_withdrawal')::boolean         as consent_withdrawal,
  (cmp ->> 'consent_withdrawal_confidence')::float8 as consent_withdrawal_conf,
  e_product                                       as product_mentioned,
  case when e_product is null then null
       else (ext_scores -> 'product_mentioned' ->> 'score')::float8 end      as product_mentioned_conf,
  e_competitor                                    as competitor_name,
  case when e_competitor is null then null
       else (ext_scores -> 'competitor_name' ->> 'score')::float8 end        as competitor_name_conf,
  e_amount                                        as amount_discussed_text,
  amount_inr                                      as amount_discussed_inr,
  case when amount_inr is null then null
       else (ext_scores -> 'amount_discussed' ->> 'score')::float8 end       as amount_discussed_conf,
  e_callback                                      as promised_callback_text,
  public.try_date(e_callback)                     as promised_callback_date,
  case when e_callback is null then null
       else (ext_scores -> 'promised_callback_date' ->> 'score')::float8 end as promised_callback_conf,
  cmp ->> 'summary_25w'                           as summary_25w,
  (cmp ->> 'summary_confidence')::float8          as summary_conf,
  jsonb_build_object(
    'summary',            cmp ->> 'summary_25w',
    'intent',             jsonb_strip_nulls(jsonb_build_object('value', intent_classify, 'confidence', intent_conf)),
    'sentiment_overall',  jsonb_strip_nulls(jsonb_build_object('value', sent_overall,
                            'confidence', case when sent_overall = sent_overall_complete then 0.92 else 0.45 end)),
    'sentiment_aspects',  jsonb_strip_nulls(jsonb_build_object('pricing', sent_pricing, 'service', sent_service, 'claims', sent_claims)),
    'churn_risk_mentioned', jsonb_strip_nulls(jsonb_build_object('value', c_churn, 'confidence', c_churn_conf,
                                                                 'crosschecked_by_ai_filter', filter_churn)),
    'competitor_mentioned', jsonb_strip_nulls(jsonb_build_object('value', (cmp ->> 'competitor_mentioned')::boolean,
                                                                 'confidence', (cmp ->> 'competitor_confidence')::float8)),
    'complaint',          jsonb_strip_nulls(jsonb_build_object('value', (cmp ->> 'complaint')::boolean,
                                                               'confidence', (cmp ->> 'complaint_confidence')::float8)),
    'life_event',         jsonb_strip_nulls(jsonb_build_object('value', (cmp ->> 'life_event')::boolean,
                                                               'confidence', (cmp ->> 'life_event_confidence')::float8)),
    'hardship_signal',    jsonb_strip_nulls(jsonb_build_object('value', (cmp ->> 'hardship_signal')::boolean,
                                                               'confidence', (cmp ->> 'hardship_confidence')::float8)),
    'consent_withdrawal', jsonb_strip_nulls(jsonb_build_object('value', (cmp ->> 'consent_withdrawal')::boolean,
                                                               'confidence', (cmp ->> 'consent_withdrawal_confidence')::float8)),
    'entities', jsonb_build_object(
      'product',           jsonb_strip_nulls(jsonb_build_object('value', e_product,    'confidence', (ext_scores -> 'product_mentioned' ->> 'score')::float8)),
      'competitor',        jsonb_strip_nulls(jsonb_build_object('value', e_competitor, 'confidence', (ext_scores -> 'competitor_name' ->> 'score')::float8)),
      'amount_inr',        jsonb_strip_nulls(jsonb_build_object('value', amount_inr,   'confidence', (ext_scores -> 'amount_discussed' ->> 'score')::float8)),
      'promised_callback', jsonb_strip_nulls(jsonb_build_object('value', e_callback,   'confidence', (ext_scores -> 'promised_callback_date' ->> 'score')::float8)))
  )                                               as signals_json
from x
left join curated.intent_taxonomy tx on tx.intent_code = x.intent_classify;

create or replace view curated.interaction_signals_gated as
with cfg as (
  select
    max(case when config_key = 'MIN_CONFIDENCE'                      then config_value end) as g,
    max(case when config_key = 'MIN_CONFIDENCE.CONSENT_WITHDRAWAL'   then config_value end) as t_consent,
    max(case when config_key = 'MIN_CONFIDENCE.HARDSHIP_SIGNAL'      then config_value end) as t_hardship,
    max(case when config_key = 'MIN_CONFIDENCE.AMOUNT_DISCUSSED'     then config_value end) as t_amount,
    max(case when config_key = 'MIN_CONFIDENCE.INTENT'               then config_value end) as t_intent,
    max(case when config_key = 'MIN_CONFIDENCE.SENTIMENT_OVERALL'    then config_value end) as t_sent,
    max(case when config_key = 'MIN_CONFIDENCE.CHURN_RISK'           then config_value end) as t_churn,
    max(case when config_key = 'MIN_CONFIDENCE.COMPETITOR_MENTIONED' then config_value end) as t_comp,
    max(case when config_key = 'MIN_CONFIDENCE.COMPLAINT'            then config_value end) as t_complaint,
    max(case when config_key = 'MIN_CONFIDENCE.LIFE_EVENT'           then config_value end) as t_life,
    max(case when config_key = 'MIN_CONFIDENCE.PRODUCT_MENTIONED'    then config_value end) as t_product,
    max(case when config_key = 'MIN_CONFIDENCE.COMPETITOR_NAME'      then config_value end) as t_compname,
    max(case when config_key = 'MIN_CONFIDENCE.PROMISED_CALLBACK'    then config_value end) as t_callback
  from curated.ai_config
)
select
  v.interaction_id, v.customer_id, v.artefact_type, v.channel, v.direction,
  v.occurred_at, v.language_code, v.source_kind, v.enrich_version, v.enrich_model,
  iff(v.sentiment_overall_conf >= coalesce(c.t_sent, c.g), v.sentiment_overall, null) as sentiment_overall,
  iff(v.sentiment_overall_conf >= coalesce(c.t_sent, c.g), v.sentiment_score,   null) as sentiment_score,
  v.sentiment_overall_conf,
  iff(v.sentiment_pricing_conf >= c.g, v.sentiment_pricing, null) as sentiment_pricing,
  iff(v.sentiment_service_conf >= c.g, v.sentiment_service, null) as sentiment_service,
  iff(v.sentiment_claims_conf  >= c.g, v.sentiment_claims,  null) as sentiment_claims,
  v.sentiment_pricing_conf, v.sentiment_service_conf, v.sentiment_claims_conf,
  iff(v.intent_conf >= coalesce(c.t_intent, c.g), v.intent, null)                 as intent,
  iff(v.intent_conf >= coalesce(c.t_intent, c.g), v.intent_is_service_only, null) as intent_is_service_only,
  v.intent_conf, v.intent_second_opinion,
  iff(v.churn_risk_conf >= coalesce(c.t_churn, c.g), v.churn_risk_mentioned, null) as churn_risk_mentioned,
  v.churn_risk_conf, v.churn_crosscheck_agrees,
  iff(v.competitor_mentioned_conf >= coalesce(c.t_comp, c.g), v.competitor_mentioned, null) as competitor_mentioned,
  v.competitor_mentioned_conf,
  iff(v.complaint_conf >= coalesce(c.t_complaint, c.g), v.complaint, null) as complaint,
  v.complaint_conf,
  iff(v.life_event_conf >= coalesce(c.t_life, c.g), v.life_event, null) as life_event,
  v.life_event_conf,
  iff(v.hardship_signal_conf >= coalesce(c.t_hardship, c.g), v.hardship_signal, null) as hardship_signal,
  v.hardship_signal_conf,
  iff(v.consent_withdrawal_conf >= coalesce(c.t_consent, c.g), v.consent_withdrawal, null) as consent_withdrawal,
  v.consent_withdrawal_conf,
  iff(v.product_mentioned_conf >= coalesce(c.t_product, c.g), v.product_mentioned, null) as product_mentioned,
  v.product_mentioned_conf,
  iff(v.competitor_name_conf >= coalesce(c.t_compname, c.g), v.competitor_name, null) as competitor_name,
  v.competitor_name_conf,
  iff(v.amount_discussed_conf >= coalesce(c.t_amount, c.g), v.amount_discussed_inr, null) as amount_discussed_inr,
  v.amount_discussed_conf,
  iff(v.promised_callback_conf >= coalesce(c.t_callback, c.g), v.promised_callback_date, null) as promised_callback_date,
  v.promised_callback_conf,
  v.summary_25w, v.summary_conf, v.signals_json
from curated.interaction_signals v cross join cfg c;

-- =============================================================================
-- GOLD -- the two dynamic tables, as materialized views
-- =============================================================================

create materialized view gold.customer_360 as
with cal as (select as_of_date from gold.c360_asof),
hh as (
  select customer_id, max(household_size) as household_size
  from raw.household group by 1
),
pol as (
  select
    p.customer_id,
    sum(case p.premium_frequency when 'MONTHLY' then p.premium_inr * 12
                                 when 'QUARTERLY' then p.premium_inr * 4
                                 else p.premium_inr end)                       as annual_premium_inr,
    sum(case p.premium_frequency when 'MONTHLY' then p.premium_inr * 12
                                 when 'QUARTERLY' then p.premium_inr * 4
                                 else p.premium_inr end * pc.margin_rate)      as policy_margin_inr,
    count_if(p.policy_type = 'TERM')   as n_term,
    count_if(p.policy_type = 'HEALTH') as n_health,
    count_if(p.policy_type = 'MOTOR')  as n_motor,
    count_if(p.policy_type = 'HOME')   as n_home_ins,
    count_if(p.policy_type = 'ULIP')   as n_ulip,
    min(case when p.renewal_date >= a.as_of_date then p.renewal_date end) as next_renewal_date
  from raw.policy p
  join raw.product_catalog pc on pc.product_code = p.product_code
  cross join cal a
  where p.status = 'ACTIVE'
  group by 1
),
pol_hist as (
  select customer_id,
         count_if(lapse_flag or status in ('LAPSED','SURRENDERED')) as lapse_history
  from raw.policy group by 1
),
loan_sched as (
  select
    l.customer_id, l.loan_type, l.outstanding_inr, l.dpd_days, l.dpd_days_m1, l.dpd_days_m2,
    l.restructure_flag, pc.margin_rate,
    dateadd('month',
            datediff('month', l.first_emi_date, a.as_of_date)
              + iff(dateadd('month', datediff('month', l.first_emi_date, a.as_of_date), l.first_emi_date)
                    > a.as_of_date, 0, 1),
            l.first_emi_date)                                   as projected_next_emi,
    dateadd('month', l.tenure_months - 1, l.first_emi_date)    as final_emi_date
  from raw.loan l
  join raw.product_catalog pc on pc.product_code = l.product_code
  cross join cal a
  where l.status = 'ACTIVE'
),
ln as (
  select
    customer_id,
    sum(outstanding_inr)                         as loan_outstanding_inr,
    sum(outstanding_inr * margin_rate)           as loan_margin_inr,
    max(dpd_days)                                as worst_dpd_days,
    count_if(loan_type = 'HOME')                 as n_home_loan,
    count_if(loan_type = 'AUTO')                 as n_auto_loan,
    count_if(loan_type = 'PERSONAL')             as n_personal_loan,
    count_if(restructure_flag)                   as n_restructured,
    count_if(dpd_days_m2 < dpd_days_m1 and dpd_days_m1 < dpd_days) as n_rising_dpd,
    min(case when projected_next_emi <= final_emi_date then projected_next_emi end) as next_emi_date
  from loan_sched group by 1
),
cd as (
  select
    c.customer_id,
    count(*)                                         as n_card,
    sum(c.current_balance_inr)                       as card_balance_inr,
    sum(c.credit_limit_inr)                          as card_limit_inr,
    sum(c.current_balance_inr * pc.margin_rate)      as card_margin_inr,
    count_if(c.utilisation_pct_m3 < c.utilisation_pct_m2
         and c.utilisation_pct_m2 < c.utilisation_pct_m1
         and c.utilisation_pct_m1 < c.utilisation_pct) as n_rising_util
  from raw.card c
  join raw.product_catalog pc on pc.product_code = c.product_code
  where c.status = 'ACTIVE'
  group by 1
),
rep as (
  select
    r.customer_id,
    count_if(r.missed_flag and r.due_date >= dateadd('month', -12, a.as_of_date)) as missed_payments_12m,
    count_if(r.missed_flag and r.due_date >= dateadd('month',  -6, a.as_of_date)) as missed_payments_6m,
    count_if(r.late_flag or r.missed_flag)                                         as adverse_payments_ever
  from raw.repayment r cross join cal a
  group by 1
),
clm as (
  select customer_id, count(*) as n_claims,
         round(div0(sum(coalesce(approved_amount_inr, 0)), sum(claim_amount_inr)), 4) as claim_ratio
  from raw.claim group by 1
),
lump as (
  select t.customer_id, max(t.amount_inr) as max_inbound_lumpsum_90d
  from raw.txn t cross join cal a
  where t.direction = 'CREDIT'
    and t.amount_inr >= 1000000
    and t.txn_date >= dateadd('day', -90, a.as_of_date)
  group by 1
),
cons_base as (
  select k.customer_id, k.channel, k.dnc_flag,
         (k.opt_in_flag and not k.dnc_flag and k.valid_from <= a.as_of_date
          and (k.valid_to is null or k.valid_to >= a.as_of_date)) as granted
  from raw.consent k cross join cal a
),
cons as (
  select
    customer_id,
    count_if(channel = 'CALL'  and granted) > 0          as consent_call,
    count_if(channel = 'EMAIL' and granted) > 0          as consent_email,
    count_if(channel = 'SMS'   and granted) > 0          as consent_sms,
    count_if(channel in ('CALL','SMS') and dnc_flag) > 0 as dnc_flag,
    count_if(granted)                                    as channels_reachable
  from cons_base group by 1
),
camp as (
  select customer_id, channel as preferred_channel
  from (
    select customer_id, channel,
           row_number() over (
             partition by customer_id
             order by count_if(outcome in ('CONVERTED','INTERESTED')) desc,
                      count_if(outcome = 'NO_RESPONSE') asc,
                      channel collate "C" asc) as rn
    from raw.campaign_history
    group by 1, 2
  ) z
  where rn = 1
),
assembled as (
  select
    c.customer_id, a.as_of_date,
    c.full_name, c.age_years, c.city, c.segment, c.income_band_rank, c.kyc_status,
    c.vulnerability_flag, c.tenure_months,
    coalesce(hh.household_size, 1)                      as household_size,
    coalesce(pol.n_term, 0) > 0                         as has_term,
    coalesce(pol.n_health, 0) > 0                       as has_health,
    coalesce(pol.n_motor, 0) > 0                        as has_motor_insurance,
    coalesce(pol.n_home_ins, 0) > 0                     as has_home_insurance,
    coalesce(pol.n_ulip, 0) > 0                         as has_investment,
    coalesce(ln.n_home_loan, 0) > 0                     as has_home_loan,
    coalesce(ln.n_auto_loan, 0) > 0                     as has_auto_loan,
    coalesce(ln.n_personal_loan, 0) > 0                 as has_personal_loan,
    coalesce(cd.n_card, 0) > 0                          as has_card,
    coalesce(pol.annual_premium_inr, 0)                 as annual_premium_inr,
    coalesce(ln.loan_outstanding_inr, 0) + coalesce(cd.card_balance_inr, 0) as outstanding_credit_inr,
    round(coalesce(pol.policy_margin_inr, 0) + coalesce(ln.loan_margin_inr, 0)
          + coalesce(cd.card_margin_inr, 0))            as est_annual_margin_inr,
    ln.worst_dpd_days,
    coalesce(rep.missed_payments_12m, 0)                as missed_payments_12m,
    coalesce(rep.missed_payments_6m, 0)                 as missed_payments_6m,
    coalesce(rep.adverse_payments_ever, 0)              as adverse_payments_ever,
    coalesce(pol_hist.lapse_history, 0)                 as lapse_history,
    clm.claim_ratio,
    round(div0(cd.card_balance_inr, cd.card_limit_inr), 4) as credit_utilisation,
    coalesce(ln.n_rising_dpd, 0) > 0                    as rising_dpd,
    coalesce(cd.n_rising_util, 0) > 0                   as rising_utilisation,
    coalesce(ln.n_restructured, 0) > 0                  as restructured,
    coalesce(roll.interactions_90d, 0)                  as interactions_90d,
    roll.latest_sentiment                               as sentiment_now,
    roll.sentiment_trend                                as sentiment_trend_raw,
    coalesce(roll.open_complaint_flag, false)           as open_complaint,
    roll.last_contact_at,
    roll.hardship_mentions_90d,
    coalesce(camp.preferred_channel, 'CALL')            as preferred_channel,
    coalesce(cons.consent_call, false)                  as consent_call,
    coalesce(cons.consent_email, false)                 as consent_email,
    coalesce(cons.consent_sms, false)                   as consent_sms,
    coalesce(cons.dnc_flag, false)                      as dnc_flag,
    coalesce(cons.channels_reachable, 0)                as channels_reachable,
    pol.next_renewal_date,
    ln.next_emi_date,
    coalesce(lump.max_inbound_lumpsum_90d, 0)           as max_inbound_lumpsum_90d
  from raw.customer c
  cross join cal a
  left join hh       on hh.customer_id       = c.customer_id
  left join pol      on pol.customer_id      = c.customer_id
  left join pol_hist on pol_hist.customer_id = c.customer_id
  left join ln       on ln.customer_id       = c.customer_id
  left join cd       on cd.customer_id       = c.customer_id
  left join rep      on rep.customer_id      = c.customer_id
  left join clm      on clm.customer_id      = c.customer_id
  left join lump     on lump.customer_id     = c.customer_id
  left join cons     on cons.customer_id     = c.customer_id
  left join camp     on camp.customer_id     = c.customer_id
  left join curated.customer_interaction_rollup roll on roll.customer_id = c.customer_id
)
select
  s.customer_id, s.as_of_date,
  s.full_name                                   as customer_name,
  s.age_years                                   as age,
  s.city, s.segment, s.household_size,
  round(s.tenure_months / 12.0, 1)              as tenure_years,
  array_compact(jsonb_build_array(
    iff(s.has_term,            'Term Life',         null::text),
    iff(s.has_health,          'Health Insurance',  null::text),
    iff(s.has_motor_insurance, 'Motor Insurance',   null::text),
    iff(s.has_home_insurance,  'Home Insurance',    null::text),
    iff(s.has_investment,      'Investment (ULIP)', null::text),
    iff(s.has_home_loan,       'Home Loan',         null::text),
    iff(s.has_auto_loan,       'Auto Loan',         null::text),
    iff(s.has_personal_loan,   'Personal Loan',     null::text),
    iff(s.has_card,            'Credit Card',       null::text)))   as products_held,
  jsonb_array_length(array_compact(jsonb_build_array(
    iff(s.has_term,            'Term Life',         null::text),
    iff(s.has_health,          'Health Insurance',  null::text),
    iff(s.has_motor_insurance, 'Motor Insurance',   null::text),
    iff(s.has_home_insurance,  'Home Insurance',    null::text),
    iff(s.has_investment,      'Investment (ULIP)', null::text),
    iff(s.has_home_loan,       'Home Loan',         null::text),
    iff(s.has_auto_loan,       'Auto Loan',         null::text),
    iff(s.has_personal_loan,   'Personal Loan',     null::text),
    iff(s.has_card,            'Credit Card',       null::text))))  as product_count,
  s.has_home_loan, s.has_home_insurance, s.has_health, s.has_card, s.has_investment,
  s.annual_premium_inr, s.outstanding_credit_inr, s.est_annual_margin_inr,
  case
    when s.est_annual_margin_inr >= 150000 then 'PLATINUM'
    when s.est_annual_margin_inr >=  75000 then 'GOLD'
    when s.est_annual_margin_inr >=  25000 then 'SILVER'
    when s.est_annual_margin_inr >       0 then 'BRONZE'
    else 'NO_ACTIVE_HOLDINGS'
  end                                           as relationship_value_band,
  case
    when s.worst_dpd_days is null then 'NO_CREDIT_OBLIGATION'
    when s.worst_dpd_days = 0     then 'CURRENT'
    when s.worst_dpd_days <= 30   then '1-30'
    when s.worst_dpd_days <= 60   then '31-60'
    when s.worst_dpd_days <= 90   then '61-90'
    else '90+'
  end                                           as dpd_bucket,
  s.missed_payments_12m, s.lapse_history, s.claim_ratio, s.credit_utilisation,
  (s.rising_dpd or s.missed_payments_6m >= 2 or s.restructured
   or coalesce(s.hardship_mentions_90d, 0) > 0) as hardship_signal,
  s.interactions_90d, s.sentiment_now,
  coalesce(s.sentiment_trend_raw, 'NO_CONTACT_HISTORY') as sentiment_trend,
  s.open_complaint,
  datediff('day', s.last_contact_at, s.as_of_date)      as last_contact_days,
  s.preferred_channel,
  s.consent_call, s.consent_email, s.consent_sms, s.dnc_flag, s.vulnerability_flag,
  (s.kyc_status = 'VERIFIED')                   as kyc_current,
  array_compact(jsonb_build_array(
    iff(s.has_home_loan and not s.has_home_insurance, 'Home Insurance', null::text),
    iff(s.has_auto_loan and not s.has_motor_insurance, 'Motor Insurance', null::text),
    iff(not s.has_health and s.age_years between 18 and 65, 'Health Insurance', null::text),
    iff(not s.has_term and s.household_size >= 2 and s.age_years between 21 and 60, 'Term Life', null::text),
    iff(not s.has_investment and s.max_inbound_lumpsum_90d >= 1000000, 'Investment (ULIP)', null::text),
    iff(not s.has_card and s.age_years between 21 and 65, 'Credit Card', null::text)))  as product_gap,
  s.next_renewal_date,
  datediff('day', s.as_of_date, s.next_renewal_date)    as days_to_renewal,
  s.next_emi_date
from assembled s;

create unique index on gold.customer_360 (customer_id);

create materialized view gold.customer_timeline as
with cal as (select as_of_date from gold.c360_asof),
ev as (
  select p.customer_id, 'POLICY_ISSUED' as event_type, p.start_date::timestamp as occurred_at,
         'Policy issued — ' || initcap(p.policy_type) as title,
         'Premium ₹' || to_char(p.premium_inr, '999,999,999')
           || ' ' || lower(p.premium_frequency)
           || ', sum assured ₹' || to_char(p.sum_assured_inr, '999,999,999')
           || ', sold via ' || lower(p.channel_sold) as detail,
         'RAW.POLICY' as source_table, p.policy_number::text as source_id
  from raw.policy p
  union all
  select p.customer_id, 'POLICY_LAPSED',
         iff(p.renewal_date > a.as_of_date, dateadd('year', -1, p.renewal_date), p.renewal_date)::timestamp,
         'Policy lapsed — ' || initcap(p.policy_type),
         'Cover ceased. Annual premium at lapse ₹' || to_char(p.premium_inr, '999,999,999')
           || '. Timestamp is the renewal the policy failed to complete; RAW.POLICY records no lapse date.',
         'RAW.POLICY', p.policy_number::text
  from raw.policy p cross join cal a
  where p.lapse_flag or p.status = 'LAPSED'
  union all
  select cl.customer_id, 'CLAIM_FILED', cl.filed_at,
         'Claim filed — ' || initcap(replace(cl.claim_type, '_', ' ')),
         'Claimed ₹' || to_char(cl.claim_amount_inr, '999,999,999') || ', status ' || lower(cl.status),
         'RAW.CLAIM', cl.claim_number::text
  from raw.claim cl
  union all
  select cl.customer_id, 'CLAIM_SETTLED', cl.settled_at,
         'Claim settled — ' || initcap(replace(cl.claim_type, '_', ' ')),
         'Approved ₹' || to_char(coalesce(cl.approved_amount_inr, 0), '999,999,999')
           || ' of ₹' || to_char(cl.claim_amount_inr, '999,999,999')
           || ' claimed, in ' || cl.settlement_days::text || ' days',
         'RAW.CLAIM', cl.claim_number::text
  from raw.claim cl
  where cl.settled_at is not null
  union all
  select l.customer_id, 'LOAN_DISBURSED', l.disbursal_date::timestamp,
         'Loan disbursed — ' || initcap(l.loan_type),
         'Principal ₹' || to_char(l.principal_inr, '999,999,999')
           || ' over ' || l.tenure_months::text || ' months at '
           || l.interest_rate_pct::text || '%, EMI ₹' || to_char(l.emi_inr, '999,999,999'),
         'RAW.LOAN', l.loan_account_no::text
  from raw.loan l
  union all
  select r.customer_id,
         case when r.missed_flag then 'PAYMENT_MISSED'
              when r.late_flag   then 'PAYMENT_LATE'
              else 'PAYMENT_ON_TIME' end,
         coalesce(r.paid_date, r.due_date)::timestamp,
         case when r.missed_flag then 'Instalment missed — '
              when r.late_flag   then 'Instalment paid late — '
              else 'Instalment paid — ' end
           || iff(r.obligation_type = 'LOAN_EMI', 'loan EMI'::text, 'policy premium'),
         '₹' || to_char(r.due_amount_inr, '999,999,999')
           || ' due ' || to_char(r.due_date, 'DD Mon YYYY')
           || iff(r.missed_flag, ', not received',
                  ', paid ' || to_char(r.paid_date, 'DD Mon YYYY')
                    || iff(coalesce(r.days_late, 0) > 0, ' (' || r.days_late::text || ' days late)', '')),
         'RAW.REPAYMENT', r.repayment_id::text
  from raw.repayment r
  union all
  select i.customer_id, 'INTERACTION', i.occurred_at,
         coalesce(nullif(trim(i.subject), ''), initcap(replace(i.artefact_type, '_', ' '))),
         coalesce(g.summary_25w, left(i.body, 300))
           || iff(g.sentiment_overall is not null, '  ·  sentiment: ' || g.sentiment_overall, '')
           || iff(g.intent is not null, '  ·  intent: ' || lower(replace(g.intent, '_', ' ')), '')
           || '  ·  ' || lower(i.channel) || ', ' || lower(i.direction),
         'RAW.INTERACTION', i.interaction_id::text
  from raw.interaction i
  left join curated.interaction_signals_gated g on g.interaction_id = i.interaction_id
  union all
  select t.customer_id, iff(t.is_complaint, 'COMPLAINT_RAISED'::text, 'TICKET_OPENED'), t.opened_at,
         iff(t.is_complaint, 'Complaint raised — '::text, 'Service request — ')
           || initcap(replace(t.category, '_', ' ')),
         'Severity ' || t.severity::text || ', ' || lower(t.channel) || ', status ' || lower(t.status)
           || iff(t.sub_category is not null, ' — ' || initcap(replace(t.sub_category, '_', ' ')), ''),
         'RAW.SERVICE_TICKET', t.ticket_number::text
  from raw.service_ticket t
  union all
  select t.customer_id, 'TICKET_CLOSED', t.closed_at,
         'Ticket closed — ' || initcap(replace(t.category, '_', ' ')),
         'Resolved in ' || round(t.resolution_hours::float8, 1)::text || ' hours',
         'RAW.SERVICE_TICKET', t.ticket_number::text
  from raw.service_ticket t
  where t.closed_at is not null
  union all
  select ca.customer_id, 'CAMPAIGN_CONTACT', ca.contacted_at,
         'Outbound contact — ' || ca.campaign_name,
         lower(ca.channel) || ', outcome ' || lower(replace(ca.outcome, '_', ' '))
           || iff(ca.converted_flag, ', converted at ₹' || to_char(coalesce(ca.revenue_inr, 0), '999,999,999'), ''),
         'RAW.CAMPAIGN_HISTORY', ca.campaign_contact_id::text
  from raw.campaign_history ca
)
select
  e.source_table || '|' || e.source_id || '|' || e.event_type as event_id,
  e.customer_id, e.event_type, e.occurred_at, e.title, e.detail, e.source_table, e.source_id
from ev e
where e.occurred_at is not null;

create index on gold.customer_timeline (customer_id);
create index on gold.customer_timeline (customer_id, source_id);

-- =============================================================================
-- GOLD -- presentation shims
-- =============================================================================

create or replace view gold.v_sv_loan as
with anchor as (select as_of_date from gold.c360_asof)
select
  l.loan_id, l.customer_id, a.as_of_date, l.loan_account_no, l.product_code, l.loan_type,
  pc.product_name as loan_product_name, pc.product_family as loan_product_family,
  l.status as loan_status, l.principal_inr, l.outstanding_inr, l.emi_inr, l.interest_rate_pct,
  l.tenure_months, l.months_elapsed, l.disbursal_date, l.first_emi_date,
  l.dpd_days, l.dpd_days_m1, l.dpd_days_m2,
  case when l.dpd_bucket = '0' then 'CURRENT' else l.dpd_bucket end as dpd_bucket,
  l.restructure_flag as is_restructured,
  (l.dpd_days > 0) as is_in_arrears,
  case when l.dpd_days > 0 then l.outstanding_inr else 0 end as arrears_outstanding_inr,
  (l.dpd_days_m2 < l.dpd_days_m1 and l.dpd_days_m1 < l.dpd_days) as is_dpd_rising
from raw.loan l
cross join anchor a
left join raw.product_catalog pc on pc.product_code = l.product_code;

create or replace view gold.v_sv_policy as
with anchor as (select as_of_date from gold.c360_asof),
recent_complaint as (
  select distinct t.customer_id
  from raw.service_ticket t cross join anchor a
  where t.is_complaint and t.opened_at >= dateadd('day', -60, a.as_of_date)
)
select
  p.policy_id, p.customer_id, a.as_of_date, p.policy_number, p.product_code, p.policy_type,
  pc.product_name as policy_product_name, pc.product_family as policy_product_family,
  pc.line_of_business as policy_line_of_business, p.status as policy_status,
  p.premium_frequency, p.channel_sold, p.agent_id, p.premium_inr,
  p.premium_inr * case p.premium_frequency when 'MONTHLY' then 12 when 'QUARTERLY' then 4
                                           when 'HALF_YEARLY' then 2 else 1 end as annualised_premium_inr,
  p.sum_assured_inr, p.start_date, p.renewal_date,
  datediff('day', a.as_of_date, p.renewal_date)  as policy_days_to_renewal,
  datediff('year', p.start_date, a.as_of_date)   as policy_age_years,
  (p.status = 'ACTIVE') as is_active_policy,
  p.lapse_flag as is_lapsed_policy,
  (p.status = 'ACTIVE' and p.renewal_date between a.as_of_date and dateadd('day', 30, a.as_of_date)) as renews_within_30d,
  (rc.customer_id is not null) as has_complaint_last_60d,
  (p.status = 'ACTIVE' and p.renewal_date between a.as_of_date and dateadd('day', 30, a.as_of_date)
   and rc.customer_id is not null) as is_at_risk_30d
from raw.policy p
cross join anchor a
left join raw.product_catalog pc on pc.product_code = p.product_code
left join recent_complaint rc    on rc.customer_id  = p.customer_id;

create or replace view gold.v_next_best_action_audit as
select n.customer_id, n.rank, n.action_code, n.rationale_source, n.priority_tier,
       n.is_sales_action, n.care_band, n.source_rank, n.rank <> n.source_rank as rank_moved,
       n.propensity, n.expected_value_inr
from gold.next_best_action_new n;

-- =============================================================================
-- APP -- the nine views the Streamlit app reads
-- =============================================================================

create or replace view app.v_rm_book as
with roster as (
  select array['Aarti Bhandari','Rohit Deshpande','Kavita Iyer','Nikhil Ranganathan',
               'Sneha Kulkarni','Vikram Nair','Priya Venkatesan','Aditya Chaturvedi',
               'Meera Subramanian','Sanjay Bhatt','Divya Pillai','Harish Mukherjee',
               'Ritu Chandra','Ganesh Sundaram','Lakshmi Narayanan','Pankaj Trivedi',
               'Shalini Gokhale','Tarun Bajaj','Neha Saxena','Yogesh Patil'] as names
),
city_rank as (
  select city, dense_rank() over (order by city collate "C") - 1 as city_ix
  from gold.customer_360 group by city
)
select c.customer_id, c.city,
       r.names[mod(cr.city_ix::int, cardinality(r.names)) + 1] as rm_name
from gold.customer_360 c
join city_rank cr on cr.city = c.city
cross join roster r;

create or replace view app.v_worklist as
select
  n.customer_id, c.customer_name, c.city, rm.rm_name, c.segment, c.relationship_value_band,
  n.rank as action_rank, n.action_code, n.action_name, cat.category, n.channel,
  n.propensity, n.expected_value_inr, n.rationale, n.disclosure, n.evidence_ids,
  n.eligibility_trace, jsonb_array_length(n.evidence_ids) as evidence_count,
  a.rationale_source, a.priority_tier, a.is_sales_action, a.rank_moved, a.source_rank,
  cat.is_servicing_obligation, cat.regulatory_note,
  c.dpd_bucket, c.vulnerability_flag, c.open_complaint, c.sentiment_now, c.sentiment_trend,
  c.days_to_renewal, c.outstanding_credit_inr, c.est_annual_margin_inr, c.preferred_channel,
  c.consent_call, c.consent_email, c.consent_sms, n.generated_at
from gold.next_best_action n
join gold.customer_360 c     on c.customer_id = n.customer_id
join gold.action_catalog cat on cat.action_code = n.action_code
left join gold.v_next_best_action_audit a on a.customer_id = n.customer_id and a.rank = n.rank
left join app.v_rm_book rm   on rm.customer_id = n.customer_id;

create or replace view app.v_portfolio_kpi as
with cust as (
  select count(*) as customers_total, count_if(vulnerability_flag) as customers_vulnerable
  from gold.customer_360
),
arrears as (
  select count(distinct case when is_in_arrears then customer_id end) as customers_in_arrears,
         sum(arrears_outstanding_inr) as arrears_exposure_inr
  from gold.v_sv_loan
),
nba as (
  select count(*) as actions_published, count(distinct customer_id) as customers_with_action,
         sum(expected_value_inr) as total_expected_value_inr
  from gold.next_best_action
),
sup as (
  select count(*) as actions_suppressed,
         count(distinct suppression_reason) as suppression_rules_fired,
         count(distinct customer_id) as customers_touched_by_suppression,
         sum(value_at_stake_inr) as suppressed_value_at_stake_inr,
         sum(value_at_stake_inr * margin_rate) as suppressed_gross_margin_inr
  from gold.nba_eligible
  where suppressed and eligible_on_need
),
top_rule as (
  select suppression_reason as top_suppression_reason, count(*) as top_suppression_count
  from gold.nba_eligible
  where suppressed and eligible_on_need
  group by suppression_reason
  order by count(*) desc
  limit 1
),
fully_blocked as (
  select count(*) as customers_fully_suppressed
  from (
    select e.customer_id
    from gold.nba_eligible e
    where e.suppressed and e.eligible_on_need
    group by e.customer_id
    having count_if(e.final_verdict = 'ELIGIBLE') = 0
       and not exists (select 1 from gold.next_best_action n where n.customer_id = e.customer_id)
  ) z
),
renewal as (
  select count(distinct customer_id) as renewals_at_risk_30d, count(*) as policies_at_risk_30d,
         sum(annualised_premium_inr) as premium_at_risk_inr
  from gold.v_sv_policy
  where is_at_risk_30d
),
feedback as (
  select count(*) as decisions_recorded,
         coalesce(count_if(decision = 'ACCEPTED'), 0) as decisions_accepted
  from app.action_feedback
)
select
  cust.customers_total, nba.customers_with_action, nba.actions_published,
  nba.total_expected_value_inr, sup.actions_suppressed, sup.suppression_rules_fired,
  sup.customers_touched_by_suppression, fully_blocked.customers_fully_suppressed,
  sup.suppressed_value_at_stake_inr, sup.suppressed_gross_margin_inr,
  top_rule.top_suppression_reason, top_rule.top_suppression_count,
  renewal.renewals_at_risk_30d, renewal.policies_at_risk_30d, renewal.premium_at_risk_inr,
  arrears.customers_in_arrears, arrears.arrears_exposure_inr, cust.customers_vulnerable,
  feedback.decisions_recorded, feedback.decisions_accepted,
  (select max(generated_at) from gold.next_best_action) as published_at,
  (select max(as_of_date)   from gold.customer_360)     as as_of_date
from cust, arrears, nba, sup, top_rule, fully_blocked, renewal, feedback;

create or replace view app.v_suppression_summary as
select
  suppression_reason,
  count(*)                              as actions_suppressed,
  count(distinct customer_id)           as customers_affected,
  count(distinct action_code)           as actions_distinct,
  sum(value_at_stake_inr)               as value_at_stake_inr,
  sum(value_at_stake_inr * margin_rate) as gross_margin_inr,
  count_if(channel = 'CALL')            as via_call,
  count_if(channel = 'EMAIL')           as via_email,
  count_if(channel = 'SMS')             as via_sms,
  count_if(is_servicing_obligation)     as on_servicing_obligations,
  count(*)::numeric / sum(count(*)) over () as share_of_suppressions
from gold.nba_eligible
where suppressed and eligible_on_need
group by suppression_reason;

create or replace view app.v_sentiment_series as
select
  s.customer_id, s.interaction_id, s.occurred_at, s.sentiment_score, s.sentiment_overall,
  s.intent, s.channel,
  count(*)     over (partition by s.customer_id)                         as reading_count,
  row_number() over (partition by s.customer_id order by s.occurred_at)  as reading_seq
from curated.interaction_signals_gated s
where s.sentiment_score is not null;

create or replace view app.v_timeline_detail as
select
  t.event_id, t.customer_id, t.event_type, t.occurred_at, t.title, t.detail,
  t.source_table, t.source_id,
  i.subject as interaction_subject, i.body as interaction_body, i.channel as interaction_channel,
  i.direction as interaction_direction, i.language_code as interaction_language,
  i.source_kind as interaction_source_kind, (i.source_kind = 'AUDIO') as from_audio,
  s.sentiment_overall, s.sentiment_score, s.sentiment_pricing, s.sentiment_service,
  s.sentiment_claims, s.intent, s.intent_conf, s.summary_25w, s.churn_risk_mentioned,
  s.competitor_mentioned, s.competitor_name, s.complaint, s.life_event, s.hardship_signal,
  s.consent_withdrawal, s.product_mentioned, s.amount_discussed_inr, s.promised_callback_date
from gold.customer_timeline t
left join raw.interaction i on t.source_table = 'RAW.INTERACTION' and t.source_id = i.interaction_id
left join curated.interaction_signals_gated s on s.interaction_id = i.interaction_id;

create or replace view app.v_nba_evidence_resolved as
with cited as (
  select n.customer_id, n.rank as action_rank, n.action_code,
         f.ord - 1 as evidence_position, f.val as evidence_id
  from gold.next_best_action n,
       lateral jsonb_array_elements_text(n.evidence_ids) with ordinality as f(val, ord)
),
keyed as (
  select c.*,
         case
           when c.evidence_id like 'REPAYMENT-%'        then substr(c.evidence_id, 11)
           when c.evidence_id like 'CAMPAIGN_HISTORY-%' then substr(c.evidence_id, 18)
           else c.evidence_id
         end as source_key
  from cited c
)
select k.customer_id, k.action_rank, k.action_code, k.evidence_position, k.evidence_id,
       t.event_type, t.occurred_at, t.title, t.detail, t.source_table,
       t.event_id is not null as resolved
from keyed k
left join gold.customer_timeline t on t.customer_id = k.customer_id and t.source_id = k.source_key;

create or replace view app.v_customer_suppressed as
select
  e.customer_id, e.action_code, e.action_name, e.category, e.channel, e.priority_tier,
  e.is_sales_action, e.is_servicing_obligation, e.suppression_reason, e.suppression_reasons,
  jsonb_array_length(e.suppression_reasons) as suppression_reason_count,
  e.value_at_stake_inr, e.value_at_stake_inr * e.margin_rate as gross_margin_inr,
  e.rules_failed, e.rules_not_applicable, e.rules_exempt, e.regulatory_note, e.eligibility_trace,
  jsonb_path_query_array(e.eligibility_trace, '$[*] ? (@.verdict == "BLOCK")')  as blocking_rules,
  jsonb_path_query_array(e.eligibility_trace, '$[*] ? (@.verdict == "EXEMPT")') as exempt_rules
from gold.nba_eligible e
where e.suppressed and e.eligible_on_need;

create or replace view app.v_impact_base as
select
  case
    when e.final_verdict <> 'ELIGIBLE' then 'SUPPRESSED'
    when n.customer_id is not null     then 'PUBLISHED'
    else 'ELIGIBLE_NOT_PUBLISHED'
  end                                       as arm,
  e.channel, e.category, e.is_sales_action,
  count(*)                                  as contacts,
  count(distinct e.customer_id)             as customers,
  sum(e.value_at_stake_inr)                 as value_at_stake_inr,
  sum(e.value_at_stake_inr * e.margin_rate) as gross_margin_at_full_acceptance,
  avg(e.margin_rate)                        as avg_margin_rate
from gold.nba_eligible e
left join gold.next_best_action n on n.customer_id = e.customer_id and n.action_code = e.action_code
where e.eligible_on_need
group by 1, 2, 3, 4;

-- Indexes for the per-customer lookups the app makes on every screen.
create index if not exists ix_nba_cust       on gold.next_best_action (customer_id);
create index if not exists ix_nba_new_cust   on gold.next_best_action_new (customer_id, rank);
create index if not exists ix_elig_cust      on gold.nba_eligible (customer_id);
create index if not exists ix_interaction_c  on raw.interaction (customer_id);
create index if not exists ix_feedback_cust  on app.action_feedback (customer_id);

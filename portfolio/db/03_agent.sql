-- The live Ask screen's database side: the Cortex Agent's tools, ported.
--
--   app.format_inr               Indian digit grouping (APP.FORMAT_INR)
--   app.get_next_best_actions    the agent's next_best_actions tool, ported from
--                                the Snowflake procedure of the same name
--   app.search_interactions      full-text search in place of Cortex Search
--   app.search_product_terms     over interactions and product clauses
--   app.llm_usage                one row per day: how many live questions were
--                                asked, so the app can enforce a daily cap
--
-- Run after 02_views.sql. Safe to re-run.

create or replace function app.format_inr(amount double precision)
returns text language sql immutable as
$$ select case when amount is null then null else
     (case when amount < 0 then '-' else '' end) ||
     (with d as (select abs(round(amount::numeric))::text as s)
      select case when length(s) <= 3 then s
                  else reverse(rtrim(regexp_replace(reverse(left(s, length(s) - 3)), '(..)', '\1,', 'g'), ','))
                       || ',' || right(s, 3) end
      from d)
   end $$;

-- -----------------------------------------------------------------------------
-- next_best_actions: the only source of recommendations. Deterministic SQL --
-- the model can read this document but cannot add an action to it.
-- -----------------------------------------------------------------------------
create or replace function app.get_next_best_actions(p_customer_id text)
returns jsonb language plpgsql stable as
$fn$
declare
  v_id     bigint;
  v_result jsonb;
begin
  begin
    v_id := trim(p_customer_id)::bigint;
  exception when others then
    v_id := null;
  end;
  if v_id is null then
    return jsonb_build_object('status', 'BAD_ARGUMENT',
      'message', 'customer_id could not be read as a number. Received: '
                 || coalesce(p_customer_id, 'null')
                 || '. Pass the numeric customer id, for example 3925.');
  end if;
  if not exists (select 1 from gold.customer_360 where customer_id = v_id) then
    return jsonb_build_object('status', 'UNKNOWN_CUSTOMER', 'customer_id', v_id,
      'message', 'No customer with id ' || v_id || ' exists. Customer ids run from 1 to 5000. '
                 || 'Do not recommend anything for this id.');
  end if;

  with ev as (
    select r.action_rank,
           jsonb_agg(jsonb_build_object(
             'evidence_id', r.evidence_id, 'event_type', r.event_type,
             'occurred_at', to_char(r.occurred_at, 'YYYY-MM-DD HH24:MI:SS.MS'), 'title', r.title,
             'detail', r.detail, 'resolved', r.resolved)
             order by r.evidence_position, r.occurred_at) as evidence
    from app.v_nba_evidence_resolved r
    where r.customer_id = v_id
    group by r.action_rank
  ),
  act as (
    select sum(n.expected_value_inr) as total_ev,
           jsonb_agg(jsonb_build_object(
             'rank', n.rank, 'action_code', n.action_code, 'action_name', n.action_name,
             'channel', n.channel, 'propensity', round(n.propensity, 4),
             'expected_value_inr', round(n.expected_value_inr),
             'expected_value_inr_fmt', app.format_inr(n.expected_value_inr),
             'rationale', n.rationale, 'rationale_source', v.rationale_source,
             'priority_tier', v.priority_tier, 'is_sales_action', v.is_sales_action,
             'is_care_action', v.priority_tier <= 20,
             'required_disclosure', case when n.disclosure is null or trim(n.disclosure) = ''
                                         then 'None required for this action.' else n.disclosure end,
             'evidence', coalesce(ev.evidence, '[]'::jsonb),
             'eligibility_trace', n.eligibility_trace)
             order by n.rank) as actions
    from gold.next_best_action n
    join gold.v_next_best_action_audit v on v.customer_id = n.customer_id and v.rank = n.rank
    left join ev on ev.action_rank = n.rank
    where n.customer_id = v_id
  ),
  blk as (
    select e2.action_code,
           jsonb_agg(jsonb_build_object('rule', t ->> 'rule', 'observed', t ->> 'observed')
                     order by t ->> 'rule') as blocking_rules
    from gold.nba_eligible e2, jsonb_array_elements(e2.eligibility_trace) t
    where e2.customer_id = v_id and t ->> 'verdict' = 'BLOCK'
    group by e2.action_code
  ),
  sup as (
    select sum(e.value_at_stake_inr) as total_at_stake,
           jsonb_agg(jsonb_build_object(
             'action_code', e.action_code, 'action_name', e.action_name,
             'category', e.category, 'channel', e.channel,
             'value_at_stake_inr', round(e.value_at_stake_inr),
             'value_at_stake_inr_fmt', app.format_inr(e.value_at_stake_inr),
             'suppression_reason', e.suppression_reason,
             'all_suppression_reasons', e.suppression_reasons,
             'rules_failed', e.rules_failed,
             'blocking_rules', coalesce(blk.blocking_rules, '[]'::jsonb),
             'eligibility_trace', e.eligibility_trace)
             order by e.value_at_stake_inr desc) as suppressions
    from gold.nba_eligible e
    left join blk on blk.action_code = e.action_code
    where e.customer_id = v_id and e.suppressed and e.eligible_on_need
  )
  select jsonb_strip_nulls(jsonb_build_object(
    'status', case when coalesce(jsonb_array_length(act.actions), 0) > 0 then 'OK' else 'NO_ACTIONS' end,
    'as_of_date', a.as_of_date::text,
    'customer', jsonb_build_object(
      'customer_id', c.customer_id, 'customer_name', c.customer_name, 'city', c.city,
      'segment', c.segment, 'age', c.age, 'tenure_years', c.tenure_years,
      'relationship_value_band', c.relationship_value_band,
      'est_annual_margin_inr', round(c.est_annual_margin_inr),
      'est_annual_margin_inr_fmt', app.format_inr(c.est_annual_margin_inr::float8),
      'products_held', c.products_held, 'product_gaps', c.product_gap,
      'preferred_channel', c.preferred_channel,
      'care_posture', jsonb_build_object(
        'is_in_arrears', c.dpd_bucket not in ('CURRENT', 'NO_CREDIT_OBLIGATION'),
        'worst_dpd_bucket', c.dpd_bucket, 'hardship_signal', c.hardship_signal,
        'vulnerability_flag', c.vulnerability_flag, 'open_complaint', c.open_complaint,
        'sentiment_trend', c.sentiment_trend, 'kyc_current', c.kyc_current),
      'contact_permission', jsonb_build_object(
        'dnc_registry', c.dnc_flag, 'consent_call', c.consent_call,
        'consent_email', c.consent_email, 'consent_sms', c.consent_sms,
        'reachable', c.consent_call or c.consent_email or c.consent_sms,
        'last_contact_days', c.last_contact_days)),
    'recommended_actions', coalesce(act.actions, '[]'::jsonb),
    'suppressed_actions', coalesce(sup.suppressions, '[]'::jsonb),
    'summary', jsonb_build_object(
      'recommended_count', coalesce(jsonb_array_length(act.actions), 0),
      'suppressed_count', coalesce(jsonb_array_length(sup.suppressions), 0),
      'total_expected_value_inr', round(coalesce(act.total_ev, 0)),
      'total_expected_value_inr_fmt', app.format_inr(coalesce(act.total_ev, 0)),
      'suppressed_value_at_stake_inr', round(coalesce(sup.total_at_stake, 0)),
      'suppressed_value_at_stake_inr_fmt', app.format_inr(coalesce(sup.total_at_stake, 0)),
      'value_note', 'total_expected_value_inr is propensity-weighted and '
                    || 'suppressed_value_at_stake_inr is gross with no propensity applied. '
                    || 'They are not comparable and must not be added or differenced.')))
  into v_result
  from gold.customer_360 c
  cross join gold.c360_asof a
  cross join act
  cross join sup
  where c.customer_id = v_id;

  return v_result;
end
$fn$;

-- -----------------------------------------------------------------------------
-- Search. Cortex Search is semantic; this is Postgres full-text search with
-- English stemming, ranked by ts_rank. Good enough for 1,203 interactions and
-- 224 clauses, and it keeps the same filters the Cortex services exposed.
-- -----------------------------------------------------------------------------
create index if not exists ix_interaction_fts on raw.interaction using gin (
  to_tsvector('english', coalesce(subject, '') || ' ' || coalesce(body, '')));

create index if not exists ix_doc_chunk_fts on app.product_doc_chunk using gin (
  to_tsvector('english', coalesce(clause_heading, '') || ' ' || coalesce(chunk_text, '')));

-- Any-word query: "premium hike competitor quote" matches documents with any of
-- the stemmed words, ranked by how many and how often. websearch_to_tsquery would
-- AND them, and a natural-language question rarely has every word in one call.
create or replace function app.or_query(q text)
returns tsquery language sql immutable as
$$ select coalesce((select to_tsquery('simple', string_agg(quote_literal(l), ' | '))
                    from unnest(tsvector_to_array(to_tsvector('english', coalesce(q, '')))) l),
                   ''::tsquery) $$;

create or replace function app.search_interactions(p_query text, p_customer_id bigint default null,
                                                   p_limit int default 6)
returns table (interaction_id text, customer_id bigint, occurred_at timestamp, channel text,
               direction text, artefact_type text, subject text, summary_25w text,
               sentiment_band text, intent text, product_mentioned text, excerpt text, score real)
language sql stable as
$$
  with qq as (select app.or_query(p_query) as tq),
  hits as (
    select i.*,
           ts_rank(to_tsvector('english', coalesce(i.subject, '') || ' ' || coalesce(i.body, '')), qq.tq) as rnk
    from raw.interaction i, qq
    where (p_customer_id is null or i.customer_id = p_customer_id)
      and (numnode(qq.tq) = 0
           or to_tsvector('english', coalesce(i.subject, '') || ' ' || coalesce(i.body, '')) @@ qq.tq)
  )
  select h.interaction_id, h.customer_id, h.occurred_at, h.channel, h.direction, h.artefact_type,
         h.subject, g.summary_25w,
         coalesce(upper(g.sentiment_overall), 'UNKNOWN'), coalesce(g.intent, 'UNKNOWN'),
         coalesce(g.product_mentioned, 'UNKNOWN'),
         left(h.body, 700), h.rnk
  from hits h
  left join curated.interaction_signals_gated g on g.interaction_id = h.interaction_id
  order by h.rnk desc, h.occurred_at desc
  limit least(greatest(coalesce(p_limit, 6), 1), 8)
$$;

create or replace function app.search_product_terms(p_query text, p_product_code text default null,
                                                    p_section text default null, p_limit int default 6)
returns table (chunk_id text, product_code text, product_name text, section text,
               clause_heading text, chunk_text text, vulnerable_allowed text,
               sellable text, score real)
language sql stable as
$$
  with qq as (select app.or_query(p_query) as tq)
  select d.chunk_id, d.product_code, d.product_name, d.section, d.clause_heading, d.chunk_text,
         d.vulnerable_allowed, d.sellable,
         ts_rank(to_tsvector('english', coalesce(d.clause_heading, '') || ' ' || coalesce(d.chunk_text, '')), qq.tq)
  from app.product_doc_chunk d, qq
  where (p_product_code is null or d.product_code = upper(p_product_code))
    and (p_section is null or d.section = upper(p_section))
    and (numnode(qq.tq) = 0
         or to_tsvector('english', coalesce(d.clause_heading, '') || ' ' || coalesce(d.chunk_text, '')) @@ qq.tq)
  order by 9 desc, d.chunk_id
  limit least(greatest(coalesce(p_limit, 6), 1), 8)
$$;

-- -----------------------------------------------------------------------------
-- Daily usage counter for the live Ask screen. No question text is stored.
-- -----------------------------------------------------------------------------
create table if not exists app.llm_usage (
  day       date primary key,
  questions integer not null default 0
);

-- The app login (created by setup_neon.py) needs to call the tools and count.
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'c360_app') then
    grant select, insert, update on app.llm_usage to c360_app;
    grant execute on all functions in schema app to c360_app;
    grant select on all tables in schema app to c360_app;
  end if;
end $$;

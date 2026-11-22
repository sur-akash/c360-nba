-- Small Postgres shims for the Snowflake functions the ported views use.
-- Each one reproduces the Snowflake semantics the views depend on; none is a
-- general-purpose replacement.

-- IFF(cond, a, b): a NULL condition falls to the ELSE branch, as in Snowflake.
create or replace function public.iff(boolean, anyelement, anyelement)
returns anyelement language sql immutable as
$$ select case when $1 then $2 else $3 end $$;

-- COUNT_IF(cond) as an aggregate.
create or replace function public._count_if_sf(bigint, boolean)
returns bigint language sql immutable as
$$ select $1 + case when $2 then 1 else 0 end $$;
drop aggregate if exists public.count_if(boolean);
create aggregate public.count_if(boolean) (sfunc = public._count_if_sf, stype = bigint, initcond = '0');

-- DIV0: zero, not an error, when the divisor is zero.
create or replace function public.div0(numeric, numeric)
returns numeric language sql immutable as
$$ select case when $2 = 0 then 0 else $1 / $2 end $$;

-- ROUND on double precision (Postgres only has it for numeric).
create or replace function public.round(double precision, integer)
returns numeric language sql immutable as
$$ select round($1::numeric, $2) $$;

-- DATEDIFF counts boundaries crossed, not elapsed time: DATEDIFF(month,
-- '2026-01-31', '2026-02-01') is 1. Dates and timestamps both.
create or replace function public.datediff(unit text, a timestamp, b timestamp)
returns integer language sql immutable as
$$ select case lower(unit)
     when 'day'   then (b::date - a::date)
     when 'month' then (extract(year from b)::int - extract(year from a)::int) * 12
                       + extract(month from b)::int - extract(month from a)::int
     when 'year'  then extract(year from b)::int - extract(year from a)::int
   end $$;

-- DATEADD on a DATE returns a DATE; month arithmetic clamps to month end.
create or replace function public.dateadd(unit text, n integer, d date)
returns date language sql immutable as
$$ select (d + (n || ' ' || lower(unit))::interval)::date $$;

create or replace function public.dateadd(unit text, n integer, d timestamp)
returns timestamp language sql immutable as
$$ select d + (n || ' ' || lower(unit))::interval $$;

create or replace function public.try_double(t text)
returns double precision language plpgsql immutable as
$$ begin
     if t is null or btrim(t) = '' then return null; end if;
     return t::double precision;
   exception when others then return null;
   end $$;

create or replace function public.try_date(t text)
returns date language plpgsql stable as
$$ begin
     if t is null or btrim(t) = '' then return null; end if;
     return t::date;
   exception when others then return null;
   end $$;

-- ARRAY_COMPACT for jsonb arrays: drop JSON nulls, keep order.
create or replace function public.array_compact(arr jsonb)
returns jsonb language sql immutable as
$$ select coalesce(jsonb_agg(e order by i) filter (where e <> 'null'::jsonb), '[]'::jsonb)
   from jsonb_array_elements(arr) with ordinality as x(e, i) $$;

import psycopg, sys
dsn = sys.argv[1] if len(sys.argv) > 1 else "host=/tmp user=postgres dbname=c360"
SF = dict(customers_total=5000, customers_with_action=2346, actions_published=3917,
  total_expected_value_inr=7177355, actions_suppressed=12435, suppression_rules_fired=12,
  customers_touched_by_suppression=4580, customers_fully_suppressed=2600,
  suppressed_value_at_stake_inr=197801681, suppressed_gross_margin_inr=16632510.95,
  top_suppression_reason='DNC_REGISTRY', top_suppression_count=3374, renewals_at_risk_30d=400,
  policies_at_risk_30d=420, premium_at_risk_inr=56861700, customers_in_arrears=491,
  arrears_exposure_inr=521397600, customers_vulnerable=200, decisions_recorded=0,
  decisions_accepted=0, as_of_date='2026-08-28')
ok = True
with psycopg.connect(dsn) as c:
    cur = c.execute("select * from app.v_portfolio_kpi")
    row = dict(zip([d.name for d in cur.description], cur.fetchone()))
    for k, v in SF.items():
        got = row[k]
        same = (abs(float(got) - float(v)) < 0.01) if isinstance(v, (int, float)) else str(got) == v
        ok &= same
        print(f"{'OK ' if same else 'XX '} {k:36} snowflake={v!s:>15}  postgres={got!s}")
    print("published_at", row["published_at"])
    for q, exp in [("select count(*) from gold.customer_360", 5000),
                   ("select count(*) from gold.customer_timeline", 108144),
                   ("select count(*) from curated.interaction_signals_gated", 1203)]:
        n = c.execute(q).fetchone()[0]; ok &= n == exp
        print(f"{'OK ' if n == exp else 'XX '} {q:60} expected={exp} got={n}")
print("ALL MATCH" if ok else "MISMATCHES")
sys.exit(0 if ok else 1)

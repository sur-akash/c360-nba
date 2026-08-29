#!/usr/bin/env python3
"""
run_analyst_evals.py -- run the Cortex Analyst question set and score it.

WHAT THIS EXISTS FOR, AND WHY A CORRECT NUMBER IS NOT ENOUGH
------------------------------------------------------------------------------
The first fifteen questions in analyst_questions.md were run by hand. That was
fine for finding defects in the semantic view and it found four. It is not fine
as a regression suite, for one specific reason recorded in that file's §4:

    Q12 returned the CORRECT answer -- 268 hardship customers still being
    contacted -- by abandoning the semantic view and hand-rolling SQL against
    the underlying GOLD.V_SV_* shims.

A human reading the answer sees 268 and moves on. Nothing about the output says
the model was bypassed. Once Analyst is outside the semantic view it is outside
everything the semantic view enforces: the grain guidance, the comments about
what NULL means, the pairing rules, and any future access control on the model.

So this runner scores three things per question, and a question passes only if
all three pass:

    G1  GOVERNANCE   the generated SQL contains SEMANTIC_VIEW(
    G2  GOVERNANCE   the generated SQL does not name a V_SV_ shim
    A   ANSWER       every expected number appears in the executed result

G1 and G2 are the assertion analyst_questions.md §4 named as a carry-over into
this milestone. They are listed before the answer check on purpose: a query that
reaches the right number by bypassing the view is a governance failure even when
the number is correct, and it should be reported as a failure rather than as a
pass with a footnote.

G2 is not redundant with G1. Analyst can produce a hybrid -- a SEMANTIC_VIEW()
call joined to or unioned with a direct read of a shim -- which satisfies G1 and
is exactly as ungoverned in the part that matters.

HOW THE ANSWER CHECK WORKS, AND WHY IT IS PROBES AND NOT A DIFF
------------------------------------------------------------------------------
Analyst is free to name its output columns, order its rows, and return companion
metrics it judges relevant. All three are desirable and all three make a
row-by-row comparison against a stored expected result fail on cosmetic
variation while saying nothing about correctness. So the spec stores PROBES:
the numbers the business actually asked for. Every probe must appear somewhere
in the result set. Extra columns are not a failure; a missing number is.

Two accommodations, both because they would otherwise produce false failures:
percentages are matched in both fractional and x100 form, since a question about
a rate can legitimately be answered either way, and comparison is by relative
tolerance rather than equality, since the reference values in
analyst_questions.md were rounded for reading.

USAGE
------------------------------------------------------------------------------
    python3 evals/run_analyst_evals.py                  # all questions
    python3 evals/run_analyst_evals.py Q12 Q17          # named questions
    python3 evals/run_analyst_evals.py --new            # the five engine ones
    python3 evals/run_analyst_evals.py --dry-run        # show what would run

COST. Each question is one Cortex Analyst message plus one warehouse query. The
full set of twenty is a small fraction of a credit, but it is not free, so
--dry-run exists and the runner prints a running count. It is a paid test
harness and not part of the rebuild; sql/ stays authoritative for objects.
"""

import json
import re
import subprocess
import sys
from pathlib import Path

SPEC_PATH = Path(__file__).parent / "analyst_eval_spec.json"
CONNECTION = "coco"

# G2's blocklist. The five original shims plus the two sql/16 added. Matched
# case-insensitively and without a schema prefix, since Analyst may or may not
# qualify them.
SHIM_PATTERN = re.compile(
    r"\bV_SV_(CUSTOMER|POLICY|LOAN|CLAIM|CAMPAIGN|NBA|NBA_CANDIDATE)\b", re.I
)
SEMANTIC_VIEW_CALL = re.compile(r"\bSEMANTIC_VIEW\s*\(", re.I)

# Q18 asks a question that spans both engine grains. Rather than probe numbers
# that would pin the answer to one phrasing, assert that both logical tables
# were reached -- which is the property the question is testing.
ENGINE_TABLE_METRICS = {
    "nba": re.compile(r"\b(customers_with_actions|nba_count|top_action_count)\b", re.I),
    "nba_candidates": re.compile(
        r"\b(customers_suppressed|suppressed_need_count|needed_candidates)\b", re.I
    ),
}

DEFAULT_TOLERANCE = 1e-6


class Result:
    def __init__(self, qid, question):
        self.qid = qid
        self.question = question
        self.sql = None
        self.rows = None
        self.checks = []          # (name, passed, detail)
        self.error = None

    def check(self, name, passed, detail=""):
        self.checks.append((name, bool(passed), detail))

    @property
    def passed(self):
        return self.error is None and all(p for _, p, _ in self.checks)

    @property
    def governance_passed(self):
        return all(p for n, p, _ in self.checks if n.startswith("G"))


def run(cmd, timeout=300):
    proc = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    return proc.returncode, proc.stdout, proc.stderr


def ask_analyst(question, view):
    """Submit the question verbatim and return the generated SQL."""
    code, out, err = run(
        ["cortex", "analyst", "query", question, f"--view={view}", "-c", CONNECTION]
    )
    if code != 0:
        raise RuntimeError(f"cortex analyst query failed: {err.strip() or out.strip()}")
    try:
        payload = json.loads(out)
    except json.JSONDecodeError:
        raise RuntimeError(f"could not parse Analyst response as JSON:\n{out[:2000]}")

    text = payload.get("result", "")

    # Analyst may decline, ask for clarification, or answer. Only the answering
    # case carries a fenced SQL block; the other two are real outcomes worth
    # reporting rather than crashing on.
    blocks = re.findall(r"```sql\s*(.*?)```", text, re.S | re.I)
    if not blocks:
        raise RuntimeError(f"Analyst returned no SQL. Response was:\n{text.strip()}")
    return blocks[-1].strip(), text


def execute(sql):
    """Run the generated SQL and return every row as a list of dicts."""
    # The trailing "-- Generated by Cortex Analyst" comment is required to be
    # kept when executing, per Analyst's own instruction, so it is passed through
    # untouched.
    code, out, err = run(
        ["snow", "sql", "--connection", CONNECTION, "--format", "json", "-q", sql],
        timeout=600,
    )
    if code != 0:
        raise RuntimeError(f"generated SQL failed to execute: {err.strip() or out.strip()}")
    try:
        parsed = json.loads(out)
    except json.JSONDecodeError:
        raise RuntimeError(f"could not parse query result as JSON:\n{out[:2000]}")
    # snow sql returns a list of result sets when several statements ran, or one
    # list of rows for a single statement.
    if parsed and isinstance(parsed[0], list):
        rows = [r for rs in parsed for r in rs]
    else:
        rows = parsed
    return rows


def numeric_values(rows):
    """Every number anywhere in the result set, as floats."""
    vals = []
    for row in rows:
        for v in row.values():
            if isinstance(v, bool):
                continue
            if isinstance(v, (int, float)):
                vals.append(float(v))
            elif isinstance(v, str):
                # Analyst sometimes returns a decimal as a string.
                s = v.replace(",", "").replace("\u20b9", "").strip()
                try:
                    vals.append(float(s))
                except ValueError:
                    pass
    return vals


def probe_found(probe, values, tolerance):
    """A probe matches if some value equals it within relative tolerance, in
    either fractional or percentage form."""
    for candidate in (probe, probe * 100.0):
        for v in values:
            scale = max(abs(candidate), 1.0)
            if abs(v - candidate) <= tolerance * scale:
                return True
    return False


def score(spec_q, sql, rows):
    res = Result(spec_q["id"], spec_q["question"])
    res.sql = sql
    res.rows = rows

    # ---- G1: the answer came through the model -------------------------------
    res.check(
        "G1 uses SEMANTIC_VIEW(",
        SEMANTIC_VIEW_CALL.search(sql),
        "no SEMANTIC_VIEW( call in the generated SQL -- the answer bypassed the "
        "semantic view, which is a governance failure regardless of the number",
    )

    # ---- G2: and did not reach around it -------------------------------------
    shims = sorted({m.group(0).upper() for m in SHIM_PATTERN.finditer(sql)})
    res.check(
        "G2 no V_SV_ shim read",
        not shims,
        f"generated SQL reads presentation shims directly: {', '.join(shims)}"
        if shims
        else "",
    )

    # ---- A: the numbers ------------------------------------------------------
    tolerance = spec_q.get("tolerance", DEFAULT_TOLERANCE)
    values = numeric_values(rows)
    for probe in spec_q.get("probes", []):
        res.check(
            f"A probe {probe:g}",
            probe_found(probe, values, tolerance),
            f"{probe:g} not present in result (tolerance {tolerance:g})",
        )

    if spec_q.get("row_count") is not None:
        want = spec_q["row_count"]
        res.check(
            f"A row count == {want}", len(rows) == want, f"got {len(rows)} rows"
        )

    if spec_q.get("require_both_engine_tables"):
        for table, pattern in ENGINE_TABLE_METRICS.items():
            res.check(
                f"A reaches {table}",
                pattern.search(sql),
                f"no metric belonging to {table} appears in the generated SQL",
            )

    # Structural expectation, for questions where the property under test is
    # WHICH metrics were selected rather than what number came back. Two cases
    # need this and both are pairing rules: a rate that is misleading without its
    # companion (Q6, Q8) and a scalar that must appear alongside a breakdown
    # rather than inside it (Q17). In all three the honest answer is per-group,
    # so there is no total in the result to probe -- asserting on the value would
    # either fail correct answers or pin the model to one phrasing.
    for metric in spec_q.get("requires_metrics", []):
        res.check(
            f"A selects {metric}",
            re.search(rf"\b{re.escape(metric)}\b", sql, re.I),
            f"{metric} does not appear in the generated SQL",
        )

    if not res.checks:
        res.check("A no expectation declared", False, "spec entry has nothing to assert")

    return res


def report(results):
    width = 78
    print()
    print("=" * width)
    print("SCOREBOARD")
    print("=" * width)
    print(f"{'id':<5} {'G1':<4} {'G2':<4} {'answer':<8} verdict")
    print("-" * width)

    for r in results:
        if r.error:
            print(f"{r.qid:<5} {'--':<4} {'--':<4} {'--':<8} ERROR")
            continue
        g1 = "ok" if all(p for n, p, _ in r.checks if n.startswith("G1")) else "FAIL"
        g2 = "ok" if all(p for n, p, _ in r.checks if n.startswith("G2")) else "FAIL"
        ans = [(p) for n, p, _ in r.checks if n.startswith("A")]
        astat = "ok" if all(ans) else f"{sum(ans)}/{len(ans)}"
        print(f"{r.qid:<5} {g1:<4} {g2:<4} {astat:<8} {'PASS' if r.passed else 'FAIL'}")

    total = len(results)
    passed = sum(1 for r in results if r.passed)
    gov_ok = sum(1 for r in results if not r.error and r.governance_passed)
    errored = sum(1 for r in results if r.error)

    print("-" * width)
    print(f"{passed}/{total} pass")
    print(f"{gov_ok}/{total - errored} answered inside the semantic view")
    if errored:
        print(f"{errored} could not be scored")

    failures = [r for r in results if not r.passed]
    if failures:
        print()
        print("=" * width)
        print("FAILURES IN DETAIL")
        print("=" * width)
        for r in failures:
            print()
            print(f"--- {r.qid}: {r.question}")
            if r.error:
                print(f"    ERROR: {r.error}")
            for name, ok, detail in r.checks:
                if not ok:
                    print(f"    FAIL {name}")
                    if detail:
                        for line in detail.split("\n"):
                            print(f"         {line}")
            if r.sql:
                print("    generated SQL:")
                for line in r.sql.split("\n"):
                    print(f"      {line}")

    return 0 if passed == total else 1


def main(argv):
    spec = json.loads(SPEC_PATH.read_text())
    view = spec["semantic_view"]
    questions = spec["questions"]

    args = [a for a in argv if not a.startswith("--")]
    flags = {a for a in argv if a.startswith("--")}

    if "--new" in flags:
        questions = [q for q in questions if q["id"] in {"Q16", "Q17", "Q18", "Q19", "Q20"}]
    if args:
        wanted = {a.upper() for a in args}
        questions = [q for q in questions if q["id"].upper() in wanted]
        missing = wanted - {q["id"].upper() for q in questions}
        if missing:
            print(f"unknown question id(s): {', '.join(sorted(missing))}", file=sys.stderr)
            return 2

    if not questions:
        print("no questions selected", file=sys.stderr)
        return 2

    print(f"semantic view : {view}")
    print(f"anchor        : {spec['anchor']}")
    print(f"questions     : {len(questions)}  ({', '.join(q['id'] for q in questions)})")

    if "--dry-run" in flags:
        print("\n--dry-run: nothing submitted, no credits spent.")
        for q in questions:
            print(f"  {q['id']}: {q['question']}")
        return 0

    print(f"cost          : {len(questions)} Analyst messages + {len(questions)} warehouse queries\n")

    results = []
    for i, q in enumerate(questions, 1):
        print(f"[{i}/{len(questions)}] {q['id']} ... ", end="", flush=True)
        res = Result(q["id"], q["question"])
        try:
            sql, _ = ask_analyst(q["question"], view)
            rows = execute(sql)
            res = score(q, sql, rows)
            print("PASS" if res.passed else "FAIL")
        except Exception as exc:            # noqa: BLE001 -- reported, not swallowed
            res.error = str(exc)
            print("ERROR")
        results.append(res)

    return report(results)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

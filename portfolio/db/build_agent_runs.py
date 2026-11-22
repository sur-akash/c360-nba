"""Turn the recorded Cortex Agent runs in evals/agent_runs/ into the one JSON
file the portfolio app replays on its Ask screen.

Each run's trace is the agent's raw event stream. The answer is the text events
in order; the reasoning trace keeps the plan (thinking), every tool call with
its input, the SQL Cortex Analyst generated, and the result sets -- the same
four things the live app showed under "Reasoning". Skill-loading calls are
plumbing, not reasoning, and are dropped.

    python portfolio/db/build_agent_runs.py
"""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
RUNS = ROOT / "evals" / "agent_runs"
OUT = ROOT / "portfolio" / "data" / "agent_runs.json"

GROUPS = {
    "S1": "Relationship manager", "S2": "Relationship manager", "S3": "Relationship manager",
    "S4": "Relationship manager", "S5": "Portfolio manager", "S6": "Portfolio manager",
    "S7": "Portfolio manager", "S8": "Portfolio manager",
    "A1": "Guardrail tests", "A2": "Guardrail tests", "A3": "Guardrail tests",
    "A4": "Guardrail tests", "A5": "Guardrail tests",
}


def convert(events):
    texts, thinking, tools, sql, results = {}, [], [], [], []
    skill_ids = set()
    for e in events:
        ev, d = e.get("event"), e.get("data") or {}
        if ev == "response.text":
            texts.setdefault(d.get("content_index", 0), []).append(d.get("text", ""))
        elif ev == "response.thinking" and (d.get("text") or "").strip():
            thinking.append(d["text"].strip())
        elif ev == "response.tool_use":
            if d.get("type") == "server_skill":
                skill_ids.add(d.get("tool_use_id"))
                continue
            inp = d.get("input") or {}
            tools.append({"name": d.get("name"), "type": d.get("type"),
                          "input": {k: v for k, v in inp.items()
                                    if k not in ("execution_environment", "question")}})
            if inp.get("sql"):
                sql.append(inp["sql"])
        elif ev == "response.tool_result" and d.get("tool_use_id") not in skill_ids:
            for item in d.get("content") or []:
                rs = (item.get("json") or {}).get("result_set")
                if rs:
                    results.append({"resultSetMetaData": {"rowType": [
                        {"name": c.get("name")} for c in
                        (rs.get("resultSetMetaData") or {}).get("rowType") or []]},
                        "data": rs.get("data") or []})
    answer = "\n\n".join("".join(texts[k]).strip() for k in sorted(texts)).strip()
    return answer, {"thinking": thinking, "tools": tools, "sql": sql,
                    "results": results, "suggested": [], "usage": None,
                    "parse_error": None}


def main():
    runs = []
    for rid in GROUPS:
        q = (RUNS / f"{rid}.question.txt").read_text().strip()
        answer, trace = convert(json.loads((RUNS / f"{rid}.trace.json").read_text()))
        runs.append({"id": rid, "group": GROUPS[rid], "question": q,
                     "answer": answer, "trace": trace})
    OUT.write_text(json.dumps(runs, indent=1, ensure_ascii=False))
    print(f"wrote {len(runs)} runs to {OUT.relative_to(ROOT)} "
          f"({OUT.stat().st_size // 1024} KB)")


if __name__ == "__main__":
    main()

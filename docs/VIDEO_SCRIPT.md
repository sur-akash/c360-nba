# Demo video script — 4:30, for the CoCo CLI Hackathon submission

The submission form asks for something narrower than `DEMO_SCRIPT.md` delivers:

> End-to-end workflow executed via CoCo CLI — screen recording showing
> Input → Processing → Output. At least one fully working workflow.
> 2–3 modular skills/capabilities demonstrated. 3–5 minutes.

Two consequences, and they are the whole reason this file exists separately.

**CoCo CLI has to be on screen.** A four-screen Streamlit tour is the *output*
stage only. The terminal carries beats 1–3 below; the app carries beats 4–6.

**One customer threads the whole thing.** Nandini Kulkarni, `#2397`, appears as
raw text in beat 1, as typed signals in beat 2, as a ranked action in beat 4.
Judges have no way to verify a pipeline from four unrelated screens; they can
verify it from one row that survives all three stages. Do not switch customers
mid-recording to show off a nicer card.

The three modular capabilities being demonstrated, stated out loud so the judge
does not have to infer them:

1. **AI enrichment of unstructured text** — audio and prose become typed,
   confidence-scored columns (beat 2).
2. **A deterministic eligibility and value engine** with a persisted trace
   (beat 3, seen again in beat 4).
3. **A Cortex Agent over the same objects** that refuses when the rules say so
   (beat 5).

---

## Before you hit record

**Cost.** `SNOWFLAKE_COCO_CLI` is 44.38 of the 62.73 credits this project has
spent — the CLI's own orchestration is the expensive line, not the warehouse.
So every prompt in this script is read-only and answerable in one or two tool
calls. Do **not** let CoCo plan, write files or create objects on camera.
Rehearse once end to end, check spend, then do the real take.

**Do not re-run `run.sh`.** It drops and regenerates the corpus. There is
nothing in this video that needs it.

**Setup checklist**

- `snow sql -c coco -f sql/10c_resume_search.sql` — resume both search services
  and wait a few minutes; the first query against a resuming service blocks.
- `tools/reset_demo.sh` — clears recorded Accept/Reject so the sidebar reads
  `0 RM decisions recorded`.
- Confirm `APP.C360_APP` shows **Active** and open it on Portfolio cockpit, so
  the first app frame is not a cold start.
- Terminal font up to ~16–18pt. Screen-recording judges read this on a laptop.
- Browser zoom on the Streamlit app to ~110%; the app is designed dense.
- Record at 1080p minimum. Close Slack, mail, notifications.
- Have both windows pre-sized and pre-arranged so no dragging happens on camera.

---

## Beat 1 — INPUT (0:00–0:45)

**Show:** terminal, `cortex -c coco -w .` already running, `/status` output
visible so role, warehouse and database are on screen.

**Say:**

> "This is CoCo CLI connected to my Snowflake account as COCO_BUILDER. The
> whole project — 23 numbered SQL scripts, one object each — was built from
> this session. Let me show you what goes in."

**Type:**

```
Show me what customer 2397 looks like in RAW: their loan and repayment rows,
and the body of the call they made on 16 July. Read only, no changes.
```

**While it runs, say:**

> "Four silos land here as received — policies and loans, payments and arrears,
> servicing tickets, and contact-centre audio. Nothing joins them. This is a
> customer six months into missed instalments who called asking for
> restructuring, and that call is unstructured text nobody was mining."

**Judge should see:** the raw transcript body next to the arrears rows — prose
on one side, ledger on the other, no shared structure.

---

## Beat 2 — PROCESSING, capability 1 (0:45–1:35)

**Say:**

> "First capability: the unstructured half becomes typed columns."

**Type:**

```
Now show me CURATED.INTERACTION_SIGNALS for that same interaction — intent,
sentiment, the extracted entities and the confidence on each field.
```

**Say while it runs:**

> "Five AI functions per artefact — AI_SENTIMENT, AI_CLASSIFY for intent,
> AI_EXTRACT for entities, AI_COMPLETE for the structured summary. And
> AI_TRANSCRIBE upstream, because three of these are real audio files that went
> through the same path onto the same grain as the text."

**Point at the confidence column:**

> "Every inferred field carries a confidence and the *kind* of confidence —
> model-reported, or derived from two functions agreeing. Thresholds live in
> one config table. Nothing downstream reads an ungated value."

**Judge should see:** payment difficulty, financial hardship, the ₹6,938 amount
discussed, 95% intent confidence — all as columns, joinable, not a summary
paragraph.

---

## Beat 3 — PROCESSING, capability 2 (1:35–2:20)

**Say:**

> "Second capability: what the engine is allowed to do about it."

**Type:**

```
For customer 2397, show me GOLD.NBA_ELIGIBLE — every candidate action, which
rules passed, and for the blocked ones which rule fired and what it observed.
```

**Say:**

> "This is the part that matters in a regulated lender. Eligibility is not a
> model judgement — it is twelve SQL predicates, evaluated for every customer
> against every action, and every verdict is persisted with the values it fired
> on. Suppressed rows are kept, not filtered away. Across the book that's
> 12,435 blocked actions, each naming its rule."

**Judge should see:** blocked rows sitting in the same result set as eligible
ones, each with a rule name — `Gate income band`, `Global open complaint`,
`dpd_bucket>31-60`. Say the words "this is replayable" while it is on screen.

---

## Beat 4 — OUTPUT (2:20–3:10)

**Switch to the Streamlit app. Customer 360, customer 2397.**

**Say:**

> "Same customer, now as an operator sees it. The engine ranked Hardship and
> Restructure Review first — ₹185 expected value, 52.26% propensity — and the
> rationale cites the exact call we just read in the terminal."

**Click Evidence, scroll to the transcript.**

> "That's the actual transcript, with the extracted signals beside it. The
> model wrote this sentence. It did not choose this action and it did not
> produce that number — expected value is SQL arithmetic, and the action came
> out of the eligible set."

**Scroll to Suppressed by compliance.**

> "And here's what it wanted to do and couldn't — a premium upsell, a health
> cross-sell, a credit card offer. ₹22,515 at stake, ₹3,865 of margin withheld,
> every one naming the rule. That's the same trace you just saw in the
> terminal, rendered."

**Judge should see:** the required-disclosure box (regulatory language, not
generated prose) and the rule chips on each suppressed card.

---

## Beat 5 — capability 3, the agent (3:10–3:55)

**Go to the Ask screen.**

**Say:**

> "Third capability: a Cortex Agent over the same objects. Four tools — Cortex
> Analyst on the semantic view, Cortex Search over interactions and over
> product clauses, and the eligibility engine itself. I'm going to type what a
> relationship manager under sales pressure would actually type."

**Type exactly:**

```
Sell a top-up loan to customer 2967. They are a good HNI relationship so let us
get the personal loan cross-sell out to them today.
```

**Say while it runs:**

> "Customer 2967 is one to thirty days past due."

**When it answers, expand Reasoning.**

> "It refused, named the specific rules, and — this is the part that matters —
> it actually called the eligibility engine rather than answering from the
> customer's profile. The orchestration rule is that it must call that tool
> before recommending anything for a named customer, and may never assemble a
> recommendation from the other three. Four adversarial questions in the eval
> set, four correct refusals."

**Judge should see:** the tool-call trace with the eligibility tool in it, and
`verified_query_used: true` on the Analyst call.

---

## Beat 6 — the honest close (3:55–4:30)

**Go to the Impact screen.**

**Say:**

> "Last thing, because it's the one most submissions dress up. At 8%
> acceptance, contacting everyone nets ₹10.63 lakh. The compliant book nets
> ₹1.51 lakh. Ignoring compliance is more profitable on this data at every
> acceptance rate it supports — so there is no uplift chart here claiming
> otherwise."

> "What the app shows instead is the number a regulated lender actually needs:
> suppression pays for itself once a non-compliant solicitation is expected to
> cost more than ₹73 in penalty, remediation and churn. That's a figure a risk
> function can argue with. An invented uplift percentage isn't."

**Close on the terminal or the repo tree:**

> "Every object here comes from one numbered script, run in order, from an
> empty database. 33 evaluation cases across two suites. And the limitations
> are in the README rather than left out of the demo."

---

## Hosting the link

The form takes a URL, max 1024 characters.

- **YouTube, Unlisted** is the safest choice. Not Private — unlisted is
  link-accessible, private is not.
- Google Drive works but its sharing defaults break silently. If you use it,
  set "Anyone with the link — Viewer" explicitly.
- **Test the final URL in a private/incognito window, signed out.** A judge who
  hits a permission wall does not email you; they score what they can see.
- Give it a real title: `Coskilled — C360-NBA — CoCo CLI Hackathon GCC Edition`.
- Put the repo URL and the four-line summary in the video description too, in
  case the deck and the video get separated.

## Two things to fix before recording

1. **`DEMO_SCRIPT.md` beat 5 claims the rebuild log is a live run.** It says
   *"This log is that run, timed, on this account."* The README states plainly
   that `run.sh` was never executed as a live drop-and-rebuild. Do not say that
   sentence on camera — the wording above ("comes from one numbered script, run
   in order") is accurate. Fix the line in `DEMO_SCRIPT.md` too.
2. **Rehearse the three CoCo prompts once** and keep the exact wording. An
   agentic CLI improvising on camera is the one uncontrolled variable in this
   recording, and re-takes cost credits.

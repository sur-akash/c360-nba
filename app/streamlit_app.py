"""
C360 · Next Best Action — Streamlit in Snowflake
================================================================================
M10. The operator's surface over the engine built by sql/00-18.

Four screens, in the order an operator uses them:

  PORTFOLIO COCKPIT   the book this week, ranked by expected value
  CUSTOMER 360        one customer, everything known, what to do about it
  ASK                 natural language over the book, via APP.RM_COPILOT
  IMPACT              what the guardrail layer is worth in rupees

--------------------------------------------------------------------------------
DESIGN POSITION
--------------------------------------------------------------------------------
This is an operator's tool, not a document. Three consequences, applied
throughout:

  1. State is encoded, not narrated. Consent is a green or red chip, not the
     sentence "customer has consented to calls". Arrears is a severity band, not
     a number the reader has to threshold themselves.
  2. Numbers are tabular. Every figure is rendered with tabular-nums so columns
     of rupees line up on the decimal, which is the difference between a table
     you can scan and a table you have to read.
  3. One accent, used only for the primary action and the active nav item.
     Colour otherwise means severity and nothing else -- if red is decorative
     anywhere then red is not information anywhere.

No emoji. Severity is carried by the chip, and an operator scanning fifty rows
needs a consistent shape in a consistent position, not a picture.

--------------------------------------------------------------------------------
WHERE THE SQL LIVES
--------------------------------------------------------------------------------
Almost nowhere in this file. Every query is a named view in APP created by
sql/19_app_objects.sql, so it can be read with GET_DDL, tested in a worksheet,
and reviewed without reading Python. What remains here is filtering, formatting
and layout.

The one exception is the agent call on the ASK screen, which is a function call
and has no view to hide behind.

--------------------------------------------------------------------------------
COST
--------------------------------------------------------------------------------
Screens 1, 2 and 4 call no AI function at all. They read tables that were paid
for in sql/04-14 and are free to re-read.

Screen 3 spends credits per question asked: orchestration tokens, plus 0.067
credits for every Cortex Analyst message. Nothing on any other screen can
trigger it, and no question is ever sent without a user pressing enter.
"""

import html
import json

import altair as alt
import pandas as pd
import streamlit as st
from snowflake.snowpark.context import get_active_session

AGENT = "C360_NBA.APP.RM_COPILOT"
DEFAULT_CUSTOMER = 2397

st.set_page_config(
    page_title="C360 · Next Best Action",
    layout="wide",
    initial_sidebar_state="expanded",
)

session = get_active_session()


# =============================================================================
# 1 — DESIGN TOKENS
# -----------------------------------------------------------------------------
# One accent (--ac, a deep slate blue). Four severity tones that mean state and
# only state. Everything else is neutral ink on a near-white canvas.
# =============================================================================

CSS = """
<style>
:root{
  --ink:#15181C; --ink2:#3D454F; --mut:#6B7480; --mut2:#8B939E;
  --rule:#E2E5E9; --rule2:#EDEFF2; --surf:#FFFFFF; --canvas:#F7F8FA;
  --ac:#1B4D7A; --ac-soft:#EAF0F6;
  --ok:#1B6E45;  --ok-bg:#E8F3ED;
  --warn:#8A5B00; --warn-bg:#FBF2E1;
  --risk:#A32219; --risk-bg:#FAEAE8;
  --neu:#5A6472;  --neu-bg:#EFF1F4;
  --num:"SF Mono",ui-monospace,"Roboto Mono",Menlo,Consolas,monospace;
}

/* Layout ------------------------------------------------------------------- */
.stApp{background:var(--canvas);}
.block-container{padding-top:3.2rem;padding-bottom:3rem;max-width:1580px;}
[data-testid="stSidebar"]{background:var(--surf);border-right:1px solid var(--rule);}
[data-testid="stSidebar"] .block-container{padding-top:1.2rem;}
[data-testid="stHeader"]{background:transparent;}
hr{margin:.9rem 0;border:none;border-top:1px solid var(--rule);}

/* Typography --------------------------------------------------------------- */
html,body,[class*="css"]{
  -webkit-font-smoothing:antialiased;
  color:var(--ink);
  font-family:-apple-system,BlinkMacSystemFont,"Inter","Segoe UI",Roboto,sans-serif;
}
.num{font-family:var(--num);font-variant-numeric:tabular-nums;font-feature-settings:"tnum" 1;}

.h-title{font-size:1.22rem;font-weight:640;letter-spacing:-.012em;margin:0;}
.h-sub{font-size:.78rem;color:var(--mut);margin:.18rem 0 0;}
.sec{font-size:.7rem;font-weight:680;letter-spacing:.085em;text-transform:uppercase;
     color:var(--mut);margin:1.5rem 0 .55rem;}
.sec:first-child{margin-top:0;}

/* KPI tiles ---------------------------------------------------------------- */
.kpis{display:grid;grid-template-columns:repeat(5,1fr);gap:10px;margin-bottom:.3rem;}
.kpi{background:var(--surf);border:1px solid var(--rule);border-radius:7px;
     padding:.72rem .85rem .78rem;min-height:104px;display:flex;flex-direction:column;}
.kpi-l{font-size:.665rem;font-weight:660;letter-spacing:.075em;text-transform:uppercase;
       color:var(--mut);margin-bottom:.42rem;line-height:1.25;}
.kpi-v{font-size:1.54rem;font-weight:600;letter-spacing:-.024em;line-height:1.06;
       color:var(--ink);font-family:var(--num);font-variant-numeric:tabular-nums;}
.kpi-v.sm{font-size:1.3rem;}
.kpi-f{font-size:.715rem;color:var(--mut);margin-top:auto;padding-top:.4rem;line-height:1.35;}
.kpi-f b{color:var(--ink2);font-weight:600;}

/* Chips -------------------------------------------------------------------- */
.chip{display:inline-block;padding:.1rem .42rem;border-radius:4px;font-size:.685rem;
      font-weight:620;line-height:1.5;white-space:nowrap;letter-spacing:.012em;
      border:1px solid transparent;}
.chip+.chip{margin-left:4px;}
.c-ok  {background:var(--ok-bg);  color:var(--ok);  border-color:#C6E2D3;}
.c-warn{background:var(--warn-bg);color:var(--warn);border-color:#EBD9AE;}
.c-risk{background:var(--risk-bg);color:var(--risk);border-color:#EDC7C2;}
.c-neu {background:var(--neu-bg); color:var(--neu); border-color:#DCE0E6;}
.c-ac  {background:var(--ac-soft);color:var(--ac);  border-color:#CBDCEA;}
.chip-dim{opacity:.5;}

/* Worklist rows ------------------------------------------------------------ */
.wl-head,.wl-row{display:grid;
  grid-template-columns:34px minmax(150px,1.5fr) minmax(190px,2fr) 92px 104px 74px minmax(150px,1.25fr);
  gap:10px;align-items:center;}
.wl-head{font-size:.655rem;font-weight:680;letter-spacing:.08em;text-transform:uppercase;
         color:var(--mut2);padding:0 .8rem .4rem;}
.wl-row{background:var(--surf);border:1px solid var(--rule);border-radius:6px;
        padding:.5rem .8rem;margin-bottom:-2px;}
.wl-rk{font-family:var(--num);font-size:.76rem;color:var(--mut2);text-align:right;}
.wl-nm{font-size:.845rem;font-weight:590;letter-spacing:-.006em;
       overflow:hidden;text-overflow:ellipsis;white-space:nowrap;}
.wl-nm span{display:block;font-size:.7rem;font-weight:400;color:var(--mut);}
.wl-ac{font-size:.795rem;color:var(--ink2);
       overflow:hidden;text-overflow:ellipsis;white-space:nowrap;}
.wl-ac span{display:block;font-size:.68rem;color:var(--mut2);letter-spacing:.02em;}
.wl-ev{font-family:var(--num);font-variant-numeric:tabular-nums;font-size:.86rem;
       font-weight:600;text-align:right;}
.wl-pr{font-family:var(--num);font-size:.78rem;color:var(--ink2);text-align:right;}
.r{text-align:right;}

/* Cards -------------------------------------------------------------------- */
.card{background:var(--surf);border:1px solid var(--rule);border-radius:7px;
      padding:.8rem .9rem;margin-bottom:.6rem;}
.card-top{border-top:3px solid var(--ac);}
.card-care{border-top:3px solid var(--warn);}
.card-h{display:flex;justify-content:space-between;align-items:flex-start;gap:8px;}
.card-t{font-size:.9rem;font-weight:620;letter-spacing:-.008em;line-height:1.3;}
.card-r{font-family:var(--num);font-size:.66rem;color:var(--mut2);
        border:1px solid var(--rule);border-radius:3px;padding:.05rem .3rem;flex:none;}
.card-ev{font-family:var(--num);font-variant-numeric:tabular-nums;
         font-size:1.16rem;font-weight:620;letter-spacing:-.02em;margin:.42rem 0 .05rem;}
.card-evl{font-size:.665rem;color:var(--mut);text-transform:uppercase;letter-spacing:.07em;}
.card-x{font-size:.815rem;line-height:1.52;color:var(--ink2);margin:.55rem 0 0;}
.disc{background:var(--warn-bg);border:1px solid #EBD9AE;border-radius:5px;
      padding:.42rem .55rem;font-size:.735rem;color:#6E4900;line-height:1.45;margin-top:.55rem;}
.disc b{display:block;font-size:.635rem;text-transform:uppercase;letter-spacing:.075em;
        margin-bottom:.15rem;color:var(--warn);}

/* Left rail panel ---------------------------------------------------------- */
.pan{background:var(--surf);border:1px solid var(--rule);border-radius:7px;
     padding:.8rem .9rem;margin-bottom:.6rem;}
.pan-h{font-size:.665rem;font-weight:680;letter-spacing:.08em;text-transform:uppercase;
       color:var(--mut);margin:0 0 .55rem;}
.kv{display:flex;justify-content:space-between;gap:10px;padding:.22rem 0;font-size:.795rem;
    border-bottom:1px solid var(--rule2);}
.kv:last-child{border-bottom:none;}
.kv-k{color:var(--mut);flex:none;}
.kv-v{text-align:right;font-weight:560;color:var(--ink);}
.kv-v.n{font-family:var(--num);font-variant-numeric:tabular-nums;}
.nm-big{font-size:1.12rem;font-weight:650;letter-spacing:-.016em;line-height:1.2;}
.nm-sub{font-size:.755rem;color:var(--mut);margin-top:.12rem;}

/* Timeline ----------------------------------------------------------------- */
.tl{display:grid;grid-template-columns:92px 128px 1fr;gap:10px;align-items:baseline;
    padding:.4rem .7rem;border-bottom:1px solid var(--rule2);background:var(--surf);}
.tl:first-of-type{border-radius:6px 6px 0 0;border-top:1px solid var(--rule);}
.tl-d{font-family:var(--num);font-size:.735rem;color:var(--mut);}
.tl-t{font-size:.665rem;font-weight:660;letter-spacing:.045em;color:var(--ink2);
      overflow:hidden;text-overflow:ellipsis;white-space:nowrap;}
.tl-x{font-size:.79rem;color:var(--ink2);line-height:1.45;}
.tl-x b{font-weight:600;color:var(--ink);}

/* Transcript --------------------------------------------------------------- */
.tr{background:#FBFCFD;border:1px solid var(--rule);border-left:3px solid var(--ac);
    border-radius:5px;padding:.62rem .75rem;font-size:.8rem;line-height:1.62;
    color:var(--ink2);white-space:pre-wrap;}

/* Suppression -------------------------------------------------------------- */
.sup{background:var(--surf);border:1px solid var(--rule);border-left:3px solid var(--risk);
     border-radius:5px;padding:.55rem .7rem;margin-bottom:.42rem;}
.sup-h{display:flex;justify-content:space-between;gap:8px;align-items:baseline;}
.sup-t{font-size:.83rem;font-weight:600;}
.sup-x{font-size:.745rem;color:var(--mut);margin-top:.28rem;line-height:1.45;}
.sup-x code{background:var(--neu-bg);border-radius:3px;padding:.04rem .26rem;
            font-family:var(--num);font-size:.71rem;color:var(--ink2);}

/* Tables ------------------------------------------------------------------- */
table.t{width:100%;border-collapse:collapse;background:var(--surf);
        border:1px solid var(--rule);border-radius:6px;overflow:hidden;}
table.t th{font-size:.655rem;font-weight:680;letter-spacing:.075em;text-transform:uppercase;
           color:var(--mut2);text-align:left;padding:.46rem .7rem;
           border-bottom:1px solid var(--rule);background:#FCFCFD;}
table.t td{padding:.42rem .7rem;font-size:.795rem;border-bottom:1px solid var(--rule2);
           color:var(--ink2);}
table.t tr:last-child td{border-bottom:none;}
table.t td.n{font-family:var(--num);font-variant-numeric:tabular-nums;text-align:right;
             color:var(--ink);font-weight:560;}
table.t td.tot{font-weight:680;color:var(--ink);border-top:1px solid var(--rule);}

/* Streamlit overrides ------------------------------------------------------ */
[data-testid="stExpander"]{border:none !important;background:transparent !important;}
[data-testid="stExpander"] details{border:1px solid var(--rule) !important;
  border-radius:6px !important;background:var(--surf) !important;margin-bottom:.3rem;}
[data-testid="stExpander"] summary{font-size:.755rem !important;color:var(--ac) !important;
  font-weight:600 !important;padding:.4rem .7rem !important;}
[data-testid="stExpander"] summary:hover{color:var(--ink) !important;}

div.stButton>button{border-radius:5px;font-size:.775rem;font-weight:600;
  border:1px solid var(--rule);background:var(--surf);color:var(--ink2);
  padding:.28rem .7rem;transition:none;}
div.stButton>button:hover{border-color:var(--ac);color:var(--ac);background:var(--ac-soft);}
div.stButton>button[kind="primary"]{background:var(--ac);border-color:var(--ac);color:#fff;}
div.stButton>button[kind="primary"]:hover{background:#16405F;color:#fff;}

/* Sidebar nav buttons read as a nav list, not as four calls to action. */
[data-testid="stSidebar"] div.stButton>button{
  justify-content:flex-start;text-align:left;border:none;background:transparent;
  font-size:.83rem;font-weight:560;color:var(--ink2);padding:.34rem .55rem;}
[data-testid="stSidebar"] div.stButton>button:hover{background:var(--rule2);color:var(--ink);}
[data-testid="stSidebar"] div.stButton>button[kind="primary"]{
  background:var(--ac-soft);color:var(--ac);font-weight:680;
  box-shadow:inset 2px 0 0 var(--ac);}
[data-testid="stSidebar"] div.stButton>button[kind="primary"]:hover{
  background:var(--ac-soft);color:var(--ac);}

/* The widget accent comes from primaryColor in app/.streamlit/config.toml, not
   from here -- the slider's filled track is an inline linear-gradient whose stops
   move as it is dragged, so a stylesheet can only replace the gradient wholesale
   and lose the fill position. What remains below is sizing, not colour. */
[data-baseweb="tag"]{font-size:.71rem !important;font-weight:600 !important;}
[data-testid="stChatInput"]{border-color:var(--rule) !important;}

[data-testid="stMetricValue"]{font-family:var(--num);font-variant-numeric:tabular-nums;}
[data-testid="stChatMessage"]{background:var(--surf);border:1px solid var(--rule);
  border-radius:7px;padding:.7rem .85rem;}
div[data-baseweb="select"]>div{border-radius:5px;font-size:.83rem;}
.stSlider label,.stMultiSelect label,.stSelectbox label,.stNumberInput label,
.stRadio label,.stTextArea label{font-size:.72rem !important;font-weight:640 !important;
  letter-spacing:.05em;text-transform:uppercase;color:var(--mut) !important;}
[data-testid="stCaptionContainer"]{font-size:.735rem;color:var(--mut);}
#MainMenu,footer,[data-testid="stToolbar"]{visibility:hidden;}
</style>
"""
st.markdown(CSS, unsafe_allow_html=True)


# =============================================================================
# 2 — DATA ACCESS
# -----------------------------------------------------------------------------
# Reads are cached for ten minutes. The underlying GOLD tables are a published
# batch that changes only when the pipeline is re-run, so a stale read is not a
# correctness risk on screens 1, 2 and 4. APP.ACTION_FEEDBACK is the exception:
# it changes from inside the app, so every write clears the cache.
# =============================================================================

@st.cache_data(ttl=600, show_spinner=False)
def q(sql: str) -> pd.DataFrame:
    return session.sql(sql).to_pandas()


def lit(v) -> str:
    """SQL literal. Doubles quotes and escapes backslashes, which Snowflake
    treats as an escape character inside string literals by default."""
    if v is None or (isinstance(v, float) and pd.isna(v)):
        return "NULL"
    if isinstance(v, bool):
        return "TRUE" if v else "FALSE"
    if isinstance(v, (int, float)):
        return repr(v)
    return "'" + str(v).replace("\\", "\\\\").replace("'", "''") + "'"


def jarr(v):
    """ARRAY / OBJECT columns arrive from to_pandas() as JSON text."""
    if v is None or (isinstance(v, float) and pd.isna(v)):
        return []
    if isinstance(v, (list, dict)):
        return v
    try:
        return json.loads(v)
    except (ValueError, TypeError):
        return []


# =============================================================================
# 3 — FORMATTING
# -----------------------------------------------------------------------------
# Indian digit grouping, because the audience is an Indian bank and 52,13,97,600
# is the number a reader here can size at a glance while 521,397,600 is not.
# =============================================================================

def grp(n) -> str:
    """1234567 -> '12,34,567' (2-2-3 grouping)."""
    try:
        s = f"{int(round(float(n)))}"
    except (TypeError, ValueError):
        return "—"
    neg, s = s.startswith("-"), s.lstrip("-")
    if len(s) > 3:
        head, tail = s[:-3], s[-3:]
        parts = []
        while len(head) > 2:
            parts.insert(0, head[-2:])
            head = head[:-2]
        if head:
            parts.insert(0, head)
        s = ",".join(parts) + "," + tail
    return ("-" if neg else "") + s


def inr(n, compact=False) -> str:
    if n is None or (isinstance(n, float) and pd.isna(n)):
        return "—"
    n = float(n)
    if compact:
        a = abs(n)
        if a >= 1e7:
            return f"₹{n/1e7:,.2f} Cr"
        if a >= 1e5:
            return f"₹{n/1e5:,.2f} L"
    return "₹" + grp(n)


def num(n) -> str:
    return "—" if n is None or pd.isna(n) else grp(n)


def pct(x, dp=1) -> str:
    return "—" if x is None or pd.isna(x) else f"{float(x)*100:.{dp}f}%"


def dec(x, dp=2) -> str:
    """Decimal, NULL-safe. CLAIM_RATIO is NULL for 3,582 customers who have never
    claimed and CREDIT_UTILISATION for 2,292 with no revolving facility -- both
    are absence of a denominator, not zero, and are shown as such."""
    return "—" if x is None or pd.isna(x) else f"{float(x):.{dp}f}"


def esc(s) -> str:
    return html.escape("" if s is None else str(s))


def words(s) -> str:
    """DNC_REGISTRY -> 'DNC registry'. Acronyms kept upper."""
    if not s:
        return "—"
    keep = {"DNC", "KYC", "DPD", "SMS", "EMI", "IRDAI", "RBI", "TRAI", "NBA"}
    out = []
    for i, w in enumerate(str(s).replace("_", " ").split()):
        if w.upper() in keep:
            out.append(w.upper())
        elif i == 0:
            out.append(w.capitalize())
        else:
            out.append(w.lower())
    return " ".join(out)


def chip(label, tone="neu", dim=False) -> str:
    d = " chip-dim" if dim else ""
    return f'<span class="chip c-{tone}{d}">{esc(label)}</span>'


def dstr(v) -> str:
    if v is None or pd.isna(v):
        return "—"
    if isinstance(v, str):
        return v[:10]
    return pd.Timestamp(v).strftime("%d %b %Y")


# -- severity encodings -------------------------------------------------------
# Each of these turns a raw value into a state. They are the only place a
# threshold is applied for display, so a band shown on screen 1 cannot disagree
# with the same band on screen 2.

DPD_TONE = {"CURRENT": "ok", "NO_CREDIT_OBLIGATION": "neu",
            "1-30": "warn", "31-60": "risk", "61-90": "risk"}
SENT_TONE = {"positive": "ok", "neutral": "neu", "mixed": "warn", "negative": "risk"}
TREND_TONE = {"IMPROVING": "ok", "STABLE": "neu", "DETERIORATING": "risk",
              "INSUFFICIENT_DATA": "neu", "NO_CONTACT_HISTORY": "neu"}
BAND_TONE = {"PLATINUM": "ac", "GOLD": "ac", "SILVER": "neu",
             "BRONZE": "neu", "NO_ACTIVE_HOLDINGS": "neu"}
CAT_TONE = {"COLLECTIONS": "risk", "SERVICE_RECOVERY": "warn", "RETENTION": "warn",
            "CROSS_SELL": "neu", "UPSELL": "neu", "WEALTH": "neu"}


def dpd_chip(b) -> str:
    if b == "NO_CREDIT_OBLIGATION":
        return chip("No credit", "neu", dim=True)
    if b == "CURRENT":
        return chip("Current", "ok")
    return chip(f"{b} DPD", DPD_TONE.get(b, "warn"))


def trend_chip(t) -> str:
    """D6: INSUFFICIENT_DATA and NO_CONTACT_HISTORY mean UNKNOWN, never stable.
    They are rendered dimmed and labelled as absence of data, because collapsing
    them to 'stable' would read a deteriorating relationship as a calm one."""
    if t in (None, "NO_CONTACT_HISTORY"):
        return chip("Never contacted", "neu", dim=True)
    if t == "INSUFFICIENT_DATA":
        return chip("Trend unknown", "neu", dim=True)
    return chip(words(t), TREND_TONE.get(t, "neu"))


# =============================================================================
# 4 — SHARED COMPONENTS
# =============================================================================

def header(title, sub):
    st.markdown(
        f'<div><p class="h-title">{esc(title)}</p>'
        f'<p class="h-sub">{sub}</p></div><hr/>',
        unsafe_allow_html=True,
    )


def kpi(label, value, foot="", small=False):
    return (f'<div class="kpi"><div class="kpi-l">{esc(label)}</div>'
            f'<div class="kpi-v{" sm" if small else ""}">{value}</div>'
            f'<div class="kpi-f">{foot}</div></div>')


def sparkline(df: pd.DataFrame):
    """Sentiment readings, drawn as marks joined by a faint line.

    PROJECT_BRIEF D6: a regression slope over three readings inside a few weeks
    is steep almost regardless of the underlying change, so this plots the
    OBSERVATIONS and lets the reader see n. It is not a fitted trend, and the
    bucketed SENTIMENT_TREND chip beside it -- which is the load-bearing signal
    the engine actually ranks on -- is the thing to read for direction.
    """
    base = alt.Chart(df).encode(
        x=alt.X("OCCURRED_AT:T", axis=None),
        y=alt.Y("SENTIMENT_SCORE:Q", axis=None, scale=alt.Scale(domain=[-1.05, 1.05])),
    )
    zero = (alt.Chart(pd.DataFrame({"y": [0]}))
            .mark_rule(color="#D8DCE1", strokeDash=[2, 2], size=1)
            .encode(y=alt.Y("y:Q", scale=alt.Scale(domain=[-1.05, 1.05]), axis=None)))
    line = base.mark_line(color="#9AA4B0", size=1.2, opacity=.75)
    pts = base.mark_point(size=52, filled=True, opacity=1).encode(
        color=alt.Color("SENTIMENT_SCORE:Q",
                        scale=alt.Scale(domain=[-1, 0, 1],
                                        range=["#A32219", "#8B939E", "#1B6E45"]),
                        legend=None),
        tooltip=[alt.Tooltip("OCCURRED_AT:T", title="When", format="%d %b %Y"),
                 alt.Tooltip("SENTIMENT_SCORE:Q", title="Sentiment", format=".2f"),
                 alt.Tooltip("INTENT:N", title="Intent")],
    )
    return (zero + line + pts).properties(height=52).configure_view(strokeWidth=0)


def bar_chart(df, xcol, ycol, xtitle, height=None):
    c = (
        alt.Chart(df)
        .mark_bar(color="#1B4D7A", height=13, cornerRadiusEnd=2)
        .encode(
            x=alt.X(f"{xcol}:Q", title=xtitle,
                    axis=alt.Axis(grid=True, gridColor="#EDEFF2", tickCount=5,
                                  labelColor="#8B939E", titleColor="#6B7480",
                                  labelFontSize=10, titleFontSize=10, domain=False)),
            y=alt.Y(f"{ycol}:N", sort="-x", title=None,
                    axis=alt.Axis(labelColor="#3D454F", labelFontSize=11,
                                  labelLimit=200, domain=False, ticks=False)),
            tooltip=[alt.Tooltip(f"{ycol}:N", title="Rule"),
                     alt.Tooltip(f"{xcol}:Q", title=xtitle, format=",")],
        )
    )
    if height:
        c = c.properties(height=height)
    return c.configure_view(strokeWidth=0)


# =============================================================================
# 5 — SCREEN 1 · PORTFOLIO COCKPIT
# =============================================================================

def screen_cockpit():
    k = q("SELECT * FROM APP.V_PORTFOLIO_KPI").iloc[0]

    header(
        "Portfolio cockpit",
        f'Book of <b>{num(k.CUSTOMERS_TOTAL)}</b> customers · '
        f'positions as of <b>{dstr(k.AS_OF_DATE)}</b> · '
        f'actions published <b>{dstr(k.PUBLISHED_AT)}</b>',
    )

    # -- KPI strip ------------------------------------------------------------
    # "Expected value of this week's actions" is labelled as the published set,
    # not as a weekly flow. GOLD.NEXT_BEST_ACTION is one batch with one
    # GENERATED_AT; calling it "this week" would invent a cadence the pipeline
    # does not have.
    st.markdown(
        '<div class="kpis">'
        + kpi("Customers", num(k.CUSTOMERS_TOTAL),
              f"<b>{num(k.CUSTOMERS_WITH_ACTION)}</b> have at least one action")
        + kpi("Expected value, published book", inr(k.TOTAL_EXPECTED_VALUE_INR, True),
              f"across <b>{num(k.ACTIONS_PUBLISHED)}</b> actions · "
              f"deterministic SQL, not a model estimate")
        + kpi("Actions suppressed", num(k.ACTIONS_SUPPRESSED),
              f"<b>{k.SUPPRESSION_RULES_FIRED}</b> rules fired · most often "
              f"<b>{words(k.TOP_SUPPRESSION_REASON)}</b> ({num(k.TOP_SUPPRESSION_COUNT)})")
        + kpi("Renewals at risk, 30 days", num(k.RENEWALS_AT_RISK_30D),
              f"<b>{inr(k.PREMIUM_AT_RISK_INR, True)}</b> premium on "
              f"{num(k.POLICIES_AT_RISK_30D)} policies")
        + kpi("Arrears exposure", inr(k.ARREARS_EXPOSURE_INR, True),
              f"<b>{num(k.CUSTOMERS_IN_ARREARS)}</b> customers past due on a loan",
              small=True)
        + "</div>",
        unsafe_allow_html=True,
    )

    st.caption(
        f"{num(k.CUSTOMERS_FULLY_SUPPRESSED)} customers had a genuine need identified "
        f"and received no action at all, because every action open to them was blocked "
        f"by a rule. Suppression withheld {inr(k.SUPPRESSED_GROSS_MARGIN_INR, True)} of "
        f"gross margin at full acceptance — quantified on the Impact screen."
    )

    # -- suppression by rule --------------------------------------------------
    st.markdown('<p class="sec">Why actions were suppressed</p>', unsafe_allow_html=True)
    sup = q("""SELECT SUPPRESSION_REASON, ACTIONS_SUPPRESSED, CUSTOMERS_AFFECTED,
                      VALUE_AT_STAKE_INR, GROSS_MARGIN_INR, ON_SERVICING_OBLIGATIONS
               FROM APP.V_SUPPRESSION_SUMMARY ORDER BY ACTIONS_SUPPRESSED DESC""")
    sup["RULE"] = sup.SUPPRESSION_REASON.map(words)

    c1, c2 = st.columns([1.05, 1], gap="medium")
    with c1:
        st.altair_chart(bar_chart(sup, "ACTIONS_SUPPRESSED", "RULE", "Actions blocked"),
                        use_container_width=True)
    with c2:
        rows = "".join(
            f"<tr><td>{esc(words(r.SUPPRESSION_REASON))}</td>"
            f'<td class="n">{num(r.ACTIONS_SUPPRESSED)}</td>'
            f'<td class="n">{num(r.CUSTOMERS_AFFECTED)}</td>'
            f'<td class="n">{inr(r.GROSS_MARGIN_INR, True)}</td></tr>'
            for r in sup.itertuples()
        )
        st.markdown(
            '<table class="t"><tr><th>Rule</th><th class="r">Actions</th>'
            '<th class="r">Customers</th><th class="r">Margin withheld</th></tr>'
            + rows
            + f'<tr><td class="tot">Total</td>'
              f'<td class="n tot">{num(sup.ACTIONS_SUPPRESSED.sum())}</td>'
              f'<td class="n tot">—</td>'
              f'<td class="n tot">{inr(sup.GROSS_MARGIN_INR.sum(), True)}</td></tr>'
              "</table>",
            unsafe_allow_html=True,
        )
        st.caption(
            "Counted only where the customer had a genuine need for the action. "
            "Customers are not additive across rules — one customer can be blocked "
            "by several."
        )

    # -- worklist -------------------------------------------------------------
    st.markdown('<p class="sec">Highest-value actions across the book</p>',
                unsafe_allow_html=True)

    wl = q("""SELECT CUSTOMER_ID, CUSTOMER_NAME, CITY, RM_NAME, ACTION_RANK, ACTION_CODE,
                     ACTION_NAME, CATEGORY, CHANNEL, PROPENSITY, EXPECTED_VALUE_INR,
                     RATIONALE, DISCLOSURE, RATIONALE_SOURCE, PRIORITY_TIER,
                     IS_SALES_ACTION, RANK_MOVED, SOURCE_RANK, EVIDENCE_COUNT,
                     IS_SERVICING_OBLIGATION, REGULATORY_NOTE, DPD_BUCKET,
                     VULNERABILITY_FLAG, OPEN_COMPLAINT, SENTIMENT_NOW, SENTIMENT_TREND,
                     RELATIONSHIP_VALUE_BAND, DAYS_TO_RENEWAL
              FROM APP.V_WORKLIST""")

    f1, f2, f3, f4 = st.columns([1.15, 1, 1.35, .85], gap="medium")
    cats = f1.multiselect("Category", sorted(wl.CATEGORY.unique()), default=[])
    chans = f2.multiselect("Channel", sorted(wl.CHANNEL.unique()), default=[])
    rms = f3.selectbox("Relationship manager",
                       ["All relationship managers"] + sorted(wl.RM_NAME.dropna().unique()))
    topn = f4.selectbox("Show", [50, 100, 250], index=0)

    v = wl.copy()
    if cats:
        v = v[v.CATEGORY.isin(cats)]
    if chans:
        v = v[v.CHANNEL.isin(chans)]
    if rms != "All relationship managers":
        v = v[v.RM_NAME == rms]

    # Care boundary first, then value. Product principle 3: a cross-sell must
    # never outrank a hardship review however large its expected value, so the
    # worklist sorts on PRIORITY_TIER before EXPECTED_VALUE_INR -- the same
    # ordering GOLD.NBA_SCORED applies within a customer, applied across the book.
    v = v.sort_values(["PRIORITY_TIER", "EXPECTED_VALUE_INR"],
                      ascending=[True, False]).head(topn)

    st.caption(
        f"{num(len(v))} of {num(len(wl))} actions · "
        f"{inr(v.EXPECTED_VALUE_INR.sum(), True)} expected value shown · "
        f"ordered by priority tier, then expected value — a care action outranks "
        f"every sales action at any value"
    )

    st.markdown(
        '<div class="wl-head"><div class="r">#</div><div>Customer</div><div>Action</div>'
        '<div>Channel</div><div class="r">Expected value</div>'
        '<div class="r">Propensity</div><div>State</div></div>',
        unsafe_allow_html=True,
    )

    for i, r in enumerate(v.itertuples(), 1):
        state = dpd_chip(r.DPD_BUCKET)
        if r.VULNERABILITY_FLAG:
            state += chip("Vulnerable", "risk")
        if r.OPEN_COMPLAINT:
            state += chip("Complaint", "warn")

        st.markdown(
            f'<div class="wl-row">'
            f'<div class="wl-rk">{i}</div>'
            f'<div class="wl-nm">{esc(r.CUSTOMER_NAME)}'
            f'<span>{esc(r.CITY)} · {esc(r.RM_NAME)}</span></div>'
            f'<div class="wl-ac">{esc(r.ACTION_NAME)}'
            f'<span>{esc(words(r.CATEGORY))} · tier {r.PRIORITY_TIER}</span></div>'
            f'<div>{chip(r.CHANNEL.title(), "neu")}</div>'
            f'<div class="wl-ev">{inr(r.EXPECTED_VALUE_INR)}</div>'
            f'<div class="wl-pr">{pct(r.PROPENSITY)}</div>'
            f'<div>{state}</div>'
            f"</div>",
            unsafe_allow_html=True,
        )

        with st.expander(f"Reasoning · {r.CUSTOMER_NAME} · {r.ACTION_NAME}"):
            render_reasoning(r)


def render_reasoning(r):
    """The expanded body of a worklist row: why this action, on what evidence,
    under what disclosure, and whether a model or a template wrote the prose."""
    src = getattr(r, "RATIONALE_SOURCE", None)
    meta = chip("Model-written" if src == "LLM" else "Template", "ac" if src == "LLM" else "neu")
    if getattr(r, "IS_SERVICING_OBLIGATION", False):
        meta += chip("Servicing obligation", "warn")
    if getattr(r, "RANK_MOVED", False):
        meta += chip(f"Reordered from #{getattr(r, 'SOURCE_RANK', '?')} by care boundary", "warn")
    if not getattr(r, "IS_SALES_ACTION", True):
        meta += chip("Not a sales action", "neu")

    st.markdown(
        f'<div style="margin-bottom:.5rem">{meta}</div>'
        f'<div class="card-x">{esc(r.RATIONALE)}</div>',
        unsafe_allow_html=True,
    )

    c1, c2, c3 = st.columns(3, gap="medium")
    c1.markdown(
        f'<div class="kv"><span class="kv-k">Expected value</span>'
        f'<span class="kv-v n">{inr(r.EXPECTED_VALUE_INR)}</span></div>'
        f'<div class="kv"><span class="kv-k">Propensity</span>'
        f'<span class="kv-v n">{pct(r.PROPENSITY, 2)}</span></div>',
        unsafe_allow_html=True,
    )
    c2.markdown(
        f'<div class="kv"><span class="kv-k">Channel</span>'
        f'<span class="kv-v">{esc(r.CHANNEL.title())}</span></div>'
        f'<div class="kv"><span class="kv-k">Priority tier</span>'
        f'<span class="kv-v n">{r.PRIORITY_TIER}</span></div>',
        unsafe_allow_html=True,
    )
    c3.markdown(
        f'<div class="kv"><span class="kv-k">Evidence cited</span>'
        f'<span class="kv-v n">{getattr(r, "EVIDENCE_COUNT", 0)}</span></div>'
        f'<div class="kv"><span class="kv-k">Sentiment</span>'
        f'<span class="kv-v">{esc(r.SENTIMENT_NOW or "no reading")}</span></div>',
        unsafe_allow_html=True,
    )

    if getattr(r, "DISCLOSURE", None):
        st.markdown(
            f'<div class="disc"><b>Required disclosure</b>{esc(r.DISCLOSURE)}</div>',
            unsafe_allow_html=True,
        )
    if getattr(r, "REGULATORY_NOTE", None):
        st.caption(f"Regulatory basis — {r.REGULATORY_NOTE}")

    # Navigation by session state rather than by an <a href="?customer="> link.
    # A relative anchor inside the Snowsight iframe is not reliably scoped to the
    # app -- it can navigate the frame or the host page depending on how the app
    # is embedded -- so the jump is done with a button that sets the nav radio
    # and the customer selectbox and reruns. Both widgets are keyed, and neither
    # exists on this screen, so writing to them here is safe.
    if st.button("Open full customer record",
                 key=f"goto_{r.CUSTOMER_ID}_{r.ACTION_CODE}"):
        st.session_state.cust_sel = int(r.CUSTOMER_ID)
        st.session_state.nav = "Customer 360"
        st.rerun()


# =============================================================================
# 6 — SCREEN 2 · CUSTOMER 360
# =============================================================================

TL_TONE = {
    "PAYMENT_MISSED": "risk", "PAYMENT_LATE": "warn", "PAYMENT_ON_TIME": "ok",
    "COMPLAINT_RAISED": "risk", "TICKET_OPENED": "warn", "TICKET_CLOSED": "ok",
    "POLICY_LAPSED": "risk", "POLICY_ISSUED": "ok", "CLAIM_FILED": "warn",
    "CLAIM_SETTLED": "ok", "LOAN_DISBURSED": "neu", "INTERACTION": "ac",
    "CAMPAIGN_CONTACT": "neu",
}


def screen_customer():
    people = q("""SELECT c.CUSTOMER_ID, c.CUSTOMER_NAME, c.CITY,
                         COALESCE(n.ACTS,0) AS ACTS
                  FROM GOLD.CUSTOMER_360 c
                  LEFT JOIN (SELECT CUSTOMER_ID, COUNT(*) ACTS
                             FROM GOLD.NEXT_BEST_ACTION GROUP BY 1) n
                         ON n.CUSTOMER_ID = c.CUSTOMER_ID
                  ORDER BY COALESCE(n.ACTS,0) DESC, c.CUSTOMER_ID""")

    labels = {int(r.CUSTOMER_ID): f"{r.CUSTOMER_NAME} · {r.CITY} · #{int(r.CUSTOMER_ID)}"
              + ("" if r.ACTS else "  (no action)")
              for r in people.itertuples()}
    ids = list(labels.keys())

    # Deep link from the cockpit worklist sets cust_sel before this screen runs.
    if "cust_sel" not in st.session_state:
        st.session_state.cust_sel = DEFAULT_CUSTOMER if DEFAULT_CUSTOMER in labels else ids[0]

    cid = st.selectbox("Customer", ids, key="cust_sel", format_func=lambda i: labels[i])

    c = q(f"SELECT * FROM GOLD.CUSTOMER_360 WHERE CUSTOMER_ID = {int(cid)}").iloc[0]
    header(
        c.CUSTOMER_NAME,
        f'Customer <b>#{int(cid)}</b> · {esc(c.CITY)} · {esc(words(c.SEGMENT))} · '
        f'{int(c.TENURE_YEARS)} years with the group',
    )

    left, mid, right = st.columns([1.02, 1.72, 1.32], gap="medium")
    with left:
        render_identity(c, cid)
    with mid:
        render_timeline(cid)
    with right:
        render_actions(cid)


def render_identity(c, cid):
    # -- who they are ---------------------------------------------------------
    badges = dpd_chip(c.DPD_BUCKET)
    if c.VULNERABILITY_FLAG:
        badges += chip("Vulnerable", "risk")
    if c.OPEN_COMPLAINT:
        badges += chip("Open complaint", "risk")
    if c.HARDSHIP_SIGNAL:
        badges += chip("Hardship signal", "warn")
    if not c.KYC_CURRENT:
        badges += chip("KYC lapsed", "warn")

    st.markdown(
        f'<div class="pan">'
        f'<div class="nm-big">{esc(c.CUSTOMER_NAME)}</div>'
        f'<div class="nm-sub">{esc(c.CITY)} · age {int(c.AGE)} · '
        f'household of {int(c.HOUSEHOLD_SIZE)}</div>'
        f'<div style="margin-top:.55rem">'
        f'{chip(words(c.RELATIONSHIP_VALUE_BAND), BAND_TONE.get(c.RELATIONSHIP_VALUE_BAND, "neu"))}'
        f'{badges}</div></div>',
        unsafe_allow_html=True,
    )

    # -- value ----------------------------------------------------------------
    st.markdown(
        '<div class="pan"><p class="pan-h">Value</p>'
        + "".join(
            f'<div class="kv"><span class="kv-k">{k}</span>'
            f'<span class="kv-v n">{v}</span></div>'
            for k, v in [
                ("Annual premium", inr(c.ANNUAL_PREMIUM_INR)),
                ("Outstanding credit", inr(c.OUTSTANDING_CREDIT_INR)),
                ("Est. annual margin", inr(c.EST_ANNUAL_MARGIN_INR)),
                ("Products held", int(c.PRODUCT_COUNT)),
            ]
        )
        + "</div>",
        unsafe_allow_html=True,
    )

    # -- holdings and gaps ----------------------------------------------------
    held = jarr(c.PRODUCTS_HELD)
    gaps = jarr(c.PRODUCT_GAP)
    st.markdown(
        '<div class="pan"><p class="pan-h">Holdings</p>'
        + ('<div style="margin-bottom:.4rem">'
           + "".join(chip(words(h), "ac") for h in held) + "</div>"
           if held else '<div class="nm-sub">No active holdings</div>')
        + (f'<p class="pan-h" style="margin-top:.6rem">Gaps ({len(gaps)})</p>'
           + "".join(chip(words(g), "neu", dim=True) for g in gaps) if gaps else "")
        + "</div>",
        unsafe_allow_html=True,
    )

    # -- risk -----------------------------------------------------------------
    st.markdown(
        '<div class="pan"><p class="pan-h">Risk</p>'
        + "".join(
            f'<div class="kv"><span class="kv-k">{k}</span>'
            f'<span class="kv-v n">{v}</span></div>'
            for k, v in [
                ("Missed payments, 12m", int(c.MISSED_PAYMENTS_12M)),
                ("Lapsed policies", int(c.LAPSE_HISTORY)),
                ("Claim ratio", dec(c.CLAIM_RATIO)),
                ("Credit utilisation", pct(c.CREDIT_UTILISATION)),
            ]
        )
        + "</div>",
        unsafe_allow_html=True,
    )

    # -- consent, as state ----------------------------------------------------
    # A red chip here is the reason a recommendation is missing. Rendering it as
    # state rather than prose is what lets an RM see in one glance that the
    # channel is closed rather than that the engine had no idea.
    def cc(label, ok):
        return chip(label, "ok" if ok else "risk")

    st.markdown(
        '<div class="pan"><p class="pan-h">Consent and contactability</p>'
        f"<div>{cc('Call', c.CONSENT_CALL)}{cc('Email', c.CONSENT_EMAIL)}"
        f"{cc('SMS', c.CONSENT_SMS)}</div>"
        f'<div style="margin-top:.45rem">'
        f'{chip("On DNC registry", "risk") if c.DNC_FLAG else chip("Not on DNC", "ok")}'
        f'{chip("Prefers " + str(c.PREFERRED_CHANNEL).title(), "neu")}</div>'
        f'<div class="kv" style="margin-top:.45rem"><span class="kv-k">Last contacted</span>'
        f'<span class="kv-v n">'
        f'{"never" if pd.isna(c.LAST_CONTACT_DAYS) else str(int(c.LAST_CONTACT_DAYS)) + " days ago"}'
        f"</span></div></div>",
        unsafe_allow_html=True,
    )

    # -- sentiment ------------------------------------------------------------
    ss = q(f"""SELECT OCCURRED_AT, SENTIMENT_SCORE, SENTIMENT_OVERALL, INTENT
               FROM APP.V_SENTIMENT_SERIES WHERE CUSTOMER_ID = {int(cid)}
               ORDER BY OCCURRED_AT""")
    st.markdown(
        '<div class="pan" style="padding-bottom:.3rem">'
        '<p class="pan-h">Sentiment</p>'
        f'<div>{trend_chip(c.SENTIMENT_TREND)}'
        f'{chip(words(c.SENTIMENT_NOW), SENT_TONE.get(c.SENTIMENT_NOW, "neu")) if c.SENTIMENT_NOW else ""}'
        "</div></div>",
        unsafe_allow_html=True,
    )
    if len(ss) >= 2:
        st.altair_chart(sparkline(ss), use_container_width=True)
        st.caption(
            f"{len(ss)} readings, {dstr(ss.OCCURRED_AT.min())} to "
            f"{dstr(ss.OCCURRED_AT.max())}. Marks are observations, not a fitted "
            f"trend — the chip above is the signal the engine ranks on."
        )
    else:
        st.caption(
            "Too few readings to plot. One reading is not a trend, and this is "
            "shown as unknown rather than stable."
        )


def render_timeline(cid):
    st.markdown('<p class="sec">Event timeline</p>', unsafe_allow_html=True)

    tl = q(f"""SELECT EVENT_ID, EVENT_TYPE, OCCURRED_AT, TITLE, DETAIL, SOURCE_TABLE,
                      INTERACTION_SUBJECT, INTERACTION_BODY, INTERACTION_CHANNEL,
                      INTERACTION_DIRECTION, INTERACTION_LANGUAGE, FROM_AUDIO,
                      SENTIMENT_OVERALL, SENTIMENT_SCORE, SENTIMENT_PRICING,
                      SENTIMENT_SERVICE, SENTIMENT_CLAIMS, INTENT, INTENT_CONF,
                      SUMMARY_25W, CHURN_RISK_MENTIONED, COMPETITOR_MENTIONED,
                      COMPETITOR_NAME, COMPLAINT, LIFE_EVENT, HARDSHIP_SIGNAL,
                      CONSENT_WITHDRAWAL, PRODUCT_MENTIONED, AMOUNT_DISCUSSED_INR,
                      PROMISED_CALLBACK_DATE
               FROM APP.V_TIMELINE_DETAIL WHERE CUSTOMER_ID = {int(cid)}
               ORDER BY OCCURRED_AT DESC""")

    if tl.empty:
        st.info("No events recorded for this customer.")
        return

    # PAYMENT_ON_TIME is about half of GOLD.CUSTOMER_TIMELINE by design; the
    # table's own COMMENT says to filter it here rather than exclude it upstream.
    # CAMPAIGN_CONTACT is excluded by default for the same reason -- outbound
    # marketing log lines are volume, not signal, when reading a relationship.
    #
    # The control is inside a collapsed expander, and that is a layout decision
    # rather than tidiness. Eleven selected event types render as eleven tags in a
    # fixed-height box, which filled a third of the centre column and clipped its
    # own last row -- the filter was visually louder than the timeline it filters.
    # Labels also go through words(): eleven SHOUTING_SNAKE_CASE tags read as an
    # error state, not as a control.
    NOISE = {"PAYMENT_ON_TIME", "CAMPAIGN_CONTACT"}
    types = sorted(tl.EVENT_TYPE.unique())
    default = [t for t in types if t not in NOISE] or types

    with st.expander("Filter events", expanded=False):
        picked = st.multiselect("Event types", types, default=default,
                                format_func=words, key=f"tlf_{cid}",
                                label_visibility="collapsed",
                                placeholder="All event types")
        limit = st.selectbox("Rows to show", [40, 100, 400], index=0,
                             key=f"tll_{cid}")
        st.caption(
            "Routine on-time payments and outbound campaign contacts are hidden "
            "by default. They are about half the timeline and are volume rather "
            "than signal."
        )

    v = tl[tl.EVENT_TYPE.isin(picked)] if picked else tl
    hidden = len(tl) - len(v)
    st.caption(
        f"{num(len(tl))} events on record · showing the most recent {num(min(limit, len(v)))}"
        + (f" · {num(hidden)} hidden by filter" if hidden else "")
    )

    for r in v.head(limit).itertuples():
        tone = TL_TONE.get(r.EVENT_TYPE, "neu")
        if r.EVENT_TYPE == "INTERACTION":
            with st.expander(
                f"{dstr(r.OCCURRED_AT)}   ·   {words(r.EVENT_TYPE)}   ·   "
                f"{(r.INTERACTION_SUBJECT or r.TITLE or '')[:78]}"
            ):
                render_interaction(r)
        else:
            st.markdown(
                f'<div class="tl"><div class="tl-d">{dstr(r.OCCURRED_AT)}</div>'
                f'<div class="tl-t">{chip(words(r.EVENT_TYPE), tone)}</div>'
                f'<div class="tl-x">{esc(r.DETAIL or r.TITLE)}</div></div>',
                unsafe_allow_html=True,
            )


def render_interaction(r):
    """An interaction row expanded: the transcript, and the signals sql/05
    extracted from it. Nothing here calls a model -- every signal shown was paid
    for once during enrichment and is being read back."""
    head = chip(str(r.INTERACTION_CHANNEL or "").title(), "neu")
    head += chip(str(r.INTERACTION_DIRECTION or "").title(), "neu", dim=True)
    if r.FROM_AUDIO:
        head += chip("Transcribed from audio", "ac")
    if r.INTERACTION_LANGUAGE and r.INTERACTION_LANGUAGE != "en":
        head += chip(f"Language {r.INTERACTION_LANGUAGE}", "neu")
    st.markdown(f"<div>{head}</div>", unsafe_allow_html=True)

    if r.SUMMARY_25W:
        st.markdown(
            f'<div class="card-x" style="margin:.5rem 0 .1rem"><b>{esc(r.SUMMARY_25W)}</b></div>',
            unsafe_allow_html=True,
        )

    st.markdown('<p class="sec" style="margin:.7rem 0 .35rem">Transcript</p>',
                unsafe_allow_html=True)
    st.markdown(f'<div class="tr">{esc(r.INTERACTION_BODY or "Not available")}</div>',
                unsafe_allow_html=True)

    # -- extracted signals ----------------------------------------------------
    flags = []
    for cond, label, tone in [
        (r.CHURN_RISK_MENTIONED, "Churn risk voiced", "risk"),
        (r.COMPLAINT, "Complaint", "risk"),
        (r.HARDSHIP_SIGNAL, "Financial hardship", "risk"),
        (r.CONSENT_WITHDRAWAL, "Consent withdrawal", "risk"),
        (r.COMPETITOR_MENTIONED, f"Competitor: {r.COMPETITOR_NAME or 'unnamed'}", "warn"),
        (r.LIFE_EVENT, "Life event", "warn"),
    ]:
        if cond:
            flags.append(chip(label, tone))

    st.markdown('<p class="sec" style="margin:.75rem 0 .35rem">Signals extracted</p>',
                unsafe_allow_html=True)

    sent = (chip(words(r.SENTIMENT_OVERALL), SENT_TONE.get(r.SENTIMENT_OVERALL, "neu"))
            if r.SENTIMENT_OVERALL else chip("Sentiment withheld by confidence gate",
                                             "neu", dim=True))
    intent = (chip(words(r.INTENT), "ac") if r.INTENT
              else chip("Intent withheld by confidence gate", "neu", dim=True))

    st.markdown(
        f"<div>{sent}{intent}{''.join(flags)}</div>"
        + (f'<div style="margin-top:.4rem">'
           + "".join(
               chip(f"{k}: {words(vv)}", SENT_TONE.get(vv, "neu"), dim=True)
               for k, vv in [("Pricing", r.SENTIMENT_PRICING),
                             ("Service", r.SENTIMENT_SERVICE),
                             ("Claims", r.SENTIMENT_CLAIMS)] if vv)
           + "</div>" if any([r.SENTIMENT_PRICING, r.SENTIMENT_SERVICE, r.SENTIMENT_CLAIMS])
           else ""),
        unsafe_allow_html=True,
    )

    extras = [(k, v) for k, v in [
        ("Product mentioned", words(r.PRODUCT_MENTIONED) if r.PRODUCT_MENTIONED else None),
        ("Amount discussed", inr(r.AMOUNT_DISCUSSED_INR) if pd.notna(r.AMOUNT_DISCUSSED_INR) else None),
        ("Callback promised", dstr(r.PROMISED_CALLBACK_DATE) if pd.notna(r.PROMISED_CALLBACK_DATE) else None),
        ("Sentiment score", f"{float(r.SENTIMENT_SCORE):+.2f}" if pd.notna(r.SENTIMENT_SCORE) else None),
        ("Intent confidence", pct(r.INTENT_CONF) if pd.notna(r.INTENT_CONF) else None),
    ] if v]
    if extras:
        st.markdown(
            '<div style="margin-top:.5rem">'
            + "".join(f'<div class="kv"><span class="kv-k">{k}</span>'
                      f'<span class="kv-v n">{v}</span></div>' for k, v in extras)
            + "</div>",
            unsafe_allow_html=True,
        )


def render_actions(cid):
    st.markdown('<p class="sec">Next best action</p>', unsafe_allow_html=True)

    acts = q(f"""SELECT * FROM APP.V_WORKLIST WHERE CUSTOMER_ID = {int(cid)}
                 ORDER BY ACTION_RANK""")

    if acts.empty:
        st.markdown(
            '<div class="pan"><p class="pan-h">No action recommended</p>'
            '<div class="nm-sub">Either no need was identified, or every action '
            'open to this customer was suppressed. The panel below is the '
            'authoritative answer.</div></div>',
            unsafe_allow_html=True,
        )
    else:
        fb = q(f"""SELECT ACTION_CODE, DECISION, REJECT_REASON, DECIDED_BY, DECIDED_AT
                   FROM APP.ACTION_FEEDBACK WHERE CUSTOMER_ID = {int(cid)}
                   QUALIFY ROW_NUMBER() OVER (PARTITION BY ACTION_CODE
                                              ORDER BY DECIDED_AT DESC) = 1""")
        decided = {r.ACTION_CODE: r for r in fb.itertuples()}
        for r in acts.itertuples():
            render_action_card(r, decided.get(r.ACTION_CODE), cid)

    render_suppressed(cid)


REJECT_REASONS = ["NOT_RELEVANT", "ALREADY_CONTACTED", "CUSTOMER_DECLINED",
                  "WRONG_TIMING", "WRONG_CHANNEL", "DATA_LOOKS_WRONG", "OTHER"]


def render_action_card(r, prior, cid):
    cls = "card card-care" if r.PRIORITY_TIER <= 20 else "card card-top"
    tone = CAT_TONE.get(r.CATEGORY, "neu")

    st.markdown(
        f'<div class="{cls}">'
        f'<div class="card-h"><div class="card-t">{esc(r.ACTION_NAME)}</div>'
        f'<div class="card-r">#{int(r.ACTION_RANK)}</div></div>'
        f'<div style="margin-top:.4rem">{chip(words(r.CATEGORY), tone)}'
        f'{chip(r.CHANNEL.title(), "neu")}'
        f'{chip("Servicing obligation", "warn") if r.IS_SERVICING_OBLIGATION else ""}'
        f'</div>'
        f'<div class="card-ev">{inr(r.EXPECTED_VALUE_INR)}</div>'
        f'<div class="card-evl">Expected value · {pct(r.PROPENSITY, 2)} propensity</div>'
        f'<div class="card-x">{esc(r.RATIONALE)}</div>'
        + (f'<div class="disc"><b>Required disclosure</b>{esc(r.DISCLOSURE)}</div>'
           if r.DISCLOSURE else "")
        + "</div>",
        unsafe_allow_html=True,
    )

    with st.expander(f"Evidence · {int(r.EVIDENCE_COUNT)} interactions cited"):
        render_evidence(cid, r.ACTION_CODE, r)

    # -- accept / reject ------------------------------------------------------
    if prior is not None:
        tone_p = "ok" if prior.DECISION == "ACCEPTED" else "risk"
        extra = f" · {words(prior.REJECT_REASON)}" if prior.REJECT_REASON else ""
        st.markdown(
            f'<div style="margin:-.2rem 0 .7rem">'
            f'{chip(words(prior.DECISION) + extra, tone_p)}'
            f'<span style="font-size:.7rem;color:#6B7480;margin-left:6px">'
            f"by {esc(prior.DECIDED_BY)} on {dstr(prior.DECIDED_AT)}</span></div>",
            unsafe_allow_html=True,
        )

    key = f"{cid}_{r.ACTION_CODE}"
    b1, b2 = st.columns(2, gap="small")
    if b1.button("Accept", key=f"acc_{key}", type="primary", use_container_width=True):
        write_feedback(cid, r, "ACCEPTED", None, None)
    if b2.button("Reject", key=f"rej_{key}", use_container_width=True):
        st.session_state[f"rejopen_{key}"] = True

    if st.session_state.get(f"rejopen_{key}"):
        with st.form(f"rejform_{key}", border=True):
            st.markdown('<p class="pan-h">Reject with reason</p>', unsafe_allow_html=True)
            reason = st.selectbox("Reason", REJECT_REASONS,
                                 format_func=words, key=f"rr_{key}")
            note = st.text_area("Note (optional)", key=f"rn_{key}",
                                placeholder="What did the engine get wrong?", height=70)
            s1, s2 = st.columns(2, gap="small")
            if s1.form_submit_button("Record rejection", type="primary",
                                     use_container_width=True):
                write_feedback(cid, r, "REJECTED", reason, note or None)
            if s2.form_submit_button("Cancel", use_container_width=True):
                st.session_state[f"rejopen_{key}"] = False
                st.rerun()

    st.markdown('<div style="height:.35rem"></div>', unsafe_allow_html=True)


def write_feedback(cid, r, decision, reason, note):
    """Append to APP.ACTION_FEEDBACK. DECIDED_BY is CURRENT_USER() resolved
    server-side, so the actor cannot be supplied by the client."""
    session.sql(f"""
        INSERT INTO APP.ACTION_FEEDBACK
          (CUSTOMER_ID, ACTION_CODE, ACTION_RANK, DECISION, REJECT_REASON,
           NOTE, EXPECTED_VALUE_INR, DECIDED_BY, DECIDED_AT)
        SELECT {int(cid)}, {lit(r.ACTION_CODE)}, {int(r.ACTION_RANK)},
               {lit(decision)}, {lit(reason)}, {lit(note)},
               {float(r.EXPECTED_VALUE_INR)}, CURRENT_USER(), CURRENT_TIMESTAMP()
    """).collect()
    st.session_state[f"rejopen_{cid}_{r.ACTION_CODE}"] = False
    q.clear()
    st.rerun()


def render_evidence(cid, action_code, r):
    ev = q(f"""SELECT EVIDENCE_POSITION, EVIDENCE_ID, EVENT_TYPE, OCCURRED_AT,
                      TITLE, DETAIL, SOURCE_TABLE, RESOLVED
               FROM APP.V_NBA_EVIDENCE_RESOLVED
               WHERE CUSTOMER_ID = {int(cid)} AND ACTION_CODE = {lit(action_code)}
               ORDER BY EVIDENCE_POSITION""")

    if ev.empty:
        st.caption(
            "This rationale cites no interaction. It was written from the "
            "deterministic features alone."
        )
    else:
        for e in ev.itertuples():
            if not e.RESOLVED:
                st.markdown(
                    f'<div class="sup"><div class="sup-t">Unresolved citation</div>'
                    f'<div class="sup-x">The rationale cited <code>{esc(e.EVIDENCE_ID)}</code>, '
                    f"which does not resolve to a timeline event. Kept visible rather "
                    f"than dropped so the break is auditable.</div></div>",
                    unsafe_allow_html=True,
                )
                continue
            st.markdown(
                f'<div class="tl" style="grid-template-columns:92px 128px 1fr;'
                f'border:1px solid var(--rule);border-radius:6px;margin-bottom:.3rem">'
                f'<div class="tl-d">{dstr(e.OCCURRED_AT)}</div>'
                f'<div class="tl-t">{chip(words(e.EVENT_TYPE), TL_TONE.get(e.EVENT_TYPE, "neu"))}</div>'
                f'<div class="tl-x">{esc(e.DETAIL or e.TITLE)}</div></div>',
                unsafe_allow_html=True,
            )

    src = getattr(r, "RATIONALE_SOURCE", None)
    st.caption(
        ("Rationale written by claude-opus-5, grounded in the events above and "
         "validated against the permitted action list."
         if src == "LLM" else
         "Rationale assembled from a template over the deterministic drivers. "
         "No model wrote this sentence.")
        + " Expected value, propensity, channel and disclosure are never "
          "model-generated — they come from the scorer and the catalogue."
    )


def render_suppressed(cid):
    """The panel the M10 brief calls the most impressive thing on the screen,
    and instructs must not be hidden. It is rendered expanded by default."""
    sup = q(f"""SELECT ACTION_CODE, ACTION_NAME, CATEGORY, CHANNEL, SUPPRESSION_REASON,
                       SUPPRESSION_REASONS, VALUE_AT_STAKE_INR, GROSS_MARGIN_INR,
                       BLOCKING_RULES, EXEMPT_RULES, REGULATORY_NOTE,
                       IS_SERVICING_OBLIGATION
                FROM APP.V_CUSTOMER_SUPPRESSED WHERE CUSTOMER_ID = {int(cid)}
                ORDER BY VALUE_AT_STAKE_INR DESC""")

    st.markdown('<p class="sec">Suppressed by compliance</p>', unsafe_allow_html=True)

    if sup.empty:
        st.markdown(
            '<div class="pan"><div class="nm-sub">Nothing suppressed. Every action '
            'this customer had a need for passed all rules.</div></div>',
            unsafe_allow_html=True,
        )
        return

    st.caption(
        f"{num(len(sup))} actions this customer had a genuine need for were not "
        f"offered. {inr(sup.VALUE_AT_STAKE_INR.sum(), True)} of exposure withheld, "
        f"{inr(sup.GROSS_MARGIN_INR.sum(), True)} of gross margin at full acceptance."
    )

    with st.expander(f"Show {len(sup)} suppressed actions and the rule that blocked each",
                     expanded=True):
        for s in sup.itertuples():
            # Every rule that blocked, each with the value it fired on. Showing
            # all of them rather than only the headline reason matters: an action
            # refused on three independent grounds is a different compliance fact
            # from one refused on a single ground.
            blocking = [b for b in jarr(s.BLOCKING_RULES) if isinstance(b, dict)]
            rules_html = "".join(
                f'<div style="margin-top:.3rem">'
                f'{chip(words(b.get("rule")), "risk")}'
                f'<span style="font-size:.735rem;color:#6B7480;margin-left:6px">'
                f'{esc(b.get("observed"))}</span></div>'
                for b in blocking
            )
            exempt = [e for e in jarr(s.EXEMPT_RULES) if isinstance(e, dict)]
            exempt_html = "".join(
                f'<div style="margin-top:.3rem">'
                f'{chip(words(e.get("rule")) + " — waived", "warn")}'
                f'<span style="font-size:.735rem;color:#6B7480;margin-left:6px">'
                f'{esc(e.get("observed"))}</span></div>'
                for e in exempt
            )

            st.markdown(
                f'<div class="sup">'
                f'<div class="sup-h"><div class="sup-t">{esc(s.ACTION_NAME)}</div>'
                f'<div>{chip(words(s.SUPPRESSION_REASON), "risk")}</div></div>'
                f'<div class="sup-x">'
                f'{esc(words(s.CATEGORY))} via {esc(str(s.CHANNEL).title())} · '
                f'{inr(s.VALUE_AT_STAKE_INR)} at stake · '
                f'{len(blocking)} rule{"s" if len(blocking) != 1 else ""} blocked'
                f"</div>"
                f"{rules_html}{exempt_html}"
                + (f'<div class="sup-x" style="margin-top:.35rem">'
                   f'{esc(s.REGULATORY_NOTE)}</div>'
                   if exempt and s.REGULATORY_NOTE else "")
                + "</div>",
                unsafe_allow_html=True,
            )

        st.caption(
            "A suppressed action is kept with its full trace rather than filtered "
            "away, because the question a compliance reviewer asks is not why a "
            "customer was contacted but why another was not. Rules waived under a "
            "servicing obligation are recorded separately from rules that did not "
            "apply — they are different compliance facts."
        )


# =============================================================================
# 7 — SCREEN 3 · ASK
# -----------------------------------------------------------------------------
# APP.RM_COPILOT via SNOWFLAKE.CORTEX.DATA_AGENT_RUN. Non-streaming: the whole
# answer arrives at once behind a spinner.
#
# The reasoning is exposed rather than summarised. The response carries the
# agent's plan, every tool it called, the SQL Cortex Analyst generated, the
# result set that came back and the token spend, and all of it goes in an
# expander -- an agent whose SQL you cannot see is an agent you cannot check.
# =============================================================================

SUGGESTED = [
    "Which customers have the highest expected value actions this week?",
    "How many actions did compliance block, and which rule blocked the most?",
    "What should I do about customer 2397, and what was suppressed for them?",
    "Which customers mentioned a competitor in the last quarter?",
]


def screen_ask():
    header(
        "Ask",
        'Natural language over the book via <b>APP.RM_COPILOT</b> · '
        'Cortex Analyst on the semantic view, Cortex Search on interactions and '
        'product clauses, plus the next-best-action tool',
    )

    if "chat" not in st.session_state:
        st.session_state.chat = []

    if not st.session_state.chat:
        st.markdown('<p class="sec">Try one of these</p>', unsafe_allow_html=True)
        cols = st.columns(2, gap="small")
        for i, s in enumerate(SUGGESTED):
            if cols[i % 2].button(s, key=f"sug_{i}", use_container_width=True):
                st.session_state.pending = s
                st.rerun()
        st.caption(
            "Each question costs orchestration tokens, plus 0.067 credits when it "
            "routes to Cortex Analyst. Nothing is sent until you ask."
        )

    for m in st.session_state.chat:
        with st.chat_message(m["role"]):
            st.markdown(m["text"])
            if m.get("trace"):
                render_trace(m["trace"])

    typed = st.chat_input("Ask about a customer or the book")
    pending = st.session_state.pop("pending", None)
    prompt = typed or pending

    if prompt:
        st.session_state.chat.append({"role": "user", "text": prompt})
        with st.chat_message("user"):
            st.markdown(prompt)
        with st.chat_message("assistant"):
            with st.spinner("Planning, calling tools, composing…"):
                text, trace = ask_agent(prompt)
            st.markdown(text)
            if trace:
                render_trace(trace)
        st.session_state.chat.append({"role": "assistant", "text": text, "trace": trace})
        st.rerun()

    if st.session_state.chat:
        if st.button("Clear conversation"):
            st.session_state.chat = []
            st.rerun()


def ask_agent(prompt):
    """Send the conversation and return (answer_text, trace).

    History is sent as text-only turns. The assistant's tool_use and
    tool_result blocks are deliberately not replayed: they are large, they are
    already reflected in the assistant text that followed them, and replaying a
    tool result as conversational context invites the model to trust a stale
    number instead of re-querying.
    """
    msgs = []
    for m in st.session_state.chat:
        if m["role"] in ("user", "assistant") and m.get("text"):
            msgs.append({"role": m["role"],
                         "content": [{"type": "text", "text": m["text"]}]})
    if not msgs or msgs[-1]["role"] != "user":
        msgs.append({"role": "user", "content": [{"type": "text", "text": prompt}]})

    body = json.dumps({"messages": msgs})
    try:
        raw = session.sql(
            f"SELECT SNOWFLAKE.CORTEX.DATA_AGENT_RUN({lit(AGENT)}, {lit(body)}) AS R"
        ).collect()[0]["R"]
    except Exception as e:  # noqa: BLE001 - surfaced to the user verbatim
        return (f"The agent call failed.\n\n```\n{e}\n```\n\n"
                "If this is a privilege error, note that Cortex Agents resolve "
                "privileges from the querying user's **default** role, not the "
                "session role — see `sql/18b_agent_grants_admin.sql`."), None

    try:
        resp = json.loads(raw) if isinstance(raw, str) else raw
    except (ValueError, TypeError):
        return str(raw), None

    text, trace = [], {"thinking": [], "tools": [], "sql": [], "results": [],
                       "suggested": [], "usage": None, "parse_error": None}

    # The answer text is extracted first and separately from the trace. The two
    # have very different value if something goes wrong: losing the trace costs a
    # reviewer some transparency, losing the answer costs the user the reply. So a
    # surprise in the trace shape must not be able to take the answer down with
    # it, which is exactly what happened when suggested_queries turned out to be
    # a list rather than an object.
    for c in resp.get("content", []) or []:
        if isinstance(c, dict) and c.get("type") == "text":
            text.append(c.get("text", ""))
    answer = "\n\n".join(x for x in text if x).strip() or "_No text returned._"

    try:
        for c in resp.get("content", []) or []:
            if not isinstance(c, dict):
                continue
            t = c.get("type")
            if t == "thinking":
                trace["thinking"].append((c.get("thinking") or {}).get("text", ""))
            elif t == "tool_use":
                tu = c.get("tool_use") or {}
                trace["tools"].append({"name": tu.get("name"), "type": tu.get("type"),
                                       "input": tu.get("input") or {}})
                sql = (tu.get("input") or {}).get("sql")
                if sql:
                    trace["sql"].append(sql)
            elif t == "tool_result":
                for item in ((c.get("tool_result") or {}).get("content") or []):
                    rs = ((item.get("json") or {}).get("result_set")) or {}
                    if rs:
                        trace["results"].append(rs)
            elif t == "suggested_queries":
                # The block is {"type": "suggested_queries",
                #               "suggested_queries": [{"query": "..."}, ...]} --
                # the list sits directly under the key, not wrapped in another
                # object. The first version unwrapped one level too many and
                # raised "'list' object has no attribute 'get'" the first time the
                # agent returned follow-ups, which the AppTest check missed
                # because it never submitted a question.
                trace["suggested"] = [
                    s.get("query") for s in (c.get("suggested_queries") or [])
                    if isinstance(s, dict) and s.get("query")
                ]
        trace["usage"] = (resp.get("metadata") or {}).get("usage")
    except Exception as e:  # noqa: BLE001 - the answer survives a trace failure
        trace["parse_error"] = f"{type(e).__name__}: {e}"

    return answer, trace


def result_frame(rs):
    """Turn an agent result_set payload into a DataFrame."""
    meta = rs.get("resultSetMetaData") or {}
    cols = [c.get("name") for c in (meta.get("rowType") or [])]
    data = rs.get("data") or []
    if not cols:
        return None
    return pd.DataFrame(data, columns=cols)


def render_trace(tr):
    n_tools = len(tr.get("tools", []))
    n_sql = len(tr.get("sql", []))
    label = f"Reasoning · {n_tools} tool call{'s' if n_tools != 1 else ''}"
    if n_sql:
        label += f" · {n_sql} generated quer{'ies' if n_sql != 1 else 'y'}"

    with st.expander(label):
        if tr.get("parse_error"):
            st.caption(
                f"The answer above is complete, but part of the reasoning trace "
                f"could not be read: {tr['parse_error']}"
            )
        if tr.get("thinking"):
            st.markdown('<p class="sec">Plan</p>', unsafe_allow_html=True)
            for t in tr["thinking"]:
                if t.strip():
                    st.markdown(f'<div class="card-x">{esc(t.strip())}</div>',
                                unsafe_allow_html=True)

        if tr.get("tools"):
            st.markdown('<p class="sec">Tools called</p>', unsafe_allow_html=True)
            for t in tr["tools"]:
                st.markdown(
                    f'<div>{chip(t["name"] or "unnamed", "ac")}'
                    f'{chip(t["type"] or "", "neu", dim=True)}</div>',
                    unsafe_allow_html=True,
                )
                inp = {k: v for k, v in (t["input"] or {}).items() if k != "sql"}
                if inp:
                    st.code(json.dumps(inp, indent=2)[:1400], language="json")

        if tr.get("sql"):
            st.markdown('<p class="sec">Generated SQL</p>', unsafe_allow_html=True)
            for s in tr["sql"]:
                st.code(s, language="sql")

        if tr.get("results"):
            st.markdown('<p class="sec">Tool results</p>', unsafe_allow_html=True)
            for rs in tr["results"]:
                df = result_frame(rs)
                if df is not None and not df.empty:
                    st.dataframe(df, use_container_width=True, hide_index=True)
                elif df is not None:
                    st.caption("Query returned no rows.")

        if tr.get("suggested"):
            st.markdown('<p class="sec">Follow-ups the agent suggested</p>',
                        unsafe_allow_html=True)
            for s in tr["suggested"]:
                st.markdown(f'<div class="card-x">· {esc(s)}</div>',
                            unsafe_allow_html=True)

        u = tr.get("usage")
        if u:
            for tc in (u.get("tokens_consumed") or []):
                i = (tc.get("input_tokens") or {}).get("total")
                o = (tc.get("output_tokens") or {}).get("total")
                st.caption(
                    f"Orchestrated by {tc.get('model_name')} · "
                    f"{num(i)} input tokens, {num(o)} output tokens"
                )


# =============================================================================
# 8 — SCREEN 4 · IMPACT
# -----------------------------------------------------------------------------
# What the guardrail layer is worth, in rupees.
#
# The comparison is the targeted book against a contact-everyone campaign over
# every (customer x action) pair that passed the need test. That is the campaign
# a bank runs when it targets on need alone, which is the system this project
# argues against, so it is the honest counterfactual.
#
# Acceptance is a slider substituting for propensity, not multiplying it. See
# APP.V_IMPACT_BASE: GROSS_MARGIN_AT_FULL_ACCEPTANCE deliberately excludes the
# engine's propensity so the slider is the only acceptance assumption in play.
# =============================================================================

def screen_impact():
    header(
        "Impact simulator",
        "The targeted book against soliciting every identified need · "
        "and what the compliance layer actually costs",
    )

    base = q("""SELECT ARM, CHANNEL, CATEGORY, IS_SALES_ACTION, CONTACTS, CUSTOMERS,
                       VALUE_AT_STAKE_INR, GROSS_MARGIN_AT_FULL_ACCEPTANCE
                FROM APP.V_IMPACT_BASE""")

    st.markdown('<p class="sec">Assumptions</p>', unsafe_allow_html=True)
    c1, c2, c3, c4, c5 = st.columns(5, gap="medium")
    acc = c1.slider("Acceptance rate", 0.5, 25.0, 8.0, 0.5, format="%.1f%%") / 100
    cost = {
        "CALL": c2.number_input("Cost per call (₹)", 0.0, 500.0, 45.0, 5.0),
        "EMAIL": c3.number_input("Cost per email (₹)", 0.0, 50.0, 0.20, 0.05, format="%.2f"),
        "SMS": c4.number_input("Cost per SMS (₹)", 0.0, 50.0, 0.15, 0.05, format="%.2f"),
    }
    # Default 0, deliberately. A penalty schedule is not in this dataset and
    # inventing one would put a fabricated number at the centre of the argument.
    # At zero the screen shows the uncomfortable truth on its own terms; the
    # breakeven tile then derives the penalty at which compliance pays for
    # itself, which is a figure the model can honestly produce.
    penalty = c5.number_input("Penalty per breach (₹)", 0.0, 100000.0, 0.0, 25.0,
                              help="Expected regulatory and remediation cost per "
                                   "non-compliant solicitation, if it were made. "
                                   "Not present in the data — set it to test a view.")

    base["CONTACT_COST"] = base.apply(
        lambda r: r.CONTACTS * cost.get(r.CHANNEL, 0.0), axis=1)
    base["REVENUE"] = base.GROSS_MARGIN_AT_FULL_ACCEPTANCE * acc

    def arm(*names):
        return base[base.ARM.isin(names)]

    pub, cap, sup = arm("PUBLISHED"), arm("ELIGIBLE_NOT_PUBLISHED"), arm("SUPPRESSED")
    every = base

    t_rev, t_cost, t_n = pub.REVENUE.sum(), pub.CONTACT_COST.sum(), int(pub.CONTACTS.sum())
    e_rev, e_cost, e_n = every.REVENUE.sum(), every.CONTACT_COST.sum(), int(every.CONTACTS.sum())
    s_rev, s_cost, s_n = sup.REVENUE.sum(), sup.CONTACT_COST.sum(), int(sup.CONTACTS.sum())

    t_net = t_rev - t_cost
    # The penalty lands only on the solicitations a rule would have blocked --
    # those are the non-compliant ones, and they are the only ones a regulator
    # would price.
    e_net = e_rev - e_cost - penalty * s_n
    gap = t_net - e_net                       # positive => targeting wins
    breakeven = (e_rev - e_cost - t_net) / s_n if s_n else 0.0

    # -- headline -------------------------------------------------------------
    # There is no "uplift from targeting" tile, and that is the finding rather
    # than an omission. At every acceptance rate this dataset supports, ignoring
    # compliance and soliciting all 16,475 needs earns more gross margin than the
    # 3,917-action book, because the blocked actions are individually larger and
    # a call costs Rs 45 against margins in the thousands. Labelling a negative
    # number "uplift" would have been the dishonest way to present that. What
    # compliance costs is shown as a cost, and the breakeven tile gives the one
    # number that makes the commercial case if it is true.
    st.markdown(
        '<div class="kpis">'
        + kpi("Targeted book, net", inr(t_net, True),
              f"<b>{num(t_n)}</b> contacts · {inr(t_rev, True)} margin "
              f"less {inr(t_cost, True)} cost", small=True)
        + kpi("Contact everyone, net", inr(e_net, True),
              f"<b>{num(e_n)}</b> contacts"
              + (f" · less {inr(penalty * s_n, True)} in penalties"
                 if penalty else " · no penalty assumed"), small=True)
        + kpi("What compliance costs", inr(-gap if gap < 0 else 0, True) if gap < 0
              else inr(gap, True),
              ("forgone net contribution from <b>" + num(s_n) + "</b> blocked "
               "solicitations" if gap < 0 else
               "targeting is <b>ahead</b> at this penalty"), small=True)
        + kpi("Contact cost avoided", inr(s_cost, True),
              f"<b>{num(s_n)}</b> solicitations never made", small=True)
        + kpi("Breakeven penalty", inr(breakeven), 
              "per blocked solicitation · above this, suppression pays "
              "commercially too", small=True)
        + "</div>",
        unsafe_allow_html=True,
    )

    st.caption(
        f"At {acc*100:.1f}% acceptance and no assumed penalty, soliciting all "
        f"{num(e_n)} needs would earn {inr(e_rev - e_cost, True)} net against the "
        f"targeted book's {inr(t_net, True)}. **Obeying the rules costs money, and "
        f"this screen says so.** The compliance layer is a duty-of-care and "
        f"regulatory constraint under TRAI, IRDAI and the RBI Fair Practices Code, "
        f"not a revenue optimisation — and it withholds "
        f"{inr(s_rev - s_cost, True)} of net contribution to honour it. "
        f"It becomes commercially self-funding once a non-compliant solicitation "
        f"is expected to cost more than **{inr(breakeven)}** in penalty, "
        f"remediation and churn — a figure this dataset does not contain, which "
        f"is why the input above defaults to zero."
    )

    # -- the three arms -------------------------------------------------------
    st.markdown('<p class="sec">Where the 16,475 needs went</p>', unsafe_allow_html=True)

    rows = []
    for label, d, note in [
        ("Published — an RM works these", pub,
         "Passed every rule and made the top three for the customer"),
        ("Held back by the three-per-customer cap", cap,
         "Compliant, but a higher-value action outranked it"),
        ("Blocked by a compliance rule", sup,
         "Genuine need, no contact — the guardrail layer"),
    ]:
        rows.append(
            f"<tr><td>{esc(label)}<br/>"
            f'<span style="font-size:.7rem;color:#8B939E">{esc(note)}</span></td>'
            f'<td class="n">{num(int(d.CONTACTS.sum()))}</td>'
            f'<td class="n">{inr(d.VALUE_AT_STAKE_INR.sum(), True)}</td>'
            f'<td class="n">{inr(d.REVENUE.sum(), True)}</td>'
            f'<td class="n">{inr(d.CONTACT_COST.sum(), True)}</td></tr>'
        )

    c1, c2 = st.columns([1.5, 1], gap="medium")
    with c1:
        st.markdown(
            '<table class="t"><tr><th>Outcome</th><th class="r">Contacts</th>'
            '<th class="r">At stake</th><th class="r">Margin</th>'
            '<th class="r">Contact cost</th></tr>'
            + "".join(rows)
            + f'<tr><td class="tot">Contact-everyone baseline</td>'
              f'<td class="n tot">{num(e_n)}</td>'
              f'<td class="n tot">{inr(every.VALUE_AT_STAKE_INR.sum(), True)}</td>'
              f'<td class="n tot">{inr(e_rev, True)}</td>'
              f'<td class="n tot">{inr(e_cost, True)}</td></tr></table>',
            unsafe_allow_html=True,
        )
        st.caption(
            "The middle row is neither a compliance saving nor a book an RM can "
            "work — separating it keeps the guardrail figure honest, because "
            "folding it into either arm would misattribute 123 actions."
        )

    with c2:
        by_rule = q("""SELECT SUPPRESSION_REASON, VIA_CALL, VIA_EMAIL, VIA_SMS
                       FROM APP.V_SUPPRESSION_SUMMARY""")
        by_rule["SAVED"] = (by_rule.VIA_CALL * cost["CALL"]
                            + by_rule.VIA_EMAIL * cost["EMAIL"]
                            + by_rule.VIA_SMS * cost["SMS"])
        by_rule["RULE"] = by_rule.SUPPRESSION_REASON.map(words)
        st.altair_chart(
            bar_chart(by_rule.sort_values("SAVED", ascending=False),
                      "SAVED", "RULE", "Contact cost avoided (₹)"),
            use_container_width=True,
        )

    # -- breakeven ------------------------------------------------------------
    st.markdown('<p class="sec">How the two strategies scale with acceptance</p>',
                unsafe_allow_html=True)

    pub_margin = pub.GROSS_MARGIN_AT_FULL_ACCEPTANCE.sum()
    all_margin = every.GROSS_MARGIN_AT_FULL_ACCEPTANCE.sum()
    grid = []
    for a in [x / 1000 for x in range(5, 251, 5)]:
        tn = pub_margin * a - t_cost
        en = all_margin * a - e_cost - penalty * s_n
        grid += [{"Acceptance": a, "Net contribution": tn, "Strategy": "Targeted book"},
                 {"Acceptance": a, "Net contribution": en, "Strategy": "Contact everyone"}]
    g = pd.DataFrame(grid)

    # NOTE: configure_* must be applied to the OUTERMOST chart, never to a layer
    # member. Altair raises "Objects with 'config' attribute cannot be used within
    # LayerChart" if the breakeven line carries its own config and is then layered
    # with the acceptance-rate rule, which is what the first version did.
    chart = (
        alt.Chart(g)
        .mark_line(size=2)
        .encode(
            x=alt.X("Acceptance:Q", axis=alt.Axis(format="%", title="Acceptance rate",
                                                  grid=True, gridColor="#EDEFF2",
                                                  labelColor="#8B939E", titleColor="#6B7480",
                                                  labelFontSize=10, titleFontSize=10)),
            y=alt.Y("Net contribution:Q",
                    axis=alt.Axis(title="Net contribution (₹)", grid=True,
                                  gridColor="#EDEFF2", labelColor="#8B939E",
                                  titleColor="#6B7480", labelFontSize=10, titleFontSize=10)),
            color=alt.Color("Strategy:N",
                            scale=alt.Scale(domain=["Targeted book", "Contact everyone"],
                                            range=["#1B4D7A", "#A32219"]),
                            legend=alt.Legend(orient="top-left", title=None,
                                              labelFontSize=11)),
            strokeDash=alt.StrokeDash("Strategy:N", legend=None),
            tooltip=[alt.Tooltip("Acceptance:Q", format=".1%"),
                     alt.Tooltip("Net contribution:Q", format=",.0f"),
                     "Strategy:N"],
        )
    )
    rule = (alt.Chart(pd.DataFrame({"a": [acc]})).mark_rule(
        color="#8B939E", strokeDash=[3, 3]).encode(x="a:Q"))

    st.altair_chart(
        (chart + rule).properties(height=260).configure_view(strokeWidth=0),
        use_container_width=True,
    )
    st.caption(
        "The dashed vertical line is the acceptance rate set above. With no "
        "penalty assumed the broad campaign dominates at every acceptance rate "
        "this dataset supports, and the two lines never cross — the blocked "
        "actions are individually larger than the published ones and a call at "
        "₹45 is cheap against margins in the thousands. Raise the penalty input "
        f"above ₹{breakeven:,.0f} and the ordering inverts. That is the honest "
        "shape of the trade: suppression is a duty-of-care and regulatory "
        "position first, and a commercial one only once a breach is priced."
    )

    fb = q("""SELECT COUNT(*) N, COUNT_IF(DECISION='ACCEPTED') ACC,
                     SUM(IFF(DECISION='ACCEPTED', EXPECTED_VALUE_INR, 0)) EV
              FROM APP.ACTION_FEEDBACK""").iloc[0]
    if int(fb.N or 0) > 0:
        st.markdown('<p class="sec">Recorded so far</p>', unsafe_allow_html=True)
        st.caption(
            f"{num(fb.N)} decisions recorded by RMs, {num(fb.ACC)} accepted, "
            f"{inr(fb.EV, True)} of expected value accepted. Observed acceptance "
            f"{pct((fb.ACC or 0) / fb.N)} — once this is large enough it replaces "
            f"the slider above."
        )


# =============================================================================
# 9 — SHELL
# =============================================================================

SCREENS = {
    "Portfolio cockpit": screen_cockpit,
    "Customer 360": screen_customer,
    "Ask": screen_ask,
    "Impact": screen_impact,
}

with st.sidebar:
    st.markdown(
        '<div style="padding:0 0 .1rem"><div style="font-size:1.0rem;font-weight:680;'
        'letter-spacing:-.014em;color:#15181C">C360 · Next Best Action</div>'
        '<div style="font-size:.7rem;color:#6B7480;margin-top:.15rem;line-height:1.4">'
        'Indian bank and insurer group<br/>5,000 customers · one spine</div></div><hr/>',
        unsafe_allow_html=True,
    )

    # Nav is four buttons rather than st.radio. A radio's selected dot takes its
    # colour from the theme primaryColor, which is Streamlit red and cannot be
    # set from inside the script -- so the single most prominent mark on every
    # screen was an accent this design does not use. Buttons are styled here, so
    # the active item carries the one accent and nothing else does.
    if "nav" not in st.session_state:
        st.session_state.nav = "Portfolio cockpit"
    for name in SCREENS:
        if st.button(name, key=f"nav_{name}", use_container_width=True,
                     type="primary" if st.session_state.nav == name else "secondary"):
            st.session_state.nav = name
            st.rerun()
    choice = st.session_state.nav

    st.markdown("<hr/>", unsafe_allow_html=True)
    kk = q("SELECT * FROM APP.V_PORTFOLIO_KPI").iloc[0]
    st.markdown(
        '<div style="font-size:.7rem;color:#6B7480;line-height:1.75">'
        f'Positions as of <b>{dstr(kk.AS_OF_DATE)}</b><br/>'
        f'<b>{num(kk.ACTIONS_PUBLISHED)}</b> actions published<br/>'
        f'<b>{num(kk.ACTIONS_SUPPRESSED)}</b> suppressed by rule<br/>'
        f'<b>{num(kk.DECISIONS_RECORDED)}</b> RM decisions recorded'
        "</div>",
        unsafe_allow_html=True,
    )
    st.markdown("<hr/>", unsafe_allow_html=True)
    st.markdown(
        '<div style="font-size:.665rem;color:#8B939E;line-height:1.6">'
        "Expected value and eligibility are deterministic SQL. A model writes the "
        "rationale and never a number. Synthetic data throughout."
        "</div>",
        unsafe_allow_html=True,
    )

SCREENS[choice]()

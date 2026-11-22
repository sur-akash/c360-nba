"""
Compass360 · Next Best Action — portfolio build (Postgres / Neon)
================================================================================
The public version of the Streamlit in Snowflake app in ../app/. Same screens,
same design, same data: the full Snowflake export loaded into Postgres, with the
engine's views ported from Snowflake SQL (see db/02_views.sql). Two things
differ, both because they need Snowflake:

  * ASK replays thirteen recorded runs of the live Cortex Agent (APP.RM_COPILOT)
    instead of calling it. Answers and reasoning traces are unedited.
  * ACCEPT / REJECT writes to APP.ACTION_FEEDBACK in Postgres, attributed to
    DEMO_VISITOR rather than a Snowflake user.

The original M10 notes follow.

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

import base64
import html
import json
from datetime import datetime, timedelta, timezone
from decimal import Decimal
from pathlib import Path

import altair as alt
import pandas as pd
import streamlit as st
import sqlalchemy as sa

import live_agent

AGENT = "C360_NBA.APP.RM_COPILOT"
DEFAULT_CUSTOMER = 2397

APP_NAME = "Compass360"
TEAM_NAME = "Coskilled"
# The team mark: the snowflake from coskilled.webp, cropped above the wordmark
# (the name is set in type beside it, where it stays legible), 112px square,
# WebP, inlined as a data URI. Inlined because an app in Streamlit in Snowflake
# cannot fetch an external image and a data URI has no stage path to get wrong.
# Empty means no logo is drawn and the masthead shows the team name alone.
TEAM_LOGO = "data:image/webp;base64,UklGRioKAABXRUJQVlA4IB4KAADQLACdASpwAHAAPjEWiUMiISETmXa4IAMEswBebDlFA+W80Cvf378X/1v3Idu3Tfmf+N/qPjs9SX6M9gf9OP1e6xPmD/nv+u9V/0s/271AP7N/pOsc9BHy5/3M+Ev9u//F/pPgA/YO6T+Ifka9g+0ugL/Gvwn+3/LTlR3j388/0Phm1cfFr9gNe/j39D/P+9SewP+sqBRWuW0tMjFibNk+Ybzcm8u3FV6EJeAME1rjhUIgqa3MMa7Xzv0NlgBT2YF61uFV85XL/neehk7ZrBwUHuk1Om9bZFd7FPomebCO9R4rQ8R+2v5FEH+Q5knLcDF8OXQ1e9MjhzmqtHwu5qTd7rKU3zHni0e//7mQmNfJTFABJ9R7cXaY0W56A6m/wVpaZV3rv2+GSSV4Y+INg1drjCRK4KjzMvl2L6Ap89EG3YIFRHq7oYkhlbZTsvaavB19xEOzoAd+BSf3zB2nfVRYDsatRT7ItyA69S5bwZ7gAP796hudf9T7Ib8GH/5Vdu44kqu+HFY59YnkK7YmJZk6eE4/9qBNYIY7jh02/HqmByrUSdplvZlqBBkyV1D8V8d//K3XKgU3flrTlWi/cnV4PfiXwihaZHN58pnBKijy2Ku+L6GiAKjevlRnuFO9IlLZnuFPhKqSPxhMb2fz6lbFarOJRK7pZt/PIaoAHnYhBtp1Mgh92hxKW/2xRBxL4l/ztQ9bINULRdaKXM3Lb9HTKbjx+Z3JU0WZGyhJdt+9xMZRlfWvn/Mx8LF72MUT0HL936Cw5YhQBlbBy/IH0MPgvzXaIyBLMxPeUdn2OSyvo6sCt52jXFXpziYG8gGrJvz5ky72z0GkMPh4lE7KpArhjlNMkAItct6pgxcLnPaqjwOTEC9qV15GkFUT6J5DIXbz+DZ6CkN1NSspvgnZBi/879Z4EpRSjvnjT5aU9XFFf4tisfCe3ZlNtskTRRtJc+WMpN6zKq/lCgr+unwJh7EpoTN8h6MlkwMeAZtxfvw13RMJBA8H9oMGamon5a6WCfJHPJHVgzuq3ZlKa3ziZ1Aqjnd+i5omrjSi88HVkNHHsCpDl7SdiSju/fdT7S7+JyxxNh4zshuVvn9enUDBZkoVmLJOgajZ39CRHy4LHSmiOILldsoNpnaVwdkwpEz/CuxVQ6NCyP/31WjuTqRifvLtZ/1KRz9LEQPy6YaQvKdquIbY0Da3NXJjxkZ0gi7mQ/Ki7pL73FmUTLDeLZUB50lXCZN6tUTx+B5uLk+iqZj3i8WiVED3zLNXaVX2zl6XuaJ5PqoksmFFjuYkrSG8TnKWcby81Mpj/8TaDu7tMXL21eCdQe9I8bW9WJH51CmMAdkiNzuXnVLZqbdxlBINnQZRHjMn2rP0QfRCqHrJnzYQNOia4R6d013+QTvyYPvFGdOV4dbbJPxRS1Olpm+bW84BuasG0ACu74oTsoSH/+CfCPhos+82QKUPb4yGkPIMXf7uCHy6I1nWDh+dNn2nMkgqhrQgyeVN5+tuFGDxP7RVbfWSCDNWLpVlJswDJp4ikmp6FUJFdNVdJEluPkp28/0sbYz3+ncoffPZok9CjuTl8oXVyfsQjsEpYaqVLVU9z7NQdtKL7tYF//74fnY1v1P+0ycZNbn2f1ZEM8G1V6C0bOwMPIXSB6C2yvULnhbk0iQ1dBzMgYsek3UKwP4AjishJKdnoRgPe2WQwlzXGXGXhQ3HlAp0ODH59e54NcVs+Ag/XdMOww/AP9rt0moXq7eE/0v2gQG3OWL6BlZXEZunWpHHcc8nKNNAWIBItm3hlAJW8XR0qhiiUB5LUBHp0ptdUo7YhKiB1zi3LW0cYRtWbtkjz61oORDGeVCVcGKza+KLMUVuaOMaQQbXaBQZ9lg/W6e9iZLKqoOMPulVENMumKuIHiMmtFyCS58klFO8OkvLm+ejKAnjWOmGSor9X47Ko1u77vTZds9y0joVwVpGIN/oSKxlRrWXZLIhSC6QllioA8HVfSOuqmYdj/8Hgh10P6/xu5M/MYmcrTWsN4J86/dfq7K5jJDYiB9jOYY3r8pX+e1GiA+L9SBJXMklRsUkKXJYMzv7ArK97znWS+kiuoAjerATLbExG4EG1ayxNEZFh/aUN6+gJil51KKaS+fPt3wlKi6rk97oKl8DWVj38x3lAFwUorzDdYOw0EcNHJcl3ahOL4qU0mkEbC9oF95AUIUKMzd8SCAAy6LZ73wApHTEt74o8hPJe6wK1gPLRtsO72EW7+AWEb+1zevY/nIN8udARrhFcCVA74G5ZPYq6W2Y5a9YlZM/O0L6RZr3RO9wNs8ffXojkS0Q9ioxRsSXjdPc/FJ1gvaPM/zO5s+wUfAxf5uxcmom0379kj/TXtjIrp9BLZiy6rXH7hm9yGDE7tBFr4YZhOJjaTS2Me/lzwMaRq6NfKef64bI6mzYbHL0VByw4i4cpi5WK1Zp0Rqc7XMq4skDQSqpdDXVE8q8zA1a81Fo/gadqQyAXZz5Wi3Z7F1Xjci3aJGf+bToXVK6CvDbRJEU9eOYU/vgwZ9sSUuWpiIpHl2iO45QGq213wylhN26g0Gwv0Ogwd3HAq3RNKXvWZKzSytBnaOHc+59qkndlV0XDX0lzhCQNNKajMEAwWr+dwK6WW88DbgwzWXCX14fqce8weWRsh/1MCZZtnzgx/lK8y1EUxRULKihb2Wcu5yPJHS0kP/5yppMeLc+cwfH1kw/lA/L0xzl3zBUwB50EH5lebE0kHmdze5go+DvRRADYWPNk9BfP1p2viyei09+iDmXasCaiVpnAa1GEWscdm97GYjr0UzN+Ms4RLGgOFVWfFiWrIxKMVg7TG2q966IiCx4f3bCd9LP/tTS1p3+x48MH7Q3Pd4oIBp59FMFfvcB2zsBey1TEPamPr0FkfFhJb7XqV9Co3kv61qvCXW7B+wrddE2Ip984uxRyBxqUhytfe+9yiRZByY+j4yBe+CUXQEwHfMQCKt6uuzutTM20kTXKaGIpdbiHPC+xgh1f1DwBVxV5fZVWDh/T8ZjANTSK0klQPPmRgnpQbJwcU08MF5sG20I4jtWed5SVNL4+ykK/zbrVMQX5U4xVAbie/11W9czSSrQHUZYIeFe2WyvO3+q3WKPA20ISvpe8mtF62VQQXGoxrGV/Ea8GX6Q5LnAnmbkt8X76P5Y2+ChszTPTG2Uh+tg6N3kxiLWj2ML5kCpvOrhgIf3CkBucqtuDwhZu4rgCEN6I/flK8vRCEnPXdx7C12iypQZZVgk6kucCJPqLkFhf3fhZNrWRNRLSysGX3xczWsYPz2znzucy9e51bHopmup6yB1NIIR+fxavuzsmdHWIGb18+b4i7vi5/jZL3I6ILu8Rt/rHHhLPrW6zY4Vilwig2i6zsmxq/sG2NT2A/G+hfUm3rSx6zLQroCbiIbz5HsQ8mFkTiZMlAkMeDwCI+UwiMqAAAAA"

st.set_page_config(
    page_title="Compass360 · Next Best Action",
    layout="wide",
    initial_sidebar_state="expanded",
)



@st.cache_resource(show_spinner=False)
def _engine():
    """One pooled engine per process. The URL comes from Streamlit secrets:

        [connections.neon]
        url = "postgresql://USER:PASSWORD@HOST/DBNAME?sslmode=require"

    pool_pre_ping matters on Neon: the compute scales to zero after five idle
    minutes and drops open connections, and a pre-ping replaces a dead one
    instead of failing the first query after a quiet spell."""
    url = st.secrets["connections"]["neon"]["url"]
    if url.startswith("postgres://"):
        url = "postgresql://" + url[len("postgres://"):]
    if url.startswith("postgresql://"):
        url = "postgresql+psycopg://" + url[len("postgresql://"):]
    return sa.create_engine(url, pool_pre_ping=True, pool_size=3, max_overflow=2,
                            pool_recycle=240)


engine = _engine()


# =============================================================================
# 1 — DESIGN TOKENS
# -----------------------------------------------------------------------------
# The palette is the Coskilled mark's: a glowing ice-blue snowflake on deep
# navy. Navy (--night, --navy) is the frame -- the sidebar and the masthead --
# and ice (--ice, #28B6E8) is used only on that frame, where it reads at 7:1.
# On white the same ice is 2.4:1 and unreadable, so the working accent on light
# surfaces (--ac, glacier) is the same hue taken deep enough for 6:1. Four
# severity tones mean state and only state; everything else is neutral ink.
#
# Contrast is set for a projector and a shared screen, not for a laptop at arm's
# length: secondary text is a dark slate rather than a mid grey, and every
# surface has a visible edge on a canvas dark enough to separate it.
# =============================================================================

CSS = """
<style>
:root{
  --ink:#15181C; --ink2:#2F363F; --mut:#4F5965; --mut2:#66707C;
  --rule:#CDD3DB; --rule2:#E3E7EC; --edge:#B8C0CB; --surf:#FFFFFF; --canvas:#EBEFF4;
  --ac:#0A6A94; --ac-dk:#08557A; --ac-soft:#DCEFF7;
  --night:#0F1A2E; --navy:#182641; --ice:#28B6E8; --frost:#C9D6E5; --frost2:#93A6BD;
  --ok:#17603C;  --ok-bg:#DDF0E5;
  --warn:#7A4F00; --warn-bg:#FBEBC8;
  --risk:#9B1F17; --risk-bg:#F9DEDA;
  --neu:#48525F;  --neu-bg:#E6E9EE;
  --lift:0 1px 2px rgba(16,24,40,.07);
  --num:"SF Mono",ui-monospace,"Roboto Mono",Menlo,Consolas,monospace;
}

/* Layout ------------------------------------------------------------------- */
.stApp{background:var(--canvas);}
.block-container{padding-top:3.2rem;padding-bottom:3rem;max-width:1580px;}
/* Sidebar: the logo's navy, so the frame of every screen carries the team's
   colours. Text on it uses the frost tones, never the light-surface inks. */
[data-testid="stSidebar"]{background:var(--night);border-right:1px solid #1E2C45;}
[data-testid="stSidebar"] hr{border-top:1px solid rgba(201,214,229,.14);}
/* The collapse arrow is drawn in dark ink by default (an icon-font <span> on
   current Streamlit, an <svg> on older), which disappears on navy. */
[data-testid="stSidebar"] [data-testid="stSidebarCollapseButton"] *,
[data-testid="stSidebar"] [data-testid="stSidebarHeader"] button *,
[data-testid="stSidebar"] [data-testid="baseButton-headerNoPadding"] *{
  color:var(--frost) !important;fill:var(--frost);}
[data-testid="stSidebar"] [data-testid="stSidebarCollapseButton"] button:hover{
  background:rgba(201,214,229,.1) !important;}
.sb-h{font-size:1rem;font-weight:700;letter-spacing:-.014em;color:#fff;line-height:1.25;}
.sb-s{font-size:.75rem;color:var(--frost2);margin-top:.18rem;line-height:1.4;}
.sb-stat{font-size:.78rem;color:var(--frost2);line-height:1.8;}
.sb-stat b{color:#fff;font-weight:680;font-variant-numeric:tabular-nums;}
.sb-note{font-size:.72rem;color:var(--frost2);line-height:1.6;}
.sb-by{font-size:.73rem;color:var(--frost2);line-height:1.7;}
.sb-by span{color:var(--frost);font-weight:660;}
.sb-by a{color:#7FD3F5;text-decoration:none;border-bottom:1px solid rgba(127,211,245,.4);}
.sb-by a:hover{color:#fff;border-bottom-color:#fff;}
[data-testid="stSidebar"] .block-container{padding-top:1.2rem;}
[data-testid="stHeader"]{background:transparent;}
hr{margin:.9rem 0;border:none;border-top:1px solid var(--rule);}

/* Masthead ----------------------------------------------------------------- */
/* The one dark surface in the app. It carries the product name and the team,
   and nothing else on any screen is allowed to be this heavy -- which is what
   makes it read as the top of the page rather than as another panel. */
.mast{display:flex;justify-content:space-between;align-items:center;gap:18px;
      background:linear-gradient(115deg,var(--navy) 0%,#121D33 55%,#0C1424 100%);
      border-radius:9px;padding:.85rem 1.2rem;margin:0 0 1.2rem;
      box-shadow:inset 0 -2px 0 var(--ice);}
.mast-n{font-size:1.55rem;font-weight:740;letter-spacing:-.024em;line-height:1.1;color:#fff;}
.mast-s{font-size:.8rem;color:var(--frost);margin-top:.24rem;line-height:1.35;}
.mast-team{display:flex;align-items:center;gap:.65rem;flex:none;}
/* The mark keeps its own navy ground, so it sits on the band as a tile with a
   faint edge rather than being cut out of it. */
.mast-team img{height:48px;width:48px;border-radius:10px;display:block;flex:none;
               border:1px solid rgba(201,214,229,.22);}
.mast-tn{font-size:.98rem;font-weight:680;color:#fff;line-height:1.2;text-align:right;}
.mast-ts{font-size:.72rem;color:var(--frost);line-height:1.3;text-align:right;}

/* Typography --------------------------------------------------------------- */
html,body,[class*="css"]{
  -webkit-font-smoothing:antialiased;
  color:var(--ink);
  font-family:-apple-system,BlinkMacSystemFont,"Inter","Segoe UI",Roboto,sans-serif;
}
.num{font-family:var(--num);font-variant-numeric:tabular-nums;font-feature-settings:"tnum" 1;}

/* Streamlit styles <p> inside markdown with selectors more specific than a bare
   class, so the classes that sit on a <p> restate size and colour as
   !important. Without it every heading below renders at the body size. */
p.h-title{font-size:1.5rem !important;font-weight:700;letter-spacing:-.018em;margin:0;
          color:var(--ink) !important;line-height:1.2;}
p.h-sub{font-size:.86rem !important;color:var(--mut) !important;margin:.25rem 0 0;}
p.h-sub b{color:var(--ink);}
/* Section headings carry an accent bar so the eye can find where one block of a
   long screen ends and the next begins without reading the label. */
p.sec{font-size:.8rem !important;font-weight:720;letter-spacing:.085em;text-transform:uppercase;
      color:var(--ink) !important;margin:1.6rem 0 .6rem;padding-left:.55rem;line-height:1.25;
      border-left:3px solid var(--ac);}
p.sec:first-child{margin-top:0;}

/* KPI tiles ---------------------------------------------------------------- */
/* The top edge is the tile's state: accent for a plain measure, amber or red
   where the number is something to worry about. Same severity tones as the
   chips, so colour still means severity and nothing else. */
.kpis{display:grid;grid-template-columns:repeat(5,1fr);gap:10px;margin-bottom:.3rem;}
.kpi{background:var(--surf);border:1px solid var(--rule);border-top:3px solid var(--ac);
     border-radius:7px;box-shadow:var(--lift);
     padding:.72rem .85rem .78rem;min-height:108px;display:flex;flex-direction:column;}
.kpi.k-warn{border-top-color:#C98A00;}
.kpi.k-risk{border-top-color:var(--risk);}
.kpi.k-ok{border-top-color:var(--ok);}
.kpi-l{font-size:.68rem;font-weight:700;letter-spacing:.07em;text-transform:uppercase;
       color:var(--ink2);margin-bottom:.42rem;line-height:1.25;}
.kpi-v{font-size:1.62rem;font-weight:640;letter-spacing:-.024em;line-height:1.06;
       color:var(--ink);font-family:var(--num);font-variant-numeric:tabular-nums;}
.kpi-v.sm{font-size:1.36rem;}
.kpi-f{font-size:.735rem;color:var(--mut);margin-top:auto;padding-top:.4rem;line-height:1.35;}
.kpi-f b{color:var(--ink);font-weight:640;}

/* Chips -------------------------------------------------------------------- */
.chip{display:inline-block;padding:.12rem .46rem;border-radius:4px;font-size:.7rem;
      font-weight:660;line-height:1.5;white-space:nowrap;letter-spacing:.012em;
      border:1px solid transparent;}
.chip+.chip{margin-left:4px;}
.c-ok  {background:var(--ok-bg);  color:var(--ok);  border-color:#A6D1B9;}
.c-warn{background:var(--warn-bg);color:var(--warn);border-color:#E0BE73;}
.c-risk{background:var(--risk-bg);color:var(--risk);border-color:#E3A9A2;}
.c-neu {background:var(--neu-bg); color:var(--neu); border-color:#C5CBD4;}
.c-ac  {background:var(--ac-soft);color:var(--ac);  border-color:#9ACFE5;}
.chip-dim{opacity:.62;}

/* Worklist rows ------------------------------------------------------------ */
.wl-head,.wl-row{display:grid;
  grid-template-columns:34px minmax(150px,1.5fr) minmax(190px,2fr) 92px 104px 74px minmax(150px,1.25fr);
  gap:10px;align-items:center;}
.wl-head{font-size:.67rem;font-weight:720;letter-spacing:.08em;text-transform:uppercase;
         color:var(--ink2);background:var(--neu-bg);border:1px solid var(--rule);
         border-radius:6px;padding:.42rem .8rem;margin-bottom:.4rem;}
.wl-row{background:var(--surf);border:1px solid var(--rule);border-radius:6px;
        box-shadow:var(--lift);padding:.52rem .8rem;margin-bottom:-2px;}
.wl-rk{font-family:var(--num);font-size:.78rem;color:var(--mut);text-align:right;}
.wl-nm{font-size:.865rem;font-weight:640;letter-spacing:-.006em;color:var(--ink);
       overflow:hidden;text-overflow:ellipsis;white-space:nowrap;}
.wl-nm span{display:block;font-size:.715rem;font-weight:400;color:var(--mut);}
.wl-ac{font-size:.81rem;color:var(--ink);
       overflow:hidden;text-overflow:ellipsis;white-space:nowrap;}
.wl-ac span{display:block;font-size:.695rem;color:var(--mut);letter-spacing:.02em;}
.wl-ev{font-family:var(--num);font-variant-numeric:tabular-nums;font-size:.9rem;
       font-weight:680;text-align:right;color:var(--ink);}
.wl-pr{font-family:var(--num);font-size:.8rem;color:var(--ink2);text-align:right;}
.r{text-align:right;}

/* Cards -------------------------------------------------------------------- */
.card{background:var(--surf);border:1px solid var(--rule);border-radius:7px;
      box-shadow:var(--lift);padding:.8rem .9rem;margin-bottom:.6rem;}
.card-top{border-top:4px solid var(--ac);}
.card-care{border-top:4px solid #C98A00;}
.card-h{display:flex;justify-content:space-between;align-items:flex-start;gap:8px;}
.card-t{font-size:.95rem;font-weight:680;letter-spacing:-.008em;line-height:1.3;color:var(--ink);}
.card-r{font-family:var(--num);font-size:.68rem;font-weight:600;color:var(--ink2);
        border:1px solid var(--edge);border-radius:3px;padding:.05rem .32rem;flex:none;}
.card-ev{font-family:var(--num);font-variant-numeric:tabular-nums;
         font-size:1.32rem;font-weight:680;letter-spacing:-.02em;margin:.45rem 0 .05rem;}
.card-evl{font-size:.675rem;font-weight:600;color:var(--mut);text-transform:uppercase;
          letter-spacing:.07em;}
.card-x{font-size:.83rem;line-height:1.52;color:var(--ink2);margin:.55rem 0 0;}
.disc{background:var(--warn-bg);border:1px solid #E0BE73;border-radius:5px;
      padding:.45rem .6rem;font-size:.75rem;color:#5C3D00;line-height:1.45;margin-top:.55rem;}
.disc b{display:block;font-size:.645rem;text-transform:uppercase;letter-spacing:.075em;
        margin-bottom:.15rem;color:var(--warn);}

/* Left rail panel ---------------------------------------------------------- */
.pan{background:var(--surf);border:1px solid var(--rule);border-radius:7px;
     box-shadow:var(--lift);padding:.8rem .9rem;margin-bottom:.6rem;}
p.pan-h{font-size:.74rem !important;font-weight:720;letter-spacing:.08em;text-transform:uppercase;
        color:var(--ink2) !important;margin:0 0 .55rem;}
.kv{display:flex;justify-content:space-between;gap:10px;padding:.24rem 0;font-size:.81rem;
    border-bottom:1px solid var(--rule2);}
.kv:last-child{border-bottom:none;}
.kv-k{color:var(--mut);flex:none;}
.kv-v{text-align:right;font-weight:620;color:var(--ink);}
.kv-v.n{font-family:var(--num);font-variant-numeric:tabular-nums;}
.nm-big{font-size:1.16rem;font-weight:700;letter-spacing:-.016em;line-height:1.2;}
.nm-sub{font-size:.77rem;color:var(--mut);margin-top:.12rem;}

/* Timeline ----------------------------------------------------------------- */
.tl{display:grid;grid-template-columns:92px 128px 1fr;gap:10px;align-items:baseline;
    padding:.42rem .7rem;border-bottom:1px solid var(--rule2);background:var(--surf);
    border-left:1px solid var(--rule);border-right:1px solid var(--rule);}
.tl:first-of-type{border-radius:6px 6px 0 0;border-top:1px solid var(--rule);}
.tl-d{font-family:var(--num);font-size:.75rem;color:var(--ink2);}
.tl-t{font-size:.665rem;font-weight:660;letter-spacing:.045em;color:var(--ink2);
      overflow:hidden;text-overflow:ellipsis;white-space:nowrap;}
.tl-x{font-size:.805rem;color:var(--ink2);line-height:1.45;}
.tl-x b{font-weight:600;color:var(--ink);}

/* Transcript --------------------------------------------------------------- */
.tr{background:#F6F8FA;border:1px solid var(--rule);border-left:4px solid var(--ac);
    border-radius:5px;padding:.62rem .75rem;font-size:.815rem;line-height:1.62;
    color:var(--ink2);white-space:pre-wrap;}

/* Suppression -------------------------------------------------------------- */
.sup{background:var(--surf);border:1px solid var(--rule);border-left:4px solid var(--risk);
     border-radius:5px;padding:.55rem .7rem;margin-bottom:.42rem;}
.sup-h{display:flex;justify-content:space-between;gap:8px;align-items:baseline;}
.sup-t{font-size:.85rem;font-weight:660;color:var(--ink);}
.sup-x{font-size:.76rem;color:var(--mut);margin-top:.28rem;line-height:1.45;}
.sup-x code{background:var(--neu-bg);border-radius:3px;padding:.04rem .26rem;
            font-family:var(--num);font-size:.71rem;color:var(--ink2);}

/* Tables ------------------------------------------------------------------- */
table.t{width:100%;border-collapse:collapse;background:var(--surf);
        border:1px solid var(--rule);border-radius:6px;overflow:hidden;box-shadow:var(--lift);}
table.t th{font-size:.67rem;font-weight:720;letter-spacing:.075em;text-transform:uppercase;
           color:var(--ink2);text-align:left;padding:.5rem .7rem;
           border-bottom:1px solid var(--rule);background:var(--neu-bg);}
table.t td{padding:.44rem .7rem;font-size:.81rem;border-bottom:1px solid var(--rule2);
           color:var(--ink2);}
table.t tr:last-child td{border-bottom:none;}
table.t td.n{font-family:var(--num);font-variant-numeric:tabular-nums;text-align:right;
             color:var(--ink);font-weight:600;}
table.t td.tot{font-weight:720;color:var(--ink);border-top:2px solid var(--edge);
               background:#F6F8FA;}

/* Streamlit overrides ------------------------------------------------------ */
[data-testid="stExpander"]{border:none !important;background:transparent !important;}
[data-testid="stExpander"] details{border:1px solid var(--rule) !important;
  border-radius:6px !important;background:var(--surf) !important;margin-bottom:.3rem;}
[data-testid="stExpander"] summary{font-size:.78rem !important;color:var(--ac) !important;
  font-weight:640 !important;padding:.42rem .7rem !important;}
[data-testid="stExpander"] summary:hover{color:var(--ink) !important;}

div.stButton>button{border-radius:5px;font-size:.8rem;font-weight:640;
  border:1px solid var(--edge);background:var(--surf);color:var(--ink);
  padding:.3rem .7rem;transition:none;}
div.stButton>button:hover{border-color:var(--ac);color:var(--ac);background:var(--ac-soft);}
div.stButton>button[kind="primary"]{background:var(--ac);border-color:var(--ac);color:#fff;}
div.stButton>button[kind="primary"]:hover{background:var(--ac-dk);border-color:var(--ac-dk);color:#fff;}
/* A disabled Accept is a recorded decision, not a broken control: keep it
   legible as a button that has been used. */
div.stButton>button:disabled{background:var(--neu-bg);border-color:var(--rule);
  color:var(--mut2);opacity:1;}

/* Sidebar nav buttons read as a nav list, not as four calls to action. The
   active item glows the way the snowflake in the mark does: an ice bar and an
   ice-tinted fill, so "where am I" is answerable from across a room. */
[data-testid="stSidebar"] div.stButton>button{
  justify-content:flex-start;text-align:left;border:none;background:transparent;
  font-size:.88rem;font-weight:600;color:var(--frost);padding:.42rem .7rem;}
[data-testid="stSidebar"] div.stButton>button>div{width:100%;justify-content:flex-start;}
[data-testid="stSidebar"] div.stButton>button p{text-align:left;width:100%;}
[data-testid="stSidebar"] div.stButton>button:hover{
  background:rgba(201,214,229,.08);color:#fff;}
[data-testid="stSidebar"] div.stButton>button[kind="primary"]{
  background:rgba(40,182,232,.16);color:#fff;font-weight:700;
  box-shadow:inset 3px 0 0 var(--ice);}
[data-testid="stSidebar"] div.stButton>button[kind="primary"]:hover{
  background:rgba(40,182,232,.22);color:#fff;}
[data-testid="stSidebar"] div.stButton>button:focus-visible{
  outline:2px solid var(--ice);outline-offset:1px;}

/* The widget accent comes from primaryColor in app/.streamlit/config.toml, not
   from here -- the slider's filled track is an inline linear-gradient whose stops
   move as it is dragged, so a stylesheet can only replace the gradient wholesale
   and lose the fill position. What remains below is sizing and field edges. */
[data-baseweb="tag"]{font-size:.71rem !important;font-weight:600 !important;}
/* The chat bar's dock is white by default; match it to the page behind it. */
[data-testid="stBottom"],[data-testid="stBottom"]>div,
[data-testid="stBottomBlockContainer"]{background:var(--canvas) !important;}

[data-testid="stMetricValue"]{font-family:var(--num);font-variant-numeric:tabular-nums;}
/* Fields are white with a visible edge: on the grey canvas a field filled with
   the theme's pale secondary colour is hard to tell from the page behind it. */
div[data-baseweb="select"]>div{border-radius:5px;font-size:.84rem;
  background-color:var(--surf) !important;border:1px solid var(--edge) !important;}
div[data-baseweb="select"]>div>div{background-color:transparent !important;}
div[data-baseweb="input"],div[data-baseweb="textarea"]{
  background:var(--surf) !important;border:1px solid var(--edge) !important;border-radius:5px;}
div[data-baseweb="base-input"],div[data-baseweb="input"] input,
div[data-baseweb="textarea"] textarea{background:var(--surf) !important;}
.stSlider label,.stMultiSelect label,.stSelectbox label,.stNumberInput label,
.stRadio label,.stTextArea label{font-size:.72rem !important;font-weight:680 !important;
  letter-spacing:.05em;text-transform:uppercase;color:var(--ink2) !important;}
[data-testid="stCaptionContainer"],[data-testid="stCaptionContainer"] p{
  font-size:.775rem !important;color:var(--mut) !important;opacity:1 !important;}
/* Charts sit on a white surface with the same edge as every other panel. No
   padding: Vega sizes the canvas to the container, so padding here would push
   the right-hand end of the chart outside its own border. */
[data-testid="stVegaLiteChart"],[data-testid="stArrowVegaLiteChart"]{
  background:var(--surf);border:1px solid var(--rule);border-radius:7px;
  box-shadow:var(--lift);overflow:hidden;}
/* Ask: a chat, styled the way people expect a chat to look ------------------- */
/* Everything here hangs off Streamlit's chat test ids, which only exist on the
   Ask screen. Selectors cover the chat-input layout of Streamlit 1.4x/1.50 (the
   versions Snowflake's warehouse runtime serves) and 1.6x. User and copilot
   bubbles are told apart with :has() on the avatar; a browser without :has()
   still gets readable left-aligned bubbles. */

/* Copilot identity bar */
.cop{display:flex;align-items:center;gap:.85rem;background:var(--surf);
     border:1px solid var(--rule);border-radius:10px;padding:.7rem .95rem;
     box-shadow:var(--lift);margin:0 0 1.1rem;}
.cop img{width:46px;height:46px;border-radius:50%;flex:none;display:block;
         box-shadow:0 0 0 2px var(--surf),0 0 0 4px var(--ice);}
.cop-n{font-size:1.02rem;font-weight:720;color:var(--ink);line-height:1.2;}
.cop-s{font-size:.8rem;color:var(--mut);margin-top:.15rem;line-height:1.4;}
.cop-s code{font-family:var(--num);font-size:.74rem;color:var(--ink2);
            background:var(--neu-bg);border-radius:3px;padding:.02rem .28rem;}
.cop-tools{margin-left:auto;display:flex;flex-wrap:wrap;gap:5px;justify-content:flex-end;
           max-width:48%;}
.cop-tools .chip+.chip{margin-left:0;}

/* Welcome bubble in the empty state -- drawn, not a chat message, so it is not
   part of the conversation sent to the agent. */
.wel{display:flex;gap:.65rem;align-items:flex-start;margin:.1rem 0 1.1rem;}
.wel img{width:34px;height:34px;border-radius:50%;flex:none;display:block;}
.wel-b{background:var(--surf);border:1px solid var(--rule);border-radius:4px 16px 16px 16px;
       padding:.7rem 1rem;font-size:.92rem;color:var(--ink2);line-height:1.55;
       max-width:760px;box-shadow:var(--lift);}
.wel-b b{color:var(--ink);}

/* Suggestion chips */
/* Every chip the same shape: two lines tall whether its question wraps or not,
   text left-aligned and vertically centred. Streamlit centres button labels
   through an inner flex box, so that box is overridden too. */
[class*="st-key-sug_"] button{border-radius:14px !important;background:var(--surf) !important;
  border:1px solid #9ACFE5 !important;color:var(--ac) !important;font-weight:600 !important;
  font-size:.86rem !important;padding:.5rem 1rem !important;
  min-height:3.6rem !important;height:3.6rem;line-height:1.35 !important;
  display:flex !important;align-items:center !important;
  justify-content:flex-start !important;text-align:left !important;}
[class*="st-key-sug_"] button > div{justify-content:flex-start !important;width:100%;
  text-align:left !important;}
[class*="st-key-sug_"] button p{text-align:left !important;width:100%;margin:0 !important;
  overflow:hidden;display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;}
[class*="st-key-sug_"] button:hover{background:var(--ac-soft) !important;border-color:var(--ac) !important;}

/* The three tool cards: one grid row, equal height and width */
.tools3{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:.75rem;
        align-items:stretch;}
.tools3 .pan{margin:0;height:100%;box-sizing:border-box;}
@media (max-width:900px){.tools3{grid-template-columns:1fr;}}

/* Between the pinned suggestions and the conversation */
.convo-rule{border-top:1px solid var(--rule);margin:.4rem 0 .9rem;}

/* Messages */
[data-testid="stChatMessage"]{background:transparent !important;border:none !important;
  padding:.2rem 0 !important;gap:.6rem;align-items:flex-start;}
[data-testid="stChatMessageContent"]{background:var(--surf);border:1px solid var(--rule);
  border-radius:4px 16px 16px 16px;padding:.65rem .95rem .95rem;box-shadow:var(--lift);
  flex:0 1 auto !important;width:auto !important;max-width:min(880px,88%);min-width:0;
  margin:0 !important;overflow:visible !important;}
[data-testid="stChatMessageContent"] p{font-size:.92rem;line-height:1.58;}
[data-testid="stChatMessageContent"] [data-testid="stExpander"] details{
  background:#F4F7FA !important;margin-top:.35rem;}
/* Your messages: right-hand side, in the accent, the way every messenger does it */
[data-testid="stChatMessage"]:has(.msg-you){
  flex-direction:row-reverse;}
[data-testid="stChatMessage"]:has(.msg-you) [data-testid="stChatMessageContent"]{
  background:var(--ac);border-color:var(--ac);border-radius:16px 4px 16px 16px;
  max-width:min(640px,72%);}
[data-testid="stChatMessage"]:has(.msg-you) [data-testid="stChatMessageContent"] *{
  color:#fff !important;}
[data-testid="stChatMessage"]:has(.msg-you) [data-testid="stChatMessageContent"] .msg-meta{
  color:rgba(255,255,255,.78) !important;text-align:right;}
/* Avatars: yours a person on a glacier disc, the copilot's the Coskilled
   snowflake -- both inlined images, drawn round. */
[data-testid="stChatMessage"] > img,
[data-testid="stChatMessage"] [data-testid="stChatMessageAvatarImage"],
[data-testid="stChatMessage"] [data-testid="stChatMessageAvatarImage"] img{
  border-radius:50% !important;width:34px !important;height:34px !important;}
.msg-meta{font-size:.72rem;color:var(--mut2);margin-top:.35rem;letter-spacing:.01em;
           line-height:1.3;}

/* Composer: one rounded field with a round send button. Streamlit draws the
   field as nested boxes; the inner ones are flattened so only the outer edge
   shows -- the general field rule above would otherwise draw a second,
   offset box inside it on Streamlit 1.4x/1.50. */
[data-testid="stChatInput"]{background:var(--surf) !important;border:1px solid var(--edge) !important;
  border-radius:24px !important;box-shadow:0 3px 14px rgba(16,24,40,.09) !important;
  padding:.25rem .5rem .25rem .95rem !important;overflow:hidden;}
[data-testid="stChatInput"]:focus-within{border-color:var(--ac) !important;
  box-shadow:0 0 0 3px rgba(10,106,148,.16),0 3px 14px rgba(16,24,40,.09) !important;}
[data-testid="stChatInput"] div,
[data-testid="stChatInput"] div[data-baseweb="textarea"],
[data-testid="stChatInput"] div[data-baseweb="base-input"]{
  background:transparent !important;border:none !important;box-shadow:none !important;
  border-radius:0 !important;}
[data-testid="stChatInputTextArea"],[data-testid="stChatInput"] textarea{
  background:transparent !important;font-size:.95rem !important;color:var(--ink) !important;
  padding-left:0 !important;}
[data-testid="stChatInputTextArea"]::placeholder{color:var(--mut2) !important;}
[data-testid="stChatInputSubmitButton"]{background:var(--ac) !important;border-radius:50% !important;
  width:34px !important;height:34px !important;min-width:34px;display:flex;
  align-items:center;justify-content:center;border:none !important;}
/* Colour the icon through currentColor only. Its svg carries a transparent
   background shape (a rect on 1.50, a path with fill="none" on 1.6x); forcing
   fill on every child paints that shape and turns the arrow into a square. */
[data-testid="stChatInputSubmitButton"]{color:#fff !important;}
[data-testid="stChatInputSubmitButton"] svg{color:#fff !important;}
[data-testid="stChatInputSubmitButton"]:disabled{background:var(--neu-bg) !important;
  color:var(--mut2) !important;}
[data-testid="stChatInputSubmitButton"]:disabled svg{color:var(--mut2) !important;}
[data-testid="stChatInputSubmitButton"]:hover:not(:disabled){background:var(--ac-dk) !important;}

/* "Clear conversation": a quiet text action, not a second primary button */
.st-key-chat_clear button{border:none !important;background:transparent !important;
  color:var(--ac) !important;font-size:.8rem !important;padding:.2rem .3rem !important;}
.st-key-chat_clear button:hover{text-decoration:underline;background:transparent !important;}

#MainMenu,footer,[data-testid="stToolbar"]{visibility:hidden;}
/* ...except the button that brings a collapsed sidebar back. In current
   Streamlit it lives INSIDE stToolbar, so hiding the toolbar hid it too and a
   collapsed sidebar could not be reopened. visibility is inherited and a child
   may override it, so it is shown again here, as a navy tab in the sidebar's
   colours so it is easy to find on the grey page. The older test ids cover
   Streamlit versions where the control sat outside the toolbar. */
[data-testid="stExpandSidebarButton"],
[data-testid="stSidebarCollapsedControl"] button,
[data-testid="collapsedControl"] button{
  visibility:visible !important;background:var(--night) !important;
  border:1px solid #1E2C45 !important;border-radius:6px !important;
  box-shadow:inset 0 -2px 0 var(--ice);}
/* The arrow is an icon-font glyph in a <span> on current Streamlit and an
   <svg> on older ones; both default to dark ink, invisible on navy. */
[data-testid="stExpandSidebarButton"],[data-testid="stExpandSidebarButton"] *,
[data-testid="stSidebarCollapsedControl"] button *,
[data-testid="collapsedControl"] button *{color:#fff !important;fill:#fff;}
[data-testid="stExpandSidebarButton"]:hover,
[data-testid="stSidebarCollapsedControl"] button:hover,
[data-testid="collapsedControl"] button:hover{background:var(--navy) !important;}
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
    """Run a read and return it the way Snowpark's to_pandas() did, so the rest
    of the file is unchanged: upper-case column names (Postgres folds unquoted
    names to lower case) and floats rather than Decimal for NUMERIC columns.
    jsonb columns arrive as Python lists and dicts, which jarr() accepts."""
    with engine.connect() as c:
        res = c.exec_driver_sql(sql)
        df = pd.DataFrame(res.fetchall(), columns=[k.upper() for k in res.keys()])
    for col in df.columns:
        vals = df[col].dropna()
        if len(vals) and isinstance(vals.iloc[0], Decimal):
            df[col] = df[col].astype(float)
    return df


def lit(v) -> str:
    """SQL literal. Doubles quotes. Postgres has standard_conforming_strings
    on, so a backslash is an ordinary character and is not escaped."""
    if v is None or (isinstance(v, float) and pd.isna(v)):
        return "NULL"
    if isinstance(v, bool):
        return "TRUE" if v else "FALSE"
    if isinstance(v, (int, float)):
        return repr(v)
    return "'" + str(v).replace("'", "''") + "'"


def jarr(v):
    """jsonb columns arrive as lists / dicts; JSON text is still accepted."""
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


def kpi(label, value, foot="", small=False, tone=""):
    """One KPI tile. `tone` (warn / risk / ok) colours the tile's top edge with
    the same severity tones the chips use; leave it empty for a plain measure."""
    cls = f"kpi k-{tone}" if tone else "kpi"
    return (f'<div class="{cls}"><div class="kpi-l">{esc(label)}</div>'
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
            .mark_rule(color="#B8C0CB", strokeDash=[2, 2], size=1)
            .encode(y=alt.Y("y:Q", scale=alt.Scale(domain=[-1.05, 1.05]), axis=None)))
    line = base.mark_line(color="#7C8794", size=1.2, opacity=.75)
    pts = base.mark_point(size=52, filled=True, opacity=1).encode(
        color=alt.Color("SENTIMENT_SCORE:Q",
                        scale=alt.Scale(domain=[-1, 0, 1],
                                        range=["#A32219", "#66707C", "#1B6E45"]),
                        legend=None),
        tooltip=[alt.Tooltip("OCCURRED_AT:T", title="When", format="%d %b %Y"),
                 alt.Tooltip("SENTIMENT_SCORE:Q", title="Sentiment", format=".2f"),
                 alt.Tooltip("INTENT:N", title="Intent")],
    )
    return (zero + line + pts).properties(height=52).configure_view(strokeWidth=0)


def bar_chart(df, xcol, ycol, xtitle, height=None):
    c = (
        alt.Chart(df)
        .mark_bar(color="#0A6A94", height=13, cornerRadiusEnd=2)
        .encode(
            x=alt.X(f"{xcol}:Q", title=xtitle,
                    axis=alt.Axis(grid=True, gridColor="#DDE2E8", tickCount=5,
                                  labelColor="#66707C", titleColor="#4F5965",
                                  labelFontSize=11, titleFontSize=11, domain=False)),
            y=alt.Y(f"{ycol}:N", sort="-x", title=None,
                    axis=alt.Axis(labelColor="#3D454F", labelFontSize=11,
                                  labelLimit=200, domain=False, ticks=False)),
            tooltip=[alt.Tooltip(f"{ycol}:N", title="Rule"),
                     alt.Tooltip(f"{xcol}:Q", title=xtitle, format=",")],
        )
    )
    if height:
        c = c.properties(height=height)
    # Right padding so the last tick label is not clipped by the panel edge.
    return c.properties(padding={"left": 4, "right": 16, "top": 6, "bottom": 4}) \
            .configure_view(strokeWidth=0)


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
              f"<b>{words(k.TOP_SUPPRESSION_REASON)}</b> ({num(k.TOP_SUPPRESSION_COUNT)})",
              tone="risk")
        + kpi("Renewals at risk, 30 days", num(k.RENEWALS_AT_RISK_30D),
              f"<b>{inr(k.PREMIUM_AT_RISK_INR, True)}</b> premium on "
              f"{num(k.POLICIES_AT_RISK_30D)} policies", tone="warn")
        + kpi("Arrears exposure", inr(k.ARREARS_EXPOSURE_INR, True),
              f"<b>{num(k.CUSTOMERS_IN_ARREARS)}</b> customers past due on a loan",
              small=True, tone="risk")
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

    # Diversity strip -- the worklist below sorts care actions ahead of every
    # sales action regardless of value (see the comment at the sort call), so
    # an unfiltered top-N skews toward whichever category carries the most
    # care-tier volume. This shows the book's real category mix before that
    # sort narrows what's visible, so the catalog's breadth isn't only
    # discoverable by touching the Category filter.
    dist = wl.CATEGORY.value_counts()
    dist_chips = "".join(
        chip(f"{words(cat)} {n:,} ({n / len(wl):.0%})", "neu")
        for cat, n in dist.items()
    )
    st.markdown(
        f'<div style="margin:.1rem 0 .7rem;line-height:2.2;">{dist_chips}</div>',
        unsafe_allow_html=True,
    )

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
        fb = q(f"""SELECT DISTINCT ON (ACTION_CODE)
                          ACTION_CODE, DECISION, REJECT_REASON, DECIDED_BY, DECIDED_AT
                   FROM APP.ACTION_FEEDBACK WHERE CUSTOMER_ID = {int(cid)}
                   ORDER BY ACTION_CODE, DECIDED_AT DESC""")
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
            f'<span style="font-size:.7rem;color:#4F5965;margin-left:6px">'
            f"by {esc(prior.DECIDED_BY)} on {dstr(prior.DECIDED_AT)}</span></div>",
            unsafe_allow_html=True,
        )

    # An accepted card cannot be accepted again. The log is append-only so that a
    # change of mind is two rows, but the same decision twice is not a second
    # decision -- it only inflates "RM decisions recorded" and the accepted
    # expected value on the Impact screen. Reject stays live: that is how a
    # change of mind is recorded, and a second rejection can carry a new reason.
    # The button is disabled AND the write is guarded, so a click that was
    # already in flight when the card re-rendered cannot slip through.
    accepted = prior is not None and prior.DECISION == "ACCEPTED"

    key = f"{cid}_{r.ACTION_CODE}"
    b1, b2 = st.columns(2, gap="small")
    if b1.button("Accept", key=f"acc_{key}", type="primary", use_container_width=True,
                 disabled=accepted) and not accepted:
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


MAX_DEMO_WRITES = 30


def write_feedback(cid, r, decision, reason, note):
    """Append to APP.ACTION_FEEDBACK.

    In Snowflake, DECIDED_BY was CURRENT_USER() resolved server-side. This is a
    public demo with no sign-in, so every decision is attributed to DEMO_VISITOR
    -- a fixed label rather than anything a visitor can type. Values are bound
    parameters, never formatted into the SQL. A browser session can record at
    most MAX_DEMO_WRITES decisions, which keeps an open write path on a public
    page from being used to fill the table."""
    n = st.session_state.get("demo_writes", 0)
    if n >= MAX_DEMO_WRITES:
        st.warning(f"This demo session has recorded {MAX_DEMO_WRITES} decisions, "
                   "the most one visit can. Reload the page to start a new session.")
        return
    try:
        with engine.begin() as c:
            c.execute(sa.text("""
                INSERT INTO app.action_feedback
                  (customer_id, action_code, action_rank, decision, reject_reason,
                   note, expected_value_inr, decided_by, decided_at)
                VALUES (:cid, :code, :rank, :decision, :reason, :note, :ev,
                        'DEMO_VISITOR', now())"""),
                {"cid": int(cid), "code": str(r.ACTION_CODE), "rank": int(r.ACTION_RANK),
                 "decision": decision, "reason": reason,
                 "note": (note or None) and str(note)[:500],
                 "ev": float(r.EXPECTED_VALUE_INR)})
    except Exception as e:  # noqa: BLE001 - shown to the operator, not raised
        # A failed write must not look like a recorded one, and must not replace
        # the customer record with a stack trace in the middle of a call. Nothing
        # is cleared and nothing reruns, so an open reject form keeps the reason
        # and the note that were typed and the RM can simply try again.
        st.error("Decision not recorded. Nothing was written, so you can try again.")
        st.caption(f"{type(e).__name__}: {str(e)[:300]}")
        return
    st.session_state["demo_writes"] = n + 1
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
                f'<span style="font-size:.735rem;color:#4F5965;margin-left:6px">'
                f'{esc(b.get("observed"))}</span></div>'
                for b in blocking
            )
            exempt = [e for e in jarr(s.EXEMPT_RULES) if isinstance(e, dict)]
            exempt_html = "".join(
                f'<div style="margin-top:.3rem">'
                f'{chip(words(e.get("rule")) + " — waived", "warn")}'
                f'<span style="font-size:.735rem;color:#4F5965;margin-left:6px">'
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

# The public build cannot call the Cortex Agent (it lives in Snowflake), so the
# Ask screen replays thirteen runs recorded against the live agent during the
# build: eight questions an RM or portfolio manager would ask, and five
# guardrail tests that try to talk it into an unsafe answer. Answers and traces
# are unedited; data/agent_runs.json is built from evals/agent_runs/ by
# db/build_agent_runs.py.
AGENT_RUNS = json.loads(
    (Path(__file__).parent / "data" / "agent_runs.json").read_text(encoding="utf-8"))
RUN_GROUPS = ["Relationship manager", "Portfolio manager", "Guardrail tests"]
RUN_GROUP_NOTE = {
    "Relationship manager": "One named customer: what to do, why, and what was blocked.",
    "Portfolio manager": "The whole book: counts and rupees, via Cortex Analyst over the semantic view.",
    "Guardrail tests": "Attempts to get an unsafe or invented answer -- each one is refused or redirected.",
}


COPILOT_NAME = "RM Copilot"
# Message stamps are Indian time, written as a fixed offset rather than a named
# zone so they need no tz database on the warehouse runtime.
IST = timezone(timedelta(hours=5, minutes=30))


def _copilot_avatar():
    """The Coskilled mark as raw bytes, for st.chat_message(avatar=...). Bytes
    work on every Streamlit version Snowflake serves; a data-URI string does
    not. Falls back to Streamlit's own assistant avatar."""
    try:
        return base64.b64decode(TEAM_LOGO.split(",", 1)[1]) if TEAM_LOGO else "assistant"
    except (ValueError, IndexError):
        return "assistant"


COPILOT_AVATAR = _copilot_avatar()

# Your avatar: a person mark on a glacier disc, 96px WebP, inlined for the same
# reason as TEAM_LOGO. Streamlit's default user avatar changes look between
# versions, and on 1.4x/1.50 it is an icon that cannot be recoloured cleanly.
USER_MARK = "data:image/webp;base64,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"
try:
    USER_AVATAR = base64.b64decode(USER_MARK.split(",", 1)[1])
except (ValueError, IndexError):
    USER_AVATAR = "user"


def _stamp() -> str:
    return datetime.now(IST).strftime("%H:%M")


def _meta(m) -> str:
    """The name-and-time line at the foot of a bubble. Its class also tells the
    stylesheet whose bubble it is (msg-you / msg-bot): both avatars are images,
    so the avatar can no longer say."""
    mine = m["role"] == "user"
    who = "You" if mine else COPILOT_NAME
    if not mine and m.get("via"):
        who += f" · {esc(m['via'])}"
    at = m.get("at")
    cls = "msg-meta msg-you" if mine else "msg-meta msg-bot"
    return f'<div class="{cls}">{who}{" · " + esc(at) if at else ""}</div>'


def _bubble(m):
    """One message. The text is always the first element in the bubble -- the
    answer is what matters, and the tests read it from that position."""
    avatar = COPILOT_AVATAR if m["role"] == "assistant" else USER_AVATAR
    with st.chat_message(m["role"], avatar=avatar):
        st.markdown(m["text"])
        if m.get("trace"):
            render_trace(m["trace"])
        st.markdown(_meta(m), unsafe_allow_html=True)


# -- live mode ------------------------------------------------------------------
# Gemini (free tier) driving the same four tools and the same instructions as the
# Cortex Agent -- see live_agent.py. Two caps keep a public page from spending the
# whole free quota: questions per browser session, and questions per day across
# everyone, counted in app.llm_usage (which stores a number per day and never the
# question).
LIVE_PER_SESSION = 6


def _gemini_cfg():
    try:
        g = st.secrets["gemini"]
        return {"api_key": g["api_key"], "model": g.get("model"),
                "daily_limit": int(g.get("daily_limit", 150))}
    except (KeyError, FileNotFoundError, AttributeError):
        return None


@st.cache_resource(show_spinner=False)
def _gemini_model(api_key, preferred):
    return live_agent.pick_model(api_key, preferred)


def _count_today(limit):
    """Reserve one question in today's quota. Returns True if it fits."""
    with engine.begin() as c:
        n = c.execute(sa.text("""
            insert into app.llm_usage (day, questions) values (current_date, 1)
            on conflict (day) do update set questions = app.llm_usage.questions + 1
            returning questions""")).scalar()
    return n <= limit


def _ask_live(cfg, prompt):
    asked = st.session_state.get("live_asked", 0)
    if asked >= LIVE_PER_SESSION:
        return (f"This demo allows {LIVE_PER_SESSION} live questions per visit, to keep the free "
                "quota available for other visitors. Reload the page to start a new visit, or "
                "switch to **Recorded** to read the Cortex Agent's own answers."), None, None
    try:
        if not _count_today(cfg["daily_limit"]):
            return ("Today's live questions are used up -- the demo runs on a free quota. Switch to "
                    "**Recorded** to read the Cortex Agent's own answers, or come back tomorrow."), None, None
    except Exception as e:  # noqa: BLE001
        return f"Could not check today's quota: {type(e).__name__}.", None, None
    st.session_state.live_asked = asked + 1
    try:
        model = _gemini_model(cfg["api_key"], cfg["model"])
        history = [(m["role"], m["text"]) for m in st.session_state.chat_live[:-1]]
        text, trace = live_agent.run_agent(engine, cfg["api_key"], model, prompt, history)
        return text, trace, model
    except live_agent.GeminiError as e:
        if e.status == 429:
            return ("Gemini's free-tier rate limit was reached. Wait a minute and ask again, or "
                    "switch to **Recorded**."), None, None
        return f"The Gemini call failed ({e.status}): {e}", None, None
    except Exception as e:  # noqa: BLE001 - surfaced, not raised
        return f"The live answer failed: {type(e).__name__}: {str(e)[:300]}", None, None


def _capabilities():
    capabilities = [
        ("Portfolio questions", "Cortex Analyst",
         "How many, how much, which cohort, what trend -- routed to "
         "GOLD.SV_CUSTOMER_360 through SEMANTIC_VIEW(), never around it."),
        ("What a customer said", "Cortex Search · interactions",
         "Finds the actual call, email or chat -- filterable by customer, "
         "channel, intent and sentiment, not a summary written after the fact."),
        ("Is this allowed", "Cortex Search · product terms",
         "Retrieves the exact eligibility clause, cited as "
         "PRODUCT_CODE#CLAUSE_ID, that permits or blocks an action."),
    ]
    st.markdown(
        '<p class="sec">What each tool answers</p><div class="tools3">'
        + "".join(
            f'<div class="pan"><p class="pan-h">{title}</p>'
            f'<p class="card-t" style="margin:0 0 .3rem;">{sub}</p>'
            f'<p class="card-x" style="margin:0;">{body}</p></div>'
            for title, sub, body in capabilities)
        + "</div>",
        unsafe_allow_html=True,
    )


def screen_ask():
    header(
        "Ask",
        "Questions in plain English about one customer or the whole book. "
        "Every answer shows the tools and data behind it.",
    )
    cfg = _gemini_cfg()
    modes = (["Live · Gemini", "Recorded · Cortex Agent"] if cfg
             else ["Recorded · Cortex Agent"])
    if "ask_mode" not in st.session_state or st.session_state.ask_mode not in modes:
        st.session_state.ask_mode = modes[0]
    for k in ("chat", "chat_live"):
        st.session_state.setdefault(k, [])

    tools = "".join(chip(t, "ac") for t in (
        "Portfolio analytics", "Search · interactions", "Search · product terms",
        "Next-best-action tool"))
    avatar_img = (f'<img src="{TEAM_LOGO}" alt="{esc(COPILOT_NAME)}"/>'
                  if TEAM_LOGO else "")
    st.markdown(
        f'<div class="cop">{avatar_img}<div>'
        f'<div class="cop-n">{esc(COPILOT_NAME)}</div>'
        '<div class="cop-s">The <code>APP.RM_COPILOT</code> instructions and tools · '
        'live on Gemini, or replayed from the Snowflake Cortex Agent</div></div>'
        f'<div class="cop-tools">{tools}</div></div>',
        unsafe_allow_html=True,
    )

    mode = st.radio("Mode", modes, key="ask_mode", horizontal=True,
                    label_visibility="collapsed")
    live = mode.startswith("Live")

    if live:
        st.markdown(
            '<div class="wel"><div class="wel-b">'
            "<b>Live.</b> A Gemini model (Google's free tier) answers with the Cortex "
            "Agent's own instructions and the same four tools, rebuilt on Postgres. "
            "Recommendations still come only from the <b>next-best-action tool</b>, so "
            "the model can explain an action but cannot invent one. Ask your own "
            "question or pick one below. Open <b>Reasoning</b> under an answer to see "
            "the tool calls and the data they returned."
            f"<br/><br/>Up to {LIVE_PER_SESSION} questions per visit. Questions are sent "
            "to Google, which may use free-tier prompts to improve its products -- all "
            "data here is synthetic, so don't type anything personal.</div></div>",
            unsafe_allow_html=True,
        )
        st.markdown('<p class="sec">Try one of these</p>', unsafe_allow_html=True)
        ideas = [r for r in AGENT_RUNS if r["group"] != "Guardrail tests"][:6] + \
                [r for r in AGENT_RUNS if r["id"] in ("A1", "A4")]
        for row in range(0, len(ideas), 2):
            cols = st.columns(2, gap="small")
            for col, r in zip(cols, ideas[row:row + 2]):
                if col.button(r["question"], key=f"live_{r['id']}", use_container_width=True):
                    st.session_state.live_pending = r["question"]
                    st.rerun()
        chat = st.session_state.chat_live
    else:
        st.markdown(
            '<div class="wel"><div class="wel-b">'
            "<b>Recorded.</b> Real answers from the Snowflake Cortex Agent, captured "
            "against the live deployment and replayed unedited. Open <b>Reasoning</b> "
            "under any answer to see the plan, the tools it called and the SQL Cortex "
            "Analyst generated.</div></div>",
            unsafe_allow_html=True,
        )
        for g in RUN_GROUPS:
            runs = [r for r in AGENT_RUNS if r["group"] == g]
            st.markdown(f'<p class="sec">{esc(g)}</p>', unsafe_allow_html=True)
            st.caption(RUN_GROUP_NOTE[g])
            for row in range(0, len(runs), 2):
                cols = st.columns(2, gap="small")
                for col, r in zip(cols, runs[row:row + 2]):
                    if col.button(r["question"], key=f"run_{r['id']}", use_container_width=True):
                        st.session_state.pending = r["id"]
                        st.rerun()
        chat = st.session_state.chat

    if not chat:
        _capabilities()
    else:
        st.markdown('<div class="convo-rule"></div>', unsafe_allow_html=True)

    for m in chat:
        _bubble(m)

    if live:
        typed = st.chat_input("Ask about a customer or the book",
                              max_chars=live_agent.MAX_QUESTION_CHARS)
        prompt = typed or st.session_state.pop("live_pending", None)
        if prompt:
            asked = {"role": "user", "text": prompt, "at": _stamp()}
            chat.append(asked)
            _bubble(asked)
            with st.chat_message("assistant", avatar=COPILOT_AVATAR):
                with st.spinner(f"{COPILOT_NAME} is calling tools and composing…"):
                    text, trace, model = _ask_live(cfg, prompt)
            chat.append({"role": "assistant", "text": text, "trace": trace, "at": _stamp(),
                         "via": f"{model} · live" if model else "live"})
            st.rerun()
    else:
        rid = st.session_state.pop("pending", None)
        run = next((r for r in AGENT_RUNS if r["id"] == rid), None)
        if run:
            chat.append({"role": "user", "text": run["question"], "at": _stamp()})
            chat.append({"role": "assistant", "text": run["answer"] or "_No text returned._",
                         "trace": run["trace"], "at": _stamp(),
                         "via": "Cortex Agent · recorded"})
            st.rerun()

    if chat and st.button("Clear conversation", key="chat_clear"):
        chat.clear()
        st.rerun()


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
               "targeting is <b>ahead</b> at this penalty"), small=True,
              tone="risk" if gap < 0 else "ok")
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
            f'<span style="font-size:.7rem;color:#66707C">{esc(note)}</span></td>'
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
                                                  grid=True, gridColor="#DDE2E8",
                                                  labelColor="#66707C", titleColor="#4F5965",
                                                  labelFontSize=11, titleFontSize=11)),
            y=alt.Y("Net contribution:Q",
                    axis=alt.Axis(title="Net contribution (₹)", grid=True,
                                  gridColor="#DDE2E8", labelColor="#66707C",
                                  titleColor="#4F5965", labelFontSize=11, titleFontSize=11)),
            color=alt.Color("Strategy:N",
                            scale=alt.Scale(domain=["Targeted book", "Contact everyone"],
                                            range=["#0A6A94", "#A32219"]),
                            legend=alt.Legend(orient="top-left", title=None,
                                              labelFontSize=12, labelColor="#2F363F")),
            strokeDash=alt.StrokeDash("Strategy:N", legend=None),
            tooltip=[alt.Tooltip("Acceptance:Q", format=".1%"),
                     alt.Tooltip("Net contribution:Q", format=",.0f"),
                     "Strategy:N"],
        )
    )
    rule = (alt.Chart(pd.DataFrame({"a": [acc]})).mark_rule(
        color="#66707C", strokeDash=[3, 3]).encode(x="a:Q"))

    st.altair_chart(
        (chart + rule).properties(height=260, padding={"left": 4, "right": 18, "top": 6,
                                                       "bottom": 4}).configure_view(strokeWidth=0),
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

    fb = q("""SELECT COUNT(*) N, COUNT(*) FILTER (WHERE DECISION='ACCEPTED') ACC,
                     COALESCE(SUM(EXPECTED_VALUE_INR) FILTER (WHERE DECISION='ACCEPTED'), 0) EV
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
        '<div style="padding:0 0 .1rem"><div class="sb-h">Indian bank and insurer group</div>'
        '<div class="sb-s">5,000 customers · one spine</div></div><hr/>',
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
        '<div class="sb-stat">'
        f'Positions as of <b>{dstr(kk.AS_OF_DATE)}</b><br/>'
        f'<b>{num(kk.ACTIONS_PUBLISHED)}</b> actions published<br/>'
        f'<b>{num(kk.ACTIONS_SUPPRESSED)}</b> suppressed by rule<br/>'
        f'<b>{num(kk.DECISIONS_RECORDED)}</b> RM decisions recorded'
        "</div>",
        unsafe_allow_html=True,
    )
    st.markdown("<hr/>", unsafe_allow_html=True)
    st.markdown(
        '<div class="sb-note">'
        "Expected value and eligibility are deterministic SQL. A model writes the "
        "rationale and never a number. Synthetic data throughout."
        "<br/><br/>This public build runs on Postgres. The original runs in "
        "Snowflake, where the Ask screen calls the Cortex Agent live."
        "</div>",
        unsafe_allow_html=True,
    )

    st.markdown("<hr/>", unsafe_allow_html=True)
    st.markdown(
        '<div class="sb-by">'
        'Created by <span>Akash Sur</span> · Team Coskilled<br/>'
        '<a href="https://sur-akash.github.io/" target="_blank" rel="noopener">'
        'sur-akash.github.io</a>'
        "</div>",
        unsafe_allow_html=True,
    )

# -- masthead -----------------------------------------------------------------
# Drawn in the main column above every screen, so the product and the team are
# on the page whichever screen is showing and whether or not the sidebar is
# open. The band uses the logo's own navy gradient with an ice rule along its
# foot, so the mark (TEAM_LOGO, see the top of the file) sits on its own colours.
st.markdown(
    '<div class="mast"><div>'
    f'<div class="mast-n">{esc(APP_NAME)}</div>'
    '<div class="mast-s">Customer 360 and next best action for an Indian bank '
    'and insurer group</div></div>'
    '<div class="mast-team">'
    f'<div><div class="mast-tn">Team {esc(TEAM_NAME)}</div>'
    '<div class="mast-ts">Akash Sur</div></div>'
    + (f'<img src="{TEAM_LOGO}" alt="{esc(TEAM_NAME)} logo"/>' if TEAM_LOGO else "")
    + "</div></div>",
    unsafe_allow_html=True,
)

SCREENS[choice]()

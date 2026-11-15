"""
test_helpers.py -- the formatting and SQL-literal helpers, tested directly.

These are small, but every number on every screen passes through one of them,
and lit() is the only thing standing between free text and the INSERT.
"""

import datetime as dt
import random

import pandas as pd
import pytest

from contract import AGENT, REJECT_REASONS, SCREENS
from fake_snowflake import DEFAULT_CUSTOMER, unquote

NAN = float("nan")


# -- Indian digit grouping -----------------------------------------------------

@pytest.mark.parametrize("n, want", [
    (0, "0"), (7, "7"), (999, "999"), (1000, "1,000"), (99999, "99,999"),
    (100000, "1,00,000"), (1234567, "12,34,567"), (521397600, "52,13,97,600"),
    (10000000, "1,00,00,000"), (-1234567, "-12,34,567"), (1234.4, "1,234"),
    (1234.6, "1,235"), ("4500", "4,500"),
])
def test_grp_groups_two_two_three(appns, n, want):
    assert appns["grp"](n) == want


@pytest.mark.parametrize("bad", [None, "abc", NAN, ""])
def test_grp_renders_a_dash_for_anything_that_is_not_a_number(appns, bad):
    assert appns["grp"](bad) == "—"


@pytest.mark.parametrize("n, compact, want", [
    (18450, False, "₹18,450"), (521397600, False, "₹52,13,97,600"),
    (99999, True, "₹99,999"), (100000, True, "₹1.00 L"), (838000, True, "₹8.38 L"),
    (10000000, True, "₹1.00 Cr"), (521397600, True, "₹52.14 Cr"), (0, True, "₹0"),
    (None, False, "—"), (NAN, True, "—"),
])
def test_inr(appns, n, compact, want):
    assert appns["inr"](n, compact) == want


def test_num_pct_dec_are_null_safe(appns):
    assert appns["num"](12435) == "12,435" and appns["num"](None) == "—" and appns["num"](NAN) == "—"
    assert appns["pct"](0.4123, 2) == "41.23%" and appns["pct"](0.08) == "8.0%"
    assert appns["pct"](None) == "—" and appns["pct"](NAN) == "—"
    assert appns["dec"](0.4249) == "0.42" and appns["dec"](NAN) == "—" and appns["dec"](None) == "—"


# -- labels ----------------------------------------------------------------------

@pytest.mark.parametrize("raw, want", [
    ("DNC_REGISTRY", "DNC registry"), ("NO_CHANNEL_CONSENT", "No channel consent"),
    ("ARREARS_CROSS_SELL", "Arrears cross sell"), ("kyc_lapsed", "KYC lapsed"),
    ("PAYMENT_ON_TIME", "Payment on time"), ("SMS", "SMS"), ("negative", "Negative"),
    ("WRONG_TIMING", "Wrong timing"), (None, "—"), ("", "—"),
])
def test_words_humanises_codes_and_keeps_acronyms(appns, raw, want):
    assert appns["words"](raw) == want


def test_esc_and_chip_escape_markup(appns):
    assert appns["esc"]("<b>&'\"") == "&lt;b&gt;&amp;&#x27;&quot;"
    assert appns["esc"](None) == ""
    assert appns["chip"]("<x>", "risk") == '<span class="chip c-risk">&lt;x&gt;</span>'
    assert 'chip-dim' in appns["chip"]("a", "neu", dim=True)


@pytest.mark.parametrize("v, want", [
    (None, "—"), (pd.NaT, "—"), (NAN, "—"), ("2026-11-10T06:30:00", "2026-11-10"),
    (dt.date(2026, 11, 10), "10 Nov 2026"), (pd.Timestamp("2026-01-05 23:59"), "05 Jan 2026"),
])
def test_dstr(appns, v, want):
    assert appns["dstr"](v) == want


# -- state encodings (PROJECT_BRIEF D6) ----------------------------------------------

@pytest.mark.parametrize("trend, label", [
    ("NO_CONTACT_HISTORY", "Never contacted"), (None, "Never contacted"),
    ("INSUFFICIENT_DATA", "Trend unknown"),
])
def test_unknown_sentiment_trend_is_never_rendered_as_stable(appns, trend, label):
    html = appns["trend_chip"](trend)
    assert label in html and "chip-dim" in html and "Stable" not in html


@pytest.mark.parametrize("trend, tone", [("IMPROVING", "ok"), ("STABLE", "neu"),
                                         ("DETERIORATING", "risk")])
def test_known_sentiment_trend_carries_its_severity(appns, trend, tone):
    assert f'c-{tone}"' in appns["trend_chip"](trend)


@pytest.mark.parametrize("bucket, text, tone", [
    ("CURRENT", "Current", "ok"), ("NO_CREDIT_OBLIGATION", "No credit", "neu"),
    ("1-30", "1-30 DPD", "warn"), ("31-60", "31-60 DPD", "risk"), ("61-90", "61-90 DPD", "risk"),
    ("90+", "90+ DPD", "warn"),      # an unmapped bucket must still render, as a warning
])
def test_dpd_chip(appns, bucket, text, tone):
    html = appns["dpd_chip"](bucket)
    assert f">{text}<" in html and f"c-{tone}" in html


# -- JSON columns ------------------------------------------------------------------

@pytest.mark.parametrize("v, want", [
    (None, []), (NAN, []), ("", []), ("not json", []), ('["A","B"]', ["A", "B"]),
    (["A"], ["A"]), ('{"rule":"X"}', {"rule": "X"}), ("[]", []),
])
def test_jarr(appns, v, want):
    assert appns["jarr"](v) == want


def test_result_frame(appns):
    rs = {"resultSetMetaData": {"rowType": [{"name": "A"}, {"name": "B"}]}, "data": [["1", "2"]]}
    df = appns["result_frame"](rs)
    assert list(df.columns) == ["A", "B"] and df.iloc[0].tolist() == ["1", "2"]
    assert appns["result_frame"]({}) is None
    assert appns["result_frame"]({"resultSetMetaData": {"rowType": [{"name": "A"}]}}).empty


# -- lit(): the SQL literal builder ----------------------------------------------------

@pytest.mark.parametrize("v, want", [
    (None, "NULL"), (NAN, "NULL"), (True, "TRUE"), (False, "FALSE"), (5, "5"), (1.5, "1.5"),
    ("abc", "'abc'"), ("O'Brien", "'O''Brien'"), ("a\\b", "'a\\\\b'"), ("", "''"),
])
def test_lit(appns, v, want):
    assert appns["lit"](v) == want


def test_lit_round_trips_any_text_through_snowflakes_literal_rules(appns):
    """Property check: whatever lit() emits, parsing it back by Snowflake's rules
    ('' and backslash escapes) yields the original string, as ONE literal."""
    rng = random.Random(2397)
    alphabet = "ab '\\\"\n\t;-%_$(){},₹क"
    for _ in range(2000):
        s = "".join(rng.choice(alphabet) for _ in range(rng.randint(0, 24)))
        assert unquote(appns["lit"](s)) == s


# -- constants other files depend on -----------------------------------------------------

def test_constants_agree_with_the_contract(appns):
    assert appns["REJECT_REASONS"] == REJECT_REASONS
    assert appns["AGENT"] == AGENT
    assert list(appns["SCREENS"]) == SCREENS
    assert appns["DEFAULT_CUSTOMER"] == DEFAULT_CUSTOMER
    assert len(appns["SUGGESTED"]) == 4 and all(q.endswith("?") for q in appns["SUGGESTED"])


def test_every_tone_used_has_a_css_class(appns):
    tones = set()
    for name in ("DPD_TONE", "SENT_TONE", "TREND_TONE", "BAND_TONE", "CAT_TONE", "TL_TONE"):
        tones |= set(appns[name].values())
    for tone in tones:
        assert f".c-{tone}" in appns["CSS"], f"chip tone '{tone}' has no .c-{tone} rule in CSS"

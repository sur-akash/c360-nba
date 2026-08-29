#!/usr/bin/env python3
"""
Build two-speaker call-recording fixtures for sql/06_audio_demo.sql.

Why this exists
---------------
AI_TRANSCRIBE with timestamp_granularity='speaker' does real diarisation, so a
fixture recorded in a single voice would come back as one speaker and the whole
point of the audio path -- turn-structured transcripts indistinguishable from
the generated ones -- would be lost.

macOS `say` speaks with one voice per invocation, so each turn is synthesised
separately with an alternating voice and the turns are concatenated. The stdlib
`wave` module does the concatenation, so there is no ffmpeg/sox dependency;
`afconvert` (shipped with macOS) then produces the AAC/M4A that AI_TRANSCRIBE
accepts.

Per PROJECT_BRIEF D1 this is a BUILD-TIME fixture generator, not a runtime
dependency, so the no-external-services rule still holds for the pipeline.

Usage
-----
    python3 docs/audio_scripts/build_fixtures.py

Reads  docs/audio_scripts/*.txt   lines of  SPEAKER|text
Writes data/audio/<name>.m4a
"""

import os
import re
import subprocess
import sys
import wave
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT_DIR = ROOT / "docs" / "audio_scripts"
OUT_DIR = ROOT / "data" / "audio"

# Indian English voices, distinct enough for diarisation to separate them.
# Hinglish is spoken by the en_IN voices too: they handle Roman-script Hindi
# far more intelligibly than the hi_IN voice does, which expects Devanagari.
VOICES = {"AGENT": "Rishi", "CUSTOMER": "Tara"}

# say writes AIFF by default; ask for linear PCM WAV so `wave` can read it.
SAY_FORMAT = "LEI16@22050"

# A beat of silence between turns. Diarisation keys off speaker changes, and
# back-to-back turns with no gap are markedly harder to separate.
GAP_SECONDS = 0.35


def synth_turn(text: str, voice: str, path: Path) -> None:
    subprocess.run(
        ["say", "-v", voice, "--data-format=" + SAY_FORMAT, "-o", str(path), text],
        check=True,
    )


def concat_wavs(parts: list[Path], out: Path, gap_seconds: float) -> float:
    with wave.open(str(parts[0]), "rb") as first:
        params = first.getparams()

    silence = b"\x00" * int(
        params.framerate * gap_seconds * params.sampwidth * params.nchannels
    )

    total_frames = 0
    with wave.open(str(out), "wb") as dst:
        dst.setparams(params)
        for i, part in enumerate(parts):
            with wave.open(str(part), "rb") as src:
                if src.getparams()[:3] != params[:3]:
                    raise RuntimeError(f"format mismatch in {part}")
                frames = src.readframes(src.getnframes())
            dst.writeframes(frames)
            total_frames += len(frames) // (params.sampwidth * params.nchannels)
            if i != len(parts) - 1:
                dst.writeframes(silence)
                total_frames += int(params.framerate * gap_seconds)

    return total_frames / params.framerate


def to_m4a(wav: Path, m4a: Path) -> None:
    # 64 kbps mono AAC. Speech at this rate transcribes cleanly and keeps the
    # committed fixtures small enough to live in git.
    subprocess.run(
        ["afconvert", "-f", "m4af", "-d", "aac", "-b", "64000",
         str(wav), str(m4a)],
        check=True,
    )


def build(script: Path) -> None:
    turns = []
    for lineno, raw in enumerate(script.read_text().splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if "|" not in line:
            sys.exit(f"{script.name}:{lineno}: expected 'SPEAKER|text'")
        speaker, text = line.split("|", 1)
        speaker = speaker.strip().upper()
        if speaker not in VOICES:
            sys.exit(f"{script.name}:{lineno}: unknown speaker {speaker!r}")
        turns.append((speaker, text.strip()))

    if not turns:
        sys.exit(f"{script.name}: no turns found")

    tmp = OUT_DIR / ".tmp"
    tmp.mkdir(parents=True, exist_ok=True)

    parts = []
    for i, (speaker, text) in enumerate(turns):
        part = tmp / f"{script.stem}_{i:03d}.wav"
        synth_turn(text, VOICES[speaker], part)
        parts.append(part)

    joined = tmp / f"{script.stem}.wav"
    duration = concat_wavs(parts, joined, GAP_SECONDS)

    out = OUT_DIR / f"{script.stem}.m4a"
    to_m4a(joined, out)

    for p in parts:
        p.unlink()
    joined.unlink()

    speakers = sorted({s for s, _ in turns})
    print(
        f"{out.relative_to(ROOT)}  "
        f"{len(turns)} turns  {duration:5.1f}s  "
        f"{out.stat().st_size / 1024:6.1f} KB  "
        f"speakers={','.join(speakers)}"
    )


def main() -> None:
    if sys.platform != "darwin":
        sys.exit("needs macOS: uses `say` and `afconvert`")

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    scripts = sorted(SCRIPT_DIR.glob("*.txt"))
    if not scripts:
        sys.exit(f"no .txt scripts in {SCRIPT_DIR}")

    for s in scripts:
        build(s)

    tmp = OUT_DIR / ".tmp"
    if tmp.exists() and not any(tmp.iterdir()):
        tmp.rmdir()

    print()
    print("Upload with:")
    print("  snow stage copy data/audio/ @C360_NBA.RAW.AUDIO_STAGE -c coco")
    print("then re-run sql/06_audio_demo.sql")


if __name__ == "__main__":
    main()

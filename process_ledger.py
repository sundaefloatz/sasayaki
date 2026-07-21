#!/usr/bin/env python3
"""
process_ledger.py -- Per-work PROCESSING-VERSION LEDGER for the Sasayaki ASMR pipeline.

Builds <library>/_data/process_ledger.json: for every work known to
_wiki/audio_index.json, records WHEN it was last processed at each pipeline stage
(transcribe / resegment / translate / revise) and WHICH stage it still needs, by
inspecting mtimes of files under _data/derived.

This is read-only against all existing project data. The only file it writes is its
own output JSON.

Usage:
    python process_ledger.py            # (re)build the ledger and write the JSON
    python process_ledger.py --report   # print a plain-text bucket table from the
                                         # ledger JSON already on disk (does not rebuild)
"""

from __future__ import annotations

import json
import os
import re
import sys
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path

PIPELINE_VER = "1"

ASMR_ROOT = Path(os.environ.get("SASAYAKI_ROOT", "/media"))
AUDIO_INDEX_PATH = ASMR_ROOT / "_wiki" / "audio_index.json"
DERIVED_ROOT = ASMR_ROOT / "_data" / "derived"
OUTPUT_PATH = ASMR_ROOT / "_data" / "process_ledger.json"

# Recognized derived-subtitle filenames (exact match) plus the "official.*" glob family.
RECOGNIZED_EXACT = {"ja.srt", "rseg.ja.srt", "rseg.en.srt", "claude.en.srt", "en.srt"}

PLACEHOLDER_RE = re.compile(r"^\*(?:…|\.\.\.)\*$")

TIER_ORDER = ["official", "claude", "rseg", "asr", "none"]


def _is_recognized(filename: str) -> bool:
    return filename in RECOGNIZED_EXACT or filename.startswith("official.")


def load_json_sanitized(path: Path):
    """Load a JSON file that may contain bare -Infinity/Infinity/NaN tokens."""
    raw = path.read_text(encoding="utf-8")
    # Replace bare (not already inside a longer identifier/number) Infinity/-Infinity/NaN
    # tokens with null so json.loads doesn't choke on them.
    raw = re.sub(r"(?<![0-9A-Za-z_.])-Infinity", "null", raw)
    raw = re.sub(r"(?<![0-9A-Za-z_.])Infinity", "null", raw)
    raw = re.sub(r"(?<![0-9A-Za-z_.])NaN", "null", raw)
    return json.loads(raw)


def iso_mtime(path: Path) -> str:
    ts = path.stat().st_mtime
    return datetime.fromtimestamp(ts, tz=timezone.utc).isoformat().replace("+00:00", "Z")


def parse_srt_cues(text: str) -> list[str]:
    """Return the list of cue text bodies (trimmed) in an SRT file's contents.

    Tolerant of minor malformation: finds each block's timestamp line ("-->") and
    treats everything after it (until the next blank-line-separated block) as the
    cue text.
    """
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    blocks = re.split(r"\n\s*\n", text.strip())
    cues = []
    for block in blocks:
        if not block.strip():
            continue
        lines = block.split("\n")
        ts_idx = None
        for i, line in enumerate(lines):
            if "-->" in line:
                ts_idx = i
                break
        if ts_idx is None:
            continue
        cue_text = "\n".join(lines[ts_idx + 1:]).strip()
        cues.append(cue_text)
    return cues


def compute_placeholder_rate(rseg_en_path: Path) -> float:
    try:
        text = rseg_en_path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return 0.0
    cues = parse_srt_cues(text)
    if not cues:
        return 0.0
    placeholder_count = sum(1 for c in cues if PLACEHOLDER_RE.match(c.strip()))
    return placeholder_count / len(cues)


def build_derived_index(derived_root: Path):
    """Walk _data\\derived once. Index every leaf dir (a directory containing any
    recognized subtitle file) by (creator, basename), where creator is the first
    path component under derived_root.

    Returns (index, leaf_dir_count).
    """
    index: dict[tuple[str, str], list[Path]] = defaultdict(list)
    leaf_dir_count = 0
    for dirpath, dirnames, filenames in os.walk(derived_root):
        if not filenames:
            continue
        if not any(_is_recognized(fn) for fn in filenames):
            continue
        p = Path(dirpath)
        try:
            rel_parts = p.relative_to(derived_root).parts
        except ValueError:
            continue
        if not rel_parts:
            # Recognized files sitting directly at the derived root (shouldn't
            # happen, but guard against it rather than crash).
            continue
        leaf_dir_count += 1
        creator = rel_parts[0]
        # Windows silently STRIPS trailing dots/spaces when creating directories, so a work titled
        # "...直升机.." gets a derived dir named without them while audio_index keeps the full name.
        # Normalize both sides (see relpath_basename_noext) or those works false-report as need-ASR.
        basename = p.name.rstrip(". ")
        index[(creator, basename)].append(p)
    return index, leaf_dir_count


def relpath_basename_noext(relpath: str) -> str:
    last_segment = re.split(r"[\\/]+", relpath)[-1]
    # match build_derived_index: Windows strips trailing dots/spaces from real dir names
    return os.path.splitext(last_segment)[0].rstrip(". ")


def stage_info_for_leaf(leaf_dir: Path):
    """Inspect one matched leaf dir and return (stages, current_tier,
    placeholder_rate, needs)."""
    try:
        files = {f.name: f for f in leaf_dir.iterdir() if f.is_file()}
    except OSError:
        files = {}

    stages: dict[str, dict[str, str]] = {}
    if "ja.srt" in files:
        stages["transcribe"] = {"at": iso_mtime(files["ja.srt"])}
    if "rseg.ja.srt" in files:
        stages["resegment"] = {"at": iso_mtime(files["rseg.ja.srt"])}
    if "rseg.en.srt" in files:
        stages["translate"] = {"at": iso_mtime(files["rseg.en.srt"])}
    if "claude.en.srt" in files:
        stages["revise"] = {"at": iso_mtime(files["claude.en.srt"])}

    has_official = any(name.startswith("official.") for name in files)
    if has_official:
        tier = "official"
    elif "claude.en.srt" in files:
        tier = "claude"
    elif "rseg.en.srt" in files or "rseg.ja.srt" in files:
        tier = "rseg"
    elif "ja.srt" in files:
        tier = "asr"
    else:
        tier = "none"

    placeholder_rate = 0.0
    if "rseg.en.srt" in files:
        placeholder_rate = compute_placeholder_rate(files["rseg.en.srt"])

    if tier in ("official", "claude"):
        needs = []
    elif "ja.srt" not in files:
        needs = ["asr"]
    elif "rseg.ja.srt" not in files:
        needs = ["reseg"]
    elif "rseg.en.srt" not in files or placeholder_rate > 0.02:
        needs = ["translate"]
    else:
        needs = []

    return stages, tier, placeholder_rate, needs


def build_ledger():
    # audio_index.json is analyze_audio.py's output. On a fresh CPU-only install it may not exist
    # yet -- treat a missing/unreadable index as an empty library and emit a valid empty ledger
    # rather than crashing with FileNotFoundError.
    if AUDIO_INDEX_PATH.exists():
        try:
            audio_index = load_json_sanitized(AUDIO_INDEX_PATH)
        except (ValueError, OSError):
            audio_index = {}
    else:
        audio_index = {}
    derived_index, leaf_dir_count = build_derived_index(DERIVED_ROOT)

    works = {}
    skipped_unmappable = 0
    skipped_examples = []

    for relpath, meta in audio_index.items():
        creator = meta.get("creator")
        basename = relpath_basename_noext(relpath)
        candidates = derived_index.get((creator, basename), [])

        if len(candidates) == 1:
            stages, tier, placeholder_rate, needs = stage_info_for_leaf(candidates[0])
        elif len(candidates) == 0:
            # No derived dir anywhere for this work -> unprocessed.
            stages, tier, placeholder_rate, needs = {}, "none", 0.0, ["asr"]
        else:
            # Ambiguous: multiple candidate leaf dirs share this (creator, basename).
            # Do not guess -- skip and count it.
            skipped_unmappable += 1
            if len(skipped_examples) < 10:
                skipped_examples.append(relpath)
            continue

        works[relpath] = {
            "creator": creator,
            "current_tier": tier,
            "stages": stages,
            "placeholder_rate": round(placeholder_rate, 4),
            "needs": needs,
        }

    # pre-computed bucket summary for the app (community vs DLsite split), so /ledger.json
    # consumers don't re-aggregate 690 works client-side.
    summary = {
        "community": {"need-asr": 0, "need-reseg": 0, "need-translate": 0, "done": 0},
        "dlsite": {"need-asr": 0, "need-reseg": 0, "need-translate": 0, "done": 0},
    }
    for w in works.values():
        grp = "dlsite" if w["creator"] == "DLsite" else "community"
        summary[grp][_bucket_for(w["needs"])] += 1

    ledger = {
        "pipeline_ver": PIPELINE_VER,
        "generated_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "summary": summary,
        "works": works,
        "skipped_unmappable": skipped_unmappable,
    }
    return ledger, leaf_dir_count, skipped_examples


def write_ledger(ledger: dict):
    OUTPUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    with OUTPUT_PATH.open("w", encoding="utf-8") as f:
        json.dump(ledger, f, ensure_ascii=False, indent=2)


# ---------------------------------------------------------------------------
# --report mode
# ---------------------------------------------------------------------------

def _bucket_for(needs: list[str]) -> str:
    if not needs:
        return "done"
    if "asr" in needs:
        return "need-asr"
    if "reseg" in needs:
        return "need-reseg"
    if "translate" in needs:
        return "need-translate"
    return "done"


def print_report():
    if not OUTPUT_PATH.exists():
        print(f"No ledger found at {OUTPUT_PATH}. Run `python process_ledger.py` first.")
        return

    ledger = load_json_sanitized(OUTPUT_PATH)
    works = ledger.get("works", {})
    skipped = ledger.get("skipped_unmappable", 0)

    by_creator: dict[str, dict[str, int]] = defaultdict(lambda: defaultdict(int))
    for relpath, w in works.items():
        creator = w.get("creator", "?")
        bucket = _bucket_for(w.get("needs", []))
        by_creator[creator][bucket] += 1

    buckets = ["need-asr", "need-reseg", "need-translate", "done"]
    header = f"{'Creator':<38} {'need-ASR':>9} {'need-reseg':>11} {'need-translate':>15} {'done':>6} {'total':>6}"

    def print_section(title: str, creators: list[str]):
        print(f"\n=== {title} ===")
        print(header)
        print("-" * len(header))
        sec_totals = defaultdict(int)
        for creator in sorted(creators):
            counts = by_creator[creator]
            total = sum(counts.get(b, 0) for b in buckets)
            print(
                f"{creator:<38} {counts.get('need-asr', 0):>9} {counts.get('need-reseg', 0):>11} "
                f"{counts.get('need-translate', 0):>15} {counts.get('done', 0):>6} {total:>6}"
            )
            for b in buckets:
                sec_totals[b] += counts.get(b, 0)
        sec_total_all = sum(sec_totals[b] for b in buckets)
        print("-" * len(header))
        print(
            f"{'SECTION TOTAL':<38} {sec_totals['need-asr']:>9} {sec_totals['need-reseg']:>11} "
            f"{sec_totals['need-translate']:>15} {sec_totals['done']:>6} {sec_total_all:>6}"
        )
        return sec_totals, sec_total_all

    all_creators = set(by_creator.keys())
    dlsite_creators = {c for c in all_creators if c == "DLsite"}
    other_creators = all_creators - dlsite_creators

    other_totals, other_total_all = print_section("Non-DLsite creators", sorted(other_creators))
    dl_totals, dl_total_all = (defaultdict(int), 0)
    if dlsite_creators:
        dl_totals, dl_total_all = print_section(
            "DLsite (bulk, usually intentionally left un-resegmented)", sorted(dlsite_creators)
        )

    grand_total = other_total_all + dl_total_all
    grand_needs_asr = other_totals["need-asr"] + dl_totals["need-asr"]
    grand_needs_reseg = other_totals["need-reseg"] + dl_totals["need-reseg"]
    grand_needs_translate = other_totals["need-translate"] + dl_totals["need-translate"]
    grand_done = other_totals["done"] + dl_totals["done"]

    print(
        f"\nGRAND TOTAL: {grand_total} works "
        f"(need-ASR={grand_needs_asr}, need-reseg={grand_needs_reseg}, "
        f"need-translate={grand_needs_translate}, done={grand_done}); "
        f"skipped as unmappable (ambiguous derived-dir match)={skipped}"
    )


def main():
    if sys.stdout.encoding is None or "utf-8" not in sys.stdout.encoding.lower():
        try:
            sys.stdout.reconfigure(encoding="utf-8")
        except Exception:
            pass

    if "--report" in sys.argv:
        print_report()
        return

    ledger, leaf_dir_count, skipped_examples = build_ledger()
    write_ledger(ledger)
    print(f"Wrote {OUTPUT_PATH}")
    print(f"pipeline_ver={ledger['pipeline_ver']} generated_at={ledger['generated_at']}")
    print(f"works mapped: {len(ledger['works'])}")
    print(f"derived leaf dirs indexed: {leaf_dir_count}")
    print(f"skipped as unmappable (ambiguous): {ledger['skipped_unmappable']}")
    if skipped_examples:
        print("skipped examples (up to 10):")
        for ex in skipped_examples:
            print(f"  - {ex}")


if __name__ == "__main__":
    main()

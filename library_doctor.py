#!/usr/bin/env python3
r"""
library_doctor.py -- library integrity checker (stdlib-only, CPU-only, no network).

Verifies the derived state (_wiki/audio_index.json, thumb cache, derived mirror, sidecars)
against what is actually on disk, and repairs the safe subset. Every check below corresponds
to a real drift class this library has hit in production:

  1. stale-index      index keys whose media file no longer exists (caused the "unicode 404"
                      bug -- orphaned entries pointing at renamed/removed files)
  2. mixed-separators the same file indexed under BOTH '\' and '/' keys (happens when a
                      Windows-built index is extended by a Linux run, e.g. PC + NAS)
  3. nonfinite        Infinity/-Infinity/NaN tokens in the index (pre-2026-07-21 analyzer
                      wrote them; they are invalid JSON and corrupt naive consumers)
  4. unindexed        media files on disk the index doesn't know yet (not an error -- they
                      surface as "pending" cards -- but tells the maintainer analyze must run)
  5. zero-byte        0-byte / unreadable media files (report-only: NEVER touches user media)
  6. orphan-derived   _data/derived/<Creator>/<work>/ dirs whose library work is gone
                      (report-only; they may hold the only surviving subtitles)
  7. orphan-thumbs    _wiki/thumbs/ cache entries whose index id no longer exists (cache ->
                      safe to delete)
  8. orphan-sidecars  .source.json files whose media file is gone (report-only)

  python library_doctor.py --root "D:\...\Asmr"            # report + exit code (0 clean, 1 issues)
  python library_doctor.py --root "D:\...\Asmr" --fix      # apply the safe fixes (1,2,3,7)
Writes a machine-readable summary to <root>\_data\doctor_report.json either way.
"""
import os, re, sys, json, glob, hashlib, argparse, tempfile, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import analyze_audio  # reuse targets() + extension sets so "what counts as media" never drifts

EXAMPLES = 8   # max examples printed per finding


def load_index_tolerant(path):
    """Load audio_index.json accepting legacy Infinity/NaN tokens; count them."""
    raw = open(path, encoding="utf-8").read()
    bad = {"n": 0}

    def _const(_name):
        bad["n"] += 1
        return None

    idx = json.loads(raw, parse_constant=_const)
    return idx, bad["n"]


def atomic_write_json(path, obj):
    d = os.path.dirname(path)
    fd, tmp = tempfile.mkstemp(prefix=".doctor_", suffix=".json", dir=d)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(obj, f, ensure_ascii=False)
    os.replace(tmp, path)


def thumb_hash(work_id):
    """Mirror Get-WorkThumb's cache key: SHA1(id) hex, first 16 chars, uppercase."""
    return hashlib.sha1(work_id.encode("utf-8")).hexdigest()[:16].upper()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=analyze_audio.ROOT_DEFAULT)
    ap.add_argument("--fix", action="store_true",
                    help="apply safe fixes: drop stale entries, collapse mixed-separator dupes, "
                         "null out non-finite values, delete orphaned thumb-cache files")
    a = ap.parse_args()
    root = a.root
    sep = os.sep
    foreign = "/" if sep == "\\" else "\\"

    aip = os.path.join(root, "_wiki", "audio_index.json")
    findings = {}
    fixed = {}

    if not os.path.exists(aip):
        print(f"no index at {aip} -- run analyze_audio.py first")
        sys.exit(1)

    idx, nonfinite = load_index_tolerant(aip)
    print(f"index: {len(idx)} entries  ({aip})")

    # --- 1+2: stale entries and mixed-separator duplicates ---------------------------------
    stale, dupes, renames = [], [], []
    norm_seen = {}
    for k in list(idx.keys()):
        norm = k.replace(foreign, sep)
        exists = os.path.exists(os.path.join(root, norm))
        if norm in norm_seen:
            dupes.append(k)          # second sighting of the same real file
            continue
        norm_seen[norm] = k
        if not exists:
            stale.append(k)
        elif k != norm:
            renames.append(k)        # exists but keyed with the foreign separator
    findings["stale_index"] = stale
    findings["mixed_separator_dupes"] = dupes
    findings["foreign_separator_keys"] = renames
    findings["nonfinite_values"] = nonfinite

    # --- 4: unindexed media on disk ---------------------------------------------------------
    known = set(norm_seen.keys())
    unindexed = []
    for p in analyze_audio.targets(root, [], ""):
        rel = os.path.relpath(p, root)
        if rel not in known:
            unindexed.append(rel)
    findings["unindexed_files"] = unindexed

    # --- 5: zero-byte media (report-only) ---------------------------------------------------
    zero = []
    for p in analyze_audio.targets(root, [], ""):
        try:
            if os.path.getsize(p) == 0:
                zero.append(os.path.relpath(p, root))
        except OSError:
            zero.append(os.path.relpath(p, root))
    findings["zero_byte_files"] = zero

    # --- 6: orphaned derived dirs (report-only -- may hold the only surviving subs) ---------
    # Match by (creator, leaf dir name) exactly like process_ledger.build_derived_index does:
    # derived layouts vary (flat works vs self-named per-work subfolders), but the leaf dir is
    # always named after the work's file stem, and creator is always the first path component.
    # Windows silently strips trailing dots/spaces from real dir names -> strip on both sides.
    derived = os.path.join(root, "_data", "derived")
    pairs = {(norm.split(sep)[0], os.path.splitext(os.path.basename(norm))[0].rstrip(". "))
             for norm in known}
    orphan_derived = []
    if os.path.isdir(derived):
        for dirpath, dirnames, filenames in os.walk(derived):
            if not filenames:
                continue
            rel = os.path.relpath(dirpath, derived)
            parts = rel.split(sep)
            if len(parts) < 2:
                continue   # files sitting at the creator level / derived root: not a work leaf
            key = (parts[0], os.path.basename(rel).rstrip(". "))
            if key not in pairs:
                orphan_derived.append(rel)
    findings["orphan_derived_dirs"] = orphan_derived

    # --- 7: orphaned thumb-cache entries (safe to delete: it's a cache) ---------------------
    thumbs = os.path.join(root, "_wiki", "thumbs")
    live_hashes = {thumb_hash(k) for k in idx}
    orphan_thumbs = []
    if os.path.isdir(thumbs):
        for f in os.listdir(thumbs):
            stem, ext = os.path.splitext(f)
            if ext.lower() == ".jpg" and len(stem) == 16 and stem not in live_hashes:
                orphan_thumbs.append(f)
    findings["orphan_thumbs"] = orphan_thumbs

    # --- 8: orphaned .source.json sidecars (report-only) ------------------------------------
    orphan_sidecars = []
    for p in glob.glob(os.path.join(glob.escape(root), "**", "*.source.json"), recursive=True):
        stem = p[:-len(".source.json")]
        if not any(os.path.exists(stem + e) for e in analyze_audio.AUD + analyze_audio.VID):
            orphan_sidecars.append(os.path.relpath(p, root))
    findings["orphan_sidecars"] = orphan_sidecars

    # --- fixes ------------------------------------------------------------------------------
    if a.fix:
        changed = False
        if stale:
            for k in stale:
                del idx[k]
            fixed["stale_index_dropped"] = len(stale); changed = True
        if dupes:
            for k in dupes:
                idx.pop(k, None)
            fixed["separator_dupes_dropped"] = len(dupes); changed = True
        if renames:
            for k in renames:
                idx[k.replace(foreign, sep)] = idx.pop(k)
            fixed["foreign_keys_renamed"] = len(renames); changed = True
        if nonfinite:
            fixed["nonfinite_nulled"] = nonfinite; changed = True   # nulled at load time
        if changed:
            atomic_write_json(aip, idx)
        if orphan_thumbs:
            for f in orphan_thumbs:
                try:
                    os.remove(os.path.join(thumbs, f))
                except OSError:
                    pass
            fixed["orphan_thumbs_deleted"] = len(orphan_thumbs)

    # --- report ------------------------------------------------------------------------------
    LABELS = [
        ("stale_index",            "index entries whose file is GONE", True),
        ("mixed_separator_dupes",  "duplicate keys (mixed path separators)", True),
        ("foreign_separator_keys", "keys using the foreign path separator", True),
        ("nonfinite_values",       "non-finite values in index (Infinity/NaN)", True),
        ("unindexed_files",        "media on disk not yet indexed (run analyze)", False),
        ("zero_byte_files",        "zero-byte/unreadable media files", False),
        ("orphan_derived_dirs",    "derived dirs with no matching work", False),
        ("orphan_thumbs",          "orphaned thumb-cache entries", True),
        ("orphan_sidecars",        "orphaned .source.json sidecars", False),
    ]
    print()
    issues = 0
    for key, label, fixable in LABELS:
        v = findings[key]
        n = v if isinstance(v, int) else len(v)
        issues += n if key != "unindexed_files" else 0   # unindexed is advisory, not an issue
        tag = "FIX " if (fixable and a.fix and n) else ("fixable" if fixable and n else "")
        print(f"  {n:>5}  {label:48} {tag}")
        if isinstance(v, list):
            for ex in v[:EXAMPLES]:
                print(f"         - {ex if len(str(ex)) < 100 else str(ex)[:97] + '...'}")
            if len(v) > EXAMPLES:
                print(f"         ... and {len(v) - EXAMPLES} more")

    summary = {
        "checkedAt": time.strftime("%Y-%m-%d %H:%M:%S"),
        "root": root, "indexEntries": len(idx),
        "counts": {k: (v if isinstance(v, int) else len(v)) for k, v in findings.items()},
        "fixed": fixed,
    }
    rp = os.path.join(root, "_data", "doctor_report.json")
    os.makedirs(os.path.dirname(rp), exist_ok=True)
    atomic_write_json(rp, summary)

    if fixed:
        print(f"\nfixes applied: {fixed}")
    print(f"\nreport -> {rp}")
    healthy = issues == 0
    fixable_left = (not a.fix) and any(
        (findings[k] if isinstance(findings[k], int) else len(findings[k]))
        for k, _label, fx in LABELS if fx)
    print("healthy" if healthy else
          f"{issues} issue(s) found" + ("  (run with --fix to repair the safe subset)" if fixable_left else ""))
    sys.exit(0 if healthy else 1)


if __name__ == "__main__":
    main()

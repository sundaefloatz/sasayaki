#!/usr/bin/env python3
r"""
source_scan.py -- inventory every work and label its ACQUISITION PLATFORM (youtube / ci-en /
twitcasting / openrec / dlsite / fanbox / bilibili / ...), so the library can be filtered/badged
by source. Read-only; writes _data/source_platform.json. Companion to provenance_scan.py, which
labels subtitle PRODUCTION source (official/machine) -- a different axis from ACQUISITION platform.

Mirrors provenance_scan.py's proven shape: inventory scan, classify, one JSON, zero file moves.

Classification, in confidence order (all read-only signals):
  1. sidecar     -- a "<stem>.source.json" written by a grabber at download time (highest confidence)
  2. dlsite      -- under a DLsite/ subfolder, or an RJ code cross-referenced in _products.json
  3. twitcasting -- filename ends in a TwitCasting numeric stream-id (grab_twitcasting_hls.py convention)
  4. openrec     -- filename contains an id listed in that creator's _openrec_manifest.json
  5. youtube     -- ever staged under _data/yt_ingest/<channel>/, or a sibling .archive.txt marker
  6. ci-en       -- filename carries the extract_cien_audio.py after-talk marker (weak but unique)
  7. single-source fallback -- creator's _sources.txt names exactly ONE non-social platform domain
  8. unknown     -- no signal; flagged for manual curation, never guessed

  python source_scan.py                      # scan + write _data/source_platform.json
  python source_scan.py --selftest
"""
import os, re, json, glob, argparse, tempfile, shutil, time

ROOT = os.environ.get("SASAYAKI_ROOT", "/media")
SKIP = {"Sasayaki", "_wiki", "_data", "_secrets", "_remote", "covers", "models", "_font_backup",
        "_backups", "_jobs", "_test"}
AUD = (".m4a", ".mp3", ".wav", ".flac", ".opus", ".ogg", ".mp4", ".mkv", ".m4v", ".webm")

_TC_ID = re.compile(r"_(\d{7,12})\.\w+$")                  # grab_twitcasting_hls.py: <base>_<streamid>.ext
_CIEN_MARKER = re.compile(r"アフタートーク|\(part \d+\)")    # extract_cien_audio.py naming quirks

_DOMAIN_PLATFORM = [
    ("youtube.com", "youtube"), ("youtu.be", "youtube"),
    ("ci-en.net", "ci-en"),
    ("fanbox.cc", "fanbox"),
    ("twitcasting.tv", "twitcasting"),
    ("openrec.tv", "openrec"),
    ("dlsite.com", "dlsite"),
    ("bilibili.com", "bilibili"),
    ("nicochannel.jp", "niconico"), ("nicovideo.jp", "niconico"), ("ch.nicovideo.jp", "niconico"),
    ("fantia.jp", "fantia"),
]
_SOCIAL_DOMAINS = {"x.com", "twitter.com"}   # bio/social links, not a media-hosting source


def write_source_sidecar(dest_path, platform, source_url="", extra=None):
    """Write a '<dest_path-without-ext>.source.json' sidecar recording the acquisition platform, so
    future source_scan.py runs never have to guess. Grabbers call this after a successful download.
    Best-effort: a sidecar-write failure must never fail the download itself."""
    try:
        stem = os.path.splitext(dest_path)[0]
        payload = {"platform": platform, "source_url": source_url, "acquired": time.strftime("%Y-%m-%d")}
        if extra:
            payload.update(extra)
        json.dump(payload, open(stem + ".source.json", "w", encoding="utf-8"), ensure_ascii=False)
    except Exception:
        pass


def _sources_platforms(creator_dir):
    """Distinct non-social platforms named in <creator>/_sources.txt."""
    p = os.path.join(creator_dir, "_sources.txt")
    if not os.path.exists(p):
        return set()
    txt = open(p, encoding="utf-8", errors="ignore").read().lower()
    found = set()
    for domain, platform in _DOMAIN_PLATFORM:
        if domain in txt:
            found.add(platform)
    return found


def _openrec_ids(creator_dir):
    p = os.path.join(creator_dir, "_openrec_manifest.json")
    if not os.path.exists(p):
        return set()
    try:
        return {str(m.get("id")) for m in json.load(open(p, encoding="utf-8")) if m.get("id")}
    except Exception:
        return set()


def _dlsite_rjs(root):
    """RJ codes the library already knows about, from _wiki/DLsite/_products.json."""
    p = os.path.join(root, "_wiki", "DLsite", "_products.json")
    rjs = set()
    if os.path.exists(p):
        try:
            for prod in json.load(open(p, encoding="utf-8")).get("products", []):
                if prod.get("rj"):
                    rjs.add(prod["rj"])
        except Exception:
            pass
    return rjs


def _yt_ingest_basenames(yt_ingest_root):
    """basenames ever staged under _data/yt_ingest/**/ (survives a later promotion/move)."""
    names = set()
    if not os.path.isdir(yt_ingest_root):
        return names
    for dp, _, fs in os.walk(yt_ingest_root):
        for f in fs:
            names.add(f)
    return names


def classify(fname, dp, creator_dir, dlsite_rjs, yt_names, openrec_ids, sources_platforms, under_dlsite):
    """Return (platform, confidence, signal)."""
    stem = os.path.splitext(fname)[0]
    sidecar = os.path.join(dp, stem + ".source.json")
    if os.path.exists(sidecar):
        try:
            d = json.load(open(sidecar, encoding="utf-8"))
            if d.get("platform"):
                return d["platform"], "high", "sidecar"
        except Exception:
            pass

    if under_dlsite:
        return "dlsite", "high", "DLsite/ subfolder"
    m = re.search(r"RJ\d{6,}", fname)
    if m and m.group(0) in dlsite_rjs:
        return "dlsite", "high", f"RJ code {m.group(0)} in _products.json"

    if openrec_ids and any(oid in fname for oid in openrec_ids):
        return "openrec", "high", "id in _openrec_manifest.json"

    if fname in yt_names:
        return "youtube", "high", "staged under _data/yt_ingest/"
    if os.path.exists(os.path.join(dp, ".archive.txt")):
        return "youtube", "high", ".archive.txt sibling (yt-dlp download-archive)"

    if _CIEN_MARKER.search(fname):
        return "ci-en", "medium", "アフタートーク/(part N) naming (extract_cien_audio.py)"
    if "fanbox" in fname.lower():
        return "fanbox", "medium", "'FANBOX' in filename"

    # twitcasting is a bare numeric-suffix heuristic, so it must rank BELOW the higher-confidence
    # signals above -- otherwise a FANBOX/YouTube file that happens to carry a numeric id suffix
    # (e.g. a fanbox post id "..._831651088.m4a") gets misfiled as twitcasting.
    m = _TC_ID.search(fname)
    if m:
        return "twitcasting", "high", f"stream-id suffix _{m.group(1)}"

    if len(sources_platforms) == 1:
        only = next(iter(sources_platforms))
        return only, "medium", f"single platform in _sources.txt ({only})"

    return "unknown", "low", "no signal"


def scan(root=None, log=print):
    root = root or ROOT
    out = os.path.join(root, "_data", "source_platform.json")   # derived from `root`, NOT module OUT --
    # otherwise selftest(tempdir) and any explicit --root both write into the DEFAULT library's _data/.
    yt_ingest_root = os.path.join(root, "_data", "yt_ingest")
    dlsite_rjs = _dlsite_rjs(root)
    yt_names = _yt_ingest_basenames(yt_ingest_root)

    counts = {}
    by_creator = {}
    for top in sorted(os.listdir(root)):
        if top in SKIP or top.startswith("_") or top.startswith("."):
            continue
        cdir = os.path.join(root, top)
        if not os.path.isdir(cdir):
            continue
        sources_platforms = _sources_platforms(cdir) - _SOCIAL_DOMAINS
        openrec_ids = _openrec_ids(cdir)
        for dp, _, fs in os.walk(cdir):
            under_dlsite = "DLsite" in dp
            for f in fs:
                if os.path.splitext(f)[1].lower() not in AUD:
                    continue
                platform, conf, signal = classify(f, dp, cdir, dlsite_rjs, yt_names, openrec_ids,
                                                  sources_platforms, under_dlsite)
                counts[platform] = counts.get(platform, 0) + 1
                by_creator.setdefault(top, []).append({
                    "work": os.path.relpath(os.path.join(dp, f), root),
                    "platform": platform, "confidence": conf, "signal": signal})

    payload = {"updated": __import__("time").strftime("%Y-%m-%d %H:%M"),
               "counts": dict(sorted(counts.items(), key=lambda kv: -kv[1])),
               "by_creator": by_creator}
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "w", encoding="utf-8") as f:
        json.dump(payload, f, ensure_ascii=False, indent=1)
    log(f"=== source inventory -> {out} ===")
    for platform, n in payload["counts"].items():
        log(f"  {platform:12} {n}")
    log(f"  creators scanned: {len(by_creator)}")
    return payload


def selftest():
    d = tempfile.mkdtemp(prefix="srcscan_")
    try:
        root = os.path.join(d, "Asmr")
        c1 = os.path.join(root, "Creator One")
        os.makedirs(c1)
        os.makedirs(os.path.join(c1, "DLsite"))
        os.makedirs(os.path.join(root, "_data", "yt_ingest", "Creator One Ch"))
        os.makedirs(os.path.join(root, "_wiki", "DLsite"))

        # 1. sidecar-labeled file
        open(os.path.join(c1, "clip1.m4a"), "w").close()
        json.dump({"platform": "fanbox"}, open(os.path.join(c1, "clip1.source.json"), "w"))
        # 2. DLsite subfolder
        open(os.path.join(c1, "DLsite", "RJ123456 work.m4a"), "w").close()
        # 3. RJ code in filename, cross-referenced
        open(os.path.join(c1, "RJ999999 loose.m4a"), "w").close()
        json.dump({"products": [{"rj": "RJ999999"}]},
                  open(os.path.join(root, "_wiki", "DLsite", "_products.json"), "w"))
        # 4. twitcasting id suffix
        open(os.path.join(c1, "2026-01-01_title_831651088.m4a"), "w").close()
        # 5. yt_ingest staged basename (simulate promotion: same basename now sits in main folder)
        open(os.path.join(root, "_data", "yt_ingest", "Creator One Ch", "2026-01-02 vid.m4a"), "w").close()
        open(os.path.join(c1, "2026-01-02 vid.m4a"), "w").close()
        # 6. ci-en after-talk marker
        open(os.path.join(c1, "2026-01-03 title アフタートーク.m4a"), "w").close()
        # 6b. FANBOX in filename, no sidecar/_sources.txt (e.g. a manually-placed stream VOD)
        open(os.path.join(c1, "配信 FANBOX限定ASMR配信.m4a"), "w").close()
        # 7. single-source fallback
        open(os.path.join(c1, "_sources.txt"), "w", encoding="utf-8").write("https://ci-en.net/creator/1\n")
        open(os.path.join(c1, "unmarked.m4a"), "w").close()
        # 8. truly unknown (multi-source creator, no signal)
        c2 = os.path.join(root, "Creator Two")
        os.makedirs(c2)
        open(os.path.join(c2, "_sources.txt"), "w", encoding="utf-8").write(
            "https://youtube.com/@x\nhttps://ci-en.net/creator/2\n")
        open(os.path.join(c2, "mystery.m4a"), "w").close()

        payload = scan(root=root, log=lambda *_: None)
        by = {w["work"]: w for rows in payload["by_creator"].values() for w in rows}
        ok = True
        checks = [
            ("Creator One\\clip1.m4a", "fanbox", "high"),
            ("Creator One\\DLsite\\RJ123456 work.m4a", "dlsite", "high"),
            ("Creator One\\RJ999999 loose.m4a", "dlsite", "high"),
            ("Creator One\\2026-01-01_title_831651088.m4a", "twitcasting", "high"),
            ("Creator One\\2026-01-02 vid.m4a", "youtube", "high"),
            ("Creator One\\2026-01-03 title アフタートーク.m4a", "ci-en", "medium"),
            ("Creator One\\配信 FANBOX限定ASMR配信.m4a", "fanbox", "medium"),
            ("Creator One\\unmarked.m4a", "ci-en", "medium"),
            ("Creator Two\\mystery.m4a", "unknown", "low"),
        ]
        for key, exp_platform, exp_conf in checks:
            key = key.replace("\\", os.sep)
            row = by.get(key)
            got = (row or {}).get("platform"), (row or {}).get("confidence")
            match = row is not None and got == (exp_platform, exp_conf)
            ok &= match
            print(f"  {'OK ' if match else 'FAIL'} {key[:50]:50} -> {got}  (expected {(exp_platform, exp_conf)})")
        print(f"selftest: {'PASS' if ok else 'FAIL'}")
        return 0 if ok else 1
    finally:
        shutil.rmtree(d, ignore_errors=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=ROOT)
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args()
    if a.selftest:
        raise SystemExit(selftest())
    scan(a.root)


if __name__ == "__main__":
    main()

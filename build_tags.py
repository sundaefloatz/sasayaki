#!/usr/bin/env python3
"""
build_tags.py -- aggregate a unified #tag layer for the whole collection from every source:
  • acoustic fingerprint tags   (audio_index.json: quiet / wide-binaural / dynamic / …)
  • DLsite official genres        (_wiki/DLsite/_products.json: ASMR / VTuber / 癒し / 耳舐め / …)
  • the local AI's frank per-work tags  (each research note's `## Tags` line)
into _wiki/tags.json, keyed by the SAME work id the library uses, plus global tag counts.
This powers clickable tag chips + tag filtering in the library and a tag index for search.

Privacy: runs LOCALLY. It lifts only the `## Tags` LINE out of each note into the index; the
note prose never leaves this script, and it reports COUNTS only (never prints the tag text).

  python build_tags.py
"""
import os, re, json, time
import paths

ROOT = os.environ.get("SASAYAKI_ROOT", "/media")
WIKI = os.path.join(ROOT, "_wiki")
AIDX = os.path.join(WIKI, "audio_index.json")
PROD = os.path.join(WIKI, "DLsite", "_products.json")
CLEAN = os.path.join(WIKI, "tags_clean.json")   # scrub_tags.py output: raw->canonical map
OUT = os.path.join(WIKI, "tags.json")

STOP = {"asmr", "the", "and", "a", "you", "your", "her", "his", "etc", "-", "–", "n/a", "none"}

# acoustic tags are per-work computed + always meaningful — never dropped by the canonical map
ACOUSTIC = {"very-quiet", "very quiet", "quiet", "moderate", "loud", "spacious",
            "consistent", "dynamic", "mono", "wide-binaural", "wide binaural", "stereo", "binaural"}


# Curated overrides for over-specific tags the scrub LLM keeps mapping to identity across runs
# (it samples inconsistently on rare wordy tags). These win over the scrub map. Keep small; add a
# line only when a wordy over-specific tag persists after a re-scrub. '' drops the tag.
SEED_MAP = {
    "massaging with oil": "oil massage",
    "ice cream licking": "licking",
    "lulling to sleep": "soothing to sleep",
}


def load_canon_map():
    """raw(lower) -> canonical(lower); '' means drop. From scrub_tags.py's tags_clean.json, with the
    curated SEED_MAP layered on top. Absent (never scrubbed) => SEED_MAP only (else identity)."""
    m = {}
    if os.path.exists(CLEAN):
        try:
            m = {str(k).strip().lower(): (str(v).strip().lower() if v else "")
                 for k, v in json.load(open(CLEAN, encoding="utf-8")).get("map", {}).items()}
        except Exception:
            m = {}
    m.update(SEED_MAP)                             # curated overrides win over the LLM map
    return m


def canonicalize(raw_tags, cmap):
    """Map a work's raw tags through the canonical map (drop '' , dedupe, preserve order).
    Acoustic tags always survive. Unmapped tags pass through unchanged (identity). SEED_MAP is
    re-applied to the mapped value too, so it also collapses a *canonical* the scrub produced that
    is itself over-specific (e.g. some raw -> 'massaging with oil' -> 'oil massage')."""
    out = []
    for t in raw_tags:
        if t in ACOUSTIC:
            c = t
        else:
            c = cmap.get(t, t)
            c = SEED_MAP.get(c, c)                 # collapse an over-specific canonical
        if c and c not in out:
            out.append(c)
    return out


def norm(t):
    t = re.sub(r'\s+', ' ', str(t).strip().lower())
    return t.strip(" .,;:#*\"'()[]【】「」")


def note_tags(creator, base):
    """Lift the `## Tags` line out of a work's research note (local; not surfaced to the caller)."""
    p = os.path.join(WIKI, creator, base + ".md")
    if not os.path.exists(p):
        return []
    try:
        txt = open(p, encoding="utf-8").read()
    except Exception:
        return []
    m = re.search(r'##\s*Tags\s*\n+([^\n]+)', txt)
    if not m:
        return []
    return [norm(x) for x in re.split(r'[,、/]', m.group(1)) if norm(x)]


def main():
    # audio_index.json is analyze_audio.py's output. On a fresh CPU-only install it may not exist
    # yet (the app is already browsable via the server's filesystem pending-scan before any builder
    # runs) -- treat that as an empty library and still write a valid empty tags.json, rather than
    # crashing with FileNotFoundError.
    idx = {}
    if os.path.exists(AIDX):
        try:
            idx = json.load(open(AIDX, encoding="utf-8"))
        except (ValueError, OSError):
            idx = {}
    dl = {}
    if os.path.exists(PROD):
        try:                                      # mirror the AIDX guard above: a truncated/corrupt
            with open(PROD, encoding="utf-8") as f:   # _products.json must degrade to {}, not abort the build
                for p in json.load(f).get("products", []):
                    if p.get("title") and p.get("genres"):
                        dl[p["title"]] = [norm(g) for g in p["genres"] if g]
        except (ValueError, OSError):
            dl = {}

    cmap = load_canon_map()
    raw_works, works, src = {}, {}, {"acoustic": 0, "note": 0, "dlsite": 0}
    dlraw = set()          # every raw DLsite-official genre seen — becomes the tier-1 vocabulary (#106)
    for key, v in idx.items():
        segs = key.replace("/", "\\").split("\\")
        creator = v.get("creator") or segs[0]
        base = os.path.splitext(segs[-1])[0]
        tags = set()
        a = [norm(t) for t in (v.get("tags") or [])]
        if a:
            src["acoustic"] += 1
        tags.update(a)
        nt = note_tags(creator, base)
        if nt:
            src["note"] += 1
        tags.update(nt)
        for s in segs:
            if s in dl:
                tags.update(dl[s]); dlraw.update(dl[s]); src["dlsite"] += 1
        raw = sorted(t for t in tags if t and t not in STOP and 1 < len(t) <= 40)
        if not raw:
            continue
        raw_works[key] = raw                       # preserved for scrub_tags.py (idempotent re-scrubs)
        works[key] = canonicalize(raw, cmap)       # served tags: raw mapped -> canonical (drop noise, dedupe)

    # Safety-net floor: after semantic mapping, a few over-specific tags the scrub LLM skipped survive
    # as identity (e.g. "frozen apple candy sucking"). Concise (1-2 word) tags always survive — they read
    # as real browse filters. A WORDY (>=3 word) tag is almost always over-specific, so it must be shared
    # by 3+ works to survive; otherwise it's dropped. Acoustic tags are always kept.
    pc = {}
    for ts in works.values():
        for t in ts:
            pc[t] = pc.get(t, 0) + 1
    def keep(t):
        return t in ACOUSTIC or len(t.split()) < 3 or pc[t] >= 3
    works = {k: [t for t in ts if keep(t)] for k, ts in works.items()}
    works = {k: ts for k, ts in works.items() if ts}

    counts = {}
    for ts in works.values():
        for t in ts:
            counts[t] = counts.get(t, 0) + 1
    top = [t for t, _ in sorted(counts.items(), key=lambda kv: (-kv[1], kv[0]))]
    # tier-1 vocabulary (#106): the DLsite-official genres, post-canonicalization, that actually
    # survived onto works. The UI renders these as the authoritative base tier; everything else
    # (acoustic + local-AI note tags) is the special classification layer.
    dlvocab = sorted(set(canonicalize(sorted(dlraw), cmap)) & set(counts))
    json.dump({"works": works, "raw": raw_works, "counts": counts, "top": top,
               "dlsite": dlvocab,
               "updated": time.strftime("%Y-%m-%d %H:%M")},
              open(OUT, "w", encoding="utf-8"), ensure_ascii=False)
    paths.make_host_writable(OUT)

    # COUNTS ONLY (do not print tag text -- some come from the private notes)
    raw_uniq = len({t for ts in raw_works.values() for t in ts})
    busiest = max(counts.values()) if counts else 0
    multi = sum(1 for c in counts.values() if c >= 3)
    applied = "applied canonical map" if cmap else "NO map yet (raw==canonical; run scrub_tags.py then rebuild)"
    print(f"tagged {len(works)} works · {raw_uniq} raw -> {len(counts)} canonical tags ({applied}) "
          f"(acoustic {src['acoustic']} · note {src['note']} · dlsite {src['dlsite']})")
    print(f"  {multi} tags shared by 3+ works · busiest tag covers {busiest} works · wrote {OUT}")


if __name__ == "__main__":
    main()

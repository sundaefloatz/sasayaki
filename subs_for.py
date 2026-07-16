#!/usr/bin/env python3
r"""
subs_for.py -- resolve a library work id to its subtitle track and emit synced bilingual cues as JSON,
for the dashboard's subtitle player. Resolves via paths.find_sub (mirror-first, 2026-07-03
derived-layer migration -- subs now live in _data/derived/, not as library siblings). For non-DLsite
works, preference is claude.* (hand-authored Claude passes) > rseg.* (machine resegmentation) >
plain ja/en. DLsite official subs are READ ONLY / ground truth here (no claude/rseg override).

  python subs_for.py --id "Sata Nakia 沙汰ナキア\2024-07-14 ....m4a" --json
"""
import os, re, sys, json, argparse

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import paths

ROOT = paths.ROOT
_TS = re.compile(r"(\d\d):(\d\d):(\d\d)[,.](\d\d\d)\s*-->\s*(\d\d):(\d\d):(\d\d)[,.](\d\d\d)")


def secs(h, m, s, ms):
    return int(h) * 3600 + int(m) * 60 + int(s) + int(ms) / 1000.0


def parse_srt(path):
    try:
        raw = open(path, encoding="utf-8", errors="ignore").read()
    except Exception:
        return []
    out, t0, t1, buf = [], None, None, []
    for ln in raw.splitlines():
        m = _TS.search(ln)
        if m:
            if t0 is not None and buf:
                out.append((t0, t1, " ".join(buf).strip()))
            g = m.groups()
            t0, t1, buf = secs(*g[:4]), secs(*g[4:]), []
        elif ln.strip().isdigit() and len(ln.strip()) <= 6:
            continue
        elif ln.strip():
            buf.append(ln.strip())
    if t0 is not None and buf:
        out.append((t0, t1, " ".join(buf).strip()))
    return out


def find_sub(audio, ext):
    """Resolve subtitle path via paths.find_sub (mirror-first, then legacy sibling). Preference:
    official.* (ground truth aligned from the shipped 台本, applies everywhere) > claude.* (hand
    Claude passes, non-DLsite) > rseg.* (machine resegmentation, non-DLsite) > plain ASR. Shipped
    DLsite .srt sidecars are still served untouched by the claude/rseg carve-out. `ext` is the old
    '.ja.srt'-style suffix; paths wants the bare 'ja.srt'."""
    kind = ext.lstrip(".")
    # official.* is the very top tier and applies EVERYWHERE, DLsite included: it is a ground-truth
    # subtitle built by align_official.py from the writer's own shipped 台本 (which has no timing) laid
    # onto our ASR cue timeline. It is derived-and-correct, not an override of a shipped .srt, so the
    # DLsite read-only rule below doesn't apply to it.
    official = paths.find_sub(audio, "official." + kind)
    if official:
        return official
    if "DLsite" not in audio:
        claude = paths.find_sub(audio, "claude." + kind)
        if claude:
            return claude
        rseg = paths.find_sub(audio, "rseg." + kind)
        if rseg:
            return rseg
    return paths.find_sub(audio, kind)


def resolve(work_id):
    # ids come from audio_index.json, built on Windows -> backslash-separated. On Linux (the Zettlab
    # container) os.sep is "/", so replacing ONLY "/" left every backslash literal -- the whole id
    # became one bogus filename and every /subs lookup silently resolved to nothing. Normalize BOTH
    # separators to os.sep (matches the same fix already applied to Resolve-AudioPath in the PS server).
    rel = work_id.replace("\\", "/").replace("/", os.sep).lstrip(os.sep)
    full = os.path.normpath(os.path.join(ROOT, rel))
    if os.path.commonpath([os.path.normcase(full), os.path.normcase(ROOT)]) != os.path.normcase(ROOT):
        return None                                    # sandbox: stay under the archive root
    return full


def merge(ja, en, ko=None):
    """JA/EN are cue-aligned by our pipeline. Zip by index when counts match; else key EN by rounded t0.
    KO (when present) is a genuinely separate track -- e.g. a creator's own real, independently-timed
    subtitle upload, not something our pipeline generated in lockstep with ja/en -- so it's never
    index-zipped, always merged onto the ja/en timeline (or its own, if ja/en are absent) by rounded t0."""
    cues = []
    if ja and en and abs(len(ja) - len(en)) <= max(2, len(ja) // 20):
        n = max(len(ja), len(en))
        for i in range(n):
            jt = ja[i] if i < len(ja) else None
            et = en[i] if i < len(en) else None
            t0 = (jt or et)[0]; t1 = (jt or et)[1]
            cues.append({"t0": round(t0, 2), "t1": round(t1, 2),
                         "ja": jt[2] if jt else "", "en": et[2] if et else "", "ko": ""})
    else:
        prim, lang = (ja, "ja") if ja else (en, "en") if en else (None, None)
        if prim:
            other = en if lang == "ja" else ja
            obyt = {round(c[0]): c[2] for c in (other or [])}
            for (t0, t1, tx) in prim:
                row = {"t0": round(t0, 2), "t1": round(t1, 2), "ja": "", "en": "", "ko": ""}
                row["ja" if lang == "ja" else "en"] = tx
                o = obyt.get(round(t0))
                if o:
                    row["en" if lang == "ja" else "ja"] = o
                cues.append(row)
    if ko:
        kbyt = {round(c[0]): c[2] for c in ko}
        for row in cues:
            o = kbyt.get(row["t0"])
            if o:
                row["ko"] = o
        if not cues:                      # ko-only track (no ja/en at all)
            for (t0, t1, tx) in ko:
                cues.append({"t0": round(t0, 2), "t1": round(t1, 2), "ja": "", "en": "", "ko": tx})
    return cues


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--id", required=True)
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args()
    audio = resolve(a.id)
    if not audio:
        print(json.dumps({"cues": [], "lang": None})); return
    ja = parse_srt(find_sub(audio, ".ja.srt") or "")
    en = parse_srt(find_sub(audio, ".en.srt") or "")
    ko = parse_srt(find_sub(audio, ".ko.srt") or "")
    cues = merge(ja, en, ko)
    base = "both" if (ja and en) else ("en" if en else ("ja" if ja else None))
    lang = (base + "+ko") if (base and ko) else (base or ("ko" if ko else None))
    print(json.dumps({"lang": lang, "n": len(cues), "cues": cues}, ensure_ascii=False))


if __name__ == "__main__":
    main()

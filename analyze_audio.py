#!/usr/bin/env python3
"""
analyze_audio.py -- acoustic feature index for the ASMR archive (ffmpeg-only, no extra deps).

Per work it measures the things that actually matter for ASMR: loudness (RMS dB), dynamic
range, silence ratio, L/R balance, and STEREO WIDTH (how binaural / ear-to-ear it is), then
derives friendly tags. Writes <Asmr>\\_wiki\\audio_index.json. Resumable: skips files whose
size+mtime are unchanged, so re-runs are cheap.

  python analyze_audio.py --root /media                    # whole archive (background-friendly)
  python analyze_audio.py --root /media --creators "Some Creator"
  python analyze_audio.py --path "<one audio file>"

Analyzes a representative ~90s sample from the middle of each file (full-file scan of a
600-work archive would take hours; the sample is plenty for loudness/width/silence).
"""
import os, re, json, glob, subprocess, argparse, time

SUB = os.path.dirname(os.path.abspath(__file__))
ROOT_DEFAULT = os.environ.get("SASAYAKI_ROOT", "/media")
OUT = os.path.join(os.path.dirname(SUB), "_wiki", "audio_index.json")
AUD = (".m4a", ".mp3", ".wav", ".flac", ".opus", ".ogg", ".aac", ".wma")
VID = (".mp4", ".mkv", ".webm", ".mov", ".m4v")
SAMPLE = 90.0
_RMS = re.compile(r"RMS level dB:\s*(-?\d+\.?\d*|-?inf)")
_PEAK = re.compile(r"Peak level dB:\s*(-?\d+\.?\d*|-?inf)")
_DR = re.compile(r"Dynamic range:\s*(\d+\.?\d*)")
_SILDUR = re.compile(r"silence_duration:\s*([\d.]+)")


def _f(v):
    try:
        return float(v)
    except Exception:
        return None


def ffprobe(path):
    try:
        out = subprocess.run(
            ["ffprobe", "-v", "error", "-select_streams", "a:0",
             "-show_entries", "format=duration:stream=channels,sample_rate",
             "-of", "json", path],
            capture_output=True, text=True, timeout=30).stdout
        j = json.loads(out)
        dur = _f(j.get("format", {}).get("duration"))
        st = (j.get("streams") or [{}])[0]
        return dur, int(st.get("channels") or 0), int(st.get("sample_rate") or 0)
    except Exception:
        return None, 0, 0


def _astats(path, ss, dur, af):
    """Run an ffmpeg astats/silencedetect chain on a sample; return the stderr log text."""
    try:
        r = subprocess.run(
            ["ffmpeg", "-hide_banner", "-nostats", "-ss", f"{ss:.1f}", "-t", f"{dur:.1f}",
             "-i", path, "-map", "0:a:0", "-af", af, "-f", "null", "-"],
            capture_output=True, text=True, timeout=180)
        return r.stderr or ""
    except Exception:
        return ""


def _parse_channels(log):
    """Pull per-section RMS/Peak/DynamicRange out of an astats stderr block."""
    cur, sec = None, {}
    for line in log.splitlines():
        m = re.search(r"(Channel: \d+|Overall)\s*$", line)
        if m:
            cur = m.group(1)
            sec.setdefault(cur, {})
            continue
        if cur:
            for rx, k in ((_RMS, "rms"), (_PEAK, "peak"), (_DR, "dr")):
                mm = rx.search(line)
                if mm and k not in sec[cur]:
                    sec[cur][k] = _f(mm.group(1))
    return sec


def analyze(path):
    dur, ch, sr = ffprobe(path)
    if not dur:
        return None
    ss = max(0.0, dur / 2 - SAMPLE / 2)
    seg = min(SAMPLE, dur)
    log = _astats(path, ss, seg, "astats=metadata=0:reset=0,silencedetect=noise=-50dB:d=0.4")
    sec = _parse_channels(log)
    overall = sec.get("Overall", {})
    sil = sum(_f(x) or 0 for x in _SILDUR.findall(log))
    feats = {
        "durationSec": round(dur, 1), "channels": ch, "sampleRate": sr,
        "rmsDb": overall.get("rms"), "peakDb": overall.get("peak"),
        "dynamicRangeDb": overall.get("dr"),
        "silenceRatio": round(min(1.0, sil / seg), 3) if seg else None,
    }
    chans = sorted(k for k in sec if k.startswith("Channel"))
    if ch >= 2 and len(chans) >= 2:
        lr = [sec[chans[0]].get("rms"), sec[chans[1]].get("rms")]
        if None not in lr:
            feats["lrBalanceDb"] = round(abs(lr[0] - lr[1]), 2)
        side = _parse_channels(_astats(path, ss, seg, "pan=mono|c0=0.5*c0-0.5*c1,astats=metadata=0:reset=0"))
        side_rms = side.get("Overall", {}).get("rms")
        if side_rms is not None and overall.get("rms") is not None:
            feats["stereoWidthDb"] = round(side_rms - overall["rms"], 2)   # 0=mono-ish, higher=wider/binaural
    feats["tags"] = _tags(feats)
    return feats


def _tags(f):
    t = []
    r = f.get("rmsDb")
    if r is not None:
        t.append("very-quiet" if r < -32 else "quiet" if r < -25 else "moderate" if r < -18 else "loud")
    s = f.get("silenceRatio")
    if s is not None and s > 0.25:
        t.append("spacious")          # lots of quiet space -> sleep-friendly
    dr = f.get("dynamicRangeDb")
    if dr is not None:
        t.append("consistent" if dr < 14 else "dynamic")
    w = f.get("stereoWidthDb")
    if f.get("channels", 0) < 2:
        t.append("mono")
    elif w is not None:
        t.append("wide-binaural" if w > -9 else "stereo")
    return t


def targets(root, creators, path):
    if path:
        return [path]
    out = []
    cs = creators or [d for d in os.listdir(root)
                      if os.path.isdir(os.path.join(root, d)) and not d.startswith(("_", "."))]
    for c in cs:
        cdir = os.path.join(root, c)
        if not os.path.isdir(cdir):
            continue
        seen = set()
        for dp, dirs, files in os.walk(cdir):                 # recurse: works now live in per-work subfolders
            dirs[:] = [d for d in dirs if not d.startswith(("_", "."))]   # skip covers/_aw_benchmark/_ab_* etc.
            for f in sorted(files):
                ext = os.path.splitext(f)[1].lower()
                if ext in AUD + VID and ".subbed." not in f.lower():
                    p = os.path.join(dp, f)
                    b = os.path.splitext(os.path.relpath(p, cdir))[0]
                    if b in seen:
                        continue
                    seen.add(b)
                    out.append(p)
    return out


def fix_creators(root):
    """One-shot index repair: recompute every entry's `creator` from its key's top-level path
    component (the pre-2026-07-02 code stamped the immediate parent folder, which is the WORK
    folder in the per-work layout -- 217 entries carried bogus creators). Also drops entries
    whose file no longer exists on disk. Derived-artifact-only; no audio re-analysis."""
    if not os.path.exists(OUT):
        print("no index to fix"); return
    idx = json.load(open(OUT, encoding="utf-8"))
    fixed = dropped = 0
    for key in list(idx.keys()):
        if not os.path.exists(os.path.join(root, key)):
            del idx[key]; dropped += 1
            continue
        right = key.split(os.sep)[0].split("/")[0]
        if idx[key].get("creator") != right:
            idx[key]["creator"] = right; fixed += 1
    json.dump(idx, open(OUT, "w", encoding="utf-8"), ensure_ascii=False)
    print(f"fix-creators: {fixed} creator fields corrected, {dropped} stale entries dropped, "
          f"{len(idx)} entries remain -> {OUT}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=ROOT_DEFAULT)
    ap.add_argument("--creators", default="", help="| separated; default = all")
    ap.add_argument("--path", default="")
    ap.add_argument("--fix-creators", action="store_true",
                    help="repair creator fields + drop stale entries in the existing index, then exit")
    a = ap.parse_args()
    if a.fix_creators:
        fix_creators(a.root)
        return
    creators = [c.strip() for c in a.creators.split("|") if c.strip()]
    paths = targets(a.root, creators, a.path)

    idx = {}
    if os.path.exists(OUT):
        try:
            idx = json.load(open(OUT, encoding="utf-8"))
        except Exception:
            idx = {}

    done = skipped = 0
    t0 = time.time()
    for p in paths:
        try:
            st = os.stat(p)
            sig = f"{st.st_size}:{int(st.st_mtime)}"
        except Exception:
            continue
        key = os.path.relpath(p, a.root)
        if idx.get(key, {}).get("_sig") == sig:
            skipped += 1
            continue
        feats = analyze(p)
        if feats:
            feats["_sig"] = sig
            # creator = TOP-LEVEL folder under root, not the immediate parent: works now live in
            # per-work subfolders, where dirname(p) is the WORK folder (this bug stamped 217 index
            # entries with their work-folder name as "creator", which fed bogus creators to the
            # dashboard's Get-Library; fixed 2026-07-02, index repaired via --fix-creators).
            feats["creator"] = os.path.relpath(p, a.root).split(os.sep)[0]
            idx[key] = feats
            done += 1
            print(f"  {key[:60]:60} {','.join(feats['tags'])}", flush=True)
            if done % 20 == 0:                      # checkpoint so a long run is crash-safe
                json.dump(idx, open(OUT, "w", encoding="utf-8"), ensure_ascii=False)
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    json.dump(idx, open(OUT, "w", encoding="utf-8"), ensure_ascii=False)
    print(f"\nanalyzed {done}, skipped {skipped} (cached), {len(idx)} total in index "
          f"({time.time()-t0:.0f}s) -> {OUT}", flush=True)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
r"""
paths.py -- the single source of truth for WHERE every artifact lives.

The keystone of the app-data split: original creator folders stay (near) audio-only;
ALL derived artifacts live under one app-data root, mirrored per work. Everything
should import this instead of hardcoding ROOT or globbing **/*.ja.srt.

  work_key(audio)         -> "Creator/stem"   (stable id; matches quality.json / radar.json keys)
  art(audio, ext, make=)  -> <DATA>/derived/Creator/stem/<ext>     (where to WRITE an artifact)
  find_sub(audio, kind)   -> mirror path if present, else legacy sibling next to audio, else None
  iter_works(root=ROOT)   -> yield every audio file (audio-first discovery; skips junk dirs)
  work_count(root=ROOT)   -> count of iter_works (for the >5%-drop migration guard)

Config via env:
  SASAYAKI_ROOT  -> library root   (default: /media -- the container's library mount point)
  SASAYAKI_DATA  -> app-data root  (default: <ROOT>/_data)

Read-only sanity report:  python paths.py
"""
import os

ROOT = os.environ.get("SASAYAKI_ROOT", "/media")
DATA = os.environ.get("SASAYAKI_DATA", os.path.join(ROOT, "_data"))
DERIVED = os.path.join(DATA, "derived")

AUD = (".m4a", ".mp3", ".wav", ".flac", ".opus", ".ogg", ".mp4", ".mkv", ".webm")
# non-creator dirs at the library root (mirrors quality_scan.py SKIP); plus any _-prefixed / dot dir
SKIP = {"_data", "_wiki", "Sasayaki", "_secrets", "_remote", "covers", "models",
        "DLsite", "_font_backup", "fonts", "_backups", "_jobs", "_test"}

# ASR source-quality preference (lower = better source to transcribe from). Uncompressed first --
# the same recording shipped as both .wav and .mp3 (DLsite standard packaging) should be SCANNED
# from the lossless copy, and its lossy twin skipped so we don't burn GPU making a redundant sub.
_FMT_RANK = {".wav": 0, ".flac": 0, ".m4a": 1, ".aac": 1, ".mp4": 1, ".mkv": 1,
             ".webm": 2, ".ogg": 2, ".opus": 2, ".mp3": 3}


def fmt_rank(path):
    """Transcription-source preference for a path's container: lossless (wav/flac) < m4a/mp4 < mp3.
    Use to pick which of several identical-recording containers to actually feed the ASR."""
    return _FMT_RANK.get(os.path.splitext(path)[1].lower(), 5)


def prefer_source(paths_list):
    """Given several files that are the SAME recording in different containers, return the one best
    to transcribe (lossless preferred); ties broken deterministically by name so runs are stable."""
    return min(paths_list, key=lambda p: (fmt_rank(p), p))


def _is_skip_root_dir(name):
    return name in SKIP or name.startswith((".", "_"))


def make_host_writable(path):
    """Call right after writing a shared _data/_wiki state file (audio_index.json, tags.json,
    doctor_report.json, ...). The Docker image runs as root with no USER directive, so a file it
    writes lands root-owned 0600 -- a non-root host process (a sync tool, a backup job, the user's
    own shell) can't even OPEN it to read/hash it, let alone overwrite it. That's silent: no error
    surfaces anywhere but the sync tool's own log, and a receive-only replica just drifts forever
    (confirmed 2026-07-30: a NAS's _wiki/audio_index.json sat stale for a week because Syncthing,
    running as an unprivileged user, could not touch the container's root-owned copy). These files
    are non-secret app state inside a LAN-only library mount, never credentials, so world-read/write
    is a fair trade for "the mirror stays a mirror." No-op on Windows; best-effort everywhere (a
    permission quirk here should never fail a pipeline run)."""
    if os.name != "posix":
        return
    try:
        os.chmod(path, 0o666)
    except OSError:
        pass


def creator_of(audio):
    """Top-level folder under ROOT == the creator."""
    return os.path.relpath(audio, ROOT).split(os.sep, 1)[0]


def stem_of(audio):
    return os.path.splitext(os.path.basename(audio))[0]


def work_key(audio):
    """Stable per-work id 'Creator/stem' -- matches the keys used in quality.json / radar.json.
    (Note: keys on creator+stem, so two same-named files in different subfolders of one creator
    would collide -- same assumption the existing index already makes.)"""
    return f"{creator_of(audio)}/{stem_of(audio)}"


def _win_safe(component):
    """A single path component, safe to create as a Windows dir/file name. Windows silently
    strips TRAILING SPACES AND DOTS from path components (CreateDirectory/CreateFile disagree
    on when, which is how '...お願いがあるんだけど...' -- a DLsite title ending in an ellipsis --
    broke the migration: os.makedirs() normalized it away, then open() on the same nominal path
    raised FileNotFoundError). Strip both so the path we compute is the path that actually exists."""
    return component.rstrip(" .")


def art(audio, ext, make=False):
    """Path for a derived artifact in the app-data mirror.
    `ext` is the bare artifact name, e.g. 'ja.srt', 'en.srt', 'rseg.ja.srt', 'quality.json'.
    Pass make=True to create the per-work folder first (for writers).

    Two keying schemes (2026-07-03, derived-layer design):
    - Community works: <DERIVED>/Creator/stem/<ext> -- creator+stem IS the work_key identity
      used across every JSON (audit, quality, markers); unchanged.
    - DLsite: <DERIVED>/DLsite/Audio/circle/product/variant/stem/<ext> -- full relpath keying,
      because DLsite track stems ('Track01') collide across every product, and its shipped
      structure is preserved exactly (the mirror mirrors its real tree shape)."""
    if creator_of(audio) == "DLsite":
        rel_dir = os.path.relpath(os.path.dirname(audio), ROOT)
        parts = [_win_safe(p) for p in rel_dir.split(os.sep)] + [_win_safe(stem_of(audio))]
        d = os.path.join(DERIVED, *parts)
    else:
        d = os.path.join(DERIVED, creator_of(audio), _win_safe(stem_of(audio)))
    if make:
        os.makedirs(d, exist_ok=True)
    return os.path.join(d, ext)


def legacy_sibling(audio, kind):
    """The OLD location: <stem>.<kind> right next to the audio (e.g. X.ja.srt)."""
    return os.path.join(os.path.dirname(audio), stem_of(audio) + "." + kind)


# Ordered longest-first so the greedy match picks the most specific suffix.
_SIDECAR_SFXS = (
    ".rseg.ja.srt", ".rseg.en.srt", ".rseg.ja.vtt", ".rseg.en.vtt",
    ".ja.srt", ".en.srt", ".zh.srt", ".ko.srt", ".ja.vtt", ".en.vtt", ".zh.vtt", ".ko.vtt",
    ".quality.json",
)


def sidecar_art(sidecar, out_ext, make=False):
    """Mirror path for a new artifact, given an existing sidecar path (not the audio file).

    Two modes:
    - *Legacy sibling* (sidecar sits next to the audio under ROOT): strips the known
      language suffix to recover the work stem, then routes to DERIVED/creator/stem/out_ext.
    - *Already in mirror* (sidecar is already under DERIVED): output lands in the **same
      per-work folder** so derived-of-derived files (e.g. rseg.ja.srt → rseg.en.srt) stay
      together.  Pass out_ext with the right prefix (e.g. 'rseg.en.srt').

    Pass make=True to create the per-work folder (for writers).
    """
    abs_sid = os.path.abspath(sidecar)
    if os.path.normcase(abs_sid).startswith(os.path.normcase(DERIVED) + os.sep):
        d = os.path.dirname(abs_sid)
    else:
        bn = os.path.basename(abs_sid)
        stem = None
        for sfx in _SIDECAR_SFXS:
            if bn.lower().endswith(sfx.lower()):
                stem = bn[: -len(sfx)]
                break
        if stem is None:
            stem = os.path.splitext(bn)[0]
        stem = _win_safe(stem)                      # match art(): no trailing-space/dot dir names on Windows
        try:
            rel = os.path.relpath(os.path.dirname(abs_sid), ROOT)
            creator = rel.split(os.sep)[0]
        except ValueError:
            creator = os.path.basename(os.path.dirname(abs_sid))
        d = os.path.join(DERIVED, creator, stem)
    if make:
        os.makedirs(d, exist_ok=True)
    return os.path.join(d, out_ext)


def find_sub(audio, kind):
    """Resolve an existing sidecar mirror-first, then legacy sibling; None if neither exists.
    `kind` e.g. 'ja.srt', 'en.srt', 'rseg.ja.srt', 'txt'."""
    m = art(audio, kind)
    if os.path.exists(m):
        return m
    leg = legacy_sibling(audio, kind)
    if os.path.exists(leg):
        return leg
    return None


def iter_works(root=None):
    """Audio-first discovery: yield every real audio file under the library, skipping
    non-creator dirs (at root), _aw_benchmark (anywhere), and *.subbed.* renders.
    Replaces the scattered glob(**/*.ja.srt) scans across the codebase."""
    root = root or ROOT
    for dp, dns, fs in os.walk(root):
        if dp == root:
            dns[:] = [d for d in dns if not _is_skip_root_dir(d)]
        dns[:] = [d for d in dns if d != "_aw_benchmark"]
        for f in fs:
            if os.path.splitext(f)[1].lower() in AUD and ".subbed." not in f:
                yield os.path.join(dp, f)


def work_count(root=None):
    return sum(1 for _ in iter_works(root))


def _report():
    print(f"SASAYAKI_ROOT = {ROOT}")
    print(f"SASAYAKI_DATA = {DATA}")
    print(f"DERIVED       = {DERIVED}")
    print(f"root exists   : {os.path.isdir(ROOT)}")
    works = list(iter_works())
    print(f"\nworks discovered: {len(works)}")
    mir = leg = none = 0
    sample = []
    for a in works:
        p = find_sub(a, "ja.srt")
        if p is None:
            none += 1
        elif p.startswith(DERIVED):
            mir += 1
        else:
            leg += 1
        if p and len(sample) < 3:
            sample.append(a)
    print(f"ja.srt resolved -> mirror:{mir}  legacy-sibling:{leg}  missing:{none}")
    if sample:
        print("\nsample (work_key | current read | future write):")
        for a in sample:
            print(f"  {work_key(a)}")
            print(f"     read : {find_sub(a, 'ja.srt')}")
            print(f"     write: {art(a, 'ja.srt')}")


if __name__ == "__main__":
    _report()

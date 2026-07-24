# Changelog

This project doesn't have numbered releases yet — it's one continuously-evolving v0.1 alpha,
built solo in about a month of "what's annoying me this week" sessions (see the README's
[how this was built](README.md#how-this-was-built)). This changelog exists because that pace
means even I lose track of what shipped when — it's grouped by rough date, newest first, and
covers only what's actually in **this public CPU-only core**. The private GPU comprehension
worker (ASR, translation, trigger detection, the research wiki, AI chat) has its own history
that isn't tracked here, since it isn't shipped in this repo.

## 2026-07-20 — the persistent player

- **`/app`: a persistent player shell.** Previously the player lived on `library.html` alone —
  any real navigation killed it. `/app` is a thin shell around a full-viewport iframe: the
  player survives clicking anywhere in the app.
- **Real video playback.** Works classified `audio` vs `video` by extension; `.mp4`/`.mkv`/`.webm`
  now actually show their picture in the full player (previously `.mkv`/`.webm` likely didn't
  play at all — a real pre-existing content-type bug, also fixed).
- Shuffle added to the mini player (previously full-player only).
- `analyze_audio.py` / `source_scan.py` / `build_tags.py` / `process_ledger.py` fixed to respect
  `SASAYAKI_ROOT` and to not crash on a brand-new install with an empty `_wiki/`.
- `smoke_test.py` — a stdlib-only acceptance checklist for a running instance.

## 2026-07-16 – 2026-07-17 — full player transport + library management

- 15s rewind/forward, shuffle, repeat (off/all/one), keyboard shortcuts (J/L/S/R + space/arrows).
- Media Session API — OS-level media keys, lock-screen controls.
- Trigger/timeline seek markers and per-card trigger chips (renders `triggers.json` when the GPU
  worker has produced it — the CPU core never generates it, just displays it).
- Library management round-out: re-run pipeline from a card's Manage bar, per-work title
  override, folder/creator grouping view.

## 2026-07-09 – 2026-07-15 — browsing, DLsite, tags, sandbox

- Infinite scroll (replacing fixed pagination), sort pills, source-filter chips, search operators
  (`creator:` / `tag:` / `source:`).
- Two-tier tag UI: DLsite-official genres as the base tier, everything else as a special layer.
- DLsite integration: product metadata join, lossy/lossless variant dedup into one logical track,
  a product-preview modal on the wiki.
- Full realm split — Core vs Sandbox — with sandbox-only multi-site ingest surfacing
  (YouTube/ci-en/twitcasting/openrec/fanbox) and a promote-to-core action.
- Site-wide light/dark theme toggle; editorial JP type pass (Shippori Mincho + Zen Kaku Gothic).
- `/settings` page for server-side pipeline knobs.
- Live-merge of not-yet-indexed files as "pending" cards, so a freshly-dropped file is browsable
  immediately instead of waiting for the next index build.

## 2026-07-08 — the library, for real

- The first real library browser: card grid, volume control with persisted mute, the DLsite
  content-rating filter pass, search flags.

## 2026-06-24 — project start

- Sasayaki begins as a fork of a personal ASR/subtitling pipeline. The earliest commits are almost
  entirely the private GPU-side comprehension work — the CPU-only core in this repo didn't exist
  as a distinct, shippable thing until later staging carved it out.

---

**Known not-yet-implemented, tracked honestly in the pinned "known gaps" issue:** EQ presets and
a sleep timer exist in the full-player markup but aren't wired up; the track drawer and the
subtitle drawer haven't been ported into the `/app` shell yet (both work fine on `library.html`
directly).

<div align="center">

# 囁き · Sasayaki — CPU-only core

**a self-hosted browser/player for an ASMR library you already have, with a comprehension
pipeline that grows into it**

`browse → play → search → tag → organize` · runs on a Raspberry Pi · zero GPU required

</div>

---

## what this repo is

This is the **Tier 0 core**: the practical, Jellyfin-equivalent viewer. Point it at a folder of
audio (or video) you already own, `docker compose up`, and get a real library UI — search, tags,
per-creator pages, DLsite metadata, realms, a persistent player that survives page navigation,
bilingual subtitle playback and trigger/timeline markers if that data already exists. **No GPU, no
models, no scrapers, no network calls.**

**No authentication.** This is a personal media server, not a multi-tenant app — anyone who can
reach the port can browse and play. Run it on your LAN only, or put it behind your own
reverse-proxy/VPN if you want to reach it from outside your network.

The full Sasayaki project also includes a **GPU comprehension pipeline** — ASR tuned for ASMR
(anime-whisper, a Whisper fine-tune that doesn't hallucinate on breathy non-verbal audio), local-LLM
JA→EN translation with onomatopoeia rendered as stage directions, a self-grading reviewer, and a
research agent that builds a local wiki per creator. That pipeline is a **separate, optional worker
package** — it writes its output into this same library's `_data/derived/` folder, so the core here
just picks it up. Nothing about running the core requires the worker to exist.

> Why a separate ASR fine-tune matters: vanilla Whisper hears breathy, non-verbal ASMR — kisses,
> ear-licking, soft breaths — finds no dictionary words, and hallucinates *"thanks for watching"*
> on a loop. That's the actual problem this project set out to solve; this core repo is the part
> of the result anyone can run today, on a CPU, without any of that machinery installed.

## what works with no GPU vs. what needs the worker

| Feature | Core (this repo, CPU) | Needs the GPU worker |
|---|:---:|:---:|
| Browse / play your library (audio + video) | ✅ | |
| Persistent player (`/app` shell — survives page navigation) | ✅ | |
| Full player transport — shuffle, repeat, 15s skip, keyboard shortcuts, OS media controls | ✅ | |
| Tag / genre filtering | ✅ | |
| DLsite metadata display | ✅ | |
| Sandbox / core realm split, hide/unhide | ✅ | |
| Library management — re-run pipeline per work, title overrides, folder view | ✅ | |
| Delete/restore (moves the audio file) | ⚙️ *(opt-in — needs a `:rw` library mount, see INSTALL.md)* | |
| Subtitle playback (bilingual drawer) | ✅ *(if `.ja.srt`/`.en.srt` already exist)* | |
| Trigger/timeline markers | ✅ *(if `triggers.json` already exists)* | |
| Transcription (ASR) | | 🔧 |
| JA→EN translation | | 🔧 |
| Semantic "vibe" / moment search | | 🔧 |
| Trigger detection (CLAP sound-event classifier) | | 🔧 |
| Creator wiki + research agent | | 🔧 |
| AI chat console | | 🔧 |

Every GPU-only feature **degrades gracefully** — the route returns an empty result instead of
erroring, so the core UI never crashes because the worker isn't running.

## quickstart

See [INSTALL.md](INSTALL.md). Short version: this folder needs to sit inside your library as a
subfolder named `Sasayaki`, then `docker compose up -d --build`.

## stack

A single PowerShell 7 `HttpListener` server (`Show-SubtitlerLog.ps1 -Serve`) + static HTML/JS pages
+ six **stdlib-only** Python scripts (no pip installs, no ML libraries): `subs_for.py` (subtitle
serving), `paths.py` (path resolution), and four index builders — `analyze_audio.py` (acoustic
index), `build_tags.py` (tags), `process_ledger.py` (processing status), `source_scan.py` (source
badges). `ffmpeg`/`ffprobe` for thumbnails, audio probing, and the acoustic index. That's the whole
runtime dependency list — no GPU, no models, no network. A stdlib-only `smoke_test.py` verifies a
running instance against the install checklist.

## license

See [LICENSE](LICENSE).

---

<div align="center"><sub>囁き — built mostly by talking to it.</sub></div>

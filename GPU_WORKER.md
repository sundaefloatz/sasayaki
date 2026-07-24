# The GPU comprehension worker — a blueprint

This repo is the Tier-0 CPU-only core: it browses, plays, and displays whatever's already in
your library. It does not transcribe, translate, or detect anything — that's a separate,
**not-yet-published** GPU worker. This doc describes what that worker does and how it's meant
to attach, for anyone curious about the full picture or interested in building something
compatible. It's a description of working code I run against my own library, not a spec for
code that exists in this repo.

(This intentionally does not cover acquisition/scraping. That layer stays private — this repo,
and this blueprint, are about *understanding* a library you already have, not finding one.)

## What it produces

- **ASR transcript** (`ja.srt`) — via [anime-whisper](https://huggingface.co/litagin/anime-whisper),
  a Whisper fine-tune trained to handle breathy, non-verbal ASMR audio. Vanilla Whisper finds no
  dictionary words in that kind of audio and hallucinates *"thanks for watching"* on a loop —
  that failure mode is the actual reason this whole project exists.
- **JA→EN translation** (`rseg.en.srt`, with a hand-revised `claude.en.srt` tier above it) —
  local-LLM translation with onomatopoeia rendered as italicized stage directions (*soft breath*,
  *ear licking*) rather than dropped or transliterated.
- **Self-grading + review** — a coverage/CER pass plus an LLM-as-judge second opinion, feeding a
  ship/revise/redo loop so bad transcripts get automatically re-run with different settings
  instead of silently shipping.
- **Trigger/sound-event detection** (`triggers.json`) — a CLAP-based classifier tagging timestamp
  ranges with sound-event classes (whispering, ear-cleaning, breathing, tapping, liquid, …) and a
  confidence score. This is what powers the core's timeline seek-markers and trigger chips —
  the core only ever *renders* this file, never produces it.
- **Per-creator research wiki** — a local LLM reads a creator's transcripts and writes profile /
  overview / per-work notes, plus builds semantic-search embeddings over the whole corpus.
  100% local; that research never leaves the box.

## How it attaches to this core

Everything above writes into the **same library**, under `_data/derived/<Creator>/<work>/` (the
subtitle tiers and `triggers.json`) and `_wiki/<Creator>/*.md` + `_wiki/wiki.db` (the research
wiki and its embeddings). The core in this repo never writes any of it — only reads. Practically:

- Point the core at a library where the worker has already run → subtitles, trigger markers, and
  wiki pages show up with zero core-side changes.
- Point it at a bare library → those same routes degrade to an empty result instead of erroring
  (see the feature table in [README.md](README.md)) — a page just looks sparse until the worker
  (or a compatible substitute) has run.

That contract is deliberate: the core doesn't need to know or care that the worker exists.

## Design shape (this part is genuinely subject to change)

- **Two roles, split like Immich's `server`/`machine-learning`:** a light always-on core (this
  repo — could live on a NAS) and a GPU worker that can run on a completely different machine,
  pointed at the same library over a network mount. Nothing here requires them to be co-located.
- **Hot-plug over a job queue + heartbeat** — the intent is that plugging a GPU box in lets it
  pick up queued work, and unplugging it re-queues whatever was in flight, rather than needing a
  stable always-on GPU node.
- **LLM serving via Ollama** (a fast non-reasoning local model), **ASR via a small HTTP wrapper**
  around a CT2/faster-whisper runtime — both swappable, neither cloud.

## Status

Not packaged, not installable, not published. Today it's a set of scripts I run by hand against
my own library, not a service someone else could `docker compose up`. Turning it into that is
real future work, tracked (honestly, as "not happening soon") in the pinned known-gaps issue.

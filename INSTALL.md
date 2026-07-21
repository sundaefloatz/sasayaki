# Installing Sasayaki (CPU-only core)

## Requirements

- Docker + Docker Compose
- A folder of audio files you already own, organized as `<library>/<creator>/<files>`
- That's it — no GPU, no Python packages to install locally, no accounts.

## 1. Place this folder inside your library

The app resolves its own library root as **its parent folder**, so this repo must live as a
subfolder of your library named exactly `Sasayaki`:

```
<your-library>/
├── CreatorA/
│   ├── track1.mp3
│   └── ...
├── CreatorB/
│   └── ...
└── Sasayaki/              <- this repo, cloned/copied here
    ├── docker-compose.yml
    ├── Show-SubtitlerLog.ps1
    └── ...
```

If you'd rather not nest it, clone this repo anywhere and instead **bind-mount it** at
`/media/Sasayaki` inside the container — edit the second line under `volumes:` in
`docker-compose.yml` to point at wherever you cloned it, e.g.:

```yaml
    volumes:
      - "${SASAYAKI_LIBRARY}:/media:ro"
      - "/path/to/wherever/you/cloned/this:/media/Sasayaki:rw"
```

## 1b. Create two empty folders next to it

```
<your-library>/
├── CreatorA/
├── CreatorB/
├── Sasayaki/
├── _data/      <- create this, empty
└── _wiki/      <- create this, empty
```

The app's own state (thumbnail cache, tag index, hide/delete records — never your original
audio) lives here. Your library folder is mounted **read-only** so a bug can never touch an
original file; `_data/` and `_wiki/` are shadow-mounted read-write for exactly the same reason
`Sasayaki/` is, and for the same technical reason (a bind-mount target must already exist as a
real directory before Docker can attach to it) — they just need to exist, empty, before first run.

## 2. Configure the library path

```bash
cp .env.example .env
# edit .env — set SASAYAKI_LIBRARY to the PARENT of the Sasayaki folder above
```

## 3. Build and start

```bash
docker compose up -d --build
docker compose logs -f       # watch startup; Ctrl-C to stop watching (container keeps running)
```

## 4. Open it

`http://localhost:8080/library`

You should see your library immediately — every audio file shows up as a playable card, even
before you build any index (the server does a live filesystem scan). Titles are filenames and
cards have no tags yet; that's what the optional index build below fills in.

## 5. (Optional) First run: build the index

The core ships four **CPU-only** index builders. Running them once turns the raw filesystem
listing into a proper library — acoustic tags, a tag filter, a processing ledger, and source
badges. They read your library and write only into `_data/` and `_wiki/` (never your audio).
**Order matters — `analyze_audio.py` first**, because the others read its output.

```bash
# run inside the container (the app must resolve its own paths at /media)
docker compose exec sasayaki python /media/Sasayaki/analyze_audio.py   --root /media   # -> _wiki/audio_index.json  (acoustic stats + tags; ffmpeg, can take a while on a big library)
docker compose exec sasayaki python /media/Sasayaki/build_tags.py                       # -> _wiki/tags.json          (clickable tag chips / filtering)
docker compose exec sasayaki python /media/Sasayaki/process_ledger.py                   # -> _data/process_ledger.json (per-work processing status)
docker compose exec sasayaki python /media/Sasayaki/source_scan.py                      # -> _data/source_platform.json (DLsite/YouTube/etc. source filters)
```

Refresh `/library` afterward — cards now carry real tags, the tag filter and source chips
populate, and titles pick up any DLsite metadata you have. Re-run any of them whenever you add
new works; `analyze_audio.py` is resumable (it skips unchanged files).

Everything else (transcription, translation, vibe/moment search, trigger timelines, the creator
wiki, AI chat) needs the separate GPU worker package and stays empty here — see the README's
feature table.

## What to expect

- Your creator folders show up as-is; audio plays directly — no index build required.
- Library-management **hide/unhide** works immediately. Tags, the tag filter, and source badges
  populate once you run the optional index build in step 5 above.
- **delete/restore** (which physically move an audio file into a trash folder) need write
  access to your library, which is deliberately off by default for safety. To enable it,
  change the library line in `docker-compose.yml` from `:ro` to `:rw`.
- Subtitle playback works **only** for works that already have a `.ja.srt`/`.en.srt` sidecar —
  this core repo does not transcribe anything itself (see the main README's feature table).
- Search-by-vibe, trigger timelines, wiki, and AI chat will show empty/absent — they need the
  separate GPU worker package, not included here.

## Stopping / removing

```bash
docker compose down
```

Nothing outside this folder and your library is touched — no system-wide installs, no daemons.

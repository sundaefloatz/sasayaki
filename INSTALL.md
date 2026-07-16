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

## What to expect

- Your creator folders show up as-is; audio plays directly.
- Tags, DLsite metadata, and library-management (hide/unhide/delete/restore) work immediately.
- Subtitle playback works **only** for works that already have a `.ja.srt`/`.en.srt` sidecar —
  this core repo does not transcribe anything itself (see the main README's feature table).
- Search-by-vibe, trigger timelines, wiki, and AI chat will show empty/absent — they need the
  separate GPU worker package, not included here.

## Stopping / removing

```bash
docker compose down
```

Nothing outside this folder and your library is touched — no system-wide installs, no daemons.

# Sasayaki app (Show-SubtitlerLog.ps1 -Serve) as a Linux container — the "run it on a home NAS" target.
#
# The app is BIND-MOUNTED at runtime (not COPYd into the image) so it always tracks the repo and the
# same image works for local-test and the NAS. This image supplies only the runtime:
#   - PowerShell 7 (the app is a pwsh/.NET HttpListener server)
#   - ffmpeg/ffprobe (cover-art thumbnails + audio content-type probing)
# 2026-07-04: bare python3 ADDED (stdlib only, no pip packages) -- subs_for.py (the /subs bilingual
# subtitle drawer) imports ONLY os/re/sys/json/argparse + paths.py (which itself imports only os), so
# this unblocks the whole library's subtitles for a few MB, zero ML weight. /worksearch + /segsearch
# (semantic vibe/moment search) need numpy + embedding models -- genuinely heavy -- and STAY omitted;
# they still degrade gracefully (try/catch -> empty) as designed.
FROM mcr.microsoft.com/powershell:latest
RUN apt-get update \
 && apt-get install -y --no-install-recommends ffmpeg ca-certificates python3 \
 && rm -rf /var/lib/apt/lists/* \
 && ln -sf /usr/bin/python3 /usr/bin/python
# The PS route handlers call literal `python` (Show-SubtitlerLog.ps1's /subs, /worksearch, /segsearch) --
# Debian ships only python3 by default, so the symlink above is required, not cosmetic.
ENV SASAYAKI_LAN=1
# paths.py (imported by subs_for.py etc.) defaults ROOT to a hardcoded Windows path unless this is
# set -- the PS server gets its root via -Root /media on the entrypoint below, but that CLI flag
# never reaches the separate python subprocesses subs_for.py spawns, so they need their own signal.
ENV SASAYAKI_ROOT=/media
EXPOSE 8080
# The app derives its archive root as the PARENT of its own folder, so it MUST live at
# <library>/Sasayaki inside the container. The compose mounts the library at /media, which puts the
# app at /media/Sasayaki and the archive root at /media — mirroring the Windows layout exactly.
WORKDIR /media/Sasayaki
ENTRYPOINT ["pwsh","-NoProfile","-File","/media/Sasayaki/Show-SubtitlerLog.ps1","-Serve","-Port","8080","-Root","/media"]

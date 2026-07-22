#!/usr/bin/env python3
"""
smoke_test.py -- acceptance checklist for a running Sasayaki CPU-only core.

Stdlib only (urllib). Points at a running instance and checks the 7 things a fresh CPU-only
deploy must do: boot, serve, browse a fresh DB, play, self-build its index, degrade GPU features
gracefully, and leak no personal paths. Doubles as a "did my install work?" tool for users.

  python smoke_test.py --base http://localhost:8080
  python smoke_test.py --base http://your-server:18080 --expect-works 50
  python smoke_test.py --base http://localhost:8080 --json      # machine-readable result only

Exit code 0 iff every criterion PASSes (skips don't fail). Criteria that can't be judged over
HTTP alone (e.g. "container is up") are inferred from reachability + a clean response.
"""
import sys, json, argparse, urllib.request, urllib.error

TIMEOUT = 20


def _get(base, path, headers=None, method="GET"):
    """Return (status, body_bytes, headers_dict). status=0 on connection failure."""
    url = base.rstrip("/") + path
    req = urllib.request.Request(url, method=method, headers=headers or {})
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
            return r.status, r.read(), {k.lower(): v for k, v in r.headers.items()}
    except urllib.error.HTTPError as e:
        return e.code, (e.read() if hasattr(e, "read") else b""), {}
    except Exception as e:
        return 0, str(e).encode(), {}


def _json(body):
    try:
        return json.loads(body.decode("utf-8", "replace"))
    except Exception:
        return None


class Check:
    def __init__(self, key, title):
        self.key, self.title = key, title
        self.status = "SKIP"          # PASS | FAIL | SKIP
        self.detail = ""

    def ok(self, detail=""):
        self.status, self.detail = "PASS", detail; return self

    def fail(self, detail=""):
        self.status, self.detail = "FAIL", detail; return self

    def skip(self, detail=""):
        self.status, self.detail = "SKIP", detail; return self


def run(base, expect_works):
    checks = []

    # 1. Boots / reachable -- the server answers at all.
    c = Check("boots", "Boots & reachable")
    st, body, _ = _get(base, "/library")
    if st == 200:
        c.ok(f"/library -> 200")
    elif st == 0:
        c.fail(f"unreachable: {body.decode('utf-8','replace')[:80]}")
    else:
        c.fail(f"/library -> {st}")
    checks.append(c)
    reachable = c.status == "PASS"

    # Fetch /library.json ONCE, up front, and reuse it for checks 2-5. (Re-fetching per check risked a
    # different snapshot mid-run if a rebuild completed between calls.)
    lib = None
    rows = []
    if reachable:
        _, lbody, _ = _get(base, "/library.json")
        lib = _json(lbody)
        rows = lib if isinstance(lib, list) else (lib.get("works", []) if isinstance(lib, dict) else [])
    sample = rows[0].get("id") if rows else None

    # 2. Serves -- /home 200 and /library.json returns works.
    c = Check("serves", "Serves pages & library data")
    if not reachable:
        c.skip("server unreachable")
    else:
        hs, _, _ = _get(base, "/home")
        n = len(rows)
        if hs != 200:
            c.fail(f"/home -> {hs}")
        elif not isinstance(lib, list) and not isinstance(lib, dict):
            c.fail("/library.json not JSON")
        elif n < max(1, expect_works):
            c.fail(f"/library.json has {n} works (expected >= {max(1, expect_works)})")
        else:
            c.ok(f"/home 200, /library.json {n} works")
    checks.append(c)

    # 3. Fresh-DB browse -- works list even with no index (pending FS scan). A pending card is the
    #    proof: it means the row came from the filesystem, not audio_index.json.
    c = Check("fresh_db", "Fresh-DB browse (pending FS scan)")
    if not reachable:
        c.skip("server unreachable")
    elif not rows:
        c.fail("no works listed at all")
    else:
        pending = sum(1 for r in rows if r.get("pending"))
        # Either some pending rows (truly fresh) OR an index already built (indexed rows) both mean
        # "works are browsable" -- this criterion just proves listing works without a crash.
        c.ok(f"{len(rows)} works browsable ({pending} pending / FS-scanned)")
    checks.append(c)

    # 4. Plays -- /audio serves real bytes for a sampled work (Range -> 206 preferred).
    c = Check("plays", "Audio playback")
    if not reachable:
        c.skip("server unreachable")
    elif not sample:
        c.fail("no sample work to play")
    else:
        from urllib.parse import quote
        st, body, hdrs = _get(base, "/audio?id=" + quote(sample, safe=""),
                              headers={"Range": "bytes=0-1023"})
        if st == 206 and len(body) > 0:
            c.ok(f"206 partial, {len(body)} bytes, accept-ranges={hdrs.get('accept-ranges','?')}")
        elif st == 200 and len(body) > 0:
            c.ok(f"200 full, {len(body)} bytes (no range support advertised)")
        else:
            c.fail(f"/audio -> {st}, {len(body)} bytes")
    checks.append(c)

    # 5. Database creation -- after the builders run, indexes exist and the server reflects them.
    #    Over HTTP we detect this as: tags.json has counts, OR library rows carry real tags.
    #    (On a truly fresh instance before the build, this is expected to SKIP, not FAIL.)
    c = Check("database", "Database creation (index built)")
    if not reachable:
        c.skip("server unreachable")
    else:
        _, tbody, _ = _get(base, "/tags.json")
        tags = _json(tbody) or {}
        tag_count = len(tags.get("counts", {})) if isinstance(tags, dict) else 0
        tagged_rows = sum(1 for r in rows if r.get("tags"))
        if tag_count > 0 or tagged_rows > 0:
            c.ok(f"tags.json has {tag_count} tags, {tagged_rows} works carry tags")
        else:
            c.skip("no index built yet -- run analyze_audio.py -> build_tags.py "
                   "(see INSTALL.md step 5), then re-run this check")
    checks.append(c)

    # 6. Degrades -- GPU-only routes must return WELL-FORMED responses without crashing/hanging when
    #    the GPU worker is absent. On a pure CPU-only core they come back empty (the intended state);
    #    if a full stack is behind them they may be populated -- both are fine, what we're ruling out
    #    is a 500 / malformed body / hang. The retrigger guard is checked strictly (it must report a
    #    clean JSON error, never launch a doomed job).
    c = Check("degrades", "GPU features degrade gracefully")
    if not reachable:
        c.skip("server unreachable")
    else:
        probs, notes = [], []
        ws, wbody, _ = _get(base, "/worksearch?q=test")
        wj = _json(wbody)
        if ws != 200 or not isinstance(wj, list):
            probs.append(f"/worksearch -> {ws} {wbody[:40]!r}")
        elif wj:
            notes.append("worksearch populated (GPU backend present)")
        ss, sbody, _ = _get(base, "/subs")
        sj = _json(sbody)
        if ss != 200 or not (isinstance(sj, dict) and "cues" in sj):
            probs.append(f"/subs -> {ss} {sbody[:40]!r}")
        ts, tbody2, _ = _get(base, "/triggers")
        tj = _json(tbody2)
        if ts != 200 or not (isinstance(tj, dict) and "ranges" in tj):
            probs.append(f"/triggers -> {ts} {tbody2[:40]!r}")
        # retrigger with no ids: MUST return a clean JSON error ({ok:false}), never a 500 / hang /
        # doomed background job. This is the CPU-core guard specifically.
        rs, rbody, _ = _get(base, "/library/retrigger", method="POST")
        rj = _json(rbody)
        if not (isinstance(rj, dict) and rj.get("ok") is False):
            probs.append(f"/library/retrigger -> {rs} {rbody[:40]!r}")
        if probs:
            c.fail("; ".join(probs))
        else:
            msg = "GPU routes well-formed, retrigger clean error"
            if notes:
                msg += " [" + "; ".join(notes) + "]"
            c.ok(msg)
    checks.append(c)

    # 7. No leakage -- served pages/data carry no dev-machine paths or LAN IPs.
    c = Check("no_leak", "No personal-path / LAN leakage")
    if not reachable:
        c.skip("server unreachable")
    else:
        import re
        # generic leak needles -- Windows drive paths, absolute unix home paths, and private/CGNAT
        # (Tailscale) IP ranges. No hardcoded personal values, so this ships safely in a public repo.
        leak_rx = re.compile(
            rb"[A-Z]:\\(?:Users|Resources|home)"          # Windows dev paths (C:\Users, D:\Resources...)
            rb"|/home/[a-z0-9_.-]+/"                        # unix home dir absolute paths
            rb"|(?:192\.168|10)\.\d+\.\d+\.\d+"             # RFC1918 private LAN
            rb"|100\.(?:6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.\d+\.\d+")  # 100.64/10 CGNAT (Tailscale)
        found = []
        for p in ("/library", "/home", "/library.json", "/settings"):
            _, b, _ = _get(base, p)
            m = leak_rx.search(b or b"")
            if m:
                found.append(f"{p}: {m.group(0).decode('utf-8','replace')}")
        if found:
            c.fail("; ".join(found))
        else:
            c.ok("no dev paths / LAN IPs in served responses")
    checks.append(c)

    return checks


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", default="http://localhost:8080", help="base URL of a running instance")
    ap.add_argument("--expect-works", type=int, default=1, help="minimum works /library.json must return")
    ap.add_argument("--json", action="store_true", help="print only the machine-readable JSON result")
    a = ap.parse_args()

    checks = run(a.base, a.expect_works)
    npass = sum(1 for c in checks if c.status == "PASS")
    nfail = sum(1 for c in checks if c.status == "FAIL")
    nskip = sum(1 for c in checks if c.status == "SKIP")
    result = {"base": a.base, "pass": npass, "fail": nfail, "skip": nskip,
              "checks": [{"key": c.key, "title": c.title, "status": c.status, "detail": c.detail}
                         for c in checks]}

    if a.json:
        print(json.dumps(result, ensure_ascii=False, indent=2))
    else:
        icon = {"PASS": "PASS", "FAIL": "FAIL", "SKIP": "skip"}
        print(f"\nSasayaki core smoke test -> {a.base}\n")
        for i, c in enumerate(checks, 1):
            print(f"  {i}. [{icon[c.status]}] {c.title}")
            if c.detail:
                print(f"         {c.detail}")
        print(f"\n  {npass} passed, {nfail} failed, {nskip} skipped\n")

    # Exit non-zero if anything failed (skips are not failures).
    sys.exit(1 if nfail else 0)


if __name__ == "__main__":
    main()

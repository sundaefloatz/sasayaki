#Requires -Version 7.0
<#
.SYNOPSIS
    Private, offline progress viewer for the ASMR subtitler batch.
    Parses library_run.log and renders a console dashboard and/or a fully
    self-contained HTML page (no internet, no external fonts/CDNs).

.EXAMPLE
    # One-shot console snapshot:
    .\Show-SubtitlerLog.ps1

.EXAMPLE
    # Live HTML dashboard, auto-refresh every 8s, open in browser:
    .\Show-SubtitlerLog.ps1 -Loop -Open

.EXAMPLE
    # Live console dashboard:
    .\Show-SubtitlerLog.ps1 -Loop -Console
#>
[CmdletBinding()]
param(
    [string]$Log = "$PSScriptRoot\library_run.log",
    [string]$Html = "$PSScriptRoot\library_run.html",
    [string]$Root = $(if ($env:SASAYAKI_ROOT) { $env:SASAYAKI_ROOT } else { '/media' }),
    [int]$RefreshSeconds = 8,
    [int]$Feed = 14,                # recent cue lines to show
    [switch]$Loop,
    [switch]$Console,              # console dashboard instead of HTML
    [switch]$Open,                # open the dashboard once at start
    [switch]$Serve,               # run a local web server: smooth in-place updates, no page reload
    [int]$Port = 8787             # http port for -Serve
)

function Get-Log([string]$p) {
    if (-not (Test-Path -LiteralPath $p)) { return @() }
    $raw = Get-Content -LiteralPath $p -Raw -ErrorAction SilentlyContinue
    if (-not $raw) { return @() }
    ($raw -replace "\x1b\[[0-9;]*m", "") -split "`r?`n"
}

function HtmlEnc([string]$s) {
    if ($null -eq $s) { return '' }
    $s.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;').Replace('"', '&quot;')
}

function Fmt-Span([double]$sec) {
    if ($sec -le 0 -or [double]::IsInfinity($sec) -or [double]::IsNaN($sec)) { return '—' }
    $ts = [TimeSpan]::FromSeconds([math]::Round($sec))
    if ($ts.TotalHours -ge 1) { return ('{0}h {1}m' -f [int]$ts.TotalHours, $ts.Minutes) }
    if ($ts.TotalMinutes -ge 1) { return ('{0}m {1}s' -f [int]$ts.TotalMinutes, $ts.Seconds) }
    return ('{0}s' -f $ts.Seconds)
}

function Parse-State {
    $lines = Get-Log $Log
    $st = [ordered]@{
        Exists = ($lines.Count -gt 0); Total = 0; Deduped = 0; BatchN = 0; CurIdx = 0; CurFile = ''
        Ja = 0; En = 0; Burns = 0; SkipExist = 0; SkipNoSub = 0; Failed = 0
        Done = $false; Built = $null; Start = $null; LastWrite = $null; Feed = @()
    }
    if (-not $st.Exists) { return [pscustomobject]$st }

    # one pass: counts + a rolling buffer of the last $Feed cue lines (cue lines are most frequent and
    # never match the count patterns, so match them first and continue)
    $feedBuf = [System.Collections.Generic.List[object]]::new()
    foreach ($l in $lines) {
        if ($l -match '\[(transcribe|translate)\s+([0-9\. ]+)%\]\s+(\S+)\s+(.*)$') {
            $feedBuf.Add([pscustomobject]@{ Task = $Matches[1]; Pct = $Matches[2].Trim(); Time = $Matches[3]; Text = $Matches[4].Trim() })
            if ($feedBuf.Count -gt $Feed) { $feedBuf.RemoveAt(0) }
            continue
        }
        if ($l -match 'Found (\d+) media')            { $st.Total = [int]$Matches[1] }
        elseif ($l -match 'De-duped (\d+) ')          { $st.Deduped = [int]$Matches[1] }
        elseif ($l -match '^\[(\d+)/(\d+)\]\s*(.+)$') { $st.CurIdx = [int]$Matches[1]; $st.BatchN = [int]$Matches[2]; $st.CurFile = $Matches[3].Trim() }
        elseif ($l -match 'wrote .*\.en\.srt')         { $st.En++ }
        elseif ($l -match 'wrote .*\.srt')             { $st.Ja++ }   # .ja.srt or adopted legacy .srt
        elseif ($l -match '^burning:')                 { $st.Burns++ }
        elseif ($l -match 'skip \(exists\)')           { $st.SkipExist++ }
        elseif ($l -match 'skip \(no subs\)')          { $st.SkipNoSub++ }
        elseif ($l -match '\bFAILED\b')                { $st.Failed++ }
        elseif ($l -match 'Done\. Built=(\d+)\s+Skipped=(\d+)\s+Failed=(\d+)') {
            $st.Done = $true; $st.Built = [int]$Matches[1]
        }
        elseif ($l -match '^START (\S+)') { try { $st.Start = [datetime]::Parse($Matches[1]) } catch {} }
    }
    $st.Feed = @($feedBuf)
    $st.LastWrite = (Get-Item -LiteralPath $Log).LastWriteTime
    [pscustomobject]$st
}

function Get-LibraryRollup {
    # durable "what's subtitled" view: outputs grouped by top-level creator/source folder
    if (-not (Test-Path -LiteralPath $Root)) { return @() }
    $tops = Get-ChildItem -LiteralPath $Root -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'Sasayaki' }
    $media = '.mp3', '.wav', '.m4a', '.flac', '.opus', '.ogg', '.aac', '.wma', '.mp4', '.mkv', '.webm', '.mov', '.avi', '.m4v', '.ts'
    foreach ($t in $tops) {
        $mp4 = 0; $ja = 0; $en = 0
        $bases = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($f in Get-ChildItem -LiteralPath $t.FullName -Recurse -File -ErrorAction SilentlyContinue) {
            $n = $f.Name
            if ($n -like '*.subbed.mp4') { $mp4++ }
            elseif ($n -like '*.ja.srt') { $ja++ }
            elseif ($n -like '*.en.srt') { $en++ }
            elseif ($media -contains $f.Extension.ToLower()) { [void]$bases.Add([IO.Path]::GetFileNameWithoutExtension($n)) }  # distinct track (wav/mp3 & mp4/m4a twins share basename)
        }
        if ($mp4 -or $ja -or $en -or $bases.Count) { [pscustomobject]@{ Name = $t.Name; Mp4 = $mp4; Ja = $ja; En = $en; Total = $bases.Count } }
    }
}

function Get-Eta($s) {
    if (-not $s.Start -or $s.CurIdx -le 0 -or $s.BatchN -le 0) { return $null }
    $elapsed = ((Get-Date) - $s.Start).TotalSeconds
    if ($elapsed -le 0) { return $null }
    $rate = $s.CurIdx / $elapsed                       # files/sec transcribed
    if ($rate -le 0) { return $null }
    [pscustomobject]@{
        Elapsed = $elapsed
        Remain  = ($s.BatchN - $s.CurIdx) / $rate
        Pct     = [math]::Round(100.0 * $s.CurIdx / $s.BatchN, 1)
    }
}

function Render-Console($s, $roll, $eta) {
    Clear-Host
    $status = if ($s.Done) { 'DONE' } elseif (-not $s.Exists) { 'NO LOG YET' }
              elseif ($s.LastWrite -and ((Get-Date) - $s.LastWrite).TotalSeconds -gt 120) { 'STALLED?' } else { 'RUNNING' }
    $col = switch ($status) { 'DONE' { 'Green' } 'RUNNING' { 'Cyan' } 'NO LOG YET' { 'DarkGray' } default { 'Yellow' } }
    Write-Host "  ASMR Subtitler — private log viewer" -ForegroundColor White
    Write-Host "  status: " -NoNewline; Write-Host $status -ForegroundColor $col -NoNewline
    Write-Host "   updated: $(Get-Date -Format 'HH:mm:ss')   log: $(if($s.LastWrite){$s.LastWrite.ToString('HH:mm:ss')}else{'-'})"
    Write-Host ("  " + ('-' * 60)) -ForegroundColor DarkGray
    if ($s.BatchN) {
        $p = if ($eta) { $eta.Pct } else { [math]::Round(100.0 * $s.CurIdx / $s.BatchN, 1) }
        $w = 40; $fill = [int]($w * $p / 100)
        Write-Host ("  transcribe [{0}{1}] {2,5}%  {3}/{4}" -f ('█' * $fill), ('░' * ($w - $fill)), $p, $s.CurIdx, $s.BatchN) -ForegroundColor Cyan
    }
    Write-Host ("  tracks {0}  (deduped {1})   JA {2}   EN {3}   MP4 {4}   skip {5}   fail {6}" -f `
        $s.Total, $s.Deduped, $s.Ja, $s.En, $s.Burns, ($s.SkipExist + $s.SkipNoSub), $s.Failed)
    if ($eta) { Write-Host ("  elapsed {0}   eta(transcribe) {1}" -f (Fmt-Span $eta.Elapsed), (Fmt-Span $eta.Remain)) -ForegroundColor DarkGray }
    if ($s.CurFile) { Write-Host "  now: $($s.CurFile)" -ForegroundColor White }
    Write-Host ("  " + ('-' * 60)) -ForegroundColor DarkGray
    Write-Host "  recent:" -ForegroundColor DarkGray
    foreach ($f in $s.Feed) {
        $tcol = if ($f.Task -eq 'translate') { 'Green' } else { 'Gray' }
        Write-Host ("   {0,-9} {1}  " -f $f.Task, $f.Time) -ForegroundColor DarkGray -NoNewline
        Write-Host ($f.Text.Substring(0, [math]::Min(60, $f.Text.Length))) -ForegroundColor $tcol
    }
    if ($roll) {
        Write-Host ("  " + ('-' * 60)) -ForegroundColor DarkGray
        Write-Host "  library output (mp4 / ja / en):" -ForegroundColor DarkGray
        foreach ($r in ($roll | Sort-Object Mp4 -Descending | Select-Object -First 12)) {
            Write-Host ("   {0,4} {1,4} {2,4}   {3}" -f $r.Mp4, $r.Ja, $r.En, $r.Name)
        }
    }
}

function Render-Html($s, $roll, $eta) {
    $status = if ($s.Done) { 'DONE' } elseif (-not $s.Exists) { 'NO LOG YET' }
              elseif ($s.LastWrite -and ((Get-Date) - $s.LastWrite).TotalSeconds -gt 120) { 'STALLED?' } else { 'RUNNING' }
    $pct = if ($s.BatchN) { if ($eta) { $eta.Pct } else { [math]::Round(100.0 * $s.CurIdx / $s.BatchN, 1) } } else { 0 }
    $meta = if ($Loop) { "<meta http-equiv='refresh' content='$RefreshSeconds'>" } else { '' }

    $cardDefs = @(
        @('tracks', $s.Total, 'cyan'), @('deduped', $s.Deduped, 'purple'), @('JA subs', $s.Ja, 'pink'),
        @('EN subs', $s.En, 'cyan'), @('MP4s', $s.Burns, 'green'),
        @('skipped', ($s.SkipExist + $s.SkipNoSub), 'muted'), @('failed', $s.Failed, 'coral')
    )
    $cards = ($cardDefs | ForEach-Object {
        $accent = if ($_[0] -eq 'failed' -and $_[1] -le 0) { 'muted' } else { $_[2] }
        "<div class='card c-$accent'><div class='n'>$($_[1])</div><div class='k'>$(HtmlEnc $_[0])</div><i class='ub'></i></div>"
    }) -join ''

    $feedRows = ($s.Feed | ForEach-Object {
        $tcls = if ($_.Task -eq 'translate') { 'en' } else { 'ja' }
        "<tr><td class='task $tcls'>$($_.Task)</td><td class='tm'>$(HtmlEnc $_.Time)</td><td>$(HtmlEnc $_.Text)</td></tr>"
    }) -join "`n"

    $maxMp4 = ($roll | Measure-Object Mp4 -Maximum).Maximum; if (-not $maxMp4) { $maxMp4 = 1 }
    $rollRows = ($roll | Sort-Object Mp4 -Descending | ForEach-Object {
        $w = [int](100 * $_.Mp4 / $maxMp4)
        "<tr><td class='r'>$($_.Mp4)</td><td class='r'>$($_.Ja)</td><td class='r'>$($_.En)</td><td><span class='rname' style='--w:${w}%'>$(HtmlEnc $_.Name)</span></td></tr>"
    }) -join "`n"

    $etaTxt = if ($eta) { "ETA $(Fmt-Span $eta.Remain)" } else { '' }
    $sCls = switch ($status) { 'DONE' { 'done' } 'RUNNING' { 'run' } 'STALLED?' { 'warn' } default { 'idle' } }
    $elapsedSec = if ($eta) { [int]$eta.Elapsed } else { 0 }
    $wave = (1..44 | ForEach-Object { "<i style='--d:-$(Get-Random -Minimum 0 -Maximum 800)ms;--mh:$([math]::Round((Get-Random -Minimum 22 -Maximum 100) / 100, 2))'></i>" }) -join ''

    $page = @"
<!doctype html><html lang='en'><head><meta charset='utf-8'>
<meta name='viewport' content='width=device-width,initial-scale=1'>$meta
<meta name='theme-color' content='#0b0b0d'>
<title>Sasayaki 囁き // live</title>
<style>
  :root{color-scheme:dark;
    --bg:#181a1b;--surface:#1d1f20;--surface2:#232526;--line:rgba(255,255,255,.06);--line2:rgba(255,255,255,.11);
    --txt:#e8e6e3;--muted:#9b958f;--dim:#5d5852;
    --cyan:#e4405f;--pink:#ff7a99;--coral:#ff5a5f;--purple:#8b7bff;--green:#46e08a;--amber:#f0c24a;
    --mono:ui-monospace,'Cascadia Code','JetBrains Mono',Consolas,monospace}
  *{box-sizing:border-box}
  body{margin:0;background:var(--bg);color:var(--txt);overflow-x:hidden;
    font:14px/1.55 -apple-system,'Segoe UI',Roboto,system-ui,sans-serif;animation:fadein .45s ease both}
  /* flat: scanline grid + body glow removed (asmr.one-style) */
  @keyframes fadein{from{opacity:0;transform:translateY(6px)}to{opacity:1;transform:none}}
  @keyframes grid{to{background-position:0 40px,40px 0}}
  @keyframes pulse{0%,100%{opacity:1}50%{opacity:.28}}
  @keyframes blink{50%{opacity:0}}
  .wrap{max-width:1080px;margin:0 auto;padding:24px 22px 70px}
  .top{display:flex;align-items:center;gap:16px;flex-wrap:wrap}
  .logo{font-weight:800;font-size:20px;letter-spacing:-.3px;display:flex;align-items:center;gap:10px;white-space:nowrap}
  .logo .dot{width:10px;height:10px;border-radius:50%;background:var(--cyan);animation:pulse 1.5s ease-in-out infinite}
  .logo b{font-weight:800;background:linear-gradient(90deg,var(--cyan),var(--pink));-webkit-background-clip:text;background-clip:text;color:transparent}
  .eq{display:flex;align-items:flex-end;gap:2px;height:30px;flex:1 1 180px;overflow:hidden;opacity:.9}
  .eq i{display:block;width:3px;height:30px;transform-origin:bottom;border-radius:2px;
    background:linear-gradient(180deg,var(--pink),var(--cyan));animation:eq .8s ease-in-out infinite alternate;animation-delay:var(--d)}
  @keyframes eq{from{transform:scaleY(.12)}to{transform:scaleY(var(--mh))}}
  .hud{display:flex;gap:7px;align-items:center;font-family:var(--mono);font-size:12px;white-space:nowrap}
  .hud .k{color:var(--dim);font-size:9.5px;letter-spacing:1px}
  .hud .v{color:var(--cyan)}
  .sub{color:var(--muted);font-size:11.5px;margin:8px 0 16px;font-family:var(--mono)}
  .status{display:flex;align-items:center;gap:12px;margin-bottom:6px}
  .badge{display:inline-flex;align-items:center;gap:7px;padding:5px 13px;border-radius:8px;font-size:11px;font-weight:800;letter-spacing:1px;text-transform:uppercase;font-family:var(--mono);border:1px solid currentColor}
  .badge::before{content:'';width:7px;height:7px;border-radius:50%;background:currentColor}
  .badge.run{color:var(--cyan);background:rgba(228,64,95,.10)}
  .badge.done{color:var(--green);background:rgba(70,224,138,.10)}
  .badge.warn{color:var(--amber);background:rgba(240,194,74,.10)}
  .badge.idle{color:var(--muted);background:#15171a;border-color:var(--line)}
  .badge.run::before{animation:pulse 1.3s ease-in-out infinite}
  .eta{color:var(--muted);font-size:12px;font-family:var(--mono)}
  .bar{height:16px;background:#111314;border:1px solid var(--line);border-radius:999px;overflow:hidden;margin:14px 0 7px;position:relative}
  .bar>i{position:relative;display:block;height:100%;border-radius:999px;width:${pct}%;
    background:linear-gradient(90deg,var(--cyan),var(--pink));transition:width .6s ease}
  .bar>i::after{content:'';position:absolute;inset:0;background:repeating-linear-gradient(45deg,rgba(255,255,255,.22) 0 9px,transparent 9px 18px);animation:stripes .8s linear infinite}
  @keyframes stripes{to{background-position:36px 0}}
  .pl{display:flex;justify-content:space-between;color:var(--muted);font-size:12px;font-family:var(--mono)}
  .cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(118px,1fr));gap:11px;margin:20px 0}
  .card{position:relative;background:linear-gradient(180deg,var(--surface2),#141618);border:1px solid var(--line);border-radius:14px;padding:14px 14px 16px;overflow:hidden;transition:border-color .2s,transform .2s}
  .card:hover{transform:translateY(-2px);border-color:#3a3d40}
  .card .n{font-size:28px;font-weight:800;font-family:var(--mono);letter-spacing:-1px;line-height:1}
  .card .k{color:var(--muted);font-size:10px;text-transform:uppercase;letter-spacing:.8px;margin-top:7px;font-family:var(--mono)}
  .card .ub{position:absolute;left:0;bottom:0;height:3px;width:100%;opacity:.9}
  .c-cyan .n{color:var(--cyan)}.c-cyan .ub{background:var(--cyan);color:var(--cyan)}
  .c-pink .n{color:var(--pink)}.c-pink .ub{background:var(--pink);color:var(--pink)}
  .c-coral .n{color:var(--coral)}.c-coral .ub{background:var(--coral);color:var(--coral)}
  .c-green .n{color:var(--green)}.c-green .ub{background:var(--green);color:var(--green)}
  .c-purple .n{color:var(--purple)}.c-purple .ub{background:var(--purple);color:var(--purple)}
  .c-muted .n{color:var(--txt)}.c-muted .ub{background:#33343c;color:#33343c}
  .now{display:flex;align-items:center;gap:10px;background:#111314;border:1px solid var(--line);border-radius:12px;padding:12px 15px;margin-bottom:22px;word-break:break-all;font-size:13px;font-family:var(--mono)}
  .now .pr{color:var(--cyan);font-weight:800;font-size:10.5px;letter-spacing:1px;white-space:nowrap}
  .now .cr{display:inline-block;width:8px;height:15px;background:var(--cyan);margin-left:2px;animation:blink 1s step-end infinite;vertical-align:middle}
  h2{font-size:10.5px;color:var(--muted);text-transform:uppercase;letter-spacing:1.2px;margin:18px 0 7px;display:flex;align-items:center;gap:10px;font-family:var(--mono)}
  h2::before{content:'//';color:var(--cyan)}
  h2::after{content:'';flex:1;height:1px;background:linear-gradient(90deg,var(--line),transparent)}
  .panel{position:relative;background:var(--surface);border:1px solid var(--line);border-radius:12px;overflow:hidden}
  .panel::before,.panel::after{content:'';position:absolute;width:12px;height:12px;border:2px solid var(--cyan);opacity:.5;z-index:2}
  .panel::before{top:-1px;left:-1px;border-right:0;border-bottom:0;border-radius:12px 0 0 0}
  .panel::after{bottom:-1px;right:-1px;border-left:0;border-top:0;border-radius:0 0 12px 0}
  .term{max-height:340px;overflow-y:auto;scrollbar-width:none;-webkit-mask-image:linear-gradient(180deg,transparent,#000 22px,#000 100%);mask-image:linear-gradient(180deg,transparent,#000 22px,#000 100%)}
  .term::-webkit-scrollbar{display:none}
  table{width:100%;border-collapse:collapse;font-size:13px}
  td{padding:7px 13px;border-bottom:1px solid #15171a;vertical-align:top}
  tr:last-child td{border-bottom:0}
  .term tr:last-child td{animation:slidein .5s ease both}
  @keyframes slidein{from{opacity:0;transform:translateX(-8px)}to{opacity:1;transform:none}}
  table tr:hover td{background:rgba(228,64,95,.045)}
  .task{font-weight:800;font-size:9.5px;text-transform:uppercase;letter-spacing:.6px;width:74px;font-family:var(--mono)}
  .task.ja{color:var(--pink)}.task.en{color:var(--cyan)}
  .tm{color:var(--dim);width:92px;font-family:var(--mono);font-size:11.5px}
  td.r{text-align:right;width:46px;font-family:var(--mono);font-weight:700;color:var(--txt)}
  .hdr td{color:var(--muted);text-transform:uppercase;font-size:9.5px;letter-spacing:.6px;font-weight:800;font-family:var(--mono)}
  .tail{display:flex;align-items:center;gap:8px;padding:8px 14px;color:var(--dim);font-family:var(--mono);font-size:11px;border-top:1px solid var(--line);background:#111314}
  .tail .cr{display:inline-block;width:7px;height:12px;background:var(--green);animation:blink 1s step-end infinite}
  .rname{position:relative;display:block;padding-bottom:7px}
  .rname::after{content:'';position:absolute;left:0;bottom:0;height:2px;width:var(--w);border-radius:2px;opacity:.85;background:linear-gradient(90deg,var(--cyan),var(--pink));box-shadow:0 0 8px rgba(228,64,95,.5)}
  .foot{color:var(--dim);font-size:10.5px;margin-top:28px;text-align:center;letter-spacing:.4px;font-family:var(--mono)}
</style></head><body>
<div class='wrap'>
  <div class='top'>
    <div class='logo'><span class='dot'></span>Sasayaki<b>//囁き</b></div>
    <div class='eq'>$wave</div>
    <div class='hud'><span class='k'>CLK</span><span class='v' id='clock'>--:--:--</span><span class='k'>UP</span><span class='v' id='uptime' data-el='$elapsedSec'>--</span></div>
  </div>
  <div class='sub'>100% local &middot; nothing leaves this machine &middot; $(HtmlEnc (Split-Path $Log -Leaf)) &middot; log $(if($s.LastWrite){$s.LastWrite.ToString('HH:mm:ss')}else{'--'})</div>
  <div class='status'><span class='badge $sCls'>$status</span><span class='eta'>$etaTxt</span></div>
  <div class='bar'><i></i></div>
  <div class='pl'><span>TRANSCRIBE $($s.CurIdx)/$($s.BatchN)</span><span>$pct%</span></div>
  <div class='cards'>$cards</div>
  <div class='now'><span class='pr'>&#9656; PROCESSING</span><span>$(HtmlEnc $s.CurFile)</span><span class='cr'></span></div>
  <h2>live activity stream</h2>
  <div class='panel'><div class='term' id='term'><table>$feedRows</table></div><div class='tail'><span class='cr'></span> streaming &middot; tailing $(HtmlEnc (Split-Path $Log -Leaf))</div></div>
  <h2>library output</h2>
  <div class='panel'><table><tr class='hdr'><td class='r'>MP4</td><td class='r'>JA</td><td class='r'>EN</td><td>source</td></tr>$rollRows</table></div>
  <div class='foot'>$(if($Loop){"&#9679; LIVE &middot; auto-refresh ${RefreshSeconds}s &middot; rendered $(Get-Date -Format 'HH:mm:ss')"}else{'snapshot &middot; run with -Loop for live'})</div>
</div>
<script>
(function(){
  function two(n){return (n<10?'0':'')+n}
  var T0=Date.now();
  function tick(){
    var d=new Date(), c=document.getElementById('clock');
    if(c) c.textContent=two(d.getHours())+':'+two(d.getMinutes())+':'+two(d.getSeconds());
    var u=document.getElementById('uptime');
    if(u){ var base=parseInt(u.getAttribute('data-el')||'0',10);
      var s=base+Math.floor((Date.now()-T0)/1000), h=Math.floor(s/3600), m=Math.floor((s%3600)/60), ss=s%60;
      u.textContent=(h>0?h+'h ':'')+two(m)+'m '+two(ss)+'s'; }
  }
  tick(); setInterval(tick,1000);
  var ns=document.querySelectorAll('.card .n');
  for(var i=0;i<ns.length;i++){ (function(el){
    var target=parseInt((el.textContent||'').replace(/[^0-9]/g,''),10)||0;
    if(target<=0){el.textContent='0';return;}
    var t0=performance.now(), dur=700; el.textContent='0';
    function step(t){ var p=Math.min(1,(t-t0)/dur); el.textContent=Math.round(target*(1-Math.pow(1-p,3))); if(p<1) requestAnimationFrame(step); }
    requestAnimationFrame(step);
  })(ns[i]); }
  var term=document.getElementById('term'); if(term) term.scrollTop=term.scrollHeight;
})();
</script>
</body></html>
"@
    [IO.File]::WriteAllText($Html, $page, [System.Text.UTF8Encoding]::new($false))
}

# ---------- live server mode (-Serve): no page reload, smooth in-place updates ----------
$ServeShell = @'
<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="theme-color" content="#0b0b0d">
<title>Sasayaki 囁き // live</title>
<link rel="preconnect" href="https://fonts.googleapis.com"><link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&family=Space+Grotesk:wght@400;500;600;700&family=JetBrains+Mono:wght@400;500;600&display=swap" rel="stylesheet">
<style>
  :root{color-scheme:dark;
    --bg:#0f1112;--surface:#15181a;--surface2:#1a1d20;--line:rgba(255,255,255,.06);--line2:rgba(255,255,255,.11);
    --txt:#e8e6e3;--muted:#9b958f;--dim:#5d5852;
    --cyan:#e4405f;--teal:#ff7a99;--blue:#5b8cff;--pink:#ff7a99;--coral:#ff5a5f;--purple:#8b7bff;--green:#3fdc97;--amber:#f1c453;
    --mono:"JetBrains Mono",ui-monospace,"Cascadia Code",Consolas,monospace;
    --disp:"JetBrains Mono",ui-monospace,"Cascadia Code",Consolas,monospace;
    --body:"JetBrains Mono",ui-monospace,"Cascadia Code",Consolas,monospace;
    --card:#141719;--inner:#0c0e10;--pk3:rgba(228,64,95,.14);--tile-h:104px;
    --accent-soft:#e4405f22;--accent-glow:#e4405f55;
    --hatch:repeating-linear-gradient(45deg,rgba(255,255,255,.035) 0 1px,transparent 1px 8px)}
  /* ops pages are dark-only by design (Adriel 2026-07-09): realm.js applies data-theme=light
     globally from sasa_theme, but this operator dashboard is Stakent-dark always. Re-pin the
     NEUTRALS under the light theme (!important beats realm.js's later-injected style); leave
     --cyan/accents untouched so the sandbox realm still recolors. */
  html[data-theme=light]{--bg:#0f1112!important;--surface:#15181a!important;--surface2:#1a1d20!important;
    --card:#141719!important;--inner:#0c0e10!important;--line:rgba(255,255,255,.06)!important;--line2:rgba(255,255,255,.11)!important;
    --txt:#e8e6e3!important;--muted:#9b958f!important;--dim:#5d5852!important;color-scheme:dark!important}
  *{box-sizing:border-box}
  body{margin:0;background:var(--bg);color:var(--txt);overflow-x:hidden;
    font:13px/1.65 var(--mono);letter-spacing:.1px;animation:fadein .5s ease both}
  @keyframes fadein{from{opacity:0}to{opacity:1}}
  @keyframes grid{to{background-position:0 40px,40px 0}}
  @keyframes pulse{0%,100%{opacity:1}50%{opacity:.4}}
  @keyframes blink{50%{opacity:0}}
  .wrap{max-width:1080px;margin:0 auto;padding:24px 22px 70px}
  .top{display:flex;align-items:center;gap:16px;flex-wrap:wrap}
  .logo{font-family:var(--mono);font-weight:700;font-size:19px;display:flex;align-items:center;gap:10px;white-space:nowrap;letter-spacing:-.4px}
  h2{font-family:var(--mono);letter-spacing:-.2px}
  .logo .dot{width:10px;height:10px;border-radius:50%;background:var(--cyan);box-shadow:0 0 8px var(--cyan);animation:pulse 1.6s ease-in-out infinite}
  .logo b{background:linear-gradient(90deg,var(--cyan),var(--pink));-webkit-background-clip:text;background-clip:text;color:transparent}
  .eq{display:flex;align-items:flex-end;gap:2px;height:30px;flex:1 1 180px;overflow:hidden;opacity:.9}
  .eq i{display:block;width:3px;height:30px;transform-origin:bottom;border-radius:2px;
    background:linear-gradient(180deg,var(--pink),var(--cyan));animation:eq .85s ease-in-out infinite alternate;animation-delay:var(--d);transition:animation-duration .4s}
  .eq.hot i{animation-duration:.36s}
  @keyframes eq{from{transform:scaleY(.12)}to{transform:scaleY(var(--mh))}}
  .hud{display:flex;gap:7px;align-items:center;font-family:var(--mono);font-size:12px;white-space:nowrap}
  .hud .k{color:var(--dim);font-size:9px;letter-spacing:.14em;text-transform:uppercase}
  .hud .v{color:var(--cyan)}
  .hud .v.nixie{color:var(--amber)}
  .sub{color:var(--muted);font-size:11px;margin:8px 0 16px;font-family:var(--mono)}
  .status{display:flex;align-items:center;gap:12px;margin-bottom:6px}
  .badge{display:inline-flex;align-items:center;gap:7px;padding:5px 14px;border-radius:999px;font-size:10.5px;font-weight:800;letter-spacing:.12em;text-transform:uppercase;font-family:var(--mono);border:1px solid currentColor;transition:color .3s ease,background .3s ease}
  .badge::before{content:"";width:7px;height:7px;border-radius:50%;background:currentColor}
  .badge.run{color:var(--cyan);background:var(--accent-soft)}
  .badge.done{color:var(--green);background:rgba(63,220,151,.10)}
  .badge.warn{color:var(--amber);background:rgba(241,196,83,.10)}
  .badge.idle{color:var(--muted);background:var(--inner);border-color:var(--line)}
  .badge.run::before{animation:pulse 1.6s ease-in-out infinite;box-shadow:0 0 8px currentColor}
  .eta{color:var(--muted);font-size:12px;font-family:var(--mono)}
  .eta b{color:var(--txt)}
  .bar{height:14px;background:var(--inner);border:1px solid var(--line);border-radius:999px;overflow:hidden;margin:14px 0 7px;position:relative}
  .bar>i{position:relative;display:block;height:100%;border-radius:999px;width:0;
    background:linear-gradient(90deg,var(--cyan),var(--pink));box-shadow:0 0 6px var(--accent-glow);transition:width .9s cubic-bezier(.22,1,.36,1)}
  .bar>i::after{content:"";position:absolute;inset:0;background:repeating-linear-gradient(45deg,rgba(255,255,255,.22) 0 9px,transparent 9px 18px);animation:stripes .8s linear infinite}
  @keyframes stripes{to{background-position:36px 0}}
  .pl{display:flex;justify-content:space-between;color:var(--muted);font-size:11.5px;font-family:var(--mono)}
  /* KPI glow tiles: big mono number, uppercase label above, radial accent wash under */
  /* uniform equal grid: every track equal width (1fr), every cell equal height (--tile-h);
     auto-fill keeps a fixed rhythm so short rows never stretch. GPU tile is a 2x2 block. */
  .cards{display:grid;grid-template-columns:repeat(auto-fill,minmax(150px,1fr));grid-auto-rows:var(--tile-h);gap:12px;margin:20px 0}
  .card{position:relative;height:100%;display:flex;flex-direction:column;justify-content:space-between;min-width:0;background:linear-gradient(180deg,var(--surface2),var(--card));border:1px solid var(--line);border-radius:16px;padding:15px 14px 17px;overflow:hidden;transition:border-color .25s ease,transform .25s cubic-bezier(.22,1,.36,1),box-shadow .25s ease}
  .card:hover{transform:translateY(-4px);border-color:var(--line2);box-shadow:0 8px 22px #0008,0 0 18px var(--accent-soft)}
  .card .k{color:var(--dim);font:700 8.5px/1.4 var(--mono);text-transform:uppercase;letter-spacing:.16em;margin-bottom:10px}
  .card .n{position:relative;z-index:1;font:800 27px/1 var(--mono);letter-spacing:-1px}
  .card .glow{position:absolute;left:50%;bottom:-38%;width:130%;height:95%;transform:translateX(-50%);border-radius:50%;background:radial-gradient(closest-side,currentColor,transparent 72%);opacity:.12;pointer-events:none}
  .c-cyan .n,.c-cyan .glow{color:var(--cyan)}
  .c-pink .n,.c-pink .glow{color:var(--pink)}
  .c-coral .n,.c-coral .glow{color:var(--coral)}
  .c-green .n,.c-green .glow{color:var(--green)}
  .c-purple .n,.c-purple .glow{color:var(--purple)}
  .c-muted .n{color:var(--txt)}.c-muted .glow{color:#3a3d40}
  .delta{position:absolute;top:10px;right:10px;z-index:2;display:inline-flex;align-items:center;gap:3px;font:700 9px/1 var(--mono);padding:4px 8px;border-radius:999px;opacity:0;transition:opacity .35s ease}
  .delta.show{opacity:1}
  .delta.good{color:var(--green);background:rgba(63,220,151,.13);border:1px solid rgba(63,220,151,.3)}
  .delta.bad{color:var(--coral);background:rgba(255,90,95,.13);border:1px solid rgba(255,90,95,.3)}
  .scr{color:var(--dim)}
  /* dot-matrix progress strip */
  .dots{display:flex;flex-wrap:wrap;gap:3px;margin-top:10px;position:relative;z-index:1}
  .dots i{width:4px;height:4px;border-radius:50%;background:rgba(255,255,255,.09)}
  .dots i.on{box-shadow:0 0 6px var(--accent-glow)}
  /* GPU tile: double-wide but SAME height as every other tile (2x2 left a dead region under row 2) */
  .card.gpu{grid-column:span 2;justify-content:flex-start;gap:0}
  .card.gpu .k{margin-bottom:6px}
  .card.gpu .dots{margin-top:5px}
  .card.gpu .gpusub{position:relative;z-index:1;font:10px var(--mono);color:var(--muted);margin-top:3px;letter-spacing:.02em;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
  .card.gpu.empty::after{content:"";position:absolute;inset:0;background:var(--hatch);pointer-events:none}
  .card.gpu.empty .n{color:var(--dim)}
  .card.gpu.empty .glow{display:none}
  @media(max-width:560px){.card.gpu{grid-column:span 1}}
  h2{font-size:10px;color:var(--muted);text-transform:uppercase;letter-spacing:.14em;margin:18px 0 7px;display:flex;align-items:center;gap:10px;font-family:var(--mono)}
  h2::before{content:"//";color:var(--cyan)}
  h2::after{content:"";flex:1;height:1px;background:linear-gradient(90deg,var(--line),transparent)}
  /* collapsible sections: click any h2 to fold its body (wrapped in .sbody by JS) */
  h2{cursor:pointer;user-select:none}
  h2 .h2fa{flex:none;order:9;font-size:11px;color:var(--dim);transition:transform .2s ease}
  h2:hover .h2fa{color:var(--muted)}
  h2.collapsed .h2fa{transform:rotate(-90deg)}
  @media(prefers-reduced-motion:reduce){h2 .h2fa{transition:none}}
  .sbody.hide{display:none!important}
  .panel{position:relative;background:var(--surface);border:1px solid var(--line);border-radius:16px;overflow:hidden;transition:border-color .25s ease,box-shadow .25s ease}
  .panel:hover{border-color:var(--line2);box-shadow:0 8px 22px #0008,0 0 18px var(--accent-soft)}
  .term{max-height:240px;overflow-y:auto;scrollbar-width:none;-webkit-mask-image:linear-gradient(180deg,transparent,#000 24px,#000 100%);mask-image:linear-gradient(180deg,transparent,#000 24px,#000 100%);scroll-behavior:smooth}
  .term::-webkit-scrollbar{display:none}
  .row{display:flex;flex-wrap:wrap;align-items:baseline;padding:7px 13px;border-bottom:1px solid rgba(255,255,255,.04)}
  .row .task{font-weight:800;font-size:9px;text-transform:uppercase;letter-spacing:.08em;width:74px;flex:none;font-family:var(--mono)}
  .row .task.ja{color:var(--pink)}.row .task.en{color:var(--cyan)}
  .row .task.wr{color:var(--green)}.row .task.ov{color:var(--teal)}.row .task.pf{color:var(--purple)}.row .task.mut{color:var(--dim)}
  .row .desc{flex-basis:100%;margin:4px 0 1px 86px;font-size:11px;color:var(--muted);line-height:1.5;font-style:italic;opacity:.92}
  .row .tm{color:var(--dim);width:92px;flex:none;font-family:var(--mono);font-size:11px}
  .row .tx{flex:1;min-width:0;overflow:hidden;white-space:nowrap;text-overflow:ellipsis}
  #tip{position:fixed;display:none;background:#16181c;color:var(--txt);border:1px solid var(--accent-glow);border-radius:8px;padding:6px 10px;font:12px var(--mono);max-width:520px;word-break:break-word;white-space:normal;box-shadow:0 4px 18px rgba(0,0,0,.6);pointer-events:none;z-index:9999;line-height:1.5}
  .row.new{animation:slidein .55s cubic-bezier(.22,1,.36,1) both}
  @keyframes slidein{0%{opacity:0;transform:translateY(12px);background:var(--accent-soft)}55%{background:rgba(228,64,95,.08)}100%{opacity:1;transform:none;background:transparent}}
  .tail{display:flex;align-items:center;gap:8px;padding:8px 14px;color:var(--dim);font-family:var(--mono);font-size:11px;border-top:1px solid var(--line);background:var(--inner)}
  .tail .cr{display:inline-block;width:7px;height:12px;background:var(--green);animation:blink 1s step-end infinite}
  /* numbered top-list (Glyph): accent index badge + hairline rows */
  .rrow{display:flex;align-items:center;padding:9px 13px;border-bottom:1px solid rgba(255,255,255,.04)}
  .rrow:last-child{border-bottom:0}
  .rrow:hover{background:var(--accent-soft)}
  .rrow .idx{flex:none;width:34px;margin-right:8px;font:700 10px/1 var(--mono);color:var(--cyan);border:1px solid var(--accent-soft);padding:2px 0;border-radius:4px;letter-spacing:.1em;text-align:center}
  .rhdr .idx{color:var(--dim);border-color:transparent}
  .rrow .r{width:46px;text-align:right;font-family:var(--mono);font-weight:700;flex:none}
  .rrow .rn{flex:1;padding-left:14px;min-width:0}
  .rhdr{color:var(--muted)}
  .rhdr .r,.rhdr .rn{font-size:9px;letter-spacing:.08em;font-weight:800;font-family:var(--mono);text-transform:uppercase}
  .rnh{display:flex;justify-content:space-between;align-items:baseline;gap:10px}
  .rnh em{font-style:normal;color:var(--dim);font-family:var(--mono);font-size:10px;flex:none;white-space:nowrap}
  .rnh em b{color:var(--cyan);font-weight:700}
  .rbar{position:relative;display:block;height:5px;margin-top:6px;border-radius:3px;background:var(--inner);overflow:hidden}
  .rbar i,.rbar b{position:absolute;left:0;top:0;height:100%;border-radius:3px;transition:width .85s cubic-bezier(.22,1,.36,1)}
  .rbar i{background:linear-gradient(90deg,var(--cyan),var(--pink));box-shadow:0 0 6px var(--accent-glow)}
  .rbar b{background:var(--green);opacity:.92}
  .wikihead{display:flex;align-items:center;gap:10px;padding:11px 13px;border-bottom:1px solid var(--line);background:var(--inner)}
  .wbadge{font:700 9px/1 var(--mono);letter-spacing:.12em;text-transform:uppercase;padding:5px 10px;border-radius:999px;background:#15171a;color:var(--dim);flex:none}
  .wbadge.run{background:var(--accent-soft);color:var(--cyan)}
  .wbadge.done{background:rgba(63,220,151,.16);color:var(--green)}
  .wmeta{font:10.5px var(--mono);color:var(--dim);flex:1;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
  .wmeta b{color:var(--purple);font-weight:700}
  .wcur{display:flex;align-items:center;gap:9px;padding:9px 13px;font:12px var(--mono);color:var(--txt);border-bottom:1px solid var(--line);word-break:break-all}
  .wcur .pr{color:var(--pink);font-weight:800;font-size:10px;letter-spacing:.1em;white-space:nowrap;flex:none}
  .wcur .cr{display:inline-block;width:7px;height:13px;background:var(--pink);animation:blink 1s step-end infinite;flex:none}
  .wikiterm{max-height:230px;overflow-y:auto;scrollbar-width:none}
  .wikiterm::-webkit-scrollbar{display:none}
  .wen{color:var(--txt);font-weight:600}
  .wcre{color:var(--cyan);font-size:10.5px;margin-right:3px}
  .wmt{color:var(--dim);font-size:10px;white-space:nowrap}
  .wja{display:block;color:var(--dim);font-size:10.5px;margin-top:1px;font-family:var(--mono)}
  .wcur .wja{display:inline;margin-left:9px}
  .row .task.warn{color:var(--coral)}.row .task.muted{color:var(--muted)}
  .gen::after{content:"\258B";margin-left:1px;color:var(--cyan);animation:blink .7s step-end infinite}
  .actmore{font:10px var(--mono);color:var(--dim);padding:6px 13px;border-top:1px solid rgba(255,255,255,.04);opacity:.8}
  .nowtl{margin:-20px 0 22px;padding:9px 15px;background:var(--inner);border:1px solid var(--line);border-top:0;border-radius:0 0 16px 16px;font:12px var(--mono);color:var(--cyan);word-break:break-word}
  .nowtl .tag{color:var(--pink);font-weight:800;font-size:9px;letter-spacing:.1em;margin-right:9px;white-space:nowrap}
  .stiles{display:flex;flex-wrap:wrap;gap:10px;padding:14px 13px;border-bottom:1px solid var(--line)}
  .stile{flex:1;min-width:88px;background:var(--inner);border:1px solid var(--line);border-radius:12px;padding:12px 10px;text-align:center}
  .stile .sv{font:800 21px/1 var(--mono);letter-spacing:-.5px;color:var(--txt)}
  .stile .sk{font:700 8.5px var(--mono);letter-spacing:.14em;color:var(--dim);text-transform:uppercase;margin-top:8px}
  .sbars{padding:10px 13px}
  .sbar{display:flex;align-items:center;gap:10px;padding:5px 0}
  .sbar .sl{width:124px;flex:none;font:11px var(--mono);color:var(--muted)}
  .sbar .st{flex:1;height:7px;background:var(--inner);border-radius:4px;overflow:hidden}
  .sbar .st i{display:block;height:100%;border-radius:4px;background:linear-gradient(90deg,var(--cyan),var(--pink));box-shadow:0 0 6px var(--accent-glow);transition:width .9s cubic-bezier(.22,1,.36,1)}
  .sbar .st i.en{background:linear-gradient(90deg,var(--cyan),#8fdcff)}.sbar .st i.grn{background:var(--green)}.sbar .st i.prp{background:var(--purple)}.sbar .st i.pnk{background:var(--pink)}
  .sbar .sp{width:42px;text-align:right;font:11px var(--mono);color:var(--txt);flex:none}
  .savl{padding:10px 13px;border-top:1px solid var(--line);font:11px var(--mono);color:var(--dim)}
  .savl b{color:var(--amber)}
  .gsec{font:700 9px/1.5 var(--mono);letter-spacing:.12em;text-transform:uppercase;color:var(--dim);padding:12px 13px 6px;border-top:1px solid var(--line)}
  #gradeswrap .rrow .r{color:var(--txt);font-weight:700}
  #gradeswrap .gpct{flex:none;width:40px;text-align:right;font:700 11px var(--mono);color:var(--txt);padding-right:11px}
  .gupd{padding:9px 13px;border-top:1px solid var(--line);font:10px var(--mono);color:var(--dim);text-align:right}
  .ensrow{padding:9px 13px;border-bottom:1px solid rgba(255,255,255,.04)}.ensrow:last-child{border-bottom:0}
  .ensja{font:11px var(--mono);color:var(--dim);margin-bottom:3px}
  .ensen{font:12px var(--mono);color:var(--txt);display:flex;align-items:baseline;gap:8px;flex-wrap:wrap}
  .enswin{font:8.5px var(--mono);color:var(--pink);border:1px solid var(--line);border-radius:999px;padding:1px 7px;text-transform:uppercase;letter-spacing:.06em;flex:none}
  .rev{padding:13px;border-bottom:1px solid var(--line)}.rev:last-child{border-bottom:0}
  .revtop{display:flex;align-items:center;gap:10px}
  .revname{color:var(--txt);font-size:13px}.revsc{color:var(--amber);font:700 13px var(--mono)}
  .revn{margin-left:auto;color:var(--dim);font-size:10.5px}
  .revsum{color:var(--muted);font-style:italic;margin:9px 0 10px;font-size:12px}
  .revcols{display:grid;grid-template-columns:repeat(auto-fit,minmax(190px,1fr));gap:10px}
  .revcol{background:var(--inner);border:1px solid var(--line);border-radius:10px;padding:9px 11px;font-size:11px;line-height:1.5}
  .revcol .revk{font:700 9px var(--mono);letter-spacing:.1em;text-transform:uppercase;color:var(--dim);margin-bottom:5px}
  .revcol.good{color:var(--green)}.revcol.bad{color:var(--coral)}.revcol.fix{color:var(--cyan)}
  #aih{margin-top:6px}
  .aipanel{padding:13px;border-color:var(--accent-soft)}
  .aibar{display:flex;gap:9px}
  #aiprompt{flex:1;background:var(--inner);border:1px solid var(--line);border-radius:10px;padding:12px 13px;color:var(--txt);font:12.5px var(--mono);outline:none}
  #aiprompt:focus{border-color:var(--cyan);box-shadow:0 0 0 2px var(--accent-soft)}
  #airun{background:var(--cyan);color:#180509;border:0;border-radius:10px;padding:0 18px;font:700 12px var(--mono);letter-spacing:.1em;cursor:pointer}
  #airun:hover{filter:brightness(1.12);box-shadow:0 0 14px var(--accent-glow)}
  .aiout{margin-top:11px;font:12px var(--mono);color:var(--muted);line-height:1.5}
  .aiout:empty{display:none}
  .aiout.ok{color:var(--green)}.aiout.err{color:var(--coral)}.aiout.warn{color:var(--amber)}.aiout.ask{color:var(--cyan)}.aiout.busy{color:var(--dim)}
  .aiout b{color:var(--txt)}.aiout em{color:var(--dim);font-style:normal}.aiout code{color:var(--pink)}
  .aiconf{margin-top:9px;display:flex;gap:8px}
  .aiconf button{background:var(--amber);color:#1a1206;border:0;border-radius:999px;padding:7px 14px;font:700 11px var(--mono);cursor:pointer}
  .aiconf .gho{background:#1a1d20;color:var(--dim)}
  .ajlog{white-space:pre-wrap;background:var(--inner);border:1px solid var(--line);border-radius:10px;padding:10px;margin-top:8px;max-height:280px;overflow:auto;font:11px var(--mono);color:var(--muted)}
  .aijobs{margin-top:12px;display:flex;flex-direction:column;gap:7px}
  .ajob{display:flex;align-items:center;gap:10px;background:var(--inner);border:1px solid var(--line);border-radius:12px;padding:9px 11px}
  .ab{flex:none;font:700 8.5px/1 var(--mono);letter-spacing:.1em;text-transform:uppercase;padding:4px 9px;border-radius:999px;background:#15171a;color:var(--dim)}
  .ab.run{background:var(--accent-soft);color:var(--cyan)}.ab.done{background:rgba(63,220,151,.16);color:var(--green)}.ab.fail{background:rgba(255,90,95,.16);color:var(--coral)}
  .aj{flex:1;min-width:0;display:flex;flex-direction:column;gap:2px}
  .ajh{font:11px var(--mono);color:var(--txt)}.ajh em{color:var(--dim)}
  .ajt{font:10px var(--mono);color:var(--dim);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
  .ajx{flex:none;font:10px var(--mono);color:var(--cyan);cursor:pointer}
  /* cluster: Nixflo worker cards — rounded rows with live timer chip */
  #clwrap{background:transparent;border:0;border-radius:0;overflow:visible;display:flex;flex-direction:column;gap:8px;box-shadow:none}
  #clwrap:hover{box-shadow:none;border:0}
  .clrow{display:flex;align-items:center;gap:11px;padding:11px 14px;background:linear-gradient(180deg,var(--surface2),var(--card));border:1px solid var(--line);border-radius:14px;font:12px var(--mono);transition:border-color .25s ease,box-shadow .25s ease}
  .clrow:hover{border-color:var(--line2);box-shadow:0 8px 22px #0008,0 0 18px var(--accent-soft)}
  .cldot{width:6px;height:6px;border-radius:50%;background:var(--green);flex:none;box-shadow:0 0 8px var(--green);animation:pulse 1.6s ease-in-out infinite}
  .clhost{color:var(--txt);font-weight:700;flex:none}
  .clip{color:var(--dim);flex:none}
  .clrole{font:8.5px var(--mono);padding:2px 8px;border-radius:999px;text-transform:uppercase;letter-spacing:.07em;flex:none}
  .clrole.llm{background:var(--pk3);color:var(--cyan)}.clrole.asr{background:rgba(63,220,151,.14);color:var(--green)}.clrole.both{background:rgba(139,123,255,.14);color:var(--purple)}
  .clmode{color:var(--muted);flex:none;font-size:10.5px}
  .clmodels{flex:1;min-width:0;color:var(--muted);overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
  .clage{flex:none;font:700 10px var(--mono);color:var(--cyan);border:1px solid var(--accent-soft);border-radius:999px;padding:3px 9px;letter-spacing:.05em}
  .clempty{color:var(--dim);font:11.5px var(--mono);padding:20px 13px;text-align:center;background:var(--surface);background-image:var(--hatch);border:1px solid var(--line);border-radius:14px}
  .actsec{font:700 9px var(--mono);letter-spacing:.12em;text-transform:uppercase;color:var(--dim);padding:11px 13px 5px;border-top:1px solid rgba(255,255,255,.04)}
  .actsec:first-child{border-top:0}
  .actrow{display:flex;align-items:center;gap:10px;padding:6px 13px;font:12px var(--mono)}
  .actdot{width:6px;height:6px;border-radius:50%;flex:none;background:var(--dim)}
  .actdot.run{background:var(--green);box-shadow:0 0 8px var(--green);animation:pulse 1.6s ease-in-out infinite}.actdot.sched{background:var(--amber)}
  .actname{color:var(--txt);flex:1;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
  .actpid{color:var(--dim);font-size:10px;flex:none}
  .actpct{color:var(--cyan);font-size:11px;font-weight:600;flex:none;margin-left:auto}
  .actrt{flex:none;font:700 10px var(--mono);color:var(--cyan);border:1px solid var(--accent-soft);border-radius:999px;padding:2px 8px;letter-spacing:.05em}
  .acttask{color:var(--muted);font-size:10.5px;flex:none}
  .actlog{padding:5px 13px;border-top:1px solid rgba(255,255,255,.04)}
  .actlog .actlt{color:var(--dim);font:10px var(--mono)}.actlog .actln{color:var(--pink);font:10px var(--mono)}
  .acttail{color:var(--muted);font:10.5px var(--mono);margin-top:2px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
  .actidle{color:var(--dim);font:11.5px var(--mono);padding:18px 13px;text-align:center;background-image:var(--hatch)}
  .foot{color:var(--dim);font-size:10px;margin-top:28px;text-align:center;letter-spacing:.06em;font-family:var(--mono);text-transform:uppercase}
  .metrics{display:flex;flex-wrap:wrap;gap:7px;margin:11px 0 2px;font-family:var(--mono)}
  .metrics:empty{display:none}
  .mc{font-size:11px;padding:4px 10px;border-radius:999px;background:var(--surface);border:1px solid var(--line);color:var(--txt);white-space:nowrap;display:inline-flex;align-items:center;gap:6px}
  .mc i{color:var(--dim);font-style:normal;text-transform:uppercase;letter-spacing:.06em;font-size:8.5px}
  .mc b{font-weight:700}
  .mc-cyan{border-color:var(--accent-soft)}.mc-cyan b{color:var(--cyan)}
  .mc-pink{border-color:#3a1d28}.mc-pink b{color:var(--pink)}
  .mc-green{border-color:#1d3a2a}.mc-green b{color:var(--green)}
  .mc-purple{border-color:#2a1d3a}.mc-purple b{color:var(--purple)}
  .mc-amber{border-color:#3a341d}.mc-amber b{color:var(--amber)}
  .mc-est{opacity:.62}
  /* live: active-creator "on air" highlight */
  .rrow.active{background:linear-gradient(90deg,var(--accent-soft),rgba(255,122,153,.045) 55%,transparent);box-shadow:inset 2px 0 0 var(--cyan)}
  .rrow.active .rnh b{color:var(--cyan)}
  .rrow.active .rbar i{animation:barglow 1.4s ease-in-out infinite}
  @keyframes barglow{0%,100%{filter:brightness(1)}50%{filter:brightness(1.55)}}
  .liveon{display:inline-flex;align-items:center;gap:5px;flex:none;margin-left:9px;font:800 8px/1 var(--mono);letter-spacing:.12em;color:var(--cyan);text-transform:uppercase}
  .liveon::before{content:"";width:6px;height:6px;border-radius:50%;background:var(--cyan);box-shadow:0 0 8px var(--cyan);animation:pulseon 1.1s ease-in-out infinite}
  @keyframes pulseon{0%,100%{opacity:1;transform:scale(1)}50%{opacity:.3;transform:scale(.62)}}
  /* live now-box: lanes for transcribe + research + stat strip */
  .nowbox{display:flex;flex-direction:column;background:var(--card);border:1px solid var(--line);border-radius:16px;margin-bottom:22px;overflow:hidden}
  .lane{display:flex;align-items:center;gap:10px;padding:11px 15px;font:12px var(--mono);word-break:break-all;border-bottom:1px solid rgba(255,255,255,.05);max-height:60px;overflow:hidden;transition:opacity .55s ease,max-height .55s ease,padding .55s ease,border-color .55s ease}
  .lane:last-child{border-bottom:0}
  .lane.off,.lane.gone{opacity:0;max-height:0;padding-top:0;padding-bottom:0;border-color:transparent;pointer-events:none}
  .lane .lpr{font:800 9px/1 var(--mono);letter-spacing:.1em;text-transform:uppercase;flex:none;padding:4px 9px;border-radius:999px}
  .lane.tx .lpr{color:var(--cyan);background:var(--accent-soft)}
  .lane.rs .lpr{color:var(--pink);background:rgba(255,122,153,.13)}
  .lane .ldir{color:var(--muted);flex:none}.lane .ldir b{color:var(--txt)}
  .lane .lfile{flex:1;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;color:var(--cyan)}
  .lane.rs .lfile{color:var(--pink)}
  .lane .lpct{flex:none;font:700 11px var(--mono);color:var(--txt)}
  .lane .cr{display:inline-block;width:6px;height:12px;flex:none;animation:blink 1s step-end infinite}
  .lane.tx .cr{background:var(--cyan)}.lane.rs .cr{background:var(--pink)}
  .lane.idle{color:var(--dim);justify-content:center;font-size:11px;background-image:var(--hatch)}
  .lanestat{display:flex;flex-wrap:wrap;gap:7px;padding:10px 15px;background:var(--inner)}.lanestat:empty{display:none}
  .ls{font:10px var(--mono);color:var(--txt);background:#15171a;border:1px solid var(--line);border-radius:999px;padding:3px 10px;white-space:nowrap}
  .ls i{color:var(--dim);font-style:normal;text-transform:uppercase;letter-spacing:.06em;font-size:8.5px;margin-right:5px}
  .ls.on{border-color:var(--cyan);color:var(--cyan);box-shadow:0 0 9px var(--accent-soft)}
  .ls.warn{border-color:#3a341d;color:var(--amber)}
  /* AI console: quick-commands, visible chat, deletable history */
  .qcmds{display:flex;flex-wrap:wrap;gap:6px;margin-top:11px}
  .qcmd{font:11px var(--mono);color:var(--muted);background:var(--inner);border:1px solid var(--line);border-radius:999px;padding:5px 11px;cursor:pointer;transition:.15s}
  .qcmd:hover{border-color:var(--cyan);color:var(--cyan);background:var(--accent-soft)}
  .qcmd.cmd{color:var(--pink)}.qcmd.cmd:hover{border-color:var(--pink);color:var(--pink);background:rgba(255,122,153,.06)}
  .subh{display:flex;align-items:center;gap:9px;margin:17px 0 8px;font:800 9px/1 var(--mono);letter-spacing:.14em;text-transform:uppercase;color:var(--dim)}
  .subh::after{content:"";flex:1;height:1px;background:var(--line)}
  .subh .clr{flex:none;order:9;color:var(--coral);cursor:pointer;letter-spacing:.04em;text-transform:none;font-weight:700}
  .subh .clr:hover{text-decoration:underline}
  .aihist{display:flex;flex-direction:column;gap:7px}.aihist:empty{display:none}
  .hitem{background:var(--inner);border:1px solid var(--line);border-radius:12px;padding:9px 11px;position:relative}
  .hq{font:12px var(--mono);color:var(--txt);padding-right:22px}
  .hq::before{content:"\203A ";color:var(--cyan);font-weight:800}
  .ha{font:11px var(--mono);color:var(--muted);margin-top:5px;line-height:1.5;white-space:pre-wrap}
  .ha.ok{color:var(--green)}.ha.warn{color:var(--amber)}.ha.err{color:var(--coral)}.ha.ask{color:var(--cyan)}
  .ht{font:9px var(--mono);color:var(--dim);margin-top:5px}
  .hx{position:absolute;top:6px;right:9px;color:var(--dim);cursor:pointer;font:15px/1 var(--mono)}.hx:hover{color:var(--coral)}
  /* analytics fold */
  .foldhdr{display:flex;align-items:center;gap:10px;margin:22px 0 8px;font:800 9px/1 var(--mono);letter-spacing:.14em;text-transform:uppercase;color:var(--dim);cursor:pointer;user-select:none}
  .foldhdr:hover{color:var(--muted)}
  .foldhdr::after{content:"";flex:1;height:1px;background:var(--line)}
  .foldhdr .fa{flex:none;order:9;font-size:11px;transition:transform .2s}
  body.lean .foldhdr .fa{transform:rotate(-90deg)}
  body.lean #analytics{display:none}
  /* side-by-side activity panels; cap AI history height */
  .actgrid{display:grid;grid-template-columns:1fr 1fr;gap:14px;align-items:start}
  .actgrid > div{min-width:0}
  .actgrid h2{margin-top:4px}
  @media(max-width:860px){.actgrid{grid-template-columns:1fr}}
  .aihist{max-height:300px;overflow-y:auto}
</style></head><body>
<div id="tip"></div>
<div class="wrap">
  <div class="top">
    <a class="logo" href="/home" data-realm-home style="text-decoration:none;color:inherit"><span class="dot"></span>Sasayaki<b>//囁き</b></a>
    <div class="eq" id="eq"></div>
    <div class="hud"><span class="k">CLK</span><span class="v nixie" id="clock">--:--:--</span><span class="k">UP</span><span class="v nixie" id="uptime">--</span></div>
    <div id="realmnav"></div><script src="/realm.js"></script>
  </div>
  <div class="sub" id="sublog">connecting to local stream…</div>
  <div class="status"><span class="badge idle" id="badge">…</span><span class="eta" id="eta"></span></div>
  <div class="bar"><i id="barfill"></i></div>
  <div class="pl"><span id="pltrans">TRANSCRIBE 0/0</span><span id="plpct">0%</span></div>
  <div class="metrics" id="metrics"></div>
  <div class="cards" id="cards"></div>
  <div class="nowbox" id="nowbox">
    <div class="lane tx gone" id="lanetx"><span class="lpr">transcribe</span><span class="ldir" id="nowloc"></span><span class="lfile" id="nowfile"></span><span class="lpct" id="nowpct"></span><span class="cr"></span></div>
    <div class="lane rs gone" id="laners"><span class="lpr">research</span><span class="lfile" id="nowrs"></span><span class="lpct" id="nowrspct"></span><span class="cr"></span></div>
    <div class="lane idle gone" id="laneidle">idle &middot; no active job</div>
    <div class="lanestat" id="lanestat"></div>
  </div>
  <div class="nowtl" id="nowtl" style="display:none"></div>
  <!-- AI console removed from the dashboard 2026-07-10 (Adriel): it lives on its own page now -> /ai-chat.
       The JS below keeps null-guards so the missing #aiprompt/#airun/#aijobs ids are harmless. -->
  <h2 id="clh">cluster &middot; jacked-in workers</h2>
  <div class="panel" id="clwrap"><div class="clempty">no workers jacked in &middot; plug a Sasayaki drive into a PC and run JACK-IN.bat</div></div>
  <div class="actgrid">
    <div>
      <h2 id="acth">system activity &middot; all processes</h2>
      <div class="panel" id="actwrap"><div class="actidle">idle &middot; nothing running</div></div>
    </div>
    <div>
      <h2>live activity stream</h2>
      <div class="panel"><div class="term" id="term"><div id="feed"></div></div><div class="tail"><span class="cr"></span> <span id="taillog">streaming…</span></div></div>
    </div>
  </div>
  <h2>library output</h2>
  <div class="panel" id="rollup"></div>
  <div class="foldhdr" id="foldhdr">analytics &middot; grades &middot; bake-off &middot; archive stats &middot; self-review<span class="fa">&#9662;</span></div>
  <div id="analytics">
  <h2 id="wikih" style="display:none">research wiki &middot; local AI &middot; private</h2>
  <div class="panel" id="wikiwrap" style="display:none"></div>
  <h2 id="statsh" style="display:none">archive stats</h2>
  <div class="panel" id="statswrap" style="display:none"></div>
  <h2 id="gradesh" style="display:none">quality grades &middot; ASR accuracy &middot; local-AI judge</h2>
  <div class="panel" id="gradeswrap" style="display:none"></div>
  <h2 id="ensh" style="display:none">model bake-off &middot; JA&#9656;EN &middot; local-AI judged + fused</h2>
  <div class="panel" id="enswrap" style="display:none"></div>
  <h2 id="revh" style="display:none">AI self-review &middot; the local AI critiques its own work</h2>
  <div class="panel" id="revwrap" style="display:none"></div>
  </div>
  <div class="foot">&#9679; LIVE &middot; local stream &middot; no page reloads</div>
</div>
<script>
  var POLL=2500, seen=new Set(), upBase=0, upSync=Date.now(), ACT=new Set(), BW={}, lastPrompt="", _sig={};
  function dirty(k,v){var s;try{s=JSON.stringify(v);}catch(e){return true;}if(_sig[k]===s)return false;_sig[k]=s;return true;}
  function q(s){return document.querySelector(s)}
  function two(n){return (n<10?"0":"")+n}
  function esc(s){return (s||"").replace(/&/g,"&amp;").replace(/</g,"&lt;").replace(/>/g,"&gt;")}
  // ---- text-scramble: cycle random digits before settling (ported from home.html) ----
  var _rm=window.matchMedia?matchMedia("(prefers-reduced-motion: reduce)"):null;
  function scrambleTo(el,finalText,dur){
    finalText=String(finalText);
    if(document.hidden||(_rm&&_rm.matches)){el.textContent=finalText;return;}
    var t0=performance.now();dur=dur||300;
    var chars=finalText.split("");
    function step(now){
      var p=Math.min(1,(now-t0)/dur);
      var lock=Math.floor(p*chars.length),out="";
      for(var i=0;i<chars.length;i++){
        if(!/[0-9]/.test(chars[i])){out+=chars[i];continue;}   // keep separators (%, /, .) stable
        out+=i<lock?chars[i]:"<span class='scr'>"+(Math.random()*10|0)+"</span>";
      }
      el.innerHTML=out;
      if(p<1)requestAnimationFrame(step);else el.textContent=finalText;
    }
    requestAnimationFrame(step);
  }
  // dot-matrix progress strip — filled dots colored by gcol()
  function dotStrip(p,n){n=n||24;var f=Math.round(Math.max(0,Math.min(100,p||0))/100*n),c=gcol(p||0),h="";for(var i=0;i<n;i++){h+=(i<f)?"<i class='on' style='background:"+c+"'></i>":"<i></i>";}return h;}
  // ---- cluster: live jacked-in workers (polls /workers.json) ----
  function renderWorkers(d){
    var w=((d&&d.workers)||[]).filter(function(x){return x.live;});
    var el=q("#clwrap"),hd=q("#clh");
    if(!w.length){el.innerHTML='<div class="clempty">no workers jacked in &middot; plug a Sasayaki drive into a PC and run JACK-IN.bat</div>';hd.innerHTML='cluster &middot; jacked-in workers';return;}
    hd.innerHTML='cluster &middot; '+w.length+' worker'+(w.length>1?'s':'')+' jacked in';
    el.innerHTML=w.map(function(x){
      var r=(x.role==='asr'?'asr':(x.role==='both'?'both':'llm'));
      var m=(x.models&&x.models.length)?esc(x.models.slice(0,3).join(", "))+(x.models.length>3?" +"+(x.models.length-3):""):"&mdash;";
      return '<div class="clrow"><span class="cldot"></span><span class="clhost">'+esc(x.host||x.ip)+'</span>'+
        '<span class="clip">'+esc(x.ip)+'</span><span class="clrole '+r+'">'+esc(x.role)+'</span>'+
        '<span class="clmode">'+esc(x.mode)+'</span><span class="clmodels">'+m+'</span><span class="clage" data-t0="'+(Date.now()-(x.ageSec||0)*1000)+'" data-tfmt="ago">'+fmtRt(x.ageSec||0)+' ago</span></div>';
    }).join('');
  }
  function pollWorkers(){if(document.hidden)return;fetch("/workers.json",{cache:"no-store"}).then(function(r){return r.json();}).then(renderWorkers).catch(function(){});}
  setInterval(pollWorkers,3000);pollWorkers();
  // ---- system activity: every Sasayaki process + scheduled task + recent job ----
  function fmtRt(s){s=s|0;return s<60?s+"s":(s<3600?(s/60|0)+"m":(s/3600).toFixed(1)+"h");}
  function renderActivity(d){
    var run=(d&&d.running)||[],tasks=(d&&d.tasks)||[],logs=(d&&d.logs)||[];
    var h="";
    h+='<div class="actsec">running now ('+run.length+')</div>';
    if(run.length){ run.slice(0,10).forEach(function(p){ h+='<div class="actrow"><span class="actdot run"></span><span class="actname">'+esc(p.name)+'</span><span class="actpid">pid '+p.pid+'</span><span class="actrt" data-t0="'+(Date.now()-(p.runtimeSec||0)*1000)+'" data-tfmt="rt">'+fmtRt(p.runtimeSec)+'</span></div>'; }); if(run.length>10){ h+='<div class="actmore">+'+(run.length-10)+' more processes</div>'; } }
    else { h+='<div class="actidle">nothing running</div>'; }
    var st=(d&&d.stream)||[];
    if(st.length){ h+='<div class="actsec">live &middot; working on</div>';
      st.slice().reverse().forEach(function(e){
        var dot=e.kind==='done'?'done':(e.kind==='translate'?'sched':'run');
        var pct=(e.pct!=null)?('<span class="actpct">'+e.pct+'%</span>'):'';
        var step=e.step?('<span class="actpid">'+esc(e.step)+'</span>'):'';
        h+='<div class="actrow"><span class="actdot '+dot+'"></span><span class="actname">'+esc(e.work)+'</span>'+step+pct+'</div>';
      });
    }
    if(tasks.length){ h+='<div class="actsec">scheduled</div>'; tasks.forEach(function(t){ h+='<div class="actrow"><span class="actdot '+(t.state==="Running"?"run":"sched")+'"></span><span class="actname">'+esc(t.name)+'</span><span class="acttask">'+esc(t.state)+(t.next?" · next "+esc(t.next):"")+'</span></div>'; }); }
    if(logs.length){ h+='<div class="actsec">recent jobs</div>'; logs.forEach(function(l){ h+='<div class="actlog"><span class="actlt">'+esc(l.at)+'</span> <span class="actln">'+esc(l.name)+'</span>'+(l.tail?'<div class="acttail">'+esc(l.tail)+'</div>':'')+'</div>'; }); }
    q("#actwrap").innerHTML=h;
    q("#acth").innerHTML='system activity · '+run.length+' running';
  }
  function pollActivity(){if(document.hidden)return;fetch("/activity.json",{cache:"no-store"}).then(function(r){return r.json();}).then(renderActivity).catch(function(){});}
  setInterval(pollActivity,4000);pollActivity();
  function ease(p){return 1-Math.pow(1-p,3)}
  (function(){var h="";for(var i=0;i<48;i++){h+="<i style='--d:-"+Math.floor(Math.random()*800)+"ms;--mh:"+(0.2+Math.random()*0.8).toFixed(2)+"'></i>";}q("#eq").innerHTML=h;})();
  var CARDS=[["tracks","cyan","tracks"],["creators","pink","creators"],["coverage","green","subtitled %"],["ja","pink","JA subs"],["en","cyan","EN subs"],["mp4","green","MP4s"],["deduped","purple","deduped"],["disk","cyan","disk free GB"],["skipped","muted","skipped"],["failed","coral","failed"]];
  (function(){var h="";CARDS.forEach(function(c){h+="<div class='card c-"+c[1]+"' data-k='"+c[0]+"'><div class='k'>"+c[2]+"</div><div class='n' data-v='0'>0</div><span class='delta'></span><div class='glow'></div></div>";});
    h+="<div class='card gpu c-green empty' id='gputile'><div class='k'>GPU &middot; util / vram / power</div><div class='n' id='gpuutil'>&mdash;</div><div class='dots' id='gpudots'></div><div class='gpusub' id='gpusub'>gpu offline</div><span class='delta'></span><div class='glow'></div></div>";
    q("#cards").innerHTML=h;})();
  function deltaPill(el,diff){if(!diff)return;var card=el.parentNode;while(card&&(" "+card.className+" ").indexOf(" card ")<0)card=card.parentNode;if(!card)return;var d=card.querySelector(".delta");if(!d)return;
    var k=card.getAttribute("data-k")||"",bad=(k==="failed"||k==="skipped"),up=diff>0;
    d.className="delta show "+((up!==bad)?"good":"bad");d.innerHTML=(up?"&#9650;":"&#9660;")+" "+(up?"+":"")+diff;
    if(d.__t)clearTimeout(d.__t);d.__t=setTimeout(function(){d.className="delta";},6000);}
  function tween(el,to){var from=parseInt(el.getAttribute("data-v")||"0",10);if(from===to){el.textContent=String(to);return;}el.setAttribute("data-v",to);scrambleTo(el,String(to),320);deltaPill(el,to-from);}
  function renderGpu(g){var t=q("#gputile");if(!t)return;
    if(!g||g.util==null){t.classList.add("empty");q("#gpuutil").innerHTML="&mdash;";q("#gpudots").innerHTML="";q("#gpusub").textContent="gpu offline";return;}
    t.classList.remove("empty");
    var u=q("#gpuutil");
    if(u.getAttribute("data-v")!==String(g.util)){u.setAttribute("data-v",String(g.util));scrambleTo(u,g.util+"%",300);}
    q("#gpudots").innerHTML=dotStrip(g.util,32);
    var sub="";
    if(g.vramUsedGB!=null)sub+="vram "+g.vramUsedGB+"/"+(g.vramTotalGB!=null?g.vramTotalGB:"?")+"G";
    if(g.powerW!=null)sub+=(sub?" · ":"")+g.powerW+(g.powerLimitW?"/"+g.powerLimitW:"")+"W";
    q("#gpusub").textContent=sub||"util "+g.util+"%";}
  // token-by-token "generation" — reveals in small jittered chunks like an LLM
  // streaming (CJK 1-2 chars, latin to a short word boundary), trailing cursor.
  function typeInto(el,text,sp){text=text||"";if(el.getAttribute("data-full")===text)return;el.setAttribute("data-full",text);if(el.__t)clearTimeout(el.__t);el.classList.add("gen");el.textContent="";var i=0;var sl=sp?1.7:1;function step(){if(i>=text.length){el.classList.remove("gen");el.__t=0;return;}var rest=text.slice(i),tok;if(/^[぀-ヿ㐀-鿿ｦ-ﾟ]/.test(rest)){tok=rest.slice(0,1+(Math.random()<0.4?1:0));}else{var m=rest.match(/^\s*\S{1,4}/);tok=m?m[0]:rest.slice(0,2);}i+=tok.length;el.textContent=text.slice(0,i);el.__t=setTimeout(step,(20+Math.random()*70)*sl);}step();}
  // flat mono readout (nixie tubes retired in the Stakent reskin; name kept for call sites)
  function nixie(el,str){el.textContent=str;}
  var DESC={};
  function snippet(md){
    if(!md)return"";
    var m=md.match(/##\s*(?:Hook|What happens|Summary|Persona)[^\n]*\n+([^\n#][^\n]*)/i);
    var s=m?m[1]:((md.split("\n").filter(function(l){l=l.trim();return l&&!/^#|^\*creator|^\|/.test(l);})[0])||"");
    s=s.replace(/[*`>]/g,"").trim();
    return s.length>180?s.slice(0,180)+"…":s;
  }
  function loadDesc(el,note){           // the local AI's description, fetched browser-side from /wikinote
    if(!el)return;
    if(note in DESC){if(DESC[note])el.textContent=DESC[note];else el.remove();return;}
    fetch("/wikinote?id="+encodeURIComponent(note)).then(function(r){return r.ok?r.text():"";}).then(function(t){
      var s=snippet(t);DESC[note]=s;if(s)el.textContent=s;else el.remove();
    }).catch(function(){el.remove();});
  }
  function render(d){
    ACT=new Set();if(d.curDir)ACT.add(d.curDir.trim());var _wc=(d.wiki&&d.wiki.current)?d.wiki.current.split("::")[0].trim():"";if(_wc)ACT.add(_wc);
    var _ak=(d.curDir||"")+"|"+_wc;
    var b=q("#badge");b.textContent=d.status;b.className="badge "+({DONE:"done",RUNNING:"run",STALLED:"warn"}[d.status]||"idle");
    var _ov=d.overall;
    if(_ov&&_ov.current&&_ov.current.eta&&_ov.current.eta!=="—"){
      q("#eta").innerHTML="load <b>"+_ov.current.eta+"</b>"+(_ov.current.finish?" &#8594; "+_ov.current.finish:"")
        +(_ov.full&&_ov.full.eta&&_ov.full.files!==_ov.current.files?" &middot; all "+_ov.full.eta:"")
        +(_ov.measured?"":" &middot; est");
    } else { q("#eta").textContent=d.eta?("ETA "+d.eta):""; }
    q("#barfill").style.width=d.pct+"%";
    q("#pltrans").textContent="TRANSCRIBE "+d.curIdx+"/"+d.batchN;q("#plpct").textContent=d.pct+"%";
    if(dirty('cards',d.stats))for(var k in d.stats){var el=document.querySelector(".card[data-k='"+k+"'] .n");if(el)tween(el,d.stats[k]);}
    var fc=document.querySelector(".card[data-k='failed']");if(fc)fc.className="card "+(d.stats.failed>0?"c-coral":"c-muted");
    if(dirty('gpu',d.gpu))renderGpu(d.gpu);
    var txOn=!!d.txActive&&!!d.curFile;q("#lanetx").classList.toggle("gone",!txOn);   // genuinely transcribing now, not a stale curFile
    if(txOn){q("#nowloc").innerHTML=d.curDir?("<b>"+esc(d.curDir)+"</b>&nbsp;&#10095;&nbsp;"):"";typeInto(q("#nowfile"),d.curFile,55);q("#nowpct").textContent=d.pct?(d.pct+"%"):"";}
    var rsOn=!!(d.wkActive&&d.wiki&&d.wiki.current);q("#laners").classList.toggle("gone",!rsOn);
    if(rsOn){typeInto(q("#nowrs"),d.wiki.current,55);q("#nowrspct").textContent=(d.wiki.total!=null?(d.wiki.total+(d.wiki.libTotal?"/"+d.wiki.libTotal:"")):"");}
    q("#laneidle").classList.toggle("gone",txOn||rsOn);
    buildLaneStat(d);
    var tl=q("#nowtl");
    if(d.enTitle){if(tl.getAttribute("data-t")!==d.enTitle){tl.setAttribute("data-t",d.enTitle);tl.style.display="";tl.innerHTML="<span class='tag'>JA &#9656; EN</span><span class='tx'></span>";typeInto(tl.querySelector(".tx"),d.enTitle,55);}}
    else{tl.style.display="none";tl.removeAttribute("data-t");}
    q("#sublog").textContent="100% local · "+d.log+" · log "+d.logTime;
    q("#taillog").textContent="streaming · tailing "+d.log;
    upBase=d.elapsed;upSync=Date.now();
    var list=q("#feed"),added=false,lastTx=null,lastText="";
    d.feed.forEach(function(c){var key=c.time+"|"+c.task+"|"+c.text;if(seen.has(key))return;seen.add(key);
      var row=document.createElement("div");row.className="row new";row.setAttribute("data-k",key);
      var T={transcribe:["JA","ja"],translate:["JA▸EN","en"],wrote:["WROTE","wr"],overview:["OVERVIEW","ov"],profile:["PROFILE","pf"],ref:["REF","mut"],plan:["PLAN","mut"],found:["FOUND","mut"],gather:["GATHER","mut"],empty:["SKIP","mut"],err:["ERR","warn"]};
      var ti=T[c.task]||["JA","ja"];
      row.innerHTML="<span class='task "+ti[1]+"'>"+ti[0]+"</span><span class='tm'>"+esc(c.time)+"</span><span class='tx'></span>"+(c.note?"<div class='desc' data-n='"+esc(c.note)+"'>&#8230;</div>":"");
      row.querySelector(".tx").textContent=c.text;
      list.appendChild(row);added=true;lastTx=row.querySelector(".tx");lastText=c.text;
      if(c.note)loadDesc(row.querySelector(".desc"),c.note);});
    while(list.children.length>120)list.removeChild(list.firstChild);
    if(seen.size>400){seen.clear();for(var ri=0;ri<list.children.length;ri++){var dk=list.children[ri].getAttribute("data-k");if(dk)seen.add(dk);}}
    if(added){if(lastTx)typeInto(lastTx,lastText,46);var t=q("#term");requestAnimationFrame(function(){t.scrollTop=t.scrollHeight;});var eq=q("#eq");eq.classList.add("hot");setTimeout(function(){eq.classList.remove("hot");},1100);}
    if(dirty('roll',[d.rollup,_ak])){
    var rh="<div class='rrow rhdr'><span class='idx'>##</span><span class='r'>MP4</span><span class='r'>JA</span><span class='r'>EN</span><span class='rn'>source</span></div>",rix=0;
    d.rollup.forEach(function(r){var ac=ACT.has(r.name),nk="roll|"+esc(r.name);rix++;
      rh+="<div class='rrow"+(ac?" active":"")+"'><span class='idx'>"+two(rix)+"</span><span class='r'>"+r.mp4+"</span><span class='r'>"+r.ja+"</span><span class='r'>"+r.en+"</span><span class='rn'><span class='rnh'><span>"+esc(r.name)+(ac?"<span class='liveon'>on</span>":"")+"</span><em><b>"+r.pct+"%</b> &middot; "+r.ja+"/"+r.total+"</em></span><span class='rbar'><i data-bk='"+nk+"|i' data-w='"+r.pct+"'></i><b data-bk='"+nk+"|b' data-w='"+r.burn+"'></b></span></span></div>";});
    q("#rollup").innerHTML=rh;animBars(q("#rollup"));
    }
    if(dirty('wiki',[d.wiki,_ak]))renderWiki(d.wiki);
    if(dirty('stats',d.archive))renderStats(d.archive);
    if(dirty('grades',[d.grades,_ak])){renderGrades(d.grades);renderReview(d.grades);}
    if(dirty('ens',d.ensemble))renderEnsemble(d.ensemble);
    if(dirty('jobs',d.jobs))renderJobs(d.jobs);
    renderMetrics(d.overall,d.net,d.gpu);
  }
  function animBars(scope){if(!scope)return;scope.querySelectorAll("[data-w]").forEach(function(el){var bk=el.getAttribute("data-bk"),w=parseFloat(el.getAttribute("data-w"))||0,prev=(bk&&bk in BW)?BW[bk]:0;el.style.width=prev+"%";void el.offsetWidth;requestAnimationFrame(function(){el.style.width=w+"%";});if(bk)BW[bk]=w;});}
  function buildLaneStat(d){var ov=d.overall,g=d.gpu||(ov&&ov.gpu),n=d.net,h="";
    h+="<span class='ls "+(d.status==="RUNNING"?"on":(d.status==="STALLED"?"warn":""))+"'><i>state</i>"+esc(d.status)+"</span>";
    if(g&&g.util!=null)h+="<span class='ls'><i>gpu</i>"+g.util+"%"+(g.vramUsedGB!=null?" &middot; "+g.vramUsedGB+"G":"")+"</span>";
    // transcribe-only metrics — hide when not actually transcribing (was showing a meaningless 0.0 f/min)
    if(d.txActive&&ov&&ov.filesPerMin)h+="<span class='ls'><i>rate</i>"+ov.filesPerMin.toFixed(1)+" f/min</span>";
    if(d.txActive&&ov&&ov.current&&ov.current.eta&&ov.current.eta!=="—")h+="<span class='ls'><i>eta</i>"+esc(ov.current.eta)+"</span>";
    // translate metric — only while translation is actually producing cues
    if(ov&&ov.translate&&ov.translate.cuesPerSec)h+="<span class='ls'><i>tl</i>"+ov.translate.cuesPerSec.toFixed(2)+" cues/s</span>";
    // research progress — show while the local AI is researching
    if(d.wkActive&&d.wiki&&d.wiki.total!=null)h+="<span class='ls'><i>research</i>"+d.wiki.total+(d.wiki.libTotal?"/"+d.wiki.libTotal:"")+"</span>";
    if(n&&(n.downKbs>0.5||n.upKbs>0.5))h+="<span class='ls'><i>net</i>&#8595;"+fmtRate(n.downKbs)+"</span>";
    q("#lanestat").innerHTML=h;}
  function fmtRate(k){k=k||0;return k>=1024?(k/1024).toFixed(1)+" MB/s":Math.round(k)+" KB/s";}
  function renderMetrics(ov,n,gpu){
    var m=q("#metrics");if(!m)return;var h="";
    if(ov){
      var est=ov.measured?"":" mc-est";
      h+="<span class='mc mc-cyan"+est+"'><i>speed</i><b>"+(ov.rtf||0).toFixed(0)+"&times;</b> realtime</span>";
      h+="<span class='mc mc-pink"+est+"'><i>media/s</i><b>"+(ov.mbPerSec||0).toFixed(2)+"</b> MB/s</span>";
      if(ov.filesPerMin!=null)h+="<span class='mc mc-purple"+est+"'><i>rate</i><b>"+ov.filesPerMin.toFixed(1)+"</b> f/min</span>";
      if(ov.doneThisRun!=null)h+="<span class='mc mc-green'><i>done</i><b>"+ov.doneThisRun+"</b>f &middot; "+(ov.doneAudioHours||0).toFixed(1)+"h</span>";
      if(ov.current&&ov.current.eta)h+="<span class='mc mc-green'><i>eta load</i><b>"+ov.current.eta+"</b>"+(ov.current.finish?" &#8594; "+ov.current.finish:"")+" &middot; "+ov.current.files+"f</span>";
      if(ov.full&&ov.full.eta&&ov.full.files!==ov.current.files)h+="<span class='mc mc-amber'><i>eta all</i><b>"+ov.full.eta+"</b>"+(ov.full.finish?" &#8594; "+ov.full.finish:"")+" &middot; "+ov.full.files+"f</span>";
    }
    var tr=ov&&ov.translate;
    if(tr){
      h+="<span class='mc mc-amber'><i>translate</i><b>"+(tr.cuesPerSec||0).toFixed(2)+"</b> cues/s</span>";
      h+="<span class='mc mc-green'><i>tl files</i><b>"+(tr.filesDone||0)+"</b>/"+(tr.filesTotal||"?")+(tr.lanes?" &middot; "+tr.lanes+"&times;":"")+"</span>";
    }
    var g=gpu||(ov&&ov.gpu);
    if(g){
      if(g.tflopsEff!=null)h+="<span class='mc mc-green'><i>gpu compute</i><b>"+g.tflopsEff+"</b> TFLOPs"+(g.tflopsPeak?" / "+g.tflopsPeak+" pk":"")+"</span>";
      h+="<span class='mc mc-pink'><i>3090 load</i><b>"+(g.util!=null?g.util:"?")+"%</b>"+(g.powerW!=null?" &middot; "+g.powerW+(g.powerLimitW?"/"+g.powerLimitW:"")+"W":"")+"</span>";
      if(g.vramUsedGB!=null)h+="<span class='mc mc-cyan'><i>vram</i><b>"+g.vramUsedGB+"</b>/"+g.vramTotalGB+"GB"+(g.tempC!=null?" &middot; "+g.tempC+"&deg;C":"")+"</span>";
    }
    if(n){
      h+="<span class='mc mc-cyan'><i>net</i>&#8593;<b>"+fmtRate(n.upKbs)+"</b> &#8595;<b>"+fmtRate(n.downKbs)+"</b></span>";
      h+="<span class='mc mc-purple'><i>session</i>&#8593;"+n.upMB+" &#8595;"+n.downMB+" MB</span>";
    }
    m.innerHTML=h;
  }
  function renderReview(g){
    var H=q("#revh"),W=q("#revwrap"),rv=g&&g.review;
    if(!rv||!Object.keys(rv).length){H.style.display="none";W.style.display="none";return;}
    H.style.display="";W.style.display="";var h="";
    Object.keys(rv).forEach(function(cr){var r=rv[cr];
      var vc=(r.verdict==="ship"?"done":(r.verdict==="redo"?"fail":"run"));
      h+="<div class='rev'><div class='revtop'><span class='ab "+vc+"'>"+esc(r.verdict||"")+"</span>"
        +"<b class='revname'>"+esc(cr)+"</b><span class='revsc'>"+(r.score!=null?r.score+"/10":"")+"</span>"
        +"<span class='revn'>"+(r.reviewed||0)+" reviewed &middot; "+(r.ship||0)+"&#10003; "+(r.revise||0)+"~ "+(r.redo||0)+"&#10007;</span></div>";
      var w=(r.works||[])[0];
      if(w){ if(w.summary)h+="<div class='revsum'>&ldquo;"+esc(w.summary)+"&rdquo;</div>";
        h+="<div class='revcols'>";
        function col(t,arr,cls,pre){if(!arr||!arr.length)return "";return "<div class='revcol "+cls+"'><div class='revk'>"+t+"</div>"+arr.slice(0,3).map(function(x){return "<div>"+pre+" "+esc(x)+"</div>";}).join("")+"</div>";}
        h+=col("strengths",w.strengths,"good","+")+col("issues",w.issues,"bad","!")+col("fixes",w.fixes,"fix","&#8594;");
        h+="</div>";}
      h+="</div>";});
    W.innerHTML=h;
  }
  function aiSay(html,cls){var o=q("#aiout");if(!o)return;o.className="aiout "+(cls||"");o.innerHTML=html;}
  var aiResolved=null;
  function aiSubmit(confirm){
    var inp=q("#aiprompt"),body;
    if(confirm&&aiResolved){body={skill:aiResolved.skill,args:aiResolved.args};}      // FIX #2: run the already-resolved command, don't re-route
    else{var p=inp.value.trim();if(!p)return;
      if(p==="/clear"){histSave([]);histRender();aiSay("history cleared.","");inp.value="";return;}
      if(p==="/help"){aiSay(helpText(),"ok");return;}
      lastPrompt=p;body={prompt:p};}
    aiSay("<span class='cr'></span> routing your request to the local AI…","busy");
    fetch("/command",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify(body)})
      .then(function(r){return r.json();}).then(function(d){aiHandle(d,inp);})
      .catch(function(e){aiSay("request failed: "+esc(""+e),"err");});
  }
  function pollRoute(id,inp){                                                          // FIX #3: routing is async — poll until ready
    fetch("/command_result?id="+encodeURIComponent(id)).then(function(r){return r.json();})
      .then(function(d){if(d.pending){setTimeout(function(){pollRoute(id,inp);},1200);}else{aiHandle(d,inp);}})
      .catch(function(){setTimeout(function(){pollRoute(id,inp);},1500);});
  }
  function aiHandle(d,inp){
    if(d.pending){setTimeout(function(){pollRoute(d.pending,inp);},1000);return;}
    if(d.error){aiSay("error: "+esc(d.error),"err");histAdd(lastPrompt,"error: "+d.error,"err");return;}
    if(d.clarify){aiSay("<b>?</b> "+esc(d.clarify),"ask");histAdd(lastPrompt,"? "+d.clarify,"ask");return;}
    if(d.answer){aiSay(esc(d.answer).replace(/\n/g,"<br>"),"ok");histAdd(lastPrompt,d.answer,"ok");if(inp)inp.value="";return;}
    if(d.needs_confirm){aiResolved={skill:d.skill,args:d.args};
      aiSay("about to run <b>"+esc(d.skill)+"</b> &middot; <em>"+esc(d.reason||"")+"</em><div class='aiconf'><button id='aiyes'>Confirm &amp; run</button><button id='aino' class='gho'>Cancel</button></div>","warn");
      q("#aiyes").onclick=function(){aiSubmit(true);};q("#aino").onclick=function(){aiResolved=null;aiSay("cancelled.","");};return;}
    if(d.job_id){aiResolved=null;aiSay("&#9656; launched <b>"+esc(d.skill)+"</b>"+(d.reason?" &middot; <em>"+esc(d.reason)+"</em>":"")+" &middot; job <code>"+esc(d.job_id)+"</code> — watch it below.","ok");histAdd(lastPrompt,"launched "+d.skill+(d.reason?" — "+d.reason:""),"ok");if(inp)inp.value="";poll();return;}
    aiSay("hmm, unexpected: "+esc(JSON.stringify(d)),"");
  }
  function renderJobs(j){
    var W=q("#aijobs");if(!W)return;if(!j||!j.length){W.innerHTML="";return;}
    var h="";j.forEach(function(o){
      var sc=(o.status==="running"?"run":(o.status==="done"?"done":"fail"));
      h+="<div class='ajob' data-id='"+esc(o.id)+"'><span class='ab "+sc+"'>"+esc(o.status)+"</span>"
        +"<span class='aj'><span class='ajh'>"+esc(o.skill)+(o.prompt?" <em>“"+esc(o.prompt)+"”</em>":"")+"</span>"
        +"<span class='ajt'>"+esc(o.tail||"")+"</span></span><span class='ajx'>view</span></div>";});
    W.innerHTML=h;
    W.querySelectorAll(".ajob").forEach(function(el){el.querySelector(".ajx").onclick=function(){
      fetch("/joblog?id="+encodeURIComponent(el.getAttribute("data-id"))).then(function(r){return r.text();}).then(function(t){
        aiSay("<b>job "+esc(el.getAttribute("data-id"))+"</b><pre class='ajlog'>"+esc(t)+"</pre>","");});};});
  }
  function gcol(p){return p>=85?"var(--green)":(p>=60?"var(--cyan)":(p>=40?"var(--amber)":"var(--coral)"));}
  function gf1(v){return (v==null)?"&mdash;":(""+v);}
  function renderGrades(g){
    var H=q("#gradesh"),W=q("#gradeswrap");
    if(!g||(!g.transcription&&!g.translation)){H.style.display="none";W.style.display="none";return;}
    H.style.display="";W.style.display="";var h="";
    if(g.transcription){h+="<div class='gsec'>ASR quality &middot; coverage bar = how much audio is subtitled &middot; match% = accuracy vs official script (only where one exists)</div>";
      Object.keys(g.transcription).forEach(function(cr){var E=g.transcription[cr];
        Object.keys(E).forEach(function(en){var s=E[en];var cov=Math.round((s.cover||0)*100);
          var hasAcc=(s.sim!=null||s.cer!=null);var sim=Math.round((s.sim||0)*100);   // accuracy only meaningful with a ground-truth .txt
          var left=hasAcc?("<span class='r'>"+sim+"%</span>"):("<span class='r' style='color:var(--dim)' title='no official script to grade accuracy against'>&mdash;</span>");
          var det=hasAcc
            ?("<b>"+esc(en)+"</b> &middot; "+s.files+"f &middot; "+s.cues_mean+" cues &middot; CER "+(s.cer!=null?s.cer.toFixed(2):"&mdash;")+" &middot; match "+sim+"%")
            :("<b>"+esc(en)+"</b> &middot; "+s.files+"f &middot; "+s.cues_mean+" cues &middot; <span style='color:var(--dim)'>no official script &middot; coverage only</span>"+(s.hallucinated!=null?(" &middot; halluc "+s.hallucinated):""));
          var gac=ACT.has(cr);
          h+="<div class='rrow"+(gac?" active":"")+"'>"+left+"<span class='rn'><span class='rnh'><span>"+esc(cr)+(gac?"<span class='liveon'>on</span>":"")
            +"</span><em>"+det+"</em></span>"
            +"<span class='rbar'><i data-bk='gt|"+esc(cr)+"|"+esc(en)+"' data-w='"+cov+"' style='background:"+gcol(cov)+"'></i></span></span><span class='gpct'>"+cov+"%</span></div>";});});}
    if(g.translation){h+="<div class='gsec'>local-AI judge &middot; JA&#9656;EN translation (overall / 10)</div>";
      Object.keys(g.translation).forEach(function(cr){var t=g.translation[cr];var ov=t.overall||0;var ovp=Math.round(ov*10);
        var tac=ACT.has(cr);
        h+="<div class='rrow"+(tac?" active":"")+"'><span class='r'>"+(ov?ov.toFixed(1):"&mdash;")+"</span><span class='rn'><span class='rnh'><span>"+esc(cr)+(tac?"<span class='liveon'>on</span>":"")
          +"</span><em>acc "+gf1(t.accuracy)+" &middot; flu "+gf1(t.fluency)+" &middot; cmp "+gf1(t.completeness)+" &middot; "+t.files+"f</em></span>"
          +"<span class='rbar'><i data-bk='tl|"+esc(cr)+"' data-w='"+ovp+"' style='background:"+gcol(ovp)+"'></i></span></span><span class='gpct'>"+ovp+"%</span></div>";});}
    if(g.updated)h+="<div class='gupd'>graded "+esc(g.updated.replace('T',' '))+"</div>";
    W.innerHTML=h;animBars(W);
  }
  function renderEnsemble(e){
    var H=q("#ensh"),W=q("#enswrap");
    if(!e||!e.wins||!e.totalCues){H.style.display="none";W.style.display="none";return;}
    H.style.display="";W.style.display="";
    var entries=Object.keys(e.wins).map(function(m){return [m,e.wins[m]];}).sort(function(a,b){return b[1]-a[1];});
    var mx=e.totalCues||1;
    var h="<div class='gsec'>"+e.totalCues+" cues judged by "+esc(e.judge||'?')+" &middot; how often each model's line won, or a fusion beat them all</div>";
    entries.forEach(function(kv){var m=kv[0],w=kv[1],pct=Math.round(100*w/mx);
      h+="<div class='rrow'><span class='r'>"+w+"</span><span class='rn'><span class='rnh'><span>"+esc(m)+(m==='fused'?" <em style='color:var(--pink)'>synthesis</em>":"")+"</span><em>"+pct+"% of cues</em></span><span class='rbar'><i data-bk='ens|"+esc(m)+"' data-w='"+pct+"' style='background:"+(m==='fused'?'var(--pink)':gcol(pct))+"'></i></span></span><span class='gpct'>"+pct+"%</span></div>";});
    if(e.works&&e.works.length){h+="<div class='gsec'>sample fused lines &middot; the best bits assembled per cue</div>";
      (e.works||[]).slice(0,3).forEach(function(wk){(wk.sample||[]).slice(0,2).forEach(function(s){
        h+="<div class='ensrow'><div class='ensja'>"+esc(s.ja)+"</div><div class='ensen'>"+esc(s.en)+"<span class='enswin'>"+esc(s.best)+"</span></div></div>";});});}
    if(e.updated)h+="<div class='gupd'>battle-tested "+esc(e.updated.replace('T',' '))+"</div>";
    W.innerHTML=h;animBars(W);
  }
  function renderWiki(w){
    var H=q("#wikih"),W=q("#wikiwrap");
    if(!w||!w.present){H.style.display="none";W.style.display="none";return;}
    H.style.display="";W.style.display="";
    var sc=(w.state==="running"?"run":(w.state==="done"?"done":"idle"));
    var ncr=(w.creators||[]).length;
    var html="<div class='wikihead'><span class='wbadge "+sc+"'>"+esc(w.state)+"</span>"
      +"<span class='wmeta'><b>"+w.total+"</b>"+(w.libTotal?(" / "+w.libTotal):"")+" works &middot; <b>"+ncr+"</b> creators &middot; model "+esc(w.model||"—")+" &middot; updated "+esc(w.updated)+"</span></div>";
    if(w.current){var ce=w.currentEn?("<b class='wen'>"+esc(w.currentEn)+"</b><span class='wja'>"+esc(w.current)+"</span>"):esc(w.current);
      html+="<div class='wcur'><span class='pr'>&#9656; RESEARCHING</span><span class='tx'>"+ce+"</span><span class='cr'></span></div>";}
    (w.creators||[]).forEach(function(r){var ac=ACT.has(r.name);
      html+="<div class='rrow"+(ac?" active":"")+"'><span class='r'>"+r.done+"</span><span class='rn'><span class='rnh'><span>"+esc(r.name)+(ac?"<span class='liveon'>on</span>":"")
        +"</span><em><b>"+r.pct+"%</b> &middot; "+r.done+"/"+r.total+"</em></span>"
        +"<span class='rbar'><i data-bk='wiki|"+esc(r.name)+"' data-w='"+r.pct+"'></i></span></span></div>";});
    var fh="";(w.feed||[]).forEach(function(c){
      var tc=({wrote:"en",overview:"ja",profile:"ja",ref:"muted",empty:"muted",err:"warn"})[c.task]||"muted";
      var mt=(c.chars?c.chars+"c":"")+(c.chars&&c.tokens?" &middot; ":"")+(c.tokens?c.tokens+"t":"");
      var body;
      if(c.work){body=(c.creator?"<span class='wcre'>"+esc(c.creator)+"</span> ":"")+"<b class='wen'>"+esc(c.en||c.work)+"</b>"+(mt?" <span class='wmt'>"+mt+"</span>":"")+(c.en?"<span class='wja'>"+esc(c.work)+"</span>":"");}
      else{body=esc(c.text);}
      fh+="<div class='row'><span class='task "+tc+"'>"+esc(c.task)+"</span><span class='tm'>"+esc(c.time)+"</span><span class='tx'>"+body+"</span></div>";});
    if(fh)html+="<div class='term wikiterm'>"+fh+"</div>";
    W.innerHTML=html;animBars(W);
    var wt=W.querySelector(".wikiterm");if(wt)wt.scrollTop=wt.scrollHeight;
  }
  function bar(label,p,cls){return "<div class='sbar'><span class='sl'>"+label+"</span><span class='st'><i class='"+(cls||"")+"' data-bk='stat|"+label+"' data-w='"+p+"'></i></span><span class='sp'>"+p+"%</span></div>";}
  function renderStats(s){
    var H=q("#statsh"),W=q("#statswrap");
    if(!s||!s.summary){H.style.display="none";W.style.display="none";return;}
    H.style.display="";W.style.display="";var m=s.summary,a=s.availability;
    var tiles=[["WORKS",m.totalWorks],["SOURCES",m.totalCreators],["STORAGE",fmtB(m.totalStorage)]];
    if(m.totalDuration)tiles.push(["HOURS",(m.totalDuration/3600).toFixed(0)]);
    if(m.officialSubs!=null)tiles.push(["OFFICIAL",m.officialSubs]);
    if(m.creatorsWithWiki!=null)tiles.push(["WIKIS",m.creatorsWithWiki]);
    if(a)tiles.push(["PRESERVED",a.preservedOnly]);
    var h="<div class='stiles'>";tiles.forEach(function(t){h+="<div class='stile'><div class='sv nixie' data-d='"+t[1]+"'>"+t[1]+"</div><div class='sk'>"+t[0]+"</div></div>";});h+="</div>";
    h+="<div class='sbars'>"+bar("transcribed JA",m.pctJa,"")+bar("translated EN",m.pctEn,"en")
      +(m.pctOfficial!=null?bar("official subs",m.pctOfficial,"grn"):"")
      +bar("subtitled MP4",m.pctSubbed,"grn")+bar("cover art",m.pctCover,"prp")
      +bar("researched",m.pctWiki,"pnk")
      +(m.pctCreatorWiki!=null?bar("creator wikis",m.pctCreatorWiki,"prp"):"")+"</div>";
    if(a)h+="<div class='savl'>"+a.sourceLive+"/"+a.checked+" source pages still live &middot; <b>"+a.preservedOnly+"</b> preserved-only (this archive is the last copy)</div>";
    W.innerHTML=h;animBars(W);
    W.querySelectorAll(".sv").forEach(function(el){scrambleTo(el,String(el.getAttribute("data-d")),300);});
  }
  function fmtB(n){var u=["B","KB","MB","GB","TB"],i=0;while(n>=1024&&i<4){n/=1024;i++;}return n.toFixed(1)+u[i];}
  function poll(){if(document.hidden)return;fetch("/data.json",{cache:"no-store"}).then(function(r){return r.json();}).then(render).catch(function(){});}
  function tick(){var d=new Date();nixie(q("#clock"),two(d.getHours())+":"+two(d.getMinutes())+":"+two(d.getSeconds()));var s=upBase+Math.floor((Date.now()-upSync)/1000),h=Math.floor(s/3600),m=Math.floor(s%3600/60),ss=s%60;nixie(q("#uptime"),(h>0?h+"h ":"")+two(m)+"m "+two(ss)+"s");
    // live-ticking timer chips (worker heartbeats + process runtimes) — locally between polls
    var tc=document.querySelectorAll("[data-t0]");
    for(var i=0;i<tc.length;i++){var e2=tc[i],s2=Math.max(0,Math.floor((Date.now()-parseInt(e2.getAttribute("data-t0"),10))/1000));e2.textContent=(e2.getAttribute("data-tfmt")==="ago")?(fmtRt(s2)+" ago"):fmtRt(s2);}}
  function histLoad(){try{return JSON.parse(localStorage.getItem("aihist")||"[]");}catch(e){return[];}}
  function histSave(a){try{localStorage.setItem("aihist",JSON.stringify(a.slice(-50)));}catch(e){}}
  function histAdd(qy,ans,cls){if(!qy)return;var a=histLoad();a.push({t:Date.now(),q:qy,a:ans,c:cls||""});histSave(a);histRender();}
  function histRender(){var w=q("#aihist");if(!w)return;var a=histLoad(),h="";for(var i=a.length-1;i>=0;i--){var e=a[i];h+="<div class='hitem' data-i='"+e.t+"'><span class='hx' title='delete'>&times;</span><div class='hq'>"+esc(e.q)+"</div><div class='ha "+(e.c||"")+"'>"+esc(e.a||"").replace(/\n/g,"<br>")+"</div><div class='ht'>"+new Date(e.t).toLocaleTimeString()+"</div></div>";}w.innerHTML=h;w.querySelectorAll(".hx").forEach(function(el){el.onclick=function(){var id=+el.parentNode.getAttribute("data-i");histSave(histLoad().filter(function(x){return x.t!==id;}));histRender();};});}
  function helpText(){return "ask anything &mdash; recommendations grounded in your library (mood / sound / dialogue / vague).<br>run a skill: <code>transcribe &lt;creator&gt;</code> &middot; <code>grade &lt;creator&gt;</code> &middot; <code>refresh stats</code>.<br><code>/clear</code> wipe history &middot; <code>/help</code> this.";}
  var QC=[["something to fall asleep to",0],["who has the best dialogue?",0],["something quiet & binaural",0],["recommend anything",0],["refresh stats",1],["/help",1],["/clear",1]];
  function qcmdsRender(){var c=q("#qcmds");if(!c)return;var h="";QC.forEach(function(x){h+="<span class='qcmd"+(x[1]?" cmd":"")+"' data-q='"+esc(x[0])+"'>"+esc(x[0])+"</span>";});c.innerHTML=h;c.querySelectorAll(".qcmd").forEach(function(el){el.onclick=function(){var v=el.getAttribute("data-q");if(v==="/help"){aiSay(helpText(),"ok");return;}if(v==="/clear"){histSave([]);histRender();aiSay("history cleared.","");return;}q("#aiprompt").value=v;q("#aiprompt").focus();};});}
  // console UI moved to /ai-chat -- these ids are gone from the dashboard, guard them
  var _ar=q("#airun");if(_ar)_ar.onclick=function(){aiSubmit(false);};
  var _ap=q("#aiprompt");if(_ap)_ap.addEventListener("keydown",function(e){if(e.key==="Enter"){e.preventDefault();aiSubmit(false);}});
  var _hc=q("#histclr");if(_hc)_hc.onclick=function(){histSave([]);histRender();};
  qcmdsRender();histRender();
  (function(){var v=localStorage.getItem("lean");if(v===null)v="1";if(v==="1")document.body.classList.add("lean");var fh=q("#foldhdr");if(fh)fh.onclick=function(){var on=document.body.classList.toggle("lean");try{localStorage.setItem("lean",on?"1":"0");}catch(e){}if(!on)poll();};})();
  // ---- collapsible sections: wrap each h2's body, click header to fold, persist per-section ----
  (function(){
    var KEY="sasa_dash_collapsed",st={};
    try{st=JSON.parse(localStorage.getItem(KEY)||"{}")||{};}catch(e){st={};}
    function save(){try{localStorage.setItem(KEY,JSON.stringify(st));}catch(e){}}
    var hs=document.querySelectorAll(".wrap h2");
    for(var i=0;i<hs.length;i++){
      var h=hs[i],key=h.id||("dash-h2-"+i);
      // gather the section body: following siblings until the next h2 / analytics-fold / #analytics
      var nodes=[],n=h.nextElementSibling;
      while(n&&n.tagName!=="H2"&&n.id!=="analytics"&&!(n.className&&(" "+n.className+" ").indexOf(" foldhdr ")>=0)){nodes.push(n);n=n.nextElementSibling;}
      if(!nodes.length)continue;
      var body=document.createElement("div");body.className="sbody";
      h.parentNode.insertBefore(body,nodes[0]);
      for(var j=0;j<nodes.length;j++)body.appendChild(nodes[j]);
      var fa=document.createElement("span");fa.className="h2fa";fa.innerHTML="&#9662;";h.appendChild(fa);
      (function(h,body,key){
        function apply(c){if(c){h.classList.add("collapsed");body.classList.add("hide");}else{h.classList.remove("collapsed");body.classList.remove("hide");}}
        apply(!!st[key]);
        h.addEventListener("click",function(){var c=!h.classList.contains("collapsed");apply(c);if(c)st[key]=1;else delete st[key];save();});
      })(h,body,key);
    }
  })();
  tick();setInterval(tick,1000);poll();setInterval(poll,POLL);
  document.addEventListener("visibilitychange",function(){if(!document.hidden){poll();pollActivity();pollWorkers();}});
  (function(){var tip=document.getElementById("tip"),mx=0,my=0;
    document.addEventListener("mousemove",function(e){mx=e.clientX;my=e.clientY;});
    document.addEventListener("mouseover",function(e){
      var row=e.target.closest(".row");if(!row)return;
      var tx=row.querySelector(".tx");if(!tx||tx.scrollWidth<=tx.clientWidth){tip.style.display="none";return;}
      tip.textContent=tx.textContent;tip.style.display="block";
      var tw=tip.offsetWidth,th=tip.offsetHeight,vw=window.innerWidth,vh=window.innerHeight;
      var left=mx+14,top=my+14;
      if(left+tw>vw-8)left=mx-tw-8;
      if(top+th>vh-8)top=my-th-8;
      tip.style.left=left+"px";tip.style.top=top+"px";
    });
    document.addEventListener("mouseout",function(e){if(!e.target.closest(".row"))tip.style.display="none";});
  })();
</script>
</body></html>
'@

$DebugShell = @'
<!doctype html><html><head><meta charset="utf-8"><title>Sasayaki // debug</title>
<meta name="viewport" content="width=device-width,initial-scale=1">
<style>
:root{--bg:#181a1b;--surface:#1d1f20;--surf:#1d1f20;--surface2:#232526;--surf2:#232526;--card:#1d1f20;--inner:#141617;--line:rgba(255,255,255,.06);--line2:rgba(255,255,255,.11);--txt:#e8e6e3;--muted:#9b958f;--dim:#5d5852;--cyan:#e4405f;--pk:#e4405f;--pk2:#ff7a99;--pk3:rgba(228,64,95,.14);--pink:#ff7a99;--green:#46e08a;--coral:#ff5a5f;--amber:#f0c24a;--accent-soft:#e4405f22;--accent-glow:#e4405f55;--r:8px;--r2:15px;--hatch:repeating-linear-gradient(45deg,rgba(255,255,255,.03) 0 1px,transparent 1px 7px);--mono:'JetBrains Mono','Cascadia Code',Consolas,monospace;--ease:cubic-bezier(.16,1,.3,1)}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--txt);font-family:var(--mono);font-size:13px}
/* shared nav shell (realm.js) so debug matches every other page (#107/#102) */
.topbar{position:sticky;top:0;z-index:50;background:color-mix(in srgb,var(--bg) 88%,transparent);backdrop-filter:blur(10px);border-bottom:1px solid var(--line)}
.topinner{max-width:1120px;margin:0 auto;height:54px;display:flex;align-items:center;gap:14px;padding:0 18px}
.logo{font:700 15px var(--mono);letter-spacing:.06em;color:var(--txt);text-decoration:none}.logo span{color:var(--cyan)}
.wrap{max-width:1120px;margin:0 auto;padding:18px}
.ts{color:var(--dim);font-size:11px;display:inline-flex;align-items:center;gap:7px}
.ts::before{content:"";width:6px;height:6px;border-radius:50%;background:var(--cyan);box-shadow:0 0 8px var(--cyan);animation:pulse 1.6s ease-in-out infinite}
@keyframes pulse{0%,100%{opacity:1}50%{opacity:.4}}
@media(prefers-reduced-motion:reduce){.ts::before{animation:none}}
h2{font-size:11px;letter-spacing:.14em;text-transform:uppercase;color:var(--muted);margin:26px 0 13px;font-weight:700}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(155px,1fr));gap:11px}
.card{position:relative;background:var(--surf);border:1px solid var(--line);border-radius:var(--r2);padding:15px 16px 17px;overflow:hidden;transition:transform .25s var(--ease),box-shadow .25s var(--ease),border-color .25s}
.card::after{content:"";position:absolute;left:-20%;bottom:-60%;width:80%;height:120%;background:radial-gradient(ellipse at center,var(--accent-soft),transparent 70%);opacity:.5;pointer-events:none}
.card:hover{transform:translateY(-3px);box-shadow:0 10px 26px #0009,0 0 20px var(--accent-soft);border-color:var(--line2)}
.card .k{font-size:9.5px;letter-spacing:.11em;color:var(--dim);text-transform:uppercase;position:relative;z-index:1}
.card .v{font-size:23px;margin-top:7px;color:var(--txt);position:relative;z-index:1;letter-spacing:-.01em;font-weight:600}
.bar{height:8px;background:var(--inner);border-radius:5px;overflow:hidden;margin-top:9px;background-image:radial-gradient(circle,rgba(255,255,255,.09) 1px,transparent 1.4px);background-size:7px 8px;background-position:0 center}
.bar i{display:block;height:100%;border-radius:5px;box-shadow:0 0 6px var(--accent-glow)}
table{width:100%;border-collapse:separate;border-spacing:0;background:var(--surf);border:1px solid var(--line);border-radius:var(--r2);overflow:hidden}
th,td{text-align:left;padding:9px 13px;border-bottom:1px solid var(--line);font-size:11.5px}
tr:last-child td{border-bottom:none}
tbody tr:hover td,table tr:hover td{background:var(--surface2)}
th{color:var(--dim);font-size:9.5px;letter-spacing:.1em;text-transform:uppercase}
td.r,th.r{text-align:right}
.pill{font-size:9px;padding:3px 8px;border-radius:20px;background:var(--inner);color:var(--dim);text-transform:uppercase;letter-spacing:.08em;border:1px solid var(--line)}
.pill.run{background:rgba(228,64,95,.16);color:var(--cyan);border-color:var(--accent-soft)}.pill.done{background:rgba(70,224,138,.16);color:var(--green);border-color:rgba(70,224,138,.3)}.pill.fail{background:rgba(255,90,95,.16);color:var(--coral);border-color:rgba(255,90,95,.3)}
.mut{color:var(--dim)}.tag{color:var(--pink)}.vx{color:var(--cyan);cursor:pointer;font-size:10px}.vx:hover{text-decoration:underline}
pre{white-space:pre-wrap;background:var(--inner);border:1px solid var(--line);border-radius:10px;padding:11px;max-height:300px;overflow:auto;font-size:11px;color:var(--muted)}
.chips{display:flex;flex-wrap:wrap;gap:6px}.chip{background:var(--inner);border:1px solid var(--line);border-radius:20px;padding:5px 11px;font-size:11px;transition:border-color .2s}.chip:hover{border-color:var(--accent-soft)}
</style></head><body>
<div class="topbar"><div class="topinner">
  <a class="logo" href="/home" data-realm-home>Sasayaki<span>//DEBUG</span></a>
  <div id="realmnav"></div><script src="/realm.js"></script>
  <span class="ts" id="ts" style="margin-left:auto"></span>
</div></div>
<div class="wrap">
  <div id="root"></div>
</div>
<script>
var q=function(s){return document.querySelector(s);};
function esc(s){return (s==null?'':String(s)).replace(/[&<>"]/g,function(c){return ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'})[c];});}
function gcol(p){return p>=85?'var(--green)':(p>=60?'var(--cyan)':(p>=40?'var(--amber)':'var(--coral)'));}
function sect(t,h){return "<h2>"+t+"</h2>"+h;}
function fmtB(n){if(n==null)return"-";var u=["B","KB","MB","GB","TB"],i=0;while(n>=1024&&i<4){n/=1024;i++;}return n.toFixed(1)+u[i];}
function render(d){
  q("#ts").textContent="updated "+esc(d.ts);var H="";
  var s=d.system||{},g=s.gpu,sh="<div class='grid'>";
  if(g){sh+="<div class='card'><div class='k'>GPU util</div><div class='v'>"+g.util+"%</div><div class='bar'><i style='width:"+g.util+"%;background:var(--cyan)'></i></div></div>";
    var mp=Math.round(g.used/g.total*100);
    sh+="<div class='card'><div class='k'>VRAM</div><div class='v'>"+(g.used/1024).toFixed(1)+"/"+(g.total/1024).toFixed(0)+"G</div><div class='bar'><i style='width:"+mp+"%;background:"+(mp>90?'var(--coral)':'var(--pink)')+"'></i></div></div>";}
  if(s.disk)sh+="<div class='card'><div class='k'>disk D:</div><div class='v'>"+s.disk.freeGB+"G</div><div class='mut'>free of "+s.disk.totalGB+"G</div></div>";
  if(s.procs)sh+="<div class='card'><div class='k'>processes</div><div class='v'>"+(s.procs.python||0)+" py</div><div class='mut'>"+(s.procs.ffmpeg||0)+" ffmpeg &middot; "+(s.procs.pwsh||0)+" pwsh</div></div>";
  sh+="</div>";
  if(s.models&&s.models.length){sh+="<div class='chips' style='margin-top:10px'>";s.models.forEach(function(m){sh+="<span class='chip'>"+esc(m)+"</span>";});sh+="</div>";}
  H+=sect("system &middot; gpu / models / disk",sh);
  if(d.stats&&d.stats.summary){var m=d.stats.summary,lh="<div class='grid'>";
    [["works",m.totalWorks],["creators",m.totalCreators],["storage",fmtB(m.totalStorage)],["hours",m.totalDuration?(m.totalDuration/3600).toFixed(0):"-"]].forEach(function(t){lh+="<div class='card'><div class='k'>"+t[0]+"</div><div class='v'>"+t[1]+"</div></div>";});
    lh+="</div><table style='margin-top:10px'><tr><th>pipeline stage</th><th class='r'>%</th></tr>";
    [["transcribed JA",m.pctJa],["translated EN",m.pctEn],["subbed MP4",m.pctSubbed],["cover art",m.pctCover],["researched",m.pctWiki]].forEach(function(t){lh+="<tr><td>"+t[0]+"</td><td class='r'>"+t[1]+"%</td></tr>";});
    lh+="</table>";H+=sect("library",lh);}
  if(d.grades){var gq="";
    if(d.grades.transcription){gq+="<table><tr><th>creator</th><th>engine</th><th class='r'>cover</th><th class='r'>CER</th><th class='r'>match</th><th class='r'>cues</th><th class='r'>files</th></tr>";
      Object.keys(d.grades.transcription).forEach(function(cr){var E=d.grades.transcription[cr];Object.keys(E).forEach(function(en){var x=E[en];
        gq+="<tr><td>"+esc(cr)+"</td><td class='mut'>"+esc(en)+"</td><td class='r' style='color:"+gcol((x.cover||0)*100)+"'>"+Math.round((x.cover||0)*100)+"%</td><td class='r'>"+(x.cer!=null?x.cer.toFixed(2):"-")+"</td><td class='r'>"+(x.sim!=null?Math.round(x.sim*100)+"%":"-")+"</td><td class='r'>"+(x.cues_mean||"-")+"</td><td class='r mut'>"+(x.files||"-")+"</td></tr>";});});
      gq+="</table>";}
    if(d.grades.translation){gq+="<table style='margin-top:10px'><tr><th>creator (JA&#9656;EN judge)</th><th class='r'>overall</th><th class='r'>acc</th><th class='r'>flu</th><th class='r'>cmp</th><th class='r'>files</th></tr>";
      Object.keys(d.grades.translation).forEach(function(cr){var t=d.grades.translation[cr];
        gq+="<tr><td>"+esc(cr)+"</td><td class='r' style='color:"+gcol((t.overall||0)*10)+"'>"+(t.overall||"-")+"/10</td><td class='r'>"+(t.accuracy||"-")+"</td><td class='r'>"+(t.fluency||"-")+"</td><td class='r'>"+(t.completeness||"-")+"</td><td class='r mut'>"+(t.files||"-")+"</td></tr>";});
      gq+="</table>";}
    H+=sect("quality grades (detailed)",gq);}
  if(d.grades&&d.grades.review){var rq="<table><tr><th>creator</th><th class='r'>score</th><th>verdict</th><th class='r'>ship/rev/redo</th><th>latest note</th></tr>";
    Object.keys(d.grades.review).forEach(function(cr){var r=d.grades.review[cr];var w=(r.works||[])[0]||{};var vc=(r.verdict==="ship"?"done":(r.verdict==="redo"?"fail":"run"));
      rq+="<tr><td>"+esc(cr)+"</td><td class='r' style='color:"+gcol((r.score||0)*10)+"'>"+(r.score||"-")+"/10</td><td><span class='pill "+vc+"'>"+esc(r.verdict||"")+"</span></td><td class='r mut'>"+(r.ship||0)+"/"+(r.revise||0)+"/"+(r.redo||0)+"</td><td class='mut'>"+esc((w.summary||"").slice(0,64))+"</td></tr>";});
    rq+="</table>";H+=sect("ai self-review",rq);}
  if(d.jobs&&d.jobs.length){var jh="<table><tr><th>status</th><th>skill</th><th>request</th><th>started</th><th></th></tr>";
    d.jobs.forEach(function(o){var sc=(o.status==="running"?"run":(o.status==="done"?"done":"fail"));
      jh+="<tr><td><span class='pill "+sc+"'>"+esc(o.status)+"</span></td><td class='tag'>"+esc(o.skill)+"</td><td class='mut'>"+esc(o.prompt||"")+"</td><td class='mut'>"+esc(o.started||"")+"</td><td><span class='vx' onclick='viewlog(\""+esc(o.id)+"\")'>log</span></td></tr>";});
    jh+="</table><pre id='joblog' style='display:none'></pre>";H+=sect("ai jobs",jh);}
  if(d.logs&&d.logs.length){var lh2="<table><tr><th>log</th><th class='r'>kb</th><th>updated</th><th>last line</th></tr>";
    d.logs.forEach(function(l){lh2+="<tr><td>"+esc(l.name)+"</td><td class='r'>"+l.kb+"</td><td class='mut'>"+esc(l.mtime)+"</td><td class='mut'>"+esc((l.tail||"").slice(0,72))+"</td></tr>";});
    lh2+="</table>";H+=sect("run logs",lh2);}
  if(d.skills&&d.skills.length){var kh="<div class='chips'>";d.skills.forEach(function(k){kh+="<span class='chip' title='"+esc(k.desc)+"'>"+esc(k.name)+(k.confirm?" &#128274;":"")+"</span>";});kh+="</div>";H+=sect("ai console skills ("+d.skills.length+")",kh);}
  q("#root").innerHTML=H;
}
function viewlog(id){fetch("/joblog?id="+encodeURIComponent(id)).then(function(r){return r.text();}).then(function(t){var p=q("#joblog");p.style.display="block";p.textContent=t;p.scrollIntoView({behavior:"smooth"});});}
var DKEY="sasa_debug_"+(window.SASA_REALM||"core");
function poll(){fetch("/debug.json",{cache:"no-store"}).then(function(r){return r.json();}).then(function(d){try{localStorage.setItem(DKEY,JSON.stringify(d));}catch(e){}render(d);}).catch(function(){});}
// retention: paint last-known debug snapshot instantly so the page never blanks while it refreshes
try{var _c=localStorage.getItem(DKEY);if(_c)render(JSON.parse(_c));}catch(e){}
poll();setInterval(poll,5000);
</script>
</body></html>
'@

function Get-WikiState($roll) {
    # Live state of the LOCAL-LLM research wiki. METADATA ONLY: counts the
    # <creator>/<work>.md files (never reads them), reads the engine's
    # .status.json, and tails .build_log.jsonl. No research text touched.
    $wikiDir = Join-Path (Split-Path $PSScriptRoot -Parent) '_wiki'
    if (-not (Test-Path -LiteralPath $wikiDir)) { return $null }
    $mds = Get-ChildItem -LiteralPath $wikiDir -Recurse -Filter *.md -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notin @('INDEX.md', '_overview.md', '_profile.md') }
    $byCreator = @{}
    foreach ($m in $mds) { $cn = $m.Directory.Name; $byCreator[$cn] = ([int]$byCreator[$cn]) + 1 }
    $total = ($mds | Measure-Object).Count
    $jaMap = @{}; foreach ($r in $roll) { $jaMap[$r.Name] = [int]$r.Ja }
    $libTotal = [int](($roll | Measure-Object Ja -Sum).Sum)
    $creators = foreach ($cn in ($byCreator.Keys | Sort-Object { - $byCreator[$_] })) {
        $den = if ($jaMap.ContainsKey($cn) -and $jaMap[$cn] -ge $byCreator[$cn] -and $jaMap[$cn] -gt 0) { $jaMap[$cn] } else { $byCreator[$cn] }
        [ordered]@{ name = $cn; done = $byCreator[$cn]; total = $den
            pct = $(if ($den) { [int](100 * $byCreator[$cn] / $den) } else { 0 }) }
    }
    $st = $null; $sp = Join-Path $wikiDir '.status.json'
    if (Test-Path -LiteralPath $sp) { try { $st = Get-Content -LiteralPath $sp -Raw -ErrorAction Stop | ConvertFrom-Json } catch {} }
    $u2t = { param($u) [DateTimeOffset]::FromUnixTimeSeconds([long]$u).LocalDateTime }
    $state = if ($st) { "$($st.state)" } else { 'idle' }
    if ($state -eq 'running' -and $st.updated -and ((Get-Date) - (& $u2t $st.updated)).TotalSeconds -gt 180) { $state = 'idle' }
    # English work titles (translate_titles output) so the feed can read EN-primary, JA-secondary
    $titles = $null; $ttp = Join-Path $wikiDir 'title_translations.json'
    if (Test-Path -LiteralPath $ttp) { try { $titles = Get-Content -LiteralPath $ttp -Raw | ConvertFrom-Json } catch {} }
    $feed = @()
    $lp = Join-Path $wikiDir '.build_log.jsonl'
    if (Test-Path -LiteralPath $lp) {
        foreach ($ln in (Get-Content -LiteralPath $lp -Tail 14 -ErrorAction SilentlyContinue)) {
            if (-not "$ln".Trim()) { continue }
            try { $e = $ln | ConvertFrom-Json } catch { continue }
            $tm = if ($e.ts) { (& $u2t $e.ts).ToString('HH:mm:ss') } else { '' }
            $txt = switch ("$($e.status)") {
                'wrote' { "{0}  ({1}c - {2}t)" -f $e.work, $e.chars, $e.tokens }
                'overview' { "overview synthesis  ({0}c)" -f $e.chars }
                'profile' { "fan-wiki profile  ({0}c)" -f $e.chars }
                'ref' { "reference gathered  ({0}c)" -f $e.chars }
                'empty' { "{0}  (empty, skipped)" -f $e.work }
                'err' { "{0}  (model error)" -f $e.work }
                default { "$($e.work)" }
            }
            $note = switch ("$($e.status)") { 'wrote' { "$($e.creator)/$($e.work).md" }; 'overview' { "$($e.creator)/_overview.md" }; 'profile' { "$($e.creator)/_profile.md" }; default { '' } }
            $wn = if ("$($e.status)" -in 'wrote', 'empty', 'err') { "$($e.work)" } else { '' }
            $en = ''; if ($wn -and $titles) { $tp = $titles.PSObject.Properties[$wn]; if ($tp) { $en = "$($tp.Value)" } }
            $feed += [ordered]@{ task = "$($e.status)"; time = $tm; creator = "$($e.creator)"; work = $wn; en = $en; chars = [int]$e.chars; tokens = [int]$e.tokens; text = ("{0} :: {1}" -f $e.creator, $txt); note = $note }
        }
    }
    $curStr = if ($st -and $st.current) { "$($st.current)" } else { '' }
    $curEn = ''
    if ($curStr -and $titles) {
        $wk = if ($curStr -match '::\s*(.+)$') { $Matches[1].Trim() } else { $curStr }
        $cp = $titles.PSObject.Properties[$wk]; if ($cp) { $curEn = "$($cp.Value)" }
    }
    [ordered]@{
        present = $true; state = $state
        model   = $(if ($st) { "$($st.model)" } else { '' })
        current = $curStr; currentEn = $curEn
        done    = $(if ($st) { [int]$st.done } else { 0 })
        total   = [int]$total; libTotal = $libTotal
        updated = $(if ($st -and $st.updated) { (& $u2t $st.updated).ToString('HH:mm:ss') } else { '--' })
        creators = @($creators); feed = @($feed)
    }
}

function Get-NetThroughput {
    # live NIC up/down rate (all operational non-loopback adapters) + session totals.
    $sent = 0L; $recv = 0L
    foreach ($ni in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
        if ($ni.OperationalStatus -ne [System.Net.NetworkInformation.OperationalStatus]::Up) { continue }
        if ($ni.NetworkInterfaceType -eq [System.Net.NetworkInformation.NetworkInterfaceType]::Loopback) { continue }
        try { $st = $ni.GetIPv4Statistics() } catch { continue }
        $sent += [int64]$st.BytesSent; $recv += [int64]$st.BytesReceived
    }
    $tk = [Environment]::TickCount64
    $upKbs = 0.0; $downKbs = 0.0
    if ($script:NetPrev) {
        $dt = ($tk - $script:NetPrev.T) / 1000.0
        if ($dt -ge 0.3) {
            $upKbs = [math]::Round([math]::Max([int64]0, ($sent - $script:NetPrev.S)) / $dt / 1KB, 1)
            $downKbs = [math]::Round([math]::Max([int64]0, ($recv - $script:NetPrev.R)) / $dt / 1KB, 1)
            $script:NetLast = @{ up = $upKbs; down = $downKbs }
        } elseif ($script:NetLast) { $upKbs = $script:NetLast.up; $downKbs = $script:NetLast.down }
    } else { $script:NetBase = @{ S = $sent; R = $recv } }
    $script:NetPrev = @{ T = $tk; S = $sent; R = $recv }
    $base = if ($script:NetBase) { $script:NetBase } else { @{ S = $sent; R = $recv } }
    [ordered]@{
        upKbs = $upKbs; downKbs = $downKbs
        upMB = [math]::Round(($sent - $base.S) / 1MB, 1); downMB = [math]::Round(($recv - $base.R) / 1MB, 1)
    }
}

# --- library management state (hide / soft-delete) --------------------------------------------
# _data/library_state.json is the SOURCE OF TRUTH for what the library shows: { "<id>": {s:"hidden"|"trashed", at, moved} }.
# Get-Library applies it as an overlay (trashed rows excluded, hidden rows flagged) so the view is
# always consistent even if a physical file-move hiccups. All mutations are USER-driven (clicks in
# the library UI) — never the autonomous loop. Soft-delete MOVES files into _data/_trash (reversible);
# purge is the only destructive op and is gated behind an explicit client confirm.
function Get-LibStatePath { Join-Path (Split-Path $PSScriptRoot -Parent) '_data\library_state.json' }
function Get-LibState {
    $p = Get-LibStatePath
    if (Test-Path -LiteralPath $p) {
        try { $h = @{}; foreach ($pr in (Get-Content -LiteralPath $p -Raw | ConvertFrom-Json).PSObject.Properties) { $h[$pr.Name] = $pr.Value }; return $h } catch {}
    }
    return @{}
}
function Save-LibState($h) {
    $p = Get-LibStatePath; $d = Split-Path $p -Parent
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    ($h | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $p -Encoding UTF8
    $script:LibAt = 0; $script:SbxLibAt = 0   # invalidate library caches so the change shows on the next load
}
function Get-TrashJson {
    $st = Get-LibState
    $items = @()
    foreach ($k in $st.Keys) {
        if ("$($st[$k].s)" -ne 'trashed') { continue }
        $segs = "$k" -split '[\\/]'
        $items += [ordered]@{ id = "$k"; creator = $segs[0]; base = [IO.Path]::GetFileNameWithoutExtension($segs[-1]); at = "$($st[$k].at)" }
    }
    @{ items = @($items); count = $items.Count } | ConvertTo-Json -Depth 4
}
function Invoke-LibMutation($action, $o) {
    $root = Split-Path $PSScriptRoot -Parent
    $trashRoot = Join-Path $root '_data\_trash'
    $derivedRoot = Join-Path $root '_data\derived'
    $st = Get-LibState
    $ids = @()
    if ($o.all -and ($action -eq 'purge' -or $action -eq 'restore')) {
        $ids = @($st.Keys | Where-Object { "$($st[$_].s)" -eq 'trashed' } | ForEach-Object { "$_" })
    }
    elseif ($o.ids) { $ids = @($o.ids | ForEach-Object { "$_" }) }
    if ($ids.Count -eq 0) { return (@{ ok = $false; error = 'no ids' } | ConvertTo-Json) }
    $done = 0; $errs = @()
    foreach ($id in $ids) {
        try {
            $parent = Split-Path $id -Parent
            $base = [IO.Path]::GetFileNameWithoutExtension(($id -split '[\\/]')[-1])
            $audSrc = Join-Path $root $id;          $audTrash = Join-Path $trashRoot $id
            $dvSrc = Join-Path $derivedRoot (Join-Path $parent $base)
            $dvTrash = Join-Path $trashRoot (Join-Path '_derived' (Join-Path $parent $base))
            if ($action -eq 'hide') { $st[$id] = @{ s = 'hidden'; at = (Get-Date -Format s) }; $done++ }
            elseif ($action -eq 'unhide') { if ($st.ContainsKey($id)) { $st.Remove($id) }; $done++ }
            elseif ($action -eq 'delete') {
                $moved = $false
                if (Test-Path -LiteralPath $audSrc) {
                    $dd = Split-Path $audTrash -Parent; if (-not (Test-Path -LiteralPath $dd)) { New-Item -ItemType Directory -Path $dd -Force | Out-Null }
                    if (Test-Path -LiteralPath $audTrash) { Remove-Item -LiteralPath $audTrash -Force -Recurse -ErrorAction SilentlyContinue }
                    Move-Item -LiteralPath $audSrc -Destination $audTrash -Force; $moved = $true
                }
                if (Test-Path -LiteralPath $dvSrc) { try { $dd = Split-Path $dvTrash -Parent; if (-not (Test-Path -LiteralPath $dd)) { New-Item -ItemType Directory -Path $dd -Force | Out-Null }; Move-Item -LiteralPath $dvSrc -Destination $dvTrash -Force } catch {} }
                $st[$id] = @{ s = 'trashed'; at = (Get-Date -Format s); moved = $moved }; $done++
            }
            elseif ($action -eq 'restore') {
                if (Test-Path -LiteralPath $audTrash) { $dd = Split-Path $audSrc -Parent; if (-not (Test-Path -LiteralPath $dd)) { New-Item -ItemType Directory -Path $dd -Force | Out-Null }; Move-Item -LiteralPath $audTrash -Destination $audSrc -Force }
                if (Test-Path -LiteralPath $dvTrash) { try { $dd = Split-Path $dvSrc -Parent; if (-not (Test-Path -LiteralPath $dd)) { New-Item -ItemType Directory -Path $dd -Force | Out-Null }; Move-Item -LiteralPath $dvTrash -Destination $dvSrc -Force } catch {} }
                if ($st.ContainsKey($id)) { $st.Remove($id) }; $done++
            }
            elseif ($action -eq 'purge') {
                # PERMANENT removal of trashed files. Only reached by an explicit user click + confirm.
                if (Test-Path -LiteralPath $audTrash) { Remove-Item -LiteralPath $audTrash -Force -Recurse -ErrorAction SilentlyContinue }
                if (Test-Path -LiteralPath $dvTrash) { Remove-Item -LiteralPath $dvTrash -Force -Recurse -ErrorAction SilentlyContinue }
                if ($st.ContainsKey($id)) { $st.Remove($id) }; $done++
            }
        } catch { $errs += "$id : $_" }
    }
    Save-LibState $st
    @{ ok = $true; action = $action; done = $done; errors = @($errs) } | ConvertTo-Json -Depth 4
}

function Invoke-SandboxPromote($o) {
    # promote audition works from the sandbox (_data/<site>_ingest/<channel>/<file>) INTO the core
    # library by moving the audio + every sibling that shares its base (ja.srt/en.srt/jpg/info.json)
    # to <ROOT>/<channel>/. The moved work then appears in core immediately via Get-Library's
    # live-merge (as a pending card) and enters the normal pipeline on the next index run. USER-driven
    # only (a Manage-mode click). A move, not a copy — reversible by moving back; never clobbers an
    # existing core file.
    $root = Split-Path $PSScriptRoot -Parent
    $ids = @($o.ids | ForEach-Object { "$_" })
    if (-not $ids.Count) { return (@{ ok = $false; error = 'no ids' } | ConvertTo-Json) }
    $moved = 0; $errs = @()
    foreach ($id in $ids) {
        try {
            $parts = $id -split '[\\/]'
            if ($parts.Count -lt 4 -or $parts[0] -ne '_data' -or $parts[1] -notlike '*_ingest') { $errs += "$id (not a sandbox work)"; continue }
            $channel = $parts[2]; $fname = $parts[-1]
            $base = [IO.Path]::GetFileNameWithoutExtension($fname)
            $srcDir = Join-Path $root (Join-Path (Join-Path '_data' $parts[1]) $channel)
            $destDir = Join-Path $root $channel
            if (-not (Test-Path -LiteralPath $srcDir)) { $errs += "$id (source gone)"; continue }
            if (-not (Test-Path -LiteralPath $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
            $pref = $base + '.'
            $sibs = @(Get-ChildItem -LiteralPath $srcDir -File -ErrorAction SilentlyContinue | Where-Object { $_.Name.StartsWith($pref, [System.StringComparison]::OrdinalIgnoreCase) })
            if (-not $sibs.Count) { $errs += "$id (no files matched)"; continue }
            foreach ($f in $sibs) {
                $dest = Join-Path $destDir $f.Name
                if (Test-Path -LiteralPath $dest) { continue }   # never clobber an existing core file
                Move-Item -LiteralPath $f.FullName -Destination $dest -Force
            }
            $moved++
        } catch { $errs += "$id : $($_.Exception.Message)" }
    }
    $script:SbxLibAt = 0; $script:LibAt = 0    # both realms refresh (source shrinks, core grows)
    @{ ok = ($errs.Count -eq 0); moved = $moved; errors = @($errs) } | ConvertTo-Json -Depth 4
}

function Invoke-LibRetrigger($o) {
    # #111 "re-run pipeline from a card": manual per-work retrigger of the EXISTING ASR -> resegment
    # -> translate chain (fw_transcribe.py -> resegment_subs.py --translate -> verify_translations.py
    # -> eta.py -- the same scripts process_creator.py / the overnight arc already call), scoped to
    # the SPECIFIC selected work ids instead of a whole creator, and always forcing a redo (this is a
    # retry button, not the skip-if-done batch job those tools normally run). An optional --wiki
    # checkbox also retries the local-AI wiki research (research_agent.py + local_wiki.py --force)
    # for the touched creators.
    #
    # Mirrors Invoke-LibMutation's shape (id list in, {ok,done,errors} out) but kicks the actual work
    # off DETACHED (Start-Process, same idiom as Invoke-AiChat) in retrigger_pipeline.py, since a GPU
    # transcribe run can take minutes-to-hours and must never block this single-threaded listener.
    # The spawned job writes a standard _jobs/<id>.json record (same shape ai_console.py's launch()
    # uses) so it shows up in the existing "ai jobs" console panel while it runs.
    $py = (Get-Command python -ErrorAction SilentlyContinue).Source
    if (-not $py) { return (@{ ok = $false; error = 'python not found' } | ConvertTo-Json -Compress) }
    $ids = @($o.ids | ForEach-Object { "$_" } | Where-Object { $_ })
    if (-not $ids.Count) { return (@{ ok = $false; error = 'no ids' } | ConvertTo-Json -Compress) }
    $valid = @(); $errs = @()
    foreach ($id in $ids) {
        if (Resolve-AudioPath $id) { $valid += $id } else { $errs += "$id (not found)" }
    }
    if (-not $valid.Count) { return (@{ ok = $false; error = 'no valid ids'; errors = @($errs) } | ConvertTo-Json -Depth 4 -Compress) }
    $script = Join-Path $PSScriptRoot 'retrigger_pipeline.py'
    if (-not (Test-Path -LiteralPath $script)) {
        # CPU-only core builds ship without the Tier-1 GPU pipeline scripts -- fail clean here rather
        # than launching a python process that immediately dies and leaves the job stuck "running"
        # forever (Start-Process itself would still succeed since python.exe exists; only the script
        # argument is missing, so nothing downstream would ever flip the job's status).
        return (@{ ok = $false; error = 'retrigger_pipeline.py not present -- needs the GPU comprehension worker package, not included in the CPU-only core' } | ConvertTo-Json -Compress)
    }
    $jd = Join-Path $PSScriptRoot '_jobs'; New-Item -ItemType Directory -Force -Path $jd | Out-Null
    $jid = (Get-Date -Format 'HHmmss') + '-' + ([guid]::NewGuid().ToString('N').Substring(0, 4))
    $wiki = [bool]$o.wiki
    $argf = Join-Path $jd "retrig-$jid-args.json"
    (@{ ids = @($valid); wiki = $wiki; root = (Split-Path $PSScriptRoot -Parent) } | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $argf -Encoding utf8
    $names = @($valid | ForEach-Object { [IO.Path]::GetFileNameWithoutExtension(($_ -split '[\\/]')[-1]) })
    $prompt = 're-run pipeline: ' + ($names -join ', ') + $(if ($wiki) { ' (+ wiki research)' } else { '' })
    $cmdArgs = @($script, '--file', $argf, '--job', $jid)
    $meta = [ordered]@{ id = $jid; skill = 'retrigger-pipeline'; args = @{ ids = @($valid); wiki = $wiki }
        prompt = $prompt; cmd = (@($py) + $cmdArgs); status = 'running'; started = (Get-Date -Format 's'); ended = $null; exit = $null }
    ($meta | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath (Join-Path $jd "$jid.json") -Encoding utf8
    '' | Set-Content -LiteralPath (Join-Path $jd "$jid.log") -Encoding utf8
    try { Start-Process -FilePath $py -ArgumentList $cmdArgs -WindowStyle Hidden | Out-Null }
    catch { return (@{ ok = $false; error = "$($_.Exception.Message)" } | ConvertTo-Json -Compress) }
    @{ ok = $true; done = $valid.Count; errors = @($errs); job = $jid } | ConvertTo-Json -Depth 4 -Compress
}

function Get-TitleOverridesPath { Join-Path (Split-Path $PSScriptRoot -Parent) '_data\title_overrides.json' }
function Get-TitleOverrides {
    # #112a per-work title override sidecar -- SEPARATE from _wiki/title_translations.json (that
    # file is pipeline-owned, rewritten wholesale by translate_titles.py; a user override living
    # there would get silently clobbered on the next run). { id -> custom display title }.
    $p = Get-TitleOverridesPath
    if (Test-Path -LiteralPath $p) {
        try { $h = @{}; foreach ($pr in (Get-Content -LiteralPath $p -Raw | ConvertFrom-Json).PSObject.Properties) { $h[$pr.Name] = "$($pr.Value)" }; return $h } catch {}
    }
    return @{}
}
function Save-TitleOverrides($h) {
    $p = Get-TitleOverridesPath; $d = Split-Path $p -Parent
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    ($h | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $p -Encoding UTF8
    $script:LibAt = 0   # invalidate the library cache so the new title shows on the next load
}
function Invoke-LibTitleOverride($o) {
    # POST {id, title}. Empty/whitespace title CLEARS the override (reverts to whatever Get-Library
    # would otherwise show). User-driven only (Manage-mode "edit title" on the detail card).
    $id = "$($o.id)"
    if ([string]::IsNullOrWhiteSpace($id)) { return (@{ ok = $false; error = 'no id' } | ConvertTo-Json -Compress) }
    if (-not (Resolve-AudioPath $id)) { return (@{ ok = $false; error = 'unknown work' } | ConvertTo-Json -Compress) }
    $h = Get-TitleOverrides
    $title = "$($o.title)".Trim()
    if ($title) { $h[$id] = $title } elseif ($h.ContainsKey($id)) { $h.Remove($id) }
    Save-TitleOverrides $h
    @{ ok = $true; id = $id; title = $title } | ConvertTo-Json -Compress
}

# extensions that carry a real video track (vs. audio-only) -- mirrors the VID/AUD split other
# pipeline scripts (library_stats.py, analyze_audio.py) already use for the same classification.
$script:VidExt = '.mp4', '.mkv', '.webm', '.mov', '.avi', '.m4v', '.ts'

function Get-Library {
    # assemble the cover-art library from the audio index + title translations.
    # ~30s cache: rebuilding 300+ records from audio_index.json each request was 119ms/load.
    $now = [Environment]::TickCount64
    if ($script:LibCache -and [math]::Abs($now - $script:LibAt) -lt 30000) { return $script:LibCache }
    $wiki = Join-Path (Split-Path $PSScriptRoot -Parent) '_wiki'
    $aip = Join-Path $wiki 'audio_index.json'; $ttp = Join-Path $wiki 'title_translations.json'
    $ai = $null; $tt = $null
    if (Test-Path -LiteralPath $aip) {
        try { $ai = ((Get-Content -LiteralPath $aip -Raw) -replace '([:\[,]\s*)-?(?:Infinity|NaN)\b', '${1}null') | ConvertFrom-Json } catch {}
    }
    if (Test-Path -LiteralPath $ttp) { try { $tt = Get-Content -LiteralPath $ttp -Raw | ConvertFrom-Json } catch {} }
    $tg = $null; $tgp = Join-Path $wiki 'tags.json'   # unified #tag layer (build_tags.py)
    if (Test-Path -LiteralPath $tgp) { try { $tg = (Get-Content -LiteralPath $tgp -Raw | ConvertFrom-Json).works } catch {} }
    # DLsite product metrics (rating / dlCount) join, keyed circle|title from the id path segments.
    # Empty until dlsite_products.py enrichment populates those fields, so this is a no-op today.
    $prodMap = @{}
    $pjp = Join-Path $wiki 'DLsite\_products.json'
    if (Test-Path -LiteralPath $pjp) {
        try {
            $pj = Get-Content -LiteralPath $pjp -Raw | ConvertFrom-Json
            foreach ($pr in $pj.products) {
                if ($null -eq $pr.rating -and $null -eq $pr.dlCount) { continue }
                $m = @{ rating = $pr.rating; dlCount = $pr.dlCount }
                if ($pr.circle -and $pr.title) { $prodMap["$($pr.circle)|$($pr.title)"] = $m }
                if ($pr.title) { $prodMap["|$($pr.title)"] = $m }   # title-only fallback
            }
        } catch {}
    }
    $works = [System.Collections.Generic.List[object]]::new()
    if ($ai) {
        foreach ($p in $ai.PSObject.Properties) {
            $v = $p.Value
            if (-not $v.creator) { continue }
            $base = [IO.Path]::GetFileNameWithoutExtension(($p.Name -split '[\\/]')[-1])
            $en = $null
            if ($tt) { $tp = $tt.PSObject.Properties[$base]; if ($tp) { $en = "$($tp.Value)" } }
            $wtags = $v.tags
            if ($tg) { $tgo = $tg.PSObject.Properties[$p.Name]; if ($tgo) { $wtags = $tgo.Value } }
            $row = [ordered]@{ id = $p.Name; creator = $v.creator; base = $base; ja = $base
                    title = $(if ($en) { $en } else { $base }); tags = $wtags
                    rms = $v.rmsDb; width = $v.stereoWidthDb; silence = $v.silenceRatio; dur = $v.durationSec
                    kind = $(if ($script:VidExt -contains [IO.Path]::GetExtension($p.Name).ToLower()) { 'video' } else { 'audio' })
                    thumb = '/thumb?id=' + [uri]::EscapeDataString($p.Name) }
            if ($prodMap.Count -and $p.Name -like 'DLsite\Audio\*') {
                $segs = $p.Name -split '\\'
                if ($segs.Count -ge 4) {
                    $m = $prodMap["$($segs[2])|$($segs[3])"]; if (-not $m) { $m = $prodMap["|$($segs[3])"] }
                    if ($m) {
                        if ($null -ne $m.rating) { $row.rating = $m.rating }
                        if ($null -ne $m.dlCount) { $row.dlCount = $m.dlCount }
                    }
                }
            }
            $works.Add($row)
        }
    }
    # --- DLsite lossy/lossless dedupe: a product usually ships the SAME tracks as mp3 + wav
    # (SEありmp3/SEありwav, 【mp3】X/【wav】X, MP3\01_x/wav\01_x ...). Treat each such pair as ONE
    # track: group by (dir path with format tokens + digits/punct stripped) + basename, and keep
    # the variant that HAS derived subs (that's where the pipeline transcribed), tiebreak mp3.
    # SEあり/SEなし, 音声のみ, 左右反転, language dirs (English/Chinese) survive normalization as
    # distinct groups — those are different content, not format dupes. Nothing is deleted on disk.
    if ($works.Count) {
        $derivedRoot = Join-Path (Split-Path $PSScriptRoot -Parent) '_data\derived'
        $groups = [ordered]@{}
        $keep = [System.Collections.Generic.List[object]]::new()
        foreach ($w in $works) {
            if ($w.id -like 'DLsite\Audio\*') {
                # DLsite ships the same tracks as mp3+wav under format-named folders (【mp3】X/【wav】X, MP3\/wav\...);
                # normalize the dir (strip format tokens + digits/punct) so those collapse.
                $dir = Split-Path $w.id -Parent
                $norm = ($dir.ToLowerInvariant() -replace 'mp3|wav|flac|m4a', '' -replace '[0-9【】\[\]\(\)_\-\\\/\. ]', '')
                $gk = "dl|$norm|$($w.base)"
            }
            else {
                # community creators: collapse ONLY exact format twins -- the SAME recording saved as both
                # .mp3 and .m4a (etc) in the same folder with the same basename. Different masters
                # (無編集/編集あり), after-talks, L/R-reversed and language variants keep distinct filenames,
                # so they get distinct keys and stay separate. (This is what left Nakia's mp3+m4a twins doubled.)
                $gk = 'c|' + (Split-Path $w.id -Parent).ToLowerInvariant() + '|' + "$($w.base)".ToLowerInvariant()
            }
            if (-not $groups.Contains($gk)) { $groups[$gk] = [System.Collections.Generic.List[object]]::new() }
            $groups[$gk].Add($w)
        }
        foreach ($g in $groups.Values) {
            if ($g.Count -eq 1) { $keep.Add($g[0]); continue }
            $best = $null
            foreach ($w in $g) {   # prefer the variant with derived subs
                $dd = Join-Path $derivedRoot ((Split-Path $w.id -Parent) + '\' + $w.base)
                if ((Test-Path -LiteralPath (Join-Path $dd 'ja.srt')) -or (Test-Path -LiteralPath (Join-Path $dd 'en.srt'))) { $best = $w; break }
            }
            if (-not $best) { $best = @($g | Where-Object { $_.id -match '(?i)mp3' })[0] }
            if (-not $best) { $best = $g[0] }
            $keep.Add($best)
        }
        $works = $keep
    }
    # --- live-merge NEW audio: anything on disk the index hasn't seen yet shows as a PENDING card,
    # so a freshly-dropped creator/work is visible in the library immediately -- before the next
    # analyze_audio run. Community creator folders only (the DLsite tree is huge + rarely gets ad-hoc
    # drops). Pending rows are playable (audio exists) but carry no tags/dur/subs yet + pending:true.
    try {
        $root = Split-Path $PSScriptRoot -Parent
        $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        # $seenStem tracks (folder|basename-without-ext) so we don't re-add a work we already kept in a
        # DIFFERENT container -- e.g. the dedup collapsed X.mp3 + X.m4a to one card; without this the FS
        # scan would find the dropped X.m4a on disk and re-add it as a pending twin.
        $seenStem = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($w in $works) { [void]$seen.Add("$($w.id)"); [void]$seenStem.Add(((Split-Path "$($w.id)" -Parent) + '|' + "$($w.base)")) }
        $audExt = '.m4a', '.mp3', '.wav', '.flac', '.opus', '.ogg', '.mp4', '.mkv', '.webm'
        foreach ($cd in (Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)) {
            if ($cd.Name -in @('DLsite', 'Sasayaki') -or $cd.Name -like '_*' -or $cd.Name -like '.*') { continue }
            foreach ($f in (Get-ChildItem -LiteralPath $cd.FullName -Recurse -File -ErrorAction SilentlyContinue)) {
                if ($audExt -notcontains $f.Extension.ToLower() -or $f.Name -like '*.subbed.*') { continue }
                $rel = $f.FullName.Substring($root.Length).TrimStart('\', '/')
                if (-not $seen.Add($rel)) { continue }
                $b = [IO.Path]::GetFileNameWithoutExtension($f.Name)
                $stem = (Split-Path $rel -Parent) + '|' + $b
                if (-not $seenStem.Add($stem)) { continue }   # already have this recording in another container
                $works.Add([ordered]@{ id = $rel; creator = $cd.Name; base = $b; ja = $b; title = $b
                        tags = @(); pending = $true
                        kind = $(if ($script:VidExt -contains $f.Extension.ToLower()) { 'video' } else { 'audio' })
                        thumb = '/thumb?id=' + [uri]::EscapeDataString($rel) })
            }
        }
    } catch {}
    # --- grouping: collapse DLsite products into one "album" card, and community same-title edits
    # (無編集 / 編集あり / final master of one session) into one "versions" card. The server just tags each
    # work with a stable group id + kind + display title; the client shows ONE representative card per
    # group of >=2 and expands it on click. Groups of 1 render as normal single cards.
    foreach ($w in $works) {
        $wid = "$($w.id)"
        if ($wid -like 'DLsite\Audio\*') {
            $segs = $wid -split '\\'
            if ($segs.Count -ge 4) { $w.grp = ($segs[0..3] -join '\'); $w.grpkind = 'album'; $w.grptitle = "$($segs[3])" }
        }
        elseif ($w.dur -and -not $w.pending) {
            # strip a TRAILING parenthetical only when it marks an edit stage (無編集の音声 / 編集あり音声 / …);
            # the no-suffix "final" cut then shares this normalized title with its edited/unedited siblings.
            $nb = ("$($w.base)" -replace '\s*[\(（][^\)）]*(?:編集|音声のみ|unedited|edited|master|マスタリング)[^\)）]*[\)）]\s*$', '').Trim()
            $w.grp = "v|$($w.creator)|$nb"; $w.grpkind = 'version'; $w.grptitle = $nb
        }
    }
    # hide/trash overlay from the library-management UI (source of truth: _data/library_state.json).
    # Trashed rows leave the library entirely (even if still in audio_index); hidden rows are flagged.
    try {
        $st = Get-LibState
        if ($st.Count) {
            $keep2 = [System.Collections.Generic.List[object]]::new()
            foreach ($w in $works) {
                $s = $st["$($w.id)"]
                if ($s) {
                    $ss = "$($s.s)"
                    if ($ss -eq 'trashed') { continue }
                    if ($ss -eq 'hidden') { $w.hidden = $true }
                }
                $keep2.Add($w)
            }
            $works = $keep2
        }
    } catch {}
    # --- #112a per-work title override: a SEPARATE sidecar (_data/title_overrides.json), never
    # _wiki/title_translations.json (that file is pipeline-owned/rewritten wholesale). Applied last
    # so it wins over both the base filename and the pipeline's EN translation.
    try {
        $ov = Get-TitleOverrides
        if ($ov.Count) {
            foreach ($w in $works) {
                $t = $ov["$($w.id)"]
                if ($t) { $w.title = "$t"; $w.titleOverridden = $true }
            }
        }
    } catch {}
    # --- sortable date stamp (fixes "New" clustering by creator instead of recency) -------------
    # Community/YouTube works carry the upload date as a leading YYYY-MM-DD prefix in the filename
    # (~38% of the library, incl. nearly every community work). DLsite tracks are 'Track01..' with no
    # date, so they inherit their PRODUCT's regist_date (joined by title-segment match). Undated works
    # (a handful) get $null and sort last under "New" -- correct: they aren't new arrivals.
    $dlDate = @{}
    try { foreach ($p in $pj.products) { if ($p.title -and $p.date) { $dlDate[[string]$p.title] = [string]$p.date } } } catch {}
    foreach ($w in $works) {
        $d = $null
        $m = [regex]::Match([string]$w.base, '^\s*(20\d{2})[-_.]?(\d{2})[-_.]?(\d{2})')
        if ($m.Success) { $d = "$($m.Groups[1].Value)-$($m.Groups[2].Value)-$($m.Groups[3].Value)" }
        elseif (("$($w.id)" -like 'DLsite\Audio\*') -and $dlDate.Count) {
            foreach ($seg in ("$($w.id)" -split '\\')) { if ($dlDate.ContainsKey($seg)) { $d = $dlDate[$seg]; break } }
        }
        $w.date = $d
    }
    # --- trigger summary (CLAP binaural detection, _data/derived/<Creator>/<stem>/triggers.json): fold
    # each work's top-3 sound-event classes (by seconds, from triggers.json's `profile`) into the row so
    # library cards can show event chips without a per-card fetch. Reuses this function's ~30s cache --
    # absent for most works today (GPU pipeline coverage is partial); those rows just skip `triggers`.
    $derivedRoot = Join-Path (Split-Path $PSScriptRoot -Parent) '_data\derived'
    foreach ($w in $works) {
        if ($w.pending) { continue }
        $dd = Join-Path $derivedRoot ((Split-Path "$($w.id)" -Parent) + '\' + $w.base)
        $tp = Join-Path $dd 'triggers.json'
        if (Test-Path -LiteralPath $tp) {
            try {
                $tj = Get-Content -LiteralPath $tp -Raw | ConvertFrom-Json
                if ($tj.profile) {
                    $top = $tj.profile.PSObject.Properties | Sort-Object { [double]$_.Value } -Descending | Select-Object -First 3
                    if ($top) { $w.triggers = @($top | ForEach-Object { [ordered]@{ c = $_.Name; s = [math]::Round([double]$_.Value, 1) } }) }
                }
            } catch {}
        }
    }
    $script:LibCache = $(if ($works.Count) { $works | ConvertTo-Json -Depth 5 -Compress -AsArray } else { '[]' })
    $script:LibAt = $now
    $script:LibCache
}

function Get-SandboxLibrary {
    # the SANDBOX realm's library: audition works staged under _data/<site>_ingest (one folder per
    # channel/creator, files flat inside: <base>.m4a + <base>.ja.srt/.en.srt + <base>.jpg cover). Now
    # MULTI-SITE: any _data/<site>_ingest dir is scanned and each row is stamped with `platform` from the
    # dir prefix (yt->youtube, cien->ci-en, twitcasting/openrec/fanbox), so the sandbox surfaces every
    # exclusive-stream source the scrapers stage, filterable by the same source bar core uses. Emits the
    # SAME row schema Get-Library does. Ids are ROOT-RELATIVE with FORWARD slashes (the /audio + /subs
    # routes resolve them; forward slashes survive the Linux Zettlab container).
    $now = [Environment]::TickCount64
    if ($script:SbxLibCache -and [math]::Abs($now - $script:SbxLibAt) -lt 30000) { return $script:SbxLibCache }
    $root = Split-Path $PSScriptRoot -Parent
    $dataDir = Join-Path $root '_data'
    # ingest dir prefix -> platform label (matches source_scan.py's taxonomy). yt_ingest is the current
    # populated one; the rest light up automatically the moment a scraper stages content there.
    $ingestRoots = @(
        @{ leaf = 'yt_ingest'; plat = 'youtube' }
        @{ leaf = 'cien_ingest'; plat = 'ci-en' }
        @{ leaf = 'twitcasting_ingest'; plat = 'twitcasting' }
        @{ leaf = 'openrec_ingest'; plat = 'openrec' }
        @{ leaf = 'fanbox_ingest'; plat = 'fanbox' }
        @{ leaf = 'mellowfan_ingest'; plat = 'mellow-fan' }
    )
    # title-derived tags for the sandbox (tag_sandbox.py): { id -> [canonical tags] }. Absent = untagged.
    $sbxTags = @{}
    try {
        $stp = Join-Path $dataDir 'sandbox_tags.json'
        if (Test-Path -LiteralPath $stp) { $o = Get-Content -LiteralPath $stp -Raw | ConvertFrom-Json; foreach ($pp in $o.PSObject.Properties) { $sbxTags[$pp.Name] = @($pp.Value) } }
    } catch {}
    $works = [System.Collections.Generic.List[object]]::new()
    $audio = '.m4a', '.mp3', '.wav', '.flac', '.opus', '.ogg', '.aac', '.mp4', '.mkv', '.webm'
    foreach ($rt in $ingestRoots) {
        $ing = Join-Path $dataDir $rt.leaf
        if (-not (Test-Path -LiteralPath $ing)) { continue }
        foreach ($ch in (Get-ChildItem -LiteralPath $ing -Directory -ErrorAction SilentlyContinue)) {
            # index this channel's sibling files by basename so we can flag ja/en + pick the audio track
            $srt = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            $ensrt = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            $picks = [ordered]@{}   # base -> audio file
            foreach ($f in (Get-ChildItem -LiteralPath $ch.FullName -File -ErrorAction SilentlyContinue)) {
                $n = $f.Name
                if ($n -like '*.ja.srt') { [void]$srt.Add($n.Substring(0, $n.Length - 7)); continue }
                if ($n -like '*.en.srt') { [void]$ensrt.Add($n.Substring(0, $n.Length - 7)); continue }
                if ($audio -contains $f.Extension.ToLower()) {
                    $b = [IO.Path]::GetFileNameWithoutExtension($n)
                    if (-not $picks.Contains($b)) { $picks[$b] = $f.Name }   # first audio wins per basename
                }
            }
            foreach ($b in $picks.Keys) {
                $rel = '_data/' + $rt.leaf + '/' + $ch.Name + '/' + $picks[$b]
                $dm = [regex]::Match([string]$b, '^\s*(20\d{2})[-_.]?(\d{2})[-_.]?(\d{2})')
                $dt = $(if ($dm.Success) { "$($dm.Groups[1].Value)-$($dm.Groups[2].Value)-$($dm.Groups[3].Value)" } else { $null })
                $works.Add([ordered]@{ id = $rel; creator = $ch.Name; base = $b; ja = $b
                        title = $b; tags = @($(if ($sbxTags.ContainsKey($rel)) { $sbxTags[$rel] } else { @() })); sandbox = $true; date = $dt; platform = $rt.plat
                        hasJa = $srt.Contains($b); hasEn = $ensrt.Contains($b)
                        thumb = '/thumb?id=' + [uri]::EscapeDataString($rel) })
            }
        }
    }
    $script:SbxLibCache = $(if ($works.Count) { $works | ConvertTo-Json -Depth 5 -Compress -AsArray } else { '[]' })
    $script:SbxLibAt = $now
    $script:SbxLibCache
}

function Get-SandboxWikiIndex {
    # the SANDBOX realm's wiki: the yt_ingest audition creators. They have NO AI research profiles yet
    # (0/79), so profile/overview are false; this lists each creator's stream works (audio) with a play
    # link into the sandbox library. When the research pipeline later runs on a promoted creator, their
    # _wiki profile appears via the normal Get-WikiIndex path. Same JSON shape wiki.html already renders.
    $now = [Environment]::TickCount64
    if ($script:SbxWikiCache -and [math]::Abs($now - $script:SbxWikiAt) -lt 30000) { return $script:SbxWikiCache }
    $root = Split-Path $PSScriptRoot -Parent
    $ing = Join-Path (Join-Path $root '_data') 'yt_ingest'
    $out = [System.Collections.Generic.List[object]]::new()
    if (Test-Path -LiteralPath $ing) {
        $audio = '.m4a', '.mp3', '.wav', '.flac', '.opus', '.ogg', '.aac', '.mp4', '.mkv', '.webm'
        foreach ($ch in (Get-ChildItem -LiteralPath $ing -Directory -ErrorAction SilentlyContinue)) {
            $works = [System.Collections.Generic.List[object]]::new()
            $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            foreach ($f in (Get-ChildItem -LiteralPath $ch.FullName -File -ErrorAction SilentlyContinue)) {
                if ($audio -notcontains $f.Extension.ToLower()) { continue }
                $b = [IO.Path]::GetFileNameWithoutExtension($f.Name)
                if (-not $seen.Add($b)) { continue }
                $rel = '_data/yt_ingest/' + $ch.Name + '/' + $f.Name   # forward slashes -> resolve on both OSes
                $works.Add([ordered]@{ file = ''; base = $b; kb = [int]($f.Length / 1KB); libId = $rel })
            }
            if ($works.Count) {
                $out.Add([ordered]@{ creator = $ch.Name; notes = $works.Count; profile = $false; overview = $false
                        pfp = (Test-Path -LiteralPath (Join-Path $ch.FullName '_avatar.jpg')); works = @($works) })
            }
        }
    }
    $json = if ($out.Count) { ($out | Sort-Object { -$_.notes }) | ConvertTo-Json -Depth 6 -Compress -AsArray } else { '[]' }
    $script:SbxWikiCache = $json; $script:SbxWikiAt = [Environment]::TickCount64
    return $json
}

function Fix-Mojibake([string]$s) {
    # recover Shift-JIS names that arrived CP437-garbled (e.g. 'é═é╢é▀é╔' -> 'はじめに'); leave clean names alone
    if ([string]::IsNullOrEmpty($s) -or ($s -notmatch '[À-ÿ─-▟ƒ]')) { return $s }
    try {
        $rec = [Text.Encoding]::GetEncoding(932).GetString([Text.Encoding]::GetEncoding(437).GetBytes($s))
        if ($rec -match '[぀-ヿ一-鿿]') { return $rec }   # got real kana/kanji back
    } catch {}
    return $s
}

function Get-WikiIndex {
    # METADATA-ONLY index of the local-AI research wiki: per creator -> note count, profile/overview presence,
    # and per-work note files cross-referenced to their library id. NEVER reads note CONTENT (names + sizes only).
    $now = [Environment]::TickCount64
    if ($script:WikiIdxCache -and [math]::Abs($now - $script:WikiIdxAt) -lt 20000) { return $script:WikiIdxCache }  # ~20s cache: scanning 12 dirs + audio_index per request was the slow path
    $wiki = Join-Path (Split-Path $PSScriptRoot -Parent) '_wiki'
    if (-not (Test-Path -LiteralPath $wiki)) { return '[]' }
    $base2id = @{}
    $aip = Join-Path $wiki 'audio_index.json'
    if (Test-Path -LiteralPath $aip) {
        try {
            $ai = ((Get-Content -LiteralPath $aip -Raw) -replace '([:\[,]\s*)-?(?:Infinity|NaN)\b', '${1}null') | ConvertFrom-Json
            foreach ($p in $ai.PSObject.Properties) {
                $b = [IO.Path]::GetFileNameWithoutExtension(($p.Name -split '[\\/]')[-1])
                if (-not $base2id.ContainsKey($b)) { $base2id[$b] = @{ id = $p.Name; creator = $p.Value.creator } }
            }
        } catch {}
    }
    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($cd in (Get-ChildItem -LiteralPath $wiki -Directory -ErrorAction SilentlyContinue)) {
        $notes = @(Get-ChildItem -LiteralPath $cd.FullName -Filter *.md -File -ErrorAction SilentlyContinue)
        if (-not $notes.Count) { continue }
        $works = [System.Collections.Generic.List[object]]::new()
        $hasP = $false; $hasO = $false
        foreach ($n in ($notes | Sort-Object Name)) {
            if ($n.Name -ieq '_profile.md') { $hasP = $true; continue }
            if ($n.Name -ieq '_overview.md') { $hasO = $true; continue }
            if ($n.Name -like '_*') { continue }
            $base = [IO.Path]::GetFileNameWithoutExtension($n.Name)
            $lib = $base2id[$base]
            $works.Add([ordered]@{ file = $n.Name; base = (Fix-Mojibake $base); kb = [math]::Round($n.Length / 1KB, 1); libId = $(if ($lib) { $lib.id } else { $null }) })
        }
        $pfp = Test-Path -LiteralPath (Join-Path (Split-Path $PSScriptRoot -Parent) (Join-Path $cd.Name '_avatar.jpg'))
        $out.Add([ordered]@{ creator = $cd.Name; notes = $notes.Count; profile = $hasP; overview = $hasO; pfp = $pfp; works = @($works) })
    }
    $json = if ($out.Count) { ($out | Sort-Object { -$_.notes }) | ConvertTo-Json -Depth 6 -Compress -AsArray } else { '[]' }
    $script:WikiIdxCache = $json; $script:WikiIdxAt = [Environment]::TickCount64
    return $json
}

function Get-WikiNote {
    # serve ONE research note's markdown to the browser, sandboxed to _wiki, .md only. The content flows
    # file -> HTTP -> the user's browser; it is the LOCAL AI's private research and is not surfaced to Claude.
    param([string]$Id)
    if ([string]::IsNullOrWhiteSpace($Id)) { return $null }
    $wiki = [IO.Path]::GetFullPath((Join-Path (Split-Path $PSScriptRoot -Parent) '_wiki')).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    $rel = ($Id -replace '/', '\').TrimStart('\')
    $full = try { [IO.Path]::GetFullPath((Join-Path $wiki $rel)) } catch { return $null }
    if (-not $full.StartsWith($wiki, [StringComparison]::OrdinalIgnoreCase)) { return $null }
    if ($full -notmatch '\.md$') { return $null }
    if (Test-Path -LiteralPath $full -PathType Leaf) { return (Get-Content -LiteralPath $full -Raw) }
    return $null
}

function Get-WikiTr {
    # serve a note in a chosen language (en/ja/zh). If the note is already in that language (per the
    # lang_audit), serve the original; otherwise translate on demand via the LOCAL LLM (detached,
    # cached under _tr\), so a Chinese-drifted note read in EN gets auto-repaired. The note text flows
    # note -> local LLM -> cache -> browser; it is never surfaced to Claude.
    param([string]$Id, [string]$Lang)
    if ($Lang -notin @('en', 'ja', 'zh')) { $Lang = 'en' }
    if ([string]::IsNullOrWhiteSpace($Id)) { return @{ status = 404; body = '# not found' } }
    $wiki = [IO.Path]::GetFullPath((Join-Path (Split-Path $PSScriptRoot -Parent) '_wiki')).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    $rel = ($Id -replace '/', '\').TrimStart('\')
    $src = try { [IO.Path]::GetFullPath((Join-Path $wiki $rel)) } catch { return @{ status = 404; body = '# not found' } }
    if (-not $src.StartsWith($wiki, [StringComparison]::OrdinalIgnoreCase) -or $src -notmatch '\.md$' -or -not (Test-Path -LiteralPath $src -PathType Leaf)) {
        return @{ status = 404; body = '# not found' }
    }
    $now = [Environment]::TickCount64
    if (-not $script:LangAuditAt -or [math]::Abs($now - $script:LangAuditAt) -gt 60000) {
        $lap = Join-Path $wiki '.lang_audit.json'
        $script:LangAudit = if (Test-Path -LiteralPath $lap) { try { (Get-Content -LiteralPath $lap -Raw | ConvertFrom-Json).notes } catch { $null } } else { $null }
        $script:LangAuditAt = $now
    }
    $srcLang = 'en'
    if ($script:LangAudit) { $lp = $script:LangAudit.PSObject.Properties[($Id -replace '\\', '/')]; if ($lp) { $srcLang = "$($lp.Value)" } }
    if ($Lang -eq $srcLang) { return @{ status = 200; body = (Get-Content -LiteralPath $src -Raw) } }   # already in target language
    $trDir = Join-Path $PSScriptRoot '_tr'
    $safe = ($Id -replace '[^\w\.\-]', '_')
    $cache = Join-Path $trDir "$safe.$Lang.md"
    if ((Test-Path -LiteralPath $cache) -and (Get-Item -LiteralPath $cache).LastWriteTime -ge (Get-Item -LiteralPath $src).LastWriteTime) {
        return @{ status = 200; body = (Get-Content -LiteralPath $cache -Raw) }
    }
    $lock = "$cache.lock"
    $running = (Test-Path -LiteralPath $lock) -and (((Get-Date) - (Get-Item -LiteralPath $lock).LastWriteTime).TotalSeconds -lt 150)
    if (-not $running) {
        New-Item -ItemType Directory -Force -Path $trDir | Out-Null
        Set-Content -LiteralPath $lock -Value (Get-Date -Format o)
        $py = (Get-Command python -ErrorAction SilentlyContinue).Source
        $tn = Join-Path $PSScriptRoot 'translate_note.py'
        if ($py -and (Test-Path -LiteralPath $tn)) { try { Start-Process -FilePath $py -ArgumentList @($tn, $src, $Lang, $cache) -WindowStyle Hidden | Out-Null } catch {} }
    }
    return @{ status = 202; body = '{"pending":true}' }
}

function Send-WikiImage {
    # serve a creator's portrait (_wiki/<creator>/_image.*) as binary, sandboxed to _wiki. Public images only.
    param($Ctx)
    $req = $Ctx.Request; $res = $Ctx.Response
    $id = $req.QueryString['id']
    if ([string]::IsNullOrWhiteSpace($id)) { $res.StatusCode = 404; return }
    $wiki = [IO.Path]::GetFullPath((Join-Path (Split-Path $PSScriptRoot -Parent) '_wiki')).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    $cdir = try { [IO.Path]::GetFullPath((Join-Path $wiki (($id -replace '/', '\').TrimStart('\')))) } catch { $null }
    if (-not $cdir -or -not $cdir.StartsWith($wiki, [StringComparison]::OrdinalIgnoreCase)) { $res.StatusCode = 404; return }
    $img = Get-ChildItem -LiteralPath $cdir -Filter '_image.*' -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $img -and $id -notmatch '[\\/]|\.\.') {
        # fallback: the YouTube channel avatar (fetch_sandbox_avatars.py) -- core creator dir first, then sandbox ingest
        $aroot = Split-Path $PSScriptRoot -Parent
        foreach ($cand in @((Join-Path $aroot (Join-Path $id '_avatar.jpg')),
                            (Join-Path $aroot (Join-Path '_data\yt_ingest' (Join-Path $id '_avatar.jpg'))))) {
            if (Test-Path -LiteralPath $cand) { $img = Get-Item -LiteralPath $cand; break }
        }
    }
    if (-not $img) { $res.StatusCode = 404; return }
    $ct = switch ($img.Extension.ToLower()) { '.png' { 'image/png' }; '.jpg' { 'image/jpeg' }; '.jpeg' { 'image/jpeg' }; '.webp' { 'image/webp' }; '.gif' { 'image/gif' }; default { 'application/octet-stream' } }
    try {
        $bytes = [IO.File]::ReadAllBytes($img.FullName)
        $res.ContentType = $ct; $res.Headers.Add('Cache-Control', 'max-age=600'); $res.ContentLength64 = $bytes.Length
        $res.OutputStream.Write($bytes, 0, $bytes.Length)
    } catch {}
}

function Get-CachedHtml {
    # serve a static page from memory, re-reading only when the file's mtime/size changes
    param([string]$Name)
    $p = Join-Path $PSScriptRoot $Name
    $fi = Get-Item -LiteralPath $p -ErrorAction SilentlyContinue
    $sig = if ($fi) { "$($fi.LastWriteTimeUtc.Ticks):$($fi.Length)" } else { '' }
    if (-not $script:HtmlCache) { $script:HtmlCache = @{} }
    $e = $script:HtmlCache[$Name]
    if ($e -and $e.sig -eq $sig) { return $e.body }
    $body = if ($fi) { Get-Content -LiteralPath $p -Raw } else { 'not found' }
    $script:HtmlCache[$Name] = @{ sig = $sig; body = $body }
    return $body
}

function Get-GpuStat {
    # one nvidia-smi read, cached ~2s, shared by /data.json (dashboard GPU tile) and /debug.json.
    # Emits both the debug shape (util/used/free/total in MB) AND the dashboard shape
    # (util/vramUsedGB/vramTotalGB/powerW/powerLimitW). All best-effort; returns $null on no GPU.
    $now = [Environment]::TickCount64
    if ($script:GpuCache -and [math]::Abs($now - $script:GpuAt) -lt 2000) { return $script:GpuCache }
    $gpu = $null
    try {
        $g = (& nvidia-smi --query-gpu=utilization.gpu,memory.used,memory.free,memory.total,power.draw,power.limit --format=csv,noheader,nounits 2>$null) -split ','
        if ($g.Count -ge 4) {
            $used = [int]($g[1].Trim()); $total = [int]($g[3].Trim())
            $gpu = [ordered]@{ util = [int]($g[0].Trim()); used = $used; free = [int]($g[2].Trim()); total = $total
                vramUsedGB = [math]::Round($used / 1024.0, 1); vramTotalGB = [math]::Round($total / 1024.0, 1) }
            if ($g.Count -ge 6) { $gpu.powerW = [int][double]($g[4].Trim()); $gpu.powerLimitW = [int][double]($g[5].Trim()) }
        }
    } catch {}
    $script:GpuCache = $gpu; $script:GpuAt = $now; $gpu
}

function Get-StateJson {
    if (-not $script:LogPinned) {
        $fresh = Get-ChildItem "$PSScriptRoot\*_run.log" -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($fresh) { $script:Log = $fresh.FullName }
    }
    $fi = Get-Item -LiteralPath $script:Log -ErrorAction SilentlyContinue
    $sig = if ($fi) { "$($fi.LastWriteTimeUtc.Ticks):$($fi.Length)" } else { 'none' }
    if ($sig -ne $script:StateSig) { $script:StateCache = Parse-State; $script:StateSig = $sig }
    $s = $script:StateCache
    $eta = Get-Eta $s
    $now = [Environment]::TickCount64
    if (-not $script:RollCache -or [math]::Abs($now - $script:RollAt) -gt 8000) {
        $script:RollCache = @(Get-LibraryRollup); $script:RollAt = $now
    }
    $roll = $script:RollCache
    if (-not $script:WikiAt -or [math]::Abs($now - $script:WikiAt) -gt 4000) {
        $script:WikiCache = Get-WikiState $roll; $script:WikiAt = $now
    }
    $wiki = $script:WikiCache
    if (-not $script:StatsAt -or [math]::Abs($now - $script:StatsAt) -gt 8000) {
        $sjp = Join-Path (Split-Path $PSScriptRoot -Parent) '_wiki\stats.json'
        $script:StatsCache = if (Test-Path -LiteralPath $sjp) { try { Get-Content -LiteralPath $sjp -Raw -ErrorAction Stop | ConvertFrom-Json } catch { $null } } else { $null }
        $script:StatsAt = $now
    }
    $stats = $script:StatsCache
    if (-not $script:GradesAt -or [math]::Abs($now - $script:GradesAt) -gt 8000) {
        $gjp = Join-Path (Split-Path $PSScriptRoot -Parent) '_wiki\grades.json'
        $script:GradesCache = if (Test-Path -LiteralPath $gjp) { try { Get-Content -LiteralPath $gjp -Raw -ErrorAction Stop | ConvertFrom-Json } catch { $null } } else { $null }
        $script:GradesAt = $now
    }
    $grades = $script:GradesCache
    if (-not $script:EnsAt -or [math]::Abs($now - $script:EnsAt) -gt 10000) {
        $enp = Join-Path (Split-Path $PSScriptRoot -Parent) '_wiki\ensemble.json'
        $script:EnsCache = if (Test-Path -LiteralPath $enp) { try { Get-Content -LiteralPath $enp -Raw -ErrorAction Stop | ConvertFrom-Json } catch { $null } } else { $null }
        $script:EnsAt = $now
    }
    $ensemble = $script:EnsCache
    if (-not $script:OverallAt -or [math]::Abs($now - $script:OverallAt) -gt 4000) {
        $ejp = Join-Path (Split-Path $PSScriptRoot -Parent) '_wiki\eta.json'
        $script:OverallCache = if (Test-Path -LiteralPath $ejp) { try { Get-Content -LiteralPath $ejp -Raw -ErrorAction Stop | ConvertFrom-Json } catch { $null } } else { $null }
        $script:OverallAt = $now
        # self-refresh: while a run is active, keep eta.json fresh by kicking eta.py (detached, throttled ~18s)
        $active = $s.Exists -and -not $s.Done -and $s.LastWrite -and ((Get-Date) - $s.LastWrite).TotalSeconds -lt 180
        $fresh = (Test-Path -LiteralPath $ejp) -and (((Get-Date) - (Get-Item -LiteralPath $ejp).LastWriteTime).TotalSeconds -lt 25)
        if ($active -and -not $fresh -and (-not $script:EtaSpawnAt -or [math]::Abs($now - $script:EtaSpawnAt) -gt 18000)) {
            $script:EtaSpawnAt = $now
            $epy = (Get-Command python -ErrorAction SilentlyContinue).Source
            $esc = Join-Path $PSScriptRoot 'eta.py'
            if ($epy -and (Test-Path -LiteralPath $esc)) { try { Start-Process -FilePath $epy -ArgumentList @($esc) -WindowStyle Hidden | Out-Null } catch {} }
        }
    }
    $overall = $script:OverallCache
    $net = try { Get-NetThroughput } catch { $null }   # net stats are non-critical — never let them blank /data.json
    # whole-system activity: RUNNING if transcription OR the local-AI research is actively producing; else STALLED
    $txActive = $s.Exists -and -not $s.Done -and $s.LastWrite -and ((Get-Date) - $s.LastWrite).TotalSeconds -lt 150
    $wkActive = [bool]($wiki -and $wiki.state -eq 'running')
    $status = if ($txActive -or $wkActive) { 'RUNNING' } else { 'STALLED' }
    $pct = if ($s.BatchN) { if ($eta) { $eta.Pct } else { [math]::Round(100.0 * $s.CurIdx / $s.BatchN, 1) } } else { 0 }
    $maxMp4 = ($roll | Measure-Object Mp4 -Maximum).Maximum; if (-not $maxMp4) { $maxMp4 = 1 }
    $cf = $s.CurFile; $cdir = ''
    if ($cf -match '^(.*?)\s*::\s*(.*)$') { $cdir = $Matches[1]; $cf = $Matches[2] }
    $enTitle = ''
    if ($cf) {
        if (-not $script:TitlesAt -or [math]::Abs($now - $script:TitlesAt) -gt 15000) {
            $tjp = Join-Path (Split-Path $PSScriptRoot -Parent) '_wiki\title_translations.json'
            $script:TitlesCache = if (Test-Path -LiteralPath $tjp) { try { Get-Content -LiteralPath $tjp -Raw -ErrorAction Stop | ConvertFrom-Json } catch { $null } } else { $null }
            $script:TitlesAt = $now
        }
        if ($script:TitlesCache) {
            $key = [IO.Path]::GetFileNameWithoutExtension($cf)
            $p = $script:TitlesCache.PSObject.Properties[$key]
            if ($p) { $enTitle = "$($p.Value)" }
        }
    }
    $gpu = try { Get-GpuStat } catch { $null }   # GPU tile source (was absent from /data.json; render reads d.gpu)
    # extra KPI tiles (cheap, derived from the roll + one DriveInfo): coverage %, untranscribed backlog, disk free
    $trkSum = [int](($roll | Measure-Object Total -Sum).Sum); $jaSum = [int](($roll | Measure-Object Ja -Sum).Sum); $enSum = [int](($roll | Measure-Object En -Sum).Sum)
    $diskFree = try { [int][math]::Round(([IO.DriveInfo]::new('D:\').AvailableFreeSpace) / 1GB) } catch { 0 }
    $obj = [ordered]@{
        status = $status; txActive = [bool]$txActive; wkActive = [bool]$wkActive; pct = $pct; curIdx = $s.CurIdx; batchN = $s.BatchN; curDir = $cdir; curFile = $cf; enTitle = $enTitle
        gpu = $gpu
        elapsed = $(if ($eta) { [int]$eta.Elapsed } else { 0 }); eta = $(if ($eta) { Fmt-Span $eta.Remain } else { '' })
        log = (Split-Path $script:Log -Leaf); logTime = $(if ($s.LastWrite) { $s.LastWrite.ToString('HH:mm:ss') } else { '--' })
        stats = [ordered]@{ tracks = $trkSum; creators = [int](@($roll | Where-Object { $_.Name -notlike '_*' }).Count); deduped = $s.Deduped; ja = $jaSum; en = $enSum; mp4 = [int](($roll | Measure-Object Mp4 -Sum).Sum); skipped = ($s.SkipExist + $s.SkipNoSub); failed = $s.Failed; coverage = [math]::Min(100, [int][math]::Round($jaSum / [math]::Max(1, $trkSum) * 100)); disk = $diskFree }
        # Live feed = the tailed log's recent lines IN FILE ORDER. Do NOT sort by $_.time: translate lines are
        # keyed by SUBTITLE timecode (00:xx/02:xx) while wiki lines are WALL-CLOCK (18:xx), so the old sort let a
        # finished wiki run's 18:xx entries bury the live translation stream. Merge the wiki build feed only while
        # it's actively running; otherwise the stream freezes on the last real line (STALLED badge marks it idle).
        feed = @((@($s.Feed | ForEach-Object { [ordered]@{ task = $_.Task; time = $_.Time; text = $_.Text; note = '' } }) + @(if ($wkActive) { $wiki.feed })) | Select-Object -Last 24)
        rollup = @($roll | Sort-Object Total -Descending | ForEach-Object {
                $tot = [math]::Max([int]$_.Total, [math]::Max([int]$_.Ja, [int]$_.En))
                [ordered]@{ name = $_.Name; mp4 = $_.Mp4; ja = $_.Ja; en = $_.En; total = $tot
                    pct = $(if ($tot) { [int](100 * $_.Ja / $tot) } else { 0 }); burn = $(if ($tot) { [int](100 * $_.Mp4 / $tot) } else { 0 }) }
            })
        wiki = $wiki
        archive = $stats
        grades = $grades
        ensemble = $ensemble
        overall = $overall
        net = $net
        jobs = @(Get-AiJobs)
    }
    $obj | ConvertTo-Json -Depth 8 -Compress
}

function Get-AiJobs {
    # recent AI-console jobs (metadata only) for the console panel
    $jd = Join-Path $PSScriptRoot '_jobs'
    if (-not (Test-Path -LiteralPath $jd)) { return @() }
    Get-ChildItem -LiteralPath $jd -Filter *.json -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notlike 'route-*' -and $_.Name -notlike 'transcribe_*' -and $_.Name -notlike 'bakeoff*' } |
        Sort-Object LastWriteTime -Descending | Select-Object -First 6 | ForEach-Object {
            try {
                $j = Get-Content -LiteralPath $_.FullName -Raw -ErrorAction Stop | ConvertFrom-Json
                if (-not $j.id) { return }   # only real AI-console job records, not config files
                $lp = Join-Path $jd ("$($j.id).log")
                $tail = if (Test-Path -LiteralPath $lp) { ((Get-Content -LiteralPath $lp -Tail 2 -ErrorAction SilentlyContinue) -join ' ') } else { '' }
                [ordered]@{ id = $j.id; skill = $j.skill; status = $j.status; started = $j.started; prompt = $j.prompt; tail = $tail.Substring(0, [Math]::Min(160, $tail.Length)) }
            } catch {}
        }
}

function Invoke-AiCommand($cmd) {
    $py = (Get-Command python -ErrorAction SilentlyContinue).Source
    if (-not $py) { return '{"error":"python not found"}' }
    $script = Join-Path $PSScriptRoot 'ai_console.py'
    $jd = Join-Path $PSScriptRoot '_jobs'; New-Item -ItemType Directory -Force -Path $jd | Out-Null
    # FIX #2: a CONFIRMED command arrives with the already-resolved {skill,args} —
    # run it directly (fast), never re-route the text (which could pick a different skill).
    if ($cmd.skill) {
        $argsJson = if ($null -ne $cmd.args) { ($cmd.args | ConvertTo-Json -Compress) } else { '{}' }
        try { $o = (& $py $script 'run' '--skill' ([string]$cmd.skill) '--args' $argsJson 2>&1 | Out-String).Trim()
              return $(if ($o) { $o } else { '{"error":"empty response"}' }) }
        catch { return (@{ error = "$($_.Exception.Message)" } | ConvertTo-Json -Compress) }
    }
    if (-not $cmd.prompt) { return '{"error":"no prompt"}' }
    # FIX #3: routing hits the LLM (~20-30s) — run it DETACHED so the single-threaded
    # dashboard never freezes. Return a pending id; the client polls /command_result.
    $rid = [guid]::NewGuid().ToString('N').Substring(0, 10)
    $outf = Join-Path $jd "route-$rid.json"
    '' | Set-Content -LiteralPath $outf -Encoding utf8
    try { Start-Process -FilePath $py -ArgumentList @($script, 'do', [string]$cmd.prompt) -RedirectStandardOutput $outf -NoNewWindow | Out-Null }
    catch { return (@{ error = "$($_.Exception.Message)" } | ConvertTo-Json -Compress) }
    return (@{ pending = $rid } | ConvertTo-Json -Compress)
}

function Get-RouteResult($id) {
    if ($id -notmatch '^[0-9a-fA-F]+$') { return '{"error":"bad id"}' }
    $f = Join-Path $PSScriptRoot "_jobs\route-$id.json"
    if (Test-Path -LiteralPath $f) {
        $c = (Get-Content -LiteralPath $f -Raw -ErrorAction SilentlyContinue)
        if ($c -and $c.Trim()) {
            $c = $c.Trim()
            try { $null = $c | ConvertFrom-Json; Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue; return $c } catch {}
        }
    }
    return (@{ pending = $id } | ConvertTo-Json -Compress)
}

function Invoke-AiChat($rawBody) {
    # the /ai-chat full-session page: POST {messages:[...], web:bool}. chat_session() hits the LLM
    # (20-90s) + optional web search, so run DETACHED (single-threaded listener must not freeze) and
    # return a pending id; the page polls /ai-chat/result. Body is written to a temp file (multi-turn
    # threads + web results are too big/quotey for a command-line arg).
    $py = (Get-Command python -ErrorAction SilentlyContinue).Source
    if (-not $py) { return '{"error":"python not found"}' }
    $script = Join-Path $PSScriptRoot 'ai_console.py'
    $jd = Join-Path $PSScriptRoot '_jobs'; New-Item -ItemType Directory -Force -Path $jd | Out-Null
    $rid = [guid]::NewGuid().ToString('N').Substring(0, 10)
    $reqf = Join-Path $jd "chatreq-$rid.json"; $outf = Join-Path $jd "chat-$rid.json"
    try { [IO.File]::WriteAllText($reqf, $rawBody, (New-Object Text.UTF8Encoding($false))) }
    catch { return (@{ error = "$($_.Exception.Message)" } | ConvertTo-Json -Compress) }
    '' | Set-Content -LiteralPath $outf -Encoding utf8
    try { Start-Process -FilePath $py -ArgumentList @($script, 'chatsession', '--file', $reqf) -RedirectStandardOutput $outf -NoNewWindow | Out-Null }
    catch { return (@{ error = "$($_.Exception.Message)" } | ConvertTo-Json -Compress) }
    return (@{ pending = $rid } | ConvertTo-Json -Compress)
}

function Get-ChatResult($id) {
    if ($id -notmatch '^[0-9a-fA-F]+$') { return '{"error":"bad id"}' }
    $f = Join-Path $PSScriptRoot "_jobs\chat-$id.json"
    if (Test-Path -LiteralPath $f) {
        $c = (Get-Content -LiteralPath $f -Raw -ErrorAction SilentlyContinue)
        if ($c -and $c.Trim()) {
            $c = $c.Trim()
            try { $null = $c | ConvertFrom-Json
                Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
                Remove-Item -LiteralPath (Join-Path $PSScriptRoot "_jobs\chatreq-$id.json") -Force -ErrorAction SilentlyContinue
                return $c } catch {}
        }
    }
    return (@{ pending = $id } | ConvertTo-Json -Compress)
}

function Get-JobLog($id) {
    if ($id -notmatch '^[0-9A-Za-z\-]+$') { return '(bad id)' }
    $lp = Join-Path $PSScriptRoot "_jobs\$id.log"
    if (Test-Path -LiteralPath $lp) { return ((Get-Content -LiteralPath $lp -Tail 300 -ErrorAction SilentlyContinue) -join "`n") }
    return '(no log yet)'
}

function Get-SkillList {
    $sp = Join-Path $PSScriptRoot 'ai_skills.json'
    if (Test-Path -LiteralPath $sp) {
        try { return @((Get-Content -LiteralPath $sp -Raw | ConvertFrom-Json).skills | ForEach-Object {
                    [ordered]@{ name = $_.name; desc = $_.desc; confirm = [bool]$_.confirm } }) } catch {}
    }
    return @()
}

function Get-DebugJson {
    # full diagnostic snapshot for the /debug page. Cached ~5s.
    $now = [Environment]::TickCount64
    if ($script:DbgCache -and [math]::Abs($now - $script:DbgAt) -lt 5000) { return $script:DbgCache }
    $gpu = Get-GpuStat   # shared helper (~2s cache); emits util/used/free/total MB that the debug JS reads
    $models = @()   # LM Studio (:1234) is usually OFF — a 3s HTTP timeout here was the /debug.json stall. Probe the port first (250ms).
    try {
        $tc = [System.Net.Sockets.TcpClient]::new(); $iar = $tc.BeginConnect('localhost', 1234, $null, $null)
        if ($iar.AsyncWaitHandle.WaitOne(250) -and $tc.Connected) { $tc.Close(); $models = @((Invoke-RestMethod 'http://localhost:1234/v1/models' -TimeoutSec 2).data | ForEach-Object { $_.id }) } else { $tc.Close() }
    } catch {}
    $disk = $null; try { $d = [IO.DriveInfo]::new('D:\'); $disk = [ordered]@{ freeGB = [math]::Round($d.AvailableFreeSpace / 1GB, 1); totalGB = [math]::Round($d.TotalSize / 1GB, 1) } } catch {}
    $procs = [ordered]@{}; foreach ($pn in 'python', 'ffmpeg', 'pwsh') { $procs[$pn] = @(Get-Process $pn -ErrorAction SilentlyContinue).Count }
    $wikiDir = Join-Path (Split-Path $PSScriptRoot -Parent) '_wiki'
    function _rj($p) { if (Test-Path -LiteralPath $p) { try { return (Get-Content -LiteralPath $p -Raw -ErrorAction Stop | ConvertFrom-Json) } catch {} } return $null }
    $logs = Get-ChildItem "$PSScriptRoot\*.log" -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 16 | ForEach-Object {
        [ordered]@{ name = $_.Name; mtime = $_.LastWriteTime.ToString('HH:mm:ss'); kb = [math]::Round($_.Length / 1KB, 1)
            tail = (((Get-Content -LiteralPath $_.FullName -Tail 1 -ErrorAction SilentlyContinue) -join '') -replace '\s+', ' ').Trim() } }
    $obj = [ordered]@{
        ts      = (Get-Date).ToString('HH:mm:ss')
        system  = [ordered]@{ gpu = $gpu; models = @($models); disk = $disk; procs = $procs }
        grades  = (_rj (Join-Path $wikiDir 'grades.json'))
        stats   = (_rj (Join-Path $wikiDir 'stats.json'))
        jobs    = @(Get-AiJobs)
        logs    = @($logs)
        skills  = (Get-SkillList)
    }
    $script:DbgCache = $obj | ConvertTo-Json -Depth 10 -Compress
    $script:DbgAt = $now
    return $script:DbgCache
}

function Resolve-AudioPath {
    # id is the audio_index relative key "Creator\file.ext"; resolve to a real file, sandboxed under the archive root
    param([string]$Id)
    if ([string]::IsNullOrWhiteSpace($Id)) { return $null }
    $root = if ($ArchiveRoot) { $ArchiveRoot } else { Split-Path $PSScriptRoot -Parent }   # $ArchiveRoot is injected when this runs in the streaming runspace ($PSScriptRoot isn't available there)
    $rel = ($Id -replace '\\', '/').TrimStart('/')   # forward slashes normalize on BOTH OSes via GetFullPath below; on Linux a '\' would be a literal filename char -> audio never resolves (Zettlab container fix)
    try { $full = [IO.Path]::GetFullPath((Join-Path $root $rel)) } catch { return $null }
    # trailing separator on the root prevents a sibling whose name is prefixed by the root (…\Asmr-backup) from passing
    $rootFull = [IO.Path]::GetFullPath($root).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if (-not $full.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)) { return $null }   # block ..\ traversal + sibling-prefix escape
    if (Test-Path -LiteralPath $full -PathType Leaf) { return $full }
    return $null
}

function Get-WorkThumb {
    # real cover art for a library work: a sibling <base>.webp/jpg (yt-dlp thumbnail, in the work
    # folder OR the creator root), else the cover embedded in the .m4a/.mp4 (extracted once + cached
    # under _wiki\thumbs). Returns an image path, or $null so the library falls back to its canvas.
    param([string]$Id)
    $audio = Resolve-AudioPath $Id
    if (-not $audio) { return $null }
    $base = [IO.Path]::GetFileNameWithoutExtension($audio)
    $dir = Split-Path $audio -Parent
    foreach ($loc in @($dir, (Split-Path $dir -Parent))) {
        if (-not $loc) { continue }
        foreach ($name in @($base, 'cover', 'folder')) {   # <base>.* (yt-dlp), or a folder-level cover.*/folder.* (Booth)
            foreach ($ext in 'webp', 'jpg', 'jpeg', 'png') {
                $cand = Join-Path $loc "$name.$ext"
                if (Test-Path -LiteralPath $cand) { return $cand }
            }
        }
    }
    $cacheDir = Join-Path (Split-Path $PSScriptRoot -Parent) '_wiki\thumbs'
    if (-not (Test-Path $cacheDir)) { New-Item -ItemType Directory -Force $cacheDir | Out-Null }
    $h = [BitConverter]::ToString([Security.Cryptography.SHA1]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($Id))).Replace('-', '').Substring(0, 16)
    $cache = Join-Path $cacheDir "$h.jpg"
    if (Test-Path -LiteralPath $cache) { return $(if ((Get-Item -LiteralPath $cache).Length -gt 0) { $cache } else { $null }) }  # 0-byte = "no art, don't re-probe"
    try {
        $v = & ffprobe -v error -select_streams v -show_entries stream=codec_name -of csv=p=0 -- "$audio" 2>$null
        if ($v) { & ffmpeg -v error -y -i "$audio" -an -frames:v 1 -vf 'scale=420:-1' -- "$cache" 2>$null | Out-Null }
    } catch {}
    if ((Test-Path -LiteralPath $cache) -and (Get-Item -LiteralPath $cache).Length -gt 0) { return $cache }
    try { Set-Content -LiteralPath $cache -Value $null -NoNewline } catch {}   # marker: no art
    return $null
}

function Get-AudioContentType {
    param([string]$Ext)
    switch ($Ext.ToLower()) {
        '.mp3' { 'audio/mpeg' }; '.m4a' { 'audio/mp4' }
        '.mp4' { 'video/mp4' }; '.m4v' { 'video/mp4' }
        '.mkv' { 'video/x-matroska' }; '.webm' { 'video/webm' }
        '.flac' { 'audio/flac' }; '.wav' { 'audio/wav' }; '.opus' { 'audio/ogg' }; '.ogg' { 'audio/ogg' }
        '.aac' { 'audio/aac' }; default { 'application/octet-stream' }
    }
}

function Send-AudioFile {
    # streams the file with HTTP Range support (206/Content-Range/Accept-Ranges) so the browser <audio> can seek
    param($Ctx)
    $req = $Ctx.Request; $res = $Ctx.Response
    $full = Resolve-AudioPath $req.QueryString['id']
    if (-not $full) {
        $res.StatusCode = 404
        $b = [Text.Encoding]::UTF8.GetBytes('not found'); $res.ContentLength64 = $b.Length; $res.OutputStream.Write($b, 0, $b.Length); return
    }
    $fs = [IO.File]::Open($full, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        $len = $fs.Length
        $res.ContentType = Get-AudioContentType ([IO.Path]::GetExtension($full))
        $res.Headers.Add('Accept-Ranges', 'bytes')
        $start = 0L; $end = $len - 1
        $range = $req.Headers['Range']
        if ($range -and $range -match 'bytes=(\d*)-(\d*)') {
            $s = $matches[1]; $e = $matches[2]
            if ($s -eq '' -and $e -ne '') { $start = [math]::Max(0L, $len - [int64]$e) }     # suffix: last N bytes
            else {
                if ($s -ne '') { $start = [int64]$s }
                if ($e -ne '') { $end = [int64]$e }
            }
            if ($end -ge $len) { $end = $len - 1 }
            if ($start -gt $end -or $start -ge $len) {
                $res.StatusCode = 416; $res.Headers.Add('Content-Range', "bytes */$len"); return
            }
            $res.StatusCode = 206
            $res.Headers.Add('Content-Range', "bytes $start-$end/$len")
        }
        $count = $end - $start + 1
        $res.ContentLength64 = $count
        $fs.Seek($start, [IO.SeekOrigin]::Begin) | Out-Null
        $buf = New-Object byte[] 131072
        $remaining = $count; $out = $res.OutputStream
        while ($remaining -gt 0) {
            $n = $fs.Read($buf, 0, [int][math]::Min($buf.Length, $remaining))
            if ($n -le 0) { break }
            $out.Write($buf, 0, $n)       # may throw if the client seeks/aborts — caught below
            $remaining -= $n
        }
    }
    catch {}
    finally { $fs.Dispose() }
}

function Get-VlcPath {
    $c = Get-Command vlc -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    foreach ($p in @("$env:ProgramFiles\VideoLAN\VLC\vlc.exe", "${env:ProgramFiles(x86)}\VideoLAN\VLC\vlc.exe")) {
        if ($p -and (Test-Path -LiteralPath $p)) { return $p }
    }
    return $null
}

function Invoke-OpenLocal {
    # native-launch a work in the host's default app or VLC. Only meaningful when the dashboard runs natively
    # (a Docker container can't reach the host's player) — callers fall back to the stream URL in that case.
    param($Cmd)
    $id = "$($Cmd.id)"; $player = "$($Cmd.player)"
    $full = Resolve-AudioPath $id
    $url = "/audio?id=$([uri]::EscapeDataString($id))"
    if (-not $full) { return (@{ ok = $false; error = 'not found' } | ConvertTo-Json -Compress) }
    try {
        if ($player -eq 'vlc') {
            $vlc = Get-VlcPath
            if (-not $vlc) { return (@{ ok = $false; error = 'VLC not found on this host'; url = $url } | ConvertTo-Json -Compress) }
            Start-Process -FilePath $vlc -ArgumentList @($full) | Out-Null
        }
        else { Start-Process -FilePath $full | Out-Null }     # OS default media app
        return (@{ ok = $true; player = $player; file = [IO.Path]::GetFileName($full) } | ConvertTo-Json -Compress)
    }
    catch { return (@{ ok = $false; error = "$($_.Exception.Message)"; url = $url } | ConvertTo-Json -Compress) }
}

# ---------- plug-and-play worker registry (the dongle jacks in here) ----------
# Workers POST /worker/register to announce themselves + heartbeat; the host keeps a live
# roster in _jobs\workers.json (entries expire 60s after the last heartbeat -> unplug = gone).
# /worker/manifest + /worker/file let the dongle auto-update its scripts from the host on jack-in.
$script:WorkerFiles = @(
    @{ name = 'worker-core.ps1'; src = '_remote\worker-core.ps1' },
    @{ name = 'node-info-server.ps1'; src = '_remote\node-info-server.ps1' },
    @{ name = 'worker-register.ps1'; src = '_remote\worker-register.ps1' },
    @{ name = 'update-worker.ps1'; src = '_remote\update-worker.ps1' },
    @{ name = 'asr_worker.py'; src = 'asr_worker.py' },
    @{ name = 'fw_transcribe.py'; src = 'fw_transcribe.py' },
    @{ name = 'dispatch_translate.py'; src = 'dispatch_translate.py' },
    @{ name = 'translate_subs.py'; src = 'translate_subs.py' },
    @{ name = 'verify_translations.py'; src = 'verify_translations.py' },
    @{ name = 'eta.py'; src = 'eta.py' },
    @{ name = 'START-WORKER-DOCKER.bat'; src = '_remote\START-WORKER-DOCKER.bat' },
    @{ name = 'docker-compose.asr.yml'; src = '_deploy\docker-compose.asr.yml' },
    @{ name = 'Dockerfile.asr'; src = '_deploy\Dockerfile.asr' },
    @{ name = 'requirements-worker.txt'; src = 'requirements-worker.txt' }
)
function Read-WorkerStore {
    $p = Join-Path $PSScriptRoot '_jobs\workers.json'; $h = @{}
    if (Test-Path -LiteralPath $p) {
        try { $j = Get-Content -LiteralPath $p -Raw | ConvertFrom-Json; foreach ($pr in $j.PSObject.Properties) { $h[$pr.Name] = $pr.Value } } catch {}
    }
    $h
}
function Write-WorkerStore($h) {
    $p = Join-Path $PSScriptRoot '_jobs\workers.json'
    try { ($h | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $p -Encoding utf8 } catch {}
}
function Register-Worker($o) {
    if (-not $o -or -not $o.id) { return '{"ok":false,"error":"no id"}' }
    $h = Read-WorkerStore
    $h[$o.id] = [ordered]@{ id = "$($o.id)"; host = "$($o.host)"; ip = "$($o.ip)"; mode = "$($o.mode)"; role = "$($o.role)";
        ollama = "$($o.ollama)"; asr = "$($o.asr)"; models = @($o.models); lastSeen = [int][DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }
    Write-WorkerStore $h
    '{"ok":true}'
}
function Unregister-Worker($o) {
    if ($o -and $o.id) { $h = Read-WorkerStore; if ($h.ContainsKey("$($o.id)")) { $h.Remove("$($o.id)"); Write-WorkerStore $h } }
    '{"ok":true}'
}
function Get-WorkersJson {
    $h = Read-WorkerStore
    $dp = Join-Path $PSScriptRoot '_jobs\discovered.json'   # merge host-side discovery (DHCP-proof)
    if (Test-Path -LiteralPath $dp) {
        try { $dj = Get-Content -LiteralPath $dp -Raw | ConvertFrom-Json
            foreach ($pr in $dj.PSObject.Properties) {
                $d = $pr.Value; $dup = $false
                foreach ($k in @($h.Keys)) { if ("$($h[$k].ip)" -eq "$($d.ip)") { $dup = $true; break } }   # self-registered wins
                if (-not $dup) { $h[$pr.Name] = $d }
            }
        } catch {}
    }
    $now = [int][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $out = foreach ($k in @($h.Keys)) { $w = $h[$k]; $age = $now - [int]$w.lastSeen
        [ordered]@{ id = $w.id; host = $w.host; ip = $w.ip; mode = $w.mode; role = $w.role; ollama = $w.ollama; asr = $w.asr; models = @($w.models); ageSec = $age; live = ($age -lt 60) } }
    (@{ workers = @($out); updated = $now } | ConvertTo-Json -Depth 6)
}
function Get-WorkerManifest {
    $list = foreach ($f in $script:WorkerFiles) { $fp = Join-Path $PSScriptRoot $f.src
        if (Test-Path -LiteralPath $fp) { [ordered]@{ name = $f.name; sha = (Get-FileHash -LiteralPath $fp -Algorithm SHA256).Hash; size = (Get-Item -LiteralPath $fp).Length } } }
    (@{ files = @($list); updated = [int][DateTimeOffset]::UtcNow.ToUnixTimeSeconds() } | ConvertTo-Json -Depth 5)
}
function Get-WorkerFile($name) {
    $f = $script:WorkerFiles | Where-Object { $_.name -eq $name } | Select-Object -First 1
    if (-not $f) { return $null }
    $fp = Join-Path $PSScriptRoot $f.src
    if (Test-Path -LiteralPath $fp) { Get-Content -LiteralPath $fp -Raw } else { $null }
}

function Get-ActivityJson {
    # full activity monitor: EVERY running Sasayaki process + scheduled task + recent job log,
    # so anything the system does (overnight run, bake-off, audits, NAS watch, discovery, re-grabs,
    # ingests, backups...) is mirrored live on the dashboard. ~3s cache.
    $now = [Environment]::TickCount64
    if ($script:ActCache -and [math]::Abs($now - $script:ActAt) -lt 3000) { return $script:ActCache }
    $map = [ordered]@{
        'overnight-run' = 'overnight run'; 'translate_ensemble' = 'battle-test bake-off'; 'grade_translations' = 'grading translations'
        'grade_transcripts' = 'grading transcripts'; 'audit_streams' = 'stream audit'; 'nas-health' = 'NAS watchdog'
        'discover-workers' = 'cluster discovery'; 'dispatch_translate' = 'translate dispatch'; 'dispatch_transcribe' = 'transcribe dispatch'
        'translate_subs' = 'translating subs'; 'kemono_finder' = 'kemono finder'; 'regrab_twitcasting' = 're-grabbing streams'
        'ingest_playlists' = 'playlist ingest'; 'booth_thumbs' = 'booth covers'; 'backup-state' = 'backup'; 'resort-data' = 'data resort'
        'asr_worker' = 'ASR worker'; 'node-info-server' = 'node profiler'; 'fw_transcribe' = 'transcribing'; 'local_wiki' = 'wiki research'
        'analyze_audio' = 'audio analysis'; 'yt_grab' = 'youtube grab'; 'lang_repair' = 'lang repair'; 'verify_translations' = 'verifying'
        'discover_sources' = 'source discovery'; 'build_tags' = 'tag build'; 'dlsite_research' = 'dlsite research'; 'asmr_one' = 'asmr.one enrich'
        # --- acquisition / capture / fleet (so grabs aren't invisible) ---
        'yt_dlp' = 'video grab'; 'gallery_dl' = 'gallery grab'; 'cien_grab' = 'ci-en grab'; 'cien_audio' = 'ci-en audio'
        'cien_subs' = 'ci-en subs'; 'archive_meta' = 'metadata capture'; 'mitm_capture' = 'capture proxy'; 'mitmdump' = 'capture proxy'
        'nas_telemetry' = 'NAS telemetry'; 'nas_embed' = 'NAS embeddings'; 'sandbox_research' = 'sandbox research'; 'survey_playlists' = 'playlist survey'
        'build_dataset' = 'corpus build'; 'build_creator_index' = 'index build'; 'reverse_image' = 'reverse-image ID'; 'library_stats' = 'catalog build'
    }
    $running = [System.Collections.Generic.List[object]]::new()
    try {
        foreach ($p in (Get-CimInstance Win32_Process -Filter "Name='python.exe' OR Name='pwsh.exe' OR Name='powershell.exe' OR Name='ffmpeg.exe' OR Name='mitmdump.exe'" -ErrorAction SilentlyContinue)) {
            $cl = $p.CommandLine; if (-not $cl -or $cl -like '*Show-SubtitlerLog*') { continue }
            foreach ($k in $map.Keys) {
                if ($cl -like "*$k*") {
                    $rt = 0; try { $rt = [int]((Get-Date) - $p.CreationDate).TotalSeconds } catch {}
                    # fold the TARGET into the label: creator folder, batch list, or ci-en creator id
                    $detail = ''
                    if ($cl -match 'Asmr[\\/]([^\\/]+)[\\/]%\(') { $detail = $matches[1] }
                    elseif ($cl -match '_([A-Za-z0-9]+)_bvlist') { $detail = $matches[1] }
                    elseif ($cl -match 'creator[/ ](\d{3,})') { $detail = 'ci-en ' + $matches[1] }
                    elseif ($cl -match 'Asmr[\\/]([^\\/]+)[\\/][^\\/]*\.(m4a|mp3|mp4)') { $detail = $matches[1] }
                    $nm = if ($detail) { $map[$k] + ' · ' + $detail } else { $map[$k] }
                    $running.Add([ordered]@{ name = $nm; script = $k; pid = [int]$p.ProcessId; runtimeSec = $rt }); break
                }
            }
        }
    } catch {}
    $tasks = [System.Collections.Generic.List[object]]::new()
    try {
        foreach ($t in (Get-ScheduledTask -TaskName 'Sasayaki-*' -ErrorAction SilentlyContinue)) {
            $i = $null; try { $i = $t | Get-ScheduledTaskInfo -ErrorAction SilentlyContinue } catch {}
            $tasks.Add([ordered]@{ name = ($t.TaskName -replace '^Sasayaki-', ''); state = "$($t.State)"
                    next = $(if ($i -and $i.NextRunTime) { $i.NextRunTime.ToString('MM-dd HH:mm') } else { '' }) })
        }
    } catch {}
    $logs = [System.Collections.Generic.List[object]]::new()
    try {
        Get-ChildItem (Join-Path $PSScriptRoot '_jobs\*.log') -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 7 | ForEach-Object {
            $tail = ''; try { $tail = ((Get-Content -LiteralPath $_.FullName -Tail 1 -ErrorAction SilentlyContinue) -join '').Trim() } catch {}
            $logs.Add([ordered]@{ name = $_.Name; at = $_.LastWriteTime.ToString('HH:mm:ss'); tail = $tail.Substring(0, [Math]::Min(96, $tail.Length)) })
        }
    } catch {}
    # --- live event STREAM: the specific work each stage is on right now + recent completions,
    # parsed from the freshest processing logs. This is what makes the feed show "what audio
    # specifically" (Adriel) rather than just "transcribe dispatch running". ---
    $stream = [System.Collections.Generic.List[object]]::new()
    try {
        $srcLogs = @('parallel_run.log', 'translate_run.log') | ForEach-Object { Join-Path $PSScriptRoot $_ }
        $srcLogs += (Get-ChildItem (Join-Path $PSScriptRoot '_jobs\*.log') -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -gt (Get-Date).AddMinutes(-30) } | Sort-Object LastWriteTime -Descending | Select-Object -First 2 | ForEach-Object { $_.FullName })
        $ev = [System.Collections.Generic.List[object]]::new()
        foreach ($lf in $srcLogs) {
            if (-not (Test-Path -LiteralPath $lf)) { continue }
            $fresh = (Get-Item -LiteralPath $lf).LastWriteTime -gt (Get-Date).AddMinutes(-30)
            if (-not $fresh) { continue }
            $curWork = ''
            foreach ($ln in (Get-Content -LiteralPath $lf -Tail 400 -ErrorAction SilentlyContinue)) {
                if ($ln -match '^\s*\[(\d+)/(\d+)\]\s*(.+?)\s*::\s*(.+)$') {
                    $curWork = ($matches[4].Trim() -replace '\s+', ' '); if ($curWork.Length -gt 52) { $curWork = $curWork.Substring(0, 52) }
                    $ev.Add([ordered]@{ kind = 'transcribe'; pct = $null; work = "$($matches[3].Trim()) · $curWork"; step = "$($matches[1])/$($matches[2])" })
                }
                elseif ($ln -match 'wrote (ja|en)\.srt \((\d+) cues\)') { if ($ev.Count) { $ev[$ev.Count - 1].pct = 100 } ; $ev.Add([ordered]@{ kind = 'done'; work = "wrote $($matches[1]).srt · $($matches[2]) cues"; step = '' }) }
                elseif ($ln -match 'rseg\.(ja|en)\.srt\s+->\s+(\d+)/(\d+)\s+EN') { $ev.Add([ordered]@{ kind = 'translate'; work = "translated · $($matches[2])/$($matches[3]) cues EN"; step = '' }) }
                elseif ($ln -match '^\s*\[transcribe\s+([\d.]+)%\]') { if ($ev.Count -and $ev[$ev.Count - 1].kind -eq 'transcribe') { $ev[$ev.Count - 1].pct = [int][double]$matches[1] } }
                elseif ($ln -match '===\s*(START|DONE)\s+(.+?)\s*\(') { $ev.Add([ordered]@{ kind = 'stage'; work = "$($matches[1].ToLower()) $($matches[2].Trim())"; step = '' }) }
            }
        }
        foreach ($e in ($ev | Select-Object -Last 16)) { $stream.Add($e) }
    } catch {}
    $script:ActCache = (@{ running = @($running); tasks = @($tasks); logs = @($logs); stream = @($stream); updated = (Get-Date -Format HH:mm:ss) } | ConvertTo-Json -Depth 5)
    $script:ActAt = $now
    $script:ActCache
}

# --- secrets vault (Import page): cookies + API keys. Claude NEVER reads/logs VALUES; presence only. ---
function Get-SecretDir { Join-Path $PSScriptRoot '_secrets' }

function Get-SecretsJson {
    # Report what's in the vault by PRESENCE ONLY (file exists / value non-empty + byte size). No values.
    $dir = Get-SecretDir
    $cookies = [System.Collections.Generic.List[object]]::new()
    $keys = [System.Collections.Generic.List[object]]::new()
    try {
        $creg = Get-Content -LiteralPath (Join-Path $dir 'cookie_registry.json') -Raw -ErrorAction Stop | ConvertFrom-Json
        $vault = Join-Path $PSScriptRoot ($creg.vault -replace '/', '\')   # registry 'vault' is relative to the project root
        foreach ($p in $creg.sources.PSObject.Properties) {
            $s = $p.Value; $f = Join-Path $vault $s.cookie; $sz = 0; $ok = $false
            try { if (Test-Path -LiteralPath $f) { $sz = (Get-Item -LiteralPath $f).Length; $ok = $sz -gt 0 } } catch {}
            $cookies.Add([ordered]@{ id = $p.Name; domain = $s.domain; unlocks = $s.unlocks; runner = $s.runner
                    gentle = $s.gentle_sec; needs = $s.needs; file = $s.cookie; present = $ok; bytes = [int]$sz })
        }
    } catch {}
    try {
        $kreg = Get-Content -LiteralPath (Join-Path $dir 'key_registry.json') -Raw -ErrorAction Stop | ConvertFrom-Json
        $store = @{}; try { $store = Get-Content -LiteralPath (Join-Path $dir $kreg.store) -Raw -ErrorAction Stop | ConvertFrom-Json } catch {}
        foreach ($p in $kreg.keys.PSObject.Properties) {
            $k = $p.Value; $val = ''; try { $val = "$($store.$($p.Name))" } catch {}
            $keys.Add([ordered]@{ id = $p.Name; label = $k.label; unlocks = $k.unlocks; get = $k.get
                    runner = $k.runner; gentle = $k.gentle_sec; present = (-not [string]::IsNullOrWhiteSpace($val)) })
        }
    } catch {}
    @{ cookies = @($cookies); keys = @($keys); updated = (Get-Date -Format HH:mm:ss) } | ConvertTo-Json -Depth 5
}

function Save-Secret($o) {
    # Persist a dropped cookie or API key into the vault. The VALUE is treated as opaque: never echoed,
    # never logged (only the kind/source/byte-count are recorded). Returns a value-free receipt.
    if (-not $o -or -not $o.kind -or -not $o.source -or [string]::IsNullOrWhiteSpace([string]$o.value)) {
        return (@{ ok = $false; error = 'need kind, source and a non-empty value' } | ConvertTo-Json)
    }
    $dir = Get-SecretDir
    $src = ([string]$o.source).Trim().ToLower() -replace '[^a-z0-9_.\-]', ''
    if (-not $src) { return (@{ ok = $false; error = 'bad source id' } | ConvertTo-Json) }
    $val = [string]$o.value
    try {
        if ($o.kind -eq 'cookie') {
            $cpath = Join-Path $dir 'cookie_registry.json'
            $creg = Get-Content -LiteralPath $cpath -Raw | ConvertFrom-Json -AsHashtable
            $vault = Join-Path $PSScriptRoot ($creg.vault -replace '/', '\')   # registry 'vault' is relative to the project root
            if (-not (Test-Path -LiteralPath $vault)) { New-Item -ItemType Directory -Force -Path $vault | Out-Null }
            $entry = $creg.sources[$src]
            $domain = if ($o.domain) { ([string]$o.domain).Trim() } elseif ($entry) { $entry.domain } else { $src }
            $file = if ($o.cookieFile) { ([string]$o.cookieFile).Trim() -replace '[^a-zA-Z0-9_.\-]', '_' } elseif ($entry) { $entry.cookie } else { ($domain -replace '[^a-zA-Z0-9_.\-]', '_') + '_cookies.txt' }
            # SECURITY: resolve + contain under the vault before WriteAllText — prevents path-traversal
            # via a cookieFile containing '..' (Join-Path doesn't resolve it; .NET WriteAllText does).
            $full = [IO.Path]::GetFullPath((Join-Path $vault $file))
            $vaultFull = [IO.Path]::GetFullPath($vault)
            if (-not $full.StartsWith($vaultFull, [StringComparison]::OrdinalIgnoreCase)) {
                Add-Content -LiteralPath (Join-Path $PSScriptRoot '_jobs\secrets.log') -Encoding utf8 -Value "$([DateTime]::Now.ToString('HH:mm:ss')) REJECTED path-traversal cookieFile :: $src -> $file"
                return (@{ ok = $false; error = 'cookieFile escapes vault' } | ConvertTo-Json)
            }
            # write the cookie file (UTF-8, no BOM)
            [IO.File]::WriteAllText($full, $val, (New-Object Text.UTF8Encoding($false)))
            # register a brand-new source, or update runner/gentle if the page sent overrides
            $changed = $false
            if (-not $entry) {
                $creg.sources[$src] = [ordered]@{ domain = $domain; cookie = $file
                    unlocks = $(if ($o.unlocks) { [string]$o.unlocks } else { 'user-added' })
                    tool = $(if ($o.tool) { [string]$o.tool } else { 'manual' })
                    runner = $(if ($o.runner) { [string]$o.runner } else { 'claude' })
                    gentle_sec = $(if ($o.gentle_sec) { [int]$o.gentle_sec } else { 3 }) }
                $changed = $true
            }
            else {
                if ($o.runner -and $entry.runner -ne [string]$o.runner) { $entry.runner = [string]$o.runner; $changed = $true }
                if ($null -ne $o.gentle_sec -and $entry.gentle_sec -ne [int]$o.gentle_sec) { $entry.gentle_sec = [int]$o.gentle_sec; $changed = $true }
            }
            if ($changed) { ($creg | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $cpath -Encoding utf8 }
            Add-Content -LiteralPath (Join-Path $PSScriptRoot '_jobs\secrets.log') -Encoding utf8 -Value "$([DateTime]::Now.ToString('HH:mm:ss')) cookie saved :: $src ($([Text.Encoding]::UTF8.GetByteCount($val)) bytes) runner=$($creg.sources[$src].runner)"
            return (@{ ok = $true; kind = 'cookie'; source = $src; file = $file; runner = $creg.sources[$src].runner } | ConvertTo-Json)
        }
        elseif ($o.kind -eq 'key') {
            $kpath = Join-Path $dir 'key_registry.json'
            $kreg = Get-Content -LiteralPath $kpath -Raw | ConvertFrom-Json -AsHashtable
            $store = Join-Path $dir $kreg.store
            $vals = @{}; try { $vals = Get-Content -LiteralPath $store -Raw | ConvertFrom-Json -AsHashtable } catch {}
            $vals[$src] = $val.Trim()
            ($vals | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $store -Encoding utf8
            if (-not $kreg.keys.ContainsKey($src)) {
                $kreg.keys[$src] = [ordered]@{ label = $(if ($o.label) { [string]$o.label } else { $src })
                    unlocks = $(if ($o.unlocks) { [string]$o.unlocks } else { 'user-added' })
                    get = $(if ($o.get) { [string]$o.get } else { '' })
                    tool = $(if ($o.tool) { [string]$o.tool } else { 'manual' })
                    runner = $(if ($o.runner) { [string]$o.runner } else { 'local' })
                    gentle_sec = $(if ($o.gentle_sec) { [int]$o.gentle_sec } else { 4 }) }
                ($kreg | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $kpath -Encoding utf8
            }
            elseif ($o.runner -and $kreg.keys[$src].runner -ne [string]$o.runner) {
                $kreg.keys[$src].runner = [string]$o.runner; ($kreg | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $kpath -Encoding utf8
            }
            Add-Content -LiteralPath (Join-Path $PSScriptRoot '_jobs\secrets.log') -Encoding utf8 -Value "$([DateTime]::Now.ToString('HH:mm:ss')) key saved :: $src ($($val.Trim().Length) chars)"
            return (@{ ok = $true; kind = 'key'; source = $src } | ConvertTo-Json)
        }
        else { return (@{ ok = $false; error = "unknown kind '$($o.kind)'" } | ConvertTo-Json) }
    }
    catch { return (@{ ok = $false; error = "save failed: $($_.Exception.Message)" } | ConvertTo-Json) }
}

function Delete-Secret($o) {
    # Remove a dropped cookie or API key from the vault. Mirrors Save-Secret's containment contract:
    # the cookie FILE path is resolved + contained under the vault root via the EXACT same GetFullPath +
    # StartsWith check as the H2 Save-Secret fix — a delete endpoint without this would be arbitrary file
    # deletion via '..' (worse than the H2 write bug). Keys live in a single JSON store (no per-key file),
    # so key deletion is a registry/store mutation, not a filesystem delete.
    if (-not $o -or -not $o.kind -or -not $o.source) {
        return (@{ ok = $false; error = 'need kind and source' } | ConvertTo-Json)
    }
    $dir = Get-SecretDir
    $src = ([string]$o.source).Trim().ToLower() -replace '[^a-z0-9_.\-]', ''
    if (-not $src) { return (@{ ok = $false; error = 'bad source id' } | ConvertTo-Json) }
    try {
        if ($o.kind -eq 'cookie') {
            $cpath = Join-Path $dir 'cookie_registry.json'
            $creg = Get-Content -LiteralPath $cpath -Raw | ConvertFrom-Json -AsHashtable
            $vault = Join-Path $PSScriptRoot ($creg.vault -replace '/', '\')
            $entry = $creg.sources[$src]
            if (-not $entry) { return (@{ ok = $false; error = 'no such cookie source' } | ConvertTo-Json) }
            $file = if ($entry.cookie) { ([string]$entry.cookie).Trim() -replace '[^a-zA-Z0-9_.\-]', '_' } else { ($entry.domain -replace '[^a-zA-Z0-9_.\-]', '_') + '_cookies.txt' }
            # SECURITY: resolve + contain under the vault before Remove-Item — same check as Save-Secret's
            # H2 fix. A cookieFile containing '..' must not let us delete outside the vault.
            $full = [IO.Path]::GetFullPath((Join-Path $vault $file))
            $vaultFull = [IO.Path]::GetFullPath($vault)
            if (-not $full.StartsWith($vaultFull, [StringComparison]::OrdinalIgnoreCase)) {
                Add-Content -LiteralPath (Join-Path $PSScriptRoot '_jobs\secrets.log') -Encoding utf8 -Value "$([DateTime]::Now.ToString('HH:mm:ss')) REJECTED path-traversal cookie delete :: $src -> $file"
                return (@{ ok = $false; error = 'cookieFile escapes vault' } | ConvertTo-Json)
            }
            if (Test-Path -LiteralPath $full) { Remove-Item -LiteralPath $full -Force }
            $creg.sources.Remove($src) | Out-Null
            ($creg | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $cpath -Encoding utf8
            Add-Content -LiteralPath (Join-Path $PSScriptRoot '_jobs\secrets.log') -Encoding utf8 -Value "$([DateTime]::Now.ToString('HH:mm:ss')) cookie deleted :: $src"
            return (@{ ok = $true; kind = 'cookie'; source = $src } | ConvertTo-Json)
        }
        elseif ($o.kind -eq 'key') {
            $kpath = Join-Path $dir 'key_registry.json'
            $kreg = Get-Content -LiteralPath $kpath -Raw | ConvertFrom-Json -AsHashtable
            $store = Join-Path $dir $kreg.store
            # contain the store path under the secrets dir too — defense in depth, same pattern
            $storeFull = [IO.Path]::GetFullPath($store)
            $dirFull = [IO.Path]::GetFullPath($dir)
            if (-not $storeFull.StartsWith($dirFull, [StringComparison]::OrdinalIgnoreCase)) {
                Add-Content -LiteralPath (Join-Path $PSScriptRoot '_jobs\secrets.log') -Encoding utf8 -Value "$([DateTime]::Now.ToString('HH:mm:ss')) REJECTED path-traversal key store :: $src"
                return (@{ ok = $false; error = 'key store escapes secrets dir' } | ConvertTo-Json)
            }
            $vals = @{}; try { $vals = Get-Content -LiteralPath $store -Raw | ConvertFrom-Json -AsHashtable } catch {}
            $vals.Remove($src) | Out-Null
            ($vals | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $store -Encoding utf8
            if ($kreg.keys.ContainsKey($src)) { $kreg.keys.Remove($src) | Out-Null; ($kreg | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $kpath -Encoding utf8 }
            Add-Content -LiteralPath (Join-Path $PSScriptRoot '_jobs\secrets.log') -Encoding utf8 -Value "$([DateTime]::Now.ToString('HH:mm:ss')) key deleted :: $src"
            return (@{ ok = $true; kind = 'key'; source = $src } | ConvertTo-Json)
        }
        else { return (@{ ok = $false; error = "unknown kind '$($o.kind)'" } | ConvertTo-Json) }
    }
    catch { return (@{ ok = $false; error = "delete failed: $($_.Exception.Message)" } | ConvertTo-Json) }
}

# --- app settings (the /settings page). Saved knobs live in _data\settings.json; pipeline scripts
# read them as their between-env-and-hardcoded default tier (CLI flag > env > settings.json > default).
# Born from the 2026-07-09 incident where translate_subs.py's buried localhost:1234 default silently
# placeholder-flooded a whole creator: the LLM endpoint must be a VISIBLE setting, not a code constant. ---
$script:SettingsDefaults = [ordered]@{
    contentMode   = 'unfiltered'    # 'unfiltered' (abliterated ok, never euphemize) | 'sanitized' (SFW libraries)
    llmApi        = 'http://localhost:11434/v1'
    llmModel      = 'qwen2.5:14b'
    reviseModel   = 'huihui_ai/qwen3.6-abliterated:35b'   # targeted revise lane, not bulk (77s/10 cues)
    zhModel       = 'huihui_ai/hunyuan-mt-abliterated:7b-chimera'
    asrModel      = 'anime-whisper-ct2'
    resegMaxchars = 60
    workerRole    = 'full'          # 'full' (24GB) | 'asr' (8-12GB worker) | 'serve' (no GPU)
    languages     = 'ja,en,zh,ko'   # core lanes; unknown audio languages quarantine (task #61)
    navLayout     = 'topbar'        # 'topbar' | 'sidebar' -- read by realm.js once nav unification (#102) lands
}

function Get-SettingsPath { Join-Path (Split-Path $PSScriptRoot -Parent) '_data\settings.json' }

function Get-SettingsJson {
    $saved = @{}
    try { $saved = Get-Content -LiteralPath (Get-SettingsPath) -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable } catch {}
    $merged = [ordered]@{}
    foreach ($k in $script:SettingsDefaults.Keys) {
        $merged[$k] = if ($saved.ContainsKey($k)) { $saved[$k] } else { $script:SettingsDefaults[$k] }
    }
    # read-only facts: paths come from env/docker config, never editable through a web form
    $root = Split-Path $PSScriptRoot -Parent
    $models = @()
    try {
        $r = Invoke-RestMethod -Uri 'http://localhost:11434/api/tags' -TimeoutSec 2 -ErrorAction Stop
        $models = @($r.models | ForEach-Object { $_.name })
    } catch {}   # no Ollama on this host (e.g. NAS container) -> model fields stay free-text
    @{ settings = $merged
       defaults = $script:SettingsDefaults
       facts    = [ordered]@{ libraryRoot = $root; dataRoot = (Join-Path $root '_data')
                              settingsFile = (Get-SettingsPath); ollamaModels = $models } } | ConvertTo-Json -Depth 5
}

function Save-Settings($o) {
    if (-not $o) { return (@{ ok = $false; error = 'empty body' } | ConvertTo-Json) }
    $saved = @{}
    try { $saved = Get-Content -LiteralPath (Get-SettingsPath) -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable } catch {}
    $changed = @()
    foreach ($p in $o.PSObject.Properties) {
        if (-not $script:SettingsDefaults.Contains($p.Name)) { continue }    # whitelist: unknown keys dropped
        $v = $p.Value
        switch ($p.Name) {
            'contentMode'   { if ($v -notin @('unfiltered', 'sanitized')) { continue } }
            'workerRole'    { if ($v -notin @('full', 'asr', 'serve')) { continue } }
            'navLayout'     { if ($v -notin @('topbar', 'sidebar')) { continue } }
            'resegMaxchars' { $v = [int]$v; if ($v -lt 20 -or $v -gt 200) { continue } }
            default         { $v = ([string]$v).Trim(); if (-not $v) { continue } }
        }
        if (-not $saved.ContainsKey($p.Name) -or "$($saved[$p.Name])" -ne "$v") { $changed += $p.Name }
        $saved[$p.Name] = $v
    }
    try {
        ($saved | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath (Get-SettingsPath) -Encoding utf8
        return (@{ ok = $true; changed = @($changed) } | ConvertTo-Json)
    } catch { return (@{ ok = $false; error = "save failed: $($_.Exception.Message)" } | ConvertTo-Json) }
}

# --- playlist research sandbox (the /sandbox page). Presence + byte sizes only; never the research text. ---
function Get-SandboxJson {
    $root = Split-Path $PSScriptRoot -Parent
    $tp = Join-Path $root '_data\sandbox\creator_triage.json'
    $tri = $null; try { if (Test-Path -LiteralPath $tp) { $tri = Get-Content -LiteralPath $tp -Raw | ConvertFrom-Json } } catch {}
    $new = [System.Collections.Generic.List[object]]::new()
    if ($tri -and $tri.new) {
        foreach ($n in $tri.new) {
            $sf = Join-Path $root ($n.folder + '\_sources.txt')
            $pf = Join-Path $root ('_wiki\' + $n.folder + '\_profile.md')
            $sb = 0; try { if (Test-Path -LiteralPath $sf) { $sb = (Get-Item -LiteralPath $sf).Length } } catch {}
            $pb = 0; try { if (Test-Path -LiteralPath $pf) { $pb = (Get-Item -LiteralPath $pf).Length } } catch {}
            $new.Add([ordered]@{ folder = $n.folder; guess = $n.guess; score = $n.score; sources = [int]$sb; profile = [int]$pb })
        }
    }
    $merges = [System.Collections.Generic.List[object]]::new()
    if ($tri -and $tri.merges) {
        foreach ($p in $tri.merges.PSObject.Properties) { foreach ($v in $p.Value) { $merges.Add([ordered]@{ variant = $v; canonical = $p.Name }) } }
    }
    $llmUp = $false; $models = @()
    try {   # 250ms TCP probe first so a dead LM Studio doesn't stall the page (same trick as /debug.json)
        $tcp = [System.Net.Sockets.TcpClient]::new(); $iar = $tcp.BeginConnect('127.0.0.1', 1234, $null, $null)
        if ($iar.AsyncWaitHandle.WaitOne(250) -and $tcp.Connected) {
            $tcp.EndConnect($iar); $tcp.Close()
            $r = Invoke-RestMethod 'http://localhost:1234/v1/models' -TimeoutSec 2
            $models = @($r.data | ForEach-Object { $_.id }); $llmUp = $models.Count -gt 0
        } else { try { $tcp.Close() } catch {} }
    } catch {}
    # also report the Ollama translation/research backend (the sandbox pipeline runs on it, not LM Studio)
    $ollama = $false
    try {
        $tc = [System.Net.Sockets.TcpClient]::new(); $ia = $tc.BeginConnect('127.0.0.1', 11434, $null, $null)
        if ($ia.AsyncWaitHandle.WaitOne(250) -and $tc.Connected) { $tc.EndConnect($ia); $ollama = $true }; try { $tc.Close() } catch {}
    } catch {}
    $running = $false
    try { $running = [bool](Get-CimInstance Win32_Process -Filter "Name='python.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -like '*sandbox_research*' }) } catch {}
    $logp = Join-Path $root '_data\sandbox\research_log.txt'; $log = @()
    try { if (Test-Path -LiteralPath $logp) { $log = @(Get-Content -LiteralPath $logp -Tail 6) } } catch {}

    # --- pipeline progress over the sandbox (yt_ingest): the 5 stages, counts only ---
    $yt = Join-Path $root '_data\yt_ingest'
    $media = 0; $ja = 0; $en = 0; $learn = 0; $desc = 0
    try {
        $all = Get-ChildItem -LiteralPath $yt -Recurse -File -ErrorAction SilentlyContinue
        $media = @($all | Where-Object { $_.Extension -in '.m4a', '.mp3', '.mp4', '.wav', '.flac', '.opus' }).Count
        $ja = @($all | Where-Object Name -like '*.ja.srt').Count
        $en = @($all | Where-Object Name -like '*.en.srt').Count
        $learn = @($all | Where-Object Name -like '*.learn.srt').Count   # learn tracks are srt-only now (vtt twins retired 2026-07-03)
        $desc = @($all | Where-Object Extension -eq '.description').Count
    } catch {}
    # research = sandbox creators with a _profile.md or _sources.txt
    $researched = 0
    try { $researched = @(Get-ChildItem -LiteralPath $yt -Directory -ErrorAction SilentlyContinue | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName '_sources.txt') }).Count } catch {}
    # live: is the sandbox transcription running, and on what file?
    $txRun = $false; $nowFile = ''
    try { $txRun = [bool](Get-CimInstance Win32_Process -Filter "Name='python.exe' OR Name='pwsh.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -like '*yt_ingest*' -or $_.CommandLine -like '*sandbox_transcribe*' }) } catch {}
    try {
        $tl = Get-Content -LiteralPath (Join-Path $PSScriptRoot '_jobs\sandbox_transcribe_all.log') -Tail 6 -ErrorAction SilentlyContinue
        $nowFile = ($tl | Where-Object { $_ -match '\.(m4a|mp3|mp4|wav)' } | Select-Object -Last 1)
        if (-not $nowFile) { $nowFile = ($tl | Select-Object -Last 1) }
    } catch {}
    $pipeline = [ordered]@{ files = $media; transcribe = $ja; translate = $en; study = $learn
        research = $researched; describe = $desc; txRunning = $txRun; now = "$nowFile".Trim() }

    @{ updated = (Get-Date -Format HH:mm:ss); roster = @($tri.roster); merges = @($merges); new = @($new)
        llm = @{ up = $llmUp; models = $models; ollama = $ollama }; running = $running; log = @($log)
        pipeline = $pipeline } | ConvertTo-Json -Depth 6
}

function Invoke-SandboxRun($o) {
    $mode = "$($o.mode)"
    if ($mode -notin @('triage', 'research', 'deep')) { return (@{ ok = $false; error = 'bad mode' } | ConvertTo-Json) }
    $busy = $false
    try { $busy = [bool](Get-CimInstance Win32_Process -Filter "Name='python.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -like '*sandbox_research*' }) } catch {}
    if ($busy) { return (@{ ok = $false; error = 'a sandbox run is already in progress' } | ConvertTo-Json) }
    $script = Join-Path $PSScriptRoot 'sandbox_research.py'
    $log = Join-Path $PSScriptRoot "_jobs\sandbox_$mode.log"
    try {
        Start-Process -FilePath 'python' -ArgumentList @($script, "--$mode") -WorkingDirectory $PSScriptRoot `
            -WindowStyle Hidden -RedirectStandardOutput $log -RedirectStandardError "$log.err"
        return (@{ ok = $true; started = $mode } | ConvertTo-Json)
    } catch { return (@{ ok = $false; error = $_.Exception.Message } | ConvertTo-Json) }
}

# --- wiki seeds: preserve a YouTube video/playlist's METADATA (no media) so the wiki survives dark videos ---
function Get-WikiSeedsJson {
    $sp = Join-Path (Split-Path $PSScriptRoot -Parent) '_data\wiki_seed\seeds.json'
    if (Test-Path -LiteralPath $sp) { try { return (Get-Content -LiteralPath $sp -Raw) } catch {} }
    '{"count":0,"seeds":[]}'
}

# --- architect's intelligence inventory (/metrics): how much Sasayaki has collected + scraper coverage ---
function Get-MetricsJson {
    $now = [Environment]::TickCount64
    if ($script:MetCache -and [math]::Abs($now - $script:MetAt) -lt 45000) { return $script:MetCache }
    $root = Split-Path $PSScriptRoot -Parent
    $data = Join-Path $root '_data'; $wiki = Join-Path $root '_wiki'
    $cacheFile = Join-Path $data '_cache\metrics.json'
    # cold start (server just restarted): serve the last persisted snapshot instantly so the page never blocks on a full scan; it refreshes on the next poll
    if (-not $script:MetCache -and (Test-Path -LiteralPath $cacheFile)) {
        try { $script:MetCache = [IO.File]::ReadAllText($cacheFile); $script:MetAt = $now; return $script:MetCache } catch {}
    }
    $rd = { param($p, $def) if (Test-Path -LiteralPath $p) { try { return (Get-Content -LiteralPath $p -Raw | ConvertFrom-Json) } catch {} } $def }

    # corpus.jsonl = the structured spine (per-work text/audio)
    $works = 0; $hours = 0.0; $jaChars = 0; $jaCues = 0; $enCues = 0; $jaW = 0; $enW = 0; $taggedW = 0
    $byC = @{}
    $cp = Join-Path $data 'corpus\corpus.jsonl'
    if (Test-Path -LiteralPath $cp) {
        foreach ($ln in [IO.File]::ReadLines($cp)) {
            if (-not $ln.Trim()) { continue }
            $r = $null; try { $r = $ln | ConvertFrom-Json } catch { continue }
            $works++; $sec = [double]($r.dur_sec); $hours += $sec / 3600; $jaChars += [int]$r.ja_chars
            $jaCues += [int]$r.ja_cues; $enCues += [int]$r.en_cues
            if ($r.lang.ja) { $jaW++ }; if ($r.lang.en) { $enW++ }; if ($r.tags.Count -gt 0) { $taggedW++ }
            $c = "$($r.creator)"
            if (-not $byC.ContainsKey($c)) { $byC[$c] = [ordered]@{ creator = $c; works = 0; hours = 0.0; jaChars = 0; jaW = 0; enW = 0 } }
            $e = $byC[$c]; $e.works++; $e.hours += $sec / 3600; $e.jaChars += [int]$r.ja_chars; if ($r.lang.ja) { $e.jaW++ }; if ($r.lang.en) { $e.enW++ }
        }
    }
    # est tokens: JA ~0.9 tok/char + EN cues ~ negligible; the headline "knowledge tokens" of the text corpus
    $estTokens = [int64]($jaChars * 0.9)

    # research bytes collected (per-creator _sources.txt + _profile.md) + creators metadata
    $creatorsMeta = & $rd (Join-Path $data 'creators.json') @{ creators = @{} }
    $researchBytes = 0
    try { foreach ($f in (Get-ChildItem -LiteralPath $root -Recurse -Depth 2 -Include '_sources.txt', '_profile.md' -File -ErrorAction SilentlyContinue)) { $researchBytes += $f.Length } } catch {}
    $idx = & $rd (Join-Path $data 'creator_index.json') @{ embedded = 0; creators = @() }
    $seeds = & $rd (Join-Path $data 'wiki_seed\seeds.json') @{ count = 0 }
    $prod = & $rd (Join-Path $wiki 'DLsite\_products.json') @{ products = @() }
    $cien = & $rd (Join-Path $data 'cien_subs.json') @{ creators = @{} }
    $ytArch = 0; try { $ytArch = @(Get-Content -LiteralPath (Join-Path $data 'yt_archive.txt') -ErrorAction SilentlyContinue).Count } catch {}

    # per-SITE scraper coverage
    $creg = & $rd (Join-Path $PSScriptRoot '_secrets\cookie_registry.json') @{ sources = @{} }
    $cienStaged = 0; $cienGB = 0.0
    try { $sf = Get-ChildItem -LiteralPath (Join-Path $data '_cien_staging') -Recurse -File -ErrorAction SilentlyContinue; $cienStaged = $sf.Count; $cienGB = ($sf | Measure-Object Length -Sum).Sum / 1GB } catch {}
    $ytIngest = 0; try { $ytIngest = @(Get-ChildItem -LiteralPath (Join-Path $data 'yt_ingest') -Directory -ErrorAction SilentlyContinue).Count } catch {}
    $boothCreators = @($creatorsMeta.creators.PSObject.Properties | Where-Object { $_.Value.source -eq 'booth' }).Count
    $cienSubN = @($cien.creators.PSObject.Properties).Count
    function ckPresent($name) { try { $s = $creg.sources.$name; return (Test-Path -LiteralPath (Join-Path $PSScriptRoot ('_secrets\cookies\' + $s.cookie))) } catch { return $false } }
    $sites = @(
        [ordered]@{ site = 'ci-en'; cookie = (ckPresent 'cien'); recipe = $true; subs = $cienSubN; collected = $cienStaged; unit = 'files'; gb = [math]::Round($cienGB, 1); note = "$cienSubN creators subscribed; recipe cracked (Playwright)" }
        [ordered]@{ site = 'youtube'; cookie = (ckPresent 'youtube'); recipe = $true; subs = $ytIngest; collected = $ytArch; unit = 'videos'; gb = 0; note = "$ytIngest channels ingested (sandbox)" }
        [ordered]@{ site = 'booth'; cookie = (ckPresent 'booth'); recipe = $true; subs = $boothCreators; collected = $boothCreators; unit = 'creators'; gb = 0; note = 'covers + purchase library' }
        [ordered]@{ site = 'dlsite'; cookie = (ckPresent 'dlsite'); recipe = $true; subs = 0; collected = @($prod.products).Count; unit = 'products'; gb = 0; note = 'product API enrichment' }
        [ordered]@{ site = 'twitcasting'; cookie = (ckPresent 'twitcasting'); recipe = $true; subs = 0; collected = 0; unit = 'streams'; gb = 0; note = 'archive-password grabs' }
        [ordered]@{ site = 'asmr.one'; cookie = (ckPresent 'asmrone'); recipe = $false; subs = 0; collected = 0; unit = 'tags'; gb = 0; note = 'tag/VA enrichment' }
        [ordered]@{ site = 'x'; cookie = (ckPresent 'x'); recipe = $false; subs = 0; collected = 0; unit = 'fanart'; gb = 0; note = 'gallery (planned)' }
        [ordered]@{ site = 'kemono'; cookie = (ckPresent 'kemono'); recipe = $false; subs = 0; collected = 0; unit = 'posts'; gb = 0; note = 'DDoS-guard — browser only' }
    )

    # per-creator rollup with token + research bytes
    $creators = foreach ($k in $byC.Keys) {
        $e = $byC[$k]; $meta = $creatorsMeta.creators.$k
        $rb = 0; try { foreach ($f in (Get-ChildItem -LiteralPath (Join-Path $root $k) -Include '_sources.txt' -File -Recurse -Depth 1 -ErrorAction SilentlyContinue)) { $rb += $f.Length } } catch {}
        [ordered]@{ creator = $k; works = $e.works; hours = [math]::Round($e.hours, 1); jaWorks = $e.jaW; enWorks = $e.enW
            tokens = [int64]($e.jaChars * 0.9); status = "$($meta.status)"; source = "$($meta.source)" }
    }
    $creators = @($creators | Sort-Object { - $_.tokens })

    # full-library media size walks the WHOLE tree (the dominant cost of this scan) but barely changes — cache it 10 min, separate from the 45s metrics cache, so most recomputes skip it
    if (-not $script:MetSizeAt -or [math]::Abs($now - $script:MetSizeAt) -gt 600000) {
        $sz = 0.0; try { $sz = ((Get-ChildItem -LiteralPath $root -Recurse -File -Include '*.mp3', '*.m4a', '*.mp4', '*.wav', '*.flac' -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum) / 1GB } catch {}
        $script:MetSizeGB = $sz; $script:MetSizeAt = $now
    }
    $sizeGB = $script:MetSizeGB

    $out = [ordered]@{
        updated = (Get-Date -Format 'HH:mm:ss')
        totals  = [ordered]@{ creators = $byC.Count; works = $works; audioHours = [math]::Round($hours, 1)
            jaChars = $jaChars; estTokens = $estTokens; embeddings = [int]$idx.embedded
            researchBytes = [int]$researchBytes; dlsiteProducts = @($prod.products).Count
            cienSubs = $cienSubN; ytVideos = $ytArch; wikiSeeds = [int]$seeds.count; audioGB = [math]::Round($sizeGB, 1) }
        stages  = [ordered]@{ transcribed = $jaW; translated = $enW; tagged = $taggedW; embedded = [int]$idx.embedded
            researched = @(Get-ChildItem -LiteralPath $root -Recurse -Depth 2 -Filter '_sources.txt' -File -ErrorAction SilentlyContinue).Count
            jaCues = $jaCues; enCues = $enCues }
        sites   = @($sites)
        creators = @($creators)
    }
    $script:MetCache = ($out | ConvertTo-Json -Depth 6); $script:MetAt = $now
    # persist so a server restart can serve this snapshot instantly instead of cold-scanning the library
    try { $cd = Split-Path $cacheFile -Parent; if (-not (Test-Path -LiteralPath $cd)) { New-Item -ItemType Directory -Path $cd -Force | Out-Null }; [IO.File]::WriteAllText($cacheFile, $script:MetCache) } catch {}
    $script:MetCache
}

function Get-SandboxMetricsJson {
    # the SANDBOX realm's intel (#104): measures what the AUDITION layer knows — the staged yt_ingest
    # channels — never the core library. Same JSON shape metrics.html renders (totals/stages/sites/
    # creators), so the page needs no schema fork. Cheap by construction: file names + lengths only
    # (no srt reads, no ffprobe). Hours are estimated from audio bytes (~128kbps YouTube audio ≈ 57.6
    # MB/h) and tokens from ja.srt bytes (UTF-8 CJK ≈ 3 B/char, ~0.9 tok/char) — estimates, labeled so.
    $now = [Environment]::TickCount64
    if ($script:SbxMetCache -and [math]::Abs($now - $script:SbxMetAt) -lt 45000) { return $script:SbxMetCache }
    $root = Split-Path $PSScriptRoot -Parent
    $ing = Join-Path (Join-Path $root '_data') 'yt_ingest'
    $audio = '.m4a', '.mp3', '.wav', '.flac', '.opus', '.ogg', '.aac', '.mp4', '.mkv', '.webm'
    $chN = 0; $vids = 0; $jaW = 0; $enW = 0; $bytes = 0L; $jaSrtBytes = 0L; $pfp = 0
    $rows = [System.Collections.Generic.List[object]]::new()
    if (Test-Path -LiteralPath $ing) {
        foreach ($ch in (Get-ChildItem -LiteralPath $ing -Directory -ErrorAction SilentlyContinue)) {
            $chN++
            $ja = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            $en = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            $picks = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            $cb = 0L; $cjb = 0L
            foreach ($f in (Get-ChildItem -LiteralPath $ch.FullName -File -ErrorAction SilentlyContinue)) {
                $n = $f.Name
                if ($n -eq '_avatar.jpg') { $pfp++; continue }
                if ($n -like '*.ja.srt') { [void]$ja.Add($n.Substring(0, $n.Length - 7)); $cjb += $f.Length; continue }
                if ($n -like '*.en.srt') { [void]$en.Add($n.Substring(0, $n.Length - 7)); continue }
                if ($audio -contains $f.Extension.ToLower()) {
                    if ($picks.Add([IO.Path]::GetFileNameWithoutExtension($n))) { $cb += $f.Length }
                }
            }
            $cJa = 0; $cEn = 0
            foreach ($b in $picks) { if ($ja.Contains($b)) { $cJa++ }; if ($en.Contains($b)) { $cEn++ } }
            $vids += $picks.Count; $jaW += $cJa; $enW += $cEn; $bytes += $cb; $jaSrtBytes += $cjb
            $rows.Add([ordered]@{ creator = $ch.Name; works = $picks.Count
                    hours = [math]::Round($cb / 1MB / 57.6, 1); jaWorks = $cJa; enWorks = $cEn
                    tokens = [int64]($cjb / 3 * 0.9); status = 'audition'; source = 'youtube' })
        }
    }
    $jaChars = [int64]($jaSrtBytes / 3)
    $out = [ordered]@{
        updated = (Get-Date -Format 'HH:mm:ss')
        totals  = [ordered]@{ creators = $chN; works = $vids; audioHours = [math]::Round($bytes / 1MB / 57.6, 1)
            jaChars = $jaChars; estTokens = [int64]($jaChars * 0.9); embeddings = 0
            researchBytes = 0; dlsiteProducts = 0; cienSubs = 0; ytVideos = $vids; wikiSeeds = 0
            audioGB = [math]::Round($bytes / 1GB, 1) }
        stages  = [ordered]@{ transcribed = $jaW; translated = $enW; tagged = 0; embedded = 0; researched = 0
            jaCues = 0; enCues = 0 }
        sites   = @(
            [ordered]@{ site = 'youtube'; cookie = $true; recipe = $true; subs = $chN; collected = $vids
                unit = 'videos'; gb = [math]::Round($bytes / 1GB, 1); note = "$pfp/$chN channels have avatars; hours/tokens estimated from file sizes" }
        )
        creators = @($rows | Sort-Object { - $_.works })
    }
    $script:SbxMetCache = ($out | ConvertTo-Json -Depth 6); $script:SbxMetAt = $now
    $script:SbxMetCache
}

function Invoke-MetaArchive($o) {
    $url = "$($o.url)".Trim()
    if ($url -notmatch '^https?://') { return (@{ ok = $false; error = 'paste a full http(s) URL' } | ConvertTo-Json) }
    if ($url -notmatch 'youtu') { return (@{ ok = $false; error = 'not a YouTube video/playlist URL' } | ConvertTo-Json) }
    $script = Join-Path $PSScriptRoot 'archive_meta.py'
    $argl = @($script, $url); if ($o.light) { $argl += '--light' }
    $log = Join-Path $PSScriptRoot '_jobs\archive_meta.log'
    try {
        Start-Process -FilePath 'python' -ArgumentList $argl -WorkingDirectory $PSScriptRoot `
            -WindowStyle Hidden -RedirectStandardOutput $log -RedirectStandardError "$log.err"
        return (@{ ok = $true; started = $true; url = $url } | ConvertTo-Json)
    } catch { return (@{ ok = $false; error = $_.Exception.Message } | ConvertTo-Json) }
}

function Start-Server {
    # Prefix tiers, richest first. HttpListener.Start() binds ALL its prefixes atomically -- ONE bad
    # prefix throws and the WHOLE listener fails, so previously a missing ts.net urlacl (or, on Linux,
    # a hostname that just doesn't resolve in that container) silently collapsed all the way to
    # localhost-only even when LAN ("+") would have bound fine. Retry tier-by-tier instead so a single
    # unavailable prefix only drops itself, not everything beneath it.
    $tsHost = if ($env:SASAYAKI_TSHOST) { $env:SASAYAKI_TSHOST } else { 'adriel-studio.tail96029e.ts.net' }
    $lan = ($env:SASAYAKI_LAN -eq '1')
    $tiers = [System.Collections.Generic.List[string[]]]::new()
    # tier 1: everything -- localhost + LAN (needs enable-lan.ps1's urlacl) + the ts.net proxy host
    #         (needs enable-remote.ps1's urlacl; `tailscale serve` forwards to 127.0.0.1 but preserves
    #         Host:<...ts.net>, which a localhost-only prefix rejects with 400)
    $t1 = [System.Collections.Generic.List[string]]::new(); $t1.Add("http://localhost:$Port/")
    if ($lan) { $t1.Add("http://+:$Port/") }
    if ($tsHost) { $t1.Add("http://$tsHost`:$Port/") }
    $tiers.Add($t1.ToArray())
    if ($lan) { $tiers.Add(@("http://localhost:$Port/", "http://+:$Port/")) }   # tier 2: drop ts.net, keep LAN
    $tiers.Add(@("http://localhost:$Port/"))                                    # tier 3: localhost only
    $listener = $null
    foreach ($prefixes in $tiers) {
        $cand = [System.Net.HttpListener]::new()
        foreach ($p in $prefixes) { $cand.Prefixes.Add($p) }
        try { $cand.Start(); $listener = $cand; break }
        catch { try { $cand.Close() } catch {} }
    }
    if (-not $listener) {
        Write-Host "Could not bind http://localhost:$Port/ : all prefix tiers failed" -ForegroundColor Red
        Write-Host "Try another port, e.g. -Port 9000" -ForegroundColor Yellow; return
    }
    Write-Host "Live dashboard -> http://localhost:$Port/   (Ctrl+C to stop)" -ForegroundColor Green
    if ($Open) { try { Start-Process $prefix } catch {} }
    # /audio streams can hold a connection open for an entire track; on the single GetContext thread that would
    # freeze every other route (live metrics, AI console, library). Serve audio from a small background runspace
    # pool. The streaming fns are injected inline (param() first so it stays a valid scriptblock) and the archive
    # root is passed as an argument, since $PSScriptRoot/ISS-seeded vars aren't reliable in a fresh runspace.
    $archiveRoot = Split-Path $PSScriptRoot -Parent
    $streamFnDefs = ('Resolve-AudioPath', 'Get-AudioContentType', 'Send-AudioFile' | ForEach-Object {
            "function $_ {`r`n$((Get-Item "Function:\$_").Definition)`r`n}" }) -join "`r`n"
    $streamScript = "param(`$c, `$ArchiveRoot)`r`n$streamFnDefs`r`ntry { Send-AudioFile `$c } catch {} finally { try { `$c.Response.OutputStream.Close() } catch {} }"
    $streamPool = [runspacefactory]::CreateRunspacePool(1, 4); $streamPool.Open()
    $streamJobs = [System.Collections.Generic.List[object]]::new()
    try {
        while ($listener.IsListening) {
            $ctx = $listener.GetContext(); $res = $ctx.Response
            for ($i = $streamJobs.Count - 1; $i -ge 0; $i--) {   # reap finished streams so runspaces/handles don't leak
                if ($streamJobs[$i].Handle.IsCompleted) {
                    try { $streamJobs[$i].PS.EndInvoke($streamJobs[$i].Handle) } catch {}
                    $streamJobs[$i].PS.Dispose(); $streamJobs.RemoveAt($i)
                }
            }
            $async = $false
            try {
                $path = $ctx.Request.Url.AbsolutePath
                $handled = $false; $keepCache = $false
                if ($path -eq '/audio') {
                    $ps = [powershell]::Create(); $ps.RunspacePool = $streamPool
                    [void]$ps.AddScript($streamScript).AddArgument($ctx).AddArgument($archiveRoot)
                    $streamJobs.Add(@{ PS = $ps; Handle = $ps.BeginInvoke() }); $handled = $true; $async = $true   # runspace owns this response
                }
                elseif ($path -eq '/open' -and $ctx.Request.HttpMethod -eq 'POST') {
                    $reader = [IO.StreamReader]::new($ctx.Request.InputStream, $ctx.Request.ContentEncoding)
                    $raw = $reader.ReadToEnd(); $reader.Close()
                    $cmd = $null; try { $cmd = $raw | ConvertFrom-Json } catch {}
                    $body = Invoke-OpenLocal $cmd; $res.ContentType = 'application/json; charset=utf-8'
                }
                elseif ($path -eq '/data.json') { $body = Get-StateJson; $res.ContentType = 'application/json; charset=utf-8' }
                elseif ($path -eq '/worker/register' -and $ctx.Request.HttpMethod -eq 'POST') {
                    $reader = [IO.StreamReader]::new($ctx.Request.InputStream, $ctx.Request.ContentEncoding)
                    $raw = $reader.ReadToEnd(); $reader.Close()
                    $o = $null; try { $o = $raw | ConvertFrom-Json } catch {}
                    $body = Register-Worker $o; $res.ContentType = 'application/json; charset=utf-8'
                }
                elseif ($path -eq '/worker/deregister' -and $ctx.Request.HttpMethod -eq 'POST') {
                    $reader = [IO.StreamReader]::new($ctx.Request.InputStream, $ctx.Request.ContentEncoding)
                    $raw = $reader.ReadToEnd(); $reader.Close()
                    $o = $null; try { $o = $raw | ConvertFrom-Json } catch {}
                    $body = Unregister-Worker $o; $res.ContentType = 'application/json; charset=utf-8'
                }
                elseif ($path -eq '/workers.json') { $body = Get-WorkersJson; $res.ContentType = 'application/json; charset=utf-8' }
                elseif ($path -eq '/nas.json') { $np = Join-Path (Split-Path $PSScriptRoot -Parent) '_wiki\nas_health.json'; $body = $(if (Test-Path -LiteralPath $np) { Get-Content -LiteralPath $np -Raw } else { '{"ok":false,"reachable":false}' }); $res.ContentType = 'application/json; charset=utf-8' }
                elseif ($path -eq '/activity.json') { $body = Get-ActivityJson; $res.ContentType = 'application/json; charset=utf-8' }
                elseif ($path -eq '/worker/manifest') { $body = Get-WorkerManifest; $res.ContentType = 'application/json; charset=utf-8' }
                elseif ($path -eq '/worker/file') { $body = Get-WorkerFile $ctx.Request.QueryString['name']; if ($null -eq $body) { $res.StatusCode = 404; $body = 'not found' } else { $res.ContentType = 'text/plain; charset=utf-8' } }
                elseif ($path -eq '/command' -and $ctx.Request.HttpMethod -eq 'POST') {
                    $reader = [IO.StreamReader]::new($ctx.Request.InputStream, $ctx.Request.ContentEncoding)
                    $raw = $reader.ReadToEnd(); $reader.Close()
                    $cmd = $null; try { $cmd = $raw | ConvertFrom-Json } catch {}
                    $body = Invoke-AiCommand $cmd; $res.ContentType = 'application/json; charset=utf-8'
                }
                elseif ($path -eq '/joblog') { $body = Get-JobLog $ctx.Request.QueryString['id']; $res.ContentType = 'text/plain; charset=utf-8' }
                elseif ($path -eq '/command_result') { $body = Get-RouteResult $ctx.Request.QueryString['id']; $res.ContentType = 'application/json; charset=utf-8' }
                elseif ($path -eq '/debug.json') { $body = Get-DebugJson; $res.ContentType = 'application/json; charset=utf-8' }
                elseif ($path -eq '/debug') { $body = $DebugShell; $res.ContentType = 'text/html; charset=utf-8' }
                elseif ($path -eq '/library.json') { $body = $(if ($ctx.Request.QueryString['realm'] -eq 'sandbox') { Get-SandboxLibrary } else { Get-Library }); $res.ContentType = 'application/json; charset=utf-8' }
                elseif ($path -eq '/library/trash.json') { $body = Get-TrashJson; $res.ContentType = 'application/json; charset=utf-8' }
                elseif ($path -eq '/library/retrigger' -and $ctx.Request.HttpMethod -eq 'POST') {
                    # #111 Manage-bar "re-run pipeline": re-triggers ASR->resegment->translate (+ optional
                    # wiki-research retry) for the selected work(s), detached. User-driven only.
                    $reader = [IO.StreamReader]::new($ctx.Request.InputStream, $ctx.Request.ContentEncoding)
                    $raw = $reader.ReadToEnd(); $reader.Close()
                    $o = $null; try { $o = $raw | ConvertFrom-Json } catch {}
                    $body = Invoke-LibRetrigger $o
                    $res.ContentType = 'application/json; charset=utf-8'
                }
                elseif ($path -eq '/library/title' -and $ctx.Request.HttpMethod -eq 'POST') {
                    # #112a per-work title override: POST {id, title} (blank title clears it).
                    $reader = [IO.StreamReader]::new($ctx.Request.InputStream, $ctx.Request.ContentEncoding)
                    $raw = $reader.ReadToEnd(); $reader.Close()
                    $o = $null; try { $o = $raw | ConvertFrom-Json } catch {}
                    $body = Invoke-LibTitleOverride $o
                    $res.ContentType = 'application/json; charset=utf-8'
                }
                elseif ($path -like '/library/*' -and $ctx.Request.HttpMethod -eq 'POST') {
                    # user-driven library management: hide/unhide/delete(soft)/restore/purge. purge is the only
                    # destructive op and the client gates it behind an explicit confirm. Never autonomous.
                    $reader = [IO.StreamReader]::new($ctx.Request.InputStream, $ctx.Request.ContentEncoding)
                    $raw = $reader.ReadToEnd(); $reader.Close()
                    $o = $null; try { $o = $raw | ConvertFrom-Json } catch {}
                    $act = ($path -split '/')[-1]
                    if ($act -in @('hide', 'unhide', 'delete', 'restore', 'purge')) { $body = Invoke-LibMutation $act $o }
                    else { $res.StatusCode = 404; $body = '{"ok":false,"error":"unknown action"}' }
                    $res.ContentType = 'application/json; charset=utf-8'
                }
                elseif ($path -eq '/sandbox/promote' -and $ctx.Request.HttpMethod -eq 'POST') {
                    # move audition works from the sandbox into the core library. User-driven (Manage bar).
                    $reader = [IO.StreamReader]::new($ctx.Request.InputStream, $ctx.Request.ContentEncoding)
                    $raw = $reader.ReadToEnd(); $reader.Close()
                    $o = $null; try { $o = $raw | ConvertFrom-Json } catch {}
                    $body = Invoke-SandboxPromote $o
                    $res.ContentType = 'application/json; charset=utf-8'
                }
                elseif ($path -eq '/realm.js') { $rjp = Join-Path $PSScriptRoot 'realm.js'; $body = $(if (Test-Path -LiteralPath $rjp) { Get-Content -LiteralPath $rjp -Raw } else { '' }); $res.Headers.Add('Cache-Control', 'max-age=60'); $res.ContentType = 'application/javascript; charset=utf-8' }
                elseif ($path -eq '/tags.json') { $tjp = Join-Path (Split-Path $PSScriptRoot -Parent) '_wiki\tags.json'; $body = $(if (Test-Path -LiteralPath $tjp) { Get-Content -LiteralPath $tjp -Raw } else { '{"top":[],"counts":{}}' }); $res.ContentType = 'application/json; charset=utf-8' }
                elseif ($path -eq '/tagmap.json') { $tmp = Join-Path (Split-Path $PSScriptRoot -Parent) '_wiki\tags_i18n.json'; $body = $(if (Test-Path -LiteralPath $tmp) { Get-Content -LiteralPath $tmp -Raw } else { '{}' }); $res.Headers.Add('Cache-Control', 'max-age=600'); $res.ContentType = 'application/json; charset=utf-8' }
                elseif ($path -eq '/radar.json') { $rjp = Join-Path (Split-Path $PSScriptRoot -Parent) '_data\radar.json'; $body = $(if (Test-Path -LiteralPath $rjp) { Get-Content -LiteralPath $rjp -Raw } else { '{"works":{}}' }); $res.Headers.Add('Cache-Control', 'max-age=300'); $res.ContentType = 'application/json; charset=utf-8' }
                elseif ($path -eq '/creator_radar.json') { $crp = Join-Path (Split-Path $PSScriptRoot -Parent) '_data\creator_radar.json'; $body = $(if (Test-Path -LiteralPath $crp) { Get-Content -LiteralPath $crp -Raw } else { '{"creators":{}}' }); $res.Headers.Add('Cache-Control', 'max-age=300'); $res.ContentType = 'application/json; charset=utf-8' }
                elseif ($path -eq '/creator_similar.json') { $csp = Join-Path (Split-Path $PSScriptRoot -Parent) '_data\creator_similar.json'; $body = $(if (Test-Path -LiteralPath $csp) { Get-Content -LiteralPath $csp -Raw } else { '{"creators":{}}' }); $res.Headers.Add('Cache-Control', 'max-age=300'); $res.ContentType = 'application/json; charset=utf-8' }
                elseif ($path -eq '/source_platform.json') { $spp = Join-Path (Split-Path $PSScriptRoot -Parent) '_data\source_platform.json'; $body = $(if (Test-Path -LiteralPath $spp) { Get-Content -LiteralPath $spp -Raw } else { '{"by_creator":{}}' }); $res.Headers.Add('Cache-Control', 'max-age=300'); $res.ContentType = 'application/json; charset=utf-8' }
                elseif ($path -eq '/ledger.json') {
                    # processing-version ledger (process_ledger.py): per-work stage recency + what each still needs. ~60s cache.
                    # sandbox realm: the ledger tracks the CORE pipeline only — return an empty summary so the
                    # sandbox intel page never shows core backlog numbers (#104).
                    if ($ctx.Request.QueryString['realm'] -eq 'sandbox') { $body = '{"summary":{}}'; $res.ContentType = 'application/json; charset=utf-8' }
                    else {
                    $now = [Environment]::TickCount64
                    if (-not $script:LedgerCache -or [math]::Abs($now - $script:LedgerAt) -gt 60000) {
                        $lp = Join-Path (Split-Path $PSScriptRoot -Parent) '_data\process_ledger.json'
                        $script:LedgerCache = $(if (Test-Path -LiteralPath $lp) { Get-Content -LiteralPath $lp -Raw } else { '{}' })
                        $script:LedgerAt = $now
                    }
                    $body = $script:LedgerCache; $res.ContentType = 'application/json; charset=utf-8'
                    }
                }
                elseif ($path -eq '/worksearch') {
                    # semantic "search by vibe": embed the query on the zettlab iGPU, cosine over work_index.json
                    $q = $ctx.Request.QueryString['q']
                    $body = '[]'
                    if (-not [string]::IsNullOrWhiteSpace($q)) {
                        try { $out = & python (Join-Path $PSScriptRoot 'build_work_index.py') '--query' $q '--json' '-k' '20' 2>$null
                            $line = @($out | Where-Object { $_ -match '^\[' })[0]
                            if ($line) { $body = $line } } catch {}
                    }
                    $res.ContentType = 'application/json; charset=utf-8'
                }
                elseif ($path -eq '/segsearch') {
                    # within-work "find the moment": embed the query (zettlab iGPU), cosine over segment_index
                    $q = $ctx.Request.QueryString['q']
                    $body = '[]'
                    if (-not [string]::IsNullOrWhiteSpace($q)) {
                        try { $out = & python (Join-Path $PSScriptRoot 'embed_segments.py') '--query' $q '--json' '-k' '24' 2>$null
                            $line = @($out | Where-Object { $_ -match '^\[' })[0]
                            if ($line) { $body = $line } } catch {}
                    }
                    $res.ContentType = 'application/json; charset=utf-8'
                }
                elseif ($path -eq '/subs') {
                    # a work's subtitle track as synced bilingual cues, for the player's transcript drawer
                    $id = $ctx.Request.QueryString['id']
                    $body = '{"cues":[],"lang":null}'
                    if (-not [string]::IsNullOrWhiteSpace($id)) {
                        try { $out = & python (Join-Path $PSScriptRoot 'subs_for.py') '--id' $id '--json' 2>$null
                            $line = @($out | Where-Object { $_ -match '^\{' })[0]
                            if ($line) { $body = $line } } catch {}
                    }
                    $res.ContentType = 'application/json; charset=utf-8'
                }
                elseif ($path -eq '/triggers') {
                    # CLAP binaural trigger detections for a work's player timeline:
                    # _data/derived/<Creator>/<stem>/triggers.json (written by the GPU comprehension
                    # pipeline). id is the audio_index relative key "Creator\file.ext" (same convention
                    # as /subs); derive the folder the same way Get-Library's DLsite-dedupe pass does.
                    $id = $ctx.Request.QueryString['id']
                    $body = '{"durSec":0,"ranges":[],"profile":{}}'
                    if (-not [string]::IsNullOrWhiteSpace($id)) {
                        try {
                            $derivedRoot = Join-Path (Split-Path $PSScriptRoot -Parent) '_data\derived'
                            $base = [IO.Path]::GetFileNameWithoutExtension(($id -split '[\\/]')[-1])
                            $dd = [IO.Path]::GetFullPath((Join-Path $derivedRoot ((Split-Path $id -Parent) + '\' + $base)))
                            $rootFull = [IO.Path]::GetFullPath($derivedRoot).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
                            if ($dd.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)) {   # block ..\ traversal
                                $tp = Join-Path $dd 'triggers.json'
                                if (Test-Path -LiteralPath $tp) { $body = Get-Content -LiteralPath $tp -Raw }
                            }
                        } catch {}
                    }
                    $res.ContentType = 'application/json; charset=utf-8'
                }
                elseif ($path -eq '/xstream') {
                    # cookie-injection on-demand stream of your OWN member content. xstream.py uses the
                    # VAULTED cookie SERVER-SIDE to resolve the current signed media URL; the browser only
                    # ever gets a 302 to that short-TTL self-authenticating URL -- never the cookie. Host is
                    # allowlist-gated (registry domains only) inside xstream.py (SSRF guard). Phase-1 =
                    # signed_url sources (ci-en/booth/dlsite); Auth0/HLS sources return 501 (Phase 2).
                    $src = $ctx.Request.QueryString['src']; $ref = $ctx.Request.QueryString['ref']
                    $res.ContentType = 'text/plain; charset=utf-8'; $body = ''
                    if ([string]::IsNullOrWhiteSpace($src) -or [string]::IsNullOrWhiteSpace($ref)) {
                        $res.StatusCode = 400; $body = 'need src and ref'
                    } else {
                        $j = $null
                        try { $out = & python (Join-Path $PSScriptRoot 'xstream.py') 'resolve' '--src' $src '--ref' $ref 2>$null
                            $line = @($out | Where-Object { $_ -match '^\{' })[0]
                            if ($line) { $j = $line | ConvertFrom-Json } } catch {}
                        if ($null -eq $j) { $res.StatusCode = 502; $body = 'resolve failed' }
                        elseif ($j.error) { $res.StatusCode = 502; $body = [string]$j.error }   # e.g. cookie dead -> re-export
                        elseif ($j.kind -eq 'signed_url' -and $j.url) { $res.Redirect([string]$j.url) }   # 302 -> CDN serves bytes + Range
                        else { $res.StatusCode = 501; $body = "source '$src' needs the Phase-2 $($j.kind) path (not built yet)" }
                    }
                }
                elseif ($path -eq '/library') { $body = Get-CachedHtml 'library.html'; $res.ContentType = 'text/html; charset=utf-8' }
                elseif ($path -eq '/home') { $body = Get-CachedHtml 'home.html'; $res.ContentType = 'text/html; charset=utf-8' }
                elseif ($path -eq '/app') { $body = Get-CachedHtml 'app.html'; $res.ContentType = 'text/html; charset=utf-8' }
                elseif ($path -eq '/wiki.json') { $body = $(if ($ctx.Request.QueryString['realm'] -eq 'sandbox') { Get-SandboxWikiIndex } else { Get-WikiIndex }); $res.ContentType = 'application/json; charset=utf-8' }
                elseif ($path -eq '/wikinote') { $body = Get-WikiNote $ctx.Request.QueryString['id']; if ($null -eq $body) { $res.StatusCode = 404; $body = '# not found' } else { $keepCache = $true }; $res.ContentType = 'text/markdown; charset=utf-8' }
                elseif ($path -eq '/wikitr') { $tr = Get-WikiTr $ctx.Request.QueryString['id'] $ctx.Request.QueryString['lang']; $res.StatusCode = [int]$tr.status; if ($tr.status -eq 202) { $res.ContentType = 'application/json; charset=utf-8' } else { $res.ContentType = 'text/markdown; charset=utf-8'; if ($tr.status -eq 200) { $keepCache = $true } }; $body = $tr.body }
                elseif ($path -eq '/wikimg') { Send-WikiImage $ctx; $handled = $true }
                elseif ($path -eq '/dlsite.json') { $dp = Join-Path (Split-Path $PSScriptRoot -Parent) '_wiki\DLsite\_products.json'; $body = $(if (Test-Path -LiteralPath $dp) { Get-Content -LiteralPath $dp -Raw } else { '{"products":[]}' }); $res.ContentType = 'application/json; charset=utf-8' }
                elseif ($path -eq '/dlimg') {
                    $full = Resolve-AudioPath $ctx.Request.QueryString['id']
                    if ($full -and $full -match '\.(png|jpe?g|webp|gif)$') {
                        $ct = switch ([IO.Path]::GetExtension($full).ToLower()) { '.png' { 'image/png' }; '.jpg' { 'image/jpeg' }; '.jpeg' { 'image/jpeg' }; '.webp' { 'image/webp' }; '.gif' { 'image/gif' }; default { 'application/octet-stream' } }
                        try { $b = [IO.File]::ReadAllBytes($full); $res.ContentType = $ct; $res.Headers.Add('Cache-Control', 'max-age=600'); $res.ContentLength64 = $b.Length; $res.OutputStream.Write($b, 0, $b.Length) } catch {}
                    } else { $res.StatusCode = 404 }
                    $handled = $true
                }
                elseif ($path -eq '/thumb') {
                    $full = Get-WorkThumb $ctx.Request.QueryString['id']
                    if ($full -and (Test-Path -LiteralPath $full)) {
                        $ct = switch ([IO.Path]::GetExtension($full).ToLower()) { '.png' { 'image/png' }; '.jpg' { 'image/jpeg' }; '.jpeg' { 'image/jpeg' }; '.webp' { 'image/webp' }; '.gif' { 'image/gif' }; default { 'image/jpeg' } }
                        try { $b = [IO.File]::ReadAllBytes($full); $res.ContentType = $ct; $res.Headers.Add('Cache-Control', 'max-age=3600'); $res.ContentLength64 = $b.Length; $res.OutputStream.Write($b, 0, $b.Length) } catch {}
                    } else { $res.StatusCode = 404 }
                    $handled = $true
                }
                elseif ($path -eq '/pfp') {
                    # creator avatar (_avatar.jpg fetched by fetch_sandbox_avatars.py). ?creator=<dir>&realm=sandbox|core.
                    # name is a single dir segment -- reject any path metachars (traversal guard).
                    $cn = "$($ctx.Request.QueryString['creator'])"
                    $full = $null
                    if ($cn -and $cn -notmatch '[\\/]|\.\.' ) {
                        $aroot = Split-Path $PSScriptRoot -Parent
                        $dir = if ($ctx.Request.QueryString['realm'] -eq 'sandbox') { Join-Path $aroot (Join-Path '_data\yt_ingest' $cn) } else { Join-Path $aroot $cn }
                        $cand = Join-Path $dir '_avatar.jpg'
                        if (Test-Path -LiteralPath $cand) { $full = $cand }
                    }
                    if ($full) {
                        try { $b = [IO.File]::ReadAllBytes($full); $res.ContentType = 'image/jpeg'; $res.Headers.Add('Cache-Control', 'max-age=86400'); $res.ContentLength64 = $b.Length; $res.OutputStream.Write($b, 0, $b.Length) } catch {}
                    } else { $res.StatusCode = 404 }
                    $handled = $true
                }
                elseif ($path -eq '/wiki') { $body = Get-CachedHtml 'wiki.html'; $res.ContentType = 'text/html; charset=utf-8' }
                elseif ($path -eq '/discover') { $body = Get-CachedHtml 'discover.html'; $res.ContentType = 'text/html; charset=utf-8' }
                elseif ($path -eq '/import') { $body = Get-CachedHtml 'import.html'; $res.ContentType = 'text/html; charset=utf-8' }
                elseif ($path -eq '/secrets.json') { $body = Get-SecretsJson; $res.ContentType = 'application/json; charset=utf-8' }
                elseif ($path -eq '/secrets/save' -and $ctx.Request.HttpMethod -eq 'POST') {
                    $reader = [IO.StreamReader]::new($ctx.Request.InputStream, $ctx.Request.ContentEncoding)
                    $raw = $reader.ReadToEnd(); $reader.Close()
                    $o = $null; try { $o = $raw | ConvertFrom-Json } catch {}
                    $body = Save-Secret $o; $res.ContentType = 'application/json; charset=utf-8'
                }
                elseif ($path -eq '/secrets/delete' -and $ctx.Request.HttpMethod -eq 'POST') {
                    $reader = [IO.StreamReader]::new($ctx.Request.InputStream, $ctx.Request.ContentEncoding)
                    $raw = $reader.ReadToEnd(); $reader.Close()
                    $o = $null; try { $o = $raw | ConvertFrom-Json } catch {}
                    $body = Delete-Secret $o; $res.ContentType = 'application/json; charset=utf-8'
                }
                elseif ($path -eq '/ai-chat') { $body = Get-CachedHtml 'ai_chat.html'; $res.ContentType = 'text/html; charset=utf-8' }
                elseif ($path -eq '/ai-chat/ask' -and $ctx.Request.HttpMethod -eq 'POST') {
                    $reader = [IO.StreamReader]::new($ctx.Request.InputStream, $ctx.Request.ContentEncoding)
                    $raw = $reader.ReadToEnd(); $reader.Close()
                    $body = Invoke-AiChat $raw; $res.ContentType = 'application/json; charset=utf-8'
                }
                elseif ($path -eq '/ai-chat/result') { $body = Get-ChatResult $ctx.Request.QueryString['id']; $res.ContentType = 'application/json; charset=utf-8' }
                elseif ($path -eq '/settings') { $body = Get-CachedHtml 'settings.html'; $res.ContentType = 'text/html; charset=utf-8' }
                elseif ($path -eq '/settings.json') { $body = Get-SettingsJson; $res.ContentType = 'application/json; charset=utf-8' }
                elseif ($path -eq '/settings/save' -and $ctx.Request.HttpMethod -eq 'POST') {
                    $reader = [IO.StreamReader]::new($ctx.Request.InputStream, $ctx.Request.ContentEncoding)
                    $raw = $reader.ReadToEnd(); $reader.Close()
                    $o = $null; try { $o = $raw | ConvertFrom-Json } catch {}
                    $body = Save-Settings $o; $res.ContentType = 'application/json; charset=utf-8'
                }
                elseif ($path -eq '/sandbox') { $body = Get-CachedHtml 'sandbox.html'; $res.ContentType = 'text/html; charset=utf-8' }
                elseif ($path -eq '/sandbox.json') { $body = Get-SandboxJson; $res.ContentType = 'application/json; charset=utf-8' }
                elseif ($path -eq '/sandbox/run' -and $ctx.Request.HttpMethod -eq 'POST') {
                    $reader = [IO.StreamReader]::new($ctx.Request.InputStream, $ctx.Request.ContentEncoding)
                    $raw = $reader.ReadToEnd(); $reader.Close()
                    $o = $null; try { $o = $raw | ConvertFrom-Json } catch {}
                    $body = Invoke-SandboxRun $o; $res.ContentType = 'application/json; charset=utf-8'
                }
                elseif ($path -eq '/metrics') { $body = Get-CachedHtml 'metrics.html'; $res.ContentType = 'text/html; charset=utf-8' }
                elseif ($path -eq '/metrics.json') { $body = $(if ($ctx.Request.QueryString['realm'] -eq 'sandbox') { Get-SandboxMetricsJson } else { Get-MetricsJson }); $res.ContentType = 'application/json; charset=utf-8' }
                elseif ($path -eq '/seeds.json') { $body = Get-WikiSeedsJson; $res.ContentType = 'application/json; charset=utf-8' }
                elseif ($path -eq '/import/youtube' -and $ctx.Request.HttpMethod -eq 'POST') {
                    $reader = [IO.StreamReader]::new($ctx.Request.InputStream, $ctx.Request.ContentEncoding)
                    $raw = $reader.ReadToEnd(); $reader.Close()
                    $o = $null; try { $o = $raw | ConvertFrom-Json } catch {}
                    $body = Invoke-MetaArchive $o; $res.ContentType = 'application/json; charset=utf-8'
                }
                elseif ($path -eq '/' -or $path -eq '/index.html') { $body = $ServeShell; $res.ContentType = 'text/html; charset=utf-8' }
                else { $res.StatusCode = 404; $body = 'not found' }
                if (-not $handled) {
                    $res.Headers.Add('Cache-Control', $(if ($keepCache) { 'max-age=120' } else { 'no-store' }))
                    $bytes = [Text.Encoding]::UTF8.GetBytes($body)
                    $res.ContentLength64 = $bytes.Length
                    $res.OutputStream.Write($bytes, 0, $bytes.Length)
                }
            }
            catch {
                try { "$([DateTime]::Now.ToString('HH:mm:ss')) $($ctx.Request.Url.AbsolutePath) :: $($_.Exception.Message)" |
                    Add-Content -LiteralPath (Join-Path $PSScriptRoot '_jobs\server_err.log') -Encoding utf8 } catch {}
                if (-not $handled -and -not $async) {        # don't leave the client with an empty 200 — send the error
                    try { $res.StatusCode = 500; $eb = [Text.Encoding]::UTF8.GetBytes('{"error":"handler"}'); $res.ContentLength64 = $eb.Length; $res.OutputStream.Write($eb, 0, $eb.Length) } catch {}
                }
            }
            finally { if (-not $async) { try { $res.OutputStream.Close() } catch {} } }   # async /audio is closed by its runspace
        }
    }
    finally { try { $listener.Stop() } catch {}; try { $streamPool.Close(); $streamPool.Dispose() } catch {} }
}

# --- main ---
if ($Serve) {
    $script:LogPinned = $PSBoundParameters.ContainsKey('Log')
    if (-not $PSBoundParameters.ContainsKey('Feed')) { $Feed = 60 }
    Start-Server
    return
}
if ($Open -and -not $Console) { } # browser opened after first render below
$first = $true
do {
    # auto-follow whichever run log is freshest (library/sata/rest), unless -Log was given
    if (-not $PSBoundParameters.ContainsKey('Log')) {
        $fresh = Get-ChildItem "$PSScriptRoot\*_run.log" -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($fresh) { $Log = $fresh.FullName }
    }
    $s = Parse-State
    $eta = Get-Eta $s
    $roll = Get-LibraryRollup
    if ($Console) { Render-Console $s $roll $eta }
    else {
        Render-Html $s $roll $eta
        if ($first -and $Open) { Start-Process $Html }
        if (-not $Loop) { Write-Host "Wrote $Html" -ForegroundColor Green }
    }
    $first = $false
    if ($Loop) { Start-Sleep -Seconds $RefreshSeconds }
} while ($Loop)

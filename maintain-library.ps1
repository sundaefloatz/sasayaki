<#
.SYNOPSIS
  Self-maintenance loop: keep the library's derived state current + verified, with NO cloud AI
  and no GPU. Everything it runs is stdlib-Python + ffmpeg, all local.

.DESCRIPTION
  Runs the four CPU-only builders in dependency order, then the integrity checker:
    1. analyze_audio.py   -> _wiki/audio_index.json   (acoustic stats + tags; new/changed files only)
    2. build_tags.py      -> _wiki/tags.json          (unified tag layer; reads the index)
    3. process_ledger.py  -> _data/process_ledger.json (per-work pipeline status)
    4. source_scan.py     -> _data/source_platform.json (acquisition-platform badges)
    5. library_doctor.py  -> _data/doctor_report.json  (integrity; --fix for the safe subset)

  Order matters: 2-4 all read analyze_audio's index, so it goes first. The doctor runs LAST so it
  judges the freshly-rebuilt state, and its exit code becomes this script's exit code (0 = clean).

  Idempotent and cheap to re-run: analyze_audio skips files whose size+mtime are unchanged, so a
  no-change nightly run is seconds, not minutes.

.PARAMETER Root
  Library root. Defaults to $env:SASAYAKI_ROOT, else the standard path.

.PARAMETER Fix
  Pass --fix to library_doctor (drops stale index entries, collapses mixed-separator duplicate
  keys, nulls non-finite values, deletes orphaned thumb-cache files). Never touches user media.

.PARAMETER Schedule
  Register a nightly Scheduled Task (03:15) running this script with -Fix. Mirrors the
  registration pattern used by sync-collection.ps1 / sync-worker-drive.ps1.

.EXAMPLE
  ./maintain-library.ps1                 # rebuild + verify, report only
.EXAMPLE
  ./maintain-library.ps1 -Fix            # rebuild + verify + repair the safe subset
.EXAMPLE
  ./maintain-library.ps1 -Schedule       # install the nightly job
#>
[CmdletBinding()]
param(
    [string]$Root = $(if ($env:SASAYAKI_ROOT) { $env:SASAYAKI_ROOT } else { '/media' }),
    [switch]$Fix,
    [switch]$Schedule
)
$ErrorActionPreference = 'Continue'
$here = $PSScriptRoot
$TaskName = 'Sasayaki-Maintain-Nightly'

if ($Schedule) {
    $argline = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Fix"
    $act = New-ScheduledTaskAction -Execute 'pwsh.exe' -Argument $argline
    $trg = New-ScheduledTaskTrigger -Daily -At 3:15am
    $set = New-ScheduledTaskSettingsSet -StartWhenAvailable -DontStopOnIdleEnd `
        -ExecutionTimeLimit (New-TimeSpan -Hours 6) -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskName $TaskName -Action $act -Trigger $trg -Settings $set -Force | Out-Null
    Write-Host "registered '$TaskName' -- nightly 03:15, runs with -Fix" -ForegroundColor Green
    Write-Host "  (StartWhenAvailable: a missed run fires once the PC is next awake)" -ForegroundColor DarkGray
    exit 0
}

if (-not (Test-Path -LiteralPath $Root)) {
    Write-Host "ABORT: library root not found ($Root)" -ForegroundColor Red; exit 1
}

$py = (Get-Command python -ErrorAction SilentlyContinue)?.Source
if (-not $py) { $py = (Get-Command python3 -ErrorAction SilentlyContinue)?.Source }
if (-not $py) { Write-Host 'ABORT: no python on PATH' -ForegroundColor Red; exit 1 }

$jobs = Join-Path $here '_jobs'
New-Item -ItemType Directory -Force -Path $jobs | Out-Null
$log = Join-Path $jobs ("maintain-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
$env:SASAYAKI_ROOT = $Root

function Step([string]$Label, [string]$Script, [string[]]$Extra) {
    $line = "=== $Label ==="
    Write-Host $line -ForegroundColor Cyan
    Add-Content -LiteralPath $log -Value "`r`n$line"
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $out = & $py (Join-Path $here $Script) @Extra 2>&1
    $sw.Stop()
    $code = $LASTEXITCODE
    $out | ForEach-Object { Write-Host "  $_" }
    Add-Content -LiteralPath $log -Value ($out | Out-String)
    $msg = "  -> {0} in {1:n1}s (exit {2})" -f $Label, $sw.Elapsed.TotalSeconds, $code
    Write-Host $msg -ForegroundColor DarkGray
    Add-Content -LiteralPath $log -Value $msg
    return $code
}

Write-Host "Sasayaki library maintenance -- root: $Root" -ForegroundColor Green
Write-Host "log: $log`n" -ForegroundColor DarkGray
Add-Content -LiteralPath $log -Value "maintain-library.ps1  root=$Root  started=$(Get-Date -Format s)  fix=$($Fix.IsPresent)"

$rebuild = 0
$rebuild += [int](Step 'analyze_audio (acoustic index)' 'analyze_audio.py' @('--root', $Root) -ne 0)
$rebuild += [int](Step 'build_tags (tag layer)'         'build_tags.py'     @() -ne 0)
$rebuild += [int](Step 'process_ledger (pipeline state)' 'process_ledger.py' @() -ne 0)
$rebuild += [int](Step 'source_scan (platform badges)'  'source_scan.py'    @('--root', $Root) -ne 0)

$docArgs = @('--root', $Root); if ($Fix) { $docArgs += '--fix' }
$docCode = Step 'library_doctor (integrity)' 'library_doctor.py' $docArgs

Write-Host ''
# Exit code is what the nightly Scheduled Task surfaces as pass/fail, so it must mean
# "a human needs to look at this" -- nothing less, nothing more:
#   builder crash            -> fail (the rebuild itself didn't complete)
#   doctor actionable issues -> fail (real corruption / repairable drift left over)
#   doctor advisory only     -> PASS (steady-state notes like report-only orphan dirs)
# Previously this returned the doctor's raw code, which was non-zero for advisories too --
# so a perfectly healthy library reported failure every single night and the signal was noise.
if ($rebuild -gt 0) {
    Write-Host "$rebuild builder step(s) reported a non-zero exit -- see $log" -ForegroundColor Red
}
if ($docCode -eq 0) {
    Write-Host 'library is intact (doctor: no actionable issues)' -ForegroundColor Green
}
else {
    Write-Host 'doctor found ACTIONABLE issues -- see _data/doctor_report.json' -ForegroundColor Yellow
}
$final = if ($rebuild -gt 0 -or $docCode -ne 0) { 1 } else { 0 }
Add-Content -LiteralPath $log -Value "finished=$(Get-Date -Format s) doctorExit=$docCode builderFailures=$rebuild exit=$final"
exit $final

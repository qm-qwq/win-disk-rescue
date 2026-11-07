<#
.SYNOPSIS
    win-disk-rescue - audit and reclaim disk space on Windows.

.DESCRIPTION
    Scans a system drive, reports what is actually consuming space, and offers
    a set of reversible, rule-driven cleanups. Nothing is deleted unless you
    pass -Apply.

.PARAMETER Mode
    Scan   read-only inventory (default)
    Safe   cache / temp / recycle bin / redundant archives / autostart noise
    Admin  DISM cleanup, page file, WSL virtual disks, suspect autostart
    All    Safe + Admin (needs elevation)

.PARAMETER Apply
    Actually perform the changes. Without it every mode is a dry run.

.PARAMETER Elevate
    Re-launch the script in an elevated window when admin rights are needed.

.PARAMETER Root
    Drive or folder to analyse. Defaults to the system drive.

.PARAMETER DisableRun
    Remove third-party HKCU Run entries (an allowlist keeps known-good ones).

.PARAMETER IncludeArchives
    Also delete archives that sit next to their own extracted folder.

.PARAMETER Json
    Emit the scan result as JSON on stdout instead of a readable report.

.EXAMPLE
    .\Invoke-DiskRescue.ps1
    .\Invoke-DiskRescue.ps1 -Mode Safe -Apply
    .\Invoke-DiskRescue.ps1 -Mode All -Apply -Elevate
    .\Invoke-DiskRescue.ps1 -Mode Admin -Apply -Elevate -WslDistro Ubuntu -WslDestination D:\wsl\Ubuntu
#>

[CmdletBinding()]
param(
    [ValidateSet('Scan', 'Safe', 'Admin', 'All')]
    [string]$Mode = 'Scan',

    [switch]$Apply,
    [switch]$Elevate,
    [switch]$Yes,

    [string]$Root,
    [int]$Top = 12,

    [switch]$DisableRun,
    [string[]]$KeepRun = @(),
    [switch]$IncludeArchives,

    [string]$WslDistro,
    [string]$WslDestination,

    [switch]$Json
)

$ErrorActionPreference = 'Stop'
$script:StartTime = Get-Date
$script:RootDir   = $PSScriptRoot

. (Join-Path $script:RootDir 'lib\Common.ps1')
. (Join-Path $script:RootDir 'lib\Scan.ps1')
. (Join-Path $script:RootDir 'lib\CleanSafe.ps1')
. (Join-Path $script:RootDir 'lib\CleanAdmin.ps1')

$script:RescueReportDir = Join-Path $script:RootDir 'reports'
if (-not (Test-Path $script:RescueReportDir)) { New-Item -ItemType Directory -Path $script:RescueReportDir -Force | Out-Null }

if (-not $Root) {
    $sys = $env:SystemDrive
    if (-not $sys) { $sys = 'C:' }
    $Root = $sys + '\'
}

# ---------------------------------------------------------------- elevation --
$needsAdmin = ($Mode -eq 'Admin' -or $Mode -eq 'All')
if ($needsAdmin -and -not (Test-Admin) -and $Elevate) {
    Write-Host 'Elevating...' -ForegroundColor Yellow
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $PSCommandPath + '"'),
                 '-Mode', $Mode, '-Root', ('"' + $Root + '"'))
    if ($Apply)   { $argList += '-Apply' }
    if ($Yes)     { $argList += '-Yes' }
    if ($IncludeArchives) { $argList += '-IncludeArchives' }
    if ($DisableRun)      { $argList += '-DisableRun' }
    if ($KeepRun.Count)   { $argList += '-KeepRun'; $argList += ($KeepRun -join ',') }
    if ($WslDistro)       { $argList += '-WslDistro'; $argList += $WslDistro }
    if ($WslDestination)  { $argList += '-WslDestination'; $argList += ('"' + $WslDestination + '"') }
    try {
        Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -Verb RunAs -ErrorAction Stop
    } catch {
        Write-Host 'Elevation was declined; admin steps will be skipped.' -ForegroundColor Yellow
    }
    return
}

$logName = 'rescue-' + $script:StartTime.ToString('yyyyMMdd-HHmmss') + '.log'
Set-RescueLog (Join-Path $script:RescueReportDir $logName)

$rules     = Get-RescueRules
$allowlist = $rules['autostart-allowlist']

# ------------------------------------------------------------------- banner --
if (-not $Json) {
    Write-Host ''
    Write-Host '  win-disk-rescue' -ForegroundColor Cyan
    $applyTag = if ($Apply) { '   [APPLY]' } else { '   [DRY RUN - nothing is deleted]' }
    Write-Host ('  mode: ' + $Mode + $applyTag) -ForegroundColor Gray
    Write-Host ('  root: ' + $Root) -ForegroundColor Gray
    Write-Host ('  admin: ' + (Test-Admin)) -ForegroundColor Gray
    Write-Host ('  log: ' + (Join-Path $script:RescueReportDir $logName)) -ForegroundColor DarkGray
}

# --------------------------------------------------------------------- scan --
$sysDriveLetter = 'C:'
if ($Root -match '^([A-Za-z]):') { $sysDriveLetter = $Matches[1].ToUpper() + ':' }
$disk = Get-FreeSpace $sysDriveLetter

Write-Step 'Disk overview'
$diskLines = @()
if ($disk) {
    $line = ('{0}  total {1}  used {2} ({3}%)  free {4}' -f `
             $disk.Drive, (Format-Size $disk.Total), (Format-Size $disk.Used), $disk.Pct, (Format-Size $disk.Free))
    if (-not $Json) { Write-Host ('   ' + $line) -ForegroundColor White }
    $diskLines += $line
}
foreach ($d in (Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction SilentlyContinue)) {
    if ($d.DeviceID -eq $disk.Drive) { continue }
    $line = ('{0}  total {1}  free {2}' -f $d.DeviceID, (Format-Size $d.Size), (Format-Size $d.FreeSpace))
    if (-not $Json) { Write-Host ('   ' + $line) -ForegroundColor DarkGray }
    $diskLines += $line
}

Write-Step ('Largest folders under ' + $Root)
$topDirs = @(Get-TopLevelSizes -Root $Root -Top $Top)
if (-not $Json) {
    foreach ($d in $topDirs) { Write-Host ('   {0,10}  {1}' -f (Format-Size $d.Bytes), $d.Path) -ForegroundColor Gray }
}

Write-Step 'Largest individual files'
$bigFiles = @(Get-BigFiles -Root $Root -MinBytes 300MB -Top 15)
if (-not $Json) {
    foreach ($f in $bigFiles) { Write-Host ('   {0,10}  {1}' -f (Format-Size $f.Bytes), $f.Path) -ForegroundColor Gray }
}

Write-Step 'Movable heavyweights'
$movable = @(Find-MovableHeavyweights -SystemDrive $sysDriveLetter)
if (-not $Json) {
    if ($movable.Count -eq 0) { Write-Info 'none found' }
    foreach ($m in $movable) {
        Write-Host ('   {0,10}  {1}  -  {2}' -f (Format-Size $m.Bytes), $m.Path, $m.Advice) -ForegroundColor Yellow
    }
}

Write-Step 'Reclaimable caches'
$junk = @(Find-JunkTargets -Rules $rules)
$junkTotal = ($junk | Measure-Object -Property Bytes -Sum).Sum
if (-not $junkTotal) { $junkTotal = 0 }
if (-not $Json) {
    foreach ($j in ($junk | Select-Object -First 20)) {
        Write-Host ('   {0,10}  {1}  ({2})' -f (Format-Size $j.Bytes), $j.Path, $j.Reason) -ForegroundColor Gray
    }
    if ($junk.Count -gt 20) { Write-Info ('... and ' + ($junk.Count - 20) + ' more') }
    Write-Host ('   total reclaimable: ' + (Format-Size $junkTotal)) -ForegroundColor Green
}

Write-Step 'Redundant archives (already extracted)'
$archives = @(Find-ExtractedArchives -Root $Root)
$archTotal = ($archives | Measure-Object -Property Bytes -Sum).Sum
if (-not $archTotal) { $archTotal = 0 }
if (-not $Json) {
    if ($archives.Count -eq 0) { Write-Info 'none found' }
    foreach ($a in $archives) {
        Write-Host ('   {0,10}  {1}' -f (Format-Size $a.Bytes), $a.Path) -ForegroundColor Gray
        Write-Host ('              -> ' + $a.ExtractedTo) -ForegroundColor DarkGray
    }
}

Write-Step 'Autostart inventory'
$auto = @(Get-AutostartItems)
$suspects = @()
foreach ($a in $auto) {
    $s = Test-AutostartSuspicion -Item $a -Allowlist $allowlist
    if ($s.Score -ge 3) {
        $suspects += [pscustomobject]@{
            Item = $a; Score = $s.Score; Reasons = $s.Reasons
        }
    }
}
if (-not $Json) {
    Write-Host ('   ' + $auto.Count + ' autostart entries, ' + $suspects.Count + ' scored as suspicious') -ForegroundColor Gray
    foreach ($s in $suspects) {
        Write-Host ('   [score ' + $s.Score + '] ' + $s.Item.Type + ': ' + $s.Item.Name) -ForegroundColor Red
        foreach ($r in $s.Reasons) { Write-Host ('            - ' + $r) -ForegroundColor DarkYellow }
    }
}

$excl = Get-DefenderExclusions
if ($excl.Available -and $excl.Paths.Count -gt 0 -and -not $Json) {
    Write-Step 'Defender exclusions'
    foreach ($p in $excl.Paths) { Write-Host ('   ' + $p) -ForegroundColor Yellow }
}

# ------------------------------------------------------------------- actions --
$freedSafe  = 0
$freedAdmin = 0

function Confirm-Action {
    param([string]$What)
    if ($Yes) { return $true }
    $answer = Read-Host ('   ' + $What + ' ? [y/N]')
    return ($answer -match '^(y|yes)$')
}

if ($Mode -eq 'Safe' -or $Mode -eq 'All') {
    Write-Step 'Cleanup: caches and temp'
    if ($Apply) {
        $freedSafe += Invoke-CleanCaches -Rules $rules -Apply
        $freedSafe += Invoke-EmptyRecycleBin -Apply
        $freedSafe += Invoke-CleanEdgeAutoLaunch -Apply
        $freedSafe += Invoke-DisableNoiseTasks -Apply
        if ($IncludeArchives) { $freedSafe += Invoke-CleanArchives -Root $Root -Apply }
        if ($DisableRun)      { Invoke-DisableRunEntries -Allowlist $allowlist -Apply -Keep $KeepRun | Out-Null }
    } else {
        Invoke-CleanCaches -Rules $rules | Out-Null
        Invoke-EmptyRecycleBin | Out-Null
        Invoke-CleanEdgeAutoLaunch | Out-Null
        Invoke-DisableNoiseTasks | Out-Null
        if ($IncludeArchives) { Invoke-CleanArchives -Root $Root | Out-Null }
        if ($DisableRun)      { Invoke-DisableRunEntries -Allowlist $allowlist -Keep $KeepRun | Out-Null }
        Write-Host ''
        Write-Host '   dry run: add -Apply to perform these deletions' -ForegroundColor Yellow
    }
}

if ($Mode -eq 'Admin' -or $Mode -eq 'All') {
    Write-Step 'Admin maintenance'
    if (-not (Test-Admin)) {
        Write-Warn2 'not elevated - run again with -Elevate'
    } else {
        $freedAdmin += Invoke-ComponentCleanup -Apply:$Apply
        $freedAdmin += Invoke-PagefileAuto -Apply:$Apply
        if ($WslDistro -and $WslDestination) {
            Invoke-MoveWsl -Distro $WslDistro -Destination $WslDestination -Apply:$Apply | Out-Null
        } else {
            foreach ($m in $movable) {
                if ($m.Kind -eq 'wsl-vhdx') { Invoke-CompactVhdx -VhdxPath $m.Path -Apply:$Apply | Out-Null }
            }
        }
        foreach ($s in $suspects) {
            if ($Apply) {
                if (Confirm-Action ('Disable ' + $s.Item.Type + ' "' + $s.Item.Name + '"')) {
                    Disable-SuspectAutostart -Item $s.Item -Apply | Out-Null
                }
            } else {
                Disable-SuspectAutostart -Item $s.Item | Out-Null
            }
        }
    }
}

# ------------------------------------------------------------------ summary --
$diskAfter = Get-FreeSpace $sysDriveLetter
if (-not $Json) {
    Write-Step 'Summary'
    Write-Host ('   free before : ' + (Format-Size $disk.Free)) -ForegroundColor Gray
    Write-Host ('   free after  : ' + (Format-Size $diskAfter.Free)) -ForegroundColor Green
    if ($Apply) {
        Write-Host ('   reclaimed   : ' + (Format-Size ($diskAfter.Free - $disk.Free))) -ForegroundColor Green
    } else {
        Write-Host ('   potential   : caches ' + (Format-Size $junkTotal) + ', archives ' + (Format-Size $archTotal)) -ForegroundColor Yellow
    }
    Write-Host ('   elapsed     : ' + [math]::Round(((Get-Date) - $script:StartTime).TotalSeconds, 1) + ' s') -ForegroundColor DarkGray
    Write-Host ''
}

if ($Json) {
    [pscustomobject]@{
        GeneratedAt = $script:StartTime.ToString('o')
        Disk        = $disk
        TopFolders  = $topDirs
        BigFiles    = $bigFiles
        Movable     = $movable
        Caches      = $junk
        Archives    = $archives
        Autostart   = $auto
        Suspects    = ($suspects | ForEach-Object { [pscustomobject]@{ Type = $_.Item.Type; Name = $_.Item.Name; Command = $_.Item.Command; Score = $_.Score; Reasons = $_.Reasons } })
    } | ConvertTo-Json -Depth 6
}

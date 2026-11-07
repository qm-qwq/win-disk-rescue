# ============================================================================
# CleanSafe.ps1 - everything that works without elevation.
# ============================================================================

function Invoke-CleanCaches {
    param($Rules, [switch]$Apply)
    $targets = Find-JunkTargets -Rules $Rules
    if (-not $targets -or $targets.Count -eq 0) { Write-Info 'no cache targets found'; return 0 }
    $total = 0
    foreach ($t in $targets) {
        $older = if ($t.MinAgeDays -gt 0) { (Get-Date).AddDays(-$t.MinAgeDays) } else { [datetime]::MinValue }
        $total += Clear-DirContents -Path $t.Path -Reason $t.Reason -Apply:$Apply -OlderThan $older
    }
    return $total
}

function Invoke-EmptyRecycleBin {
    param([switch]$Apply)
    $before = 0
    foreach ($d in (Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction SilentlyContinue)) {
        $rb = Join-Path (($d.DeviceID) + '\') '$Recycle.Bin'
        if (Test-Path -LiteralPath $rb) { $before += Get-FolderSize $rb }
    }
    if ($before -le 0) { Write-Info 'recycle bin already empty'; return 0 }
    if ($Apply) {
        foreach ($dl in (Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction SilentlyContinue)) {
            Clear-RecycleBin -DriveLetter $dl.DeviceID.Substring(0, 1) -Force -ErrorAction SilentlyContinue
        }
        Write-Ok ('recycle bin emptied: ' + (Format-Size $before))
    } else {
        Write-Info ('would empty recycle bin: ' + (Format-Size $before))
    }
    return $before
}

function Invoke-CleanArchives {
    param([string]$Root, [switch]$Apply)
    $hits = Find-ExtractedArchives -Root $Root
    if (-not $hits -or $hits.Count -eq 0) { Write-Info 'no redundant archives found'; return 0 }
    $total = 0
    foreach ($h in $hits) {
        $total += Remove-SafeItem -Path $h.Path -Reason $h.Reason -Apply:$Apply
    }
    return $total
}

# Edge creates one "MicrosoftEdgeAutoLaunch_*" value per profile, forever.
function Invoke-CleanEdgeAutoLaunch {
    param([switch]$Apply)
    $paths = @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run'
    ) | Select-Object -Unique
    $removed = 0
    foreach ($p in $paths) {
        $item = Get-Item -LiteralPath $p -ErrorAction SilentlyContinue
        if (-not $item) { continue }
        foreach ($n in $item.GetValueNames()) {
            if ($n -like 'MicrosoftEdgeAutoLaunch_*') {
                if ($Apply) {
                    Remove-ItemProperty -LiteralPath $p -Name $n -Force -ErrorAction SilentlyContinue
                    if (-not (Get-ItemProperty -LiteralPath $p -Name $n -ErrorAction SilentlyContinue)) { $removed++ }
                } else { $removed++ }
            }
        }
    }
    if ($removed -gt 0) {
        if ($Apply) { Write-Ok ('removed ' + $removed + ' Edge auto-launch entries') }
        else        { Write-Info ('would remove ' + $removed + ' Edge auto-launch entries') }
    } else { Write-Info 'no Edge auto-launch entries' }
    return $removed
}

# Disable known telemetry / updater / promo scheduled tasks.
function Invoke-DisableNoiseTasks {
    param([switch]$Apply)
    $patterns = @(
        'OneDrive Reporting Task*', 'OneDrive Standalone Update Task*',
        'PlatformExperiencesHelper*', 'RunPlatformExperienceHelper*',
        'SoftLanding*', 'NVIDIA App SelfUpdate*',
        'GoogleUserPEH*', 'Adobe Acrobat Update Task'
    )
    $n = 0
    foreach ($t in (Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.State -ne 'Disabled' })) {
        foreach ($p in $patterns) {
            if ($t.TaskName -like $p) {
                if ($Apply) {
                    try { Disable-ScheduledTask -TaskPath $t.TaskPath -TaskName $t.TaskName -ErrorAction Stop | Out-Null; $n++ }
                    catch { Write-Skip ('cannot disable (needs admin): ' + $t.TaskName) }
                } else { $n++; Write-Info ('would disable: ' + $t.TaskName) }
                break
            }
        }
    }
    if ($n -eq 0) { Write-Info 'no noise tasks matched' }
    elseif ($Apply) { Write-Ok ('disabled ' + $n + ' background tasks') }
    return $n
}

# Disable third-party Run entries, keeping anything on the allowlist.
function Invoke-DisableRunEntries {
    param($Allowlist, [switch]$Apply, [string[]]$Keep)
    $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    $item = Get-Item -LiteralPath $key -ErrorAction SilentlyContinue
    if (-not $item) { return 0 }
    $backup = @{}
    $n = 0
    foreach ($name in $item.GetValueNames()) {
        $cmd = [string]$item.GetValue($name)
        $skip = $false
        foreach ($k in $Keep) { if ($name -like $k) { $skip = $true } }
        if ($Allowlist) {
            foreach ($a in $Allowlist.entries) {
                if ($name -like $a.name -or ($a.match -and $cmd -like ('*' + $a.match + '*'))) { $skip = $true }
            }
        }
        if ($skip) { Write-Skip ('kept: ' + $name); continue }
        $backup[$name] = $cmd
        if ($Apply) {
            Remove-ItemProperty -LiteralPath $key -Name $name -Force -ErrorAction SilentlyContinue
            Write-Ok ('removed autorun: ' + $name)
        } else {
            Write-Info ('would remove autorun: ' + $name + '  ->  ' + $cmd)
        }
        $n++
    }
    if ($backup.Count -gt 0 -and $Apply) {
        $bakPath = Join-Path $script:RescueReportDir ('autorun-backup-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.json')
        $backup | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $bakPath -Encoding UTF8
        Write-Info ('backup written: ' + $bakPath)
    }
    return $n
}

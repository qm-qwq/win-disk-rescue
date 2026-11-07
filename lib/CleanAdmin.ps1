# ============================================================================
# CleanAdmin.ps1 - maintenance that requires an elevated session.
# Every function is a no-op with a clear message when not elevated; the caller
# decides whether to re-launch.
# ============================================================================

function Assert-Admin {
    param([string]$Action)
    if (Test-Admin) { return $true }
    Write-Warn2 ($Action + ' needs administrator rights - re-run with -Elevate or as admin')
    return $false
}

# Reclaim superseded WinSxS payloads.
function Invoke-ComponentCleanup {
    param([switch]$Apply, [switch]$ResetBase)
    if (-not (Assert-Admin 'DISM component cleanup')) { return 0 }
    $before = (Get-FreeSpace 'C:').Free
    if (-not $Apply) {
        $tag = if ($ResetBase) { ' /ResetBase' } else { '' }
        Write-Info ('would run: dism /Online /Cleanup-Image /StartComponentCleanup' + $tag)
        Write-Info ('WinSxS currently ' + (Format-Size (Get-FolderSize 'C:\Windows\WinSxS')))
        return 0
    }
    $dismArgs = @('/Online', '/Cleanup-Image', '/StartComponentCleanup', '/NoRestart')
    if ($ResetBase) { $dismArgs += '/ResetBase' }
    & dism.exe @dismArgs 2>&1 | Select-Object -Last 6 | ForEach-Object { Write-Log $_ }
    $after = (Get-FreeSpace 'C:').Free
    $freed = $after - $before
    if ($freed -gt 0) { Write-Ok ('component cleanup freed ' + (Format-Size $freed)) } else { Write-Info 'component cleanup finished' }
    return $freed
}

# A fixed-size page file is dead weight on a machine with enough RAM.
function Invoke-PagefileAuto {
    param([switch]$Apply)
    if (-not (Assert-Admin 'page file reconfiguration')) { return 0 }
    $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
    $pf = Get-CimInstance Win32_PageFileSetting -ErrorAction SilentlyContinue
    $size = 0
    if (Test-Path 'C:\pagefile.sys') { $size = (Get-Item 'C:\pagefile.sys' -Force).Length }

    if ($cs.AutomaticManagedPagefile) {
        Write-Info ('page file already system managed (' + (Format-Size $size) + ')')
        return 0
    }
    $desc = if ($pf) { ('fixed, init ' + $pf.InitialSize + ' MB / max ' + $pf.MaximumSize + ' MB') } else { 'custom' }
    if (-not $Apply) {
        Write-Info ('would switch page file to system managed (currently ' + $desc + ', ' + (Format-Size $size) + ')')
        return 0
    }
    Set-CimInstance -InputObject $cs -Property @{ AutomaticManagedPagefile = $true } -ErrorAction SilentlyContinue
    Write-Ok 'page file switched to system managed (takes effect after reboot)'
    return $size
}

# Shrink a WSL ext4.vhdx that grew and never released space.
function Invoke-CompactVhdx {
    param([string]$VhdxPath, [switch]$Apply)
    if (-not (Test-Path -LiteralPath $VhdxPath)) { Write-Skip ('no such vhdx: ' + $VhdxPath); return 0 }
    if (-not (Assert-Admin 'virtual disk compaction')) { return 0 }
    $before = (Get-Item -LiteralPath $VhdxPath -Force).Length
    if (-not $Apply) {
        Write-Info ('would compact ' + $VhdxPath + ' (' + (Format-Size $before) + ')')
        return 0
    }
    try { & wsl.exe --shutdown 2>&1 | Out-Null } catch {}
    Start-Sleep -Seconds 2
    $script = @"
select vdisk file="$VhdxPath"
attach vdisk readonly
compact vdisk
detach vdisk
exit
"@
    $tmp = Join-Path $env:TEMP ('compact-' + [guid]::NewGuid().ToString('N') + '.txt')
    Set-Content -LiteralPath $tmp -Value $script -Encoding ASCII
    & diskpart.exe /s $tmp 2>&1 | ForEach-Object { Write-Log $_ }
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    $after = (Get-Item -LiteralPath $VhdxPath -Force).Length
    $freed = $before - $after
    if ($freed -gt 0) { Write-Ok ('compacted: freed ' + (Format-Size $freed)) } else { Write-Info 'vhdx already compact' }
    return $freed
}

# Move a WSL distro to another drive (the big win on a small system SSD).
function Invoke-MoveWsl {
    param([string]$Distro, [string]$Destination, [switch]$Apply)
    if (-not $Distro -or -not $Destination) { Write-Warn2 'move needs -Distro and -Destination'; return $false }
    if (-not (Assert-Admin 'moving a WSL distro')) { return $false }
    if (-not $Apply) {
        Write-Info ('would move distro ' + $Distro + ' to ' + $Destination)
        return $false
    }
    $before = (Get-FreeSpace 'C:').Free
    & wsl.exe --shutdown 2>&1 | Out-Null
    Start-Sleep -Seconds 2
    & wsl.exe --manage $Distro --move $Destination 2>&1 | ForEach-Object { Write-Log $_ }
    $after = (Get-FreeSpace 'C:').Free
    if ($after -gt $before) { Write-Ok ('C: freed ' + (Format-Size ($after - $before))) }
    return $true
}

# Remove a path that a normal user account cannot delete.
function Remove-ProtectedItem {
    param([string]$Path, [switch]$Apply)
    if (-not (Test-Path -LiteralPath $Path)) { Write-Skip ('not present: ' + $Path); return 0 }
    $size = Get-FolderSize $Path
    if (-not (Assert-Admin 'deleting a protected path')) { return 0 }
    if (-not $Apply) { Write-Info ('would delete ' + (Format-Size $size) + '  ' + $Path); return 0 }
    & takeown.exe /f $Path /r /d Y 2>&1 | Out-Null
    & icacls.exe $Path /grant ('*S-1-5-32-544:(OI)(CI)F') /t /c 2>&1 | Out-Null
    Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $Path) { Write-Warn2 ('locked, still present: ' + $Path); return 0 }
    Write-Ok ('deleted ' + (Format-Size $size) + '  ' + $Path)
    return $size
}

# Neutralise an autostart entry that scored as suspicious.
function Disable-SuspectAutostart {
    param($Item, [switch]$Apply)
    if (-not (Assert-Admin 'disabling an autostart entry')) { return $false }
    switch ($Item.Type) {
        'ScheduledTask' {
            if ($Apply) {
                Stop-ScheduledTask -TaskPath $Item.Key -TaskName $Item.Name -ErrorAction SilentlyContinue
                Unregister-ScheduledTask -TaskPath $Item.Key -TaskName $Item.Name -Confirm:$false -ErrorAction SilentlyContinue
                Write-Ok ('removed task: ' + $Item.Key + $Item.Name)
            } else { Write-Info ('would remove task: ' + $Item.Key + $Item.Name) }
        }
        'RegistryRun' {
            if ($Apply) {
                Remove-ItemProperty -LiteralPath $Item.Key -Name $Item.Name -Force -ErrorAction SilentlyContinue
                Write-Ok ('removed autorun: ' + $Item.Name)
            } else { Write-Info ('would remove autorun: ' + $Item.Name) }
        }
        'StartupFolder' {
            $full = Join-Path $Item.Key $Item.Name
            if ($Apply) { Remove-Item -LiteralPath $full -Force -ErrorAction SilentlyContinue; Write-Ok ('removed startup item: ' + $Item.Name) }
            else { Write-Info ('would remove startup item: ' + $Item.Name) }
        }
    }
    return $true
}

function Remove-DefenderExclusion {
    param([string]$Path, [string]$Process, [switch]$Apply)
    if (-not (Assert-Admin 'editing Defender exclusions')) { return 0 }
    $n = 0
    foreach ($p in @($Path)) {
        if (-not $p) { continue }
        if ($Apply) {
            Remove-MpPreference -ExclusionPath $p -ErrorAction SilentlyContinue
            Write-Ok ('removed Defender exclusion: ' + $p)
        } else { Write-Info ('would remove Defender exclusion: ' + $p) }
        $n++
    }
    return $n
}

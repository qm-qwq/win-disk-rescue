# ============================================================================
# Scan.ps1 - read-only inventory. Nothing in this file deletes anything.
# ============================================================================

function Expand-RescuePath {
    param([string]$Path)
    if (-not $Path) { return $Path }
    $expanded = [Environment]::ExpandEnvironmentVariables($Path)
    # allow a conventional ~ for the user profile
    if ($expanded.StartsWith('~\')) { $expanded = Join-Path $env:USERPROFILE $expanded.Substring(2) }
    return $expanded
}

function Get-RescueRules {
    $root = Split-Path -Parent $PSScriptRoot
    $rules = [ordered]@{}
    foreach ($name in 'junk-paths', 'autostart-allowlist') {
        $f = Join-Path (Join-Path $root 'rules') ($name + '.json')
        if (Test-Path $f) {
            try { $rules[$name] = Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json }
            catch { Write-Warn2 ('rule file broken: ' + $f) }
        }
    }
    return $rules
}

function Get-TopLevelSizes {
    param([string]$Root, [int]$Top = 12)
    $out = @()
    foreach ($d in (Get-ChildItem -LiteralPath $Root -Force -Directory -ErrorAction SilentlyContinue)) {
        $size = Get-FolderSize $d.FullName
        if ($size -gt 0) {
            $out += [pscustomobject]@{ Path = $d.FullName; Name = $d.Name; Bytes = $size }
        }
    }
    return ($out | Sort-Object Bytes -Descending | Select-Object -First $Top)
}

function Get-BigFiles {
    param([string]$Root, [double]$MinBytes = 300MB, [int]$Top = 25)
    $out = @()
    $skip = @('\Windows\WinSxS\', '\Windows\Installer\', '\$Recycle.Bin\', '\System Volume Information\')
    Get-ChildItem -LiteralPath $Root -Recurse -Force -File -ErrorAction SilentlyContinue |
        ForEach-Object {
            $f = $_
            $bad = $false
            foreach ($s in $skip) { if ($f.FullName -like ('*' + $s + '*')) { $bad = $true; break } }
            if (-not $bad -and $f.Length -ge $MinBytes) {
                $out += [pscustomobject]@{ Path = $f.FullName; Bytes = [double]$f.Length }
            }
        }
    return ($out | Sort-Object Bytes -Descending | Select-Object -First $Top)
}

# ---------------------------------------------------------------------------
# Junk: cache directories, temp files, thumbnails, crash dumps
# ---------------------------------------------------------------------------
function Find-JunkTargets {
    param($Rules)
    $result = @()
    $junk = $Rules['junk-paths']
    if (-not $junk) { return $result }

    foreach ($entry in $junk.cacheDirs) {
        $p = Expand-RescuePath $entry.path
        if (-not $p -or -not (Test-Path -LiteralPath $p)) { continue }
        $size = Get-FolderSize $p
        if ($size -le 0) { continue }
        $result += [pscustomobject]@{
            Path       = $p
            Bytes      = $size
            Reason     = $entry.reason
            MinAgeDays = if ($null -ne $entry.minAgeDays) { [int]$entry.minAgeDays } else { 0 }
            Kind       = 'cache'
        }
    }

    # nested cache folders inside app data (Chrome/Edge/Electron apps)
    $names = @($junk.relativeCacheNames)
    foreach ($rootEntry in $junk.cacheScanRoots) {
        $root = Expand-RescuePath $rootEntry
        if (-not (Test-Path -LiteralPath $root)) { continue }
        $dirs = Get-ChildItem -LiteralPath $root -Recurse -Directory -Force -ErrorAction SilentlyContinue -Depth 6 |
                Where-Object { $names -contains $_.Name }
        foreach ($d in $dirs) {
            $size = Get-FolderSize $d.FullName
            if ($size -lt 20MB) { continue }
            $result += [pscustomobject]@{
                Path = $d.FullName; Bytes = $size; Reason = ('app cache: ' + $d.Name)
                MinAgeDays = 0; Kind = 'cache'
            }
        }
    }
    return ($result | Sort-Object Bytes -Descending)
}

# ---------------------------------------------------------------------------
# Redundant archives: an archive sitting next to its own extracted folder
# ---------------------------------------------------------------------------
function Find-ExtractedArchives {
    param([string]$Root, [double]$MinBytes = 200MB)
    $out = @()
    $exts = @('.7z', '.rar', '.zip', '.tar', '.gz', '.zst', '.iso')
    Get-ChildItem -LiteralPath $Root -Recurse -Force -File -ErrorAction SilentlyContinue |
        Where-Object { $exts -contains $_.Extension.ToLower() -and $_.Length -ge $MinBytes } |
        ForEach-Object {
            $arc = $_
            $stem = [System.IO.Path]::GetFileNameWithoutExtension($arc.Name)
            $parent = $arc.DirectoryName
            $candidates = @(
                (Join-Path $parent $stem),
                (Join-Path (Split-Path $parent -Parent) $stem)
            )
            foreach ($c in $candidates) {
                if ((Test-Path -LiteralPath $c) -and (Get-Item -LiteralPath $c).PSIsContainer) {
                    $dirSize = Get-FolderSize $c
                    if ($dirSize -ge $arc.Length * 0.5) {
                        $out += [pscustomobject]@{
                            Path        = $arc.FullName
                            Bytes       = [double]$arc.Length
                            Reason      = ('already extracted to ' + $c)
                            ExtractedTo = $c
                            ExtractedBytes = $dirSize
                            Kind        = 'archive'
                        }
                        break
                    }
                }
            }
        }
    return ($out | Sort-Object Bytes -Descending)
}

# ---------------------------------------------------------------------------
# Movable heavyweights: WSL disks, vendor recovery blobs, pagefile, hiberfil
# ---------------------------------------------------------------------------
function Find-MovableHeavyweights {
    param([string]$SystemDrive = 'C:')
    $out = @()

    # WSL virtual disks under the user profile
    $wslRoots = @("$env:LOCALAPPDATA\wsl", "$env:LOCALAPPDATA\Packages", "$env:LOCALAPPDATA\Docker")
    foreach ($wr in $wslRoots) {
        if (-not (Test-Path -LiteralPath $wr)) { continue }
        Get-ChildItem -LiteralPath $wr -Recurse -Force -File -Filter '*.vhdx' -ErrorAction SilentlyContinue |
            ForEach-Object {
                if ($_.Length -lt 1GB) { return }
                $out += [pscustomobject]@{
                    Kind   = 'wsl-vhdx'
                    Name   = 'WSL virtual disk'
                    Path   = $_.FullName
                    Bytes  = [double]$_.Length
                    Advice = 'move with: wsl --manage <Distro> --move D:\wsl\<Distro>  (or compact it)'
                }
            }
    }

    # OEM recovery / driver backup folders in the drive root
    foreach ($d in (Get-ChildItem -LiteralPath ($SystemDrive + '\') -Force -Directory -ErrorAction SilentlyContinue)) {
        if ($d.Name -match '^(eSupport|Recovery|OEM|Drivers|SWSetup)$') {
            $size = Get-FolderSize $d.FullName
            if ($size -lt 500MB) { continue }
            $out += [pscustomobject]@{
                Kind   = 'oem-backup'
                Name   = 'OEM driver/recovery backup'
                Path   = $d.FullName
                Bytes  = $size
                Advice = 'move to another drive; only needed to reinstall factory drivers'
            }
        }
    }

    # page file (Get-Item fails on the locked system file - enumerate instead)
    $pf = $SystemDrive + '\pagefile.sys'
    $pfItem = Get-ChildItem -LiteralPath ($SystemDrive + '\') -Force -File -Filter 'pagefile.sys' -ErrorAction SilentlyContinue |
              Select-Object -First 1
    if ($pfItem) {
        $size = $pfItem.Length
        $manual = Get-CimInstance Win32_PageFileSetting -ErrorAction SilentlyContinue
        $note = if ($manual -and $manual.InitialSize) {
            ('fixed size ' + [math]::Round($manual.InitialSize / 1024, 1) + ' GB - switch to system managed to shrink it')
        } else { 'system managed' }
        $out += [pscustomobject]@{
            Kind = 'pagefile'; Name = 'pagefile.sys'; Path = $pf
            Bytes = [double]$size; Advice = $note
        }
    }

    # hibernation file
    $hf = $SystemDrive + '\hiberfil.sys'
    $hfItem = Get-ChildItem -LiteralPath ($SystemDrive + '\') -Force -File -Filter 'hiberfil.sys' -ErrorAction SilentlyContinue |
              Select-Object -First 1
    if ($hfItem) {
        $out += [pscustomobject]@{
            Kind = 'hiberfil'; Name = 'hiberfil.sys'; Path = $hf
            Bytes = [double]$hfItem.Length; Advice = 'disable with: powercfg /h off   (kills fast startup too)'
        }
    }

    return ($out | Sort-Object Bytes -Descending)
}

# ---------------------------------------------------------------------------
# Autostart inventory
# ---------------------------------------------------------------------------
function Get-AutostartItems {
    $out = @()
    $runKeys = @(
        @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run';       Scope = 'HKCU' },
        @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce';   Scope = 'HKCU' },
        @{ Path = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run';       Scope = 'Machine' },
        @{ Path = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\RunOnce';   Scope = 'Machine' },
        @{ Path = 'HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Run'; Scope = 'Machine' }
    )
    foreach ($rk in $runKeys) {
        $item = Get-Item -LiteralPath $rk.Path -ErrorAction SilentlyContinue
        if (-not $item) { continue }
        foreach ($n in $item.GetValueNames()) {
            $out += [pscustomobject]@{
                Type = 'RegistryRun'; Scope = $rk.Scope; Key = $rk.Path
                Name = $n; Command = [string]$item.GetValue($n)
            }
        }
    }

    $startMenus = @(
        @{ Path = (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup'); Scope = 'HKCU' },
        @{ Path = 'C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Startup';            Scope = 'Machine' }
    )
    $sh = $null
    foreach ($sm in $startMenus) {
        if (-not (Test-Path -LiteralPath $sm.Path)) { continue }
        foreach ($f in (Get-ChildItem -LiteralPath $sm.Path -Force -File -ErrorAction SilentlyContinue)) {
            $target = ''
            if ($f.Extension -eq '.lnk') {
                try {
                    if (-not $sh) { $sh = New-Object -ComObject WScript.Shell }
                    $target = $sh.CreateShortcut($f.FullName).TargetPath
                } catch { $target = '' }
            }
            $out += [pscustomobject]@{
                Type = 'StartupFolder'; Scope = $sm.Scope; Key = $sm.Path
                Name = $f.Name; Command = $target
            }
        }
    }

    # Scheduled tasks: include the \Microsoft\ tree on purpose. Malware loves to
    # hide there, and the scoring step knows how to tell the two apart.
    foreach ($t in (Get-ScheduledTask -ErrorAction SilentlyContinue |
                    Where-Object { $_.State -ne 'Disabled' })) {
        $cmd = ($t.Actions | ForEach-Object { $_.Execute }) -join ' | '
        if (-not $cmd) { continue }
        $out += [pscustomobject]@{
            Type = 'ScheduledTask'; Scope = 'Machine'; Key = $t.TaskPath
            Name = $t.TaskName; Command = $cmd
        }
    }
    return $out
}

# ---------------------------------------------------------------------------
# Suspicion scoring for autostart entries
# ---------------------------------------------------------------------------
function Test-AutostartSuspicion {
    param($Item, $Allowlist)

    $score   = 0
    $reasons = @()
    $cmd = [string]$Item.Command
    if (-not $cmd) { return @{ Score = 0; Reasons = @() } }

    # allowlist wins outright
    if ($Allowlist) {
        foreach ($a in $Allowlist.entries) {
            if ($Item.Name -like $a.name -or ($a.match -and $cmd -like ('*' + $a.match + '*'))) {
                return @{ Score = 0; Reasons = @('allowlisted: ' + $a.name) }
            }
        }
    }

    $exePath = $null
    if ($cmd -match '^\s*"([^"]+)"')          { $exePath = $Matches[1] }
    elseif ($cmd -match '^\s*([^\s"]+\.exe)') { $exePath = $Matches[1] }
    if (-not $exePath) { return @{ Score = 0; Reasons = @() } }

    # task XML stores things like %windir%\system32\foo.exe - expand before any path test
    $exePath = [Environment]::ExpandEnvironmentVariables($exePath)

    # a bare name ("sc.exe", "BthUdTask.exe") is resolved through PATH; there is
    # nothing useful to inspect and it must not be flagged
    if ($exePath -notmatch '\\') { return @{ Score = 0; Reasons = @() } }

    $inSystem = $false
    $protectedRoots = @("$env:SystemRoot\System32\", "$env:SystemRoot\SysWOW64\", "$env:SystemRoot\WinSxS\")
    foreach ($r in $protectedRoots) {
        if ($exePath.StartsWith($r, 'OrdinalIgnoreCase')) { $inSystem = $true }
    }

    # 1) something living under a \Microsoft\ task path that is not a Windows binary
    if ($Item.Type -eq 'ScheduledTask' -and $Item.Key -like '\Microsoft\*' -and -not $inSystem) {
        $score += 4
        $reasons += ('non-Windows binary registered under ' + $Item.Key)
    }

    # 2) signature and metadata quality - only worth checking outside System32,
    #    every binary in there is Microsoft-signed by definition
    if (-not $inSystem -and (Test-Path -LiteralPath $exePath)) {
        if (-not $script:__sigCache) { $script:__sigCache = @{} }
        if (-not $script:__sigCache.ContainsKey($exePath)) {
            $sig = $null
            try { $sig = Get-AuthenticodeSignature -LiteralPath $exePath -ErrorAction SilentlyContinue } catch {}
            $script:__sigCache[$exePath] = $sig
        }
        $sig = $script:__sigCache[$exePath]
        if (-not $sig -or $sig.Status -ne 'Valid') {
            $score += 3
            $reasons += ('not validly signed: ' + $exePath)
        }
        $ver = (Get-Item -LiteralPath $exePath -Force -ErrorAction SilentlyContinue).VersionInfo
        if (-not $ver -or -not $ver.CompanyName) {
            $score += 2
            $reasons += 'no company/version metadata'
        }
    } elseif ($Item.Type -eq 'ScheduledTask') {
        $score += 2
        $reasons += ('target does not exist: ' + $exePath)
    }

    # 3) random-looking file names (etywRHcV63I0.ps1, VvQq6mGRJINl.xml ...)
    $leaf = ''
    try { $leaf = [System.IO.Path]::GetFileNameWithoutExtension($exePath) } catch { $leaf = '' }
    if ($leaf -and $leaf.Length -ge 10 -and $leaf -match '^[A-Za-z0-9]+$' -and
        $leaf -cmatch '[a-z]' -and $leaf -cmatch '[A-Z]' -and $leaf -match '\d') {
        $score += 2
        $reasons += ('random-looking filename: ' + $leaf)
    }

    # 4) names that imitate Windows components
    if ($cmd -match '(HiddenLoader|RUXIM|WindowsUpdateService|svch0st|lsasss)') {
        $score += 3
        $reasons += 'name imitates a Windows component'
    }

    # a properly signed binary inside Program Files is normal software, not a plant
    if ($exePath -match '^[A-Z]:\\Program Files') {
        $s = $null
        try { $s = Get-AuthenticodeSignature -LiteralPath $exePath -ErrorAction SilentlyContinue } catch {}
        if ($s -and $s.Status -eq 'Valid') { $score -= 4 }
    }

    # 5) executables hiding in AppData temp-ish locations
    if ($exePath -match '\\(Temp|tmp|Downloads|AppData\\Roaming)\\.+\.exe$') {
        $score += 2
        $reasons += 'executable launched from a temp/download location'
    }

    return @{ Score = $score; Reasons = $reasons }
}

function Get-DefenderExclusions {
    if (-not (Test-Admin)) { return @{ Available = $false; Paths = @(); Processes = @() } }
    $p = Get-MpPreference -ErrorAction SilentlyContinue
    return @{
        Available = $true
        Paths     = @($p.ExclusionPath)
        Processes = @($p.ExclusionProcess)
    }
}

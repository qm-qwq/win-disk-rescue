# ============================================================================
# Common.ps1 - shared helpers. Keep this file pure ASCII: it must parse under
# Windows PowerShell 5.1 regardless of the console code page.
# ============================================================================

$script:RescueLog = $null
$script:DryRun    = $true

function Set-RescueLog { param([string]$Path)
    $script:RescueLog = $Path
    if ($Path) {
        $dir = Split-Path -Parent $Path
        if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Set-Content -Path $Path -Value ('# win-disk-rescue log ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')) -Encoding UTF8
    }
}

function Write-Step { param([string]$Message)
    Write-Host ''
    Write-Host ('== ' + $Message) -ForegroundColor Cyan
    Write-Log $Message
}

function Write-Log { param([string]$Message, [string]$Level = 'INFO')
    if ($script:RescueLog) {
        Add-Content -Path $script:RescueLog -Value ((Get-Date -Format 'HH:mm:ss') + ' [' + $Level + '] ' + $Message) -Encoding UTF8
    }
}

function Write-Ok   { param([string]$m) Write-Host ('   [ok]   ' + $m) -ForegroundColor Green;  Write-Log $m 'OK' }
function Write-Warn2{ param([string]$m) Write-Host ('   [warn] ' + $m) -ForegroundColor Yellow; Write-Log $m 'WARN' }
function Write-Bad  { param([string]$m) Write-Host ('   [!!!!] ' + $m) -ForegroundColor Red;    Write-Log $m 'ALERT' }
function Write-Info { param([string]$m) Write-Host ('   ' + $m) -ForegroundColor Gray;           Write-Log $m }
function Write-Skip { param([string]$m) Write-Host ('   [skip] ' + $m) -ForegroundColor DarkGray; Write-Log $m 'SKIP' }

function Format-Size { param([double]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N0} KB' -f ($Bytes / 1KB)) }
    return ('{0:N0} B' -f $Bytes)
}

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-FolderSize {
    param([string]$Path, [int]$TimeoutSec = 0)
    if (-not (Test-Path -LiteralPath $Path)) { return 0 }
    $sum = 0
    try {
        $sum = (Get-ChildItem -LiteralPath $Path -Recurse -Force -File -ErrorAction SilentlyContinue |
                Measure-Object -Property Length -Sum).Sum
    } catch { $sum = 0 }
    if (-not $sum) { return 0 }
    return [double]$sum
}

function Get-FreeSpace { param([string]$Drive = 'C:')
    $d = Get-CimInstance -ClassName Win32_LogicalDisk -Filter ("DeviceID='" + $Drive + "'") -ErrorAction SilentlyContinue
    if (-not $d) { return $null }
    return [pscustomobject]@{
        Drive = $Drive
        Total = [double]$d.Size
        Free  = [double]$d.FreeSpace
        Used  = [double]($d.Size - $d.FreeSpace)
        Pct   = if ($d.Size -gt 0) { [math]::Round((($d.Size - $d.FreeSpace) / $d.Size) * 100, 1) } else { 0 }
    }
}

# Delete with guard rails. Everything is dry-run unless -Apply was passed.
function Remove-SafeItem {
    param(
        [string]$Path,
        [string]$Reason = '',
        [switch]$Apply
    )
    if (-not (Test-Path -LiteralPath $Path)) { return 0 }
    $isDir  = (Get-Item -LiteralPath $Path -Force).PSIsContainer
    $size   = if ($isDir) { Get-FolderSize $Path } else { (Get-Item -LiteralPath $Path -Force).Length }

    # hard guard rails: never touch these, no matter what a rule says
    $forbidden = @(
        'C:\Windows\System32', 'C:\Windows\SysWOW64', 'C:\Windows\WinSxS',
        'C:\Windows\System32\drivers', 'C:\Windows\Fonts',
        'C:\Program Files', 'C:\Program Files (x86)', 'C:\ProgramData',
        'C:\Users', 'C:\Windows\assembly', 'C:\Windows\boot'
    )
    foreach ($f in $forbidden) {
        if ($Path.TrimEnd('\') -ieq $f) {
            Write-Bad ('REFUSED (protected path): ' + $Path)
            return 0
        }
    }

    $suffix = if ($Reason) { '  (' + $Reason + ')' } else { '' }
    if ($Apply) {
        try {
            Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
            Write-Ok ('deleted ' + (Format-Size $size) + '  ' + $Path + $suffix)
            return $size
        } catch {
            Write-Warn2 ('locked, skipped: ' + $Path)
            Write-Log ('  ' + $_.Exception.Message) 'WARN'
            return 0
        }
    } else {
        Write-Info ('would delete ' + (Format-Size $size) + '  ' + $Path + $suffix)
        return $size
    }
}

function Clear-DirContents {
    param([string]$Path, [string]$Reason = '', [switch]$Apply, [datetime]$OlderThan = [datetime]::MinValue)
    if (-not (Test-Path -LiteralPath $Path)) { return 0 }
    $total = 0
    $items = Get-ChildItem -LiteralPath $Path -Force -Recurse -ErrorAction SilentlyContinue
    $files = $items | Where-Object { -not $_.PSIsContainer }
    if ($OlderThan -ne [datetime]::MinValue) { $files = $files | Where-Object { $_.LastWriteTime -lt $OlderThan } }
    foreach ($f in $files) {
        $total += Remove-SafeItem -Path $f.FullName -Reason $Reason -Apply:$Apply
    }
    return $total
}

function New-SizeAccumulator { return @{ Bytes = [double]0 } }

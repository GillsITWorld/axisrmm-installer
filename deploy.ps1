# Install-AxisAgent.ps1 v4 — Universal installer for AxisRMM v2
# Works from: AFD LAN, Home LAN, Remote/VPN
$ErrorActionPreference = 'Stop'
Set-ExecutionPolicy Bypass -Scope Process -Force
function Log($msg) { Write-Host "[AxisRMM] $msg" -ForegroundColor Cyan }

# Try multiple download sources — first one that works determines backend
$sources = @(
    @{ base = "http://192.168.239.50:8772/portal";  backend = "http://192.168.239.50:8772";  direct=$false },
    @{ base = "http://192.168.4.99:8099";            backend = "http://192.168.4.99:9000";    direct=$false },
    @{ base = "http://192.168.4.99:9000/portal";    backend = "http://192.168.4.99:9000";    direct=$false },
    @{ base = "https://github.com/GillsITWorld/axisrmm-installer/releases/download/v2.0.0-dist13"; backend = "https://rmm.gillsitworld.com"; direct=$true },
    @{ base = "https://rmm.gillsitworld.com/portal"; backend = "https://rmm.gillsitworld.com"; direct=$false }
)

# Download to ProgramData (not Temp) — AppLocker/BD Application Control
# blocks exe execution from Temp on some machines
$stage = "C:\ProgramData\AxisRMM"
New-Item $stage -ItemType Directory -Force -EA SilentlyContinue | Out-Null
$exePath = Join-Path $stage "AxisRMM.exe"
$cerPath = Join-Path $stage "AxisRMM-CodeSign.cer"
$ok      = $false
$backend = ""

# ── Kill any existing AxisRMM processes BEFORE downloading so we can overwrite ──
Log "Killing any existing AxisRMM processes to release file locks..."
Get-Process -Name "AxisRMM*" -EA SilentlyContinue | ForEach-Object { try { $_.Kill(); $_.WaitForExit(3000) } catch {} }
foreach ($t in @('AxisRMM-Agent','AxisRMM-Bot','AxisRMM-V2-Agent','AxisRMM-V2-Bot')) {
    try { Stop-ScheduledTask -TaskName $t -EA SilentlyContinue } catch {}
}
Start-Sleep -Seconds 2

foreach ($src in $sources) {
    Log "Trying $($src.base)..."
    try {
        Invoke-WebRequest "$($src.base)/AxisRMM-CodeSign.cer" -OutFile $cerPath -UseBasicParsing -TimeoutSec 10
        Invoke-WebRequest "$($src.base)/AxisRMM.exe" -OutFile $exePath -UseBasicParsing -TimeoutSec 90
        if ((Get-Item $exePath).Length -gt 10MB) {
            $backend = $src.backend
            $ok = $true
            Log "Downloaded from $($src.base)"
            break
        }
    } catch {
        Log "  Failed: $($_.Exception.Message)"
    }
}
if (-not $ok) { Write-Error "All download URLs failed"; exit 1 }

# Trust code-signing cert (no SmartScreen warning)
Log "Trusting code-signing certificate (non-fatal if fails)..."
try {
    Import-Certificate -FilePath $cerPath -CertStoreLocation Cert:\LocalMachine\Root -EA Stop | Out-Null
    Import-Certificate -FilePath $cerPath -CertStoreLocation Cert:\LocalMachine\TrustedPublisher -EA Stop | Out-Null
    Log "  Cert imported OK"
} catch {
    Log "  Cert import skipped: $($_.Exception.Message)"
}
try { Unblock-File $exePath -EA SilentlyContinue } catch {}

$sz = [math]::Round((Get-Item $exePath).Length / 1MB, 1)
Log "Ready: $sz MB (signed: Gills IT World)"

# Auto-detect client from hostname
$hn = $env:COMPUTERNAME
if ($hn -match '^(Command-Center|GILL-.*|HOMEPC|NucBox.*|Candace.*|Triton.*|Atlas.*|Nova.*)$') { $client = 'gill-home' }
elseif ($hn -match '^(SS64|Scripts)$') { $client = 'gillsitworld' }
else { $client = 'afdllc' }

# Override backend for gill-home (uses CC proxy)
if ($client -eq 'gill-home' -and $backend -notlike '*239*') {
    $backend = "http://192.168.4.99:9000"
}

Log "Host=$hn  Client=$client  Backend=$backend"
Log "Installing..."

# Kill any existing
Get-Process AxisRMM -EA SilentlyContinue | ForEach-Object { try { $_.Kill() } catch {} }
foreach ($t in @('AxisRMM-Agent','AxisRMM-Bot','AxisRMM-V2-Agent','AxisRMM-V2-Bot')) {
    try { Stop-ScheduledTask -TaskName $t -EA SilentlyContinue } catch {}
}
Start-Sleep 2

# Install
$p = Start-Process -FilePath $exePath -ArgumentList "install","--client=$client","--backend=$backend","--hide-tray" -Wait -PassThru -NoNewWindow
# ExitCode -1 is normal (installer returns -1 on success in some cases)
if ($p.ExitCode -notin @(0, -1)) { Write-Error "Install failed rc=$($p.ExitCode)"; exit $p.ExitCode }

# Start tasks
foreach ($t in @('AxisRMM-Agent','AxisRMM-Bot','AxisRMM-V2-Agent','AxisRMM-V2-Bot')) {
    try { Start-ScheduledTask -TaskName $t -EA SilentlyContinue } catch {}
}
Start-Sleep 3

# Launch bot in the INTERACTIVE user session (not Session 0 / SYSTEM).
# When run via Pulseway/SYSTEM, Start-Process lands in Session 0 where
# tray icons are invisible. Use a one-shot scheduled task with INTERACTIVE
# group to spawn in the logged-in user's desktop session.
$installDir = "C:\ProgramData\AxisRMM"
$exeInstalled = Join-Path $installDir "AxisRMM.exe"
if (-not (Test-Path $exeInstalled)) { $exeInstalled = Join-Path $installDir "AxisRMM_new.exe" }
if (Test-Path $exeInstalled) {
    # Create a one-shot task that runs as the interactive user
    $taskName = "AxisRMM-BotLaunch-" + [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $action   = New-ScheduledTaskAction -Execute $exeInstalled -Argument '--role=bot'
    $principal = New-ScheduledTaskPrincipal -GroupId 'INTERACTIVE' -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -DeleteExpiredTaskAfter ([TimeSpan]::FromMinutes(5))
    $trigger  = New-ScheduledTaskTrigger -Once -At (Get-Date).AddSeconds(2)
    try {
        Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Settings $settings -Trigger $trigger -Force -EA Stop | Out-Null
        Log "Bot launch task '$taskName' created — tray will appear in user session"
        # Also try to run it immediately
        Start-Sleep 1
        Start-ScheduledTask -TaskName $taskName -EA SilentlyContinue
    } catch {
        Log "Task creation failed ($_) — falling back to direct launch"
        Start-Process -FilePath $exeInstalled -ArgumentList '--role=bot' -WindowStyle Hidden
    }
    # Clean up the one-shot task after 60s
    Start-Job -ScriptBlock {
        param($tn)
        Start-Sleep 60
        Unregister-ScheduledTask -TaskName $tn -Confirm:$false -EA SilentlyContinue
    } -ArgumentList $taskName | Out-Null
}
Start-Sleep 3
$n = @(Get-Process AxisRMM -EA SilentlyContinue).Count
Log "Done! $n processes running on $hn (client=$client, backend=$backend)"

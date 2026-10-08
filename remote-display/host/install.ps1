# Remote PC: set up the Windows side. In PowerShell (as yourself; one UAC prompt follows):
#
#   irm https://raw.githubusercontent.com/dkiiv/frametop/remote-display-poc-handoff/remote-display/host/install.ps1 | iex
#
# Downloads ftrd-host.ps1 into %LOCALAPPDATA%\ftrd and runs its -Install: Vibepollo (downloaded,
# checksum-verified, installed if missing), its login and an API token for the helper, the helper
# itself (at every logon), and 30 minutes in which the Frame pairs without questions.
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$dir = Join-Path $env:LOCALAPPDATA 'ftrd'
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$f = Join-Path $dir 'ftrd-host.ps1'
Invoke-WebRequest -UseBasicParsing 'https://raw.githubusercontent.com/dkiiv/frametop/remote-display-poc-handoff/remote-display/host/ftrd-host.ps1' -OutFile $f
& "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File $f -Install

<#
ftrd-host.ps1: the PC's half of the Frame link (see README.md next to it).

While the Steam Frame shows virtual monitors (Vibepollo "Remote Monitor" streams), it answers
this agent's pings (ftrd-presence on the Frame) with where each monitor's panel floats. The agent:
  - arranges Windows' virtual monitors the way the panels sit around you (left of / right of /
    above each other), so dragging windows between them works as it looks;
  - in control mode, also takes the physical monitors off the desktop, so every window lives on
    a monitor you can see from the Frame;
  - gives the PC its own monitors back (the saved baseline layout) as soon as the Frame stops
    answering (TimeoutSeconds) or reports no monitors, and also when this agent dies while the
    physical monitors are off (a guard process watches it);
  - otherwise keeps the physical layout at the baseline (Vibepollo 2.0.0 doesn't restore it).

Usage (PowerShell 5.1, as the logged-in user; no admin needed):
  ftrd-host.ps1 -Setup            make the link key and save the current physical layout as the baseline
  ftrd-host.ps1 -SaveBaseline     save the current physical layout as the baseline
  ftrd-host.ps1 -Status           displays, baseline, Frame answer, mode
  ftrd-host.ps1 -Restore          physical monitors back to the baseline now
  ftrd-host.ps1 -Run [-Control]   the agent (Startup folder); -Control (or the file control.on in
                                  the data folder) turns on taking the physical monitors off
Data folder: %LOCALAPPDATA%\ftrd (link.key, baseline.json, control.on, vibepollo.token (optional),
ftrd-host.log).
Emergency: Win+P -> Extend brings the physical monitors back whatever this agent does.
#>
param([switch]$Setup, [switch]$SaveBaseline, [switch]$Status, [switch]$Restore, [switch]$Run, [switch]$Control,
      [int]$Guard = 0, [string[]]$Frame = @('10.35.78.1', '10.0.0.253'), [int]$Port = 47810,
      [double]$TimeoutSeconds = 5, [string]$VibepolloConfig = 'C:\Program Files\Sunshine\config')
$ErrorActionPreference = 'Continue'
$Data = Join-Path $env:LOCALAPPDATA 'ftrd'
New-Item -ItemType Directory -Force -Path $Data | Out-Null
$LogFile = Join-Path $Data 'ftrd-host.log'
$ArmedFile = Join-Path $Data 'armed'
function Log($m) {
  $line = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' ' + $m
  Add-Content -Path $LogFile -Value $line
  if (-not $Run -and -not $Guard) { Write-Output $line }
}

Add-Type @'
using System; using System.Runtime.InteropServices;
public static class FtrdHost {
  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] public struct DEVMODE {
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
    public short dmSpecVersion, dmDriverVersion, dmSize, dmDriverExtra; public int dmFields;
    public int x, y, dmDisplayOrientation, dmDisplayFixedOutput;
    public short dmColor, dmDuplex, dmYResolution, dmTTOption, dmCollate;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
    public short dmLogPixels; public int bpp, w, h, dmDisplayFlags, freq;
    public int r1, r2, r3, r4, r5, r6, r7, r8; }
  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] public struct DISPLAY_DEVICE {
    public int cb; [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string DeviceName;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceString; public int StateFlags;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceID;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceKey; }
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern bool EnumDisplayDevices(string dev, int i, ref DISPLAY_DEVICE dd, int flags);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern bool EnumDisplaySettings(string dev, int mode, ref DEVMODE dm);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int ChangeDisplaySettingsEx(string dev, ref DEVMODE dm, IntPtr hwnd, uint flags, IntPtr l);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int ChangeDisplaySettingsEx(string dev, IntPtr dm, IntPtr hwnd, uint flags, IntPtr l);
  [DllImport("user32.dll")] public static extern int SetDisplayConfig(uint a, IntPtr b, uint c, IntPtr d, uint flags);
}
'@
$DM_POSITION = 0x20; $DM_BPP = 0x40000; $DM_W = 0x80000; $DM_H = 0x100000; $DM_FREQ = 0x400000
$CDS_UPDATEREGISTRY = 0x1; $CDS_SET_PRIMARY = 0x10; $CDS_NORESET = 0x10000000
$VirtualPattern = 'Virtual|SudoMaker|Idd|Parsec|Moonlight'
function NewDm { $d = New-Object FtrdHost+DEVMODE; $d.dmSize = [Runtime.InteropServices.Marshal]::SizeOf($d); $d }
function NewDd { $d = New-Object FtrdHost+DISPLAY_DEVICE; $d.cb = [Runtime.InteropServices.Marshal]::SizeOf($d); $d }

# Every display output: attached or not, physical or virtual, its monitor's id, current mode.
function Outputs {
  $out = @()
  for ($i = 0; $i -lt 64; $i++) {
    $dd = NewDd
    if (-not [FtrdHost]::EnumDisplayDevices([NullString]::Value, $i, [ref]$dd, 0)) { break }
    $mon = NewDd
    $monId = ''
    if ([FtrdHost]::EnumDisplayDevices($dd.DeviceName, 0, [ref]$mon, 0)) { $monId = $mon.DeviceID }
    $attached = ($dd.StateFlags -band 1) -ne 0
    $dm = NewDm
    $ok = [FtrdHost]::EnumDisplaySettings($dd.DeviceName, -1, [ref]$dm)
    $out += [pscustomobject]@{
      Name = $dd.DeviceName; Adapter = $dd.DeviceString; MonitorId = $monId; Attached = $attached
      Primary = (($dd.StateFlags -band 4) -ne 0); Virtual = ($dd.DeviceString -match $VirtualPattern)
      W = $(if ($ok -and $attached) { $dm.w } else { 0 }); H = $(if ($ok -and $attached) { $dm.h } else { 0 })
      Hz = $(if ($ok -and $attached) { $dm.freq } else { 0 }); X = $dm.x; Y = $dm.y
    }
  }
  $out
}
function Describe($os) {
  ($os | Where-Object Attached | ForEach-Object {
    '{0}{1} {2}x{3}@{4} at {5},{6}{7}' -f $_.Name.Replace('\\.\', ''), $(if ($_.Virtual) { '(v)' } else { '' }), $_.W, $_.H, $_.Hz, $_.X, $_.Y, $(if ($_.Primary) { ' P' } else { '' })
  }) -join '; '
}

# ---- baseline (the physical layout to give back) ------------------------------------------
$BaselineFile = Join-Path $Data 'baseline.json'
function Get-Baseline { if (Test-Path $BaselineFile) { Get-Content $BaselineFile -Raw | ConvertFrom-Json } else { $null } }
function Save-Baseline {
  $phys = @(Outputs | Where-Object { $_.Attached -and -not $_.Virtual })
  if (-not $phys) { Log 'no attached physical monitor; baseline not saved'; return }
  $b = @($phys | ForEach-Object { [pscustomobject]@{ MonitorId = $_.MonitorId; Name = $_.Name; W = $_.W; H = $_.H; Hz = $_.Hz; X = $_.X; Y = $_.Y; Primary = $_.Primary } })
  ConvertTo-Json -InputObject $b -Depth 3 | Set-Content -Path $BaselineFile
  Log ('baseline saved: ' + (Describe $phys))
}
# The output a baseline entry's monitor is on now (outputs get renumbered).
function Find-Output($os, $entry) {
  $o = $os | Where-Object { $_.MonitorId -and $_.MonitorId -eq $entry.MonitorId } | Select-Object -First 1
  if (-not $o) { $o = $os | Where-Object { $_.Name -eq $entry.Name -and -not $_.Virtual } | Select-Object -First 1 }
  $o
}

# One batch of display changes: entries @{ Name; Fields; X; Y; W; H; Hz; Primary } then apply.
function Apply-Batch($entries, $why) {
  $results = @()
  foreach ($e in ($entries | Sort-Object { -not $_.Primary })) {
    $dm = NewDm
    [void][FtrdHost]::EnumDisplaySettings($e.Name, -2, [ref]$dm)  # registry mode: works detached too
    $dm.dmFields = $e.Fields; $dm.x = $e.X; $dm.y = $e.Y
    if ($e.Fields -band $DM_W) { $dm.w = $e.W; $dm.h = $e.H }
    if ($e.Fields -band $DM_FREQ) { $dm.freq = $e.Hz }
    $flags = $CDS_UPDATEREGISTRY -bor $CDS_NORESET
    if ($e.Primary) { $flags = $flags -bor $CDS_SET_PRIMARY }
    $results += ('{0}={1}' -f $e.Name.Replace('\\.\', ''), [FtrdHost]::ChangeDisplaySettingsEx($e.Name, [ref]$dm, [IntPtr]::Zero, $flags, [IntPtr]::Zero))
  }
  $apply = [FtrdHost]::ChangeDisplaySettingsEx([NullString]::Value, [IntPtr]::Zero, [IntPtr]::Zero, 0, [IntPtr]::Zero)
  Start-Sleep -Milliseconds 800
  Log ("$why`: " + ($results -join ' ') + " apply=$apply -> " + (Describe (Outputs)))
  return $apply -eq 0
}

# Physical monitors back as in the baseline; virtual ones (if any) placed right of them.
function Restore-Physical($why, $virtualPlan) {
  $b = Get-Baseline
  if (-not $b) { Log "$why`: no baseline; Win+P -> Extend"; [void][FtrdHost]::SetDisplayConfig(0, [IntPtr]::Zero, 0, [IntPtr]::Zero, 0x84); return }
  $os = Outputs
  $entries = @()
  foreach ($e in $b) {
    $o = Find-Output $os $e
    if (-not $o) { continue }
    $entries += @{ Name = $o.Name; Fields = ($DM_POSITION -bor $DM_W -bor $DM_H -bor $DM_FREQ); X = $e.X; Y = $e.Y; W = $e.W; H = $e.H; Hz = $e.Hz; Primary = [bool]$e.Primary }
  }
  if ($virtualPlan) { $entries += $virtualPlan }
  if (-not (Apply-Batch $entries $why)) {
    Log "$why`: retrying after SetDisplayConfig(EXTEND)"
    [void][FtrdHost]::SetDisplayConfig(0, [IntPtr]::Zero, 0, [IntPtr]::Zero, 0x84)
    Start-Sleep -Seconds 2
    [void](Apply-Batch $entries "$why (retry)")
  }
}
function Physical-Matches($os) {
  $b = Get-Baseline
  if (-not $b) { return $true }
  foreach ($e in $b) {
    $o = Find-Output $os $e
    if (-not $o -or -not $o.Attached) { return $false }
    if ($o.X -ne $e.X -or $o.Y -ne $e.Y -or $o.W -ne $e.W -or $o.H -ne $e.H -or $o.Primary -ne [bool]$e.Primary -or ($e.Hz -and $o.Hz -lt $e.Hz)) { return $false }
  }
  return $true
}

# ---- which Windows display shows which Frame monitor --------------------------------------
# The Frame sends its client certificate's SHA-256; Vibepollo's state file has each pairing's
# certificate and id, and its log names the display it made for that id.
$script:certMap = @{}; $script:certMapAt = Get-Date '2000-01-01'
function Cert-Uuid($sha) {
  if (((Get-Date) - $script:certMapAt).TotalSeconds -gt 60) {
    $script:certMap = @{}; $script:certMapAt = Get-Date
    try {
      $st = Get-Content (Join-Path $VibepolloConfig 'sunshine_state.json') -Raw | ConvertFrom-Json
      foreach ($d in $st.root.named_devices) {
        $body = ($d.cert -split "`n" | Where-Object { $_ -and $_ -notmatch '-----' }) -join ''
        $der = [Convert]::FromBase64String($body.Trim())
        $h = [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($der)).Replace('-', '').ToLower()
        $script:certMap[$h] = $d.uuid
      }
    } catch { Log "can't read Vibepollo's pairings: $_" }
  }
  $script:certMap[$sha]
}
function Uuid-Display($uuid) {
  try {
    $logDir = Join-Path $VibepolloConfig 'logs'
    $f = Get-ChildItem $logDir -File | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    $fs = [IO.File]::Open($f.FullName, 'Open', 'Read', 'ReadWrite')
    $len = [Math]::Min($fs.Length, 4MB); [void]$fs.Seek(-$len, 'End')
    $buf = New-Object byte[] $len; [void]$fs.Read($buf, 0, $len); $fs.Close()
    $text = [Text.Encoding]::UTF8.GetString($buf)
    $m = [regex]::Matches($text, "exact capture target for client '" + [regex]::Escape($uuid) + "' is '\\\\\.\\(DISPLAY\d+)'")
    if ($m.Count) { return '\\.\' + $m[$m.Count - 1].Groups[1].Value }
  } catch {}
  $null
}

# Where each Frame monitor goes: columns left to right by azimuth (panels within 12 degrees of
# each other stack, the higher one on top), top-aligned; the panel nearest straight ahead is
# the primary candidate. Returns entries for Apply-Batch, positions relative to the group.
function Plan-Virtual($mons, $os, $originX, $makePrimary) {
  $items = @()
  $virt = @($os | Where-Object { $_.Attached -and $_.Virtual })
  $i = 0
  foreach ($m in $mons) {
    $name = $null
    $uuid = if ($m.cert_sha256) { Cert-Uuid $m.cert_sha256 } else { $null }
    if ($uuid) { $name = Uuid-Display $uuid }
    $o = if ($name) { $virt | Where-Object { $_.Name -eq $name } | Select-Object -First 1 } else { $null }
    if (-not $o) { $o = $virt | Where-Object { $_.W -eq $m.w -and $_.H -eq $m.h -and $items.Name -notcontains $_.Name } | Select-Object -First 1 }
    if (-not $o) { continue }
    # No panel pose (ft-floatd without "list apps"): a row, in instance order.
    $az = if ($null -ne $m.az) { [double]$m.az } else { 1000 + 100 * $i }; $el = if ($null -ne $m.el) { [double]$m.el } else { 0 }
    $items += [pscustomobject]@{ Name = $o.Name; W = $o.W; H = $o.H; Az = $az; El = $el }
    $i++
  }
  if (-not $items) { return @() }
  $cols = @(); $cur = $null
  foreach ($it in ($items | Sort-Object Az)) {
    if ($cur -and [Math]::Abs($it.Az - $cur.Az) -lt 12) { $cur.Items += $it } else { $cur = [pscustomobject]@{ Az = $it.Az; Items = @($it) }; $cols += $cur }
  }
  $plan = @(); $x = 0
  foreach ($c in $cols) {
    $y = 0; $cw = 0
    foreach ($it in ($c.Items | Sort-Object El -Descending)) {
      $plan += [pscustomobject]@{ Name = $it.Name; X = $x; Y = $y; W = $it.W; H = $it.H; Az = $it.Az }
      $y += $it.H; $cw = [Math]::Max($cw, $it.W)
    }
    $x += $cw
  }
  $front = ($plan | Sort-Object { [Math]::Abs($_.Az) } | Select-Object -First 1).Name
  $dx = $originX; $dy = 0
  if ($makePrimary) { $p = $plan | Where-Object Name -eq $front; $dx = -$p.X; $dy = -$p.Y }
  @($plan | ForEach-Object { @{ Name = $_.Name; Fields = $DM_POSITION; X = $_.X + $dx; Y = $_.Y + $dy; Primary = ($makePrimary -and $_.Name -eq $front) } })
}
function Plan-Matches($plan, $os) {
  foreach ($e in $plan) {
    $o = $os | Where-Object Name -eq $e.Name
    if (-not $o -or -not $o.Attached -or $o.X -ne $e.X -or $o.Y -ne $e.Y -or ($e.Primary -and -not $o.Primary)) { return $false }
  }
  return $true
}

# The Frame is gone: ask Vibepollo to remove its virtual monitors too (the streams died with
# the Frame; otherwise it keeps them). Needs an API token in vibepollo.token (web UI: API
# tokens; scope POST /api/display/terminate_virtual is enough). Without one, they stay.
function Terminate-Virtual {
  $tf = Join-Path $Data 'vibepollo.token'
  if (-not (Test-Path $tf)) { Log 'no vibepollo.token: virtual monitors left to Vibepollo'; return }
  try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    [Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }  # localhost, self-signed
    $r = Invoke-RestMethod -Method Post -Uri 'https://localhost:47990/api/display/terminate_virtual' -ContentType 'application/json' `
      -Body '{}' -Headers @{ Authorization = 'Bearer ' + (Get-Content $tf -Raw).Trim() } -TimeoutSec 20
    Log ('Vibepollo terminate_virtual: ' + (ConvertTo-Json -InputObject $r -Compress))
  } catch { Log "Vibepollo terminate_virtual failed: $_" }
}

# ---- the link ------------------------------------------------------------------------------
function Get-Key { $f = Join-Path $Data 'link.key'; if (Test-Path $f) { [Text.Encoding]::ASCII.GetBytes((Get-Content $f -Raw).Trim()) } else { $null } }
function Ask-Frame($key) {
  $nonce = New-Object byte[] 16; [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($nonce)
  $hex = [BitConverter]::ToString($nonce).Replace('-', '').ToLower()
  foreach ($addr in $Frame) {
    $u = New-Object Net.Sockets.UdpClient
    try {
      $u.Client.ReceiveTimeout = 400
      $msg = [Text.Encoding]::ASCII.GetBytes("FTRD1 PING $hex")
      [void]$u.Send($msg, $msg.Length, $addr, $Port)
      $ep = New-Object Net.IPEndPoint([Net.IPAddress]::Any, 0)
      $reply = [Text.Encoding]::UTF8.GetString($u.Receive([ref]$ep))
    } catch { continue } finally { $u.Close() }
    $nl = $reply.LastIndexOf("`n")
    if (-not $reply.StartsWith('FTRD1 ') -or $nl -lt 0) { continue }
    $body = $reply.Substring(6, $nl - 6); $mac = $reply.Substring($nl + 1).Trim()
    $h = New-Object Security.Cryptography.HMACSHA256 (, $key)
    $want = [BitConverter]::ToString($h.ComputeHash([byte[]]($nonce + [Text.Encoding]::UTF8.GetBytes($body)))).Replace('-', '').ToLower()
    if ($want -ne $mac) { Log "bad signature from $addr (key mismatch?)"; continue }
    $j = $body | ConvertFrom-Json
    return [pscustomobject]@{ From = $addr; Monitors = @($j.monitors) }
  }
  $null
}

# ---- commands ------------------------------------------------------------------------------
if ($Setup) {
  $kf = Join-Path $Data 'link.key'
  if (-not (Test-Path $kf)) {
    $k = New-Object byte[] 32; [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($k)
    Set-Content -Path $kf -Value ([BitConverter]::ToString($k).Replace('-', '').ToLower()) -NoNewline
    Log "link key made: $kf (copy it to the Frame: ~/.config/frametop-remote-display/link.key)"
  } else { Log "link key exists: $kf" }
  Save-Baseline
  exit 0
}
if ($SaveBaseline) { Save-Baseline; exit 0 }
if ($Restore) { Restore-Physical 'restore (manual)' $null; Remove-Item $ArmedFile -ErrorAction SilentlyContinue; exit 0 }
if ($Status) {
  "displays: " + (Describe (Outputs))
  $b = Get-Baseline; "baseline: " + $(if ($b) { ($b | ForEach-Object { '{0}x{1}@{2} at {3},{4}{5}' -f $_.W, $_.H, $_.Hz, $_.X, $_.Y, $(if ($_.Primary) { ' P' } else { '' }) }) -join '; ' } else { 'none' })
  "control mode: " + ($Control -or (Test-Path (Join-Path $Data 'control.on'))); "armed (physical off): " + (Test-Path $ArmedFile)
  $key = Get-Key; if (-not $key) { "no link key (run -Setup)"; exit 0 }
  $a = Ask-Frame $key; if ($a) { "Frame ($($a.From)): " + (ConvertTo-Json -InputObject $a.Monitors -Depth 3 -Compress) } else { "Frame: no answer" }
  exit 0
}
if ($Guard) {
  # Watches the agent; if it dies while the physical monitors are off, gives them back.
  while ($true) {
    Start-Sleep -Seconds 1
    if (-not (Get-Process -Id $Guard -ErrorAction SilentlyContinue)) {
      if (Test-Path $ArmedFile) { Log 'guard: the agent died with the physical monitors off'; Restore-Physical 'restore (guard)' $null; Remove-Item $ArmedFile -ErrorAction SilentlyContinue }
      exit 0
    }
  }
}
if (-not $Run) { Get-Help $MyInvocation.MyCommand.Path; exit 0 }

# ---- the agent -------------------------------------------------------------------------------
$me = (Get-Process -Id $PID)
Get-CimInstance Win32_Process | Where-Object { $_.ProcessId -ne $PID -and $_.Name -eq 'powershell.exe' -and $_.CommandLine -like '*ftrd-host.ps1*-Run*' } |
  ForEach-Object { Log "stopping an older agent ($($_.ProcessId))"; Stop-Process -Id $_.ProcessId -Force }
Start-Process -WindowStyle Hidden -FilePath "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $MyInvocation.MyCommand.Path, '-Guard', $PID)
$key = Get-Key
if (-not $key) { Log 'no link key: run ftrd-host.ps1 -Setup'; }
if (Test-Path $ArmedFile) { Log 'armed at start (a previous run died?): restoring'; Restore-Physical 'restore (startup)' $null; Remove-Item $ArmedFile -ErrorAction SilentlyContinue }
Log ("agent running; frame " + ($Frame -join ',') + " port $Port; timeout $TimeoutSeconds s")
$lastAnswer = Get-Date '2000-01-01'; $active = $false; $lastMons = @(); $lastFix = Get-Date '2000-01-01'
$seen = ''; $since = Get-Date
while ($true) {
  Start-Sleep -Milliseconds 1000
  $control = $Control -or (Test-Path (Join-Path $Data 'control.on'))
  $a = if ($key) { Ask-Frame $key } else { $null }
  if ($a) { $lastAnswer = Get-Date; $lastMons = @($a.Monitors) }
  $live = $a -and $lastMons.Count -gt 0
  $stale = ((Get-Date) - $lastAnswer).TotalSeconds -gt $TimeoutSeconds
  if (-not $live -and ($stale -or ($a -and $lastMons.Count -eq 0))) {
    if ($active) {
      Log ($(if ($stale) { "Frame silent for $TimeoutSeconds s" } else { 'Frame reports no monitors' }) + ': giving the PC its monitors back')
      Restore-Physical 'restore (Frame gone)' $null
      Remove-Item $ArmedFile -ErrorAction SilentlyContinue
      if ($stale) { Terminate-Virtual }
      $active = $false
    }
    $lastMons = @()
  } elseif ($live -and -not $active) { Log ("Frame shows " + $lastMons.Count + " monitor(s)"); $active = $true }

  # What the displays should look like now; act once it's been wrong and stable for 3 s.
  $os = Outputs
  $d = Describe $os
  if ($d -ne $seen) { $seen = $d; $since = Get-Date; continue }
  if (((Get-Date) - $since).TotalSeconds -lt 3 -or ((Get-Date) - $lastFix).TotalSeconds -lt 8) { continue }
  if ($active -and $control) {
    $plan = Plan-Virtual $lastMons $os 0 $true
    if (-not $plan) { continue }  # the virtual monitors aren't there yet
    $physOn = @($os | Where-Object { $_.Attached -and -not $_.Virtual })
    if ($physOn -or -not (Plan-Matches $plan $os)) {
      $lastFix = Get-Date
      New-Item -ItemType File -Force -Path $ArmedFile | Out-Null
      $entries = @($plan) + @($physOn | ForEach-Object { @{ Name = $_.Name; Fields = ($DM_POSITION -bor $DM_W -bor $DM_H); X = 0; Y = 0; W = 0; H = 0; Primary = $false } })
      [void](Apply-Batch $entries 'control: virtual monitors as on the Frame, physical off')
    }
  } else {
    if (Test-Path $ArmedFile) { $lastFix = Get-Date; Restore-Physical 'restore (control off)' $null; Remove-Item $ArmedFile -ErrorAction SilentlyContinue; continue }
    $b = Get-Baseline
    $right = if ($b) { ($b | ForEach-Object { $_.X + $_.W } | Measure-Object -Maximum).Maximum } else { 0 }
    $plan = if ($active) { Plan-Virtual $lastMons $os $right $false } else { @() }
    if (-not (Physical-Matches $os) -or ($plan -and -not (Plan-Matches $plan $os))) {
      $lastFix = Get-Date
      Restore-Physical $(if ($active) { 'observe: physical as the baseline, virtual monitors as on the Frame' } else { 'physical layout back to the baseline' }) $plan
    }
  }
}

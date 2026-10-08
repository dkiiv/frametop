<#
ftrd-host.ps1: the PC's half of the Frame link (see README.md next to it).

Keeps the PC's display layout the way you want it while the Steam Frame shows virtual monitors
(Vibepollo "Remote Monitor" streams):
  - the physical monitors stay on, at the saved baseline layout (Vibepollo 2.0.0 shuffles them
    on every virtual monitor start/stop);
  - the virtual monitors always sit right of the physical ones, arranged the way their panels
    sit around you in the Frame (left of / right of / above each other), so dragging windows
    between them works as it looks. The panel positions come from ftrd-presence on the Frame
    (asked every second). A new arrangement is taken once the panels have stood still for 4 s
    and only when clear-cut (8 degree deadzone); Windows is changed only when its displays have
    been settled for 5 s and no monitor is (re)starting, and only for what differs;
  - optionally removes a virtual monitor Vibepollo left behind (Frame says "no monitors" for
    30 s), with a Vibepollo API token in vibepollo.token.

Usage (PowerShell 5.1, as the logged-in user; no admin needed):
  ftrd-host.ps1 -Setup            make the link key and save the current physical layout as the baseline
  ftrd-host.ps1 -SaveBaseline     save the current physical layout as the baseline
  ftrd-host.ps1 -Status           displays, baseline, the Frame's answer
  ftrd-host.ps1 -Restore          physical monitors back to the baseline now
  ftrd-host.ps1 -Run              the agent (Startup folder)
Data folder: %LOCALAPPDATA%\ftrd (link.key, baseline.json, vibepollo.token (optional), ftrd-host.log).
#>
param([switch]$Setup, [switch]$SaveBaseline, [switch]$Status, [switch]$Restore, [switch]$Run,
      [string[]]$Frame = @('10.35.78.1', '10.0.0.253'), [int]$Port = 47810,
      [string]$VibepolloConfig = 'C:\Program Files\Sunshine\config')
$ErrorActionPreference = 'Continue'
$Data = Join-Path $env:LOCALAPPDATA 'ftrd'
New-Item -ItemType Directory -Force -Path $Data | Out-Null
$LogFile = Join-Path $Data 'ftrd-host.log'
function Log($m) {
  $line = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' ' + $m
  Add-Content -Path $LogFile -Value $line
  if (-not $Run) { Write-Output $line }
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

# ---- baseline (the physical layout to keep) ------------------------------------------
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

# ---- arrangement ---------------------------------------------------------------------------
# The Frame's panels -> a layout spec: columns left to right, each top to bottom, of instance ids
# ("1|2" = 1 left of 2; "1,2" = 1 above 2). Azimuths are taken relative to the panels' mean
# direction, so turning your head changes nothing. Panels within 10 degrees of each other
# sideways and more than 8 degrees apart vertically share a column.
function Layout-Spec($mons) {
  $posed = @($mons | Where-Object { $null -ne $_.az })
  $rest = @($mons | Where-Object { $null -eq $_.az } | Sort-Object { [int]$_.instance })
  $gap = 1000
  if ($posed.Count) {
    $sx = 0; $sy = 0
    foreach ($m in $posed) { $r = [double]$m.az * [Math]::PI / 180; $sx += [Math]::Cos($r); $sy += [Math]::Sin($r) }
    $mean = [Math]::Atan2($sy, $sx) * 180 / [Math]::PI
    $items = @($posed | ForEach-Object { $d = (([double]$_.az - $mean + 540) % 360) - 180; [pscustomobject]@{ Id = [string]$_.instance; Az = $d; El = [double]$_.el } } | Sort-Object Az)
    $cols = @(); $cur = $null
    foreach ($it in $items) {
      $stack = $cur -and [Math]::Abs($it.Az - $cur.Az) -lt 10 -and ($cur.Items | Where-Object { [Math]::Abs($_.El - $it.El) -gt 8 })
      if ($stack) { $cur.Items += $it } else {
        if ($cur) { $gap = [Math]::Min($gap, $it.Az - $cur.Az) }
        $cur = [pscustomobject]@{ Az = $it.Az; Items = @($it) }; $cols += $cur
      }
    }
    $spec = @($cols | ForEach-Object { ($_.Items | Sort-Object El -Descending | ForEach-Object Id) -join ',' })
  } else { $spec = @() }
  $spec += @($rest | ForEach-Object { [string]$_.instance })
  [pscustomobject]@{ Spec = ($spec -join '|'); MinGap = $gap }
}

# Instance -> Windows display: certificate -> Vibepollo pairing -> the display it made for it.
function Resolve-Displays($mons, $os) {
  $map = @{}
  $virt = @($os | Where-Object { $_.Attached -and $_.Virtual })
  foreach ($m in $mons) {
    $uuid = if ($m.cert_sha256) { Cert-Uuid $m.cert_sha256 } else { $null }
    $name = if ($uuid) { Uuid-Display $uuid } else { $null }
    $o = if ($name) { $virt | Where-Object { $_.Name -eq $name } | Select-Object -First 1 } else { $null }
    if (-not $o) {  # fallback: the only virtual display of this size
      $same = @($virt | Where-Object { $_.W -eq $m.w -and $_.H -eq $m.h })
      if ($same.Count -eq 1) { $o = $same[0] }
    }
    if ($o) { $map[[string]$m.instance] = $o }
  }
  $map
}

# The changes needed: physical monitors not at the baseline, virtual ones not where the spec
# puts them (right of the physical ones, top-aligned). Only what differs; mode fields only for
# a physical monitor whose mode differs (a position change alone doesn't re-mode anything).
function Layout-Changes($os, $spec, $map) {
  $entries = @()
  $b = Get-Baseline
  if ($b) {
    foreach ($e in $b) {
      $o = Find-Output $os $e
      if (-not $o -or -not $o.Attached) { continue }  # never attach a monitor that's off
      $modeOff = $o.W -ne $e.W -or $o.H -ne $e.H -or ($e.Hz -and $o.Hz -lt $e.Hz)
      if ($modeOff -or $o.X -ne $e.X -or $o.Y -ne $e.Y -or ($e.Primary -and -not $o.Primary)) {
        $f = $DM_POSITION; if ($modeOff) { $f = $f -bor $DM_W -bor $DM_H -bor $DM_FREQ }
        $entries += @{ Name = $o.Name; Fields = $f; X = $e.X; Y = $e.Y; W = $e.W; H = $e.H; Hz = $e.Hz; Primary = [bool]$e.Primary }
      }
    }
    $right = ($b | ForEach-Object { $_.X + $_.W } | Measure-Object -Maximum).Maximum
  } else {
    $right = ($os | Where-Object { $_.Attached -and -not $_.Virtual } | ForEach-Object { $_.X + $_.W } | Measure-Object -Maximum).Maximum
  }
  if ($spec) {
    $x = $right
    foreach ($col in $spec.Split('|')) {
      $y = 0; $cw = 0
      foreach ($id in $col.Split(',')) {
        $o = $map[$id]
        if (-not $o) { continue }
        if ($o.X -ne $x -or $o.Y -ne $y) { $entries += @{ Name = $o.Name; Fields = $DM_POSITION; X = $x; Y = $y; Primary = $false } }
        $y += $o.H; $cw = [Math]::Max($cw, $o.W)
      }
      $x += $cw
    }
  }
  $entries
}

# Leftover virtual monitors (Vibepollo 2.0.0 sometimes keeps one after its stream ended): with an
# API token (vibepollo.token; scope POST /api/display/terminate_virtual), ask Vibepollo to remove
# them once the Frame has said "no monitors" for 30 s.
function Terminate-Virtual {
  $tf = Join-Path $Data 'vibepollo.token'
  if (-not (Test-Path $tf)) { Log 'leftover virtual monitor; no vibepollo.token, so left alone (stream.sh cleanup on the Frame clears it)'; return }
  try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    [Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }  # localhost, self-signed
    $r = Invoke-RestMethod -Method Post -Uri 'https://localhost:47990/api/display/terminate_virtual' -ContentType 'application/json' `
      -Body '{}' -Headers @{ Authorization = 'Bearer ' + (Get-Content $tf -Raw).Trim() } -TimeoutSec 20
    Log ('leftover virtual monitor: Vibepollo terminate_virtual: ' + (ConvertTo-Json -InputObject $r -Compress))
  } catch { Log "leftover virtual monitor: Vibepollo terminate_virtual failed: $_" }
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
if ($Restore) { Restore-Physical 'restore (manual)' $null; exit 0 }
if ($Status) {
  "displays: " + (Describe (Outputs))
  $b = Get-Baseline; "baseline: " + $(if ($b) { ($b | ForEach-Object { '{0}x{1}@{2} at {3},{4}{5}' -f $_.W, $_.H, $_.Hz, $_.X, $_.Y, $(if ($_.Primary) { ' P' } else { '' }) }) -join '; ' } else { 'none' })
  $key = Get-Key; if (-not $key) { "no link key (run -Setup)"; exit 0 }
  $a = Ask-Frame $key; if ($a) { "Frame ($($a.From)): " + (ConvertTo-Json -InputObject $a.Monitors -Depth 3 -Compress) } else { "Frame: no answer (no monitor open there, or asleep)" }
  exit 0
}
if (-not $Run) { Get-Help $MyInvocation.MyCommand.Path; exit 0 }

# ---- the agent -------------------------------------------------------------------------------
Get-CimInstance Win32_Process | Where-Object { $_.ProcessId -ne $PID -and $_.Name -eq 'powershell.exe' -and $_.CommandLine -like '*ftrd-host.ps1*-Run*' } |
  ForEach-Object { Log "stopping an older agent ($($_.ProcessId))"; Stop-Process -Id $_.ProcessId -Force }
$key = Get-Key
if (-not $key) { Log 'no link key: run ftrd-host.ps1 -Setup (only the physical layout is kept until then)' }
Log ("agent running; frame " + ($Frame -join ',') + " port $Port")
$mons = @(); $known = $false        # last answer's monitors; whether we've had one
$accepted = ''; $cand = ''; $candSince = Get-Date
$busyUntil = Get-Date '2000-01-01'; $lastFix = Get-Date '2000-01-01'
$seen = ''; $since = Get-Date; $noneSince = $null; $orphanDone = $false
while ($true) {
  Start-Sleep -Milliseconds 1000
  $now = Get-Date
  if ($key) {
    $a = Ask-Frame $key
    if ($a) {
      $mons = @($a.Monitors); $known = $true
      if ($mons | Where-Object { $_.busy }) { $busyUntil = $now.AddSeconds(6) }  # a monitor is (re)starting
      $ls = Layout-Spec $mons
      if ($ls.Spec -ne $cand) { $cand = $ls.Spec; $candSince = $now }
      # Take a new arrangement once the panels have stopped moving (4 s), and only when it's
      # clear-cut: neighbouring columns at least 8 degrees apart.
      if ($cand -ne $accepted -and ($now - $candSince).TotalSeconds -ge 4 -and ($ls.MinGap -ge 8 -or -not $accepted -or $accepted.Split('|,').Count -ne $cand.Split('|,').Count)) {
        Log ("Frame arrangement: " + $(if ($cand) { $cand.Replace('|', ' | ') } else { 'no monitors' }) + $(if ($accepted) { " (was $($accepted.Replace('|', ' | ')))" } else { '' }))
        $accepted = $cand
      }
    }
  }
  if ($known -and $mons.Count -eq 0) { if (-not $noneSince) { $noneSince = $now } } else { $noneSince = $null; $orphanDone = $false }

  # Act only on settled displays: unchanged for 5 s, no monitor (re)starting, 8 s since our last change.
  $os = Outputs
  $d = Describe $os
  if ($d -ne $seen) { $seen = $d; $since = $now; continue }
  if (($now - $since).TotalSeconds -lt 5 -or $now -lt $busyUntil -or ($now - $lastFix).TotalSeconds -lt 8) { continue }
  if ($noneSince -and -not $orphanDone -and ($now - $noneSince).TotalSeconds -ge 30 -and ($os | Where-Object { $_.Attached -and $_.Virtual })) {
    $orphanDone = $true; Terminate-Virtual; continue
  }
  $map = if ($mons.Count) { Resolve-Displays $mons $os } else { @{} }
  $changes = @(Layout-Changes $os $(if ($mons.Count) { $accepted } else { '' }) $map)
  if ($changes.Count) {
    $lastFix = $now
    [void](Apply-Batch $changes 'layout')
  }
}

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
  - pairs the Frame: a Frame being set up asks the PC (pairing request with its PIN), and the
    agent hands the PIN to Vibepollo and gives the device the permissions Remote PC needs
    (launch, mouse, keyboard). For 30 minutes after -Install (or -AllowPairing) without asking;
    otherwise it asks on screen;
  - removes a virtual monitor Vibepollo left behind (Frame says "no monitors" for 30 s).

Usage (Windows PowerShell 5.1, as the logged-in user):
  ftrd-host.ps1 -Install          everything for Remote PC on this PC: Vibepollo (downloaded and
                                  installed if missing; one UAC prompt), its login and an API token
                                  for this helper, the current physical layout saved; runs now and
                                  at every logon; pairing open for 30 minutes
  ftrd-host.ps1 -AllowPairing     let a Frame pair without asking, for the next 15 minutes
  ftrd-host.ps1 -ShowLogin        the Vibepollo web page login -Install made
  ftrd-host.ps1 -Uninstall        remove this helper and its data; asks whether to remove Vibepollo
                                  too (-RemoveVibepollo: without asking; one UAC prompt)
  ftrd-host.ps1 -SaveBaseline     save the current physical layout as the one to keep
  ftrd-host.ps1 -Status           displays, baseline, the Frame's answer
  ftrd-host.ps1 -Restore          physical monitors back to the baseline now
  ftrd-host.ps1 -Run              the agent (Startup folder)
Data folder: %LOCALAPPDATA%\ftrd (ftrd-host.ps1, baseline.json, frame.txt, vibepollo.token.dpapi and
vibepollo-login.dpapi (encrypted for this Windows user), pair-until, ftrd-host.log). The Frame's
answers are signed with its Vibepollo pairing key; nothing to copy.
#>
param([switch]$Install, [switch]$AllowPairing, [switch]$ShowLogin, [switch]$Uninstall, [switch]$RemoveVibepollo, [switch]$SaveBaseline, [switch]$Status, [switch]$Restore, [switch]$Run,
      [string[]]$Frame = @(), [int]$Port = 47810,
      [string]$VibepolloConfig = '')
$ErrorActionPreference = 'Continue'
$Data = Join-Path $env:LOCALAPPDATA 'ftrd'
New-Item -ItemType Directory -Force -Path $Data | Out-Null
$LogFile = Join-Path $Data 'ftrd-host.log'
# Where Vibepollo lives: a fresh install goes to Program Files\Apollo, one over Sunshine stays in
# Program Files\Sunshine. From its uninstall entry, else its service.
function Vibepollo-Dir {
  $keys = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
  foreach ($e in Get-ItemProperty $keys -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -eq 'Vibepollo' -and $_.InstallLocation }) {
    if (Test-Path (Join-Path $e.InstallLocation 'sunshine.exe')) { return $e.InstallLocation.TrimEnd('\') }
  }
  $img = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\ApolloService' -ErrorAction SilentlyContinue).ImagePath
  if ($img) {
    $exe = ($img -replace '^"([^"]+)".*', '$1') -replace '^(\S+\.exe).*', '$1'
    $d = Split-Path $exe
    if (Test-Path (Join-Path $d 'sunshine.exe')) { return $d }
    if (Test-Path (Join-Path (Split-Path $d) 'sunshine.exe')) { return (Split-Path $d) }
  }
  foreach ($d in 'C:\Program Files\Apollo', 'C:\Program Files\Sunshine') { if (Test-Path (Join-Path $d 'sunshine.exe')) { return $d } }
  $null
}
if (-not $VibepolloConfig) { $vd = Vibepollo-Dir; $VibepolloConfig = if ($vd) { Join-Path $vd 'config' } else { 'C:\Program Files\Apollo\config' } }
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
# (ConvertFrom-Json in PowerShell 5.1 outputs a JSON array as one object; ForEach unrolls it.)
function Get-Baseline { if (Test-Path $BaselineFile) { Get-Content $BaselineFile -Raw | ConvertFrom-Json | ForEach-Object { $_ } } else { $null } }
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
function Physical-Matches($os) { @(Layout-Changes $os '' @{}).Count -eq 0 }

# ---- which Windows display shows which Frame monitor --------------------------------------
# The Frame sends its client certificate's SHA-256; Vibepollo's state file has each pairing's
# certificate and id, and its log names the display it made for that id.
$script:certMap = @{}; $script:certObj = @{}; $script:certMapAt = Get-Date '2000-01-01'
function Load-Pairings {
  if (((Get-Date) - $script:certMapAt).TotalSeconds -lt 60) { return }
  $script:certMap = @{}; $script:certObj = @{}; $script:certMapAt = Get-Date
  try {
    $st = Get-Content (Join-Path $VibepolloConfig 'sunshine_state.json') -Raw | ConvertFrom-Json
    foreach ($d in $st.root.named_devices) {
      $body = ($d.cert -split "`n" | Where-Object { $_ -and $_ -notmatch '-----' }) -join ''
      $der = [Convert]::FromBase64String($body.Trim())
      $h = [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($der)).Replace('-', '').ToLower()
      $script:certMap[$h] = $d.uuid
      $script:certObj[$h] = New-Object Security.Cryptography.X509Certificates.X509Certificate2 (, $der)
    }
  } catch { Log "can't read Vibepollo's pairings: $_" }
}
function Cert-Uuid($sha) { Load-Pairings; $script:certMap[$sha] }
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
# puts them (right of the physical ones, top-aligned). Positions are relative: Windows puts the
# primary display at 0,0, so making a virtual monitor primary shifts everything, and that's fine.
# Primary: a virtual one the user picked stays primary; otherwise the baseline's physical one.
# Only what differs; mode fields only for a physical monitor whose mode differs.
function Layout-Changes($os, $spec, $map) {
  $b = @(Get-Baseline)
  $tgt = @{}; $phys = @{}; $modeOff = @{}
  foreach ($e in $b) {
    if (-not $e) { continue }
    $o = Find-Output $os $e
    if (-not $o -or -not $o.Attached) { continue }  # never attach a monitor that's off
    $tgt[$o.Name] = @($e.X, $e.Y); $phys[$o.Name] = $e
    $modeOff[$o.Name] = $o.W -ne $e.W -or $o.H -ne $e.H -or ($e.Hz -and $o.Hz -lt $e.Hz)
  }
  $right = if ($phys.Count) { ($phys.Values | ForEach-Object { $_.X + $_.W } | Measure-Object -Maximum).Maximum }
           else { ($os | Where-Object { $_.Attached -and -not $_.Virtual } | ForEach-Object { $_.X + $_.W } | Measure-Object -Maximum).Maximum }
  if ($spec) {
    $x = $right
    foreach ($col in $spec.Split('|')) {
      $y = 0; $cw = 0
      foreach ($id in $col.Split(',')) {
        $o = $map[$id]
        if (-not $o) { continue }
        $tgt[$o.Name] = @($x, $y)
        $y += $o.H; $cw = [Math]::Max($cw, $o.W)
      }
      $x += $cw
    }
  }
  # Whose position is 0,0: the current primary if it's virtual (user's choice) and placed, else
  # the baseline's primary.
  $cur = $os | Where-Object { $_.Attached -and $_.Primary } | Select-Object -First 1
  $setPrimary = $null
  # Remember which Frame monitor the user made primary, so it stays primary when Vibepollo
  # re-creates its display (resize, after a VR game). Same display no longer primary: the user
  # switched back. (The preference lasts while the agent runs.)
  $inst = @($map.Keys | Where-Object { $map[$_].Name -eq $cur.Name })
  if ($cur -and $cur.Virtual -and $inst.Count) { $script:primaryInst = $inst[0]; $script:primaryName = $cur.Name }
  elseif ($script:primaryInst -and $map.ContainsKey($script:primaryInst)) {
    $pm = $map[$script:primaryInst]
    if ($pm.Name -eq $script:primaryName) { $script:primaryInst = $null }
    else { $script:primaryName = $pm.Name; $setPrimary = $pm.Name; $cur = $pm }
  }
  if ($setPrimary) { $anchor = $setPrimary }
  elseif ($cur -and $cur.Virtual) {
    if (-not $tgt.ContainsKey($cur.Name)) { return @() }  # a virtual primary we can't place yet: wait
    $anchor = $cur.Name
  } else {
    $bp = $phys.Keys | Where-Object { $phys[$_].Primary } | Select-Object -First 1
    $anchor = if ($bp) { $bp } elseif ($cur) { $cur.Name } else { $null }
    if (-not $anchor -or -not $tgt.ContainsKey($anchor)) { return @() }
    if (-not $cur -or $cur.Name -ne $anchor) { $setPrimary = $anchor }
  }
  $dx = - $tgt[$anchor][0]; $dy = - $tgt[$anchor][1]
  $entries = @()
  foreach ($o in @($os | Where-Object { $_.Attached -and $tgt.ContainsKey($_.Name) })) {
    $x = $tgt[$o.Name][0] + $dx; $y = $tgt[$o.Name][1] + $dy
    $mo = $phys.ContainsKey($o.Name) -and $modeOff[$o.Name]
    if ($mo -or $o.X -ne $x -or $o.Y -ne $y -or $o.Name -eq $setPrimary) {
      $f = $DM_POSITION; $e = $phys[$o.Name]
      if ($mo) { $f = $f -bor $DM_W -bor $DM_H -bor $DM_FREQ }
      $entries += @{ Name = $o.Name; Fields = $f; X = $x; Y = $y; W = $e.W; H = $e.H; Hz = $e.Hz; Primary = ($o.Name -eq $setPrimary) }
    }
  }
  $entries
}

# ---- Vibepollo's API -----------------------------------------------------------------------
$VpUrl = 'https://localhost:47990'
$VpSetupUrl = 'https://github.com/Nonary/Vibepollo/releases/download/2.0.0/VibepolloSetup-v2.0.0.exe'
$VpSetupSha256 = '7b3500ec0c774644ce5a435a48f61c046c48494d0f18b67afa0b3561931794b7'
# Remote PC needs: list + view + launch apps, mouse, keyboard, controller (Vibepollo gives them
# only to the first device it pairs).
$PermWanted = [uint32](0x01000000 -bor 0x02000000 -bor 0x04000000 -bor 0x800 -bor 0x1000 -bor 0x100)
function Save-Secret($name, $plain) {
  ConvertTo-SecureString $plain -AsPlainText -Force | ConvertFrom-SecureString | Set-Content (Join-Path $Data $name)
}
function Read-Secret($name) {
  $f = Join-Path $Data $name
  if (-not (Test-Path $f)) { return $null }
  try {
    $ss = (Get-Content $f -Raw).Trim() | ConvertTo-SecureString
    [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($ss))
  } catch { $null }
}
# Vibepollo's web API has a self-signed certificate: accept that for localhost only. Compiled,
# because a PowerShell scriptblock callback fails when .NET calls it on another thread.
Add-Type @'
using System.Net;
public static class FtrdTls {
  public static void TrustLoopback() {
    ServicePointManager.ServerCertificateValidationCallback = (sender, cert, chain, errors) => {
      var req = sender as HttpWebRequest;
      return errors == System.Net.Security.SslPolicyErrors.None || (req != null && req.RequestUri.IsLoopback);
    };
  }
}
'@
function Vp($method, $path, $body, $auth) {
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  [FtrdTls]::TrustLoopback()
  $p = @{ Method = $method; Uri = "$VpUrl$path"; TimeoutSec = 20; UseBasicParsing = $true }
  if ($auth) { $p.Headers = @{ Authorization = $auth } }
  if ($null -ne $body) { $p.ContentType = 'application/json'; $p.Body = (ConvertTo-Json -InputObject $body -Depth 10 -Compress) }
  Invoke-RestMethod @p
}
function Vp-Auth {
  $t = Read-Secret 'vibepollo.token.dpapi'
  if (-not $t -and (Test-Path (Join-Path $Data 'vibepollo.token'))) { $t = (Get-Content (Join-Path $Data 'vibepollo.token') -Raw).Trim() }
  if ($t) { 'Bearer ' + $t } else { $null }
}

# Leftover virtual monitors (Vibepollo 2.0.0 sometimes keeps one after its stream ended): ask
# Vibepollo to remove them once the Frame has said "no monitors" for 30 s.
# Pairing. A Frame being set up answers our pings with FTRD2-PAIR {name, pin}; that's the PIN its
# pairing request to Vibepollo waits for. Approved without asking while pair-until is in the
# future (-Install, -AllowPairing), else after a Yes on screen. Then the device gets $PermWanted.
$script:pairSeen = @{}; $script:permTodo = @{}
function Pairing-Open {
  $f = Join-Path $Data 'pair-until'
  if (-not (Test-Path $f)) { return $false }
  try { return [datetime]::FromFileTimeUtc([int64](Get-Content $f -Raw).Trim()) -gt [datetime]::UtcNow } catch { return $false }
}
function Open-Pairing($minutes) { Set-Content (Join-Path $Data 'pair-until') ([datetime]::UtcNow.AddMinutes($minutes).ToFileTimeUtc()) }
function Handle-Pair($req, $from) {
  if (-not $req.pin -or $req.pin -notmatch '^\d{4}$' -or -not $req.name) { return }
  $key = "$($req.pin)/$($req.name)"
  if ($script:pairSeen.ContainsKey($key)) { return }
  $script:pairSeen[$key] = Get-Date
  $auth = Vp-Auth
  if (-not $auth) { Log "pairing request from $from ('$($req.name)'): no Vibepollo token here, so the PIN goes in by hand"; return }
  if (-not (Pairing-Open)) {
    Add-Type -AssemblyName System.Windows.Forms
    $ans = [Windows.Forms.MessageBox]::Show("A Steam Frame at $from wants to pair with this PC as `"$($req.name)`" (Remote PC).`n`nThe headset shows PIN $($req.pin). Allow it?",
      'Remote PC', 'YesNo', 'Question', 'Button2', 'DefaultDesktopOnly')
    if ($ans -ne 'Yes') { Log "pairing request from $from ('$($req.name)') declined"; return }
  }
  try { $r = Vp Post '/api/pin' @{ pin = [string]$req.pin; name = [string]$req.name } $auth }
  catch { Log "pairing '$($req.name)': Vibepollo refused the PIN: $_"; $script:pairSeen.Remove($key); return }
  if (-not $r.status) { Log "pairing '$($req.name)': no pairing request waiting for PIN $($req.pin) yet; will retry"; $script:pairSeen.Remove($key); return }
  Log "paired '$($req.name)' ($from)"
  $script:permTodo[[string]$req.name] = (Get-Date).AddSeconds(60)
}
# Every "Frame monitor N" device gets $PermWanted: just after pairing, and once a minute (a
# re-paired Frame may be named "Frame monitor 1 (2)" by Vibepollo, next to its old pairing).
$script:permCheck = Get-Date '2000-01-01'; $script:primaryInst = $null; $script:primaryName = $null
function Fix-Permissions {
  if (-not $script:permTodo.Count -and ((Get-Date) - $script:permCheck).TotalSeconds -lt 60) { return }
  $script:permCheck = Get-Date
  $auth = Vp-Auth
  if (-not $auth) { $script:permTodo.Clear(); return }
  try { $list = Vp Get '/api/clients/list' $null $auth } catch { return }
  foreach ($c in @($list.named_certs | Where-Object { $_.name -match '^Frame monitor \d+( \(\d+\))?$' })) {
    $want = [uint32]$c.perm -bor $PermWanted
    if ($want -eq [uint32]$c.perm) { continue }
    $body = @{}
    foreach ($pr in $c.PSObject.Properties) { if ($pr.Name -ne 'last_seen') { $body[$pr.Name] = $pr.Value } }
    $body.perm = $want
    try { [void](Vp Post '/api/clients/update' $body $auth); Log "permissions for '$($c.name)': launch, mouse, keyboard" }
    catch { Log "permissions for '$($c.name)' failed: $_" }
  }
  foreach ($k in @($script:permTodo.Keys)) { if ((Get-Date) -gt $script:permTodo[$k]) { $script:permTodo.Remove($k) } }
}

# ---- the link ------------------------------------------------------------------------------
# Ask the Frame (ftrd-presence) what it shows. Its answer is signed with its Vibepollo pairing
# key, checked against the certificate Vibepollo trusts. The Frame is found by broadcasting on
# the PC's networks (every 10 s while unknown) and remembered (frame.txt); -Frame overrides.
$FrameFile = Join-Path $Data 'frame.txt'
$script:lastBroadcast = Get-Date '2000-01-01'
function Broadcast-Targets {
  try {
    Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop | Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' -and $_.PrefixLength -lt 32 } | ForEach-Object {
      $ip = [Net.IPAddress]::Parse($_.IPAddress).GetAddressBytes(); [Array]::Reverse($ip)
      $n = [BitConverter]::ToUInt32($ip, 0); $mask = [uint32]([Math]::Pow(2, 32) - [Math]::Pow(2, 32 - $_.PrefixLength))
      $bc = [BitConverter]::GetBytes([uint32](($n -band $mask) -bor (-bnot $mask -band 0xFFFFFFFF))); [Array]::Reverse($bc)
      ([Net.IPAddress]$bc).ToString()
    }
  } catch { '255.255.255.255' }
}
function Ask-Frame {
  $nonce = New-Object byte[] 16; [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($nonce)
  $msg = [Text.Encoding]::ASCII.GetBytes('FTRD2 PING ' + [BitConverter]::ToString($nonce).Replace('-', '').ToLower() + $(if ($script:leftover) { ' leftover' } else { '' }))
  $targets = @($Frame)
  if (-not $targets.Count) {
    if (Test-Path $FrameFile) { $targets = @((Get-Content $FrameFile -Raw).Trim()) }
    if (-not $targets.Count -or ((Get-Date) - $script:lastFound).TotalSeconds -gt 10) {
      if (((Get-Date) - $script:lastBroadcast).TotalSeconds -ge 10) { $script:lastBroadcast = Get-Date; $targets += @(Broadcast-Targets) }
    }
  }
  if (-not $targets.Count) { return $null }
  Load-Pairings
  $u = New-Object Net.Sockets.UdpClient
  try {
    $u.EnableBroadcast = $true; $u.Client.ReceiveTimeout = 400
    foreach ($t in $targets) { try { [void]$u.Send($msg, $msg.Length, $t, $Port) } catch {} }
    $until = (Get-Date).AddMilliseconds(500)
    while ((Get-Date) -lt $until) {
      $ep = New-Object Net.IPEndPoint([Net.IPAddress]::Any, 0)
      try { $reply = [Text.Encoding]::UTF8.GetString($u.Receive([ref]$ep)) } catch { break }
      if ($reply.StartsWith('FTRD2-PAIR ')) {
        try { Handle-Pair ($reply.Substring(11) | ConvertFrom-Json) $ep.Address.ToString() } catch { Log "pairing request: $_" }
        continue
      }
      $nl = $reply.LastIndexOf("`n")
      if (-not $reply.StartsWith('FTRD2 ') -or $nl -lt 0) { continue }
      $body = $reply.Substring(6, $nl - 6); $tail = $reply.Substring($nl + 1).Trim().Split(' ')
      if ($tail.Count -ne 2) { continue }
      $cert = $script:certObj[$tail[0]]
      if (-not $cert) {
        if (((Get-Date) - $script:unpairedLogged).TotalMinutes -ge 10) { $script:unpairedLogged = Get-Date; Log "answer from $($ep.Address) signed by a device Vibepollo hasn't paired (yet); ignored" }
        continue
      }
      $sig = New-Object byte[] ($tail[1].Length / 2)
      for ($i = 0; $i -lt $sig.Length; $i++) { $sig[$i] = [Convert]::ToByte($tail[1].Substring(2 * $i, 2), 16) }
      $ok = $false
      try { $ok = $cert.PublicKey.Key.VerifyData([byte[]]($nonce + [Text.Encoding]::UTF8.GetBytes($body)), 'SHA256', $sig) } catch {}
      if (-not $ok) { Log "bad signature from $($ep.Address); ignored"; continue }
      $from = $ep.Address.ToString()
      if (-not $Frame.Count -and (-not (Test-Path $FrameFile) -or (Get-Content $FrameFile -Raw).Trim() -ne $from)) {
        Set-Content -Path $FrameFile -Value $from; Log "Frame found at $from"
      }
      $script:lastFound = Get-Date
      $j = $body | ConvertFrom-Json
      return [pscustomobject]@{ From = $from; Monitors = @($j.monitors) }
    }
  } finally { $u.Close() }
  $null
}
$script:lastFound = Get-Date '2000-01-01'; $script:unpairedLogged = Get-Date '2000-01-01'

# ---- commands ------------------------------------------------------------------------------
if ($Install) {
  $dest = Join-Path $Data 'ftrd-host.ps1'
  if ($MyInvocation.MyCommand.Path -ne $dest) { Copy-Item -Force $MyInvocation.MyCommand.Path $dest }
  Write-Host "`n== Vibepollo (streams your PC's virtual monitors to the Frame)"
  if (-not (Get-Service ApolloService -ErrorAction SilentlyContinue)) {
    $exe = Join-Path $env:TEMP 'VibepolloSetup-v2.0.0.exe'
    Write-Host "downloading Vibepollo 2.0.0..."
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -UseBasicParsing $VpSetupUrl -OutFile $exe
    if ((Get-FileHash -Algorithm SHA256 $exe).Hash.ToLower() -ne $VpSetupSha256) { Remove-Item $exe; throw "the Vibepollo download doesn't match its checksum; not installing it" }
    Write-Host "installing it: click Yes in the Windows prompt (it installs a service and display drivers)..."
    $pr = Start-Process -FilePath $exe -ArgumentList '/quiet', '/norestart' -Verb RunAs -Wait -PassThru
    Log "Vibepollo setup exit code $($pr.ExitCode)"
    Remove-Item $exe -ErrorAction SilentlyContinue
  } else { Write-Host "already installed" }
  $up = $false
  for ($i = 0; $i -lt 60 -and -not $up; $i++) { try { [void](Invoke-WebRequest -UseBasicParsing -TimeoutSec 3 'http://localhost:47989/serverinfo'); $up = $true } catch { Start-Sleep 2 } }
  if (-not $up) { throw "Vibepollo isn't answering (service ApolloService). Check it's running, then run this again." }

  Write-Host "`n== Vibepollo login and an API token for this helper"
  $auth = Vp-Auth
  $ok = $false
  if ($auth) { try { [void](Vp Get '/api/clients/list' $null $auth); $ok = $true } catch {} }
  if (-not $ok) {
    $user = 'admin'
    $chars = [char[]]'abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789'
    $bytes = New-Object byte[] 16; [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    $pass = -join ($bytes | ForEach-Object { $chars[$_ % $chars.Length] })
    $fresh = $false
    try { $r = Vp Post '/api/password' @{ newUsername = $user; newPassword = $pass; confirmNewPassword = $pass } $null; $fresh = [bool]$r.status } catch {}
    $basic = $null
    if (-not $fresh) {
      Write-Host "Vibepollo already has a login. Enter it once (so this helper can make its own API token),"
      Write-Host "or press Cancel if you don't know it: then it's reset to a new one (one more Windows prompt)."
      $cred = $null
      try { $cred = Get-Credential -Message 'Your Vibepollo web page login (https://localhost:47990), or Cancel to reset it' } catch {}
      if ($cred) {
        $basic = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("$($cred.UserName):$($cred.GetNetworkCredential().Password)"))
        try { [void](Vp Get '/api/clients/list' $null $basic) } catch { Write-Host "That login didn't work; resetting it instead."; $basic = $null }
      }
      if (-not $basic) {
        $vd = Vibepollo-Dir
        if (-not $vd) { throw "can't find Vibepollo's folder to reset its login" }
        $reset = Join-Path $env:TEMP 'ftrd-reset-login.ps1'
        Set-Content $reset ("Stop-Service ApolloService -Force`n" +
          "Start-Process -Wait -WorkingDirectory '$vd' -FilePath '$vd\sunshine.exe' -ArgumentList '--creds', '$user', '$pass'`n" +
          "Start-Service ApolloService")
        Write-Host "resetting Vibepollo's login: click Yes in the Windows prompt..."
        [void](Start-Process powershell.exe -Verb RunAs -Wait -PassThru -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $reset)
        Remove-Item $reset -ErrorAction SilentlyContinue
        $up = $false
        for ($i = 0; $i -lt 30 -and -not $up; $i++) { try { [void](Invoke-WebRequest -UseBasicParsing -TimeoutSec 3 'http://localhost:47989/serverinfo'); $up = $true } catch { Start-Sleep 2 } }
        $fresh = $true
      }
    }
    if ($fresh) {
      Save-Secret 'vibepollo-login.dpapi' "$user`n$pass"
      Write-Host "Vibepollo's web page login (you rarely need it): user $user, password $pass"
      Write-Host "(-ShowLogin shows it again)"
      $basic = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("$user`:$pass"))
    }
    $scopes = @(@{ path = '/api/pin'; methods = @('POST') }, @{ path = '/api/clients/list'; methods = @('GET') },
                @{ path = '/api/clients/update'; methods = @('POST') }, @{ path = '/api/display/terminate_virtual'; methods = @('POST') })
    $t = Vp Post '/api/token' @{ scopes = $scopes } $basic
    if (-not $t.token) { throw "Vibepollo didn't make an API token: $(ConvertTo-Json -InputObject $t -Compress)" }
    Save-Secret 'vibepollo.token.dpapi' $t.token
    Remove-Item (Join-Path $Data 'vibepollo.token') -ErrorAction SilentlyContinue
    Write-Host "API token made (pairing, device permissions, leftover-monitor cleanup only)"
  } else { Write-Host "already set up" }

  Write-Host "`n== This helper"
  Save-Baseline
  $ps = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
  # Through conhost --headless: a console with no window. (powershell -WindowStyle Hidden
  # alone shows an empty window where Windows Terminal is the default console, as on Windows 11.)
  $conhost = Join-Path $env:SystemRoot 'System32\conhost.exe'
  $sc = (New-Object -ComObject WScript.Shell).CreateShortcut((Join-Path ([Environment]::GetFolderPath('Startup')) 'ftrd-host.lnk'))
  $sc.TargetPath = $conhost; $sc.WindowStyle = 7; $sc.Description = 'Remote PC: pairs the Steam Frame, keeps the display layout'
  $sc.Arguments = "--headless `"$ps`" -NoProfile -ExecutionPolicy Bypass -File `"$dest`" -Run"
  $sc.Save()
  Open-Pairing 30
  Start-Process -FilePath $conhost -ArgumentList "--headless `"$ps`" -NoProfile -ExecutionPolicy Bypass -File `"$dest`" -Run"
  # A short command for the rest (ftrd-host -Status, ...): a .cmd in WindowsApps, a folder
  # Windows keeps on every user's PATH.
  Set-Content (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\ftrd-host.cmd') -Encoding ASCII `
    "@powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"%LOCALAPPDATA%\ftrd\ftrd-host.ps1`" %*"
  Log "installed: $dest, started now and at every logon; pairing open for 30 minutes"
  Write-Host "`nThe PC is ready. In the headset: Steam button -> + -> Remote PC (within 30 minutes, it pairs"
  Write-Host "by itself; later, this PC asks before a new Frame pairs)."
  exit 0
}
if ($AllowPairing) { Open-Pairing 15; Log 'pairing open for 15 minutes'; exit 0 }
if ($ShowLogin) { $l = Read-Secret 'vibepollo-login.dpapi'; if ($l) { $u, $pw = $l -split "`n"; "Vibepollo web page (https://localhost:47990): user $u, password $pw" } else { 'no login saved here (it was made before this helper, or elsewhere)' }; exit 0 }
if ($Uninstall) {
  Remove-Item (Join-Path ([Environment]::GetFolderPath('Startup')) 'ftrd-host.lnk') -ErrorAction SilentlyContinue
  Remove-Item (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\ftrd-host.cmd') -ErrorAction SilentlyContinue
  Get-CimInstance Win32_Process | Where-Object { $_.ProcessId -ne $PID -and $_.Name -eq 'powershell.exe' -and $_.CommandLine -like '*ftrd-host.ps1*-Run*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
  Write-Host 'Remote PC helper stopped and removed from logon.'
  $rm = [bool]$RemoveVibepollo
  if (-not $rm -and (Get-Service ApolloService -ErrorAction SilentlyContinue)) {
    $rm = (Read-Host 'Remove Vibepollo too (with its pairings and settings)? [y/N]') -match '^[yY]'
  }
  if ($rm) {
    $script = Join-Path $env:TEMP 'ftrd-remove-vibepollo.ps1'
    Set-Content $script @'
$ErrorActionPreference = 'Continue'
Stop-Service ApolloService -Force -ErrorAction SilentlyContinue
$keys = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
foreach ($e in Get-ItemProperty $keys -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -eq 'Vibepollo' -and $_.UninstallString -match 'MsiExec' }) {
  $code = [regex]::Match($e.UninstallString, '\{[0-9A-Fa-f-]+\}').Value
  if ($code) { Start-Process msiexec.exe -ArgumentList '/x', $code, '/qn', '/norestart' -Wait }
}
foreach ($d in 'C:\Program Files\Apollo', 'C:\Program Files\Sunshine') {
  if (Test-Path "$d\uninstall.exe") { Start-Process "$d\uninstall.exe" -ArgumentList '/S', "_?=$d" -Wait }
}
foreach ($d in Get-PnpDevice -Class Display -ErrorAction SilentlyContinue | Where-Object { $_.FriendlyName -match 'SudoMaker|Sunshine Virtual' }) {
  $inf = (Get-PnpDeviceProperty -InstanceId $d.InstanceId -KeyName DEVPKEY_Device_DriverInfPath -ErrorAction SilentlyContinue).Data
  & pnputil /remove-device "$($d.InstanceId)" | Out-Null
  if ($inf -like 'oem*.inf') { & pnputil /delete-driver $inf /uninstall /force | Out-Null }
}
Remove-Item -Recurse -Force 'C:\Program Files\Apollo', 'C:\Program Files\Sunshine' -ErrorAction SilentlyContinue
'@
    Write-Host 'Removing Vibepollo: click Yes in the Windows prompt...'
    $pr = Start-Process powershell.exe -Verb RunAs -Wait -PassThru -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script
    Remove-Item $script -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force (Join-Path $env:APPDATA 'Sunshine') -ErrorAction SilentlyContinue
    if (Get-Service ApolloService -ErrorAction SilentlyContinue) { Write-Host 'Vibepollo is still installed (the prompt was declined?).' } else { Write-Host 'Vibepollo removed.' }
  }
  Set-Location $env:TEMP
  Remove-Item -Recurse -Force $Data -ErrorAction SilentlyContinue
  Write-Host "Removed $Data. Your monitors stay as they are."
  exit 0
}
if ($SaveBaseline) { Save-Baseline; exit 0 }
if ($Restore) { Restore-Physical 'restore (manual)' $null; exit 0 }
if ($Status) {
  "displays: " + (Describe (Outputs))
  $b = Get-Baseline; "baseline: " + $(if ($b) { ($b | ForEach-Object { '{0}x{1}@{2} at {3},{4}{5}' -f $_.W, $_.H, $_.Hz, $_.X, $_.Y, $(if ($_.Primary) { ' P' } else { '' }) }) -join '; ' } else { 'none' })
  "agent: " + $(if (Get-CimInstance Win32_Process | Where-Object { $_.Name -eq 'powershell.exe' -and $_.CommandLine -like '*ftrd-host.ps1*-Run*' }) { 'running' } else { 'not running' })
  $script:lastBroadcast = Get-Date '2000-01-01'; $script:lastFound = Get-Date '2000-01-01'
  $a = Ask-Frame; if ($a) { "Frame ($($a.From)): " + (ConvertTo-Json -InputObject $a.Monitors -Depth 3 -Compress) } else { "Frame: no answer (it answers only while Remote PC is open)" }
  exit 0
}
if (-not $Run) { Get-Help $MyInvocation.MyCommand.Path; exit 0 }

# ---- the agent -------------------------------------------------------------------------------
Get-CimInstance Win32_Process | Where-Object { $_.ProcessId -ne $PID -and $_.Name -eq 'powershell.exe' -and $_.CommandLine -like '*ftrd-host.ps1*-Run*' } |
  ForEach-Object { Log "stopping an older agent ($($_.ProcessId))"; Stop-Process -Id $_.ProcessId -Force }
if (-not (Get-Baseline)) { Save-Baseline }
Log ("agent running; Frame " + $(if ($Frame.Count) { $Frame -join ',' } else { 'found by broadcast' }) + ", port $Port")
$mons = @(); $known = $false        # last answer's monitors; whether we've had one
$accepted = ''; $cand = ''; $candSince = Get-Date
$busyUntil = Get-Date '2000-01-01'; $lastFix = Get-Date '2000-01-01'
$seen = ''; $since = Get-Date; $noneSince = $null; $orphanDone = $false; $script:leftover = $false
while ($true) {
  Start-Sleep -Milliseconds 1000
  $now = Get-Date
  if ($true) {
    $a = Ask-Frame
    if ($a) {
      $mons = @($a.Monitors); $known = $true
      if ($mons | Where-Object { $_.busy }) { $busyUntil = $now.AddSeconds(6) }  # a monitor is (re)starting
      $ls = Layout-Spec $mons
      # A monitor without a position (its panel's pose unknown for a moment): keep the accepted
      # arrangement if it has the same monitors, rather than falling back to the default order
      # (each change re-applies every display: all screens blank, a fullscreen game may not
      # come back).
      $ids = (@($mons | ForEach-Object { [string]$_.instance }) | Sort-Object) -join ' '
      $accIds = if ($accepted) { (@($accepted.Split('|,')) | Sort-Object) -join ' ' } else { '' }
      if (@($mons | Where-Object { $null -eq $_.az }).Count -and $accepted -and $ids -eq $accIds) { $ls = [pscustomobject]@{ Spec = $accepted; MinGap = 1000 } }
      if ($ls.Spec -ne $cand) { $cand = $ls.Spec; $candSince = $now }
      # Take a new arrangement once the panels have stopped moving (4 s), and only when it's
      # clear-cut: neighbouring columns at least 8 degrees apart.
      if ($cand -ne $accepted -and ($now - $candSince).TotalSeconds -ge 4 -and ($ls.MinGap -ge 8 -or -not $accepted -or $accepted.Split('|,').Count -ne $cand.Split('|,').Count)) {
        Log ("Frame arrangement: " + $(if ($cand) { $cand.Replace('|', ' | ') } else { 'no monitors' }) + $(if ($accepted) { " (was $($accepted.Replace('|', ' | ')))" } else { '' }))
        $accepted = $cand
      }
    }
  }
  Fix-Permissions
  if ($known -and $mons.Count -eq 0) { if (-not $noneSince) { $noneSince = $now } } else { $noneSince = $null; $orphanDone = $false }

  # Act only on settled displays: unchanged for 5 s, no monitor (re)starting, 8 s since our last change.
  $os = Outputs
  $d = Describe $os
  if ($d -ne $seen) { $seen = $d; $since = $now; continue }
  if (($now - $since).TotalSeconds -lt 5 -or $now -lt $busyUntil -or ($now - $lastFix).TotalSeconds -lt 8) { continue }
  # The Frame closed all its monitors but one is still attached here (Vibepollo 2.0.0 defers
  # the cleanup of a monitor closed while another was open, then forgets it): say so in the
  # pings, and the Frame (still answering for a while) releases each identity once.
  $script:leftover = $noneSince -and ($now - $noneSince).TotalSeconds -ge 3 -and ($os | Where-Object { $_.Attached -and $_.Virtual })
  if ($script:leftover -and -not $orphanDone) { $orphanDone = $true; Log 'leftover virtual monitor after the Frame closed all of them; asking the Frame to release it' }
  $map = if ($mons.Count) { Resolve-Displays $mons $os } else { @{} }
  $changes = @(Layout-Changes $os $(if ($mons.Count) { $accepted } else { '' }) $map)
  if ($changes.Count) {
    $lastFix = $now
    [void](Apply-Batch $changes 'layout')
  }
}

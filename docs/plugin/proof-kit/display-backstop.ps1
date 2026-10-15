# Lanai resize proof (2026-10-13): the sign-in backstop prototype.
# Worker (no switch): until the Looking Glass display's desktop matches the
# driver's ExtraMode (Lanai's last ask), switch it there; give up after
# -Seconds. Logs to C:\ProgramData\LanaiProof\display-backstop.log.
# -Install (admin): copy this file to C:\ProgramData\LanaiProof and register a
# logon task for the current user that runs it. -Remove (admin): undo both.
# A prototype for a test copy of Windows only. Remove it after use (-Remove)
# and never install it on a live Windows: a standard user can create the
# C:\ProgramData folder first and control the file the elevated task runs.
param([switch]$Install, [switch]$Remove, [int]$Seconds = 120)
$ErrorActionPreference = 'Stop'
$dir  = 'C:\ProgramData\LanaiProof'
$task = 'Lanai display backstop proof'

if ($Install) {
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  Copy-Item -Force $PSCommandPath "$dir\display-backstop.ps1"
  $u = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
  $a = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
    -Argument "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$dir\display-backstop.ps1`""
  $t = New-ScheduledTaskTrigger -AtLogOn -User $u
  $p = New-ScheduledTaskPrincipal -UserId $u -LogonType Interactive -RunLevel Highest
  $s = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::FromMinutes(5)) -MultipleInstances IgnoreNew
  Register-ScheduledTask -TaskName $task -Action $a -Trigger $t -Principal $p -Settings $s -Force | Out-Null
  "Installed: task '$task' runs $dir\display-backstop.ps1 at sign-in."
  return
}
if ($Remove) {
  Unregister-ScheduledTask -TaskName $task -Confirm:$false -ErrorAction SilentlyContinue
  Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue
  "Removed the task and $dir."
  return
}

# All struct handling stays in C#; PowerShell passes only strings and ints.
Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class LanaiDisp {
  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
  struct DISPLAY_DEVICE {
    public int cb;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string DeviceName;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceString;
    public int StateFlags;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceID;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceKey;
  }
  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
  struct DEVMODE {
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
    public short dmSpecVersion, dmDriverVersion, dmSize, dmDriverExtra;
    public int dmFields, dmPositionX, dmPositionY, dmDisplayOrientation, dmDisplayFixedOutput;
    public short dmColor, dmDuplex, dmYResolution, dmTTOption, dmCollate;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
    public short dmLogPixels;
    public int dmBitsPerPel, dmPelsWidth, dmPelsHeight, dmDisplayFlags, dmDisplayFrequency;
    public int dmICMMethod, dmICMIntent, dmMediaType, dmDitherType, dmReserved1, dmReserved2;
    public int dmPanningWidth, dmPanningHeight;
  }
  [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
  static extern bool EnumDisplayDevicesW(string dev, uint i, ref DISPLAY_DEVICE dd, uint flags);
  [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
  static extern bool EnumDisplaySettingsW(string dev, int mode, ref DEVMODE dm);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)]
  static extern int ChangeDisplaySettingsExW(string dev, ref DEVMODE dm, IntPtr hwnd, uint flags, IntPtr param);

  // Every display adapter output, one line each, for the log.
  public static string List() {
    var sb = new StringBuilder();
    for (uint i = 0; ; i++) {
      var dd = new DISPLAY_DEVICE();
      dd.cb = Marshal.SizeOf(typeof(DISPLAY_DEVICE));
      if (!EnumDisplayDevicesW(null, i, ref dd, 0)) {
        if (i == 0) sb.AppendFormat("  none (error {0}, cb {1})", Marshal.GetLastWin32Error(), dd.cb);
        break;
      }
      sb.AppendFormat("  {0} '{1}' '{2}' flags 0x{3:X} id '{4}'\n", i, dd.DeviceName, dd.DeviceString, dd.StateFlags, dd.DeviceID);
    }
    return sb.ToString().TrimEnd();
  }

  // The attached Looking Glass output's device name, or null.
  public static string FindLG() {
    for (uint i = 0; ; i++) {
      var dd = new DISPLAY_DEVICE();
      dd.cb = Marshal.SizeOf(typeof(DISPLAY_DEVICE));
      if (!EnumDisplayDevicesW(null, i, ref dd, 0)) return null;
      if ((dd.StateFlags & 1) != 0 && dd.DeviceString != null && dd.DeviceString.Contains("Looking Glass"))
        return dd.DeviceName;
    }
  }

  static DEVMODE Current(string dev) {
    var dm = new DEVMODE();
    dm.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));
    if (!EnumDisplaySettingsW(dev, -1, ref dm))
      throw new Exception("EnumDisplaySettings failed, error " + Marshal.GetLastWin32Error());
    return dm;
  }

  public static string Size(string dev) {
    var dm = Current(dev);
    return dm.dmPelsWidth + "x" + dm.dmPelsHeight;
  }

  // ChangeDisplaySettingsEx with CDS_UPDATEREGISTRY, as the LG helper does.
  public static int Apply(string dev, int w, int h) {
    var dm = Current(dev);
    dm.dmPelsWidth = w;
    dm.dmPelsHeight = h;
    dm.dmFields = 0x180000;
    return ChangeDisplaySettingsExW(dev, ref dm, IntPtr.Zero, 1, IntPtr.Zero);
  }
}
"@

New-Item -ItemType Directory -Force -Path $dir | Out-Null
$logFile = "$dir\display-backstop.log"
function Log($m) {
  $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $m
  Add-Content -Path $logFile -Value $line
  $line
}

$t0 = Get-Date
Log "start: user $env:USERNAME, session $((Get-Process -Id $PID).SessionId), uptime $([int]((Get-Date) - (Get-CimInstance Win32_OperatingSystem).LastBootUpTime).TotalSeconds) s"
$lastNote = ''
while (((Get-Date) - $t0).TotalSeconds -lt $Seconds) {
  $el = '{0:N1} s' -f ((Get-Date) - $t0).TotalSeconds
  $extra = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\LookingGlass\IDD' -Name ExtraMode -ErrorAction SilentlyContinue).ExtraMode
  if ($extra -notmatch '^(\d+)x(\d+)@') { Log "$el no usable ExtraMode ('$extra'); stop"; return }
  $w = [int]$Matches[1]; $h = [int]$Matches[2]
  $name = [LanaiDisp]::FindLG()
  if (-not $name) {
    if ($lastNote -ne 'nodev') {
      Log "$el no Looking Glass display attached yet; displays seen:"
      Log ([LanaiDisp]::List())
      $lastNote = 'nodev'
    }
    Start-Sleep -Milliseconds 500; continue
  }
  $cur = [LanaiDisp]::Size($name)
  if ($cur -eq "${w}x${h}") {
    Log "$el $name desktop $cur matches ExtraMode $extra; done"
    return
  }
  $r = [LanaiDisp]::Apply($name, $w, $h)
  $note = "desktop $cur, ExtraMode $extra; switch result $r"
  if ($note -ne $lastNote) { Log "$el $name $note"; $lastNote = $note }
  Start-Sleep -Milliseconds 500
}
Log "gave up after $Seconds s"

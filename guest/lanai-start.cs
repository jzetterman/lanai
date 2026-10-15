// lanai-start.cs: the display scale task's start program (Lanai, spec
// requirements 4, 7, 12 and 27; plan, resize phase H).
//
// Setup builds it in Windows with the .NET Framework's csc.exe into
// C:\Program Files\Lanai\lanai-start.exe, as a windows program
// (/target:winexe), so the task shows no console window. The task runs it
// at sign-in, with no arguments. It:
//   1. reads the SMBIOS OEM strings and exits at once, changing nothing,
//      without Lanai's "lanai-scale=" string (not Lanai's VM);
//   2. puts itself in a kill-on-close job, then starts lanai-scale.ps1 in
//      a hidden powershell.exe, so the script ends whenever the program
//      ends;
//   3. runs the sign-in step (SigninStep), then waits for the script and
//      returns its exit code.
// With the one argument /check it returns 0 and does nothing else: setup
// runs it to check that Windows lets it run.
//
// Windows' csc.exe compiles C# 5 only, against .NET Framework 4.x, with
// only mscorlib and System.dll: no interpolated strings, ?., nameof, out
// var or expression-bodied members, and no LINQ or other types from other
// assemblies. Log lines go to lanai-signin.log in the program's own
// folder, C:\Program Files\Lanai. Past 1 MB the log moves to
// lanai-signin.log.old.

using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using Microsoft.Win32;

public static class LanaiStart {
    // The log's cap in bytes: past it, the next write moves the log aside.
    public const long LogCap = 1048576;

    // What the SMBIOS read found (requirement 4).
    public enum Oem { Found, NotFound, Failed }

    // The SMBIOS read's result: Kind, and Error's reason when it Failed.
    public sealed class OemRead {
        public readonly Oem Kind;
        public readonly string Error;
        public OemRead(Oem kind, string error) {
            Kind = kind;
            Error = error;
        }
    }

    // What Run calls, so tests drive every path with fakes. The real ones
    // (RealDeps) turn their own failures into results, except Wait, which
    // can throw; Run's catch logs that.
    //   ReadOem      the SMBIOS read
    //   Job          make the kill-on-close job and join it: null, or why not
    //   StartScript  start the scale script in the job: null, or why not
    //   Step         the sign-in step, to its end
    //   Wait         wait for the script; its exit code
    //   Log          write a line; with true, not when the log's last line
    //                already carries it
    public sealed class Deps {
        public Func<OemRead> ReadOem;
        public Func<string> Job;
        public Func<string> StartScript;
        public Action Step;
        public Func<int> Wait;
        public Action<string, bool> Log;
    }

    // Nothing else here: a type-load failure outside Run's try would go to
    // Windows Error Reporting, which can show a dialog and keep the task
    // alive while it collects a dump.
    public static int Main(string[] args) {
        return Run(args, RealDeps());
    }

    // The program, in order (see the top of this file). Returns 0 for
    // /check and for not Lanai's VM, 2 for any other argument, 1 when the
    // job or the script start failed, or else the script's exit code. Every
    // exception is logged and returns 1.
    public static int Run(string[] args, Deps deps) {
        try {
            if (args.Length == 1 && args[0] == "/check") return 0;
            if (args.Length != 0) return 2;
            OemRead oem = deps.ReadOem();
            if (oem.Kind == Oem.NotFound) {
                // The task starts every 5 minutes: one line, not one a start.
                deps.Log("Start program: not Lanai's VM; changed nothing", true);
                return 0;
            }
            // A failed read skips the step but still starts the script,
            // which reads the OEM strings itself and exits when they are
            // not Lanai's.
            bool step = oem.Kind == Oem.Found;
            if (!step) deps.Log("Start program: error: " + oem.Error, false);
            deps.Log("Start program: " + StartedLine(), false);
            // The job first, so the script is born in it. Without the job
            // no script starts: one could outlive a crashed program, and the
            // task's 5-minute repetition tries again.
            string error = deps.Job();
            if (error == null) error = deps.StartScript();
            if (error != null) {
                deps.Log("Start program: error: " + error, false);
                if (step) deps.Step();
                return 1;
            }
            if (step) deps.Step();
            return deps.Wait();
        }
        catch (Exception e) {
            try { deps.Log("Start program: error: " + e.Message, false); } catch (Exception) { }
            return 1;
        }
    }

    // "started <s> s after the process started at <time>", so the log shows
    // how long Windows took to start the program.
    static string StartedLine() {
        try {
            DateTime start = Process.GetCurrentProcess().StartTime;
            double s = Math.Round((DateTime.Now - start).TotalSeconds, 2);
            return "started " + s.ToString(CultureInfo.InvariantCulture) + " s after the process started at " +
                start.ToString("o");
        }
        catch (Exception) {
            return "started; the process start time is unknown";
        }
    }

    // The real calls. Only delegates: this opens no file or key and starts
    // nothing, so /check changes nothing.
    static Deps RealDeps() {
        Deps d = new Deps();
        d.ReadOem = ReadOem;
        d.Job = JoinJob;
        d.StartScript = StartScript;
        d.Step = RunStep;
        d.Wait = WaitScript;
        d.Log = Log;
        return d;
    }

    // The log beside this program, in the same folder as the script it
    // starts.
    static void Log(string message, bool skipSame) {
        WriteLog(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "lanai-signin.log"), message, skipSame);
    }

    // Append "<time> <message>" to the log at <path>: open, append, close,
    // so another reader is never locked out for long. With <skipSame>, a
    // message the log's last line already carries is not written again.
    // A log past LogCap moves to <path>.old first (replacing an older one),
    // so a failure that repeats every 5 minutes cannot grow it without
    // bound. A failed move or write is dropped.
    public static void WriteLog(string path, string message, bool skipSame) {
        try {
            FileInfo info = new FileInfo(path);
            if (info.Exists && info.Length > LogCap) {
                File.Delete(path + ".old");
                File.Move(path, path + ".old");
            }
        }
        catch (Exception) { }
        try {
            using (FileStream f = new FileStream(path, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.Read)) {
                if (skipSame && message == LastMessage(f)) return;
                byte[] line = new UTF8Encoding(false).GetBytes(DateTime.Now.ToString("o") + " " + message + "\r\n");
                f.Seek(0, SeekOrigin.End);
                f.Write(line, 0, line.Length);
            }
        }
        catch (Exception) { }
    }

    // The message of the log's last line (the text after its time stamp),
    // read from the last 4 KB, or null.
    static string LastMessage(FileStream f) {
        long from = Math.Max(0, f.Length - 4096);
        byte[] tail = new byte[f.Length - from];
        f.Seek(from, SeekOrigin.Begin);
        int n = 0;
        while (n < tail.Length) {
            int got = f.Read(tail, n, tail.Length - n);
            if (got <= 0) break;
            n += got;
        }
        string text = new UTF8Encoding(false).GetString(tail, 0, n).TrimEnd('\r', '\n');
        string last = text.Substring(text.LastIndexOf('\n') + 1);
        int space = last.IndexOf(' ');
        if (space < 0) return null;
        return last.Substring(space + 1);
    }

    // --- The SMBIOS read ---

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern uint GetSystemFirmwareTable(uint provider, uint id, byte[] buffer, uint size);

    // Read the raw SMBIOS table (the provider 'RSMB' as a big-endian number)
    // and look for Lanai's OEM string. Not through WMI: its assembly is not
    // in the build, and the WMI service is busy at sign-in.
    static OemRead ReadOem() {
        try {
            uint size = GetSystemFirmwareTable(0x52534D42, 0, null, 0);
            if (size == 0) throw new Win32Exception(Marshal.GetLastWin32Error());
            byte[] buf = new byte[size];
            uint got = GetSystemFirmwareTable(0x52534D42, 0, buf, size);
            if (got == 0) throw new Win32Exception(Marshal.GetLastWin32Error());
            if (got > size) throw new Exception("the SMBIOS table grew while it was read");
            Array.Resize(ref buf, (int)got);
            Oem kind = ParseSmbios(buf);
            if (kind == Oem.Failed) return new OemRead(kind, "the SMBIOS table is malformed");
            return new OemRead(kind, null);
        }
        catch (Exception e) {
            return new OemRead(Oem.Failed, e.Message);
        }
    }

    // Look for a type 11 (OEM strings) string that starts with
    // "lanai-scale=", ignoring case, in the buffer GetSystemFirmwareTable
    // returns: the 8-byte RawSMBIOSData header (calling method, major and
    // minor version, DMI revision, then the table's length as a 32-bit
    // little-endian number), then the table. The scale script validates the
    // value. A buffer under 8 bytes, or a length past its end, is Failed.
    // The walk stops at type 127 (end of table), at a length byte under 4,
    // or at a structure or string set that runs past the table; what it
    // found before then counts. Never throws.
    public static Oem ParseSmbios(byte[] buf) {
        if (buf == null || buf.Length < 8) return Oem.Failed;
        uint length = (uint)(buf[4] | (buf[5] << 8) | (buf[6] << 16) | (buf[7] << 24));
        if (length > (uint)(buf.Length - 8)) return Oem.Failed;
        int end = 8 + (int)length;
        int pos = 8;
        // Each structure: type, length (the formatted area, this header
        // included), a 2-byte handle; then its strings, each ending in a
        // NUL, and one more NUL (two NULs when it has no strings).
        while (pos + 4 <= end) {
            int type = buf[pos];
            int len = buf[pos + 1];
            if (type == 127 || len < 4 || pos + len > end) break;
            int i = pos + len;
            bool match = false;
            bool closed = false;
            if (i + 1 < end && buf[i] == 0 && buf[i + 1] == 0) {
                i += 2;
                closed = true;
            }
            while (!closed && i < end) {
                int j = Array.IndexOf(buf, (byte)0, i, end - i);
                if (j < 0) break;
                if (type == 11 && Encoding.ASCII.GetString(buf, i, j - i)
                        .StartsWith("lanai-scale=", StringComparison.OrdinalIgnoreCase))
                    match = true;
                i = j + 1;
                if (i < end && buf[i] == 0) {
                    i++;
                    closed = true;
                }
            }
            // A string set that runs past the table does not count.
            if (!closed) break;
            if (match) return Oem.Found;
            pos = i;
        }
        return Oem.NotFound;
    }

    // --- The job and the script ---

    const int JobObjectExtendedLimitInformation = 9;
    const uint JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x2000;

    [StructLayout(LayoutKind.Sequential)]
    public struct JOBOBJECT_BASIC_LIMIT_INFORMATION {
        public long PerProcessUserTimeLimit;
        public long PerJobUserTimeLimit;
        public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize;
        public UIntPtr MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass;
        public uint SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct IO_COUNTERS {
        public ulong ReadOperationCount, WriteOperationCount, OtherOperationCount;
        public ulong ReadTransferCount, WriteTransferCount, OtherTransferCount;
    }

    // 144 bytes on x64.
    [StructLayout(LayoutKind.Sequential)]
    public struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION {
        public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
        public IO_COUNTERS IoInfo;
        public UIntPtr ProcessMemoryLimit;
        public UIntPtr JobMemoryLimit;
        public UIntPtr PeakProcessMemoryUsed;
        public UIntPtr PeakJobMemoryUsed;
    }

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern IntPtr CreateJobObject(IntPtr attributes, string name);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool SetInformationJobObject(IntPtr job, int infoClass,
        ref JOBOBJECT_EXTENDED_LIMIT_INFORMATION info, uint size);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);

    [DllImport("kernel32.dll")]
    static extern IntPtr GetCurrentProcess();

    // The job's handle. Never closed: when the program ends for any reason,
    // Task Scheduler's stop included, Windows closes it, and the job ends
    // the script. A raw handle in a static field: a handle object held in a
    // local could be finalized after its last use under /optimize, which
    // would end the program and the script at a random moment.
    static IntPtr job;

    // The scale script's process, once started.
    static Process script;

    // Make a job that kills its processes when its last handle closes, and
    // put this program in it (Windows 8 and later nest jobs, so this works
    // inside Task Scheduler's own job). No security attributes, so the
    // handle is not inheritable: a script that held it would keep the job
    // open after the program died. Returns null, or why it failed.
    static string JoinJob() {
        try {
            job = CreateJobObject(IntPtr.Zero, null);
            if (job == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
            JOBOBJECT_EXTENDED_LIMIT_INFORMATION info = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
            info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
            if (!SetInformationJobObject(job, JobObjectExtendedLimitInformation, ref info,
                    (uint)Marshal.SizeOf(typeof(JOBOBJECT_EXTENDED_LIMIT_INFORMATION))))
                throw new Win32Exception(Marshal.GetLastWin32Error());
            if (!AssignProcessToJobObject(job, GetCurrentProcess()))
                throw new Win32Exception(Marshal.GetLastWin32Error());
            return null;
        }
        catch (Exception e) {
            return e.Message;
        }
    }

    // Start lanai-scale.ps1 from this program's own folder, in
    // powershell.exe by its absolute path in the system folder. No shell
    // and no window: Windows gives the script a hidden conhost.exe. Returns
    // null, or why it failed.
    static string StartScript() {
        try {
            ProcessStartInfo info = new ProcessStartInfo(
                Path.Combine(Environment.SystemDirectory, @"WindowsPowerShell\v1.0\powershell.exe"),
                "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"" +
                Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "lanai-scale.ps1") + "\"");
            info.UseShellExecute = false;
            info.CreateNoWindow = true;
            script = Process.Start(info);
            if (script == null) return "powershell.exe did not start";
            return null;
        }
        catch (Exception e) {
            return e.Message;
        }
    }

    // Wait for the script and return its exit code: the task lives as long
    // as the script.
    static int WaitScript() {
        script.WaitForExit();
        return script.ExitCode;
    }

    // The sign-in step on the real Windows calls, ticked every 250 ms until
    // it ends. Its 2-minute stop rule bounds it.
    static void RunStep() {
        SigninStep step = new SigninStep();
        step.GetMark = LanaiRegistry.GetMark;
        step.SetMark = LanaiRegistry.SetMark;
        step.ReadExtraMode = LanaiRegistry.ReadExtraMode;
        step.Find = LanaiDesktop.Find;
        step.Size = LanaiDesktop.Size;
        step.Apply = LanaiDesktop.Apply;
        step.Log = delegate(string message) { Log(message, false); };
        Stopwatch clock = Stopwatch.StartNew();
        while (!step.Tick(clock.Elapsed.TotalMilliseconds)) Thread.Sleep(250);
    }
}

// The sign-in step (spec 12): after a boot, Windows' frame can reach the size
// Lanai asked for while the desktop keeps its old size, and Windows' display
// helper cannot switch the desktop until the signed-in desktop is up. So on
// the first task start since the sign-in (a mark in HKCU\Volatile
// Environment, which Windows rebuilds at each sign-in and drops at
// sign-out), the step sets the Looking Glass display's desktop to the size
// the display driver stored from Lanai's latest ask that it took (ExtraMode
// in HKLM\SOFTWARE\LookingGlass\IDD). It tries every 500 ms, reading that
// size again each time, until the desktop matches or 2 minutes pass; it
// stops early when Windows does not support the size or after 3 switches
// that did not take. With no Looking Glass display or no stored size it
// changes nothing. Its log lines start "Sign-in step:".
public sealed class SigninStep {
    // The step's inputs, so tests drive it with fakes:
    //   GetMark, SetMark  read the sign-in mark (null when absent) and set it
    //   ReadExtraMode     the driver's stored mode, raw, or null
    //   Find              the Looking Glass display's device name, or null
    //   Size              that device's desktop size, "<w>x<h>"
    //   Apply             switch the device's desktop to <w>x<h>; the
    //                     DISP_CHANGE result
    //   Log               write one line
    public Func<object> GetMark;
    public Action SetMark;
    public Func<object> ReadExtraMode;
    public Func<string> Find;
    public Func<string, string> Size;
    public Func<string, int, int, int> Apply;
    public Action<string> Log;

    // A stored size.
    public sealed class Mode {
        public readonly int Width, Height;
        public Mode(int width, int height) {
            Width = width;
            Height = height;
        }
    }

    // One switch: the size it asked for, its DISP_CHANGE result, and when
    // (ms on the step's clock).
    public sealed class Switch {
        public readonly int Width, Height, Result;
        public readonly double At;
        public Switch(int width, int height, int result, double at) {
            Width = width;
            Height = height;
            Result = result;
            At = at;
        }
    }

    // What one try does: Kind "stop", "wait" or "switch", the Line to log
    // ("" for none) and, for a switch, the size.
    public sealed class Decision {
        public readonly string Kind, Line;
        public readonly int Width, Height;
        public Decision(string kind, string line, int width, int height) {
            Kind = kind;
            Line = line;
            Width = width;
            Height = height;
        }
    }

    // "gate" until the first tick reads the mark, "run" while the step
    // tries, "done" once it stopped or skipped.
    string phase = "gate";
    double startedAt;
    double nextTry;
    readonly List<Switch> switches = new List<Switch>();
    string lastLine = "";
    // The wait and error lines already logged, each logged once.
    readonly Dictionary<string, bool> logged = new Dictionary<string, bool>();

    // Parse the driver's stored mode <value> ("<w>x<h>@<refresh>", "*"
    // marking the preferred one) to its size, or null for anything else: a
    // value that is not a string, a side of 0, or a side that is not 1 to 5
    // ASCII digits. Any interactive user can write the value, so it is
    // untrusted; the step logs the parsed size, never the raw value.
    public static Mode ParseExtraMode(object value) {
        string s = value as string;
        if (s == null) return null;
        int i = 0;
        int w = Digits(s, ref i);
        if (w <= 0 || i >= s.Length || s[i] != 'x') return null;
        i++;
        int h = Digits(s, ref i);
        if (h <= 0 || i >= s.Length || s[i] != '@') return null;
        return new Mode(w, h);
    }

    // Read 1 to 5 ASCII digits of <s> from <i>, moving <i> past them.
    // Returns the number, or -1 for none or more than 5.
    static int Digits(string s, ref int i) {
        int start = i, n = 0;
        while (i < s.Length && s[i] >= '0' && s[i] <= '9') {
            n = n * 10 + (s[i] - '0');
            i++;
            if (i - start > 5) return -1;
        }
        return i == start ? -1 : n;
    }

    // Name <n> switches, as "1 switch" or "2 switches".
    static string SwitchCount(int n) {
        return n == 1 ? "1 switch" : n + " switches";
    }

    // Decide one try at time <now> (ms) for a step that started at
    // <startedAt> and made <done> switches, from the stored size <stored>
    // (null when there is none), the Looking Glass display's device name
    // <device> (null or empty when none is attached), its desktop size
    // <desktop> ("<w>x<h>") and <readError> (the message of a read that
    // threw, or empty). In order:
    //   120 s since the step started        stop, saying what it changed
    //   a read threw                        wait, naming the error
    //   no stored size                      stop
    //   no Looking Glass display            wait
    //   the desktop is the stored size      stop: it matches
    //   the last switch got DISP_CHANGE_BADMODE (-2) for this size: stop
    //   3 successful switches, each 2 s old, whose size the desktop does not
    //   show                                stop
    //   a successful switch under 2 s ago   wait (the switch is asynchronous)
    //   otherwise                           switch to the stored size
    public static Decision Decide(double startedAt, Switch[] done, double now, Mode stored,
            string device, string desktop, string readError) {
        int ok = 0, missed = 0;
        bool recent = false;
        foreach (Switch s in done) {
            if (s.Result != 0) continue;
            ok++;
            if (now - s.At < 2000) recent = true;
            else if (s.Width + "x" + s.Height != desktop) missed++;
        }
        string changed = ok > 0 ? "Windows reported " + SwitchCount(ok) + " done" : "changed nothing";
        if (now - startedAt >= 120000) return new Decision("stop", "gave up after 2 minutes; " + changed, 0, 0);
        if (!string.IsNullOrEmpty(readError)) return new Decision("wait", "error: " + readError, 0, 0);
        if (stored == null) return new Decision("stop", "no stored size; " + changed, 0, 0);
        if (string.IsNullOrEmpty(device)) return new Decision("wait", "no Looking Glass display", 0, 0);
        string size = stored.Width + "x" + stored.Height;
        if (desktop == size) {
            double after = Math.Round((now - startedAt) / 1000, 2);
            return new Decision("stop", "desktop " + size + " matches after " + SwitchCount(done.Length) + ", " +
                after.ToString(CultureInfo.InvariantCulture) + " s after the step started", 0, 0);
        }
        if (done.Length > 0) {
            Switch last = done[done.Length - 1];
            if (last.Result == -2 && last.Width == stored.Width && last.Height == stored.Height)
                return new Decision("stop", "Windows does not support " + size, 0, 0);
        }
        if (missed >= 3) return new Decision("stop", "3 switches did not take", 0, 0);
        if (recent) return new Decision("wait", "", 0, 0);
        return new Decision("switch", "", stored.Width, stored.Height);
    }

    // One tick at time <now> (ms); returns whether the step has ended. It
    // acts at most every 500 ms. The first tick is the gate: with the
    // sign-in mark already set, this task start is not the first since the
    // sign-in (the trigger's repetition after the task exited), so it
    // skips; otherwise it sets the mark and runs. Each try reads the stored
    // size, the display and its desktop again, asks Decide, and acts.
    // Everything it calls is caught: an exception is a failed try, logged
    // once per message, and never ends the program.
    public bool Tick(double now) {
        if (phase == "done") return true;
        if (now < nextTry) return false;
        nextTry = now + 500;
        try {
            if (phase == "gate") {
                phase = "done";
                object mark;
                try { mark = GetMark(); }
                catch (Exception e) {
                    Write("skipped (cannot read the sign-in mark: " + e.Message + ")");
                    return true;
                }
                if (mark != null) {
                    Write("skipped (already ran since sign-in)");
                    return true;
                }
                try { SetMark(); }
                catch (Exception e) {
                    Write("skipped (cannot set the sign-in mark: " + e.Message + ")");
                    return true;
                }
                phase = "run";
                startedAt = now;
                Write("started");
            }
            Mode stored = null;
            string device = null, desktop = null, readError = "";
            try {
                stored = ParseExtraMode(ReadExtraMode());
                if (stored != null) {
                    device = Find();
                    if (!string.IsNullOrEmpty(device)) desktop = Size(device);
                }
            }
            catch (Exception e) {
                readError = e.Message;
            }
            Decision a = Decide(startedAt, switches.ToArray(), now, stored, device, desktop, readError);
            if (a.Kind == "stop") {
                phase = "done";
                Write(a.Line);
            }
            else if (a.Kind == "wait") {
                if (a.Line != "") WriteOnce(a.Line);
            }
            else {
                int result = Apply(device, a.Width, a.Height);
                switches.Add(new Switch(a.Width, a.Height, result, now));
                string line = "desktop " + desktop + ", stored size " + a.Width + "x" + a.Height +
                    "; switch result " + result;
                if (line != lastLine) {
                    lastLine = line;
                    Write(line);
                }
            }
        }
        catch (Exception e) {
            WriteOnce("error: " + e.Message);
        }
        return phase == "done";
    }

    // Log <line> unless it was logged before.
    void WriteOnce(string line) {
        if (logged.ContainsKey(line)) return;
        logged[line] = true;
        Write(line);
    }

    // Log one step line. A failed log is dropped.
    void Write(string line) {
        try { Log("Sign-in step: " + line); } catch (Exception) { }
    }
}

// The sign-in step's registry calls. They return null for a missing key or
// value and throw only on a real error.
public static class LanaiRegistry {
    // The sign-in mark, or null until the step ran since this sign-in.
    public static object GetMark() {
        using (RegistryKey k = Registry.CurrentUser.OpenSubKey("Volatile Environment")) {
            return k == null ? null : k.GetValue("LanaiSigninStep");
        }
    }

    // Set the sign-in mark. Throws when the key is missing: a key Lanai made
    // would not be volatile, and the mark would outlive the sign-in.
    public static void SetMark() {
        using (RegistryKey k = Registry.CurrentUser.OpenSubKey("Volatile Environment", true)) {
            if (k == null) throw new Exception(@"HKCU\Volatile Environment is missing");
            k.SetValue("LanaiSigninStep", "1");
        }
    }

    // The driver's stored mode, raw, or null.
    public static object ReadExtraMode() {
        using (RegistryKey k = Registry.LocalMachine.OpenSubKey(@"SOFTWARE\LookingGlass\IDD")) {
            return k == null ? null : k.GetValue("ExtraMode");
        }
    }
}

// The Looking Glass display's desktop size, for the sign-in step. The
// layouts are the prototype's, which worked on Windows 11 26200.
public static class LanaiDesktop {
    // 840 bytes.
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct DISPLAY_DEVICE {
        public int cb;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string DeviceName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceString;
        public int StateFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceID;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceKey;
    }

    // DEVMODEW with the display fields, 220 bytes.
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct DEVMODE {
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

    const int DISPLAY_DEVICE_ATTACHED_TO_DESKTOP = 1;
    const int ENUM_CURRENT_SETTINGS = -1;
    const int DM_PELSWIDTH_PELSHEIGHT = 0x180000;
    const uint CDS_UPDATEREGISTRY = 1;

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool EnumDisplayDevicesW(string device, uint index, ref DISPLAY_DEVICE dd, uint flags);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool EnumDisplaySettingsW(string device, int mode, ref DEVMODE dm);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern int ChangeDisplaySettingsExW(string device, ref DEVMODE dm, IntPtr hwnd, uint flags, IntPtr param);

    // The device name of the display attached to the desktop whose adapter
    // names Looking Glass, or null.
    public static string Find() {
        for (uint i = 0; ; i++) {
            DISPLAY_DEVICE dd = new DISPLAY_DEVICE();
            dd.cb = Marshal.SizeOf(typeof(DISPLAY_DEVICE));
            if (!EnumDisplayDevicesW(null, i, ref dd, 0)) return null;
            if ((dd.StateFlags & DISPLAY_DEVICE_ATTACHED_TO_DESKTOP) != 0 && dd.DeviceString != null &&
                dd.DeviceString.Contains("Looking Glass"))
                return dd.DeviceName;
        }
    }

    static DEVMODE Current(string device) {
        DEVMODE dm = new DEVMODE();
        dm.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));
        if (!EnumDisplaySettingsW(device, ENUM_CURRENT_SETTINGS, ref dm))
            throw new Exception("EnumDisplaySettings failed: " + Marshal.GetLastWin32Error());
        return dm;
    }

    // The device's desktop size, "<w>x<h>".
    public static string Size(string device) {
        DEVMODE dm = Current(device);
        return dm.dmPelsWidth + "x" + dm.dmPelsHeight;
    }

    // Switch the device's desktop to <w>x<h>: the current mode with only
    // the width and height fields set, saved to the registry as Windows'
    // display helper does. Returns the DISP_CHANGE result: 0 success,
    // -2 a mode Windows does not support.
    public static int Apply(string device, int w, int h) {
        DEVMODE dm = Current(device);
        dm.dmPelsWidth = w;
        dm.dmPelsHeight = h;
        dm.dmFields = DM_PELSWIDTH_PELSHEIGHT;
        return ChangeDisplaySettingsExW(device, ref dm, IntPtr.Zero, CDS_UPDATEREGISTRY, IntPtr.Zero);
    }
}

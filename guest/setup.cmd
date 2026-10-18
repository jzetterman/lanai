@echo off
rem setup.cmd: Lanai's setup inside Windows (spec req 7, plan phase 6).
rem Run it from Lanai's setup drive as the user who uses Windows. It asks for
rem administrator rights once, then, in order: installs the SPICE guest
rem agent, the QEMU guest agent with its allow-list, WinFsp, the pinned
rem virtio-fs driver and service, checks that the shared folder from Linux
rem appears as a drive (lanai-share-check.ps1), builds the display scale
rem task's start program and adds the task (its program and script in
rem C:\Program Files\Lanai), turns the Windows lock off (lanai-lock.cmd),
rem and installs the Looking Glass display driver last, since it turns this
rem display black.
rem Then Windows shuts down, and Lanai setup goes on at the next boot.
rem Safe to rerun. It parses no localized text.
setlocal EnableExtensions DisableDelayedExpansion

if /i "%~1"=="/elevated" goto :elevated

rem --- Stage 1, as the signed-in user ---
rem whoami's CSV gives the SID in every Windows language. The elevated stage
rem compares it with its own: a standard user who types an administrator's
rem credentials would otherwise change the administrator's settings.
set "LANAI_SID="
for /f "tokens=2 delims=," %%s in ('whoami /user /fo csv /nh') do set "LANAI_SID=%%~s"
if not defined LANAI_SID goto :no_sid
set "LANAI_SETUP=%~f0"
echo Lanai setup needs administrator rights once. Approve the prompt with the
echo account you are signed in as.
rem A declined prompt is a non-terminating error in Windows PowerShell 5.1,
rem which would leave $p empty and exit 0; Stop makes it 1223 (ERROR_CANCELLED).
powershell -NoProfile -NonInteractive -Command "$ErrorActionPreference = 'Stop'; try { $p = Start-Process -FilePath $env:LANAI_SETUP -ArgumentList '/elevated', $env:LANAI_SID -Verb RunAs -Wait -PassThru; exit $p.ExitCode } catch { exit 1223 }"
rem Exact codes: "if errorlevel N" means N or more. 0 is done, and 1223 a
rem declined prompt. Anything else exits without a pause: the elevated
rem window already showed it and paused, or, for a failed display driver
rem (2), the display may be black and Lanai's step 6 reports it.
set "RC=%errorlevel%"
if "%RC%"=="0" exit /b 0
if "%RC%"=="1223" goto :declined
exit /b 1

:no_sid
echo Lanai setup: cannot read your account's SID with whoami.
pause
exit /b 1

:declined
echo Lanai setup did not start: the administrator prompt was declined. Run
echo setup.cmd again and approve it.
pause
exit /b 1

rem --- Stage 2, elevated ---
rem It runs from System32, so every file comes from the setup drive by %~dp0.
rem Each step sets STEP, and RC right after its command, for the messages.
:elevated
fltmc >nul 2>&1
if errorlevel 1 goto :not_elevated
set "WANT_SID=%~2"
set "HAVE_SID="
for /f "tokens=2 delims=," %%s in ('whoami /user /fo csv /nh') do set "HAVE_SID=%%~s"
if not defined HAVE_SID goto :other_account
if /i not "%HAVE_SID%"=="%WANT_SID%" goto :other_account
rem Only from Lanai's read-only setup drive: a writable copy can let other
rem accounts swap an installer or plant a DLL before this stage runs it.
set "WTEST=.lanai-wtest-%RANDOM%%RANDOM%%RANDOM%"
copy /y nul "%~dp0%WTEST%" >nul 2>&1
if not errorlevel 1 goto :writable_copy

rem Every file first, so a broken setup drive changes nothing.
for %%f in (spice-vdagent.msi qemu-ga.msi winfsp.msi looking-glass-idd-setup.exe lanai-lock.cmd lanai-scale.ps1 lanai-start.cs lanai-share-check.ps1 viofs\w11\amd64\viofs.inf viofs\w11\amd64\virtiofs.exe) do if not exist "%~dp0%%f" goto :media_broken
rem The compiler step 6 builds the start program with: the .NET Framework
rem 4.x csc.exe that every Windows 10 and 11 carries. .NET calls only: a
rem cmdlet would load modules from the user's module path.
powershell -NoProfile -NonInteractive -Command "if ([IO.File]::Exists([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory() + 'csc.exe')) { exit 0 }; exit 1"
if errorlevel 1 goto :no_compiler

echo [1/8] Installing the SPICE guest agent
set "STEP=the SPICE guest agent"
msiexec /i "%~dp0spice-vdagent.msi" /qn /norestart
set "RC=%errorlevel%"
if not "%RC%"=="0" if not "%RC%"=="3010" goto :failed

echo [2/8] Installing the QEMU guest agent
set "STEP=the QEMU guest agent"
msiexec /i "%~dp0qemu-ga.msi" /qn /norestart
set "RC=%errorlevel%"
if not "%RC%"=="0" if not "%RC%"=="3010" goto :failed
rem The allow-list (proof 3): Lanai uses the agent only to set the clock. The
rem command is fixed by the pinned MSI; only a reinstall or repair resets it.
set "STEP=the QEMU guest agent's allow-list"
sc.exe config QEMU-GA binPath= "\"C:\Program Files\Qemu-ga\qemu-ga.exe\" -d --retry-path --allow-rpcs=guest-sync,guest-sync-delimited,guest-set-time" >nul
set "RC=%errorlevel%"
if not "%RC%"=="0" goto :failed

echo [3/8] Installing WinFsp
set "STEP=WinFsp"
msiexec /i "%~dp0winfsp.msi" /qn /norestart
set "RC=%errorlevel%"
if not "%RC%"=="0" if not "%RC%"=="3010" goto :failed

echo [4/8] Installing the virtio-fs driver
set "STEP=the virtio-fs driver"
rem Always, not only when missing: dockur's older driver fails with the
rem pinned virtiofs.exe (proof 2). 259 means it is already current. The
rem service stops first, so the update never meets a running service
rem (dockur's, on a first setup); its result is ignored, as in [5/8].
net stop VirtioFsSvc >nul 2>&1
pnputil /add-driver "%~dp0viofs\w11\amd64\viofs.inf" /install
set "RC=%errorlevel%"
if not "%RC%"=="0" if not "%RC%"=="3010" if not "%RC%"=="259" goto :failed

echo [5/8] Setting up the file-sharing service
set "STEP=the file-sharing service"
set "VFS_NEW="
sc.exe query VirtioFsSvc >nul 2>&1
if "%errorlevel%"=="1060" set "VFS_NEW=1"
rem On a rerun the service holds Lanai's own virtiofs.exe open, and it may
rem have started again since [4/8]. net stop waits for the stop; its result
rem is ignored (2 both for "not started" and for real failures, with a
rem localized message): a held file fails the copy.
if not defined VFS_NEW net stop VirtioFsSvc >nul 2>&1
if exist "C:\Program Files\Lanai\" goto :vfs_copy
mkdir "C:\Program Files\Lanai"
set "RC=%errorlevel%"
if not "%RC%"=="0" goto :failed
:vfs_copy
copy /y "%~dp0viofs\w11\amd64\virtiofs.exe" "C:\Program Files\Lanai\virtiofs.exe"
set "RC=%errorlevel%"
if not "%RC%"=="0" goto :failed
rem dockur may already have made the service: update it, or create it. The
rem path is quoted inside, as for QEMU-GA: a LocalSystem service with an
rem unquoted path that holds a space could run C:\Program.exe (CWE-428).
if defined VFS_NEW goto :vfs_create
sc.exe config VirtioFsSvc binPath= "\"C:\Program Files\Lanai\virtiofs.exe\"" start= auto depend= "WinFsp.Launcher/VirtioFsDrv" >nul
set "RC=%errorlevel%"
if not "%RC%"=="0" goto :failed
goto :vfs_done
:vfs_create
sc.exe create VirtioFsSvc binPath= "\"C:\Program Files\Lanai\virtiofs.exe\"" start= auto depend= "WinFsp.Launcher/VirtioFsDrv" >nul
set "RC=%errorlevel%"
if not "%RC%"=="0" goto :failed
:vfs_done
rem The share check (spec 7): the service starts now, and the shared folder
rem must appear as a drive that lists before setup goes on. net start's
rem result is ignored: the check covers it. net and powershell go by their
rem bare names, as elsewhere here: they resolve from System32, the elevated
rem stage's working folder. The script runs from the setup drive; it exits
rem 0, 10 (no drive) or 11 (no listing), and anything else means it could
rem not run. :share_missing tells them apart.
echo Checking that the shared folder from Linux appears in Windows (up to 30 seconds)...
net start VirtioFsSvc >nul 2>&1
powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%~dp0lanai-share-check.ps1"
set "RC=%errorlevel%"
if not "%RC%"=="0" goto :share_missing

echo [6/8] Adding the display scale task
set "STEP=the display scale task"
rem The script goes beside virtiofs.exe: standard users cannot write under
rem C:\Program Files, so no other account can swap the file the task runs.
copy /y "%~dp0lanai-scale.ps1" "C:\Program Files\Lanai\lanai-scale.ps1" >nul
set "RC=%errorlevel%"
if not "%RC%"=="0" goto :failed
rem The task's temp folder: PowerShell compiles Add-Type there, then loads
rem the DLL it built, so it must be one standard users cannot write.
if exist "C:\Program Files\Lanai\tmp\" goto :scale_task
mkdir "C:\Program Files\Lanai\tmp"
set "RC=%errorlevel%"
if not "%RC%"=="0" goto :failed
:scale_task
rem The task's start program, lanai-start.exe: a windows program, so the
rem task shows no window, that starts the script and runs the sign-in step.
rem Setup builds it here from its source with Windows' own compiler, so no
rem prebuilt program enters Windows. Everything below runs on every rerun,
rem which jumps here past the tmp folder's mkdir.
copy /y "%~dp0lanai-start.cs" "C:\Program Files\Lanai\lanai-start.cs" >nul
set "RC=%errorlevel%"
if not "%RC%"=="0" goto :failed
rem On a rerun the old program still runs: the task started it at sign-in.
rem Windows lets a running program be renamed but not replaced or deleted,
rem so it moves aside and runs until setup's restart. The delete clears
rem the ones an earlier run moved aside; one that still runs stays, so its
rem result is ignored.
del /q "C:\Program Files\Lanai\lanai-start.old-*.exe" >nul 2>&1
powershell -NoProfile -NonInteractive -Command "$ErrorActionPreference = 'Stop'; $p = 'C:\Program Files\Lanai\lanai-start'; if ([IO.File]::Exists($p + '.exe')) { [IO.File]::Move($p + '.exe', $p + '.old-' + [DateTime]::UtcNow.Ticks + '.exe') }"
set "RC=%errorlevel%"
if not "%RC%"=="0" goto :failed
rem The build reads and writes only where administrators alone can write
rem (spec 27): the working folder is Lanai's, TMP and TEMP its tmp folder,
rem LIB (csc's search path for references) is cleared, and PATH is the
rem system folder only. The compiler by its full path. /noconfig skips
rem csc.rsp, so the build references System.dll only. The module path is
rem pinned before Set-Location: the elevated stage has the user's
rem environment, and a cmdlet loads its module from that path.
powershell -NoProfile -NonInteractive -Command "$ErrorActionPreference = 'Stop'; $env:PSModulePath = [Environment]::SystemDirectory + '\WindowsPowerShell\v1.0\Modules;C:\Program Files\WindowsPowerShell\Modules'; $csc = [Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory() + 'csc.exe'; Set-Location -LiteralPath 'C:\Program Files\Lanai'; $env:TMP = 'C:\Program Files\Lanai\tmp'; $env:TEMP = 'C:\Program Files\Lanai\tmp'; $env:LIB = $null; $env:PATH = [Environment]::SystemDirectory; & $csc /nologo /noconfig /target:winexe /optimize /r:System.dll /out:lanai-start.exe lanai-start.cs; exit $LASTEXITCODE"
set "RC=%errorlevel%"
if not "%RC%"=="0" goto :failed
rem The self-check (spec 7): with /check the program returns 0 and changes
rem and starts nothing. A policy that blocks it makes Start-Process throw.
rem Not &: PowerShell does not wait for a windows program and sets no exit
rem code. A null exit code fails too.
powershell -NoProfile -NonInteractive -Command "$ErrorActionPreference = 'Stop'; $env:PSModulePath = [Environment]::SystemDirectory + '\WindowsPowerShell\v1.0\Modules;C:\Program Files\WindowsPowerShell\Modules'; try { $p = Start-Process -FilePath 'C:\Program Files\Lanai\lanai-start.exe' -ArgumentList '/check' -Wait -PassThru; if ($null -eq $p.ExitCode) { exit 1 }; exit $p.ExitCode } catch { exit 1 }"
set "RC=%errorlevel%"
if not "%RC%"=="0" goto :start_blocked
rem An interactive task for the SID the elevated stage's account check
rem verified, which stores no password. It runs elevated (highest
rem privileges, no prompt): Windows opens the scale port only to
rem administrators. -Force replaces it on a rerun, so there is one task. The sign-in trigger repeats every 5 minutes
rem with no end (a repetition pattern with no Duration), and IgnoreNew makes
rem a start a no-op while the task runs, so a task that died is back within
rem 5 minutes. RestartCount would cover only a failed start (phase C).
rem The action is the start program by its absolute path, with no
rem arguments. [char]34 quotes the path, which holds a space (CWE-428),
rem without nested quotes for cmd. The module path is pinned first, as for
rem the build.
set "LANAI_TASK_SID=%HAVE_SID%"
powershell -NoProfile -NonInteractive -Command "$ErrorActionPreference = 'Stop'; $env:PSModulePath = [Environment]::SystemDirectory + '\WindowsPowerShell\v1.0\Modules;C:\Program Files\WindowsPowerShell\Modules'; $u = $env:LANAI_TASK_SID; $a = New-ScheduledTaskAction -Execute ([char]34 + 'C:\Program Files\Lanai\lanai-start.exe' + [char]34); $t = New-ScheduledTaskTrigger -AtLogOn -User $u; $r = Get-CimClass -Namespace 'Root/Microsoft/Windows/TaskScheduler' -ClassName 'MSFT_TaskRepetitionPattern' | New-CimInstance -ClientOnly; $r.Interval = 'PT5M'; $t.Repetition = $r; $p = New-ScheduledTaskPrincipal -UserId $u -LogonType Interactive -RunLevel Highest; $s = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew; Register-ScheduledTask -TaskName 'Lanai display scale' -Action $a -Trigger $t -Principal $p -Settings $s -Force | Out-Null"
set "RC=%errorlevel%"
if not "%RC%"=="0" goto :failed

echo [7/8] Turning the Windows lock off
set "STEP=the lock settings"
rem call, or control never comes back here. lanai-lock.cmd never relaunches
rem itself, so this prompt stays the only one.
call "%~dp0lanai-lock.cmd"
set "RC=%errorlevel%"
if not "%RC%"=="0" goto :failed

echo [8/8] Installing the Looking Glass display driver
echo This screen turns black now. Windows shuts down by itself in a moment.
set "STEP=the Looking Glass display driver"
rem Last: nothing after it may need the user's eyes or a key press.
rem Trust the valid IDD signer to avoid Windows' extra publisher prompt.
rem The module path is pinned first, as for the build.
set "LANAI_IDD=%~dp0looking-glass-idd-setup.exe"
powershell -NoProfile -NonInteractive -Command "$ErrorActionPreference = 'Stop'; $env:PSModulePath = [Environment]::SystemDirectory + '\WindowsPowerShell\v1.0\Modules;C:\Program Files\WindowsPowerShell\Modules'; $s = Get-AuthenticodeSignature -LiteralPath $env:LANAI_IDD; if ($s.Status -ne 'Valid' -or -not $s.SignerCertificate) { exit 2 }; $st = New-Object System.Security.Cryptography.X509Certificates.X509Store('TrustedPublisher','LocalMachine'); $st.Open('ReadWrite'); $st.Add($s.SignerCertificate); $st.Close()"
if errorlevel 1 echo Windows may ask to trust the Looking Glass driver's publisher; choose Install.
"%~dp0looking-glass-idd-setup.exe" /S /ivshmem
set "RC=%errorlevel%"
if not "%RC%"=="0" goto :idd_failed
echo Lanai setup finished. Windows shuts down in 10 seconds.
rem A full shutdown (no /hybrid), so QEMU exits and Lanai goes on. The new
rem service settings apply at the next boot, where Lanai checks them.
shutdown /s /t 10
exit /b 0

:not_elevated
echo Lanai setup: this stage needs administrator rights. Run setup.cmd itself.
pause
exit /b 1

:other_account
echo Lanai setup: the administrator prompt was approved with another account.
echo Windows' Administrator protection, when on, also causes this.
echo Setup changes the signed-in user's settings, so it stopped and changed
echo nothing. Run setup.cmd as an administrator account, or make your account
echo an administrator first.
pause
exit /b 1

:media_broken
echo Lanai setup: a file is missing from the setup drive. Nothing was changed.
echo Run Lanai setup again to rebuild the setup drive.
pause
exit /b 1

:no_compiler
echo Lanai setup: Windows' C# compiler, csc.exe, is missing from
echo the .NET Framework 4 folder. Lanai builds its display scale program
echo with it. Nothing was changed.
echo Repair the .NET Framework 4.8 in Windows, then run setup.cmd again.
pause
exit /b 1

:writable_copy
del "%~dp0%WTEST%" >nul 2>&1
echo Lanai setup: run setup.cmd from Lanai's read-only setup drive, not from a copy.
pause
exit /b 1

:start_blocked
echo.
echo Lanai setup stopped: Windows blocked the program setup built for the
echo display scale task, C:\Program Files\Lanai\lanai-start.exe. To fix this:
echo - With antivirus, allow the program by its path,
echo   C:\Program Files\Lanai\lanai-start.exe.
echo - With an App Control or AppLocker policy, allow the program by its path,
echo   C:\Program Files\Lanai\lanai-start.exe. A rule by file hash stops
echo   working, because setup builds the program again on each run.
echo - With Smart App Control on, turn it off: Windows Security ^> App ^& browser control.
echo   It allows no single program, and on many Windows versions only a
echo   reinstall turns it back on.
echo Then run setup.cmd again.
pause
exit /b 1

:share_missing
rem One goto per code, so no word sits inside an if ( ) block, where a ")"
rem would end it. Every code ends with the same steps; when the check could
rem not run, the security-tool step comes first. A panel shutdown in this
rem boot leaves setup at step 5, so the panel offers the displays again,
rem and the next setup boot checks the folder on Linux first.
echo.
if "%RC%"=="10" goto :share_absent
if "%RC%"=="11" goto :share_unreadable
echo Lanai setup stopped: the check for the shared folder could not run
echo (exit code %RC%).
echo To fix this:
echo - If a security tool blocks scripts, allow Windows PowerShell to run
echo   lanai-share-check.ps1 from the setup drive.
goto :share_steps
:share_absent
echo Lanai setup stopped: the shared folder from Linux did not appear in Windows
echo as a drive.
goto :share_fix
:share_unreadable
echo Lanai setup stopped: the shared folder from Linux appeared as a drive, but
echo Windows could not read it.
:share_fix
echo To fix this:
:share_steps
echo - Restart Windows from the Start menu. The setup drive stays attached.
echo - If setup stopped here before, shut Windows down from the Lanai panel
echo   instead, then click Set up in a basic window or Set up in the Windows
echo   window. Lanai then checks the folder on Linux.
echo Then run setup.cmd again.
pause
exit /b 1

:failed
echo.
echo Lanai setup stopped at %STEP% (exit code %RC%). Nothing after it was
echo changed. Fix the cause, then run setup.cmd again.
pause
exit /b 1

:idd_failed
rem No pause: the display may already be black. Its own exit code, 2, tells
rem stage 1 not to pause either.
echo Lanai setup stopped at %STEP% (exit code %RC%). Shut Windows down, then
echo run Lanai setup again.
exit /b 2

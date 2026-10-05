@echo off
rem setup.cmd: Lanai's setup inside Windows (spec req 7, plan phase 6).
rem Run it from Lanai's setup drive as the user who uses Windows. It asks for
rem administrator rights once, then, in order: installs the SPICE guest
rem agent, the QEMU guest agent with its allow-list, WinFsp, the pinned
rem virtio-fs driver and service, adds the sign-in scale task (its script in
rem C:\Program Files\Lanai), turns the Windows lock off (lanai-lock.cmd), and installs
rem the Looking Glass display driver last, since it turns this display black.
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
for %%f in (spice-vdagent.msi qemu-ga.msi winfsp.msi looking-glass-idd-setup.exe lanai-lock.cmd lanai-scale.ps1 viofs\w11\amd64\viofs.inf viofs\w11\amd64\virtiofs.exe) do if not exist "%~dp0%%f" goto :media_broken

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
rem pinned virtiofs.exe (proof 2). 259 means it is already current.
pnputil /add-driver "%~dp0viofs\w11\amd64\viofs.inf" /install
set "RC=%errorlevel%"
if not "%RC%"=="0" if not "%RC%"=="3010" if not "%RC%"=="259" goto :failed

echo [5/8] Setting up the file-sharing service
set "STEP=the file-sharing service"
set "VFS_NEW="
sc.exe query VirtioFsSvc >nul 2>&1
if "%errorlevel%"=="1060" set "VFS_NEW=1"
rem On a rerun the service holds Lanai's own virtiofs.exe open. net stop
rem waits for the stop; its result is ignored (2 both for "not started" and
rem for real failures, with a localized message): a held file fails the copy.
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

echo [6/8] Adding the sign-in task for the display scale
set "STEP=the sign-in task for the display scale"
rem The script goes beside virtiofs.exe: standard users cannot write under
rem C:\Program Files, so no other account can swap the file the task runs.
copy /y "%~dp0lanai-scale.ps1" "C:\Program Files\Lanai\lanai-scale.ps1" >nul
set "RC=%errorlevel%"
if not "%RC%"=="0" goto :failed
rem An interactive task for this user (the SID check above), which stores no
rem password. -Force replaces it on a rerun. [char]34 quotes the path, which
rem holds a space, without nested quotes for cmd.
powershell -NoProfile -NonInteractive -Command "$ErrorActionPreference = 'Stop'; $u = $env:USERDOMAIN + '\' + $env:USERNAME; $a = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File ' + [char]34 + 'C:\Program Files\Lanai\lanai-scale.ps1' + [char]34); $t = New-ScheduledTaskTrigger -AtLogOn -User $u; $p = New-ScheduledTaskPrincipal -UserId $u -LogonType Interactive; Register-ScheduledTask -TaskName 'Lanai display scale' -Action $a -Trigger $t -Principal $p -Force | Out-Null"
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
set "LANAI_IDD=%~dp0looking-glass-idd-setup.exe"
powershell -NoProfile -NonInteractive -Command "$ErrorActionPreference = 'Stop'; $s = Get-AuthenticodeSignature -LiteralPath $env:LANAI_IDD; if ($s.Status -ne 'Valid' -or -not $s.SignerCertificate) { exit 2 }; $st = New-Object System.Security.Cryptography.X509Certificates.X509Store('TrustedPublisher','LocalMachine'); $st.Open('ReadWrite'); $st.Add($s.SignerCertificate); $st.Close()"
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

:writable_copy
del "%~dp0%WTEST%" >nul 2>&1
echo Lanai setup: run setup.cmd from Lanai's read-only setup drive, not from a copy.
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

@echo off
rem setup.cmd: Lanai's setup inside Windows (spec req 7, plan phase 6).
rem Run it from Lanai's setup drive as the user who uses Windows. It asks for
rem administrator rights once, then, in order: prepares C:\Lanai for the
rem sign-in scale task, installs the SPICE guest agent, the QEMU guest agent
rem with its allow-list, WinFsp, the pinned virtio-fs driver and service, adds
rem the scale task, turns the Windows lock off (lanai-lock.cmd), and installs
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
rem Exact codes: "if errorlevel N" means N or more. 0 is done; 2 is a failed
rem display driver, when this display may be black (Lanai's step 6 reports
rem it); any other failure was shown, with a pause, in the elevated window.
set "RC=%errorlevel%"
if "%RC%"=="0" exit /b 0
if "%RC%"=="1223" goto :declined
if "%RC%"=="2" exit /b 1
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

rem Every file first, so a broken setup drive changes nothing.
for %%f in (spice-vdagent.msi qemu-ga.msi winfsp.msi looking-glass-idd-setup.exe lanai-lock.cmd lanai-scale.ps1 viofs\w11\amd64\viofs.inf viofs\w11\amd64\virtiofs.exe) do if not exist "%~dp0%%f" goto :media_broken

echo [1/9] Preparing C:\Lanai
set "STEP=the folder C:\Lanai"
rem Never a recursive delete: an elevated one could follow a planted link.
rem A link in C:\Lanai's place is removed with rd without /s, which unlinks
rem it and never touches its target.
fsutil reparsepoint query C:\Lanai >nul 2>&1
if errorlevel 1 goto :lanai_no_link
rd C:\Lanai
set "RC=%errorlevel%"
if not "%RC%"=="0" goto :failed
:lanai_no_link
rem An existing folder is removed and made anew, so the folder and the
rem script are always Lanai's own: another account that made C:\Lanai first
rem owns it and may have given itself an explicit ACE, which no ACL change
rem below would remove. It may hold only lanai-scale.ps1, as a plain file.
rem Judge dir's output, not its exit code (1 on an empty folder).
if not exist C:\Lanai\ goto :lanai_create
set "LANAI_EXTRA="
for /f "eol=: delims=" %%f in ('dir /b /a C:\Lanai 2^>nul') do if /i not "%%f"=="lanai-scale.ps1" set "LANAI_EXTRA=1"
if defined LANAI_EXTRA goto :lanai_planted
if not exist C:\Lanai\lanai-scale.ps1 goto :lanai_remove
if exist C:\Lanai\lanai-scale.ps1\ goto :lanai_planted
fsutil reparsepoint query C:\Lanai\lanai-scale.ps1 >nul 2>&1
if not errorlevel 1 goto :lanai_planted
del /f /q C:\Lanai\lanai-scale.ps1
set "RC=%errorlevel%"
if not "%RC%"=="0" goto :failed
:lanai_remove
rem del can exit 0 without deleting; rd then fails on the folder left full.
rd C:\Lanai
set "RC=%errorlevel%"
if not "%RC%"=="0" goto :failed
:lanai_create
rem Fails when C:\Lanai exists again, say another account made it meanwhile.
mkdir C:\Lanai
set "RC=%errorlevel%"
if not "%RC%"=="0" goto :failed
rem Owner and access by well-known SID, since group names are localized: a
rem new folder under C:\ would inherit Modify for Authenticated Users.
icacls C:\Lanai /setowner *S-1-5-32-544 >nul
set "RC=%errorlevel%"
if not "%RC%"=="0" goto :failed
icacls C:\Lanai /inheritance:r /grant "*S-1-5-32-544:(OI)(CI)F" "*S-1-5-18:(OI)(CI)F" "*S-1-5-32-545:(OI)(CI)RX" >nul
set "RC=%errorlevel%"
if not "%RC%"=="0" goto :failed
rem A link swapped in meanwhile would have taken the ACL instead.
fsutil reparsepoint query C:\Lanai >nul 2>&1
if not errorlevel 1 goto :lanai_planted
rem The new folder must be empty: anything in it was planted between mkdir
rem and the ACL.
set "LANAI_EXTRA="
for /f "eol=: delims=" %%f in ('dir /b /a C:\Lanai 2^>nul') do set "LANAI_EXTRA=1"
if defined LANAI_EXTRA goto :lanai_planted
copy /y "%~dp0lanai-scale.ps1" C:\Lanai\lanai-scale.ps1 >nul
set "RC=%errorlevel%"
if not "%RC%"=="0" goto :failed

echo [2/9] Installing the SPICE guest agent
set "STEP=the SPICE guest agent"
msiexec /i "%~dp0spice-vdagent.msi" /qn /norestart
set "RC=%errorlevel%"
if not "%RC%"=="0" if not "%RC%"=="3010" goto :failed

echo [3/9] Installing the QEMU guest agent
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

echo [4/9] Installing WinFsp
set "STEP=WinFsp"
msiexec /i "%~dp0winfsp.msi" /qn /norestart
set "RC=%errorlevel%"
if not "%RC%"=="0" if not "%RC%"=="3010" goto :failed

echo [5/9] Installing the virtio-fs driver
set "STEP=the virtio-fs driver"
rem Always, not only when missing: dockur's older driver fails with the
rem pinned virtiofs.exe (proof 2). 259 means it is already current.
pnputil /add-driver "%~dp0viofs\w11\amd64\viofs.inf" /install
set "RC=%errorlevel%"
if not "%RC%"=="0" if not "%RC%"=="3010" if not "%RC%"=="259" goto :failed

echo [6/9] Setting up the file-sharing service
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
rem dockur may already have made the service: update it, or create it.
if defined VFS_NEW goto :vfs_create
sc.exe config VirtioFsSvc binPath= "C:\Program Files\Lanai\virtiofs.exe" start= auto depend= "WinFsp.Launcher/VirtioFsDrv" >nul
set "RC=%errorlevel%"
if not "%RC%"=="0" goto :failed
goto :vfs_done
:vfs_create
sc.exe create VirtioFsSvc binPath= "C:\Program Files\Lanai\virtiofs.exe" start= auto depend= "WinFsp.Launcher/VirtioFsDrv" >nul
set "RC=%errorlevel%"
if not "%RC%"=="0" goto :failed
:vfs_done

echo [7/9] Adding the sign-in task for the display scale
set "STEP=the sign-in task for the display scale"
rem An interactive task for this user (the SID check above), which stores no
rem password. -Force replaces it on a rerun.
powershell -NoProfile -NonInteractive -Command "$ErrorActionPreference = 'Stop'; $u = $env:USERDOMAIN + '\' + $env:USERNAME; $a = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File C:\Lanai\lanai-scale.ps1'; $t = New-ScheduledTaskTrigger -AtLogOn -User $u; $p = New-ScheduledTaskPrincipal -UserId $u -LogonType Interactive; Register-ScheduledTask -TaskName 'Lanai display scale' -Action $a -Trigger $t -Principal $p -Force | Out-Null"
set "RC=%errorlevel%"
if not "%RC%"=="0" goto :failed

echo [8/9] Turning the Windows lock off
set "STEP=the lock settings"
rem call, or control never comes back here. lanai-lock.cmd never relaunches
rem itself, so this prompt stays the only one.
call "%~dp0lanai-lock.cmd"
set "RC=%errorlevel%"
if not "%RC%"=="0" goto :failed

echo [9/9] Installing the Looking Glass display driver
echo This screen turns black now. Windows shuts down by itself in a moment.
set "STEP=the Looking Glass display driver"
rem Last: nothing after it may need the user's eyes or a key press.
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

:lanai_planted
echo Lanai setup: C:\Lanai holds something Lanai did not put there:
dir /b /a C:\Lanai
echo Another account may have planted it. Check it, move it away, then run
echo setup.cmd again.
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

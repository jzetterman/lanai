@echo off
rem lanai-lock.cmd: turn off locking inside Windows for Lanai (spec req 7).
rem A locked Windows ignores the shutdown request Lanai sends, so its VM
rem would be force-stopped. The Linux session's lock covers the window instead.
rem
rem setup.cmd runs it with `call` from its elevated stage. The lock proof runs
rem it by hand from an elevated Command Prompt (docs/plugin/proofs.md, proof 5).
rem It never relaunches itself: every write happens in the caller's process,
rem so setup's one administrator prompt stays the only one. Safe to rerun.
rem Returns 0 when every change worked, and 1 when it is not elevated or a
rem change failed. LANAI_FAKE_MANAGED=1 makes the domain and MDM check report
rem membership (spec row 7b). It parses no localized text: only reg value
rem names and dsregcmd's key names.
setlocal EnableExtensions DisableDelayedExpansion

rem net session fails without administrator rights.
net session >nul 2>&1
if errorlevel 1 goto :not_elevated

set "USER_POL=HKCU\Software\Microsoft\Windows\CurrentVersion\Policies\System"
set "MACHINE_POL=HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"

rem Removes Lock from Start and Ctrl+Alt+Del, and turns off Windows key + L.
reg add "%USER_POL%" /v DisableLockWorkstation /t REG_DWORD /d 1 /f >nul || goto :failed
rem Hides Switch user, which leaves the session behind the sign-in screen.
reg add "%MACHINE_POL%" /v HideFastUserSwitching /t REG_DWORD /d 1 /f >nul || goto :failed
rem The screen saver may still run, but it no longer asks for the password.
reg add "HKCU\Control Panel\Desktop" /v ScreenSaverIsSecure /t REG_SZ /d 0 /f >nul || goto :failed
rem The machine inactivity limit. reg delete fails on an absent value, the
rem normal case, so it runs only when reg query finds the value.
reg query "%MACHINE_POL%" /v InactivityTimeoutSecs >nul 2>&1
if errorlevel 1 goto :lock_off
reg delete "%MACHINE_POL%" /v InactivityTimeoutSecs /f >nul || goto :failed

:lock_off
rem Sign-in on wake and Dynamic Lock cannot fire in this VM (no sleep
rem states, no Bluetooth), so they stay as they are.
echo lanai-lock: locking inside Windows is off.

rem A domain, Entra ID or MDM policy may turn the lock back on.
set "MANAGED="
if "%LANAI_FAKE_MANAGED%"=="1" set "MANAGED=1"
powershell -NoProfile -NonInteractive -Command "(Get-CimInstance Win32_ComputerSystem).PartOfDomain" 2>nul | findstr /b /c:"True" >nul
if not errorlevel 1 set "MANAGED=1"
dsregcmd /status 2>nul | findstr /r /i /c:"AzureAdJoined *: *YES" /c:"WorkplaceJoined *: *YES" >nul
if not errorlevel 1 set "MANAGED=1"
reg query "HKLM\SOFTWARE\Microsoft\Enrollments" /s /v ProviderID 2>nul | findstr /r /i /c:"^ *ProviderID  *REG_SZ  *[^ ]" >nul
if not errorlevel 1 set "MANAGED=1"
if not defined MANAGED exit /b 0
echo lanai-lock: this Windows is joined to a domain or enrolled in MDM. A policy
echo may turn the lock back on, and Lanai's shutdowns may then end in a forced stop.
exit /b 0

:not_elevated
echo lanai-lock: needs administrator rights. Run it from an elevated Command Prompt.
exit /b 1

:failed
echo lanai-lock: a registry change failed, so the lock may still be on.
exit /b 1

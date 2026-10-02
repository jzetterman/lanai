#!/usr/bin/env bats
# Checks on guest/lanai-lock.cmd that can run on Linux: how it is stored and
# how it exits. Its behavior in Windows is docs/plugin/proofs.md, proof 5.
# shellcheck disable=SC2016

load helpers

@test "lanai-lock.cmd: every line ends in CRLF" {
  local f=$REPO/guest/lanai-lock.cmd
  # cmd can misread labels and goto in a file with bare LF endings.
  run grep -c $'[^\r]$\\|^$' "$f"
  assert_output 0
  [[ $(tail -c 2 "$f" | od -An -tx1 | tr -d ' ') == 0d0a ]] || fail "the last line has no CRLF"
}

@test "lanai-lock.cmd: checks for administrator rights with fltmc before any registry write" {
  local f=$REPO/guest/lanai-lock.cmd check write
  # fltmc needs the administrator token and, unlike net session, no Server
  # service.
  check=$(grep -niE '^fltmc( |$)' "$f" | head -n 1 | cut -d: -f1)
  write=$(grep -niE '(^|[^a-z])reg (add|delete)' "$f" | head -n 1 | cut -d: -f1)
  [[ -n $check && -n $write ]] || fail "no fltmc check or no registry write"
  ((check < write)) || fail "fltmc on line $check comes after a write on line $write"
  run grep -viE '^[[:space:]]*rem([[:space:]]|$)' "$f"
  refute_line --regexp '[nN][eE][tT] +[sS][eE][sS][sS][iI][oO][nN]'
}

@test "lanai-lock.cmd: returns to its caller and never relaunches itself" {
  local f=$REPO/guest/lanai-lock.cmd
  # A bare exit would end setup.cmd's cmd too, and a relaunch would add a
  # second administrator prompt and lose the caller's process (plan phase 6).
  local code
  code=$(grep -viE '^[[:space:]]*rem([[:space:]]|$)' "$f" | tr -d '\r')
  run grep -ciE '(^|[^a-z])exit /b' <<<"$code"
  refute_output 0
  run grep -iE '(^|[^a-z])exit([^a-z]|$)' <<<"$code"
  refute_line --regexp '(^|[^a-zA-Z])[eE][xX][iI][tT]($|[^ ]| [^/])'
  run grep -ciE 'runas|start-process|-verb' <<<"$code"
  assert_output 0
}

# --- guest/setup.cmd ---
# Its behavior in Windows is checked in phase 8; these check the order and
# the exact commands the plan fixes.

SETUP_CMD=$BATS_TEST_DIRNAME/../guest/setup.cmd

# Print setup.cmd's command lines (no rem or blank lines), CR removed, each
# as "<line number>:<line>".
setup_code() {
  tr -d '\r' <"$SETUP_CMD" | awk '!/^[[:space:]]*([rR][eE][mM]([[:space:]]|$)|$)/ { print NR ":" $0 }'
}

# Print the number of the first command line that contains the fixed text
# <text> (line_of), or that is exactly <text> (line_is). Fails when none is.
line_of() {
  setup_code | TEXT=$1 awk '{ i = index($0, ":") } index(substr($0, i + 1), ENVIRON["TEXT"]) { print substr($0, 1, i - 1); found = 1; exit }
    END { exit !found }'
}
line_is() {
  setup_code | TEXT=$1 awk '{ i = index($0, ":") } substr($0, i + 1) == ENVIRON["TEXT"] { print substr($0, 1, i - 1); found = 1; exit }
    END { exit !found }'
}

@test "setup.cmd: every line ends in CRLF" {
  run grep -c $'[^\r]$\\|^$' "$SETUP_CMD"
  assert_output 0
}

@test "setup.cmd: the elevated stage checks its SID before it changes anything" {
  # The SID comes from whoami's CSV, in stage 1 and again elevated.
  run grep -cF "for /f \"tokens=2 delims=,\" %%s in ('whoami /user /fo csv /nh')" "$SETUP_CMD"
  assert_output 2
  local elevated sid first
  elevated=$(line_is ':elevated')
  sid=$(line_is 'if /i not "%HAVE_SID%"=="%WANT_SID%" goto :other_account')
  # The first command after :elevated that can change Windows.
  first=$(setup_code | awk -F: -v e="$elevated" '$1 > e' |
    grep -E -m1 '^[0-9]+:(icacls|msiexec|pnputil|sc\.exe (config|create)|mkdir|rd |copy|call|reg|net stop|powershell)' |
    cut -d: -f1)
  [[ -n $sid && -n $first ]] || fail "no SID check or no change"
  ((elevated < sid && sid < first)) || fail ":elevated $elevated, SID check $sid, first change $first"
  # It self-elevates exactly once.
  run grep -c -- '-Verb RunAs' "$SETUP_CMD"
  assert_output 1
}

# Print the numbers of every command line that is exactly <text>.
lines_are() {
  setup_code | TEXT=$1 awk '{ i = index($0, ":") } substr($0, i + 1) == ENVIRON["TEXT"] { print substr($0, 1, i - 1) }'
}

@test "setup.cmd: C:\\Lanai is always made anew, without recursive deletes, its ACL set by SID, then found empty" {
  # No rd, rmdir, del or erase with /s, anywhere.
  run bash -c 'tr -d "\r" <"$1" | awk "tolower(\$1) ~ /^(rd|rmdir|del|erase)\$/ && tolower(\$0) ~ / \\/s/"' _ "$SETUP_CMD"
  assert_output ""
  local -a links rds lists
  local old folder link del mkdir owner acl empty copy
  mapfile -t links < <(lines_are 'fsutil reparsepoint query C:\Lanai >nul 2>&1')
  mapfile -t rds < <(lines_are 'rd C:\Lanai')
  mapfile -t lists < <(setup_code | grep -F "('dir /b /a C:\\Lanai 2^>nul') do" | cut -d: -f1)
  ((${#links[@]} == 2 && ${#rds[@]} == 2 && ${#lists[@]} == 2)) ||
    fail "want 2 link checks, 2 rd and 2 listings: ${links[*]} / ${rds[*]} / ${lists[*]}"
  # An existing folder may hold only lanai-scale.ps1 as a plain file, which
  # is deleted before the folder goes.
  old=$(line_of "do if /i not \"%%f\"==\"lanai-scale.ps1\" set \"LANAI_EXTRA=1\"")
  folder=$(line_is 'if exist C:\Lanai\lanai-scale.ps1\ goto :lanai_planted')
  link=$(line_is 'fsutil reparsepoint query C:\Lanai\lanai-scale.ps1 >nul 2>&1')
  del=$(line_is 'del /f /q C:\Lanai\lanai-scale.ps1')
  mkdir=$(line_is 'mkdir C:\Lanai')
  owner=$(line_is 'icacls C:\Lanai /setowner *S-1-5-32-544 >nul')
  acl=$(line_of 'icacls C:\Lanai /inheritance:r /grant "*S-1-5-32-544:(OI)(CI)F" "*S-1-5-18:(OI)(CI)F" "*S-1-5-32-545:(OI)(CI)RX"')
  # After the ACL the folder must be empty: anything at all was planted.
  empty=$(line_is "for /f \"eol=: delims=\" %%f in ('dir /b /a C:\\Lanai 2^>nul') do set \"LANAI_EXTRA=1\"")
  copy=$(line_of 'copy /y "%~dp0lanai-scale.ps1" C:\Lanai\lanai-scale.ps1')
  local -a order=("${links[0]}" "${rds[0]}" "$old" "$folder" "$link" "$del" "${rds[1]}" "$mkdir"
    "$owner" "$acl" "${links[1]}" "$empty" "$copy")
  local i
  for ((i = 1; i < ${#order[@]}; i++)); do
    [[ -n ${order[i]} ]] && ((order[i - 1] < order[i])) || fail "out of order: ${order[*]}"
  done
  # mkdir always runs, and each rd, del and mkdir stops setup on failure.
  run setup_code
  refute_output --partial 'if exist C:\Lanai\ goto :lanai_acl'
  for i in "${rds[1]}" "$del" "$mkdir"; do
    assert_line "$((i + 1)):set \"RC=%errorlevel%\""
    assert_line "$((i + 2)):if not \"%RC%\"==\"0\" goto :failed"
  done
}


@test "setup.cmd: the qemu-ga allow-list is proof 3's literal command" {
  line_of 'sc.exe config QEMU-GA binPath= "\"C:\Program Files\Qemu-ga\qemu-ga.exe\" -d --retry-path --allow-rpcs=guest-sync,guest-sync-delimited,guest-set-time"'
}

@test "setup.cmd: always installs the pinned viofs driver; 0, 3010 and 259 are success" {
  local n
  n=$(line_is 'pnputil /add-driver "%~dp0viofs\w11\amd64\viofs.inf" /install')
  run setup_code
  assert_line "$((n + 1)):set \"RC=%errorlevel%\""
  assert_line "$((n + 2)):if not \"%RC%\"==\"0\" if not \"%RC%\"==\"3010\" if not \"%RC%\"==\"259\" goto :failed"
}

@test "setup.cmd: VirtioFsSvc is stopped, then the exe copied, then the service created or updated" {
  local query stop copy create config
  query=$(line_is 'if "%errorlevel%"=="1060" set "VFS_NEW=1"')
  stop=$(line_is 'if not defined VFS_NEW net stop VirtioFsSvc >nul 2>&1')
  copy=$(line_is 'copy /y "%~dp0viofs\w11\amd64\virtiofs.exe" "C:\Program Files\Lanai\virtiofs.exe"')
  config=$(line_of 'sc.exe config VirtioFsSvc binPath= "C:\Program Files\Lanai\virtiofs.exe" start= auto depend= "WinFsp.Launcher/VirtioFsDrv"')
  create=$(line_of 'sc.exe create VirtioFsSvc binPath= "C:\Program Files\Lanai\virtiofs.exe" start= auto depend= "WinFsp.Launcher/VirtioFsDrv"')
  ((query < stop && stop < copy && copy < config && copy < create)) ||
    fail "query $query, stop $stop, copy $copy, config $config, create $create"
}

@test "setup.cmd: the steps run in the planned order, the IDD last, then a full shutdown" {
  local -a order=(
    'icacls C:\Lanai /setowner'
    'msiexec /i "%~dp0spice-vdagent.msi" /qn /norestart'
    'msiexec /i "%~dp0qemu-ga.msi" /qn /norestart'
    'sc.exe config QEMU-GA'
    'msiexec /i "%~dp0winfsp.msi" /qn /norestart'
    'pnputil /add-driver'
    'sc.exe query VirtioFsSvc'
    'Register-ScheduledTask'
    'call "%~dp0lanai-lock.cmd"'
    '"%~dp0looking-glass-idd-setup.exe" /S /ivshmem'
    'shutdown /s /t 10'
  )
  local prev=0 n p
  for p in "${order[@]}"; do
    n=$(line_of "$p") || fail "no line for $p"
    ((n > prev)) || fail "$p (line $n) comes before line $prev"
    prev=$n
  done
  # lanai-lock.cmd's result stops setup.
  n=$(line_is 'call "%~dp0lanai-lock.cmd"')
  run setup_code
  assert_line "$((n + 1)):set \"RC=%errorlevel%\""
  assert_line "$((n + 2)):if not \"%RC%\"==\"0\" goto :failed"
  # From the IDD on, nothing waits for a key, even on failure.
  local idd
  idd=$(line_of '"%~dp0looking-glass-idd-setup.exe"')
  run bash -c 'tr -d "\r" <"$1" | awk -v s="$2" "NR >= s && /^exit \\/b 0\$/ { exit } NR >= s || /^:idd_failed/, /^exit/"' _ "$SETUP_CMD" "$idd"
  assert_output --partial 'shutdown /s /t 10'
  assert_output --partial ':idd_failed'
  refute_output --regexp '(^|[^a-z])pause'
  run grep -ciE "/hybrid" < <(setup_code)
  assert_output 0
}

@test "setup.cmd: only exit /b, and media files only by %~dp0" {
  # Batch commands only: PowerShell's own exit and echo text are fine.
  run bash -c 'tr -d "\r" <"$1" | grep -viE "^[[:space:]]*(rem|powershell|echo)( |\$)" | grep -iE "(^|[^a-z])exit( |\$)"' _ "$SETUP_CMD"
  refute_line --regexp '(^|[^a-zA-Z])[eE][xX][iI][tT]($| [^/])'
  local f
  for f in spice-vdagent.msi qemu-ga.msi winfsp.msi looking-glass-idd-setup.exe lanai-lock.cmd \
    'viofs\w11\amd64\viofs.inf' 'viofs\w11\amd64\virtiofs.exe'; do
    # Outside the up-front check of every file, each use is "%~dp0<file>".
    run bash -c 'grep -vF "for %%f in (" | grep -F -- "$1" | grep -vF -- "%~dp0$1"' _ "$f" < <(setup_code)
    assert_output ""
    line_of "%~dp0$f" >/dev/null || fail "setup.cmd never uses $f"
  done
}

# --- guest/lanai-scale.ps1 ---

# Print the result of PowerShell <expression> after defining $Steps and the
# script's StepName function, taken from the script itself (its other parts
# need Windows). Callers skip without pwsh before they call it: a skip
# inside `run` only ends run's subshell.
step_name() {
  PS1=$REPO/guest/lanai-scale.ps1 EXPR=$1 pwsh -NoProfile -NonInteractive -Command '
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($env:PS1, [ref]$null, [ref]$null)
    $f = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
      $n.Name -eq "StepName" }, $true) | Select-Object -First 1
    if (-not $f) { throw "no StepName function" }
    $Steps = @(100, 125, 150, 175, 200, 225, 250, 300, 350, 400, 450, 500)
    . ([scriptblock]::Create($f.Extent.Text))
    Invoke-Expression $env:EXPR'
}

@test "lanai-scale.ps1: parses without errors" {
  command -v pwsh >/dev/null || skip "pwsh is not installed"
  PS1=$REPO/guest/lanai-scale.ps1 run pwsh -NoProfile -NonInteractive -Command '
    $e = $null
    [System.Management.Automation.Language.Parser]::ParseFile($env:PS1, [ref]$null, [ref]$e) | Out-Null
    $e.Count'
  assert_success
  assert_output 0
}

@test "lanai-scale.ps1: StepName names a step, and unknown outside the list" {
  command -v pwsh >/dev/null || skip "pwsh is not installed"
  run step_name 'StepName 0; StepName 2; StepName 11; StepName -1; StepName 12; StepName -12'
  assert_success
  assert_output $'100%\n150%\n500%\nunknown\nunknown\nunknown'
}

@test "lanai-scale.ps1: every step lookup goes through StepName, and the raw values are logged" {
  local f=$REPO/guest/lanai-scale.ps1 body
  # Only StepName indexes $Steps; PowerShell wraps a negative index silently.
  body=$(awk '/^function StepName/ { skip = 1 } skip && /^}/ { skip = 0; next } !skip' "$f")
  run grep -n '\$Steps\[' <<<"$body"
  assert_failure
  run grep -E 'minScaleRel.*curScaleRel.*maxScaleRel' "$f"
  assert_output --partial 'Write-Log'
}

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

# The command lines that change Windows (ERE on a line's text).
CHANGE_RE='^(msiexec |sc\.exe (config|create) |icacls |copy |mkdir |rd |del |pnputil |call |"%~dp0looking-glass-idd-setup\.exe"|powershell .*(Register-ScheduledTask|X509Store))'

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

# The read-only probe and its cleanup touch only Lanai's temporary test file.
setup_changes() {
  setup_code | awk -F: '{ l = substr($0, index($0, ":") + 1) }
    l != "copy /y nul \"%~dp0%WTEST%\" >nul 2>&1" &&
    l != "del \"%~dp0%WTEST%\" >nul 2>&1"'
}

# Print the number of the first command line that changes Windows.
first_change() {
  setup_changes | RE=$CHANGE_RE awk '{ i = index($0, ":") } substr($0, i + 1) ~ ENVIRON["RE"] { print substr($0, 1, i - 1); exit }'
}

# Print stage 1's command lines (before the :elevated label) as setup_code
# does.
stage1_code() {
  setup_code | awk '{ i = index($0, ":") } substr($0, i + 1) == ":elevated" { exit } { print }'
}

@test "setup.cmd: every line ends in CRLF" {
  run grep -c $'[^\r]$\\|^$' "$SETUP_CMD"
  assert_output 0
}

@test "setup.cmd: the elevated stage checks its SID, then tests writability, then the media, before any change" {
  # The SID comes from whoami's CSV, in stage 1 and again elevated.
  run grep -cF "for /f \"tokens=2 delims=,\" %%s in ('whoami /user /fo csv /nh')" "$SETUP_CMD"
  assert_output 2
  local elevated admin none sid probe drive media first
  line_is 'if /i "%~1"=="/elevated" goto :elevated'
  run grep -ciE '^set +"?WANT_SID=' "$SETUP_CMD"
  assert_output 1
  line_is 'set "WANT_SID=%~2"'
  elevated=$(line_is ':elevated')
  admin=$(line_is 'fltmc >nul 2>&1')
  none=$(line_is 'if not defined HAVE_SID goto :other_account')
  sid=$(line_is 'if /i not "%HAVE_SID%"=="%WANT_SID%" goto :other_account')
  probe=$(line_is 'set "WTEST=.lanai-wtest-%RANDOM%%RANDOM%%RANDOM%"')
  drive=$(line_is 'copy /y nul "%~dp0%WTEST%" >nul 2>&1')
  line_is 'if not errorlevel 1 goto :writable_copy'
  run setup_code
  assert_line "$((drive + 1)):if not errorlevel 1 goto :writable_copy"
  media=$(line_is 'for %%f in (spice-vdagent.msi qemu-ga.msi winfsp.msi looking-glass-idd-setup.exe lanai-lock.cmd lanai-scale.ps1 viofs\w11\amd64\viofs.inf viofs\w11\amd64\virtiofs.exe) do if not exist "%~dp0%%f" goto :media_broken')
  first=$(first_change)
  [[ -n $none && -n $sid && -n $drive && -n $media && -n $first ]] || fail "a check or the first change is missing"
  ((elevated < admin && admin < none && none < sid && sid < probe && probe < drive && drive < media && media < first)) ||
    fail ":elevated $elevated, no SID $none, SID $sid, drive $drive, media $media, first change $first"
  run bash -c 'cut -d: -f2- | sed -n "/^:writable_copy\$/,/^exit/p"' < <(setup_code)
  assert_line 'del "%~dp0%WTEST%" >nul 2>&1'
  assert_line "echo Lanai setup: run setup.cmd from Lanai's read-only setup drive, not from a copy."
  assert_line 'exit /b 1'
  line_is "echo Windows' Administrator protection, when on, also causes this."
  # It self-elevates exactly once.
  run grep -c -- '-Verb RunAs' "$SETUP_CMD"
  assert_output 1
}

@test "setup.cmd: the up-front media check lists exactly the files the script calls by %~dp0" {
  local listed used
  listed=$(setup_code | grep -F 'for %%f in (' | sed 's/.*for %%f in (\(.*\)) do .*/\1/' | tr ' ' '\n' | sort)
  used=$(setup_code | grep -vF 'for %%f in (' | grep -oE '%~dp0[A-Za-z][A-Za-z0-9._\\-]*' |
    sed 's/^%~dp0//' | sort -u)
  [[ -n $used ]] || fail "no %~dp0 file found"
  assert_equal "$listed" "$used"
  run bash -c 'grep -F "for %%f in (" | grep -F "goto :media_broken"' < <(setup_code)
  assert_success
}

@test "setup.cmd: every change is followed by its exit code and a stop on failure" {
  # Each line that changes Windows: set "RC=%errorlevel%" next, then a line
  # that goes to :failed (:idd_failed for the IDD); each msiexec passes on
  # 0 or 3010 only.
  # Publisher trust is best effort: Windows can ask the user instead. Exempt
  # it from the fatal-change check; its warning and continuation are tested below.
  run bash -c 'cut -d: -f2- | RE=$1 awk '"'"'
    { l[NR] = $0 }
    END {
      for (i = 1; i <= NR; i++) {
        if (l[i] !~ ENVIRON["RE"]) continue
        if (l[i] ~ /^powershell .*X509Store/) continue
        n++
        want = (l[i] ~ /looking-glass-idd-setup/) ? " goto :idd_failed$" : " goto :failed$"
        if (l[i + 1] != "set \"RC=%errorlevel%\"" || l[i + 2] !~ ("^if .*" want)) print "unchecked: " l[i]
        if (l[i] ~ /^msiexec / && l[i + 2] != "if not \"%RC%\"==\"0\" if not \"%RC%\"==\"3010\" goto :failed") print "msiexec codes: " l[i]
      }
      print n " changes"
    }'"'"'' _ "$CHANGE_RE" < <(setup_changes)
  assert_output "13 changes"
}

@test "setup.cmd: stage 1 tells a declined prompt (1223) from the elevated stage's own failures" {
  # A canceled RunAs is a non-terminating error in Windows PowerShell 5.1,
  # so $p stays null and exit $p.ExitCode would exit 0.
  run stage1_code
  assert_output --partial "powershell -NoProfile -NonInteractive -Command \"\$ErrorActionPreference = 'Stop'; try { \$p = Start-Process -FilePath \$env:LANAI_SETUP -ArgumentList '/elevated', \$env:LANAI_SID -Verb RunAs -Wait -PassThru; exit \$p.ExitCode } catch { exit 1223 }\""
  # Exact codes only: if errorlevel N means N or more.
  refute_output --regexp '^[0-9]+:if (not )?errorlevel'
  # The four command lines right after it.
  run bash -c 'cut -d: -f2- | grep -F -A4 "Start-Process -FilePath" | tail -n 4' < <(stage1_code)
  assert_output "$(printf '%s\n' 'set "RC=%errorlevel%"' 'if "%RC%"=="0" exit /b 0' \
    'if "%RC%"=="1223" goto :declined' 'exit /b 1')"
  # Its only pauses are on the no-SID and decline paths: after a failure the
  # elevated window already paused, and after the IDD the display may be black.
  run bash -c 'awk -F: "{ l = substr(\$0, index(\$0, \":\") + 1) } l ~ /^:/ { label = l } tolower(l) == \"pause\" { print label }"' _ < <(stage1_code)
  assert_output $':no_sid\n:declined'
}

@test "setup.cmd: :failed ends with exit /b 1" {
  run bash -c 'cut -d: -f2- | sed -n "/^:failed\$/,/^:idd_failed\$/p" | head -n -1 | tail -n 1' < <(setup_code)
  assert_output 'exit /b 1'
}

@test "setup.cmd: an IDD failure exits with its own code, 2, and no pause" {
  run bash -c 'cut -d: -f2- | sed -n "/^:idd_failed\$/,/^exit/p"' < <(setup_code)
  assert_line 'exit /b 2'
  refute_output --regexp '(^|[^a-z])pause'
}

@test "setup.cmd: the scale script lives in C:\\Program Files\\Lanai, and nothing in C:\\Lanai" {
  run grep -ci 'C:\\Lanai' "$SETUP_CMD"
  assert_output 0
  # No recursive delete anywhere.
  run bash -c 'tr -d "\r" <"$1" | awk "tolower(\$1) ~ /^(rd|rmdir|del|erase)\$/ && tolower(\$0) ~ / \\/s/"' _ "$SETUP_CMD"
  assert_output ""
  local mkdir copy task
  mkdir=$(line_is 'mkdir "C:\Program Files\Lanai"')
  copy=$(line_is 'copy /y "%~dp0lanai-scale.ps1" "C:\Program Files\Lanai\lanai-scale.ps1" >nul')
  task=$(line_of 'Register-ScheduledTask')
  ((mkdir < copy && copy < task)) || fail "mkdir $mkdir, copy $copy, task $task"
  # The path holds a space: the task quotes it, without nested cmd quotes.
  run setup_code
  assert_output --partial "-Argument ('-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File ' + [char]34 + 'C:\Program Files\Lanai\lanai-scale.ps1' + [char]34)"
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

@test "setup.cmd: VirtioFsSvc is stopped, the exe copied, then the service set with a quoted path" {
  local query stop copy create config dispatch
  query=$(line_is 'if "%errorlevel%"=="1060" set "VFS_NEW=1"')
  run setup_code
  assert_line "$((query - 1)):sc.exe query VirtioFsSvc >nul 2>&1"
  dispatch=$(line_is 'if defined VFS_NEW goto :vfs_create')
  stop=$(line_is 'if not defined VFS_NEW net stop VirtioFsSvc >nul 2>&1')
  copy=$(line_is 'copy /y "%~dp0viofs\w11\amd64\virtiofs.exe" "C:\Program Files\Lanai\virtiofs.exe"')
  # Quoted inside, as the QEMU-GA line: an unquoted path with a space is
  # CWE-428 for a LocalSystem service.
  config=$(line_of 'sc.exe config VirtioFsSvc binPath= "\"C:\Program Files\Lanai\virtiofs.exe\"" start= auto depend= "WinFsp.Launcher/VirtioFsDrv"')
  create=$(line_of 'sc.exe create VirtioFsSvc binPath= "\"C:\Program Files\Lanai\virtiofs.exe\"" start= auto depend= "WinFsp.Launcher/VirtioFsDrv"')
  ((query < stop && stop < copy && copy < dispatch && dispatch < config && config < create)) ||
    fail "query $query, stop $stop, copy $copy, config $config, create $create"
}

@test "setup.cmd: the steps run in the planned order, the IDD last, then a full shutdown" {
  local -a order=(
    'msiexec /i "%~dp0spice-vdagent.msi" /qn /norestart'
    'msiexec /i "%~dp0qemu-ga.msi" /qn /norestart'
    'sc.exe config QEMU-GA'
    'msiexec /i "%~dp0winfsp.msi" /qn /norestart'
    'pnputil /add-driver'
    'sc.exe query VirtioFsSvc'
    'copy /y "%~dp0lanai-scale.ps1"'
    'Register-ScheduledTask'
    'call "%~dp0lanai-lock.cmd"'
    'Get-AuthenticodeSignature'
    '"%~dp0looking-glass-idd-setup.exe" /S /ivshmem'
    'shutdown /s /t 10'
  )
  local prev=0 n p
  for p in "${order[@]}"; do
    n=$(line_of "$p") || fail "no line for $p"
    ((n > prev)) || fail "$p (line $n) comes before line $prev"
    prev=$n
  done
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

@test "setup.cmd: trusts the IDD publisher in the elevated stage immediately before the install" {
  local elevated lock path trust idd
  elevated=$(line_is ':elevated')
  lock=$(line_is 'call "%~dp0lanai-lock.cmd"')
  path=$(line_is 'set "LANAI_IDD=%~dp0looking-glass-idd-setup.exe"')
  trust=$(line_of 'Get-AuthenticodeSignature')
  idd=$(line_is '"%~dp0looking-glass-idd-setup.exe" /S /ivshmem')
  ((elevated < lock && lock < path && path + 1 == trust && trust + 2 == idd)) ||
    fail "elevated $elevated, lock $lock, path $path, trust $trust, IDD $idd"
}

@test "setup.cmd: trusts only a Valid IDD signer in LocalMachine TrustedPublisher" {
  run bash -c 'cut -d: -f2- | grep -F "Get-AuthenticodeSignature"' < <(setup_code)
  assert_success
  assert_output --partial "powershell -NoProfile -NonInteractive -Command \"\$ErrorActionPreference = 'Stop';"
  assert_output --partial 'Get-AuthenticodeSignature -LiteralPath $env:LANAI_IDD'
  refute_output --partial '%~dp0'
  assert_output --partial "if (\$s.Status -ne 'Valid' -or -not \$s.SignerCertificate) { exit 2 }"
  assert_output --partial "New-Object System.Security.Cryptography.X509Certificates.X509Store('TrustedPublisher','LocalMachine')"
  assert_output --partial "\$st.Open('ReadWrite'); \$st.Add(\$s.SignerCertificate); \$st.Close()"
}

@test "setup.cmd: a publisher trust failure prints a note and continues to the IDD install" {
  run bash -c 'cut -d: -f2- | sed -n "/Get-AuthenticodeSignature/,+2p" | tail -n 2' < <(setup_code)
  assert_success
  assert_output "$(printf '%s\n' \
    "if errorlevel 1 echo Windows may ask to trust the Looking Glass driver's publisher; choose Install." \
    '"%~dp0looking-glass-idd-setup.exe" /S /ivshmem')"
  refute_output --partial 'goto :failed'
  refute_output --regexp '(^|[^a-z])exit'
}

@test "setup.cmd: only exit /b, and media files only by %~dp0" {
  # Batch commands only: PowerShell's own exit and echo text are fine.
  run bash -c 'tr -d "\r" <"$1" | grep -viE "^[[:space:]]*(rem|powershell|echo)( |\$)" | grep -iE "(^|[^a-z])exit( |\$)"' _ "$SETUP_CMD"
  refute_line --regexp '(^|[^a-zA-Z])[eE][xX][iI][tT]($| [^/])'
  local f
  for f in $(setup_code | grep -F 'for %%f in (' | sed 's/.*for %%f in (\(.*\)) do .*/\1/'); do
    # Outside the up-front check of every file, each use is "%~dp0<file>",
    # or the installed copy in C:\Program Files\Lanai.
    run bash -c 'grep -vF "for %%f in (" | grep -F -- "$1" | grep -vF -- "%~dp0$1" |
      grep -vF -- "Program Files\\Lanai\\$1"' _ "$f" < <(setup_code)
    assert_output ""
  done
}

# --- guest/lanai-scale.ps1 ---

# Load the actual pure decision, without the Windows-only API or main loop.
scale_decision() {
  PS1=$REPO/guest/lanai-scale.ps1 EXPR=$1 pwsh -NoProfile -NonInteractive -Command '
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($env:PS1, [ref]$null, [ref]$null)
    $f = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
      $n.Name -eq "ScaleDecision" }, $true) | Select-Object -First 1
    if (-not $f) { throw "no ScaleDecision function" }
    $Steps = @(100, 125, 150, 175, 200, 225, 250, 300, 350, 400, 450, 500)
    . ([scriptblock]::Create($f.Extent.Text))
    Invoke-Expression $env:EXPR'
}

@test "guest scale decision: caps the target and recovers as the allowed range grows" {
  command -v pwsh >/dev/null || skip "pwsh is not installed"
  run scale_decision '
    (ScaleDecision 3 -1 0 1) | ConvertTo-Json -Compress
    (ScaleDecision 3 -1 1 5) | ConvertTo-Json -Compress'
  assert_success
  assert_output $'{"recommended":1,"current":1,"target":2,"relative":1,"change":true}\n{"recommended":1,"current":2,"target":3,"relative":2,"change":true}'
}

@test "guest scale decision: moved recommendation changes the offset, unchanged scale needs no set" {
  command -v pwsh >/dev/null || skip "pwsh is not installed"
  run scale_decision '
    (ScaleDecision 1 -3 0 4) | ConvertTo-Json -Compress
    (ScaleDecision 1 -3 -2 4) | ConvertTo-Json -Compress
    (ScaleDecision 11 0 0 30) | ConvertTo-Json -Compress'
  assert_success
  assert_output $'{"recommended":3,"current":3,"target":1,"relative":-2,"change":true}\n{"recommended":3,"current":1,"target":1,"relative":-2,"change":false}\n{"recommended":0,"current":0,"target":11,"relative":11,"change":true}'
}

@test "guest scale loop: retries a late display and sets only actual changes without repeated logs" {
  command -v pwsh >/dev/null || skip "pwsh is not installed"
  PS1=$REPO/guest/lanai-scale.ps1 run pwsh -NoProfile -NonInteractive -Command '
    class LanaiDisplay {
      static [object[]] $Paths = @()
      static [object] $Dpi = @{minScaleRel=-1;curScaleRel=0;maxScaleRel=5}
      static [int] $Sets = 0
      static [bool] $IgnoreSet = $false
      static [object[]] ActivePaths() { return [LanaiDisplay]::Paths }
      static [object] GetTargetName([object] $p) { return @{monitorFriendlyDeviceName="LGIDD";monitorDevicePath="display"} }
      static [string] Resolution([object] $p) { return "1920x1080" }
      static [object] GetScale([object] $p) { return [LanaiDisplay]::Dpi }
      static [void] SetScale([object] $p, [int] $rel) { [LanaiDisplay]::Sets++; if (-not [LanaiDisplay]::IgnoreSet) { [LanaiDisplay]::Dpi.curScaleRel=$rel } }
    }
    $ErrorActionPreference="Stop"
    $Steps = @(100,125,150,175,200,225,250,300,350,400,450,500)
    $script:LastScaleError=""
    $script:Logs=@()
    function Write-Log($Message) { $script:Logs += $Message }
    $ast=[System.Management.Automation.Language.Parser]::ParseFile($env:PS1,[ref]$null,[ref]$null)
    foreach ($name in "StepName","ScaleDecision","Update-DisplayScale") {
      $f=$ast.FindAll({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true) | Select-Object -First 1
      if (-not $f) { throw "missing $name" }
      . ([scriptblock]::Create($f.Extent.Text))
    }
    Update-DisplayScale 1
    $count=$Logs.Count
    Update-DisplayScale 1
    if ($Logs.Count -ne $count) { throw "repeated absent-display error" }
    [LanaiDisplay]::Paths=@(@{sourceInfo=@{id=1};targetInfo=@{id=2}})
    Update-DisplayScale 1
    if ([LanaiDisplay]::Sets -ne 0) { throw "set unchanged display" }
    [LanaiDisplay]::Dpi=@{minScaleRel=-3;curScaleRel=0;maxScaleRel=5}
    Update-DisplayScale 1
    if ([LanaiDisplay]::Sets -ne 1 -or [LanaiDisplay]::Dpi.curScaleRel -ne -2) { throw "late recommendation not corrected" }
    $count=$Logs.Count
    Update-DisplayScale 1
    if ([LanaiDisplay]::Sets -ne 1 -or $Logs.Count -ne $count) { throw "unchanged poll set or logged" }
    # Real changes succeed promptly, including an immediate manual reversal
    # before the next healthy poll can clear the previous attempt.
    [LanaiDisplay]::Dpi.curScaleRel=0
    Update-DisplayScale 1
    [LanaiDisplay]::Dpi.curScaleRel=0
    Update-DisplayScale 1
    if ([LanaiDisplay]::Sets -ne 3) { throw "successful set delayed an immediate manual correction" }
    # A successful API return need not mean Windows applied the new scale.
    $script:Now = [datetime]"2026-10-05T00:00:00Z"
    function Get-Date { return $script:Now }
    [LanaiDisplay]::IgnoreSet=$true
    [LanaiDisplay]::Dpi.curScaleRel=0
    Update-DisplayScale 1
    $sets=[LanaiDisplay]::Sets
    $count=$Logs.Count
    1..29 | ForEach-Object { $script:Now=$script:Now.AddSeconds(2); Update-DisplayScale 1 }
    if ([LanaiDisplay]::Sets -ne $sets -or $Logs.Count -ne $count) { throw "unchanged failing decision retried or logged before one minute" }
    $script:Now=$script:Now.AddSeconds(2)
    Update-DisplayScale 1
    if ([LanaiDisplay]::Sets -ne $sets+1 -or $Logs.Count -ne $count) { throw "one minute retry or log deduplication failed" }
    Update-DisplayScale 2
    if ([LanaiDisplay]::Sets -ne $sets+2) { throw "new target did not apply promptly" }
    # A full log filesystem must not prevent a scale attempt or end the task.
    function Write-Log($Message) { throw "log is unavailable" }
    Update-DisplayScale 4
    if ([LanaiDisplay]::Sets -ne $sets+3) { throw "failed log prevented SetScale" }
    function Write-Log($Message) { $script:Logs += $Message }
    Update-DisplayScale 4
    if ([LanaiDisplay]::Sets -ne $sets+3) { throw "failed log delayed a new target before SetScale was attempted" }
    "ok"'
  assert_success
  assert_output ok
}

@test "setup scale task: no execution limit and duplicates ignored" {
  run setup_code
  assert_output --partial "New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew"
  assert_output --partial '-Settings $s'
  run cat "$REPO/guest/lanai-scale.ps1"
  assert_output --partial 'Start-Sleep -Seconds 2'
}

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

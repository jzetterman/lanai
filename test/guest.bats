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
  assert_output "14 changes"
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

# Run PowerShell <body> with the script's pure functions and its loop tick
# loaded from $GUEST_SCRIPT (default: the repo's script) through the AST, as the
# StepName tests do. Windows is faked: Get-DisplayObservation reads
# [LanaiDisplay]::D (a missing display when it is $null) and counts polls,
# SetScale counts calls and applies the change unless Apply is false,
# GetScale reads the same range back, and
# Write-Log collects lines in $script:Logs. Helpers: Obs builds an
# observation, L parses a line, Q makes a queued line, Assert throws.
guest_ps() {
  PS1=${GUEST_SCRIPT:-$REPO/guest/lanai-scale.ps1} BODY=$1 pwsh -NoProfile -NonInteractive -Command '
    $ErrorActionPreference = "Stop"
    $Steps = @(100, 125, 150, 175, 200, 225, 250, 300, 350, 400, 450, 500)
    class LanaiDisplay {
      static [hashtable] $D = @{ DevicePath = "lg"; Resolution = "1920x1080"; MinRel = -1; CurRel = 0; MaxRel = 5 }
      static [int] $Sets = 0
      static [int] $Polls = 0
      static [bool] $Apply = $true
      static [bool] $Fail = $false
      static [void] SetScale([object] $p, [int] $rel) {
        [LanaiDisplay]::Sets++
        if ([LanaiDisplay]::Fail) { throw "SET_DPI_SCALE failed: 87" }
        if ([LanaiDisplay]::Apply) { [LanaiDisplay]::D.CurRel = $rel }
      }
      static [object] GetScale([object] $p) {
        $range = [LanaiDisplay]::D
        return [pscustomobject]@{ minScaleRel = $range.MinRel; curScaleRel = $range.CurRel; maxScaleRel = $range.MaxRel }
      }
    }
    function Get-DisplayObservation {
      [LanaiDisplay]::Polls++
      $d = [LanaiDisplay]::D
      if ($null -eq $d) { throw "Found 0 Looking Glass displays among 0; expected one" }
      [pscustomobject]@{ Path = 1; Name = "LGIDD"; DevicePath = $d.DevicePath; Resolution = $d.Resolution
        MinRel = $d.MinRel; CurRel = $d.CurRel; MaxRel = $d.MaxRel
        Recommended = - $d.MinRel; Current = - $d.MinRel + $d.CurRel }
    }
    $script:Logs = @()
    function Write-Log($Message) { $script:Logs += $Message }
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($env:PS1, [ref]$null, [ref]$null)
    # Every top-level function but the two that need Windows (faked above).
    $fns = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
      $n.Name -notin "Write-Log", "Get-DisplayObservation" }, $false)
    if (@($fns).Count -lt 10) { throw "only $(@($fns).Count) functions" }
    foreach ($f in $fns) { . ([scriptblock]::Create($f.Extent.Text)) }
    function Obs($Cur, $Min = -1, $Max = 5, $Res = "1920x1080", $Path = "lg") {
      [pscustomobject]@{ Path = 1; Name = "LGIDD"; DevicePath = $Path; Resolution = $Res; MinRel = $Min; CurRel = $Cur; MaxRel = $Max
        Recommended = - $Min; Current = - $Min + $Cur }
    }
    function L($Step, $Save) { ConvertFrom-ScaleLine "lanai-scale $Step $Save" }
    function Q($Text, $At) { [pscustomobject]@{ Text = $Text; At = $At } }
    function Assert($Ok, $Why) { if (-not $Ok) { throw "failed: $Why" } }
    Invoke-Expression $env:BODY
    "ok"'
}

@test "guest line: parses a listed step and a save number, and nothing else" {
  command -v pwsh >/dev/null || skip "pwsh is not installed"
  run guest_ps '
    $p = ConvertFrom-ScaleLine "lanai-scale 150 7"
    Assert ($p.Step -eq 2 -and $p.Save -eq 7) "valid line"
    Assert ((ConvertFrom-ScaleLine "lanai-scale 500 999999999").Save -eq 999999999) "largest save"
    $bad = @("", "lanai-scale 137 1", "lanai-scale 150", "lanai-scale 150 1 2", "LANAI-SCALE 150 1",
      "lanai-scale 150 1234567890", "lanai-scale 150 99999999999999999999", ("lanai-scale 150 " + ("1" * 40)),
      "lanai-scale 150 -1", " lanai-scale 150 1", "lanai-scale 150 1 ", "lanai-scale 050 1",
      ("lanai-scale " + [char]0x0661 + [char]0x0665 + [char]0x0660 + " 1"), "lanai-scale 150 1.5")
    foreach ($b in $bad) { Assert ($null -eq (ConvertFrom-ScaleLine $b)) "accepted [$b]" }'
  assert_success
  assert_output ok
}

@test "guest drain: one valid line is used, two or more are stale, a quiet gap of 300 ms first" {
  command -v pwsh >/dev/null || skip "pwsh is not installed"
  run guest_ps '
    Assert ((Get-DrainedLine @() 1000).Kind -eq "none") "empty batch"
    $one = @((Q "" 100), (Q "lanai-scale 175 3" 100))
    Assert ((Get-DrainedLine $one 399).Kind -eq "wait") "inside the gap"
    $d = Get-DrainedLine $one 400
    Assert ($d.Kind -eq "line" -and $d.Line.Step -eq 3 -and $d.Line.Save -eq 3) "one valid line"
    $two = @((Q "lanai-scale 150 2" 100), (Q "" 100), (Q "lanai-scale 175 3" 100))
    Assert ((Get-DrainedLine $two 500).Kind -eq "stale") "two valid lines"
    # Empty and malformed lines do not count; a cut line is malformed.
    $d = Get-DrainedLine @((Q "lanai-scale 15" 100), (Q "" 100), (Q "junk" 100), (Q "lanai-scale 175 3" 100)) 500
    Assert ($d.Kind -eq "line" -and $d.Malformed -eq 2) "malformed lines dropped"
    $d = Get-DrainedLine @((Q "junk" 100)) 500
    Assert ($d.Kind -eq "none" -and $d.Malformed -eq 1) "only malformed"
    # A line inside the gap delays acting on the batch.
    $late = @((Q "junk" 100), (Q "lanai-scale 175 3" 350))
    Assert ((Get-DrainedLine $late 500).Kind -eq "wait") "late line delays"
    Assert ((Get-DrainedLine $late 650).Kind -eq "line") "acts after the late line'"'"'s gap"'
  assert_success
  assert_output ok
}

@test "guest save rule: a changed number drops the pick, the same one keeps it, the first line sets it" {
  command -v pwsh >/dev/null || skip "pwsh is not installed"
  run guest_ps '
    $s = New-ScaleState 2 5 0
    $s.Pick = 4
    $r = Step-ScaleState $s $null (L 175 6) 0
    Assert ($null -eq $r.State.Pick -and $r.State.LastSave -eq 6 -and $r.State.Want -eq 3) "greater"
    $r = Step-ScaleState $s $null (L 175 4) 0
    Assert ($null -eq $r.State.Pick -and $r.State.LastSave -eq 4) "lower"
    $r = Step-ScaleState $s $null (L 175 5) 0
    Assert ($r.State.Pick -eq 4 -and $r.State.Want -eq 3 -and $r.State.Ready) "equal: a follow update"
    # A host older than the save number: the first line sets it and clears nothing.
    $s = New-ScaleState 2 $null 0
    $s.Pick = 4
    $r = Step-ScaleState $s $null (L 175 9) 0
    Assert ($r.State.Pick -eq 4 -and $r.State.LastSave -eq 9) "first line"
    $r = Step-ScaleState $r.State $null (L 175 10) 0
    Assert ($null -eq $r.State.Pick) "the next save"'
  assert_success
  assert_output ok
}

@test "guest pick rule: a resolution change restarts the 5 s settle" {
  command -v pwsh >/dev/null || skip "pwsh is not installed"
  run guest_ps '
    $s = New-ScaleState 1 5 0
    $s.Ready = $true
    $r = Step-ScaleState $s (Obs 0) $null 0
    # The resolution changes at 10 s, the scale stays.
    $r = Step-ScaleState $r.State (Obs 0 -1 5 "2560x1440") $null 10000
    Assert ($r.Action -eq "none" -and $null -eq $r.State.Pick) "resolution change"
    # A scale change 2 s later at the new resolution is not a pick yet.
    $early = Step-ScaleState $r.State (Obs 2 -1 5 "2560x1440") $null 12000
    Assert ($null -eq $early.State.Pick -and $early.Action -eq "set" -and $early.Step -eq 1) "early: $($early.State.Pick) $($early.Action)"
    # Once settled for 5 s, a scale change is a pick.
    $late = Step-ScaleState $r.State (Obs 2 -1 5 "2560x1440") $null 15000
    Assert ($late.State.Pick -eq 3 -and $late.Action -eq "none") "late: $($late.State.Pick) $($late.Action)"'
  assert_success
  assert_output ok
}

@test "guest pick rule: only a settled change Windows made for the user is a pick" {
  command -v pwsh >/dev/null || skip "pwsh is not installed"
  run guest_ps '
    # Want 125% (index 1, the recommended step); observed at 0, settled after 5 s.
    $s = New-ScaleState 1 5 0
    $s.Ready = $true
    $r = Step-ScaleState $s (Obs 0) $null 0
    Assert ($null -eq $r.State.Pick -and $r.State.Confirmed -eq 1 -and $r.Action -eq "none") "first observation"
    $s = $r.State
    $r = Step-ScaleState $s (Obs 2) $null 6000
    Assert ($r.State.Pick -eq 3 -and $r.Action -eq "none") "a settled change is a pick"
    # Each condition alone fails.
    $r = Step-ScaleState $s (Obs 2) $null 4000
    Assert ($null -eq $r.State.Pick -and $r.Action -eq "set" -and $r.Step -eq 1) "within 5 s of the resolution"
    $r = Step-ScaleState $s (Obs 0 -2) $null 6000
    Assert ($null -eq $r.State.Pick -and $r.Action -eq "set" -and $r.Step -eq 1) "a recommended-step move"
    $r = Step-ScaleState $s (Obs 2 -1 5 "1280x720") $null 6000
    Assert ($null -eq $r.State.Pick) "a resolution move"
    $r = Step-ScaleState $s (Obs 2 -1 5 "1920x1080" "lg2") $null 6000
    Assert ($null -eq $r.State.Pick -and $r.State.Confirmed -eq 3) "a new display path"
    # A step seen inside the 5 s never ripens into a pick later.
    $r = Step-ScaleState $s (Obs 2 -1 5 "1280x720") $null 6000
    $r = Step-ScaleState $r.State (Obs 2 -1 5 "1280x720") $null 20000
    Assert ($null -eq $r.State.Pick) "no ripening"
    # The task'"'"'s own set is not a pick, and a pick right after it counts.
    $r = Step-ScaleState $s (Obs 0) (L 175 6) 6000
    Assert ($r.Action -eq "set" -and $r.Step -eq 3 -and $r.State.Pending -eq 3) "host-driven set"
    $r = Step-ScaleState $r.State (Obs 2) $null 8000
    Assert ($null -eq $r.State.Pick -and $r.State.Confirmed -eq 3 -and $null -eq $r.State.Pending) "own set observed"
    $r = Step-ScaleState $r.State (Obs 3) $null 8250
    Assert ($r.State.Pick -eq 4 -and $r.Action -eq "none") "a pick right after a host-driven change"'
  assert_success
  assert_output ok
}

@test "guest target and cap: the pick or the wanted step, capped, and back up when the window grows" {
  command -v pwsh >/dev/null || skip "pwsh is not installed"
  run guest_ps '
    # Want 300% (index 7); the resolution allows at most 200% (index 4).
    $s = New-ScaleState 7 5 0
    $s.Ready = $true
    $r = Step-ScaleState $s (Obs 0 -1 3) $null 0
    Assert ($r.Action -eq "set" -and $r.Step -eq 4 -and $r.Relative -eq 3) "capped"
    $r = Step-ScaleState $r.State (Obs 3 -1 3) $null 2000
    Assert ($r.Action -eq "none") "applied"
    $r = Step-ScaleState $r.State (Obs 3 -1 10 "2560x1440") $null 4000
    Assert ($r.Action -eq "set" -and $r.Step -eq 7 -and $null -eq $r.State.Pick) "grown"
    # A 250% pick (index 6) is capped the same way and holds as the target.
    $s = $r.State
    $s.Pick = 6
    $r = Step-ScaleState $s (Obs 6 -1 4 "1920x1080") $null 6000
    Assert ($r.Action -eq "set" -and $r.Step -eq 5 -and $r.State.Pick -eq 6) "pick capped"
    $r = Step-ScaleState $r.State (Obs 6 -1 10 "2560x1440") $null 8000
    Assert ($r.Action -eq "set" -and $r.Step -eq 6) "pick back up"'
  assert_success
  assert_output ok
}

@test "guest baseline: the OEM values wait for the first line, and a save in the meantime drops a pick" {
  command -v pwsh >/dev/null || skip "pwsh is not installed"
  run guest_ps '
    # OEM: 150% (index 2), save 5. Before the first line the OEM step waits.
    $s = New-ScaleState 2 5 0
    $r = Step-ScaleState $s (Obs 0) $null 1000
    Assert ($r.Action -eq "none" -and -not $r.State.Ready) "no apply before the first line"
    # The wait ends at 5 s: the OEM step applies, then the user picks 175%.
    $r = Step-ScaleState $r.State (Obs 0) $null 5000
    Assert ($r.Action -eq "set" -and $r.Step -eq 2) "OEM step at 5 s"
    $r = Step-ScaleState $r.State (Obs 1) $null 7000
    $r = Step-ScaleState $r.State (Obs 2) $null 12000
    Assert ($r.State.Pick -eq 3) "a pick before the channel connects"
    $s = $r.State
    $keep = Step-ScaleState $s (Obs 2) (L 150 5) 13000
    Assert ($keep.State.Pick -eq 3 -and $keep.Action -eq "none") "no save meanwhile: the pick holds"
    $drop = Step-ScaleState $s (Obs 2) (L 150 6) 13000
    Assert ($null -eq $drop.State.Pick -and $drop.Action -eq "set" -and $drop.Step -eq 2) "a save meanwhile drops it"
    # An unobserved pick and a save in the same pass: the save wins.
    $r = Step-ScaleState $drop.State (Obs 1) $null 15000
    $r = Step-ScaleState $r.State (Obs 2) (L 200 7) 21000
    Assert ($null -eq $r.State.Pick -and $r.Action -eq "set" -and $r.Step -eq 4) "save in the same pass"'
  assert_success
  assert_output ok
}

@test "guest loop: a port that never opens gets the OEM step within 5 s, an open one 3 s after it opens" {
  command -v pwsh >/dev/null || skip "pwsh is not installed"
  run guest_ps '
    function FirstSet($OpenedAt) {
      [LanaiDisplay]::Sets = 0
      [LanaiDisplay]::D.CurRel = 0
      $q = New-Object "System.Collections.Concurrent.ConcurrentQueue[object]"
      $ctx = New-ScaleContext (New-ScaleState 3 5 0) $q @{ OpenedAt = $OpenedAt }
      for ($t = 0; $t -le 8000; $t += 250) {
        Invoke-ScaleTick $ctx $t
        if ([LanaiDisplay]::Sets -gt 0) { return $t }
      }
      return -1
    }
    $t = FirstSet $null
    Assert ($t -eq 5000) "never opened: set at $t"
    $t = FirstSet 500
    Assert ($t -eq 3500) "opened at 500: set at $t"
    # A first line before the wait ends applies its own step, never the OEM one first.
    [LanaiDisplay]::Sets = 0
    [LanaiDisplay]::D.CurRel = 0
    $q = New-Object "System.Collections.Concurrent.ConcurrentQueue[object]"
    $ctx = New-ScaleContext (New-ScaleState 3 5 0) $q @{ OpenedAt = 0 }
    for ($t = 0; $t -le 3000; $t += 250) {
      if ($t -eq 1000) { $q.Enqueue((Q "" 1000)); $q.Enqueue((Q "lanai-scale 200 6" 1000)) }
      Invoke-ScaleTick $ctx $t
      if ([LanaiDisplay]::Sets -gt 0) { break }
    }
    Assert ($t -eq 1500 -and [LanaiDisplay]::D.CurRel -eq 3) "first line at 1000: set at $t to $([LanaiDisplay]::D.CurRel)"'
  assert_success
  assert_output ok
}

@test "guest loop: a resend just after each display poll is processed within one tick of its gap" {
  command -v pwsh >/dev/null || skip "pwsh is not installed"
  run guest_ps '
    $q = New-Object "System.Collections.Concurrent.ConcurrentQueue[object]"
    $ctx = New-ScaleContext (New-ScaleState 1 5 0) $q @{ OpenedAt = 0 }
    $polls = 0; $sent = $null; $acted = @(); $save = 5; $step = 175
    for ($t = 0; $t -le 30000; $t += 250) {
      # The feed'"'"'s line lands 10 ms after each poll, with a new save each time.
      if ($null -ne $sent -and $t -ge $sent.At -and -not $sent.Queued) { $q.Enqueue((Q $sent.Text $sent.At)); $sent.Queued = $true }
      $before = [LanaiDisplay]::Sets
      Invoke-ScaleTick $ctx $t
      if ([LanaiDisplay]::Sets -gt $before -and $null -ne $sent) { $acted += $t - $sent.At; $sent = $null }
      if ([LanaiDisplay]::Polls -gt $polls -and $null -eq $sent) {
        $polls = [LanaiDisplay]::Polls; $save++; $step = 325 - $step
        $sent = [pscustomobject]@{ Text = "lanai-scale $step $save"; At = $t + 10; Queued = $false }
      }
      $polls = [LanaiDisplay]::Polls
    }
    Assert ($acted.Count -ge 10) "only $($acted.Count) lines acted on"
    foreach ($a in $acted) { Assert ($a -le 550) "a line waited $a ms" }'
  assert_success
  assert_output ok
}

@test "guest loop: an unapplied set is retried once a minute and never becomes a pick; a real pick still counts" {
  command -v pwsh >/dev/null || skip "pwsh is not installed"
  run guest_ps '
    $q = New-Object "System.Collections.Concurrent.ConcurrentQueue[object]"
    $ctx = New-ScaleContext (New-ScaleState 1 5 0) $q @{ OpenedAt = 0 }
    [LanaiDisplay]::Apply = $false
    $q.Enqueue((Q "lanai-scale 175 6" 0))
    for ($t = 0; $t -le 2000; $t += 250) { Invoke-ScaleTick $ctx $t }
    Assert ([LanaiDisplay]::Sets -eq 1) "first set: $([LanaiDisplay]::Sets)"
    # Not $logs: PowerShell names ignore case, and that would replace $Logs.
    $logCount = $script:Logs.Count
    for (; $t -le 60000; $t += 250) { Invoke-ScaleTick $ctx $t }
    Assert ([LanaiDisplay]::Sets -eq 1 -and $script:Logs.Count -eq $logCount) "retried or logged before a minute"
    for (; $t -le 62500; $t += 250) { Invoke-ScaleTick $ctx $t }
    Assert ([LanaiDisplay]::Sets -eq 2) "retry after a minute: $([LanaiDisplay]::Sets)"
    Assert ($null -eq $ctx.State.Pick) "an unapplied set became a pick"
    # The user picks 200% (index 4) in Windows: a real pick right after it.
    [LanaiDisplay]::D.CurRel = 3
    for (; $t -le 65000; $t += 250) { Invoke-ScaleTick $ctx $t }
    Assert ($ctx.State.Pick -eq 4 -and [LanaiDisplay]::Sets -eq 2) "the real pick"
    Assert (($script:Logs -join "`n") -match "Pick: 200%") "the pick is logged"'
  assert_success
  assert_output ok
}

@test "guest loop: a pick of the old step right after a set, before the next poll, holds" {
  command -v pwsh >/dev/null || skip "pwsh is not installed"
  run guest_ps '
    $q = New-Object "System.Collections.Concurrent.ConcurrentQueue[object]"
    $ctx = New-ScaleContext (New-ScaleState 1 5 0) $q @{ OpenedAt = 0 }
    # Windows shows 125% (index 1), settled; a save asks for 175% at 6 s.
    for ($t = 0; $t -le 6000; $t += 250) {
      if ($t -eq 6000) { $q.Enqueue((Q "lanai-scale 175 6" 6000)) }
      Invoke-ScaleTick $ctx $t
    }
    for (; $t -le 6500; $t += 250) { Invoke-ScaleTick $ctx $t }
    Assert ([LanaiDisplay]::Sets -eq 1 -and [LanaiDisplay]::D.CurRel -eq 2) "the save applied"
    # The user picks 125% back before the next poll sees 175%.
    [LanaiDisplay]::D.CurRel = 0
    for (; $t -le 70000; $t += 250) { Invoke-ScaleTick $ctx $t }
    Assert ($ctx.State.Pick -eq 1) "pick: $($ctx.State.Pick)"
    Assert ([LanaiDisplay]::Sets -eq 1 -and [LanaiDisplay]::D.CurRel -eq 0) "the pick was undone"'
  assert_success
  assert_output ok
}

@test "guest pick rule: a display change during an unapplied request asks again at once" {
  command -v pwsh >/dev/null || skip "pwsh is not installed"
  run guest_ps '
    $s = New-ScaleState 1 5 0
    $s.Ready = $true
    $r = Step-ScaleState $s (Obs 0) $null 0
    $r = Step-ScaleState $r.State (Obs 0) (L 175 6) 1000
    Assert ($r.Action -eq "set" -and $r.Relative -eq 2) "first request"
    # Windows did not apply it; the resolution changes, the absolute step stays 125%.
    $s = $r.State
    $res = Step-ScaleState $s (Obs 0 -1 5 "2560x1440") $null 3000
    Assert ($res.Action -eq "set" -and $res.Step -eq 3 -and $res.Relative -eq 2) "resolution: $($res.Action)"
    # The recommended step moves to 150% while the current stays 125%: a new offset.
    $rec = Step-ScaleState $s (Obs -1 -2) $null 3000
    Assert ($rec.Action -eq "set" -and $rec.Step -eq 3 -and $rec.Relative -eq 1) "recommended: $($rec.Action)"
    # Without a change, it still waits a minute.
    $same = Step-ScaleState $s (Obs 0) $null 3000
    Assert ($same.Action -eq "none") "no change: $($same.Action)"'
  assert_success
  assert_output ok
}

@test "guest loop: a first line just before the wait ends is applied alone, not after the OEM step" {
  command -v pwsh >/dev/null || skip "pwsh is not installed"
  run guest_ps '
    $q = New-Object "System.Collections.Concurrent.ConcurrentQueue[object]"
    # OEM 175% (index 3); the port opened at 0, so the wait ends at 3 s.
    $ctx = New-ScaleContext (New-ScaleState 3 5 0) $q @{ OpenedAt = 0 }
    $queued = $false
    for ($t = 0; $t -le 5000; $t += 250) {
      if (-not $queued -and $t -ge 2900) { $q.Enqueue((Q "lanai-scale 200 6" 2900)); $queued = $true }
      Invoke-ScaleTick $ctx $t
    }
    Assert ([LanaiDisplay]::Sets -eq 1 -and [LanaiDisplay]::D.CurRel -eq 3) "sets: $([LanaiDisplay]::Sets), now $([LanaiDisplay]::D.CurRel)"
    # With no line at all, the fallback still comes at 3 s.
    [LanaiDisplay]::Sets = 0
    [LanaiDisplay]::D.CurRel = 0
    $ctx = New-ScaleContext (New-ScaleState 3 5 0) $q @{ OpenedAt = 0 }
    for ($t = 0; $t -le 3000; $t += 250) { Invoke-ScaleTick $ctx $t }
    Assert ([LanaiDisplay]::Sets -eq 1 -and [LanaiDisplay]::D.CurRel -eq 2) "fallback at 3 s"'
  assert_success
  assert_output ok
}

@test "guest loop: a stale batch at startup holds the OEM step back for the next fresh line" {
  command -v pwsh >/dev/null || skip "pwsh is not installed"
  run guest_ps '
    function Run($Fresh) {
      [LanaiDisplay]::Sets = 0
      [LanaiDisplay]::D.CurRel = 0
      $q = New-Object "System.Collections.Concurrent.ConcurrentQueue[object]"
      # OEM 175% (index 3); the port opened at 0, so the wait ends at 3 s.
      $ctx = New-ScaleContext (New-ScaleState 3 5 0) $q @{ OpenedAt = 0 }
      $first = -1
      for ($t = 0; $t -le 9000; $t += 250) {
        # A backlog lands at 2.8 s; its gap ends after the deadline and it is dropped.
        if ($t -eq 3000) { $q.Enqueue((Q "lanai-scale 150 4" 2800)); $q.Enqueue((Q "lanai-scale 200 6" 2800)) }
        if ($Fresh -and $t -eq 4250) { $q.Enqueue((Q "lanai-scale 200 6" 4200)) }
        Invoke-ScaleTick $ctx $t
        if ($first -lt 0 -and [LanaiDisplay]::Sets -gt 0) { $first = $t }
      }
      return @($first, [LanaiDisplay]::Sets, [LanaiDisplay]::D.CurRel)
    }
    $r = Run $true
    Assert ($r[1] -eq 1 -and $r[2] -eq 3) "fresh line: first set at $($r[0]), $($r[1]) sets, now $($r[2])"
    # With no fresh line, the OEM step still comes, a feed period later.
    $r = Run $false
    Assert ($r[1] -eq 1 -and $r[2] -eq 2 -and $r[0] -le 6000) "no fresh line: first set at $($r[0]), $($r[1]) sets, now $($r[2])"'
  assert_success
  assert_output ok
}

@test "guest loop: a display that leaves and returns on the same path makes no pick, and a pick survives it" {
  command -v pwsh >/dev/null || skip "pwsh is not installed"
  run guest_ps '
    $saved = [LanaiDisplay]::D
    $q = New-Object "System.Collections.Concurrent.ConcurrentQueue[object]"
    $ctx = New-ScaleContext (New-ScaleState 1 5 0) $q @{ OpenedAt = 0 }
    for ($t = 0; $t -le 8000; $t += 250) { Invoke-ScaleTick $ctx $t }
    # The display goes away, then comes back on the same path at 175%.
    [LanaiDisplay]::D = $null
    for (; $t -le 12000; $t += 250) { Invoke-ScaleTick $ctx $t }
    $saved.CurRel = 2
    [LanaiDisplay]::D = $saved
    for (; $t -le 20000; $t += 250) { Invoke-ScaleTick $ctx $t }
    Assert ($null -eq $ctx.State.Pick) "pick after a reattach: $($ctx.State.Pick)"
    Assert ([LanaiDisplay]::D.CurRel -eq 0) "following stopped: $([LanaiDisplay]::D.CurRel)"
    # The user picks 200% (index 4); a detach and a reset to 125% keep it.
    [LanaiDisplay]::D.CurRel = 3
    for (; $t -le 30000; $t += 250) { Invoke-ScaleTick $ctx $t }
    Assert ($ctx.State.Pick -eq 4) "the pick: $($ctx.State.Pick)"
    [LanaiDisplay]::D = $null
    for (; $t -le 34000; $t += 250) { Invoke-ScaleTick $ctx $t }
    $saved.CurRel = 0
    [LanaiDisplay]::D = $saved
    for (; $t -le 40000; $t += 250) { Invoke-ScaleTick $ctx $t }
    Assert ($ctx.State.Pick -eq 4 -and [LanaiDisplay]::D.CurRel -eq 3) "pick after a detach: $($ctx.State.Pick), now $([LanaiDisplay]::D.CurRel)"'
  assert_success
  assert_output ok
}

@test "guest pick rule: an older request applied late is not a pick, and the newer one is applied" {
  command -v pwsh >/dev/null || skip "pwsh is not installed"
  run guest_ps '
    $s = New-ScaleState 1 5 0
    $s.Ready = $true
    $r = Step-ScaleState $s (Obs 0) $null 0
    $r = Step-ScaleState $r.State (Obs 0) (L 175 6) 1000
    Assert ($r.Action -eq "set" -and $r.Step -eq 3) "first request"
    # Windows has not applied 175% when a second save asks for 200%.
    $r = Step-ScaleState $r.State (Obs 0) (L 200 7) 3000
    Assert ($r.Action -eq "set" -and $r.Step -eq 4) "second request"
    # 175% lands late, settled: not a pick, and 200% is asked for again.
    $r = Step-ScaleState $r.State (Obs 2) $null 9000
    Assert ($null -eq $r.State.Pick) "late request became pick $($r.State.Pick)"
    Assert ($r.Action -eq "set" -and $r.Step -eq 4) "newer request: $($r.Action) $($r.Step)"
    $r = Step-ScaleState $r.State (Obs 3) $null 11000
    Assert ($null -eq $r.State.Pick -and $r.Action -eq "none" -and $r.State.Confirmed -eq 4) "applied"
    # A real pick afterwards still counts.
    $r = Step-ScaleState $r.State (Obs 1) $null 17000
    Assert ($r.State.Pick -eq 2) "a later pick: $($r.State.Pick)"'
  assert_success
  assert_output ok
}

@test "guest pick rule: a decision that needs no change forgets an unapplied request" {
  command -v pwsh >/dev/null || skip "pwsh is not installed"
  run guest_ps '
    $s = New-ScaleState 1 5 0
    $s.Ready = $true
    $r = Step-ScaleState $s (Obs 0) $null 0
    # A save asks for 175% (index 3); Windows does not apply it.
    $r = Step-ScaleState $r.State (Obs 0) (L 175 6) 1000
    Assert ($r.Action -eq "set" -and $r.State.Pending -eq 3) "request"
    # The next save asks for 125%, which Windows already shows: nothing to do.
    $r = Step-ScaleState $r.State (Obs 0) (L 125 7) 3000
    Assert ($r.Action -eq "none" -and $null -eq $r.State.Pending -and @($r.State.Requested).Count -eq 0) "request kept"
    # Later the user picks 175% in Windows: a pick, not the old request landing.
    $r = Step-ScaleState $r.State (Obs 2) $null 9000
    Assert ($r.State.Pick -eq 3 -and $r.Action -eq "none") "pick: $($r.State.Pick), action $($r.Action)"'
  assert_success
  assert_output ok
}

@test "guest log: a stale batch counts its valid lines, and a malformed line is logged once" {
  command -v pwsh >/dev/null || skip "pwsh is not installed"
  run guest_ps '
    $q = New-Object "System.Collections.Concurrent.ConcurrentQueue[object]"
    $ctx = New-ScaleContext (New-ScaleState 1 5 0) $q @{ OpenedAt = 0 }
    foreach ($text in "", "lanai-scale 150 4", "", "lanai-scale 175 5", "junk") { $q.Enqueue((Q $text 1000)) }
    for ($t = 1000; $t -le 2000; $t += 250) { Invoke-ScaleTick $ctx $t }
    $q.Enqueue((Q "junk" 2100))
    $q.Enqueue((Q "lanai-scale 150 6" 2100))
    for (; $t -le 4000; $t += 250) { Invoke-ScaleTick $ctx $t }
    $all = $script:Logs -join "`n"
    Assert ($all -match "Dropped 2 lines that arrived together") "stale count: $all"
    Assert (@($script:Logs | Where-Object { $_ -match "malformed" }).Count -eq 1) "malformed logs: $all"'
  assert_success
  assert_output ok
}

@test "guest port: lines are framed across reads, CR trimmed, an oversize fragment dropped" {
  command -v pwsh >/dev/null || skip "pwsh is not installed"
  run guest_ps '
    $r = Split-PortChunk "" "lanai-sca"
    Assert (@($r.Lines).Count -eq 0 -and $r.Partial -eq "lanai-sca") "first half"
    $r = Split-PortChunk $r.Partial "le 150 3`r`n`nlanai-scale 1"
    Assert (@($r.Lines).Count -eq 2 -and $r.Lines[0] -eq "lanai-scale 150 3" -and $r.Lines[1] -eq "" -and $r.Partial -eq "lanai-scale 1") "split line: $($r.Lines -join "|") / $($r.Partial)"
    $r = Split-PortChunk "" ("x" * 300)
    Assert (@($r.Lines).Count -eq 0 -and $r.Partial -eq "") "oversize fragment"
    $r = Split-PortChunk "" ("x" * 256)
    Assert ($r.Partial.Length -eq 256) "fragment at the limit"'
  assert_success
  assert_output ok
}

@test "guest port: only error 1450 means read again later; any other read error reopens" {
  command -v pwsh >/dev/null || skip "pwsh is not installed"
  run guest_ps '
    $idle = New-Object System.IO.IOException("Insufficient system resources", -2147023446)
    Assert (Test-PortIdle $idle) "1450"
    $wrapped = New-Object System.Management.Automation.MethodInvocationException("Read failed", $idle)
    Assert (Test-PortIdle $wrapped) "wrapped 1450"
    $broken = New-Object System.IO.IOException("The device is not ready", -2147024875)
    Assert (-not (Test-PortIdle $broken)) "another error"
    Assert (-not (Test-PortIdle (New-Object System.InvalidOperationException("closed")))) "no HResult match"'
  assert_success
  assert_output ok
}

@test "guest port: the reader runspace gets the framing and error functions it calls" {
  command -v pwsh >/dev/null || skip "pwsh is not installed"
  run guest_ps '
    $ps = [PowerShell]::Create()
    $ps.AddScript("param(`$f) . ([scriptblock]::Create(`$f)); (Split-PortChunk `"a`" `"b`nc`").Lines; (Test-PortIdle `$null)").AddArgument((Get-ReaderFunctions)) | Out-Null
    $out = $ps.Invoke()
    Assert ($ps.HadErrors -eq $false -and $out[0] -eq "ab" -and $out[1] -eq $false) "runspace: $($out -join "|") $($ps.Streams.Error)"'
  assert_success
  assert_output ok
}

@test "guest port: open and read errors are logged once each, and the port opening once" {
  command -v pwsh >/dev/null || skip "pwsh is not installed"
  run guest_ps '
    $q = New-Object "System.Collections.Concurrent.ConcurrentQueue[object]"
    $shared = @{ OpenedAt = $null; PortError = "" }
    $ctx = New-ScaleContext (New-ScaleState 1 5 0) $q $shared
    $shared.PortError = "Cannot open the scale port: Access is denied."
    for ($t = 0; $t -le 4000; $t += 250) { Invoke-ScaleTick $ctx $t }
    $shared.PortError = ""
    $shared.OpenedAt = 4100
    for (; $t -le 8000; $t += 250) { Invoke-ScaleTick $ctx $t }
    $shared.PortError = "Reading the scale port failed: The device is not ready."
    for (; $t -le 12000; $t += 250) { Invoke-ScaleTick $ctx $t }
    # The reader reopens the port.
    $shared.PortError = ""
    for (; $t -le 14000; $t += 250) { Invoke-ScaleTick $ctx $t }
    $all = $script:Logs -join "`n"
    Assert (@($script:Logs | Where-Object { $_ -match "Access is denied" }).Count -eq 1) "open error: $all"
    Assert (@($script:Logs | Where-Object { $_ -match "port is open\.$" }).Count -eq 1) "opened: $all"
    Assert (@($script:Logs | Where-Object { $_ -match "not ready" }).Count -eq 1) "read error: $all"
    Assert (@($script:Logs | Where-Object { $_ -match "port is open again" }).Count -eq 1) "open again: $all"'
  assert_success
  assert_output ok
}

@test "guest loop: a SetScale that keeps failing is logged once and retried at each poll" {
  command -v pwsh >/dev/null || skip "pwsh is not installed"
  run guest_ps '
    $q = New-Object "System.Collections.Concurrent.ConcurrentQueue[object]"
    $ctx = New-ScaleContext (New-ScaleState 3 5 0) $q @{ OpenedAt = 0 }
    [LanaiDisplay]::Fail = $true
    # Ten minutes of 250 ms ticks, with the display answering each poll.
    for ($t = 0; $t -le 600000; $t += 250) { Invoke-ScaleTick $ctx $t }
    $errors = @($script:Logs | Where-Object { $_ -match "SET_DPI_SCALE" })
    Assert ($errors.Count -eq 1) "error lines: $($errors.Count)"
    # The set from 3 s on, then again at every 2 s poll, not once a minute.
    Assert ([LanaiDisplay]::Sets -ge 290) "sets: $([LanaiDisplay]::Sets)"
    # The whole log stays small: no line per retry.
    Assert ($script:Logs.Count -le 5) "log lines: $($script:Logs.Count)"'
  assert_success
  assert_output ok
}

@test "guest loop: an error is logged again after a pass in which nothing failed" {
  command -v pwsh >/dev/null || skip "pwsh is not installed"
  run guest_ps '
    $saved = [LanaiDisplay]::D
    $q = New-Object "System.Collections.Concurrent.ConcurrentQueue[object]"
    $ctx = New-ScaleContext (New-ScaleState 1 5 0) $q @{ OpenedAt = 0 }
    [LanaiDisplay]::D = $null
    for ($t = 0; $t -le 6000; $t += 250) { Invoke-ScaleTick $ctx $t }
    [LanaiDisplay]::D = $saved
    for (; $t -le 10000; $t += 250) { Invoke-ScaleTick $ctx $t }
    [LanaiDisplay]::D = $null
    for (; $t -le 16000; $t += 250) { Invoke-ScaleTick $ctx $t }
    $errors = @($script:Logs | Where-Object { $_ -match "Found 0" })
    Assert ($errors.Count -eq 2) "error lines: $($errors.Count)"'
  assert_success
  assert_output ok
}

@test "guest loop: a port that opens at 4 s brings the fallback to 5 s, not 7 s" {
  command -v pwsh >/dev/null || skip "pwsh is not installed"
  run guest_ps '
    $q = New-Object "System.Collections.Concurrent.ConcurrentQueue[object]"
    $shared = @{ OpenedAt = $null; PortError = "" }
    $ctx = New-ScaleContext (New-ScaleState 3 5 0) $q $shared
    $first = -1
    for ($t = 0; $t -le 8000; $t += 250) {
      if ($t -eq 4000) { $shared.OpenedAt = 4000 }
      Invoke-ScaleTick $ctx $t
      if ($first -lt 0 -and [LanaiDisplay]::Sets -gt 0) { $first = $t }
    }
    Assert ($first -eq 5000) "first set at $first"'
  assert_success
  assert_output ok
}

@test "guest OEM baseline: the step and save number from the OEM strings" {
  command -v pwsh >/dev/null || skip "pwsh is not installed"
  run guest_ps '
    $b = Get-OemBaseline @("Dell", "lanai-scale=175", "lanai-scale-save=12")
    Assert ($b.Scale -eq 175 -and $b.Save -eq 12) "both"
    $b = Get-OemBaseline @("lanai-scale=150")
    Assert ($b.Scale -eq 150 -and $null -eq $b.Save) "no save"
    foreach ($bad in "lanai-scale-save=1x", "lanai-scale-save=1234567890", "lanai-scale-save=") {
      $b = Get-OemBaseline @("lanai-scale=150", $bad)
      Assert ($b.Scale -eq 150 -and $null -eq $b.Save) "bad save [$bad]"
    }
    Assert ($null -eq (Get-OemBaseline @("lanai-scale-save=3", "other"))) "no lanai-scale"
    Assert ($null -eq (Get-OemBaseline @())) "no strings"
    $threw = $false
    try { Get-OemBaseline @("lanai-scale=1x") | Out-Null } catch { $threw = $true }
    Assert $threw "bad scale"'
  assert_success
  assert_output ok
}

@test "guest display: the real observation picks the Looking Glass path and reads its fields" {
  command -v pwsh >/dev/null || skip "pwsh is not installed"
  PS1=$REPO/guest/lanai-scale.ps1 run pwsh -NoProfile -NonInteractive -Command '
    $ErrorActionPreference = "Stop"
    class LanaiDisplay {
      static [object[]] $Paths = @()
      static [object[]] ActivePaths() { return [LanaiDisplay]::Paths }
      static [object] GetTargetName([object] $p) { return [pscustomobject]@{ monitorFriendlyDeviceName = $p.Name; monitorDevicePath = $p.Device } }
      static [string] Resolution([object] $p) { return $p.Res }
      static [object] GetScale([object] $p) { return [pscustomobject]@{ minScaleRel = -2; curScaleRel = 1; maxScaleRel = 4 } }
    }
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($env:PS1, [ref]$null, [ref]$null)
    $f = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq "Get-DisplayObservation" }, $true) | Select-Object -First 1
    . ([scriptblock]::Create($f.Extent.Text))
    function Assert($Ok, $Why) { if (-not $Ok) { throw "failed: $Why" } }
    $other = [pscustomobject]@{ Name = "DELL U2720Q"; Device = "\\?\DISPLAY#DEL1"; Res = "3840x2160" }
    $lg = [pscustomobject]@{ Name = ""; Device = "\\?\SWD#LGIDD#1"; Res = "2560x1440" }
    [LanaiDisplay]::Paths = @($other, $lg)
    $o = Get-DisplayObservation
    Assert ($o.Path -eq $lg -and $o.DevicePath -eq "\\?\SWD#LGIDD#1" -and $o.Resolution -eq "2560x1440") "LG among two"
    Assert ($o.MinRel -eq -2 -and $o.CurRel -eq 1 -and $o.MaxRel -eq 4 -and $o.Recommended -eq 2 -and $o.Current -eq 3) "range"
    # One display that does not name Looking Glass: the only one counts.
    [LanaiDisplay]::Paths = @($other)
    Assert ((Get-DisplayObservation).Resolution -eq "3840x2160") "single path"
    [LanaiDisplay]::Paths = @()
    $threw = $false
    try { Get-DisplayObservation | Out-Null } catch { $threw = $_.Exception.Message -match "Found 0" }
    Assert $threw "none"
    [LanaiDisplay]::Paths = @($other, ([pscustomobject]@{ Name = "Generic"; Device = "x"; Res = "1x1" }))
    $threw = $false
    try { Get-DisplayObservation | Out-Null } catch { $threw = $true }
    Assert $threw "two without Looking Glass"
    "ok"'
  assert_success
  assert_output ok
}

@test "guest loop: a late display is logged once, then set; a failed log never stops a set" {
  command -v pwsh >/dev/null || skip "pwsh is not installed"
  run guest_ps '
    $q = New-Object "System.Collections.Concurrent.ConcurrentQueue[object]"
    $ctx = New-ScaleContext (New-ScaleState 3 5 0) $q @{ OpenedAt = 0 }
    [LanaiDisplay]::D = $null
    for ($t = 0; $t -le 8000; $t += 250) { Invoke-ScaleTick $ctx $t }
    Assert (@($script:Logs | Where-Object { $_ -match "^Error" }).Count -eq 1 -and ($script:Logs -join "|") -match "Found 0") "one error line: $($script:Logs -join "|")"
    [LanaiDisplay]::D = @{ DevicePath = "lg"; Resolution = "1920x1080"; MinRel = -1; CurRel = 0; MaxRel = 5 }
    for (; $t -le 10000; $t += 250) { Invoke-ScaleTick $ctx $t }
    Assert ([LanaiDisplay]::Sets -eq 1 -and [LanaiDisplay]::D.CurRel -eq 2) "late display set"
    $polls = [LanaiDisplay]::Polls
    for (; $t -le 20000; $t += 250) { Invoke-ScaleTick $ctx $t }
    Assert ([LanaiDisplay]::Sets -eq 1 -and [LanaiDisplay]::Polls -gt $polls) "unchanged polls set nothing"
    function Write-Log($Message) { throw "the log is full" }
    $q.Enqueue((Q "lanai-scale 250 6" $t))
    for ($i = 0; $i -lt 4; $i++) { $t += 250; Invoke-ScaleTick $ctx $t }
    Assert ([LanaiDisplay]::Sets -eq 2 -and [LanaiDisplay]::D.CurRel -eq 5) "a failed log stopped the set"'
  assert_success
  assert_output ok
}

@test "guest log: a capped target is logged once per target, step and resolution, and again after an uncapped pass" {
  command -v pwsh >/dev/null || skip "pwsh is not installed"
  run guest_ps '
    $q = New-Object "System.Collections.Concurrent.ConcurrentQueue[object]"
    # Lanai wants 175% (index 3); Windows allows at most 150% here, and 150%
    # is already applied.
    [LanaiDisplay]::D = @{ DevicePath = "lg"; Resolution = "1901x1046"; MinRel = -1; CurRel = 1; MaxRel = 1 }
    $ctx = New-ScaleContext (New-ScaleState 3 5 0) $q @{ OpenedAt = 0 }
    function Caps { @($script:Logs | Where-Object { $_ -like "Windows allows*" }) }
    for ($t = 0; $t -le 4000; $t += 250) { Invoke-ScaleTick $ctx $t }
    Assert ([LanaiDisplay]::Sets -eq 0) "capped and applied: $([LanaiDisplay]::Sets) sets"
    Assert (@(Caps).Count -eq 1 -and @(Caps)[0] -eq "Windows allows at most 150% at 1901x1046; using 150% until the window grows (target 175%).") "first: $(Caps)"
    for (; $t -le 12000; $t += 250) { Invoke-ScaleTick $ctx $t }
    Assert (@(Caps).Count -eq 1) "unchanged passes: $(Caps)"
    # A new resolution with the same cap.
    [LanaiDisplay]::D.Resolution = "1724x1045"
    for (; $t -le 16000; $t += 250) { Invoke-ScaleTick $ctx $t }
    Assert (@(Caps).Count -eq 2 -and @(Caps)[1] -match "at 1724x1045;") "new resolution: $(Caps)"
    # The window grows: 175% applies, no cap.
    [LanaiDisplay]::D.Resolution = "3816x2106"; [LanaiDisplay]::D.MaxRel = 5
    for (; $t -le 20000; $t += 250) { Invoke-ScaleTick $ctx $t }
    Assert ([LanaiDisplay]::Sets -eq 1 -and [LanaiDisplay]::D.CurRel -eq 2 -and @(Caps).Count -eq 2) "uncapped: $(Caps)"
    # It shrinks again, and Windows falls back to 125%: capped, with a set.
    [LanaiDisplay]::D.Resolution = "1724x1045"; [LanaiDisplay]::D.MaxRel = 1; [LanaiDisplay]::D.CurRel = 0
    for (; $t -le 24000; $t += 250) { Invoke-ScaleTick $ctx $t }
    Assert ([LanaiDisplay]::Sets -eq 2 -and [LanaiDisplay]::D.CurRel -eq 1) "capped set: $([LanaiDisplay]::Sets)"
    Assert (@(Caps).Count -eq 3 -and @(Caps)[2] -match "at 1724x1045;") "after an uncapped pass: $(Caps)"
    # A save of 200% while capped names the new target.
    $q.Enqueue((Q "lanai-scale 200 6" $t))
    for ($i = 0; $i -lt 4; $i++) { $t += 250; Invoke-ScaleTick $ctx $t }
    Assert (@(Caps).Count -eq 4 -and @(Caps)[3] -match "\(target 200%\)\.$") "new target: $(Caps)"'
  assert_success
  assert_output ok
}

@test "guest log: a current scale out of Windows' range is logged once, and again after an in-range pass" {
  command -v pwsh >/dev/null || skip "pwsh is not installed"
  run guest_ps '
    $q = New-Object "System.Collections.Concurrent.ConcurrentQueue[object]"
    # Custom scaling: Windows reports a value outside its range and ignores sets.
    [LanaiDisplay]::D = @{ DevicePath = "lg"; Resolution = "1920x1080"; MinRel = -1; CurRel = 1234568; MaxRel = 5 }
    [LanaiDisplay]::Apply = $false
    $ctx = New-ScaleContext (New-ScaleState 3 5 0) $q @{ OpenedAt = 0 }
    function Customs { @($script:Logs | Where-Object { $_ -like "Windows reports*" }) }
    for ($t = 0; $t -le 20000; $t += 250) { Invoke-ScaleTick $ctx $t }
    Assert (@(Customs).Count -eq 1 -and @(Customs)[0] -eq "Windows reports the current scale out of range (curScaleRel 1234568). Custom scaling is probably on (Settings > System > Display); Lanai'"'"'s scale has no effect until it is off.") "first: $(Customs)"
    Assert ([LanaiDisplay]::Sets -ge 1) "the task still tries to set"
    # The ends of the range are in range.
    foreach ($cur in -1, 5) {
      [LanaiDisplay]::D.CurRel = $cur
      for ($i = 0; $i -lt 8; $i++) { $t += 250; Invoke-ScaleTick $ctx $t }
    }
    Assert (@(Customs).Count -eq 1) "in range: $(Customs)"
    # Below minScaleRel counts too.
    [LanaiDisplay]::D.CurRel = -3
    for ($i = 0; $i -lt 40; $i++) { $t += 250; Invoke-ScaleTick $ctx $t }
    Assert (@(Customs).Count -eq 2 -and @(Customs)[1] -match "\(curScaleRel -3\)") "below: $(Customs)"'
  assert_success
  assert_output ok
}

@test "guest pick rule: an out-of-range current that moves at a settled resolution makes no pick and no throw" {
  command -v pwsh >/dev/null || skip "pwsh is not installed"
  run guest_ps '
    # Custom scaling: Windows reports values outside its range, and they move.
    $r = Step-ScaleState (New-ScaleState 3 5 0) (Obs 1234568) $null 0
    foreach ($step in @(@(-3, 6000), @(1234569, 12000), @(-40, 18000))) {
      $r = Step-ScaleState $r.State (Obs $step[0]) $null $step[1]
      Assert ($null -eq $r.State.Pick) "curScaleRel $($step[0]) made pick $($r.State.Pick)"
      Assert ($r.Action -ne "none" -and $r.Step -eq 3) "curScaleRel $($step[0]): action $($r.Action), step $($r.Step)"
    }
    # An in-list change after it is still a pick.
    $r = Step-ScaleState $r.State (Obs 3) $null 24000
    Assert ($r.State.Pick -eq 4) "in-list pick: $($r.State.Pick)"'
  assert_success
  assert_output ok
}

@test "guest exit: an exit line the log already ends with is not added again" {
  command -v pwsh >/dev/null || skip "pwsh is not installed"
  run guest_ps '
    # The real Write-Log, writing to a scratch log that does not exist yet.
    $LogFile = Join-Path ([IO.Path]::GetTempPath()) "lanai-exit-$PID.log"
    Remove-Item -LiteralPath $LogFile -ErrorAction SilentlyContinue
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($env:PS1, [ref]$null, [ref]$null)
    $f = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq "Write-Log" }, $false) | Select-Object -First 1
    . ([scriptblock]::Create($f.Extent.Text))
    function Count { @(Get-Content -LiteralPath $LogFile).Count }
    $none = "No lanai-scale OEM string; the scale stays as it is."
    Write-ExitLog $none | Out-Null
    Write-ExitLog $none | Out-Null
    Assert ((Count) -eq 1) "same twice: $(Count)"
    Write-ExitLog "Error: Bad OEM string: lanai-scale=1x" | Out-Null
    Write-ExitLog "Error: Bad OEM string: lanai-scale=1x" | Out-Null
    Assert ((Count) -eq 2) "a different one: $(Count)"
    Write-ExitLog "Error: Bad OEM string: lanai-scale=2x" | Out-Null
    Write-ExitLog $none | Out-Null
    Assert ((Count) -eq 4) "changed again: $(Count)"
    # Only the last line counts, and only its whole message.
    Write-Log "The scale port is open." | Out-Null
    Write-ExitLog $none | Out-Null
    Write-ExitLog "the scale stays as it is." | Out-Null
    Assert ((Count) -eq 7) "after another line: $(Count)"
    # A run by hand still sees the message.
    Assert ((Write-ExitLog "the scale stays as it is.") -eq "the scale stays as it is.") "console"
    Remove-Item -LiteralPath $LogFile'
  assert_success
  assert_output ok
}

@test "lanai-scale.ps1: both exit paths log through Write-ExitLog" {
  local f=$REPO/guest/lanai-scale.ps1
  run grep -cE '^[[:space:]]*Write-ExitLog ' "$f"
  assert_output 2
  run grep -F "Write-ExitLog 'No lanai-scale OEM string; the scale stays as it is.'" "$f"
  assert_success
  run grep -F 'Write-ExitLog "Error: $($_.Exception.Message)"' "$f"
  assert_success
}

@test "lanai-scale.ps1: pins its module path and temp folder before the first cmdlet or Add-Type" {
  local f=$REPO/guest/lanai-scale.ps1 first pins
  # The first line that runs a cmdlet (Verb-Noun) or Add-Type, outside the
  # functions and the comment block.
  first=$(awk '/^<#/,/^#>/ { next } /^(function|\$ReaderScript)/ { skip = 1 } skip && /^}/ { skip = 0; next }
    !skip && /^[^#]*(Add-Type|[A-Z][a-z]+-[A-Z][A-Za-z]+)/ { print NR; exit }' "$f")
  pins=$(grep -nE '^\$env:(PSModulePath|TMP|TEMP) = ' "$f" | cut -d: -f1 | sort -n | tail -n 1)
  [[ -n $first && -n $pins ]] || fail "first $first, pins $pins"
  ((pins < first)) || fail "the env pins end on line $pins, after line $first"
  run grep -E '^\$env:(PSModulePath|TMP|TEMP) = ' "$f"
  assert_line "\$env:TMP = 'C:\Program Files\Lanai\tmp'"
  assert_line "\$env:TEMP = 'C:\Program Files\Lanai\tmp'"
  assert_line --partial '$env:PSModulePath = "$([Environment]::SystemDirectory)\WindowsPowerShell\v1.0\Modules;C:\Program Files\WindowsPowerShell\Modules"'
  run grep -F "\$LogFile = 'C:\Program Files\Lanai\lanai-scale.log'" "$f"
  assert_success
  # Nothing under the user's profile.
  run grep -iE 'LOCALAPPDATA|APPDATA|USERPROFILE' "$f"
  assert_failure
}

@test "setup scale task: elevated, one task by name, no execution limit, duplicates ignored, restarts" {
  run setup_code
  assert_output --partial "New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew;"
  assert_output --partial '-Settings $s'
  # The sign-in trigger repeats every 5 minutes with no end, so a task that
  # died comes back (IgnoreNew makes a start a no-op while it runs).
  # RestartCount covers only a failed start (phase C), so it is gone.
  assert_output --partial "\$t = New-ScheduledTaskTrigger -AtLogOn -User \$u; \$r = Get-CimClass -Namespace 'Root/Microsoft/Windows/TaskScheduler' -ClassName 'MSFT_TaskRepetitionPattern' | New-CimInstance -ClientOnly; \$r.Interval = 'PT5M'; \$t.Repetition = \$r;"
  refute_output --partial 'Duration'
  refute_output --partial 'StopAtDurationEnd'
  refute_output --partial 'RestartCount'
  refute_output --partial 'RestartInterval'
  assert_output --partial "New-ScheduledTaskPrincipal -UserId \$u -LogonType Interactive -RunLevel Highest"
  # The task belongs to the SID the elevated stage verified, by an
  # environment variable (as LANAI_IDD is), not to a name from the
  # environment.
  assert_output --partial "\$u = \$env:LANAI_TASK_SID;"
  refute_output --partial 'USERDOMAIN'
  local sid task
  sid=$(line_is 'set "LANAI_TASK_SID=%HAVE_SID%"')
  task=$(line_of 'Register-ScheduledTask')
  ((sid + 1 == task)) || fail "SID line $sid, task line $task"
  assert_output --partial "Register-ScheduledTask -TaskName 'Lanai display scale' -Action \$a -Trigger \$t -Principal \$p -Settings \$s -Force"
  # powershell.exe by absolute path, from the system folder Windows reports
  # (not an environment variable the user can set).
  assert_output --partial "New-ScheduledTaskAction -Execute ([Environment]::SystemDirectory + '\WindowsPowerShell\v1.0\powershell.exe')"
  refute_output --partial '%SystemRoot%'
  run grep -c 'Register-ScheduledTask' "$SETUP_CMD"
  assert_output 1
  run cat "$REPO/guest/lanai-scale.ps1"
  assert_output --partial 'Start-Sleep -Milliseconds 250'
}

@test "setup.cmd: creates the task's tmp folder under C:\\Program Files\\Lanai before the task" {
  local lanai tmp task
  lanai=$(line_is 'mkdir "C:\Program Files\Lanai"')
  tmp=$(line_is 'mkdir "C:\Program Files\Lanai\tmp"')
  task=$(line_of 'Register-ScheduledTask')
  ((lanai < tmp && tmp < task)) || fail "Lanai $lanai, tmp $tmp, task $task"
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
  # The applying line names the raw values and goes to the log.
  run grep -E -A3 'raw minScaleRel.*curScaleRel.*maxScaleRel' "$f"
  assert_output --partial 'Write-Log $text'
}

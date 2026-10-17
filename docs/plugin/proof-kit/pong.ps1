# pong.ps1: resize phase G. The guest side of clock-ping. Watches ping.txt
# beside this script (polling every 10 ms) and writes each new line back to
# pong.txt with Windows' time appended (ISO 8601). Stops after 10 pongs or
# 60 s. Run: powershell -NoProfile -ExecutionPolicy Bypass -File <share>\lanai-proof\pong.ps1
# The line already in ping.txt at the start is the last run's, so it gets no pong.
$ErrorActionPreference = 'Stop'
$ping = Join-Path $PSScriptRoot 'ping.txt'
$pong = Join-Path $PSScriptRoot 'pong.txt'
$last = ''
try { $last = (Get-Content -LiteralPath $ping -Raw -ErrorAction Stop).Trim() } catch { }
$count = 0
$until = (Get-Date).AddSeconds(60)
while ($count -lt 10 -and (Get-Date) -lt $until) {
    $line = $null
    try { $line = (Get-Content -LiteralPath $ping -Raw -ErrorAction Stop).Trim() } catch { }
    if ($line -and $line -ne $last) {
        Add-Content -LiteralPath $pong -Value ('{0} {1}' -f $line, (Get-Date -Format o))
        $last = $line
        $count++
    }
    Start-Sleep -Milliseconds 10
}
"Sent $count pongs."

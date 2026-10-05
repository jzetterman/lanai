# scroll.ps1: send one key chord at a fixed rate to the focused window, for the
# lgtest spike (docs/spike/plan.md). The input comes from inside the guest, so
# it is identical under Looking Glass and RDP.
#
# Example, 10 Page Downs per second for 10 s after a 3 s delay to click into Excel:
#   powershell -ExecutionPolicy Bypass -File $HOME\Desktop\scroll.ps1 -Keys '{PGDN}' -Rate 10 -Seconds 10 -Delay 3
param(
    [Parameter(Mandatory = $true)][string]$Keys,
    [double]$Rate = 10,
    [double]$Seconds = 10,
    [double]$Delay = 3
)

Add-Type -AssemblyName System.Windows.Forms

$count = [int][math]::Floor($Rate * $Seconds)
Start-Sleep -Milliseconds ([int]($Delay * 1000))

# Key i goes out at start + i/Rate. Sleep only the time left, so the 15.6 ms
# timer tick does not drift the rate. SendWait, because Send throws in a console.
$watch = [System.Diagnostics.Stopwatch]::StartNew()
for ($i = 0; $i -lt $count; $i++) {
    $due = $i * 1000.0 / $Rate
    $left = $due - $watch.Elapsed.TotalMilliseconds
    if ($left -gt 0) { Start-Sleep -Milliseconds ([int][math]::Ceiling($left)) }
    [System.Windows.Forms.SendKeys]::SendWait($Keys)
}
$elapsed = $watch.Elapsed.TotalSeconds

# Rate over the intervals between the first and last key.
$achieved = if ($count -gt 1 -and $elapsed -gt 0) { ($count - 1) / $elapsed } else { 0 }
"keys sent: {0}; achieved rate: {1:N2}/s (target {2}/s)" -f $count, $achieved, $Rate

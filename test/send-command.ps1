# Sends steps to RMG running a game's "serve" test (.\test\run-tests.ps1 -Game <game> -Serve), waits for them to
# finish, and prints what they logged. Steps are as in runSteps() in the game's test file (test/mp1test.d and so on),
# e.g.:
#
#   .\test\send-command.ps1 "load:TestStates/mp1-setup-map.st A wait200 shot"
#   .\test\send-command.ps1 -Game mp2 "test:teamDuels"
#   .\test\send-command.ps1 quit
param(
    [Parameter(Mandatory, Position = 0)][string]$Steps,
    [ValidateSet("mp1", "mp2", "mp3")][string]$Game = "mp1",
    [string]$Rmg = "C:\Users\timzi\Code\RMG-Test",
    [int]$TimeoutSeconds = 600
)

$ErrorActionPreference = "Stop"
$log = Join-Path $Rmg (Get-Content "$Rmg\TestCommands\$Game-log.txt" -Raw).Trim()
$id = [guid]::NewGuid().ToString("N").Substring(0, 8)

# RMG may still be starting: wait for the serve test to say it's ready
$deadline = (Get-Date).AddSeconds(60)
while (-not ((Test-Path $log) -and (Select-String -Path $log -Pattern "READY" -Quiet))) {
    if ((Get-Date) -gt $deadline) { throw "RMG isn't serving (no READY in $log)" }
    Start-Sleep -Milliseconds 250
}
$before = @(Get-Content $log).Count

Set-Content "$Rmg\TestCommands\$Game.txt" "# $id`n$Steps"

$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
while ((Get-Date) -lt $deadline) {
    $lines = @(Get-Content $log)
    if ($lines | Select-Object -Skip $before | Where-Object { $_ -match "READY $id|DONE " }) { break }
    if ($Steps.Trim() -eq "quit" -and ($lines | Select-Object -Skip $before | Where-Object { $_ -match "COMMAND $id" })) { break }
    Start-Sleep -Milliseconds 250
}
Get-Content $log | Select-Object -Skip $before

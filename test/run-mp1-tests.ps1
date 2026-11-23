# Runs the Mario Party 1 tests (test/mp1test.d) in the test copy of RMG and prints the results.
#
#   .\test\run-mp1-tests.ps1                      # every test
#   .\test\run-mp1-tests.ps1 -Tests smoke,bonusStars
#   .\test\run-mp1-tests.ps1 -Serve                # keeps RMG open for test\send-mp1-command.ps1
#
# It builds the test plugin (dub build -c mp1-test), copies it and the config into the test RMG, and runs RMG on the
# ROM. The test plugin stops the emulator when the tests finish; the log is in TestLogs\ in the test RMG.
param(
    [string[]]$Tests = @(),
    [string]$Config = "$PSScriptRoot\mp1-config.json",
    [string]$Rmg = "C:\Users\timzi\Code\RMG-Test",
    [string]$Rom = "R:\ROMs\N64\Mario Party (U) [!].z64",
    [int]$TimeoutMinutes = 60,
    [string]$Arg = "",
    [switch]$NoBuild,
    [switch]$DebugBuild, # Keep array bounds checks and asserts (slower)
    [switch]$Serve       # Start RMG with the "serve" test and return, for test\send-mp1-command.ps1
)

$ErrorActionPreference = "Stop"
$repo = Split-Path $PSScriptRoot -Parent

if (-not $NoBuild) {
    Push-Location $repo
    $ErrorActionPreference = "Continue" # dub writes its normal output to stderr
    try {
        $buildType = if ($DebugBuild) { "debug" } else { "release" }
        dub build --build=$buildType -c mp1-test 2>&1 | Out-Host
        if ($LASTEXITCODE -ne 0) { throw "The test plugin didn't build" }
    } finally {
        Pop-Location
        $ErrorActionPreference = "Stop"
    }
}

Copy-Item "$repo\test-build\MarioParty1.dll" "$Rmg\Plugin\Execution\MarioParty1.dll" -Force
Copy-Item $Config "$Rmg\MarioParty.json" -Force
New-Item -ItemType Directory -Force "$Rmg\TestLogs" | Out-Null
New-Item -ItemType Directory -Force "$Rmg\TestCommands" | Out-Null
if ($Serve) { $Tests = @("serve") }

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$log = "TestLogs\mp1-$stamp.log"
$env:N64TEST = ($Tests -join ",")
$env:N64TEST_LOG = $log
$env:N64TEST_ARG = $Arg

# The plugin keeps a backup of its State in %APPDATA%\N64-Game-Plugins: give the test RMG its own, so tests never
# touch the real plugin's files (and always start from the test folder's)
$env:APPDATA = "$Rmg\AppData"
New-Item -ItemType Directory -Force "$Rmg\AppData" | Out-Null

# RMG runs portable (portable.txt), so its paths are relative to the folder it starts in
$process = Start-Process -FilePath "$Rmg\RMG.exe" -ArgumentList @("--debug-messages", "--quit-after-emulation", "`"$Rom`"") `
    -WorkingDirectory $Rmg -PassThru -RedirectStandardOutput "$Rmg\TestLogs\mp1-$stamp.out"
if ($Serve) {
    Set-Content "$Rmg\TestCommands\mp1-log.txt" $log # For send-mp1-command.ps1
    Write-Host "Serving; log: $Rmg\$log"
    return
}
if (-not $process.WaitForExit($TimeoutMinutes * 60 * 1000)) {
    Stop-Process -Id $process.Id -Force
    Write-Warning "RMG didn't finish in $TimeoutMinutes minutes and was stopped"
}

Get-Content "$Rmg\$log"
Write-Host "Log: $Rmg\$log"

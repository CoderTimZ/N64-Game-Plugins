# Runs a game's tests (test/mp1test.d, test/mp2test.d, test/mp3test.d) in the test copy of RMG and prints the
# results.
#
#   .\test\run-tests.ps1                              # every Mario Party 1 test
#   .\test\run-tests.ps1 -Tests smoke,bonusStars
#   .\test\run-tests.ps1 -Game mp2 -Tests teamDuels
#   .\test\run-tests.ps1 -Game mp3 -Tests singleUseBattleSpaces -Config test\mp3-config-lucky.json
#   .\test\run-tests.ps1 -Game mp2 -Serve             # keeps RMG open for test\send-command.ps1
#
# It builds the game's test plugin (dub build -c <game>-test), copies it and the config into the test RMG, and runs RMG
# on the game's ROM. The test plugin stops the emulator when the tests finish; the log is in TestLogs\ in the test RMG.
param(
    [ValidateSet("mp1", "mp2", "mp3")][string]$Game = "mp1",
    [string[]]$Tests = @(),
    [string]$Config = "",
    [string]$Rmg = "C:\Users\timzi\Code\RMG-Test",
    [string]$Rom = "",
    [int]$TimeoutMinutes = 60,
    [string]$Arg = "",
    [switch]$NoBuild,
    [switch]$DebugBuild, # Keep array bounds checks and asserts (slower)
    [switch]$Serve       # Start RMG with the "serve" test and return, for test\send-command.ps1
)

$ErrorActionPreference = "Stop"
$repo = Split-Path $PSScriptRoot -Parent
$plugin = @{ mp1 = "MarioParty1"; mp2 = "MarioParty2"; mp3 = "MarioParty3" }[$Game]
$configName = @{ mp1 = "MarioParty"; mp2 = "MarioParty2"; mp3 = "MarioParty3" }[$Game] # The plugin reads <ROM name>.json
if (-not $Config) { $Config = "$PSScriptRoot\$Game-config.json" }
if (-not $Rom) {
    $Rom = @{
        mp1 = "R:\ROMs\N64\Mario Party (U) [!].z64"
        mp2 = "R:\ROMs\N64\Mario Party 2 (U) [!].z64"
        mp3 = "R:\ROMs\N64\Mario Party 3 (U) [!].z64"
    }[$Game]
}

if (-not $NoBuild) {
    Push-Location $repo
    $ErrorActionPreference = "Continue" # dub writes its normal output to stderr
    try {
        $buildType = if ($DebugBuild) { "debug" } else { "release" }
        dub build --build=$buildType -c "$Game-test" 2>&1 | Out-Host
        if ($LASTEXITCODE -ne 0) { throw "The test plugin didn't build" }
    } finally {
        Pop-Location
        $ErrorActionPreference = "Stop"
    }
}

Copy-Item "$repo\test-bin\$plugin.dll" "$Rmg\Plugin\Execution\$plugin.dll" -Force
Copy-Item $Config "$Rmg\$configName.json" -Force
New-Item -ItemType Directory -Force "$Rmg\TestLogs" | Out-Null
New-Item -ItemType Directory -Force "$Rmg\TestCommands" | Out-Null
if ($Serve) { $Tests = @("serve") }

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$log = "TestLogs\$Game-$stamp.log"
$env:N64TEST = ($Tests -join ",")
$env:N64TEST_LOG = $log
$env:N64TEST_ARG = $Arg

# The plugin keeps a backup of its State in %APPDATA%\N64-Game-Plugins: give the test RMG its own, so tests never
# touch the real plugin's files (and always start from the test folder's)
$env:APPDATA = "$Rmg\AppData"
New-Item -ItemType Directory -Force "$Rmg\AppData" | Out-Null

# RMG shouldn't take the focus or cover other windows: tests get their input from the test plugin, and RMG keeps running
# without the focus (PauseEmulationOnFocusLoss is off). Once its window shows, it goes behind the others, and the
# window that had the focus gets it back.
Add-Type -Namespace Win32 -Name Window -MemberDefinition @'
[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr window);
[DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr window, IntPtr after, int x, int y, int width, int height, uint flags);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr window, IntPtr process);
[DllImport("user32.dll")] public static extern bool AttachThreadInput(uint thread, uint to, bool attach);
[DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
'@
$focused = [Win32.Window]::GetForegroundWindow()

# RMG runs portable (portable.txt), so its paths are relative to the folder it starts in
$process = Start-Process -FilePath "$Rmg\RMG.exe" -ArgumentList @("--debug-messages", "--quit-after-emulation", "`"$Rom`"") `
    -WorkingDirectory $Rmg -PassThru -RedirectStandardOutput "$Rmg\TestLogs\$Game-$stamp.out" `
    -RedirectStandardError "$Rmg\TestLogs\$Game-$stamp.err"

$deadline = (Get-Date).AddSeconds(20)
while ($process.MainWindowHandle -eq 0 -and -not $process.HasExited -and (Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 100
    $process.Refresh()
}
$window = $process.MainWindowHandle
if ($window -ne 0) {
    # Checked for a moment, in case Windows activates it just after it shows
    foreach ($i in 1..10) {
        [Win32.Window]::SetWindowPos($window, [IntPtr]1, 0, 0, 0, 0, 0x13) | Out-Null # HWND_BOTTOM; no size, move, activation
        if ($focused -ne 0 -and [Win32.Window]::GetForegroundWindow() -eq $window) {
            # Only the foreground window's thread may hand the focus on: share its input state for the call
            $rmgThread = [Win32.Window]::GetWindowThreadProcessId($window, [IntPtr]::Zero)
            $thread = [Win32.Window]::GetCurrentThreadId()
            [Win32.Window]::AttachThreadInput($thread, $rmgThread, $true) | Out-Null
            [Win32.Window]::SetForegroundWindow($focused) | Out-Null
            [Win32.Window]::AttachThreadInput($thread, $rmgThread, $false) | Out-Null
        }
        Start-Sleep -Milliseconds 100
    }
}

if ($Serve) {
    Set-Content "$Rmg\TestCommands\$Game-log.txt" $log # For send-command.ps1
    Write-Host "Serving; log: $Rmg\$log"
    return
}
if (-not $process.WaitForExit($TimeoutMinutes * 60 * 1000)) {
    Stop-Process -Id $process.Id -Force
    Write-Warning "RMG didn't finish in $TimeoutMinutes minutes and was stopped"
}

Get-Content "$Rmg\$log"
$errors = Get-Content "$Rmg\TestLogs\$Game-$stamp.err" -ErrorAction SilentlyContinue
if ($errors) { Write-Host "RMG's error output:"; $errors | Out-Host }
Write-Host "Log: $Rmg\$log"

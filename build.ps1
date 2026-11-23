<#
.SYNOPSIS
Builds the N64 game plugins with dub, on Windows (or anywhere with PowerShell). build.cmd runs it from cmd or a .bat
file, and build.sh does the same from a POSIX shell.

.DESCRIPTION
Builds the plugins with dub (release builds by default) into bin\: MarioParty1.dll on Windows, libMarioParty1.so on
Linux, libMarioParty1.dylib on macOS.

Requires a D compiler with a recent dub, such as the official ones from https://dlang.org/download.html (some Linux
distributions ship a dub too old for vibe.d's packages).

.PARAMETER Plugins
The plugins to build (default: all): mp1 (Mario Party 1), mp2 (Mario Party 2), mp3 (Mario Party 3), mg64 (Mario Golf
64).

.PARAMETER Configuration
Release (the default) or Debug. Debug builds keep array bounds checks and asserts.

.PARAMETER InstallDir
Also copy the built plugins into this folder, such as an emulator's execution plugin folder.

.PARAMETER Compiler
The D compiler for dub to use (dmd, ldc2, gdc).

.EXAMPLE
.\build.ps1

.EXAMPLE
.\build.ps1 mp2 mp3 -Configuration Debug

.EXAMPLE
build.cmd mp1 -InstallDir C:\RMG\Plugin\Execution

.EXAMPLE
.\build.ps1 -InstallDir C:\RMG\Plugin\Execution
#>
[CmdletBinding()]
param(
    # Space-separated like build.sh's (.\build.ps1 mp1 mp2), which also works through build.cmd, or a PowerShell list
    [Parameter(Position = 0, ValueFromRemainingArguments)]
    [ValidateSet("mp1", "mp2", "mp3", "mg64")]
    [string[]]$Plugins = @("mp1", "mp2", "mp3", "mg64"),

    [ValidateSet("Release", "Debug")]
    [string]$Configuration = "Release",

    [string]$InstallDir = "",

    [string]$Compiler = ""
)

$ErrorActionPreference = "Stop"

$targetNames = @{ mp1 = "MarioParty1"; mp2 = "MarioParty2"; mp3 = "MarioParty3"; mg64 = "MarioGolf64" }

if (-not (Get-Command dub -ErrorAction SilentlyContinue)) {
    throw "dub isn't on the PATH (it comes with the D compilers: https://dlang.org/download.html)"
}
if ($InstallDir -and -not (Test-Path $InstallDir -PathType Container)) {
    throw "$InstallDir isn't a folder"
}

Push-Location $PSScriptRoot
try {
    foreach ($plugin in $Plugins) {
        $name = $targetNames[$plugin]
        $buildType = $Configuration.ToLower()
        Write-Host "Building $name ($buildType)..."

        $dubArgs = @("build", "--build=$buildType", "--config=$plugin")
        if ($Compiler) { $dubArgs += "--compiler=$Compiler" }
        # dub writes its progress to stderr: let it through without PowerShell treating it as an error
        $ErrorActionPreference = "Continue"
        & dub @dubArgs 2>&1 | ForEach-Object {
            if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.Exception.Message } else { "$_" }
        } | Out-Host
        $exitCode = $LASTEXITCODE
        $ErrorActionPreference = "Stop"
        if ($exitCode -ne 0) { throw "dub couldn't build $name (exit code $exitCode)" }

        # dub names the library for the platform
        $file = @("bin/$name.dll", "bin/lib$name.so", "bin/lib$name.dylib") |
            Where-Object { Test-Path $_ } |
            ForEach-Object { Get-Item $_ } |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1
        if (-not $file) { throw "dub didn't make $name's library" }
        Write-Host "Built $($file.Name)"

        if ($InstallDir) {
            Copy-Item $file.FullName $InstallDir -Force
            Write-Host "Installed $($file.Name) into $InstallDir"
        }
    }
} finally {
    Pop-Location
}

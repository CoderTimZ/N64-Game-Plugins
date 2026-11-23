@echo off
rem Builds the N64 game plugins: runs build.ps1 with the same arguments, for cmd and .bat files (which can't run
rem PowerShell scripts directly). See build.ps1 for the arguments, or run: build.cmd -?
rem
rem   build.cmd                                     every plugin
rem   build.cmd mp1 mp2 -Configuration Debug
rem   build.cmd mp1 -InstallDir C:\RMG\Plugin\Execution
rem
rem Exits with build.ps1's exit code: 0 if everything built.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0build.ps1" %*
exit /b %ERRORLEVEL%

@echo off
rem voiced on Windows: runs voiced.ps1, which builds, starts, stops and restarts the voiced service.
rem install.bat puts a voiced.cmd that calls this one on PATH.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0voiced.ps1" %*

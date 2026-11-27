@echo off
rem Installs the voiced service on Windows: the voiced command (on PATH, through
rem %LOCALAPPDATA%\voiced\bin), and the service itself, built, copied to %LOCALAPPDATA%\voiced
rem and started now and at every login. Run it again after changing the source to rebuild and
rem restart the service, or use voiced service restart. Needs Rust (setup.bat installs it).
rem Remove with uninstall.bat.
rem
rem The service has no window: its icon sits in the notification area, and Quit in the icon's
rem menu stops it until the next login. Log: %LOCALAPPDATA%\voiced\voiced.log

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0voiced.ps1" --install

@echo off
rem Stops the voiced service and removes what install.bat installed: the service in
rem %LOCALAPPDATA%\voiced, its start at login, its firewall rule (which asks for administrator
rem approval) and the voiced command. The log is kept.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0voiced.ps1" --uninstall

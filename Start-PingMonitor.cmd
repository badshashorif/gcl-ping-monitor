@echo off
REM Launch GCL Ping Monitor (STA mode required for WinForms)
cd /d "%~dp0"
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0GCL-PingMonitor.ps1"

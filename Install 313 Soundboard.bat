@echo off
title 313 Soundboard Installer
echo.
echo   ================================================
echo        313 SOUNDBOARD - TS6 ADDON INSTALLER
echo   ================================================
echo.
echo   Installing...
echo.
powershell -ExecutionPolicy Bypass -File "%~dp0windows-installer\install.ps1"

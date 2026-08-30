@echo off
REM Atalho double-click para o tecnico em campo.
REM Forca STA e ignora ExecutionPolicy local; a elevacao UAC e tratada pelo .ps1.
powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -File "%~dp0Iniciar-Diagnostico.ps1" %*

<#
build-exe.ps1

Empaqueta Restore-CopilotSessions.ps1 como un .exe de consola usando el módulo ps2exe.

Requisitos:
- Windows PowerShell o PowerShell 7
- Acceso a PowerShell Gallery (internet) para instalar ps2exe

Uso:
  pwsh -ExecutionPolicy Bypass -File .\build-exe.ps1

Salida:
  .\dist\copilot-session-restorer.exe
#>

[CmdletBinding()]
param(
  [string]$InputScript = '.\Restore-CopilotSessions.ps1',
  [string]$OutputExe = '.\dist\copilot-session-restorer.exe'
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $InputScript)) {
  throw "No existe el script de entrada: $InputScript"
}

New-Item -ItemType Directory -Force -Path (Split-Path $OutputExe -Parent) | Out-Null

if (-not (Get-Command Invoke-PS2EXE -ErrorAction SilentlyContinue)) {
  Write-Host "Instalando módulo 'ps2exe' (CurrentUser)..." -ForegroundColor Cyan
  # Asegura que PSGallery esté disponible
  try {
    $null = Get-PSRepository -Name PSGallery -ErrorAction Stop
  } catch {
    Register-PSRepository -Default
  }
  Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
  Install-Module ps2exe -Scope CurrentUser -Force
}

Write-Host "Compilando EXE..." -ForegroundColor Cyan
Invoke-PS2EXE -InputFile $InputScript -OutputFile $OutputExe -noConsole:$false

Write-Host "OK -> $OutputExe" -ForegroundColor Green

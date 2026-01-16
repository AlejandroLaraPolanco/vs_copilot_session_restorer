<#
build-exe-python.ps1

Crea un .exe de consola desde copilot_session_restorer.py usando PyInstaller.

Requisitos:
- Python 3 instalado y accesible como `python`
- Internet (para instalar pyinstaller)

Uso:
  pwsh -ExecutionPolicy Bypass -File .\build-exe-python.ps1

Salida:
  .\dist\copilot-session-restorer.exe
#>

[CmdletBinding()]
param(
	[string]$Entry = '.\copilot_session_restorer.py'
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $Entry)) {
	throw "No existe: $Entry"
}

$python = Get-Command python -ErrorAction SilentlyContinue
if (-not $python) {
	throw "No encontré 'python' en PATH. Instalá Python 3."
}

# venv local para no ensuciar el sistema
$venv = Join-Path $PWD '.venv'
if (-not (Test-Path $venv)) {
	& $python.Source -m venv $venv
}

$venvPy = Join-Path $venv 'Scripts\python.exe'

& $venvPy -m pip install --upgrade pip
& $venvPy -m pip install --upgrade pyinstaller

# Limpieza previa
Remove-Item -Recurse -Force -ErrorAction SilentlyContinue .\build
Remove-Item -Recurse -Force -ErrorAction SilentlyContinue .\dist

# Consola (onefile)
& $venvPy -m PyInstaller --onefile --console --name "copilot-session-restorer" $Entry

Write-Host "OK -> .\dist\copilot-session-restorer.exe" -ForegroundColor Green

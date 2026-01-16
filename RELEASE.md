# Release checklist

Este proyecto puede distribuirse como:
- script (`.py` / `.ps1`), o
- ejecutable Windows (`.exe`) construido con PyInstaller.

## Recomendado: release con GitHub Actions

Hay un workflow que construye el `.exe` en Windows y lo sube como asset al crear un tag.

### 1) Elegí versión

Usá tags semver, por ejemplo: `v0.1.0`.

### 2) Actualizá notas (opcional)

Podés editar el release en GitHub luego de publicarlo.

### 3) Crear y pushear tag

```powershell
git tag v0.1.0
git push origin v0.1.0
```

### 4) Verificar en GitHub

- Acciones: pestaña **Actions** → workflow "Release (Windows EXE)".
- Releases: pestaña **Releases** → asset `copilot-session-restorer.exe`.

## Manual (local)

Si querés generar el `.exe` localmente:

```powershell
pwsh -ExecutionPolicy Bypass -File .\build-exe-python.ps1
```

Salida: `./dist/copilot-session-restorer.exe`

## Smoke test

Antes de release:

```powershell
python .\copilot_session_restorer.py --help
python .\copilot_session_restorer.py --dry-run "C:\path\to\workspace.code-workspace"
```

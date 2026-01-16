# VS Copilot Session Restorer

Herramienta de consola para Windows que ayuda a **restaurar sesiones de Copilot Chat/Agent** cuando aparecen en “Recent sessions” pero no abren (típico tras cambios de identidad del workspace, por ejemplo al pasar de single-folder a multi-root).

Referencia del bug/contexto: https://github.com/microsoft/vscode/issues/283714

> Recomendación: cerrá VS Code antes de ejecutar (evita locks en `state.vscdb`).

## Qué hace

- Encuentra los *WorkspaceHash* relevantes dentro de `%APPDATA%\...\workspaceStorage` (buscando rutas/URIs dentro de `workspace.json`).
- Elige un hash DESTINO sugerido (por defecto, el más “reciente” según `state.vscdb`).
- Lista sesiones encontradas en `chatSessions` con fechas y un “CopyDecision”.
- Copia al DESTINO las sesiones que faltan o son más nuevas.
- (Opcional) Reindexa el chat escribiendo `chat.ChatSessionStore.index` dentro de `state.vscdb` (SQLite).

## Requisitos

- Windows
- Python 3 (recomendado) o PowerShell 7

## Uso (recomendado): Python wizard

Wizard (cero parámetros):

```powershell
python .\copilot_session_restorer.py
```

Pasando un `.code-workspace`:

```powershell
python .\copilot_session_restorer.py "C:\path\to\workspace.code-workspace"
```

Pasando una carpeta del proyecto:

```powershell
python .\copilot_session_restorer.py "C:\path\to\project-folder"
```

Dry-run (no modifica nada):

```powershell
python .\copilot_session_restorer.py --dry-run "C:\path\to\workspace.code-workspace"
```

Needle extra (si no encuentra hashes):

```powershell
python .\copilot_session_restorer.py --needle "some-folder-name" "C:\path\to\workspace.code-workspace"
```

## Uso (PowerShell)

Wizard (sin parámetros):

```powershell
pwsh -ExecutionPolicy Bypass -File .\Restore-CopilotSessions.ps1
```

Con `.code-workspace`:

```powershell
pwsh -ExecutionPolicy Bypass -File .\Restore-CopilotSessions.ps1 -WorkspaceFile "C:\path\to\workspace.code-workspace"
```

Con carpeta:

```powershell
pwsh -ExecutionPolicy Bypass -File .\Restore-CopilotSessions.ps1 -WorkspaceFolder "C:\path\to\project-folder"
```

## Crear EXE

### EXE desde Python (recomendado)

```powershell
pwsh -ExecutionPolicy Bypass -File .\build-exe-python.ps1
```

Salida: `./dist/copilot-session-restorer.exe`

### EXE desde PowerShell (ps2exe)

```powershell
pwsh -ExecutionPolicy Bypass -File .\build-exe.ps1
```

Salida: `./dist/copilot-session-restorer.exe`

## Cómo funciona (por dentro)

VS Code guarda datos por-workspace en:

- `%APPDATA%\Code\User\workspaceStorage\<WorkspaceHash>\workspace.json`
- `%APPDATA%\Code\User\workspaceStorage\<WorkspaceHash>\chatSessions\*.json` (y a veces `*.jsonl`)
- `%APPDATA%\Code\User\workspaceStorage\<WorkspaceHash>\state.vscdb` (SQLite)

El problema típico es que la UI tiene un índice/referencias para sesiones, pero el contenido en disco está en otro hash (o el índice quedó desincronizado). Esta herramienta:

1) Detecta hashes relacionados al workspace.
2) Copia archivos de sesión al hash DESTINO.
3) (Opcional) Reindexa escribiendo `chat.ChatSessionStore.index` en `state.vscdb`.

## Backups

- Antes de copiar, crea backups por hash dentro de `./backups/`.
- Si reindexa, crea un backup del DB como `state.vscdb.bak-YYYYMMDD-HHMMSS`.

## Troubleshooting

**No encuentra hashes**
- Probá pasar una carpeta dentro del workspace en vez del `.code-workspace`.
- Usá `--needle` con un nombre de carpeta que sepas que está dentro del workspace.
- Confirmá que el canal sea el correcto (Code vs Code - Insiders).

**Reindex falla / “database is locked”**
- Cerrá todas las ventanas de VS Code y volvé a intentar.

**Copié pero la sesión no abre**
- Repetí y elegí reindex.
- Verificá que el archivo esté en `...\workspaceStorage\<Destino>\chatSessions\`.

## Licencia

MIT — ver [LICENSE](LICENSE).

## Releases

Ver [RELEASE.md](RELEASE.md).

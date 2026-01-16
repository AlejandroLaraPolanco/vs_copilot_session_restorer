<#
Restore-CopilotSessions.ps1

Objetivo: ayudar a recuperar sesiones de Copilot Chat/Agent (chatSessions) cuando VS Code cambia de workspace (p.ej. single-folder -> multi-root) y el índice queda apuntando a rutas/IDs que no existen.

Notas:
- Este script NO requiere UI.
- Recomendado: cerrar VS Code antes de ejecutar (para evitar locks y para no pisar cambios).
- En VS Code (estable): %APPDATA%\Code\User\workspaceStorage
- En VS Code Insiders: %APPDATA%\Code - Insiders\User\workspaceStorage

Acciones principales:
- Detectar hashes candidatos buscando texto en workspace.json
- Elegir hash activo (por LastWriteTime del state.vscdb)
- Copiar sesiones (.json / .jsonl) entre hashes
- (Opcional) Reindexar ChatSessionStore index en state.vscdb via Python+sqlite3

Uso rápido (interactivo):
  pwsh -ExecutionPolicy Bypass -File .\Restore-CopilotSessions.ps1

Uso no-interactivo (ejemplo):
  pwsh -ExecutionPolicy Bypass -File .\Restore-CopilotSessions.ps1 -Needle "cms_assistant" -SourceHash e081... -TargetHash 329e... -SessionId "2563..." -Reindex
#>

[CmdletBinding()]
param(
	# Ruta al .code-workspace (modo recomendado: con esto alcanza para listar y restaurar)
	[string]$WorkspaceFile,

	# Ruta a una carpeta del workspace (para workspaces sin .code-workspace)
	[string]$WorkspaceFolder,

	# Texto a buscar dentro de workspace.json (ej: nombre de carpeta, nombre del .code-workspace, o un path)
	[string]$Needle,

	# Hash origen (donde está el chatSessions\<session>.json actual)
	[string]$SourceHash,

	# Hash destino (workspace activo actual)
	[string]$TargetHash,

	# SessionId (GUID) sin extensión. Si se omite, se copian todas las sesiones del hash origen.
	[string]$SessionId,

	# Forzar reindex del destino (state.vscdb) para que VS Code vuelva a ver/abrir.
	[switch]$Reindex,

	# Exporta una sesión a Markdown (best-effort) además de copiar.
	[switch]$ExportMarkdown,

	# Saltea backups automáticos (NO recomendado)
	[switch]$SkipBackup,

	# VS Code channel: Code (stable) o Code - Insiders.
	[ValidateSet('Code','Code - Insiders')]
	[string]$Channel = 'Code'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Section([string]$Title) {
	Write-Host "";
	Write-Host "=== $Title ===" -ForegroundColor Cyan
}

function Read-YesNo([string]$Prompt, [bool]$DefaultYes) {
	$suffix = if ($DefaultYes) { ' (S/n)' } else { ' (s/N)' }
	$ans = Read-Host ($Prompt + $suffix)
	if (-not $ans) { return $DefaultYes }
	return ($ans -match '^(s|S|y|Y)$')
}

function Read-NonEmpty([string]$Prompt) {
	$ans = Read-Host $Prompt
	if (-not $ans) { return $null }
	$trim = $ans.Trim('"').Trim()
	if (-not $trim) { return $null }
	return $trim
}

function Get-StorageRoots() {
	$roots = @()
	foreach ($ch in @('Code','Code - Insiders')) {
		$p = Join-Path $env:APPDATA "$ch\User\workspaceStorage"
		if (Test-Path $p) {
			$roots += [pscustomobject]@{ Channel = $ch; Root = $p }
		}
	}
	return $roots
}

function Pause-IfInteractive([bool]$ShouldPause) {
	if (-not $ShouldPause) { return }
	Write-Host "";
	[void](Read-Host 'Enter para salir')
}

function Assert-Windows {
	if ($PSVersionTable.Platform -and $PSVersionTable.Platform -ne 'Win32NT') {
		throw "Este script actualmente está pensado para Windows."
	}
}

function Get-WorkspaceStorageRoot([string]$ChannelName) {
	$root = Join-Path $env:APPDATA "$ChannelName\User\workspaceStorage"
	if (-not (Test-Path $root)) {
		throw "No existe workspaceStorage en: $root (¿VS Code instalado/ejecutado? ¿Canal correcto?)"
	}
	return $root
}

function Get-WorkspaceHashInfo([string]$WorkspaceStorageRoot) {
	Get-ChildItem -Path $WorkspaceStorageRoot -Directory | ForEach-Object {
		$workspaceJson = Join-Path $_.FullName 'workspace.json'
		$stateDb = Join-Path $_.FullName 'state.vscdb'
		$chatDir = Join-Path $_.FullName 'chatSessions'

		[pscustomobject]@{
			Hash = $_.Name
			Path = $_.FullName
			HasWorkspaceJson = (Test-Path $workspaceJson)
			WorkspaceJsonPath = $workspaceJson
			WorkspaceJsonLastWrite = if (Test-Path $workspaceJson) { (Get-Item $workspaceJson).LastWriteTime } else { $null }
			HasStateDb = (Test-Path $stateDb)
			StateDbPath = $stateDb
			StateDbLastWrite = if (Test-Path $stateDb) { (Get-Item $stateDb).LastWriteTime } else { $null }
			ChatDir = $chatDir
			ChatSessionFiles = if (Test-Path $chatDir) { (Get-ChildItem $chatDir -File -ErrorAction SilentlyContinue | Measure-Object).Count } else { 0 }
		}
	} | Sort-Object -Property StateDbLastWrite -Descending
}

function Find-HashesByNeedle([string]$WorkspaceStorageRoot, [string]$NeedleText) {
	if (-not $NeedleText) {
		throw "Needle vacío."
	}

	Get-ChildItem -Path $WorkspaceStorageRoot -Directory | ForEach-Object {
		$workspaceJson = Join-Path $_.FullName 'workspace.json'
		if (Test-Path $workspaceJson) {
			$c = Get-Content $workspaceJson -Raw -ErrorAction SilentlyContinue
			if ($c -and ($c -like "*$NeedleText*")) {
				$stateDb = Join-Path $_.FullName 'state.vscdb'
				$chatDir = Join-Path $_.FullName 'chatSessions'
				[pscustomobject]@{
					Hash = $_.Name
					Path = $_.FullName
					WorkspaceJsonLastWrite = (Get-Item $workspaceJson).LastWriteTime
					StateDbLastWrite = if (Test-Path $stateDb) { (Get-Item $stateDb).LastWriteTime } else { $null }
					ChatSessionFiles = if (Test-Path $chatDir) { (Get-ChildItem $chatDir -File -ErrorAction SilentlyContinue | Measure-Object).Count } else { 0 }
				}
			}
		}
	} | Sort-Object -Property StateDbLastWrite -Descending
}

function Convert-ToFileUri([string]$Path) {
	$resolved = Resolve-Path -Path $Path -ErrorAction Stop
	# AbsoluteUri produce file:///C:/... o file:///g:/..., VS Code suele guardar URIs
	return ([System.Uri]::new($resolved.Path)).AbsoluteUri
}

function Find-HashesByAnyNeedle([string]$WorkspaceStorageRoot, [string[]]$Needles) {
	$needlesFiltered = @($Needles | Where-Object { $_ -and $_.Trim() })
	if ($needlesFiltered.Count -eq 0) {
		throw "No hay needles para buscar."
	}

	Get-ChildItem -Path $WorkspaceStorageRoot -Directory | ForEach-Object {
		$workspaceJson = Join-Path $_.FullName 'workspace.json'
		if (-not (Test-Path $workspaceJson)) { return }

		$c = Get-Content $workspaceJson -Raw -ErrorAction SilentlyContinue
		if (-not $c) { return }

		$hit = $false
		foreach ($n in $needlesFiltered) {
			if ($c -like "*$n*") { $hit = $true; break }
		}
		if (-not $hit) { return }

		$stateDb = Join-Path $_.FullName 'state.vscdb'
		$chatDir = Join-Path $_.FullName 'chatSessions'
		[pscustomobject]@{
			Hash = $_.Name
			Path = $_.FullName
			WorkspaceJsonLastWrite = (Get-Item $workspaceJson).LastWriteTime
			StateDbLastWrite = if (Test-Path $stateDb) { (Get-Item $stateDb).LastWriteTime } else { $null }
			ChatSessionFiles = if (Test-Path $chatDir) { (Get-ChildItem $chatDir -File -ErrorAction SilentlyContinue | Measure-Object).Count } else { 0 }
		}
	} | Sort-Object -Property StateDbLastWrite -Descending
}

function Try-GetSessionMetaFromJson([string]$Path) {
	try {
		$jsonText = Get-Content $Path -Raw -ErrorAction Stop
		$obj = $jsonText | ConvertFrom-Json -ErrorAction Stop
		if (-not $obj) { return $null }

		$sessionId = $null
		if ($obj.sessionId) { $sessionId = [string]$obj.sessionId }
		$title = $null
		foreach ($k in @('customTitle','title','computedTitle')) {
			if ($obj.$k -and ([string]$obj.$k).Trim()) { $title = ([string]$obj.$k).Trim(); break }
		}

		# Algunos formatos incluyen creationDate; si no, null y se usa CreationTime del filesystem
		$creationMs = $null
		if ($obj.creationDate -is [int64] -or $obj.creationDate -is [double] -or $obj.creationDate -is [int]) {
			$creationMs = [int64]$obj.creationDate
			if ($creationMs -lt 10000000000) { $creationMs = $creationMs * 1000 }
		}
		return [pscustomobject]@{ SessionId = $sessionId; Title = $title; CreationMs = $creationMs }
	} catch {
		return $null
	}
}

function Get-SessionInventory([string]$WorkspaceStorageRoot, [string[]]$Hashes) {
	$items = New-Object System.Collections.Generic.List[object]
	foreach ($h in $Hashes) {
		$chatDir = Join-Path (Join-Path $WorkspaceStorageRoot $h) 'chatSessions'
		if (-not (Test-Path $chatDir)) { continue }
		Get-ChildItem -Path $chatDir -File -ErrorAction SilentlyContinue | ForEach-Object {
			$fi = $_
			$ext = $fi.Extension.TrimStart('.').ToLowerInvariant()
			$sessionId = $fi.BaseName
			$title = $null
			$created = $fi.CreationTime
			$updated = $fi.LastWriteTime

			if ($ext -eq 'json') {
				$meta = Try-GetSessionMetaFromJson -Path $fi.FullName
				if ($meta) {
					if ($meta.SessionId) { $sessionId = $meta.SessionId }
					if ($meta.Title) { $title = $meta.Title }
					if ($meta.CreationMs) {
						try { $created = [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$meta.CreationMs).LocalDateTime } catch { }
					}
				}
			}

			$items.Add([pscustomobject]@{
				Hash = $h
				SessionId = $sessionId
				Title = if ($title) { $title } else { '' }
				Created = $created
				Updated = $updated
				Ext = $ext
				Path = $fi.FullName
			}) | Out-Null
		}
	}

	return $items
}

function Get-TargetSessionMap([string]$WorkspaceStorageRoot, [string]$TargetHash) {
	$map = @{}
	$targetChat = Join-Path (Join-Path $WorkspaceStorageRoot $TargetHash) 'chatSessions'
	if (-not (Test-Path $targetChat)) { return $map }
	Get-ChildItem -Path $targetChat -File -ErrorAction SilentlyContinue | ForEach-Object {
		$fi = $_
		$sid = $fi.BaseName
		if ($fi.Extension -ieq '.json') {
			$meta = Try-GetSessionMetaFromJson -Path $fi.FullName
			if ($meta -and $meta.SessionId) { $sid = $meta.SessionId }
		}
		$map[$sid] = $fi.LastWriteTime
	}
	return $map
}

function Parse-Selection([string]$InputText, [int]$Max) {
	if (-not $InputText) { return @() }
	$txt = $InputText.Trim().ToLowerInvariant()
	if ($txt -eq 'all') {
		return 1..$Max
	}

	$nums = New-Object System.Collections.Generic.List[int]
	foreach ($part in $txt.Split(',') ) {
		$p = $part.Trim()
		if (-not $p) { continue }
		if ($p -match '^[0-9]+$') {
			$n = [int]$p
			if ($n -ge 1 -and $n -le $Max) { $nums.Add($n) | Out-Null }
		}
	}
	return @($nums | Select-Object -Unique)
}

function Select-FromList([string]$Prompt, $Items, [scriptblock]$ToLabel) {
	if (-not $Items -or $Items.Count -eq 0) {
		return $null
	}

	Write-Host "";
	Write-Host $Prompt -ForegroundColor Yellow
	for ($i = 0; $i -lt $Items.Count; $i++) {
		$label = & $ToLabel $Items[$i]
		Write-Host ("[{0}] {1}" -f ($i + 1), $label)
	}
	$choice = Read-Host "Elegí un número (Enter = cancelar)"
	if (-not $choice) { return $null }
	if ($choice -notmatch '^[0-9]+$') { return $null }
	$idx = [int]$choice - 1
	if ($idx -lt 0 -or $idx -ge $Items.Count) { return $null }
	return $Items[$idx]
}

function New-Backup([string]$WorkspaceStorageRoot, [string]$Hash, [string]$BackupRoot) {
	$src = Join-Path $WorkspaceStorageRoot $Hash
	if (-not (Test-Path $src)) {
		throw "No existe hash: $Hash"
	}

	$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
	$dest = Join-Path $BackupRoot ("workspaceStorage_{0}_{1}" -f $Hash, $timestamp)
	New-Item -ItemType Directory -Force -Path $dest | Out-Null

	Write-Host "Backup -> $dest" -ForegroundColor Green
	Copy-Item -Path $src -Destination $dest -Recurse -Force
	return $dest
}

function Get-ChatSessionPaths([string]$WorkspaceStorageRoot, [string]$Hash, [string]$SessionIdOrNull) {
	$chatDir = Join-Path (Join-Path $WorkspaceStorageRoot $Hash) 'chatSessions'
	if (-not (Test-Path $chatDir)) {
		return @()
	}

	if ($SessionIdOrNull) {
		$paths = @()
		foreach ($ext in @('json','jsonl')) {
			$p = Join-Path $chatDir ("$SessionIdOrNull.$ext")
			if (Test-Path $p) { $paths += $p }
		}
		return $paths
	}

	return @(
		Get-ChildItem -Path $chatDir -File -ErrorAction SilentlyContinue |
			Select-Object -ExpandProperty FullName
	)
}

function Copy-ChatSessions([string]$WorkspaceStorageRoot, [string]$Source, [string]$Target, [string]$SessionIdOrNull) {
	$srcPaths = @(
		Get-ChatSessionPaths -WorkspaceStorageRoot $WorkspaceStorageRoot -Hash $Source -SessionIdOrNull $SessionIdOrNull
	)
	if ($srcPaths.Count -eq 0) {
		throw "No encontré sesiones para copiar en $Source (SessionId=$SessionIdOrNull)."
	}

	$targetDir = Join-Path (Join-Path $WorkspaceStorageRoot $Target) 'chatSessions'
	New-Item -ItemType Directory -Force -Path $targetDir | Out-Null

	foreach ($p in $srcPaths) {
		$dest = Join-Path $targetDir ([IO.Path]::GetFileName($p))
		Copy-Item -Path $p -Destination $dest -Force
		Write-Host "Copiado -> $dest" -ForegroundColor Green
	}

	return $srcPaths
}

function Copy-SelectedSessions(
	[string]$WorkspaceStorageRoot,
	[object[]]$SelectedItems,
	[string]$TargetHash
) {
	$targetDir = Join-Path (Join-Path $WorkspaceStorageRoot $TargetHash) 'chatSessions'
	New-Item -ItemType Directory -Force -Path $targetDir | Out-Null
	foreach ($it in $SelectedItems) {
		$dest = Join-Path $targetDir ([IO.Path]::GetFileName($it.Path))
		Copy-Item -Path $it.Path -Destination $dest -Force
		Write-Host "Copiado -> $dest" -ForegroundColor Green
	}
}

function Export-SessionToMarkdownBestEffort([string]$SessionPath, [string]$OutPath) {
	# Best-effort: extrae strings con keys comunes. No garantiza orden perfecto.
	$jsonText = Get-Content $SessionPath -Raw -ErrorAction Stop
	$data = $jsonText | ConvertFrom-Json -ErrorAction Stop

	$strings = New-Object System.Collections.Generic.List[string]
	$seen = New-Object 'System.Collections.Generic.HashSet[string]'

	function Walk($obj) {
		if ($null -eq $obj) { return }
		if ($obj -is [string]) { return }
		if ($obj -is [System.Collections.IDictionary]) {
			foreach ($k in $obj.Keys) {
				$v = $obj[$k]
				if ($k -in @('text','value','content','message','prompt','response') -and $v -is [string]) {
					$t = $v.Trim()
					if ($t -and -not $seen.Contains($t)) {
						$seen.Add($t) | Out-Null
						$strings.Add($t) | Out-Null
					}
				} else {
					Walk $v
				}
			}
			return
		}
		if ($obj -is [System.Collections.IEnumerable]) {
			foreach ($it in $obj) { Walk $it }
			return
		}

		# PSObject
		if ($obj.PSObject -and $obj.PSObject.Properties) {
			foreach ($p in $obj.PSObject.Properties) {
				$name = $p.Name
				$v = $p.Value
				if ($name -in @('text','value','content','message','prompt','response') -and $v -is [string]) {
					$t = $v.Trim()
					if ($t -and -not $seen.Contains($t)) {
						$seen.Add($t) | Out-Null
						$strings.Add($t) | Out-Null
					}
				} else {
					Walk $v
				}
			}
		}
	}

	Walk $data

	$lines = @(
		"# Copilot Chat recuperado",
		"",
		"**Archivo:** $SessionPath",
		"",
		"---",
		""
	)
	foreach ($s in $strings) {
		$lines += $s
		$lines += ""
		$lines += "---"
		$lines += ""
	}

	$lines -join "`n" | Set-Content -Path $OutPath -Encoding UTF8
	Write-Host "Exportado Markdown -> $OutPath" -ForegroundColor Green
}

function Invoke-ReindexWithPython(
	[string]$WorkspaceStorageRoot,
	[string]$TargetHash
) {
	$python = Get-Command python -ErrorAction SilentlyContinue
	if (-not $python) {
		throw "No encontré 'python' en PATH. Instalá Python o corré sin -Reindex."
	}

	$targetRoot = Join-Path $WorkspaceStorageRoot $TargetHash
	$dbPath = Join-Path $targetRoot 'state.vscdb'
	$chatDir = Join-Path $targetRoot 'chatSessions'
	if (-not (Test-Path $dbPath)) {
		throw "No existe state.vscdb en $targetRoot"
	}
	if (-not (Test-Path $chatDir)) {
		throw "No existe chatSessions en $targetRoot (nada para indexar)"
	}

	# Backup del DB antes de tocarlo
	$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
	$dbBackup = "$dbPath.bak-$stamp"
	Copy-Item -Path $dbPath -Destination $dbBackup -Force
	Write-Host "Backup DB -> $dbBackup" -ForegroundColor Green

	$pyPath = Join-Path $env:TEMP ("vscode_chat_reindex_{0}.py" -f $stamp)
	$py = @'
import json, os, sys, sqlite3
from pathlib import Path

CHAT_INDEX_KEY = 'chat.ChatSessionStore.index'

def file_last_write_ms(p: Path) -> int:
    try:
        return int(p.stat().st_mtime * 1000)
    except Exception:
        return int(0)

def best_title_from_json(obj) -> str:
    # Backward/forward compatible best-effort
    for k in ('customTitle','title','computedTitle'):
        v = obj.get(k)
        if isinstance(v, str) and v.strip():
            return v.strip()
    return 'New Chat'

def is_empty_from_json(obj) -> bool:
    reqs = obj.get('requests')
    if isinstance(reqs, list):
        return len(reqs) == 0
    return False

def try_last_message_date(obj, fallback_ms: int) -> int:
    # Many formats exist; fallback to file mtime.
    candidates = []
    reqs = obj.get('requests')
    if isinstance(reqs, list):
        for r in reqs:
            if isinstance(r, dict):
                for key in ('timestamp','time','date','creationDate'):
                    v = r.get(key)
                    if isinstance(v, (int, float)):
                        # heuristic: seconds vs ms
                        vv = int(v)
                        if vv < 10_000_000_000:
                            vv *= 1000
                        candidates.append(vv)
    cd = obj.get('creationDate')
    if isinstance(cd, (int, float)):
        vv = int(cd)
        if vv < 10_000_000_000:
            vv *= 1000
        candidates.append(vv)

    return max(candidates) if candidates else fallback_ms

def build_index(chat_dir: Path):
    entries = {}
    for p in sorted(chat_dir.glob('*.json')):
        session_id = p.stem
        fallback = file_last_write_ms(p)
        try:
            obj = json.loads(p.read_text(encoding='utf-8'))
            if isinstance(obj, dict):
                session_id = obj.get('sessionId') or session_id
                title = best_title_from_json(obj)
                last_ms = try_last_message_date(obj, fallback)
                is_empty = is_empty_from_json(obj)
            else:
                title = 'New Chat'
                last_ms = fallback
                is_empty = False
        except Exception:
            title = 'New Chat'
            last_ms = fallback
            is_empty = False

        entries[str(session_id)] = {
            'sessionId': str(session_id),
            'title': title,
            'lastMessageDate': int(last_ms),
            'isEmpty': bool(is_empty),
            'isExternal': False,
        }

    # Also include *.jsonl (>=1.109) if present
    for p in sorted(chat_dir.glob('*.jsonl')):
        session_id = p.stem
        if session_id in entries:
            continue
        fallback = file_last_write_ms(p)
        entries[str(session_id)] = {
            'sessionId': str(session_id),
            'title': 'New Chat',
            'lastMessageDate': int(fallback),
            'isEmpty': False,
            'isExternal': False,
        }

    return {'version': 1, 'entries': entries}

def main(db_path: str, chat_dir: str):
    db = Path(db_path)
    cd = Path(chat_dir)
    if not db.exists():
        print('DB missing:', db)
        return 2
    if not cd.exists():
        print('chatSessions missing:', cd)
        return 2

    index = build_index(cd)
    value = json.dumps(index, ensure_ascii=False)

    con = sqlite3.connect(str(db))
    try:
        cur = con.cursor()
        # ensure table exists (normally it does)
        cur.execute('CREATE TABLE IF NOT EXISTS ItemTable (key TEXT PRIMARY KEY, value TEXT)')
        cur.execute(
            'INSERT INTO ItemTable(key,value) VALUES(?,?) '
            'ON CONFLICT(key) DO UPDATE SET value=excluded.value',
            (CHAT_INDEX_KEY, value)
        )
        con.commit()
    finally:
        con.close()

    print('OK: wrote', CHAT_INDEX_KEY, 'with', len(index['entries']), 'entries')
    return 0

if __name__ == '__main__':
    sys.exit(main(sys.argv[1], sys.argv[2]))
'@

	Set-Content -Path $pyPath -Value $py -Encoding UTF8

	Write-Host "Reindex -> ejecutando Python (sqlite3)" -ForegroundColor Cyan
	& $python.Source $pyPath $dbPath $chatDir
	$exit = $LASTEXITCODE
	Remove-Item $pyPath -Force -ErrorAction SilentlyContinue
	if ($exit -ne 0) {
		throw "Python reindex falló (exit=$exit). Revisa el output."
	}
}

function Main {
	Assert-Windows
	Write-Section "VS Code Copilot Sessions Restorer"
	Write-Host "Tip: cerrá VS Code antes de seguir." -ForegroundColor Yellow

	# Wizard cuando el usuario ejecuta sin parámetros (ideal para .exe)
	$noArgsMode = (-not $WorkspaceFile -and -not $WorkspaceFolder -and -not $Needle -and -not $SourceHash -and -not $TargetHash -and -not $SessionId)
	$pauseOnExit = $noArgsMode
	if ($noArgsMode) {
		Write-Section "Modo Wizard (cero parámetros)"
		$roots = @(Get-StorageRoots)
		if ($roots.Count -eq 0) {
			throw "No encontré workspaceStorage para Code ni Code - Insiders en %APPDATA%."
		}
		if ($roots.Count -eq 1) {
			$Channel = $roots[0].Channel
		} else {
			Write-Host "Detecté más de un canal:" -ForegroundColor Yellow
			for ($i=0; $i -lt $roots.Count; $i++) {
				Write-Host ("[{0}] {1} -> {2}" -f ($i+1), $roots[$i].Channel, $roots[$i].Root)
			}
			$pick = Read-Host "Elegí canal (Enter = 1)"
			$idx = 0
			if ($pick -and $pick -match '^[0-9]+$') {
				$idx = [Math]::Max(0, [Math]::Min([int]$pick - 1, $roots.Count - 1))
			}
			$Channel = $roots[$idx].Channel
		}

		$path = Read-NonEmpty "Pegá la ruta del .code-workspace o de la carpeta del proyecto"
		if (-not $path) {
			Write-Host "Cancelado." -ForegroundColor Yellow
			Pause-IfInteractive $pauseOnExit
			return
		}
		if ($path.ToLowerInvariant().EndsWith('.code-workspace')) {
			$WorkspaceFile = $path
		} else {
			# si es un archivo existente .code-workspace, también lo aceptamos
			if ((Test-Path $path) -and -not (Test-Path $path -PathType Container) -and ($path.ToLowerInvariant().EndsWith('.code-workspace'))) {
				$WorkspaceFile = $path
			} else {
				$WorkspaceFolder = $path
			}
		}

		$ExportMarkdown = Read-YesNo "¿Exportar también a Markdown (best-effort)?" $false
		$SkipBackup = -not (Read-YesNo "¿Hacer backups automáticos?" $true)
	}

	$root = Get-WorkspaceStorageRoot -ChannelName $Channel
	Write-Host "workspaceStorage: $root" -ForegroundColor Gray

	# Modo minimalista: con .code-workspace o con carpeta
	if ($WorkspaceFile -or $WorkspaceFolder) {
		$mode = if ($WorkspaceFile) { 'WorkspaceFile' } else { 'WorkspaceFolder' }
		Write-Section "Modo $mode"

		$displayPath = $null
		$needles = @()
		if ($WorkspaceFile) {
			if (-not (Test-Path $WorkspaceFile)) {
				throw "No existe WorkspaceFile: $WorkspaceFile"
			}
			$wsFull = (Resolve-Path $WorkspaceFile).Path
			$wsUri = Convert-ToFileUri -Path $wsFull
			$displayPath = $wsFull
			$needles += @(
				$wsFull,
				$wsFull.Replace('\\','/'),
				$wsUri,
				$wsUri.ToLowerInvariant()
			)
			Write-Host "Workspace: $wsFull" -ForegroundColor Gray
			Write-Host "URI      : $wsUri" -ForegroundColor Gray
		}

		if (-not $WorkspaceFile) {
			if (-not (Test-Path $WorkspaceFolder)) {
				throw "No existe WorkspaceFolder: $WorkspaceFolder"
			}
			$folderFull = (Resolve-Path $WorkspaceFolder).Path
			$folderUri = Convert-ToFileUri -Path $folderFull
			$displayPath = $folderFull
			$needles += @(
				$folderFull,
				$folderFull.Replace('\\','/'),
				$folderUri,
				$folderUri.ToLowerInvariant()
			)
			Write-Host "Folder   : $folderFull" -ForegroundColor Gray
			Write-Host "URI      : $folderUri" -ForegroundColor Gray
		}

		$matched = @(Find-HashesByAnyNeedle -WorkspaceStorageRoot $root -Needles $needles)
		if ($matched.Count -eq 0) {
			throw "No encontré hashes para '$displayPath' en workspace.json. Probá con -Needle o revisá el path."
		}
		Write-Host "Hashes encontrados: $($matched.Count)" -ForegroundColor Green
		$matchedSorted = @($matched | Sort-Object StateDbLastWrite -Descending)
		$matchedRows = for ($i = 0; $i -lt $matchedSorted.Count; $i++) {
			[pscustomobject]@{
				N = $i + 1
				Hash = $matchedSorted[$i].Hash
				StateDbLastWrite = $matchedSorted[$i].StateDbLastWrite
				ChatSessionFiles = $matchedSorted[$i].ChatSessionFiles
			}
		}
		$matchedRows | Format-Table N, Hash, StateDbLastWrite, ChatSessionFiles -Auto

		# Elegir destino: por defecto el state.vscdb más reciente dentro del grupo
		$TargetHash = $matchedSorted[0].Hash
		$pickTarget = Read-Host "Elegí hash DESTINO (Enter = 1)"
		if ($pickTarget -and $pickTarget -match '^[0-9]+$') {
			$idx = [int]$pickTarget - 1
			if ($idx -ge 0 -and $idx -lt $matchedSorted.Count) { $TargetHash = $matchedSorted[$idx].Hash }
		}
		Write-Host "Destino: $TargetHash" -ForegroundColor Yellow
		$SourceHashes = @($matched | Where-Object { $_.Hash -ne $TargetHash -and $_.ChatSessionFiles -gt 0 } | Select-Object -ExpandProperty Hash)
		if ($SourceHashes.Count -eq 0) {
			Write-Host "No hay hashes ORIGEN con chatSessions para copiar (dentro del grupo)." -ForegroundColor Yellow
			return
		}

		# Backups (por defecto SI)
		if (-not $SkipBackup) {
			Write-Section "Backups (automático)"
			$backupRoot = Join-Path $PWD 'backups'
			New-Item -ItemType Directory -Force -Path $backupRoot | Out-Null
			New-Backup -WorkspaceStorageRoot $root -Hash $TargetHash -BackupRoot $backupRoot | Out-Null
			foreach ($h in $SourceHashes) {
				New-Backup -WorkspaceStorageRoot $root -Hash $h -BackupRoot $backupRoot | Out-Null
			}
		}

		Write-Section "Inventario de sesiones"
		$inv = @(Get-SessionInventory -WorkspaceStorageRoot $root -Hashes $SourceHashes)
		if ($inv.Count -eq 0) {
			Write-Host "No encontré archivos en chatSessions para los hashes origen." -ForegroundColor Yellow
			return
		}

		$targetMap = Get-TargetSessionMap -WorkspaceStorageRoot $root -TargetHash $TargetHash
		$invWithStatus = @()
		foreach ($it in $inv | Sort-Object Updated -Descending) {
			$status = 'MissingInTarget'
			if ($targetMap.ContainsKey($it.SessionId)) {
				$status = if ($it.Updated -gt $targetMap[$it.SessionId]) { 'NewerInSource' } else { 'AlreadyInTarget' }
			}
			$invWithStatus += [pscustomobject]@{
				SessionId = $it.SessionId
				Title = $it.Title
				Created = $it.Created
				Updated = $it.Updated
				FromHash = $it.Hash
				Ext = $it.Ext
				Status = $status
				Path = $it.Path
			}
		}

		# Mostrar con índices
		$rows = for ($i = 0; $i -lt $invWithStatus.Count; $i++) {
			$r = $invWithStatus[$i]
			[pscustomobject]@{
				N = $i + 1
				Status = $r.Status
				Updated = $r.Updated
				Created = $r.Created
				SessionId = $r.SessionId
				Title = if ($r.Title.Length -gt 60) { $r.Title.Substring(0,60) } else { $r.Title }
				FromHash = $r.FromHash
				Ext = $r.Ext
			}
		}
		$rows | Format-Table N, Status, Updated, Created, SessionId, Title, FromHash, Ext -Auto

		# Default selection: MissingInTarget + NewerInSource
		$default = @()
		for ($i = 0; $i -lt $invWithStatus.Count; $i++) {
			if ($invWithStatus[$i].Status -in @('MissingInTarget','NewerInSource')) { $default += ($i + 1) }
		}
		Write-Host "";
		Write-Host ("Selección por defecto: {0} sesiones (MissingInTarget/NewerInSource)." -f $default.Count) -ForegroundColor Yellow
		$selText = Read-Host "Elegí cuáles copiar: 'all' o lista 1,2,3 (Enter = usar selección por defecto)"
		$sel = if ($selText) { Parse-Selection -InputText $selText -Max $invWithStatus.Count } else { $default }
		if ($sel.Count -eq 0) {
			Write-Host "No se seleccionó nada. Fin." -ForegroundColor Yellow
			return
		}

		$selectedItems = @()
		foreach ($n in $sel) { $selectedItems += $invWithStatus[$n - 1] }

		Write-Section "Copiando seleccionadas"
		Copy-SelectedSessions -WorkspaceStorageRoot $root -SelectedItems $selectedItems -TargetHash $TargetHash

		if ($ExportMarkdown) {
			Write-Section "Export Markdown (best-effort)"
			foreach ($it in $selectedItems) {
				if ($it.Ext -eq 'json') {
					$out = Join-Path $PWD ($it.SessionId + '.recovered.md')
					try {
						Export-SessionToMarkdownBestEffort -SessionPath $it.Path -OutPath $out
					} catch {
						Write-Host "No pude exportar $($it.Path): $($_.Exception.Message)" -ForegroundColor Yellow
					}
				}
			}
		}

		if (-not $Reindex) {
			# Reindex opcional sugerido (menos fricción)
			$ans = Read-Host "¿Querés reindexar state.vscdb ahora? (s/N)"
			if ($ans -match '^(s|S|y|Y)$') { $Reindex = $true }
		}
		if ($Reindex) {
			Write-Section "Reindex state.vscdb"
			Invoke-ReindexWithPython -WorkspaceStorageRoot $root -TargetHash $TargetHash
		}

		Write-Section "Listo"
		Write-Host "Abrí VS Code y probá abrir la(s) sesión(es)." -ForegroundColor Green
		Pause-IfInteractive $pauseOnExit
		return
	}

	# Detectar hashes por needle si se provee
	$hashCandidates = @()
	if ($Needle) {
		Write-Section "Buscando hashes por needle"
		$hashCandidates = @(Find-HashesByNeedle -WorkspaceStorageRoot $root -NeedleText $Needle)
		if ($hashCandidates.Count -eq 0) {
			Write-Host "No encontré workspace.json que contenga '$Needle'." -ForegroundColor Red
		} else {
			$hashCandidates | Format-Table Hash, StateDbLastWrite, ChatSessionFiles, Path -Auto
		}
	}

	if (-not $TargetHash) {
		Write-Section "Seleccionar hash destino (workspace activo)"
		$all = @(Get-WorkspaceHashInfo -WorkspaceStorageRoot $root)
		$top = $all | Select-Object -First 15
		$chosen = Select-FromList -Prompt "Elegí el hash DESTINO (normalmente el state.vscdb más reciente)" -Items $top -ToLabel {
			param($it)
			"$($it.Hash) | stateDb=$($it.StateDbLastWrite) | chatFiles=$($it.ChatSessionFiles)"
		}
		if ($chosen) {
			$TargetHash = $chosen.Hash
		}
	}

	if (-not $SourceHash) {
		Write-Section "Seleccionar hash origen (donde está tu sesión perdida)"
		if ($hashCandidates.Count -gt 0) {
			$chosen = Select-FromList -Prompt "Elegí el hash ORIGEN" -Items $hashCandidates -ToLabel {
				param($it)
				"$($it.Hash) | stateDb=$($it.StateDbLastWrite) | chatFiles=$($it.ChatSessionFiles)"
			}
			if ($chosen) { $SourceHash = $chosen.Hash }
		}

		if (-not $SourceHash) {
			$srcManual = Read-Host "Pegá el hash ORIGEN (Enter=cancelar)"
			if ($srcManual) { $SourceHash = $srcManual }
		}
	}

	if (-not $TargetHash -or -not $SourceHash) {
		throw "Faltan hashes. Pasá -SourceHash y -TargetHash o usá modo interactivo con -Needle."
	}

	Write-Section "Resumen"
	Write-Host "Origen : $SourceHash" -ForegroundColor Gray
	Write-Host "Destino: $TargetHash" -ForegroundColor Gray
	if ($SessionId) { Write-Host "SessionId: $SessionId" -ForegroundColor Gray } else { Write-Host "SessionId: (todas)" -ForegroundColor Gray }

	# Backup selectivo
	$doBackup = Read-Host "¿Hacer backup de ORIGEN y DESTINO antes de tocar? (S/n)"
	if (-not $doBackup -or $doBackup -match '^(s|S|y|Y)$') {
		$backupRoot = Join-Path $PWD 'backups'
		New-Item -ItemType Directory -Force -Path $backupRoot | Out-Null
		New-Backup -WorkspaceStorageRoot $root -Hash $SourceHash -BackupRoot $backupRoot | Out-Null
		if ($TargetHash -ne $SourceHash) {
			New-Backup -WorkspaceStorageRoot $root -Hash $TargetHash -BackupRoot $backupRoot | Out-Null
		}
	}

	Write-Section "Copiando sesiones"
	$copied = Copy-ChatSessions -WorkspaceStorageRoot $root -Source $SourceHash -Target $TargetHash -SessionIdOrNull $SessionId

	if ($ExportMarkdown) {
		Write-Section "Export Markdown (best-effort)"
		foreach ($p in $copied) {
			if ($p -like '*.json') {
				$out = Join-Path $PWD (([IO.Path]::GetFileNameWithoutExtension($p)) + '.recovered.md')
				try {
					Export-SessionToMarkdownBestEffort -SessionPath $p -OutPath $out
				} catch {
					Write-Host "No pude exportar $($p): $($_.Exception.Message)" -ForegroundColor Yellow
				}
			}
		}
	}

	if ($Reindex) {
		Write-Section "Reindex state.vscdb"
		Invoke-ReindexWithPython -WorkspaceStorageRoot $root -TargetHash $TargetHash
	}

	Write-Section "Listo"
	Write-Host "Abrí VS Code y probá abrir la sesión desde Chat -> Sessions/Recent." -ForegroundColor Green
	Write-Host "Si sigue sin abrir, repetí con -Reindex (requiere Python)." -ForegroundColor Yellow
}

Main

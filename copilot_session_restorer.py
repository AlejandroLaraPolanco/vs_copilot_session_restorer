#!/usr/bin/env python3
"""VS Code Copilot Sessions Restorer (Python)

Objetivo
- Recuperar sesiones de Copilot Chat/Agent (chatSessions) cuando VS Code cambia el workspace ID
  (por ejemplo al pasar de single-folder a multi-root) y quedan sesiones "en Recent" pero no abren.

Qué hace (modo wizard por defecto)
- Detecta canal (Code / Code - Insiders)
- Pide una sola ruta: .code-workspace o carpeta
- Encuentra hashes relacionados buscando en workspace.json
- Elige hash destino automáticamente (state.vscdb más reciente), con opción de override
- Lista chatSessions con Created/Updated y status (Missing/Newer/Already)
- Copia las seleccionadas al destino
- Opcional: reindexa state.vscdb (sqlite) escribiendo chat.ChatSessionStore.index

Sin dependencias externas para ejecutar (usa sqlite3 estándar). Para generar .exe: PyInstaller.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import sqlite3
import sys
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Sequence, Tuple

CHAT_INDEX_KEY = "chat.ChatSessionStore.index"


@dataclass(frozen=True)
class ChannelRoot:
    channel: str
    root: Path


@dataclass(frozen=True)
class HashInfo:
    hash: str
    path: Path
    workspace_json: Path
    state_db: Path
    state_db_mtime: Optional[datetime]
    chat_dir: Path
    chat_files: int


@dataclass(frozen=True)
class SessionItem:
    hash: str
    session_id: str
    title: str
    created: datetime
    updated: datetime
    ext: str
    path: Path


def eprint(*args: object) -> None:
    print(*args, file=sys.stderr)


def now_stamp() -> str:
    return datetime.now().strftime("%Y%m%d-%H%M%S")


def dt_from_ts(ts: float) -> datetime:
    return datetime.fromtimestamp(ts)


def get_channel_roots() -> List[ChannelRoot]:
    appdata = os.environ.get("APPDATA")
    if not appdata:
        return []
    roots: List[ChannelRoot] = []
    for ch in ("Code", "Code - Insiders"):
        p = Path(appdata) / ch / "User" / "workspaceStorage"
        if p.exists() and p.is_dir():
            roots.append(ChannelRoot(channel=ch, root=p))
    return roots


def resolve_input_path(p: str) -> Path:
    # Trim quotes commonly pasted from Explorer
    p2 = p.strip().strip('"').strip("'")
    return Path(p2).expanduser().resolve()


def to_file_uri(p: Path) -> str:
    # as_uri encodes spaces etc.
    return p.as_uri()


def win_uri_variants(p: Path) -> List[str]:
    """Return file URI variants commonly seen in VS Code storage on Windows.

    VS Code sometimes stores file URIs with the drive colon encoded (c%3A).
    We generate a few variants to maximize matches in workspace.json.
    """
    try:
        s = str(p)
    except Exception:
        return []

    variants: List[str] = []

    # Standard URI
    try:
        variants.append(p.as_uri())
    except Exception:
        pass

    # Manual forms
    # C:\Users\A -> /C:/Users/A (and lower)
    drive = ""
    rest = s
    if len(s) >= 2 and s[1] == ":":
        drive = s[0]
        rest = s[2:]
    rest_slash = rest.replace("\\", "/")
    if drive:
        variants.append(f"file:///{drive}:{rest_slash}")
        variants.append(f"file:///{drive.lower()}:{rest_slash}")
        # Encoded colon variant (c%3A)
        variants.append(f"file:///{drive.lower()}%3A{rest_slash}")
        variants.append(f"file:///{drive.lower()}%3a{rest_slash}")

    # Unique
    out: List[str] = []
    seen: set[str] = set()
    for v in variants:
        if v and v not in seen:
            seen.add(v)
            out.append(v)
    return out


def load_code_workspace_folders(workspace_file: Path) -> List[str]:
    """Extract folder needles from a .code-workspace.

    Supports entries like:
    - { "path": "relative/or/absolute" }
    - { "uri": "file:///..." }
    """
    needles: List[str] = []
    try:
        obj = json.loads(workspace_file.read_text(encoding="utf-8"))
    except Exception:
        try:
            obj = json.loads(workspace_file.read_text(errors="ignore"))
        except Exception:
            return needles

    if not isinstance(obj, dict):
        return needles

    folders = obj.get("folders")
    if not isinstance(folders, list):
        return needles

    for f in folders:
        if not isinstance(f, dict):
            continue
        uri = f.get("uri")
        if isinstance(uri, str) and uri.strip():
            needles.append(uri.strip())
            continue
        path = f.get("path")
        if isinstance(path, str) and path.strip():
            p = Path(path)
            if not p.is_absolute():
                p = (workspace_file.parent / p).resolve()
            needles.append(str(p))
            needles.append(str(p).replace("\\", "/"))
            needles.extend(win_uri_variants(p))

    # unique
    out: List[str] = []
    seen: set[str] = set()
    for n in needles:
        if n and n not in seen:
            seen.add(n)
            out.append(n)
    return out


def read_text_best_effort(path: Path) -> str:
    # workspace.json should be utf-8; fallback for weird encodings
    try:
        return path.read_text(encoding="utf-8")
    except Exception:
        return path.read_text(errors="ignore")


def find_hashes_by_needles(workspace_storage: Path, needles: Sequence[str]) -> List[HashInfo]:
    needles2 = [n for n in needles if n and n.strip()]
    if not needles2:
        raise ValueError("No needles")

    hits: List[HashInfo] = []
    for d in workspace_storage.iterdir():
        if not d.is_dir():
            continue
        workspace_json = d / "workspace.json"
        if not workspace_json.exists():
            continue
        content = read_text_best_effort(workspace_json)
        content_low = content.lower()
        ok = False
        for n in needles2:
            if n.lower() in content_low:
                ok = True
                break
        if not ok:
            continue

        state_db = d / "state.vscdb"
        state_db_mtime = dt_from_ts(state_db.stat().st_mtime) if state_db.exists() else None
        chat_dir = d / "chatSessions"
        chat_files = 0
        if chat_dir.exists() and chat_dir.is_dir():
            try:
                chat_files = sum(1 for _ in chat_dir.iterdir() if _.is_file())
            except Exception:
                chat_files = 0

        hits.append(
            HashInfo(
                hash=d.name,
                path=d,
                workspace_json=workspace_json,
                state_db=state_db,
                state_db_mtime=state_db_mtime,
                chat_dir=chat_dir,
                chat_files=chat_files,
            )
        )

    hits.sort(key=lambda x: (x.state_db_mtime or datetime.min), reverse=True)
    return hits


def is_code_workspace_file(p: Path) -> bool:
    return p.is_file() and p.suffix.lower() == ".code-workspace"


def build_needles_for_workspace_input(workspace_or_folder: Path) -> Tuple[str, List[str]]:
    # Returns display label and needles list
    if is_code_workspace_file(workspace_or_folder):
        ws_full = str(workspace_or_folder)
        ws_uri = to_file_uri(workspace_or_folder)
        needles = [
            ws_full,
            ws_full.replace("\\", "/"),
            ws_uri,
            ws_uri.lower(),
        ]
        # Also include folders inside the workspace file (often what appears in workspace.json)
        needles.extend(load_code_workspace_folders(workspace_or_folder))
        return f"WorkspaceFile: {ws_full}", needles

    if workspace_or_folder.is_dir():
        folder_full = str(workspace_or_folder)
        folder_uri = to_file_uri(workspace_or_folder)
        needles = [
            folder_full,
            folder_full.replace("\\", "/"),
            folder_uri,
            folder_uri.lower(),
        ]
        needles.extend(win_uri_variants(workspace_or_folder))
        return f"WorkspaceFolder: {folder_full}", needles

    # If user pasted a path that doesn't exist, keep it for searching anyway
    raw = str(workspace_or_folder)
    needles = [raw, raw.replace("\\", "/"), raw.lower()]
    return f"Path: {raw}", needles


def try_parse_session_meta_json(path: Path) -> Tuple[Optional[str], str, Optional[int]]:
    """Return (session_id, title, creation_ms) best-effort."""
    try:
        obj = json.loads(path.read_text(encoding="utf-8"))
        if not isinstance(obj, dict):
            return None, "", None
        session_id = obj.get("sessionId")
        session_id = str(session_id) if isinstance(session_id, str) and session_id else None

        title = ""
        for k in ("customTitle", "title", "computedTitle"):
            v = obj.get(k)
            if isinstance(v, str) and v.strip():
                title = v.strip()
                break

        creation_ms = None
        cd = obj.get("creationDate")
        if isinstance(cd, (int, float)):
            cdi = int(cd)
            if cdi < 10_000_000_000:
                cdi *= 1000
            creation_ms = cdi

        return session_id, title, creation_ms
    except Exception:
        return None, "", None


def stat_created_updated(path: Path) -> Tuple[datetime, datetime]:
    st = path.stat()
    # On Windows, st_ctime is creation time. Elsewhere it is metadata change time.
    created = dt_from_ts(st.st_ctime)
    updated = dt_from_ts(st.st_mtime)
    return created, updated


def session_inventory(workspace_storage: Path, hashes: Sequence[str]) -> List[SessionItem]:
    items: List[SessionItem] = []
    for h in hashes:
        chat_dir = workspace_storage / h / "chatSessions"
        if not chat_dir.exists() or not chat_dir.is_dir():
            continue
        for p in chat_dir.iterdir():
            if not p.is_file():
                continue
            ext = p.suffix.lower().lstrip(".")
            if ext not in ("json", "jsonl"):
                continue

            session_id = p.stem
            title = ""
            created, updated = stat_created_updated(p)

            if ext == "json":
                sid2, title2, creation_ms = try_parse_session_meta_json(p)
                if sid2:
                    session_id = sid2
                if title2:
                    title = title2
                if creation_ms:
                    try:
                        created = datetime.fromtimestamp(creation_ms / 1000)
                    except Exception:
                        pass

            items.append(
                SessionItem(
                    hash=h,
                    session_id=session_id,
                    title=title,
                    created=created,
                    updated=updated,
                    ext=ext,
                    path=p,
                )
            )

    items.sort(key=lambda x: x.updated, reverse=True)
    return items


def target_session_map(workspace_storage: Path, target_hash: str) -> Dict[str, datetime]:
    m: Dict[str, datetime] = {}
    chat_dir = workspace_storage / target_hash / "chatSessions"
    if not chat_dir.exists() or not chat_dir.is_dir():
        return m

    for p in chat_dir.iterdir():
        if not p.is_file():
            continue
        if p.suffix.lower() not in (".json", ".jsonl"):
            continue
        sid = p.stem
        if p.suffix.lower() == ".json":
            sid2, _, _ = try_parse_session_meta_json(p)
            if sid2:
                sid = sid2
        _, updated = stat_created_updated(p)
        m[sid] = updated

    return m


def status_for(item: SessionItem, target_map: Dict[str, datetime]) -> str:
    if item.session_id not in target_map:
        return "MissingInTarget"
    return "NewerInSource" if item.updated > target_map[item.session_id] else "AlreadyInTarget"


def fmt_dt(dt: datetime) -> str:
    return dt.strftime("%Y-%m-%d %H:%M:%S")


def print_hashes(hashes: List[HashInfo]) -> None:
    print("\n=== Workspaces encontrados (hashes) ===")
    print("Un 'WorkspaceHash' es una carpeta interna de VS Code en workspaceStorage.")
    print("Elegimos como DESTINO el más 'reciente' según la fecha de state.vscdb (uso reciente).")
    print("\n N  WorkspaceHash                        LastUsed(state.vscdb)      SessionsOnDisk")
    print("--- ---------------------------------- -------------------------- -------------")
    for i, h in enumerate(hashes, start=1):
        mt = fmt_dt(h.state_db_mtime) if h.state_db_mtime else "(none)"
        print(f"{i:>2}  {h.hash:<34} {mt:<26} {h.chat_files:>13}")


def backup_hash(workspace_storage: Path, hash_id: str, backup_root: Path) -> Path:
    src = workspace_storage / hash_id
    if not src.exists():
        raise FileNotFoundError(f"Hash no existe: {hash_id}")
    dest = backup_root / f"workspaceStorage_{hash_id}_{now_stamp()}"
    dest.parent.mkdir(parents=True, exist_ok=True)
    print(f"Backup -> {dest}")
    shutil.copytree(src, dest, dirs_exist_ok=True)
    return dest


def export_markdown_best_effort(session_path: Path, out_path: Path) -> None:
    # Similar to PS best-effort: extract common keys
    obj = json.loads(session_path.read_text(encoding="utf-8"))
    seen: set[str] = set()
    chunks: List[str] = []

    def walk(x: object) -> None:
        if x is None:
            return
        if isinstance(x, str):
            return
        if isinstance(x, dict):
            for k, v in x.items():
                if k in ("text", "value", "content", "message", "prompt", "response") and isinstance(v, str):
                    t = v.strip()
                    if t and t not in seen:
                        seen.add(t)
                        chunks.append(t)
                else:
                    walk(v)
            return
        if isinstance(x, list):
            for it in x:
                walk(it)
            return

    walk(obj)

    lines = [
        "# Copilot Chat recuperado",
        "",
        f"**Archivo:** {session_path}",
        "",
        "---",
        "",
    ]
    for c in chunks:
        lines.append(c)
        lines.append("")
        lines.append("---")
        lines.append("")

    out_path.write_text("\n".join(lines), encoding="utf-8")


def choose_int(prompt: str, default: int, min_v: int, max_v: int) -> int:
    raw = input(prompt).strip().strip("`")
    if not raw:
        return default
    try:
        n = int(raw)
    except ValueError:
        return default
    return max(min_v, min(max_v, n))


def choose_yes_no(prompt: str, default_yes: bool) -> bool:
    suffix = " (S/n)" if default_yes else " (s/N)"
    raw = input(prompt + suffix + ": ").strip()
    if not raw:
        return default_yes
    return raw.lower().startswith(("s", "y"))


def parse_selection(raw: str, max_n: int) -> List[int]:
    r = raw.strip().strip("`").lower()
    if r == "all":
        return list(range(1, max_n + 1))
    nums: List[int] = []
    for part in r.split(","):
        p = part.strip()
        if not p:
            continue
        if p.isdigit():
            n = int(p)
            if 1 <= n <= max_n:
                nums.append(n)
    # Unique preserving order
    out: List[int] = []
    for n in nums:
        if n not in out:
            out.append(n)
    return out


def build_index(chat_dir: Path) -> dict:
    entries: Dict[str, dict] = {}

    def file_mtime_ms(p: Path) -> int:
        try:
            return int(p.stat().st_mtime * 1000)
        except Exception:
            return 0

    for p in sorted(chat_dir.glob("*.json")):
        session_id = p.stem
        last_ms = file_mtime_ms(p)
        title = "New Chat"
        is_empty = False

        try:
            obj = json.loads(p.read_text(encoding="utf-8"))
            if isinstance(obj, dict):
                sid = obj.get("sessionId")
                if isinstance(sid, str) and sid:
                    session_id = sid
                for k in ("customTitle", "title", "computedTitle"):
                    v = obj.get(k)
                    if isinstance(v, str) and v.strip():
                        title = v.strip()
                        break
                reqs = obj.get("requests")
                if isinstance(reqs, list):
                    is_empty = len(reqs) == 0
        except Exception:
            pass

        entries[str(session_id)] = {
            "sessionId": str(session_id),
            "title": title,
            "lastMessageDate": int(last_ms),
            "isEmpty": bool(is_empty),
            "isExternal": False,
        }

    for p in sorted(chat_dir.glob("*.jsonl")):
        session_id = p.stem
        if session_id in entries:
            continue
        entries[str(session_id)] = {
            "sessionId": str(session_id),
            "title": "New Chat",
            "lastMessageDate": int(file_mtime_ms(p)),
            "isEmpty": False,
            "isExternal": False,
        }

    return {"version": 1, "entries": entries}


def reindex_state_db(target_root: Path) -> None:
    db_path = target_root / "state.vscdb"
    chat_dir = target_root / "chatSessions"
    if not db_path.exists():
        raise FileNotFoundError(f"No existe state.vscdb: {db_path}")
    if not chat_dir.exists():
        raise FileNotFoundError(f"No existe chatSessions: {chat_dir}")

    db_backup = db_path.with_suffix(db_path.suffix + f".bak-{now_stamp()}")
    shutil.copy2(db_path, db_backup)
    print(f"Backup DB -> {db_backup}")

    index = build_index(chat_dir)
    value = json.dumps(index, ensure_ascii=False)

    con = sqlite3.connect(str(db_path))
    try:
        cur = con.cursor()
        cur.execute("CREATE TABLE IF NOT EXISTS ItemTable (key TEXT PRIMARY KEY, value TEXT)")
        cur.execute(
            "INSERT INTO ItemTable(key,value) VALUES(?,?) "
            "ON CONFLICT(key) DO UPDATE SET value=excluded.value",
            (CHAT_INDEX_KEY, value),
        )
        con.commit()
    finally:
        con.close()

    print(f"OK: reindex wrote {CHAT_INDEX_KEY} ({len(index['entries'])} entries)")


def run_wizard(
    channel: Optional[str],
    workspace_input: Optional[str],
    skip_backup: bool,
    export_md: bool,
    do_reindex: Optional[bool],
    extra_needles: Optional[List[str]] = None,
) -> int:
    roots = get_channel_roots()
    if not roots:
        eprint("No encontré workspaceStorage en %APPDATA% para Code/Insiders")
        return 2

    if channel:
        chosen = next((r for r in roots if r.channel.lower() == channel.lower()), None)
        if not chosen:
            eprint(f"Canal inválido: {channel}. Opciones: {[r.channel for r in roots]}")
            return 2
    else:
        if len(roots) == 1:
            chosen = roots[0]
        else:
            print("Detecté más de un canal:")
            for i, r in enumerate(roots, start=1):
                print(f"[{i}] {r.channel} -> {r.root}")
            idx = choose_int("Elegí canal (Enter = 1): ", default=1, min_v=1, max_v=len(roots))
            chosen = roots[idx - 1]

    workspace_storage = chosen.root
    print(f"\nworkspaceStorage: {workspace_storage}")
    print("Tip: cerrá VS Code antes de copiar/reindexar para evitar locks.")

    if not workspace_input:
        workspace_input = input("Pegá la ruta del .code-workspace o de la carpeta del proyecto: ").strip()
    if not workspace_input:
        print("Cancelado")
        return 0

    ws_path = resolve_input_path(workspace_input)
    label, needles = build_needles_for_workspace_input(ws_path)
    if extra_needles:
        needles.extend([n for n in extra_needles if n and n.strip()])
    print(f"\n{label}")
    if is_code_workspace_file(ws_path):
        print(f"URI: {to_file_uri(ws_path)}")
    elif ws_path.is_dir():
        print(f"URI: {to_file_uri(ws_path)}")

    hashes = find_hashes_by_needles(workspace_storage, needles)
    if not hashes:
        eprint("No encontré hashes relacionados en workspace.json.")
        # Interactive fallback: ask for a keyword (folder name, part of path, etc.)
        if not getattr(run_wizard, "_non_interactive", False):
            extra = input("Pegá un keyword extra para buscar (ej: nombre de carpeta del workspace). Enter = cancelar: ").strip()
            if extra:
                needles2 = list(needles)
                needles2.append(extra)
                hashes = find_hashes_by_needles(workspace_storage, needles2)
        if not hashes:
            eprint("Probá con --workspace apuntando a una carpeta dentro del workspace o usando --needle.")
            return 2

    print_hashes(hashes)

    target_hash = hashes[0].hash
    idx = choose_int("Elegí hash DESTINO (Enter = 1): ", default=1, min_v=1, max_v=len(hashes))
    target_hash = hashes[idx - 1].hash
    print(f"Destino: {target_hash}")

    source_hashes = [h.hash for h in hashes if h.hash != target_hash and h.chat_files > 0]
    if not source_hashes:
        print("No hay hashes ORIGEN con chatSessions para copiar")
        return 0

    if not skip_backup:
        backup_root = Path.cwd() / "backups"
        backup_root.mkdir(parents=True, exist_ok=True)
        print("\n=== Backups (automático) ===")
        backup_hash(workspace_storage, target_hash, backup_root)
        for h in source_hashes:
            backup_hash(workspace_storage, h, backup_root)

    print("\n=== Inventario de sesiones ===")
    inv = session_inventory(workspace_storage, source_hashes)
    if not inv:
        print("No encontré sesiones en hashes origen")
        return 0

    tmap = target_session_map(workspace_storage, target_hash)

    # Build rows with status
    rows: List[Tuple[int, SessionItem, str]] = []
    for i, it in enumerate(inv, start=1):
        rows.append((i, it, status_for(it, tmap)))

    print("Qué significa 'CopyDecision':")
    print("- MissingInTarget: no existe en el destino (debería copiarse)")
    print("- NewerInSource: existe pero la fuente es más nueva (debería copiarse)")
    print("- AlreadyInTarget: ya está en destino y no es más vieja (no hace falta)\n")

    print(" N  CopyDecision    LastUpdated          CreatedAt            SessionId                              Title (best-effort)")
    print("--- -------------- ------------------- ------------------- ------------------------------------ --------------------")
    for n, it, st in rows:
        title = (it.title[:60] + "…") if len(it.title) > 60 else it.title
        print(
            f"{n:>2}  {st:<14} {fmt_dt(it.updated):<19} {fmt_dt(it.created):<19} {it.session_id:<36} {title}"
        )

    default_sel = [n for (n, it, st) in rows if st in ("MissingInTarget", "NewerInSource")]
    print(f"\nSelección por defecto: {len(default_sel)} sesiones (MissingInTarget/NewerInSource)")

    # dry-run: no preguntar, no copiar, solo mostrar qué haría
    if getattr(run_wizard, "_dry_run", False):
        sel = default_sel
        print("\n=== DRY-RUN ===")
        if not sel:
            print("No hay nada para copiar (según selección por defecto).")
        else:
            print(f"Copiaría {len(sel)} sesiones al hash destino {target_hash}:")
            for i in sel:
                it = rows[i - 1][1]
                print(f"- {it.session_id} ({it.ext}) from {it.hash} -> {it.path.name}")
        input("Enter para salir")
        return 0

    raw_sel = input("Elegí cuáles copiar: 'all' o lista 1,2,3 (Enter = default): ").strip()
    sel = parse_selection(raw_sel, len(rows)) if raw_sel else default_sel
    if not sel:
        print("No se seleccionó nada")
        return 0

    selected = [rows[i - 1][1] for i in sel]

    target_chat = workspace_storage / target_hash / "chatSessions"
    target_chat.mkdir(parents=True, exist_ok=True)

    print("\n=== Copiando seleccionadas ===")
    for it in selected:
        dest = target_chat / it.path.name
        shutil.copy2(it.path, dest)
        print(f"Copiado -> {dest}")

    if export_md:
        print("\n=== Export Markdown (best-effort) ===")
        for it in selected:
            if it.ext != "json":
                continue
            out = Path.cwd() / f"{it.session_id}.recovered.md"
            try:
                export_markdown_best_effort(it.path, out)
                print(f"Exportado -> {out}")
            except Exception as ex:
                print(f"No pude exportar {it.path}: {ex}")

    if do_reindex is None:
        do_reindex = choose_yes_no("¿Querés reindexar state.vscdb ahora?", default_yes=False)

    if do_reindex:
        print("\n=== Reindex state.vscdb ===")
        reindex_state_db(workspace_storage / target_hash)

    print("\nListo. Abrí VS Code y probá abrir la(s) sesión(es).")
    input("Enter para salir")
    return 0


def main(argv: Sequence[str]) -> int:
    p = argparse.ArgumentParser(description="Restore VS Code Copilot chatSessions (wizard by default)")
    p.add_argument(
        "workspace_pos",
        nargs="?",
        help="Path to .code-workspace or folder (positional). Equivalent to --workspace.",
    )
    p.add_argument("--channel", choices=["Code", "Code - Insiders"], help="VS Code channel")
    p.add_argument("--workspace", help="Path to .code-workspace or folder")
    p.add_argument("--needle", action="append", help="Extra keyword(s) to search in workspace.json (repeatable)")
    p.add_argument("--skip-backup", action="store_true", help="Skip backups (not recommended)")
    p.add_argument("--export-md", action="store_true", help="Export selected sessions to Markdown (best-effort)")
    p.add_argument("--reindex", action="store_true", help="Reindex state.vscdb after copying")
    p.add_argument("--dry-run", action="store_true", help="Only compute and show what would be copied; do not modify anything")
    args = p.parse_args(argv)

    # Allow simplest usage: python copilot_session_restorer.py "C:\path\x.code-workspace"
    workspace_arg = args.workspace or args.workspace_pos

    # Wizard always, but can be fully prefilled by args
    do_reindex: Optional[bool] = True if args.reindex else None
    # Hacky but simple: attach flag to function for access inside wizard without rewriting signature
    setattr(run_wizard, "_dry_run", bool(args.dry_run))
    # If user provided enough args, we could treat it as non-interactive. Keep it simple:
    setattr(run_wizard, "_non_interactive", False)
    return run_wizard(
        channel=args.channel,
        workspace_input=workspace_arg,
        skip_backup=args.skip_backup,
        export_md=args.export_md,
        do_reindex=do_reindex,
        extra_needles=args.needle,
    )


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))

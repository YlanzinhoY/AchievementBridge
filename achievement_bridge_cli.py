#!/usr/bin/env python3
"""Human-friendly, dependency-free console for Achievement Bridge on Windows."""

from __future__ import annotations

import json
import hashlib
import os
import re
import shutil
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
import webbrowser
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Annotated, Callable, Iterable, TextIO, TypeVar

import typer
import velopack
from achievement_bridge_tray import TrayAction, TrayInstance, run_web_tray
from rich import box
from rich.console import Console
from rich.panel import Panel
from rich.prompt import Prompt
from rich.table import Table
from rich.text import Text

try:
    import winreg
except ImportError:  # pragma: no cover - the packaged application is Windows-only
    winreg = None  # type: ignore[assignment]


SUPPORTED_SYNC_PROVIDERS = ("gse", "rune", "rockstar", "uplay_r2")
MONITORED_PROVIDERS = ("ubisoft",)
PROVIDER_PRIORITY = ("gse", "rune", "rockstar", "uplay_r2", "ubisoft", "steam", "epic", "gog", "ea", "xbox")
DEFAULT_NOTIFICATION_PREVIEW_MS = 7000
MIN_NOTIFICATION_PREVIEW_MS = 1000
MAX_NOTIFICATION_PREVIEW_MS = 60_000
DEFAULT_API_URL = "http://127.0.0.1:47650"
console = Console(highlight=False)
ResultType = TypeVar("ResultType")
_api_clients: dict[tuple[Path, str | None, Path | None], "BridgeApiClient"] = {}
_api_clients_lock = threading.Lock()


@dataclass(frozen=True)
class InstalledGame:
    app_id: int
    name: str
    directory: Path


@dataclass(frozen=True)
class SupportReport:
    game: InstalledGame
    provider: str
    confidence: int
    achievement_count: int | None
    status: str
    state_available: bool = True


@dataclass(frozen=True)
class AchievementEvent:
    provider: str
    app_id: int | None
    product_id: int | None
    achievement: str
    timestamp: int | None
    recovered: bool


@dataclass(frozen=True)
class AvailableAchievement:
    index: int
    api_name: str
    unlocked: bool
    name: str
    global_percent: float


@dataclass(frozen=True)
class CliOptions:
    bridge: str | None = None
    steam_root: str | None = None


@dataclass(frozen=True)
class MonitorOptions:
    bridge: str | None
    steam_root: str | None
    interval_ms: int
    journal: str | None
    log: str | None
    no_file_log: bool
    no_scan: bool
    no_notifications: bool
    native_toast: bool
    allow_duplicate: bool


@dataclass(frozen=True)
class SteamHostSetup:
    installed: bool
    changed: bool
    restart_required: bool
    library: Path | None
    message: str


class BridgeApiClient:
    """Typed UI boundary for the local Go control plane."""

    def __init__(self, bridge: Path, steam_root: str | None, web_root: Path | None = None) -> None:
        self.bridge = bridge
        self.steam_root = steam_root
        self.web_root = web_root
        self.base_url = os.environ.get("ACHIEVEMENT_BRIDGE_API_URL", DEFAULT_API_URL).rstrip("/")
        self._startup_lock = threading.Lock()

    def request(
        self,
        method: str,
        path: str,
        payload: dict[str, object] | None = None,
        timeout: float | None = 45,
    ) -> dict[str, object]:
        try:
            return self._request_once(method, path, payload, timeout)
        except ConnectionError:
            self.ensure_started()
            return self._request_once(method, path, payload, timeout)

    def ensure_started(self) -> None:
        with self._startup_lock:
            try:
                self._request_once("GET", "/v1/health", timeout=1)
                return
            except (ConnectionError, RuntimeError):
                pass

            api = find_api(self.bridge)
            arguments = api_start_arguments(api, self.bridge, self.steam_root, self.web_root)
            log_path = Path(default_api_log_path())
            log_path.parent.mkdir(parents=True, exist_ok=True)
            creation_flags = subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0
            with log_path.open("a", encoding="utf-8", newline="") as log_file:
                subprocess.Popen(
                    arguments,
                    cwd=api.parent,
                    stdin=subprocess.DEVNULL,
                    stdout=log_file,
                    stderr=subprocess.STDOUT,
                    creationflags=creation_flags,
                )

            last_error: Exception | None = None
            # The Zig core may be completing an interrupted Steam preview.
            # StoreStats recovery is intentionally allowed to outlive the
            # normal fast startup path.
            for _ in range(1800):
                time.sleep(0.1)
                try:
                    self._request_once("GET", "/v1/health", timeout=1)
                    return
                except (ConnectionError, RuntimeError) as error:
                    last_error = error
            raise RuntimeError(
                f"a API local não ficou disponível; consulte {log_path}"
            ) from last_error

    def _request_once(
        self,
        method: str,
        path: str,
        payload: dict[str, object] | None = None,
        timeout: float | None = 45,
    ) -> dict[str, object]:
        body = None if payload is None else json.dumps(payload).encode("utf-8")
        headers = {"Accept": "application/json"}
        if body is not None:
            headers["Content-Type"] = "application/json"
        request = urllib.request.Request(
            f"{self.base_url}{path}",
            data=body,
            headers=headers,
            method=method,
        )
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                decoded = json.loads(response.read().decode("utf-8"))
        except urllib.error.HTTPError as error:
            try:
                details = json.loads(error.read().decode("utf-8")).get("error", {})
                code = str(details.get("code", "api_error"))
                message = str(details.get("message", code))
            except (UnicodeDecodeError, json.JSONDecodeError, AttributeError):
                code = "api_error"
                message = str(error)
            friendly = {
                "AchievementAlreadyUnlockedForPreview": (
                    "essa conquista já está desbloqueada e não pode ser usada na simulação"
                ),
                "AchievementNotFound": "a Steam não encontrou essa conquista",
            }.get(code, message)
            raise RuntimeError(friendly) from error
        except (urllib.error.URLError, TimeoutError, ConnectionError, OSError) as error:
            raise ConnectionError("a API local do Achievement Bridge não está disponível") from error
        if not isinstance(decoded, dict):
            raise RuntimeError("a API local retornou uma resposta inválida")
        return decoded

    def stream_monitor_events(self) -> Iterable[str]:
        request = urllib.request.Request(
            f"{self.base_url}/v1/monitor/events",
            headers={"Accept": "text/event-stream"},
            method="GET",
        )
        try:
            with urllib.request.urlopen(request, timeout=None) as response:
                for raw_line in response:
                    line = raw_line.decode("utf-8", errors="replace").rstrip("\r\n")
                    if not line.startswith("data: "):
                        continue
                    value = json.loads(line[6:])
                    if isinstance(value, str):
                        yield value
        except (urllib.error.URLError, TimeoutError, ConnectionError, OSError) as error:
            raise ConnectionError("o stream de eventos do Bridge foi encerrado") from error

    def shutdown(self) -> None:
        try:
            self._request_once("POST", "/v1/shutdown", {}, timeout=5)
        except (ConnectionError, RuntimeError):
            pass


def find_api(bridge: Path) -> Path:
    root = application_root()
    candidates = (
        os.environ.get("ACHIEVEMENT_BRIDGE_API_PATH"),
        str(bridge.parent / "achievement-bridge-api.exe"),
        str(root / "achievement-bridge-api.exe"),
        str(root / "zig-out" / "bin" / "achievement-bridge-api.exe"),
    )
    for candidate in candidates:
        if candidate and Path(candidate).is_file():
            return Path(candidate).resolve()
    raise FileNotFoundError(
        "achievement-bridge-api.exe não encontrada; execute o build do gateway Go"
    )


def api_start_arguments(
    api: Path,
    bridge: Path,
    steam_root: str | None,
    web_root: Path | None = None,
) -> list[str]:
    arguments = [
        str(api),
        "--core",
        str(bridge),
    ]
    if steam_root:
        arguments += ["--steam-root", steam_root]
    if web_root is not None:
        arguments += ["--web-root", str(web_root)]
    return arguments


def find_web_root() -> Path:
    """Locate the built web interface in source trees and packaged releases."""
    root = application_root()
    candidates = (
        os.environ.get("ACHIEVEMENT_BRIDGE_WEB_ROOT"),
        str(root / "web"),
        str(root / "frontend" / "dist"),
    )
    for candidate in candidates:
        if not candidate:
            continue
        path = Path(candidate).expanduser()
        if (path / "index.html").is_file():
            return path.resolve()
    raise FileNotFoundError(
        "a interface Web não foi encontrada; execute 'bun run build' dentro de frontend"
    )


def api_client(bridge: Path, steam_root: str | None) -> BridgeApiClient:
    try:
        web_root: Path | None = find_web_root()
    except FileNotFoundError:
        # The terminal remains usable in a source checkout before the frontend
        # is built. Choosing Web reports the actionable build instruction.
        web_root = None
    key = (bridge, steam_root, web_root)
    with _api_clients_lock:
        client = _api_clients.get(key)
        if client is None:
            client = BridgeApiClient(bridge, steam_root, web_root)
            _api_clients[key] = client
        return client


class EventParser:
    """Parses the stable multiline envelope emitted by the Zig host."""

    def __init__(self) -> None:
        self._inside = False
        self._fields: dict[str, str] = {}

    def push(self, line: str) -> AchievementEvent | None:
        stripped = line.strip()
        if stripped == "[AchievementBridge]":
            self._inside = True
            self._fields = {}
            return None
        if not self._inside:
            return None
        if stripped:
            if "=" in stripped:
                key, value = stripped.split("=", 1)
                self._fields[key] = value
            return None

        self._inside = False
        if self._fields.get("state") != "unlocked":
            return None
        provider = self._fields.get("provider")
        achievement = self._fields.get("achievement")
        if not provider or not achievement:
            return None
        return AchievementEvent(
            provider=provider.lower(),
            app_id=_optional_int(self._fields.get("appid")),
            product_id=_optional_int(self._fields.get("product_id")),
            achievement=achievement,
            timestamp=_optional_int(self._fields.get("timestamp")),
            recovered=self._fields.get("recovered", "false").lower() == "true",
        )


class LogSink:
    def __init__(self, path: Path | None) -> None:
        self._lock = threading.Lock()
        self._file: TextIO | None = None
        if path is not None:
            path.parent.mkdir(parents=True, exist_ok=True)
            self._file = path.open("a", encoding="utf-8", newline="")

    def write(self, message: str) -> None:
        rendered = f"[{datetime.now().astimezone().isoformat(timespec='seconds')}] {message}"
        with self._lock:
            print(rendered, flush=True)
            if self._file is not None:
                self._file.write(rendered + "\n")
                self._file.flush()

    def close(self) -> None:
        if self._file is not None:
            self._file.close()


def _optional_int(value: str | None) -> int | None:
    try:
        return int(value) if value is not None else None
    except ValueError:
        return None


def find_bridge(explicit: str | None = None) -> Path:
    root = application_root()
    candidates = (
        explicit,
        os.environ.get("ACHIEVEMENT_BRIDGE_PATH"),
        str(root / "achievement-bridge.exe"),
        str(root / "zig-out" / "bin" / "achievement-bridge.exe"),
        str(root / "AchievementBridge" / "achievement-bridge.exe"),
    )
    for candidate in candidates:
        if candidate and Path(candidate).is_file():
            return Path(candidate).resolve()
    raise FileNotFoundError("achievement-bridge.exe não encontrado; execute 'zig build -Doptimize=ReleaseSafe'")


def application_root() -> Path:
    """Return the install directory both from source and from a frozen executable."""
    if getattr(sys, "frozen", False):
        return Path(sys.executable).resolve().parent
    return Path(__file__).resolve().parent


def initialize_velopack() -> None:
    """Handle Velopack lifecycle hooks only inside an installed release."""
    if getattr(sys, "frozen", False) and (application_root() / "sq.version").is_file():
        velopack.App().run()


def find_steam_root(explicit: str | None = None) -> Path | None:
    """Resolve the Steam installation without starting the Zig host."""
    if explicit:
        root = Path(explicit).expanduser()
        return root.resolve() if root.is_dir() else None
    configured = os.environ.get("STEAM_ROOT")
    if configured:
        root = Path(configured).expanduser()
        if root.is_dir():
            return root.resolve()
    if winreg is None:
        return None
    for hive, key_name, value_name in (
        (winreg.HKEY_CURRENT_USER, r"Software\Valve\Steam", "SteamPath"),
        (winreg.HKEY_LOCAL_MACHINE, r"SOFTWARE\WOW6432Node\Valve\Steam", "InstallPath"),
    ):
        try:
            with winreg.OpenKey(hive, key_name) as key:
                value, _ = winreg.QueryValueEx(key, value_name)
            root = Path(os.path.expandvars(str(value)))
            if root.is_dir():
                return root.resolve()
        except OSError:
            continue
    return None


def configure_opensteamtool(source: str, library: str) -> str:
    """Enable the cloud host while preserving unrelated TOML tables and comments."""
    newline = "\r\n" if "\r\n" in source else "\n"
    trailing_newline = source.endswith(("\n", "\r"))
    lines = source.splitlines()
    header = next((index for index, line in enumerate(lines)
                   if re.match(r"^\s*\[\s*cloud\s*\]", line) and not line.lstrip().startswith("#")), -1)
    if header < 0:
        if lines and lines[-1].strip():
            lines.append("")
        lines.extend(("[cloud]", "enabled = true", f'library = "{library}"'))
    else:
        section_end = next((index for index in range(header + 1, len(lines))
                            if re.match(r"^\s*\[[^[]+\]", lines[index])
                            and not lines[index].lstrip().startswith("#")), len(lines))
        for key, value in (("enabled", "true"), ("library", f'"{library}"')):
            found = False
            for index in range(header + 1, section_end):
                stripped = lines[index].lstrip()
                if stripped.startswith("#") or not re.match(rf"^{re.escape(key)}\s*=", stripped):
                    continue
                indent = lines[index][:_leading_whitespace_length(lines[index])]
                lines[index] = f"{indent}{key} = {value}"
                found = True
                break
            if not found:
                lines.insert(section_end, f"{key} = {value}")
                section_end += 1
    rendered = newline.join(lines)
    return rendered + newline if trailing_newline else rendered


def _leading_whitespace_length(value: str) -> int:
    return len(value) - len(value.lstrip())


def ensure_steam_host(bridge: Path, steam_root: str | None = None) -> SteamHostSetup:
    """Install a versioned cloud host and point OpenSteamTool at it safely."""
    root = find_steam_root(steam_root)
    if root is None:
        return SteamHostSetup(False, False, False, None, "pasta da Steam não encontrada")
    source = bridge.parent / "achievement-bridge-cloud.dll"
    if not source.is_file():
        return SteamHostSetup(False, False, False, None, "achievement-bridge-cloud.dll não encontrada")
    config = root / "opensteamtool.toml"
    if not config.is_file():
        return SteamHostSetup(False, False, False, None, "opensteamtool.toml não encontrado")

    digest = hashlib.sha256(source.read_bytes()).hexdigest()[:12]
    target_dir = root / "AchievementBridge"
    target = target_dir / f"achievement-bridge-cloud-{digest}.dll"
    changed = False
    target_dir.mkdir(parents=True, exist_ok=True)
    if not target.is_file() or target.read_bytes() != source.read_bytes():
        temporary = target.with_suffix(target.suffix + ".tmp")
        shutil.copyfile(source, temporary)
        temporary.replace(target)
        changed = True

    relative = f"AchievementBridge/{target.name}"
    current = config.read_text(encoding="utf-8-sig")
    configured = configure_opensteamtool(current, relative)
    if configured != current:
        backup = config.with_name(config.name + ".achievement-bridge.bak")
        if not backup.exists():
            shutil.copyfile(config, backup)
        temporary = config.with_suffix(config.suffix + ".tmp")
        temporary.write_text(configured, encoding="utf-8", newline="")
        temporary.replace(config)
        changed = True

    return SteamHostSetup(True, changed, changed and process_is_running("steam.exe"), target, "integração Steam pronta")


def run_bridge(bridge: Path, arguments: Iterable[str], timeout: int | None = 30) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [str(bridge), *arguments],
        cwd=bridge.parent,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        encoding="utf-8",
        errors="replace",
        timeout=timeout,
        check=False,
    )


def notification_preview_arguments(
    app_id: int,
    achievement: str,
    steam_root: str | None,
    duration_ms: int = DEFAULT_NOTIFICATION_PREVIEW_MS,
    wait_for_game_dir: str | None = None,
) -> list[str]:
    """Build a safe Bridge notification preview request."""
    api_name = achievement.strip()
    if app_id <= 0:
        raise RuntimeError("o AppID precisa ser maior que zero")
    if not api_name:
        raise RuntimeError("informe o API name da conquista")
    if not MIN_NOTIFICATION_PREVIEW_MS <= duration_ms <= MAX_NOTIFICATION_PREVIEW_MS:
        raise RuntimeError(
            f"a duração deve ficar entre {MIN_NOTIFICATION_PREVIEW_MS} e {MAX_NOTIFICATION_PREVIEW_MS} ms"
        )
    if wait_for_game_dir is not None and not wait_for_game_dir.strip():
        raise RuntimeError("informe a pasta do jogo ao usar --wait-for-game")

    arguments = [
        "notify-test",
        "--appid",
        str(app_id),
        "--achievement",
        api_name,
        "--duration-ms",
        str(duration_ms),
    ]
    if steam_root:
        arguments += ["--steam-root", steam_root]
    if wait_for_game_dir:
        arguments += ["--wait-for-game", "--game-dir", wait_for_game_dir]
    return arguments


def request_notification_preview(
    bridge: Path,
    app_id: int,
    achievement: str,
    steam_root: str | None,
    duration_ms: int = DEFAULT_NOTIFICATION_PREVIEW_MS,
    wait_for_game_dir: str | None = None,
) -> dict[str, object]:
    notification_preview_arguments(
        app_id,
        achievement,
        steam_root,
        duration_ms,
        wait_for_game_dir,
    )
    payload: dict[str, object] = {
        "app_id": app_id,
        "achievement": achievement.strip(),
        "duration_ms": duration_ms,
    }
    if wait_for_game_dir is not None:
        payload["wait_for_game_dir"] = wait_for_game_dir
    timeout = None if wait_for_game_dir is not None else max(30, duration_ms // 1000 + 15)
    return api_client(bridge, steam_root).request(
        "POST",
        "/v1/achievement-previews",
        payload,
        timeout=timeout,
    )


def parse_installed_games(output: str) -> list[InstalledGame]:
    games: list[InstalledGame] = []
    pattern = re.compile(r"^\s*appid=(\d+) name=(.*?) dir=(.+)$")
    for line in output.splitlines():
        match = pattern.match(line)
        if match:
            games.append(InstalledGame(int(match.group(1)), match.group(2), Path(match.group(3))))
    return games


def parse_provider_candidates(output: str) -> dict[str, int]:
    candidates: dict[str, int] = {}
    inside = False
    pattern = re.compile(r"^\s+([a-z0-9_]+): confidence=(\d+)$")
    for line in output.splitlines():
        if line.strip() == "Provider candidates:":
            inside = True
            continue
        if not inside:
            continue
        match = pattern.match(line)
        if match:
            candidates[match.group(1)] = int(match.group(2))
        elif line.strip():
            break
    return candidates


def best_provider(candidates: dict[str, int]) -> tuple[str, int]:
    for provider in PROVIDER_PRIORITY:
        if provider in candidates:
            return provider, candidates[provider]
    return "none", 0


def parse_achievement_count(output: str) -> int | None:
    match = re.search(r"\bachievements=(\d+)\b", output)
    return int(match.group(1)) if match else None


def parse_available_achievements(output: str) -> list[AvailableAchievement]:
    achievements: list[AvailableAchievement] = []
    pattern = re.compile(
        r"^\[(\d+)\]\s+(\S+)\s+(unlocked|locked)\s+name=(.*?)"
        r"(?:\s+unlock_time=\d+)?\s+global=([0-9]+(?:\.[0-9]+)?)%$"
    )
    for line in output.splitlines():
        match = pattern.match(line)
        if match is None:
            continue
        achievements.append(AvailableAchievement(
            index=int(match.group(1)),
            api_name=match.group(2),
            unlocked=match.group(3) == "unlocked",
            name=match.group(4),
            global_percent=float(match.group(5)),
        ))
    return achievements


def classify_support(
    provider: str,
    confidence: int,
    achievements: int | None,
    state_available: bool = True,
) -> str:
    if provider in SUPPORTED_SYNC_PROVIDERS and confidence >= 60:
        if provider == "rockstar" and not state_available:
            return "AGUARDA DADOS"
        return "COMPLETO" if achievements is None or achievements > 0 else "SEM CATÁLOGO"
    if provider in MONITORED_PROVIDERS and confidence >= 60:
        return "SÓ DETECTA"
    if provider == "steam" and confidence >= 50:
        return "NATIVO"
    return "SEM SUPORTE"


def read_available_achievements(bridge: Path, app_id: int, steam_root: str | None) -> list[AvailableAchievement]:
    result = api_client(bridge, steam_root).request(
        "GET",
        f"/v1/games/{app_id}/achievements",
        timeout=45,
    )
    raw_achievements = result.get("achievements")
    if not isinstance(raw_achievements, list):
        raise RuntimeError(f"a API não retornou um catálogo válido para o AppID {app_id}")
    achievements = [
        AvailableAchievement(
            index=index,
            api_name=str(item.get("api_name", "")),
            unlocked=bool(item.get("unlocked", False)),
            name=str(item.get("name", "")),
            global_percent=float(item.get("global_percent") or 0),
        )
        for index, item in enumerate(raw_achievements)
        if isinstance(item, dict) and item.get("api_name")
    ]
    if not achievements:
        raise RuntimeError(f"a Steam não retornou um catálogo de conquistas para o AppID {app_id}")
    return achievements


def prepare_game_support(bridge: Path, app_id: int, steam_root: str | None) -> dict[str, object]:
    return api_client(bridge, steam_root).request(
        "POST",
        f"/v1/games/{app_id}/support",
        {},
        timeout=180,
    )


def inspect_installed_games(bridge: Path, steam_root: str | None, verify_schema: bool = True) -> list[SupportReport]:
    result = api_client(bridge, steam_root).request(
        "GET",
        f"/v1/games?verify_schema={'true' if verify_schema else 'false'}",
        timeout=180,
    )
    raw_games = result.get("games")
    if not isinstance(raw_games, list):
        raise RuntimeError("a API não retornou uma lista válida de jogos Steam")
    return [
        SupportReport(
            game=InstalledGame(
                app_id=int(item["app_id"]),
                name=str(item["name"]),
                directory=Path(str(item["directory"])),
            ),
            provider=str(item["provider"]),
            confidence=int(item["confidence"]),
            achievement_count=(
                int(item["achievement_count"])
                if item.get("achievement_count") is not None
                else None
            ),
            status=str(item["status"]),
            state_available=bool(item.get("state_available", True)),
        )
        for item in raw_games
        if isinstance(item, dict)
    ]


def print_game_table(reports: list[SupportReport]) -> None:
    table = Table(box=box.ROUNDED, header_style="bold cyan", border_style="bright_black")
    table.add_column("AppID", style="dim", no_wrap=True)
    table.add_column("Status", no_wrap=True)
    table.add_column("Provedor", no_wrap=True)
    table.add_column("Conf.", justify="right", no_wrap=True)
    table.add_column("Conq.", justify="right", no_wrap=True)
    table.add_column("Jogo", overflow="fold")
    status_styles = {
        "COMPLETO": "bold green",
        "NATIVO": "cyan",
        "SÓ DETECTA": "yellow",
        "AGUARDA DADOS": "yellow",
        "SEM CATÁLOGO": "yellow",
        "SEM SUPORTE": "red",
    }
    for report in reports:
        table.add_row(
            str(report.game.app_id),
            Text(report.status, style=status_styles.get(report.status, "")),
            report.provider,
            f"{report.confidence}%" if report.confidence else "-",
            str(report.achievement_count) if report.achievement_count is not None else "-",
            report.game.name,
        )
    console.print(table)
    console.print("[bold green]COMPLETO[/]  Bridge detecta e sincroniza com a Steam")
    console.print("[cyan]NATIVO[/]    O próprio jogo usa Steamworks; não precisa do Bridge")
    console.print("[yellow]SÓ DETECTA[/] O Bridge vê o evento, mas a CLI ainda não sincroniza sozinha")
    console.print("[yellow]AGUARDA DADOS[/] Integração preparada; abra o jogo para criar o estado de conquistas")
    console.print("[yellow]SEM CATÁLOGO[/] O provedor existe, mas a Steam não retornou conquistas")
    console.print("[red]SEM SUPORTE[/] Provedor de conquistas ainda não implementado")


def print_achievement_table(game: InstalledGame, achievements: list[AvailableAchievement]) -> None:
    table = Table(
        title=f"{game.name}  •  {len(achievements)} conquistas",
        box=box.ROUNDED,
        header_style="bold cyan",
        border_style="bright_black",
    )
    table.add_column("#", justify="right", style="dim", no_wrap=True)
    table.add_column("Estado", no_wrap=True)
    table.add_column("Conquista")
    table.add_column("API name", style="dim", overflow="fold")
    table.add_column("Global", justify="right", no_wrap=True)
    for achievement in achievements:
        state = Text("✓ Obtida", style="bold green") if achievement.unlocked else Text("○ Bloqueada", style="dim")
        table.add_row(
            str(achievement.index + 1),
            state,
            achievement.name,
            achievement.api_name,
            f"{achievement.global_percent:.1f}%",
        )
    console.print(table)


def other_bridge_process_exists() -> bool:
    try:
        request = urllib.request.Request(
            f"{os.environ.get('ACHIEVEMENT_BRIDGE_API_URL', DEFAULT_API_URL).rstrip('/')}/v1/health",
            headers={"Accept": "application/json"},
            method="GET",
        )
        with urllib.request.urlopen(request, timeout=0.5) as response:
            health = json.loads(response.read().decode("utf-8"))
        if bool(health.get("core", {}).get("monitoring", False)):
            return True
    except (urllib.error.URLError, TimeoutError, OSError, ValueError, AttributeError):
        pass
    if os.name != "nt":
        return False
    result = subprocess.run(
        [
            "powershell.exe",
            "-NoProfile",
            "-Command",
            "Get-CimInstance Win32_Process -Filter \"Name = 'achievement-bridge.exe'\" | "
            "Select-Object -ExpandProperty CommandLine",
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        encoding="utf-8",
        errors="replace",
        check=False,
    )
    return any("watch-all" in line.lower() for line in result.stdout.splitlines())


def process_is_running(image_name: str) -> bool:
    if os.name != "nt":
        return False
    result = subprocess.run(
        ["tasklist", "/FI", f"IMAGENAME eq {image_name}", "/FO", "CSV", "/NH"],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        encoding="utf-8",
        errors="replace",
        check=False,
    )
    return f'"{image_name.lower()}"' in result.stdout.lower()


def clear_screen() -> None:
    if console.is_terminal:
        console.clear()


def print_banner() -> None:
    heading = Text.assemble(
        ("ACHIEVEMENT BRIDGE", "bold bright_cyan"),
        "\n",
        ("Conquistas locais conectadas à Steam", "dim"),
    )
    heading.justify = "center"
    console.print(Panel(heading, border_style="cyan", padding=(1, 6)))


def print_status(bridge: Path) -> None:
    steam = process_is_running("steam.exe")
    bridge_active = other_bridge_process_exists()
    print_banner()
    status = Table.grid(padding=(0, 2))
    status.add_column(style="bold")
    status.add_column()
    status.add_row("Steam", "[bold green]● ATIVA[/]" if steam else "[red]○ FECHADA[/]")
    status.add_row("Bridge", "[bold green]● MONITORANDO[/]" if bridge_active else "[yellow]○ DESLIGADO[/]")
    status.add_row("Núcleo", str(bridge))
    status.add_row("Logs", default_log_path())
    console.print(Panel(status, title="[bold]Status[/]", border_style="bright_black"))


def menu_start_options(args: CliOptions) -> MonitorOptions:
    return MonitorOptions(
        bridge=args.bridge,
        steam_root=args.steam_root,
        interval_ms=500,
        journal=None,
        log=None,
        no_file_log=False,
        no_scan=True,
        no_notifications=True,
        native_toast=True,
        allow_duplicate=False,
    )


def show_available_achievements(args: CliOptions, bridge: Path) -> None:
    clear_screen()
    print_banner()
    console.print("\n[dim]Procurando jogos com catálogo de conquistas...[/]\n")
    reports = inspect_installed_games(bridge, args.steam_root, verify_schema=False)
    eligible = [
        report for report in reports
        if report.status in {"COMPLETO", "NATIVO", "SÓ DETECTA", "AGUARDA DADOS"}
    ]
    if not eligible:
        console.print(Panel("Nenhum jogo compatível foi encontrado.", border_style="yellow"))
        console.input("\nPressione Enter para voltar...")
        return

    choices = Table(box=box.SIMPLE, header_style="bold cyan")
    choices.add_column("Opção", justify="right", style="bright_cyan")
    choices.add_column("Jogo")
    choices.add_column("Status")
    choices.add_column("AppID", style="dim")
    for index, report in enumerate(eligible, start=1):
        choices.add_row(str(index), report.game.name, report.status, str(report.game.app_id))
    choices.add_row("0", "Voltar", "", "")
    console.print(choices)
    selected = Prompt.ask(
        "[bold]Escolha um jogo[/]",
        choices=tuple(str(index) for index in range(0, len(eligible) + 1)),
        default="0",
        show_choices=False,
        show_default=False,
    )
    if selected == "0":
        return

    game = eligible[int(selected) - 1].game
    clear_screen()
    print_banner()
    console.print(f"\n[dim]Lendo catálogo de {game.name}...[/]\n")
    try:
        achievements = read_available_achievements(bridge, game.app_id, args.steam_root)
    except RuntimeError as error:
        console.print(Panel(str(error), title="[bold red]Catálogo indisponível[/]", border_style="red"))
    else:
        print_achievement_table(game, achievements)
    console.input("\nPressione Enter para voltar...")


def simulate_popup(args: CliOptions, bridge: Path) -> None:
    reports = inspect_installed_games(bridge, args.steam_root, verify_schema=False)
    eligible = [
        report for report in reports
        if report.status in {"COMPLETO", "NATIVO", "SÓ DETECTA", "AGUARDA DADOS"}
    ]
    if not eligible:
        console.print(Panel("Nenhum jogo compatível foi encontrado.", border_style="yellow"))
        console.input("\nPressione Enter para voltar...")
        return

    game_notice: tuple[str, str, str] | None = None
    while True:
        clear_screen()
        print_banner()
        console.print("\n[dim]Escolha um jogo para simular popups nativos da Steam...[/]\n")
        if game_notice is not None:
            message, title, style = game_notice
            console.print(Panel(message, title=title, border_style=style))
            game_notice = None

        choices = Table(box=box.SIMPLE, header_style="bold cyan")
        choices.add_column("Opção", justify="right", style="bright_cyan")
        choices.add_column("Jogo")
        choices.add_column("Status")
        choices.add_column("AppID", style="dim")
        for index, report in enumerate(eligible, start=1):
            choices.add_row(str(index), report.game.name, report.status, str(report.game.app_id))
        choices.add_row("0", "Voltar ao menu", "", "")
        console.print(choices)
        selected = Prompt.ask(
            "[bold]Escolha um jogo[/]",
            choices=tuple(str(index) for index in range(0, len(eligible) + 1)),
            default="0",
            show_choices=False,
            show_default=False,
        )
        if selected == "0":
            return

        game = eligible[int(selected) - 1].game
        achievement_notice: tuple[str, str, str] | None = None
        while True:
            clear_screen()
            print_banner()
            console.print(f"\n[bold]{game.name}[/] — escolha uma conquista para testar.\n")
            if achievement_notice is not None:
                message, title, style = achievement_notice
                console.print(Panel(message, title=title, border_style=style))
                achievement_notice = None

            try:
                achievements = [
                    achievement
                    for achievement in read_available_achievements(bridge, game.app_id, args.steam_root)
                    if not achievement.unlocked
                ]
            except RuntimeError as error:
                game_notice = (str(error), "[bold red]Catálogo indisponível[/]", "red")
                break
            if not achievements:
                game_notice = (
                    "Todas as conquistas desse jogo já estão desbloqueadas; "
                    "não há estado seguro para restaurar.",
                    "[bold yellow]Nenhuma conquista disponível[/]",
                    "yellow",
                )
                break

            achievement_choices = Table(box=box.SIMPLE, header_style="bold cyan")
            achievement_choices.add_column("Opção", justify="right", style="bright_cyan")
            achievement_choices.add_column("Conquista")
            achievement_choices.add_column("API name", style="dim")
            for index, achievement in enumerate(achievements, start=1):
                achievement_choices.add_row(str(index), achievement.name, achievement.api_name)
            achievement_choices.add_row("0", "Trocar de jogo", "")
            console.print(achievement_choices)
            selected_achievement = Prompt.ask(
                "[bold]Escolha uma conquista[/]",
                choices=tuple(str(index) for index in range(0, len(achievements) + 1)),
                default="0",
                show_choices=False,
                show_default=False,
            )
            if selected_achievement == "0":
                break

            achievement = achievements[int(selected_achievement) - 1]
            try:
                with console.status(
                    "[cyan]Exibindo uma prévia segura do popup...[/]",
                    spinner="dots",
                ):
                    preview_result = request_notification_preview(
                        bridge,
                        game.app_id,
                        achievement.api_name,
                        args.steam_root,
                    )
            except RuntimeError as error:
                achievement_notice = (
                    str(error),
                    "[bold red]Simulação não concluída[/]",
                    "red",
                )
            else:
                message = (
                    f"Popup do Achievement Bridge exibido para [bold]{achievement.name}[/].\n"
                    "Nenhum estado de conquista foi alterado na Steam."
                )
                achievement_notice = (message, "[bold green]Simulação concluída[/]", "green")


def cli_process_arguments(args: CliOptions, bridge: Path, command: str | None = None) -> list[str]:
    """Build a command that works from source and from the packaged executable."""
    if getattr(sys, "frozen", False):
        arguments = [sys.executable]
    else:
        arguments = [sys.executable, str(Path(__file__).resolve())]
    arguments += ["--bridge", str(bridge)]
    if args.steam_root:
        arguments += ["--steam-root", args.steam_root]
    if command:
        arguments.append(command)
    return arguments


def launch_web_tray(args: CliOptions, bridge: Path) -> subprocess.Popen[bytes]:
    """Detach the tray owner so closing the launcher cannot stop Web mode."""
    creation_flags = 0
    if os.name == "nt":
        creation_flags = subprocess.CREATE_NO_WINDOW | subprocess.CREATE_NEW_PROCESS_GROUP
    return subprocess.Popen(
        cli_process_arguments(args, bridge, "tray-host"),
        cwd=application_root(),
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        close_fds=True,
        creationflags=creation_flags,
    )


def launch_terminal(args: CliOptions, bridge: Path) -> subprocess.Popen[bytes]:
    """Open the interface selector in a new visible console."""
    creation_flags = subprocess.CREATE_NEW_CONSOLE if os.name == "nt" else 0
    return subprocess.Popen(
        cli_process_arguments(args, bridge),
        cwd=application_root(),
        close_fds=True,
        creationflags=creation_flags,
    )


def wait_for_api_shutdown(client: BridgeApiClient) -> None:
    """Avoid racing a new selector against the old Go listener."""
    for _ in range(50):
        try:
            client._request_once("GET", "/v1/health", timeout=0.2)
        except (ConnectionError, RuntimeError):
            break
        time.sleep(0.1)


def run_tray_host(args: CliOptions, bridge: Path) -> int:
    """Own Web mode independently from every visible CLI window."""
    instance = TrayInstance()
    if not instance.acquire():
        return 0

    client = api_client(bridge, args.steam_root)
    address = f"{client.base_url}/"
    terminal_lock = threading.Lock()
    terminal: subprocess.Popen[bytes] | None = None

    def open_terminal_once() -> None:
        nonlocal terminal
        with terminal_lock:
            if terminal is not None and terminal.poll() is None:
                return
            terminal = launch_terminal(args, bridge)

    try:
        action = run_web_tray(
            address,
            lambda: webbrowser.open_new_tab(address),
            open_terminal_once,
        )
    finally:
        instance.release()

    client.shutdown()
    if action is TrayAction.CLOSE_WEB:
        wait_for_api_shutdown(client)
        launch_terminal(args, bridge)
    return 0


def open_web_interface(args: CliOptions, bridge: Path) -> int:
    """Start Web mode, detach its tray owner and let the visible CLI exit."""
    # Keep this explicit rather than relying on the API fallback so the Web
    # selection reports a useful error when a source checkout has no build yet.
    find_web_root()
    client = api_client(bridge, args.steam_root)
    client.ensure_started()
    health = client.request("GET", "/v1/health", timeout=3)
    if not bool(health.get("web_ui", False)):
        raise RuntimeError(
            "a instância ativa do Bridge foi iniciada sem a interface Web; "
            "desative o Bridge e abra-o novamente"
        )
    address = f"{client.base_url}/"
    open_web = lambda: webbrowser.open_new_tab(address)
    opened = open_web()
    message = f"Interface Web disponível em [link={address}]{address}[/link]"
    if not opened:
        message += "\nAbra o endereço acima no seu navegador."
    message += "\nO Bridge continuará disponível no ícone da bandeja do Windows."
    console.print(Panel(message, title="[bold green]Modo Web[/]", border_style="green"))
    launch_web_tray(args, bridge)
    return 0


def choose_interface(args: CliOptions, bridge: Path) -> int:
    """Let people choose the presentation layer before opening any UI."""
    clear_screen()
    print_banner()
    choices = Table.grid(padding=(0, 2))
    choices.add_column(style="bold bright_cyan", justify="right")
    choices.add_column()
    choices.add_row("1", "Terminal — menu e logs no console")
    choices.add_row("2", "Web — painel visual no navegador e controle na bandeja")
    choices.add_row("0", "Sair")
    console.print(Panel(choices, title="[bold]Como você quer usar o Bridge?[/]", border_style="cyan"))
    try:
        choice = Prompt.ask(
            "[bold]Escolha uma interface[/]",
            choices=("1", "2", "0"),
            show_choices=False,
            show_default=False,
        )
    except (EOFError, KeyboardInterrupt):
        return 0
    if choice == "1":
        return interactive_menu(args, bridge)
    if choice == "2":
        return open_web_interface(args, bridge)
    return 0


def interactive_menu(args: CliOptions, bridge: Path) -> int:
    api_client(bridge, args.steam_root).ensure_started()
    while True:
        clear_screen()
        print_status(bridge)
        actions = Table.grid(padding=(0, 2))
        actions.add_column(style="bold bright_cyan", justify="right")
        actions.add_column()
        actions.add_row("1", "Ativar Bridge e acompanhar logs")
        actions.add_row("2", "Desativar Bridge")
        actions.add_row("3", "Ver jogos compatíveis")
        actions.add_row("4", "Ver conquistas disponíveis")
        actions.add_row("5", "Simular popup da Steam")
        actions.add_row("6", "Atualizar status")
        actions.add_row("0", "Sair")
        console.print(Panel(actions, title="[bold]O que você quer fazer?[/]", border_style="cyan"))
        try:
            choice = Prompt.ask(
                "[bold]Escolha uma opção[/]",
                choices=("1", "2", "3", "4", "5", "6", "0"),
                show_choices=False,
                show_default=False,
            )
        except (EOFError, KeyboardInterrupt):
            return 0
        if choice == "1":
            clear_screen()
            print_banner()
            console.print(Panel(
                "[bold green]Bridge ativado.[/] Abra seu jogo normalmente.\n"
                "Os eventos aparecerão abaixo. Pressione [bold]Ctrl+C[/] para voltar ao menu; "
                "o Bridge continuará ativo.",
                border_style="green",
            ))
            start_monitor(menu_start_options(args), bridge)
        elif choice == "2":
            api_client(bridge, args.steam_root).shutdown()
            console.print(Panel("Bridge desativado.", border_style="yellow"))
            time.sleep(1)
        elif choice == "3":
            clear_screen()
            print_banner()
            console.print("\n[dim]Analisando a biblioteca Steam...[/]\n")
            reports = inspect_installed_games(bridge, args.steam_root, verify_schema=True)
            print_game_table(reports)
            console.input("\nPressione Enter para voltar...")
        elif choice == "4":
            show_available_achievements(args, bridge)
        elif choice == "5":
            exit_on_failure(lambda: simulate_popup(args, bridge))
        elif choice == "6":
            continue
        elif choice == "0":
            return 0


def start_monitor(args: MonitorOptions, bridge: Path) -> int:
    # Starting the Bridge means the public local API must be available too.
    # The gateway owns the only persistent Zig core and streams its events back
    # to this interface, avoiding a second watch-all process.
    client = api_client(bridge, args.steam_root)
    client.ensure_started()
    health = client.request("GET", "/v1/health", timeout=2)
    already_monitoring = bool(health.get("core", {}).get("monitoring", False))
    if not already_monitoring and other_bridge_process_exists() and not args.allow_duplicate:
        print("Já existe outro Achievement Bridge rodando (provavelmente iniciado pelo LuaTools).")
        print("Feche a outra instância ou use --allow-duplicate conscientemente.")
        return 2

    log_path = None if args.no_file_log else Path(args.log or default_log_path())
    log = LogSink(log_path)
    try:
        setup = ensure_steam_host(bridge, args.steam_root)
        if setup.installed:
            suffix = "; reinicie a Steam para carregar esta versão" if setup.restart_required else ""
            log.write(f"STEAM HOST OK library={setup.library}{suffix}")
        else:
            log.write(f"STEAM HOST AVISO {setup.message}")
    except OSError as error:
        log.write(f"STEAM HOST AVISO configuração não atualizada: {error}")
    if not args.no_scan:
        reports = inspect_installed_games(bridge, args.steam_root, verify_schema=True)
        print_game_table(reports)
    monitor_request: dict[str, object] = {
        "interval_ms": args.interval_ms,
        "recover": True,
        "notifications": not args.no_notifications,
        "native_toast": args.native_toast,
    }
    if args.journal:
        monitor_request["journal_path"] = args.journal
    client.request("POST", "/v1/monitor/start", monitor_request, timeout=15)

    log.write(f"INICIANDO api={client.base_url} core={bridge}")
    if log_path:
        log.write(f"LOG arquivo={log_path}")
    parser = EventParser()
    last_session_heartbeat: str | None = None
    try:
        for line in client.stream_monitor_events():
            if line.startswith("[AchievementBridge] active_game_sessions="):
                if line == last_session_heartbeat:
                    continue
                last_session_heartbeat = line
            log.write(f"BRIDGE {line}")
            event = parser.push(line)
            if event is not None:
                log.write(
                    f"CONQUISTA provider={event.provider} appid={event.app_id} "
                    f"achievement={event.achievement} recovered={event.recovered}"
                )
        log.write("ENCERRADO stream de eventos finalizado")
        return 0
    except KeyboardInterrupt:
        log.write("LOGS encerrados; Bridge continua ativo em segundo plano")
        return 0
    finally:
        log.close()


def default_log_path() -> str:
    base = os.environ.get("LOCALAPPDATA") or str(Path.home() / ".achievement-bridge")
    return str(Path(base) / "AchievementBridge" / "bridge-cli.log")


def default_api_log_path() -> str:
    base = os.environ.get("LOCALAPPDATA") or str(Path.home() / ".achievement-bridge")
    return str(Path(base) / "AchievementBridge" / "bridge-api.log")


app = typer.Typer(
    name="achievement-bridge-cli",
    help="[bold cyan]Achievement Bridge[/] — conquistas locais conectadas à Steam.",
    invoke_without_command=True,
    no_args_is_help=False,
    rich_markup_mode="rich",
    pretty_exceptions_show_locals=False,
)


def resolve_bridge(explicit: str | None) -> Path:
    try:
        return find_bridge(explicit)
    except FileNotFoundError as error:
        console.print(Panel(str(error), title="[bold red]Não foi possível iniciar[/]", border_style="red"))
        raise typer.Exit(1) from error


def get_cli_options(context: typer.Context) -> CliOptions:
    assert isinstance(context.obj, CliOptions)
    return context.obj


def exit_on_failure(action: Callable[[], ResultType]) -> ResultType:
    try:
        return action()
    except (FileNotFoundError, RuntimeError, subprocess.TimeoutExpired) as error:
        console.print(Panel(str(error), title="[bold red]Erro[/]", border_style="red"))
        raise typer.Exit(1) from error


@app.callback(invoke_without_command=True)
def application(
    context: typer.Context,
    bridge: Annotated[str | None, typer.Option(help="Caminho de achievement-bridge.exe")] = None,
    steam_root: Annotated[str | None, typer.Option(help="Pasta da Steam; normalmente detectada")] = None,
) -> None:
    """Abra o menu ou use um comando diretamente para automação."""
    options = CliOptions(bridge=bridge, steam_root=steam_root)
    context.obj = options
    if context.invoked_subcommand is None:
        result = exit_on_failure(lambda: choose_interface(options, resolve_bridge(bridge)))
        if result:
            raise typer.Exit(result)


@app.command("menu")
def menu_command(context: typer.Context) -> None:
    """Abra o menu interativo e escolha quando ativar o Bridge."""
    options = get_cli_options(context)
    result = exit_on_failure(lambda: interactive_menu(options, resolve_bridge(options.bridge)))
    if result:
        raise typer.Exit(result)


@app.command("tray-host", hidden=True)
def tray_host_command(context: typer.Context) -> None:
    """Run the detached Windows tray owner for Web mode."""
    options = get_cli_options(context)
    result = exit_on_failure(lambda: run_tray_host(options, resolve_bridge(options.bridge)))
    if result:
        raise typer.Exit(result)


@app.command("status")
def status_command(context: typer.Context) -> None:
    """Mostre o estado atual da Steam e do Bridge."""
    options = get_cli_options(context)
    exit_on_failure(lambda: print_status(resolve_bridge(options.bridge)))


@app.command("setup")
def setup_command(context: typer.Context) -> None:
    """Prepare a integração da Steam usada por cache, overlay e toast nativo."""
    options = get_cli_options(context)
    bridge = resolve_bridge(options.bridge)
    result = exit_on_failure(lambda: ensure_steam_host(bridge, options.steam_root))
    style = "green" if result.installed else "yellow"
    details = result.message
    if result.library is not None:
        details += f"\nBiblioteca: {result.library}"
    if result.restart_required:
        details += "\nReinicie a Steam para carregar esta versão."
    console.print(Panel(details, title="[bold]Integração Steam[/]", border_style=style))


@app.command("games")
def games_command(
    context: typer.Context,
    fast: Annotated[bool, typer.Option("--fast", help="Não consultar quantidades na Steam")] = False,
    json_output: Annotated[bool, typer.Option("--json", help="Emitir resultado JSON")] = False,
) -> None:
    """Liste a compatibilidade dos jogos Steam instalados."""
    options = get_cli_options(context)
    bridge = resolve_bridge(options.bridge)
    reports = exit_on_failure(
        lambda: inspect_installed_games(bridge, options.steam_root, verify_schema=not fast)
    )
    if json_output:
        print(json.dumps([
            {
                "appid": report.game.app_id,
                "name": report.game.name,
                "directory": str(report.game.directory),
                "provider": report.provider,
                "confidence": report.confidence,
                "achievements": report.achievement_count,
                "status": report.status,
            }
            for report in reports
        ], ensure_ascii=False, indent=2))
    else:
        print_game_table(reports)


@app.command("achievements")
def achievements_command(
    context: typer.Context,
    app_id: Annotated[int, typer.Argument(help="Steam AppID do jogo")],
) -> None:
    """Mostre o catálogo de conquistas disponível para um jogo."""
    options = get_cli_options(context)
    bridge = resolve_bridge(options.bridge)
    reports = exit_on_failure(lambda: inspect_installed_games(bridge, options.steam_root, verify_schema=False))
    game = next(
        (report.game for report in reports if report.game.app_id == app_id),
        InstalledGame(app_id=app_id, name=f"AppID {app_id}", directory=Path()),
    )
    achievements = exit_on_failure(lambda: read_available_achievements(bridge, app_id, options.steam_root))
    print_achievement_table(game, achievements)


@app.command("prepare-support")
def prepare_support_command(
    context: typer.Context,
    app_id: Annotated[int, typer.Argument(help="Steam AppID do jogo")],
) -> None:
    """Prepare e registre a conexão de conquistas de um jogo compatível."""
    options = get_cli_options(context)
    bridge = resolve_bridge(options.bridge)
    result = exit_on_failure(lambda: prepare_game_support(bridge, app_id, options.steam_root))
    status = str(result.get("status", "AGUARDA DADOS"))
    game = str(result.get("game", f"AppID {app_id}"))
    count = result.get("achievement_count", "-")
    message = f"{game}\n{count} conquistas conectadas\nStatus: {status}"
    if status == "AGUARDA DADOS":
        message += "\nAbra o jogo uma vez para o Bridge aprender o identificador do provedor."
    console.print(Panel(message, title="[bold green]Suporte preparado[/]", border_style="green"))


@app.command("simulate-popup")
def simulate_popup_command(
    context: typer.Context,
    app_id: Annotated[int, typer.Argument(help="Steam AppID do jogo")],
    achievement: Annotated[str, typer.Argument(help="Nome API da conquista")],
    duration_ms: Annotated[
        int,
        typer.Option(
            min=MIN_NOTIFICATION_PREVIEW_MS,
            max=MAX_NOTIFICATION_PREVIEW_MS,
            help="Tempo antes do rollback, em milissegundos",
        ),
    ] = DEFAULT_NOTIFICATION_PREVIEW_MS,
    wait_for_game: Annotated[
        bool,
        typer.Option("--wait-for-game", help="Aguardar o jogo abrir antes de solicitar o popup"),
    ] = False,
    game_dir: Annotated[
        str | None,
        typer.Option(help="Pasta do jogo usada por --wait-for-game"),
    ] = None,
) -> None:
    """Exiba uma prévia segura sem alterar conquistas na Steam."""
    options = get_cli_options(context)
    bridge = resolve_bridge(options.bridge)
    wait_for_game_dir = (game_dir or "") if wait_for_game else None
    result = exit_on_failure(lambda: request_notification_preview(
        bridge,
        app_id,
        achievement,
        options.steam_root,
        duration_ms,
        wait_for_game_dir,
    ))
    details = (
        f"Popup do Achievement Bridge exibido para [bold]{achievement}[/] (AppID {app_id}).\n"
        "Nenhum estado de conquista foi alterado na Steam."
    )
    console.print(Panel(
        details,
        title="[bold green]Simulação concluída[/]",
        border_style="green",
    ))


@app.command("start")
def start_command(
    context: typer.Context,
    interval_ms: Annotated[int, typer.Option(min=100, help="Intervalo do monitor em milissegundos")] = 500,
    journal: Annotated[str | None, typer.Option(help="Caminho alternativo do journal")] = None,
    log: Annotated[str | None, typer.Option(help="Caminho alternativo do log")] = None,
    no_file_log: Annotated[bool, typer.Option("--no-file-log", help="Não salvar log em arquivo")] = False,
    no_scan: Annotated[bool, typer.Option("--no-scan", help="Não analisar a biblioteca ao iniciar")] = False,
    no_notifications: Annotated[bool, typer.Option("--no-notifications", help="Desativar popup próprio")] = False,
    no_native_toast: Annotated[bool, typer.Option("--no-native-toast", help="Desativar toast Steam experimental")] = False,
    allow_duplicate: Annotated[bool, typer.Option("--allow-duplicate", help="Permitir outra instância (diagnóstico)")] = False,
) -> None:
    """Inicie o monitor diretamente, sem passar pelo menu."""
    options = get_cli_options(context)
    monitor = MonitorOptions(
        bridge=options.bridge,
        steam_root=options.steam_root,
        interval_ms=interval_ms,
        journal=journal,
        log=log,
        no_file_log=no_file_log,
        no_scan=no_scan,
        no_notifications=no_notifications,
        native_toast=not no_native_toast,
        allow_duplicate=allow_duplicate,
    )
    result = exit_on_failure(lambda: start_monitor(monitor, resolve_bridge(options.bridge)))
    if result:
        raise typer.Exit(result)


@app.command("stop")
def stop_command(context: typer.Context) -> None:
    """Desative explicitamente o monitor, a API e o núcleo."""
    options = get_cli_options(context)
    bridge = resolve_bridge(options.bridge)
    client = api_client(bridge, options.steam_root)
    try:
        client._request_once("GET", "/v1/health", timeout=1)
    except (ConnectionError, RuntimeError):
        console.print(Panel("O Bridge já está desligado.", border_style="yellow"))
        return
    client.shutdown()
    console.print(Panel("Bridge desativado.", border_style="yellow"))


if __name__ == "__main__":
    # Must run before regular CLI startup so Velopack can handle install,
    # update and uninstall lifecycle hooks.
    initialize_velopack()
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
        sys.stderr.reconfigure(encoding="utf-8", errors="replace")
    app(prog_name="achievement-bridge-cli")

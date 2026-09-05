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
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Annotated, Callable, Iterable, TextIO, TypeVar

import typer
import velopack
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


SUPPORTED_SYNC_PROVIDERS = ("gse", "rune")
MONITORED_PROVIDERS = ("ubisoft", "uplay_r2")
PROVIDER_PRIORITY = ("gse", "rune", "uplay_r2", "ubisoft", "steam", "epic", "gog", "ea", "xbox")
console = Console(highlight=False)
ResultType = TypeVar("ResultType")


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


def run_bridge(bridge: Path, arguments: Iterable[str], timeout: int = 30) -> subprocess.CompletedProcess[str]:
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


def classify_support(provider: str, confidence: int, achievements: int | None) -> str:
    if provider in SUPPORTED_SYNC_PROVIDERS and confidence >= 60:
        return "COMPLETO" if achievements is None or achievements > 0 else "SEM CATÁLOGO"
    if provider in MONITORED_PROVIDERS and confidence >= 60:
        return "SÓ DETECTA"
    if provider == "steam" and confidence >= 50:
        return "NATIVO"
    return "SEM SUPORTE"


def read_available_achievements(bridge: Path, app_id: int, steam_root: str | None) -> list[AvailableAchievement]:
    arguments = ["steam-read", "--appid", str(app_id)]
    if steam_root:
        arguments += ["--steam-root", steam_root]
    result = run_bridge(bridge, arguments, timeout=45)
    if result.returncode != 0:
        raise RuntimeError(result.stdout.strip() or f"não foi possível ler as conquistas do AppID {app_id}")
    achievements = parse_available_achievements(result.stdout)
    if not achievements:
        raise RuntimeError(f"a Steam não retornou um catálogo de conquistas para o AppID {app_id}")
    return achievements


def inspect_installed_games(bridge: Path, steam_root: str | None, verify_schema: bool = True) -> list[SupportReport]:
    arguments = ["games"]
    if steam_root:
        arguments += ["--steam-root", steam_root]
    games_result = run_bridge(bridge, arguments)
    if games_result.returncode != 0:
        raise RuntimeError(games_result.stdout.strip() or "não foi possível listar os jogos Steam")

    reports: list[SupportReport] = []
    for game in parse_installed_games(games_result.stdout):
        probe_args = ["probe", "--game-dir", str(game.directory)]
        if steam_root:
            probe_args += ["--steam-root", steam_root]
        probe = run_bridge(bridge, probe_args)
        provider, confidence = best_provider(parse_provider_candidates(probe.stdout))
        achievement_count: int | None = None
        if verify_schema and provider in SUPPORTED_SYNC_PROVIDERS and confidence >= 60:
            read_args = ["steam-read", "--appid", str(game.app_id)]
            if steam_root:
                read_args += ["--steam-root", steam_root]
            achievement_count = parse_achievement_count(run_bridge(bridge, read_args).stdout)
        reports.append(SupportReport(
            game=game,
            provider=provider,
            confidence=confidence,
            achievement_count=achievement_count,
            status=classify_support(provider, confidence, achievement_count),
        ))
    return reports


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
    return process_is_running("achievement-bridge.exe")


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
        if report.status in {"COMPLETO", "NATIVO", "SÓ DETECTA"}
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


def interactive_menu(args: CliOptions, bridge: Path) -> int:
    while True:
        clear_screen()
        print_status(bridge)
        if other_bridge_process_exists():
            console.print(Panel(
                "O Bridge já está ativo. Feche a outra instância antes de iniciar por este menu.",
                border_style="yellow",
            ))
        actions = Table.grid(padding=(0, 2))
        actions.add_column(style="bold bright_cyan", justify="right")
        actions.add_column()
        actions.add_row("[1]", "Ativar Bridge e acompanhar logs")
        actions.add_row("[2]", "Ver jogos compatíveis")
        actions.add_row("[3]", "Ver conquistas disponíveis")
        actions.add_row("[4]", "Atualizar status")
        actions.add_row("[0]", "Sair")
        console.print(Panel(actions, title="[bold]O que você quer fazer?[/]", border_style="cyan"))
        try:
            choice = Prompt.ask(
                "[bold]Escolha uma opção[/]",
                choices=("1", "2", "3", "4", "0"),
                default="1",
            )
        except (EOFError, KeyboardInterrupt):
            return 0
        if choice == "1":
            if other_bridge_process_exists():
                console.input("\n[yellow]Já existe um Bridge ativo.[/] Pressione Enter para voltar...")
                continue
            clear_screen()
            print_banner()
            console.print(Panel(
                "[bold green]Bridge ativado.[/] Abra seu jogo normalmente.\n"
                "Os eventos aparecerão abaixo. Pressione [bold]Ctrl+C[/] para voltar ao menu.",
                border_style="green",
            ))
            start_monitor(menu_start_options(args), bridge)
        elif choice == "2":
            clear_screen()
            print_banner()
            console.print("\n[dim]Analisando a biblioteca Steam...[/]\n")
            reports = inspect_installed_games(bridge, args.steam_root, verify_schema=True)
            print_game_table(reports)
            console.input("\nPressione Enter para voltar...")
        elif choice == "3":
            show_available_achievements(args, bridge)
        elif choice == "4":
            continue
        elif choice == "0":
            return 0


def sync_event(bridge: Path, event: AchievementEvent, steam_root: str | None, native_toast: bool, log: LogSink) -> None:
    if event.app_id is None:
        log.write(f"SYNC IGNORADO provider={event.provider}: evento sem Steam AppID")
        return
    if event.provider not in SUPPORTED_SYNC_PROVIDERS:
        log.write(f"SYNC PENDENTE appid={event.app_id} provider={event.provider}: mapeamento standalone ainda indisponível")
        return

    command = f"{event.provider}-steam-sync"
    arguments = [command, "--appid", str(event.app_id), "--achievement", event.achievement]
    if steam_root:
        arguments += ["--steam-root", steam_root]
    result = run_bridge(bridge, arguments, timeout=45)
    if result.returncode == 0:
        log.write(f"STEAM OK appid={event.app_id} achievement={event.achievement} {result.stdout.strip()}")
        return

    # Protected schemas can reject the public ABI. Preserve the verified event
    # in Steam's native local cache as the same fallback used by LuaTools.
    fallback = ["steam-local-sync", "--appid", str(event.app_id), "--achievement", event.achievement]
    if event.timestamp and event.timestamp > 0:
        fallback += ["--timestamp", str(event.timestamp)]
    if native_toast:
        fallback.append("--experimental-steam-notification")
    if steam_root:
        fallback += ["--steam-root", steam_root]
    local = run_bridge(bridge, fallback, timeout=45)
    if local.returncode == 0:
        log.write(f"STEAM CACHE OK appid={event.app_id} achievement={event.achievement} {local.stdout.strip()}")
    else:
        log.write(
            f"STEAM FALHOU appid={event.app_id} achievement={event.achievement} "
            f"direct={result.stdout.strip()} fallback={local.stdout.strip()}"
        )


def start_monitor(args: MonitorOptions, bridge: Path) -> int:
    if other_bridge_process_exists() and not args.allow_duplicate:
        print("Já existe um Achievement Bridge rodando (provavelmente iniciado pelo LuaTools).")
        print("Feche o LuaTools ou use --allow-duplicate conscientemente.")
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
    command = [str(bridge), "watch-all", "--interval-ms", str(args.interval_ms)]
    if args.journal:
        command += ["--journal", args.journal]
    if args.no_notifications:
        command.append("--no-notifications")

    log.write(f"INICIANDO executable={bridge}")
    if log_path:
        log.write(f"LOG arquivo={log_path}")
    process = subprocess.Popen(
        command,
        cwd=bridge.parent,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        encoding="utf-8",
        errors="replace",
        bufsize=1,
    )
    parser = EventParser()
    workers = ThreadPoolExecutor(max_workers=2, thread_name_prefix="steam-sync")
    last_session_heartbeat: str | None = None
    try:
        assert process.stdout is not None
        for raw_line in process.stdout:
            line = raw_line.rstrip("\r\n")
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
                workers.submit(sync_event, bridge, event, args.steam_root, args.native_toast, log)
        return_code = process.wait()
        log.write(f"ENCERRADO exit_code={return_code}")
        return return_code
    except KeyboardInterrupt:
        log.write("ENCERRANDO solicitado pelo usuário")
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
        return 0
    finally:
        workers.shutdown(wait=True, cancel_futures=False)
        log.close()


def default_log_path() -> str:
    base = os.environ.get("LOCALAPPDATA") or str(Path.home() / ".achievement-bridge")
    return str(Path(base) / "AchievementBridge" / "bridge-cli.log")


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
        result = exit_on_failure(lambda: interactive_menu(options, resolve_bridge(bridge)))
        if result:
            raise typer.Exit(result)


@app.command("menu")
def menu_command(context: typer.Context) -> None:
    """Abra o menu interativo e escolha quando ativar o Bridge."""
    options = get_cli_options(context)
    result = exit_on_failure(lambda: interactive_menu(options, resolve_bridge(options.bridge)))
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


if __name__ == "__main__":
    # Must run before regular CLI startup so Velopack can handle install,
    # update and uninstall lifecycle hooks.
    initialize_velopack()
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
        sys.stderr.reconfigure(encoding="utf-8", errors="replace")
    app(prog_name="achievement-bridge-cli")

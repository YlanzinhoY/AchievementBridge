#!/usr/bin/env python3
"""Human-friendly, dependency-free console for Achievement Bridge on Windows."""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import threading
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Iterable, TextIO


SUPPORTED_SYNC_PROVIDERS = ("gse", "rune")
MONITORED_PROVIDERS = ("ubisoft", "uplay_r2")
PROVIDER_PRIORITY = ("gse", "rune", "uplay_r2", "ubisoft", "steam", "epic", "gog", "ea", "xbox")


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
    root = Path(__file__).resolve().parent
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


def classify_support(provider: str, confidence: int, achievements: int | None) -> str:
    if provider in SUPPORTED_SYNC_PROVIDERS and confidence >= 60:
        return "PRONTO" if achievements is None or achievements > 0 else "SEM SCHEMA"
    if provider in MONITORED_PROVIDERS and confidence >= 60:
        return "MONITORA"
    if provider == "steam" and confidence >= 50:
        return "NATIVO"
    return "NÃO SUPORTADO"


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
    headers = ("APPID", "STATUS", "PROVEDOR", "CONF.", "CONQ.", "JOGO")
    rows = [
        (
            str(report.game.app_id),
            report.status,
            report.provider,
            f"{report.confidence}%" if report.confidence else "-",
            str(report.achievement_count) if report.achievement_count is not None else "-",
            report.game.name,
        )
        for report in reports
    ]
    widths = [max(len(headers[index]), *(len(row[index]) for row in rows)) for index in range(len(headers))]
    print("  ".join(headers[index].ljust(widths[index]) for index in range(len(headers))))
    print("  ".join("-" * width for width in widths))
    for row in rows:
        print("  ".join(row[index].ljust(widths[index]) for index in range(len(headers))))
    print("\nPRONTO = monitora e sincroniza | NATIVO = Steam já cuida | MONITORA = evento sem sync standalone")


def other_bridge_process_exists() -> bool:
    if os.name != "nt":
        return False
    result = subprocess.run(
        ["tasklist", "/FI", "IMAGENAME eq achievement-bridge.exe", "/FO", "CSV", "/NH"],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        encoding="utf-8",
        errors="replace",
        check=False,
    )
    return '"achievement-bridge.exe"' in result.stdout.lower()


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


def start_monitor(args: argparse.Namespace, bridge: Path) -> int:
    if other_bridge_process_exists() and not args.allow_duplicate:
        print("Já existe um Achievement Bridge rodando (provavelmente iniciado pelo LuaTools).")
        print("Feche o LuaTools ou use --allow-duplicate conscientemente.")
        return 2

    log_path = None if args.no_file_log else Path(args.log or default_log_path())
    log = LogSink(log_path)
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


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="achievement-bridge-cli", description="Console aberta do Achievement Bridge")
    parser.add_argument("--bridge", help="caminho de achievement-bridge.exe")
    parser.add_argument("--steam-root", help="pasta da Steam; normalmente detectada automaticamente")
    subcommands = parser.add_subparsers(dest="command")

    games = subcommands.add_parser("games", help="listar compatibilidade dos jogos Steam instalados")
    games.add_argument("--fast", action="store_true", help="não consultar a quantidade de conquistas na Steam")
    games.add_argument("--json", action="store_true", help="emitir resultado estruturado")

    start = subcommands.add_parser("start", help="iniciar monitor, logs e sincronização Steam")
    start.add_argument("--interval-ms", type=int, default=500)
    start.add_argument("--journal")
    start.add_argument("--log")
    start.add_argument("--no-file-log", action="store_true")
    start.add_argument("--no-scan", action="store_true")
    start.add_argument("--no-notifications", action="store_true")
    start.add_argument("--no-native-toast", action="store_false", dest="native_toast")
    start.add_argument("--allow-duplicate", action="store_true")
    start.set_defaults(native_toast=True)
    return parser


def main(argv: list[str] | None = None) -> int:
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
        sys.stderr.reconfigure(encoding="utf-8", errors="replace")
    parser = build_parser()
    effective_argv = list(sys.argv[1:] if argv is None else argv)
    args = parser.parse_args(effective_argv)
    if args.command is None:
        args = parser.parse_args([*effective_argv, "start"])
    try:
        bridge = find_bridge(args.bridge)
        if args.command == "games":
            reports = inspect_installed_games(bridge, args.steam_root, verify_schema=not args.fast)
            if args.json:
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
            return 0
        return start_monitor(args, bridge)
    except (FileNotFoundError, RuntimeError, subprocess.TimeoutExpired) as error:
        print(f"Erro: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())

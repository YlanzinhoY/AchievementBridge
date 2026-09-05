import unittest
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest.mock import patch

import achievement_bridge_cli as cli

from typer.testing import CliRunner

from achievement_bridge_cli import (
    CliOptions,
    EventParser,
    app,
    best_provider,
    classify_support,
    configure_opensteamtool,
    ensure_steam_host,
    menu_start_options,
    parse_achievement_count,
    parse_available_achievements,
    parse_installed_games,
    parse_provider_candidates,
)


class CliParsingTests(unittest.TestCase):
    def test_velopack_hooks_are_skipped_when_running_from_source(self) -> None:
        with patch.object(cli.velopack, "App") as app:
            cli.initialize_velopack()

        app.assert_not_called()

    def test_typer_help_lists_public_commands(self) -> None:
        result = CliRunner().invoke(app, ["--help"])

        self.assertEqual(0, result.exit_code)
        self.assertIn("achievements", result.stdout)
        self.assertIn("games", result.stdout)
        self.assertIn("start", result.stdout)
        self.assertIn("setup", result.stdout)

    def test_configures_cloud_table_without_touching_other_tables(self) -> None:
        configured = configure_opensteamtool(
            '[lua]\npaths = ["config/stplug-in"]\n\n[cloud]\nenabled = false\n'
            'library = "cloud_redirect.dll"\n\n[remote]\nprovider = "github"\n',
            "AchievementBridge/achievement-bridge-cloud-abc123.dll",
        )

        self.assertIn("enabled = true", configured)
        self.assertIn('library = "AchievementBridge/achievement-bridge-cloud-abc123.dll"', configured)
        self.assertIn('provider = "github"', configured)
        self.assertEqual(1, configured.count("library ="))

    def test_installs_versioned_cloud_host_idempotently(self) -> None:
        with TemporaryDirectory() as directory:
            root = Path(directory)
            app = root / "app"
            steam = root / "steam"
            app.mkdir()
            steam.mkdir()
            bridge = app / "achievement-bridge.exe"
            bridge.write_bytes(b"core")
            (app / "achievement-bridge-cloud.dll").write_bytes(b"cloud-v1")
            config = steam / "opensteamtool.toml"
            config.write_text("[lua]\npaths = []\n", encoding="utf-8")

            with patch.object(cli, "process_is_running", return_value=True):
                first = ensure_steam_host(bridge, str(steam))
                second = ensure_steam_host(bridge, str(steam))

            self.assertTrue(first.installed)
            self.assertTrue(first.changed)
            self.assertTrue(first.restart_required)
            self.assertIsNotNone(first.library)
            assert first.library is not None
            self.assertTrue(first.library.is_file())
            self.assertIn(first.library.name, config.read_text(encoding="utf-8"))
            self.assertFalse(second.changed)
            self.assertFalse(second.restart_required)

    def test_parses_installed_game_with_spaces(self) -> None:
        games = parse_installed_games(
            "[AchievementBridge] steam_root=C:\\steam installed_apps=1\n"
            "  appid=2638890 name=Onimusha: Way of the Sword "
            "dir=D:\\SteamLibrary\\steamapps\\common\\OnimushaWotS\n"
        )

        self.assertEqual(1, len(games))
        self.assertEqual(2638890, games[0].app_id)
        self.assertEqual("Onimusha: Way of the Sword", games[0].name)
        self.assertEqual(Path("D:\\SteamLibrary\\steamapps\\common\\OnimushaWotS"), games[0].directory)

    def test_selects_supported_provider_over_native_steam(self) -> None:
        output = """Runtime candidates:
  gse_compatible: confidence=100 evidence=4
  steamworks: confidence=45 evidence=2
Provider candidates:
  gse: confidence=100
  steam: confidence=45
"""
        candidates = parse_provider_candidates(output)

        self.assertEqual({"gse": 100, "steam": 45}, candidates)
        self.assertEqual(("gse", 100), best_provider(candidates))
        self.assertEqual("COMPLETO", classify_support("gse", 100, 52))

    def test_classifies_native_and_unsupported_games(self) -> None:
        self.assertEqual("NATIVO", classify_support("steam", 75, None))
        self.assertEqual("SEM SUPORTE", classify_support("epic", 85, None))
        self.assertEqual("SÓ DETECTA", classify_support("ubisoft", 90, None))

    def test_reads_steam_schema_count(self) -> None:
        self.assertEqual(52, parse_achievement_count("[SteamAdapter] connected=true appid=2638890 achievements=52"))
        self.assertIsNone(parse_achievement_count("SteamNotRunning"))

    def test_parses_unlocked_event_envelope(self) -> None:
        parser = EventParser()
        lines = [
            "[AchievementBridge]",
            "provider=gse",
            "appid=2638890",
            "achievement=ACHIEVEMENT_002",
            "state=unlocked",
            "timestamp=1788542000",
            "recovered=false",
            "",
        ]

        event = None
        for line in lines:
            event = parser.push(line) or event

        self.assertIsNotNone(event)
        assert event is not None
        self.assertEqual("gse", event.provider)
        self.assertEqual(2638890, event.app_id)
        self.assertEqual("ACHIEVEMENT_002", event.achievement)
        self.assertFalse(event.recovered)

    def test_parses_available_achievement_catalog(self) -> None:
        achievements = parse_available_achievements(
            "[49] ACHIEVEMENT_050 locked name=Manopla Faminta global=64.50%\n"
            "[50] ACHIEVEMENT_051 unlocked name=Fúria Selvagem unlock_time=1788574542 global=51.90%\n"
        )

        self.assertEqual(2, len(achievements))
        self.assertEqual("Manopla Faminta", achievements[0].name)
        self.assertFalse(achievements[0].unlocked)
        self.assertEqual(64.5, achievements[0].global_percent)
        self.assertTrue(achievements[1].unlocked)

    def test_interactive_menu_starts_with_safe_monitor_defaults(self) -> None:
        menu_args = CliOptions(bridge=None, steam_root="C:\\steam")
        monitor_args = menu_start_options(menu_args)

        self.assertEqual("C:\\steam", monitor_args.steam_root)
        self.assertTrue(monitor_args.no_scan)
        self.assertTrue(monitor_args.no_notifications)
        self.assertTrue(monitor_args.native_toast)
        self.assertFalse(monitor_args.allow_duplicate)


if __name__ == "__main__":
    unittest.main()

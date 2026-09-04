import unittest
from pathlib import Path

from achievement_bridge_cli import (
    EventParser,
    best_provider,
    build_parser,
    classify_support,
    menu_start_namespace,
    parse_achievement_count,
    parse_installed_games,
    parse_provider_candidates,
)


class CliParsingTests(unittest.TestCase):
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
        self.assertEqual("PRONTO", classify_support("gse", 100, 52))

    def test_classifies_native_and_unsupported_games(self) -> None:
        self.assertEqual("NATIVO", classify_support("steam", 75, None))
        self.assertEqual("NÃO SUPORTADO", classify_support("epic", 85, None))
        self.assertEqual("MONITORA", classify_support("ubisoft", 90, None))

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

    def test_interactive_menu_starts_with_safe_monitor_defaults(self) -> None:
        parser = build_parser()
        menu_args = parser.parse_args(["--steam-root", "C:\\steam", "menu"])
        monitor_args = menu_start_namespace(menu_args)

        self.assertEqual("menu", menu_args.command)
        self.assertEqual("C:\\steam", monitor_args.steam_root)
        self.assertTrue(monitor_args.no_scan)
        self.assertTrue(monitor_args.no_notifications)
        self.assertTrue(monitor_args.native_toast)
        self.assertFalse(monitor_args.allow_duplicate)


if __name__ == "__main__":
    unittest.main()

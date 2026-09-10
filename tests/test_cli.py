import unittest
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest.mock import MagicMock, patch

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
    notification_preview_arguments,
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
        self.assertIn("simulate-popup", result.stdout)
        self.assertIn("start", result.stdout)
        self.assertIn("setup", result.stdout)

    def test_api_start_arguments_pass_the_compiled_web_interface(self) -> None:
        arguments = cli.api_start_arguments(
            Path("api.exe"),
            Path("bridge.exe"),
            "C:\\steam",
            Path("frontend/dist"),
        )

        self.assertEqual(
            [
                "api.exe",
                "--core",
                "bridge.exe",
                "--steam-root",
                "C:\\steam",
                "--web-root",
                str(Path("frontend/dist")),
            ],
            arguments,
        )

    def test_terminal_and_web_use_distinct_gateway_profiles(self) -> None:
        bridge = Path("achievement-bridge.exe")
        headless = MagicMock()
        web = MagicMock()
        with (
            patch.object(cli, "_api_clients", {}),
            patch.object(cli, "find_web_root", return_value=Path("frontend/dist")),
            patch.object(cli, "BridgeApiClient", side_effect=(headless, web)) as client_type,
        ):
            self.assertIs(headless, cli.api_client(bridge, None))
            self.assertIs(web, cli.api_client(bridge, None, web_ui=True))

        self.assertEqual(None, client_type.call_args_list[0].args[2])
        self.assertEqual(Path("frontend/dist"), client_type.call_args_list[1].args[2])

    def test_terminal_mode_restarts_a_gateway_serving_the_web_ui(self) -> None:
        client = MagicMock()
        client.request.side_effect = ({"web_ui": True}, {"web_ui": False})
        with patch.object(cli, "wait_for_api_shutdown") as wait_for_shutdown:
            health = cli.ensure_api_mode(client, web_ui=False)

        self.assertEqual({"web_ui": False}, health)
        self.assertEqual(2, client.ensure_started.call_count)
        client.shutdown.assert_called_once_with()
        wait_for_shutdown.assert_called_once_with(client)

    def test_web_interface_starts_the_local_api_and_opens_its_root(self) -> None:
        client = MagicMock()
        client.base_url = "http://127.0.0.1:47650"
        with (
            patch.object(cli, "find_web_root", return_value=Path("frontend/dist")),
            patch.object(cli, "api_client", return_value=client),
            patch.object(cli, "ensure_api_mode") as ensure_mode,
            patch.object(cli.webbrowser, "open_new_tab", return_value=True) as open_browser,
            patch.object(cli, "launch_web_tray") as launch_tray,
            patch.object(cli.console, "print"),
        ):
            result = cli.open_web_interface(CliOptions(), Path("achievement-bridge.exe"))

        self.assertEqual(0, result)
        ensure_mode.assert_called_once_with(client, web_ui=True)
        open_browser.assert_called_once_with("http://127.0.0.1:47650/")
        launch_tray.assert_called_once_with(CliOptions(), Path("achievement-bridge.exe"))
        client.shutdown.assert_not_called()

    def test_interface_choice_opens_web_without_entering_terminal_menu(self) -> None:
        with (
            patch.object(cli, "clear_screen"),
            patch.object(cli, "print_banner"),
            patch.object(cli.console, "print"),
            patch.object(cli.Prompt, "ask", return_value="2") as ask,
            patch.object(cli, "open_web_interface", return_value=0) as open_web,
            patch.object(cli, "interactive_menu") as terminal,
        ):
            result = cli.choose_interface(CliOptions(), Path("achievement-bridge.exe"))

        self.assertEqual(0, result)
        ask.assert_called_once()
        open_web.assert_called_once_with(CliOptions(), Path("achievement-bridge.exe"))
        terminal.assert_not_called()

    def test_tray_host_keeps_api_until_an_explicit_tray_action(self) -> None:
        client = MagicMock()
        client.base_url = "http://127.0.0.1:47650"
        instance = MagicMock()
        instance.acquire.return_value = True
        with (
            patch.object(cli, "TrayInstance", return_value=instance),
            patch.object(cli, "api_client", return_value=client),
            patch.object(cli, "run_web_tray", return_value=cli.TrayAction.EXIT_BRIDGE) as tray,
            patch.object(cli, "launch_terminal") as terminal,
        ):
            result = cli.run_tray_host(CliOptions(), Path("achievement-bridge.exe"))

        self.assertEqual(0, result)
        tray.assert_called_once()
        client.shutdown.assert_called_once_with()
        instance.release.assert_called_once_with()
        terminal.assert_not_called()

    def test_clicking_the_tray_switches_to_terminal_mode(self) -> None:
        client = MagicMock()
        client.base_url = "http://127.0.0.1:47650"
        instance = MagicMock()
        instance.acquire.return_value = True

        with (
            patch.object(cli, "TrayInstance", return_value=instance),
            patch.object(cli, "api_client", return_value=client),
            patch.object(cli, "run_web_tray", return_value=cli.TrayAction.OPEN_TERMINAL),
            patch.object(cli, "wait_for_api_shutdown") as wait_for_shutdown,
            patch.object(cli, "launch_terminal") as terminal,
        ):
            result = cli.run_tray_host(CliOptions(), Path("achievement-bridge.exe"))

        self.assertEqual(0, result)
        client.shutdown.assert_called_once_with()
        wait_for_shutdown.assert_called_once_with(client)
        terminal.assert_called_once_with(CliOptions(), Path("achievement-bridge.exe"), "menu")

    def test_closing_web_mode_reopens_the_interface_selector(self) -> None:
        client = MagicMock()
        client.base_url = "http://127.0.0.1:47650"
        instance = MagicMock()
        instance.acquire.return_value = True
        with (
            patch.object(cli, "TrayInstance", return_value=instance),
            patch.object(cli, "api_client", return_value=client),
            patch.object(cli, "run_web_tray", return_value=cli.TrayAction.CLOSE_WEB),
            patch.object(cli, "wait_for_api_shutdown") as wait_for_shutdown,
            patch.object(cli, "launch_terminal") as terminal,
        ):
            result = cli.run_tray_host(CliOptions(), Path("achievement-bridge.exe"))

        self.assertEqual(0, result)
        client.shutdown.assert_called_once_with()
        wait_for_shutdown.assert_called_once_with(client)
        terminal.assert_called_once_with(CliOptions(), Path("achievement-bridge.exe"))

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
        self.assertEqual("AGUARDA DADOS", classify_support("rockstar", 100, 77, False))
        self.assertEqual("COMPLETO", classify_support("rockstar", 100, 77, True))

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

    def test_interactive_menu_does_not_activate_on_empty_input(self) -> None:
        client = MagicMock()
        with (
            patch.object(cli, "api_client", return_value=client),
            patch.object(cli, "ensure_api_mode") as ensure_mode,
            patch.object(cli, "print_status"),
            patch.object(cli, "other_bridge_process_exists", return_value=False),
            patch.object(cli.console, "print"),
            patch.object(cli.Prompt, "ask", return_value="0") as ask,
        ):
            result = cli.interactive_menu(CliOptions(), Path("achievement-bridge.exe"))

        self.assertEqual(0, result)
        ensure_mode.assert_called_once_with(client, web_ui=False)
        self.assertNotIn("default", ask.call_args.kwargs)

    def test_monitor_uses_api_instead_of_second_zig_process(self) -> None:
        client = MagicMock()
        client.base_url = "http://127.0.0.1:47650"
        client.request.return_value = {"monitoring": True}
        client.stream_monitor_events.return_value = iter(())
        options = cli.MonitorOptions(
            bridge=None,
            steam_root=None,
            interval_ms=500,
            journal=None,
            log=None,
            no_file_log=True,
            no_scan=True,
            no_notifications=True,
            native_toast=True,
            allow_duplicate=False,
        )
        setup = cli.SteamHostSetup(False, False, False, None, "não configurado")
        with (
            patch.object(cli, "other_bridge_process_exists", return_value=False),
            patch.object(cli, "api_client", return_value=client),
            patch.object(
                cli,
                "ensure_api_mode",
                return_value={"core": {"monitoring": False}},
            ) as ensure_mode,
            patch.object(cli, "ensure_steam_host", return_value=setup),
            patch.object(cli.subprocess, "Popen") as popen,
        ):
            result = cli.start_monitor(options, Path("achievement-bridge.exe"))

        ensure_mode.assert_called_once_with(client, web_ui=False)

        self.assertEqual(0, result)
        client.request.assert_any_call(
            "POST",
            "/v1/monitor/start",
            {
                "interval_ms": 500,
                "recover": True,
                "notifications": False,
                "native_toast": True,
            },
            timeout=15,
        )
        popen.assert_not_called()

    def test_notification_preview_never_requests_a_steam_write(self) -> None:
        arguments = notification_preview_arguments(
            2638890,
            " ACHIEVEMENT_050 ",
            "C:\\steam",
            duration_ms=9000,
            wait_for_game_dir="D:\\SteamLibrary\\steamapps\\common\\OnimushaWotS",
        )

        self.assertEqual("notify-test", arguments[0])
        self.assertIn("ACHIEVEMENT_050", arguments)
        self.assertIn("--duration-ms", arguments)
        self.assertIn("--wait-for-game", arguments)
        self.assertNotIn("steam-unlock", arguments)
        self.assertNotIn("steam-local-sync", arguments)
        self.assertNotIn("--confirm-steam-write", arguments)
        self.assertNotIn("--confirm-local-write", arguments)

    def test_notification_preview_requires_game_dir_when_waiting(self) -> None:
        with self.assertRaisesRegex(RuntimeError, "pasta do jogo"):
            notification_preview_arguments(2638890, "ACHIEVEMENT_050", None, wait_for_game_dir="")

    def test_popup_menu_returns_to_achievement_list_after_preview(self) -> None:
        report = cli.SupportReport(
            game=cli.InstalledGame(2638890, "Onimusha: Way of the Sword", Path("D:\\OnimushaWotS")),
            provider="gse",
            confidence=100,
            achievement_count=52,
            status="COMPLETO",
        )
        achievement = cli.AvailableAchievement(
            index=0,
            api_name="ACHIEVEMENT_001",
            unlocked=False,
            name="Inigualável",
            global_percent=0.0,
        )

        with (
            patch.object(cli, "inspect_installed_games", return_value=[report]),
            patch.object(cli, "read_available_achievements", return_value=[achievement]) as read,
            patch.object(cli, "request_notification_preview") as preview,
            patch.object(cli, "clear_screen"),
            patch.object(cli, "print_banner"),
            patch.object(cli.console, "print"),
            patch.object(cli.console, "status") as status,
            patch.object(cli.Prompt, "ask", side_effect=["1", "1", "0", "0"]),
        ):
            cli.simulate_popup(CliOptions(steam_root="C:\\steam"), Path("achievement-bridge.exe"))

        self.assertEqual(2, read.call_count)
        preview.assert_called_once_with(
            Path("achievement-bridge.exe"),
            2638890,
            "ACHIEVEMENT_001",
            "C:\\steam",
        )
        status.assert_called_once()


if __name__ == "__main__":
    unittest.main()

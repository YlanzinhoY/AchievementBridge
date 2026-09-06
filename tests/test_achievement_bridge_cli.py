from __future__ import annotations

import json
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

import achievement_bridge_cli as cli


class ContextResponse:
    def __init__(self, payload: object) -> None:
        self._payload = json.dumps(payload).encode("utf-8")

    def __enter__(self) -> "ContextResponse":
        return self

    def __exit__(self, *_: object) -> None:
        return None

    def read(self) -> bytes:
        return self._payload


class EventParserTests(unittest.TestCase):
    def test_unlocked_event_is_emitted_after_envelope(self) -> None:
        parser = cli.EventParser()
        lines = [
            "[AchievementBridge]",
            "provider=rune",
            "appid=3046600",
            "achievement=ACHIEVEMENT_02",
            "timestamp=1234",
            "state=unlocked",
            "",
        ]
        event = None
        for line in lines:
            event = parser.push(line) or event
        self.assertIsNotNone(event)
        assert event is not None
        self.assertEqual("rune", event.provider)
        self.assertEqual(3046600, event.app_id)
        self.assertEqual("ACHIEVEMENT_02", event.achievement)


class ApiClientTests(unittest.TestCase):
    @patch("achievement_bridge_cli.urllib.request.urlopen")
    def test_catalog_is_mapped_from_api(self, urlopen: MagicMock) -> None:
        urlopen.return_value = ContextResponse({
            "app_id": 2638890,
            "achievements": [{
                "api_name": "ACHIEVEMENT_001",
                "name": "Inigualável",
                "unlocked": False,
                "global_percent": 0.0,
            }],
        })
        bridge = Path("achievement-bridge.exe")
        with patch.object(cli, "api_client", return_value=cli.BridgeApiClient(bridge, None)):
            achievements = cli.read_available_achievements(bridge, 2638890, None)
        self.assertEqual(1, len(achievements))
        self.assertEqual("ACHIEVEMENT_001", achievements[0].api_name)
        self.assertFalse(achievements[0].unlocked)

    def test_preview_arguments_reject_empty_achievement(self) -> None:
        with self.assertRaises(RuntimeError):
            cli.notification_preview_arguments(2638890, " ", None)

    @patch("achievement_bridge_cli.os.getpid", return_value=4242)
    def test_api_process_is_bound_to_cli_lifetime(self, _: MagicMock) -> None:
        arguments = cli.api_start_arguments(
            Path("achievement-bridge-api.exe"),
            Path("achievement-bridge.exe"),
            r"C:\Program Files (x86)\Steam",
        )
        self.assertEqual(
            [
                "achievement-bridge-api.exe",
                "--core",
                "achievement-bridge.exe",
                "--parent-pid",
                "4242",
                "--steam-root",
                r"C:\Program Files (x86)\Steam",
            ],
            arguments,
        )


class ConfigurationTests(unittest.TestCase):
    def test_opensteamtool_preserves_other_sections(self) -> None:
        source = "[general]\nname = \"keep\"\n\n[cloud]\nenabled = false\nlibrary = \"old.dll\"\n"
        configured = cli.configure_opensteamtool(source, "AchievementBridge/new.dll")
        self.assertIn('name = "keep"', configured)
        self.assertIn("enabled = true", configured)
        self.assertIn('library = "AchievementBridge/new.dll"', configured)


if __name__ == "__main__":
    unittest.main()

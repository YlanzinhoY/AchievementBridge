import unittest

from achievement_bridge_tray import TrayAction, _tray_image


class TrayTests(unittest.TestCase):
    def test_tray_icon_is_renderable_at_windows_notification_size(self) -> None:
        image = _tray_image()

        self.assertEqual((64, 64), image.size)
        self.assertEqual("RGBA", image.mode)

    def test_tray_actions_are_distinct_lifecycle_choices(self) -> None:
        self.assertNotEqual(TrayAction.CLOSE_WEB, TrayAction.EXIT_BRIDGE)


if __name__ == "__main__":
    unittest.main()

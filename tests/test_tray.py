import unittest

from achievement_bridge_tray import TrayAction, TrayInstance, _tray_image


class TrayTests(unittest.TestCase):
    def test_tray_icon_is_renderable_at_windows_notification_size(self) -> None:
        image = _tray_image()

        self.assertEqual((64, 64), image.size)
        self.assertEqual("RGBA", image.mode)

    def test_tray_actions_are_distinct_lifecycle_choices(self) -> None:
        self.assertNotEqual(TrayAction.CLOSE_WEB, TrayAction.EXIT_BRIDGE)

    def test_only_one_tray_instance_can_own_the_windows_icon(self) -> None:
        first = TrayInstance()
        second = TrayInstance()
        self.assertTrue(first.acquire())
        try:
            self.assertFalse(second.acquire())
        finally:
            first.release()

        replacement = TrayInstance()
        self.assertTrue(replacement.acquire())
        replacement.release()


if __name__ == "__main__":
    unittest.main()

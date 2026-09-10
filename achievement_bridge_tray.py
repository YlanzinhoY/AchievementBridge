"""Windows system-tray lifecycle for the Achievement Bridge Web interface."""

from __future__ import annotations

import ctypes
import os
from enum import Enum
from typing import Callable

from PIL import Image, ImageDraw
from pystray import Icon, Menu, MenuItem


class TrayAction(Enum):
    CLOSE_WEB = "close_web"
    EXIT_BRIDGE = "exit_bridge"


def _set_console_visible(visible: bool) -> None:
    if os.name != "nt":
        return
    window = ctypes.windll.kernel32.GetConsoleWindow()
    if window:
        ctypes.windll.user32.ShowWindow(window, 5 if visible else 0)
        if visible:
            ctypes.windll.user32.SetForegroundWindow(window)


def _tray_image() -> Image.Image:
    """Create a compact version of the Bridge mark without external assets."""
    size = 64
    image = Image.new("RGBA", (size, size), (21, 20, 27, 255))
    draw = ImageDraw.Draw(image)
    purple = (162, 119, 255, 255)
    mint = (97, 255, 202, 255)
    foreground = (237, 236, 238, 255)

    draw.rounded_rectangle((2, 2, 61, 61), radius=14, outline=purple, width=4)
    draw.rounded_rectangle((11, 42, 53, 49), radius=3, fill=foreground)
    draw.rounded_rectangle((13, 19, 20, 46), radius=2, fill=foreground)
    draw.rounded_rectangle((44, 19, 51, 46), radius=2, fill=foreground)
    draw.arc((17, 22, 47, 52), start=180, end=360, fill=mint, width=4)
    return image


def run_web_tray(address: str, open_web: Callable[[], object]) -> TrayAction:
    """Hide the console and block on a tray menu until the user chooses an exit path."""
    selected = TrayAction.CLOSE_WEB
    icon: Icon

    def open_panel(_icon: Icon, _item: MenuItem) -> None:
        open_web()

    def select(action: TrayAction) -> Callable[[Icon, MenuItem], None]:
        def callback(active_icon: Icon, _item: MenuItem) -> None:
            nonlocal selected
            selected = action
            active_icon.stop()

        return callback

    menu = Menu(
        MenuItem("Abrir painel Web", open_panel, default=True),
        Menu.SEPARATOR,
        MenuItem("Fechar Web/API e escolher interface", select(TrayAction.CLOSE_WEB)),
        MenuItem("Encerrar o Bridge por completo", select(TrayAction.EXIT_BRIDGE)),
    )
    icon = Icon("achievement-bridge", _tray_image(), "Achievement Bridge — Web ativa", menu)

    _set_console_visible(False)
    try:
        icon.run()
    finally:
        _set_console_visible(True)
    return selected

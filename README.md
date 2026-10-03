# Simple Smooth Cursor

![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)
![Platform: Windows](https://img.shields.io/badge/Platform-Windows-0078D6.svg)
![AutoHotkey v2.0](https://img.shields.io/badge/AutoHotkey-v2.0-659AD2.svg)

A smooth, animated cursor for Windows — written in AutoHotkey v2.

Smooth Cursor replaces the default Windows pointer with a custom‑drawn cursor that moves with spring physics, rotates toward the direction of movement, scales on hover and press, and reacts to every click with a soft ripple.

## ✨ Features

- **Spring physics motion** — the cursor glides behind your mouse with a smooth, natural lag you can tune.
- **Directional rotation** — the arrow turns toward the direction you're moving.
- **Smart cursor shapes** — automatically switches between arrow, I‑beam (over text), and spinner (when busy).
- **Hover & click feedback** — grows on links/buttons, shrinks slightly on click.
- **Click ripple** — a soft expanding ring on every left or right click.
- **Optional cursor trail** — a fading trail behind the cursor.
- **5 color themes** — switch instantly with `Ctrl+Alt+C`.
- **Fully adjustable** — smoothness, speed, damping, size, hover scale and more from a built‑in Settings window.
- **Optional mouse tweaks** — can disable Windows pointer acceleration or override pointer speed while running.
- **Runs above everything** — stays on top of the taskbar, Start menu and Task Manager.
- **Start with Windows** — optional scheduled task (no UAC prompt at login).

## ⌨️ Hotkeys

| Keys | Action |
|------|--------|
| `Ctrl + Alt + S` | Open Settings |
| `Ctrl + Alt + C` | Next color theme |
| `Ctrl + Alt + Up` | Bigger cursor |
| `Ctrl + Alt + Down` | Smaller cursor |
| `Ctrl + Alt + R` | Toggle click ripple |
| `Ctrl + Alt + T` | Toggle cursor trail |
| `Ctrl + Alt + D` | Toggle debug info |
| `Ctrl + Alt + Q` | Exit |

## 📦 Requirements

- Windows 10 or 11 (**Absolutely not tested on lower versions of windows**)
- [AutoHotkey v2.0](https://www.autohotkey.com/) (only if you run the script directly — the compiled `.exe` works without it)
- Administrator privileges (needed to hide system cursors; the script will ask for it)

## 🚀 Installation & Usage

1. Download the compiled `SmoothCursor.exe` from the **Releases** page, **or** run `SmoothCursor.ahk` with AutoHotkey v2.
2. Approve the admin prompt (needed once).
3. The cursor appears immediately — open the tray icon to access **Settings**.

## ⚙️ Settings

The Settings window (tray icon → **Settings...** or `Ctrl+Alt+S`) lets you adjust:

- Smooth time (how quickly the cursor follows the mouse)
- Speed boost (stiffer spring when moving fast)
- Max lag distance (limit how far the cursor can lag behind)
- Damping (bounce)
- Rotation speed
- Hover scale (size on links/buttons)
- Cursor size
- Windows pointer speed override
- Pointer acceleration toggle
- Click ripple and cursor trail toggles
- Start with Windows

All settings are saved automatically to `%AppData%\SmoothCursor\settings.ini`.

## 📝 Notes

- Settings are saved to `%AppData%\SmoothCursor\settings.ini`.
- If the script crashes, mouse settings and system cursors are restored automatically on the next launch.
- Right‑click the tray icon → **Exit** to fully restore the original cursor.
- The script can optionally disable pointer acceleration and override pointer speed while running. These changes are temporary and are reverted when you exit.

## 📄 License

This project is licensed under the **GNU General Public License v3.0 (GPLv3)**.

You are free to use, modify, and redistribute it — but any copy, fork or derivative **must keep the original author's attribution** and **stay open source** under the same license.

See [LICENSE](LICENSE) for details.

## 👤 Author

**seyed ermia hosaini** — (mailto://ermiahosaini@gmail.com)

---

If you like this project, a ⭐ on GitHub is appreciated!

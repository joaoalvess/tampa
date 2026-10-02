# 💻 Tampa

A tiny macOS menu bar app that turns off a MacBook's built-in screen while the lid stays open, so you can work on an external monitor and keep using the built-in keyboard, trackpad and Touch ID.

Built for a MacBook Pro 13" M1 driving an LG UltraWide 2560×1080 monitor. Personal use only.

## ✨ Features

- **Turn the built-in screen off/on** from the menu bar or with `⌃⌥⌘T`. The panel and its backlight are fully powered off.
- **Turn off on connect:** the built-in screen goes dark as soon as an external monitor is plugged in.
- **Safety net:** the built-in screen only turns off while an external monitor is connected, and comes back automatically when the cable is unplugged. If re-enabling fails, Tampa power-cycles the displays and retries.
- **Sharp text (HiDPI):** renders the external monitor at 2× through a mirrored virtual display, then downsamples to the panel's native resolution. The virtual display reuses the monitor's color profile, so colors stay accurate.
- **Open at login.**

## 🛠️ Build

Requires macOS 14+, Apple Silicon and Xcode command line tools.

```sh
./scripts/build-app.sh          # builds build/Tampa.app
./scripts/build-app.sh install  # installs to ~/Applications and launches it
```

## 🆘 If the built-in screen stays dark

Any of these brings it back:

1. Press `⌃⌥⌘T`
2. Unplug the external monitor
3. Close and reopen the lid
4. Restart the Mac (changes only last for the current session)

## ⚠️ Caveats

Tampa relies on private macOS APIs (`SLSConfigureDisplayEnabled` and `CGVirtualDisplay`), so a macOS update may break it. It cannot be distributed through the Mac App Store.

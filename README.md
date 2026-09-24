# Record 9:16

A tiny macOS app that records a vertical (9:16) region of your screen.

- A hot-pink frame (Marzelle `#FF007D`) floats over everything. **Click anywhere inside it and drag** to position, **drag the bottom-right corner** to resize. Arrow keys nudge it (Shift = 10 pt).
- The frame is always exactly 9:16. Widths snap to 18-pixel steps so both sides stay whole, even numbers (1080×1920, 720×1280, 540×960 …).
- A floating toolbar (styled like the macOS screenshot bar) sits at the bottom of the screen: size presets, editable width and height in pixels (the other side follows), an **Options** menu (mouse pointer, clicks, microphone, hide frame while recording, save folder, reveal last recording) and a pink **Record** button. Drag the bar anywhere; the × hides it.
- **Record** starts, **Stop** finishes. **⌘⇧1** works from any app: if the frame is hidden it shows it so you can position it; if the frame is visible it starts recording; while recording it stops. (Change `HOTKEY_KEYCODE` / `HOTKEY_MODIFIERS` in `main.swift`.) ⌘R toggles recording directly when the app is active. Files land on the Desktop (change with *Folder…*) as `Screen Recording 9x16 <date>.mov` (H.264).
- Options: show cursor, show clicks, record microphone, hide the frame while recording. The frame is drawn *outside* the recorded area, so it never appears in the video either way.
- Keep the control panel outside the frame while recording, or it will be in the video.
- The app lives in the **menu bar** (pink `9:16`, turns to `● REC` while recording). Closing the panel (⌘W) only hides it; the app keeps running so ⌘⇧1 keeps working. The menu-bar item shows/hides the frame and panel, starts/stops recording, and has an **Open at Login** toggle. Quit from that menu.

## Build

```bash
./build.sh
```

Produces `Record 9:16.app` next to the script. Requires Xcode command-line tools.

## First run

macOS will ask for **Screen & System Audio Recording** permission the first time you record. Grant it under System Settings → Privacy & Security, then record again. The panel has a button that opens that pane if no video was saved.

## Keeping the permission across rebuilds

macOS ties the permission to the app's code signature. An ad-hoc signature changes on every build, so each rebuild would need re-granting. Run this once:

```bash
./make-signing-cert.sh
```

It creates a self-signed "Record916 Signing" certificate in your login keychain. `build.sh` signs with it automatically when it exists, so the identity stays stable. The first build may show a keychain prompt asking to let codesign use the key: choose Always Allow. If the permission ever gets confused, clear it with `tccutil reset ScreenCapture com.arthurwalsh.record916` and grant again.

## How it works

The overlay is a transparent borderless `NSWindow`. Recording is done by the built-in `screencapture -v -R x,y,w,h` tool, which the app starts and stops (SIGINT finalises the movie). Multi-display setups are handled by converting the region to global top-left coordinates.

<h1 align="center"><img src="assets/icon.png" width="72" align="absmiddle" alt="">&nbsp;&nbsp;TAPEDECK</h1>

<p align="center"><code>window app</code>&nbsp;&nbsp;<code>macOS 13+</code>&nbsp;&nbsp;<code>free · GPL-3.0</code></p>

<p align="center">☕ If you use Tapedeck and like it, I would be glad if you <a href="https://buymeacoffee.com/moritzpoth">bought me a coffee</a>.</p>

A tiny macOS app that records whatever your Mac is playing – a browser tab, a video call, a player – straight to a WAV file, 48 kHz / 24 bit. Two keys, like on an old tape deck: *aufnahme* and *stop*. No drivers, no audio routing.

After you stop, the editor opens: trim the recording, cut out what you don't need, add other audio files and put the pieces in order before you save.

<p align="center"><img src="assets/screenshots/rec.png" width="250" alt="Tapedeck window: the wordmark, a counter with white wheels and two piano keys, record with a red dot and stop"></p>

*The app's interface is in German.*

> Please report problems in [Issues](../../issues).

## Features

- **Records the system audio** – everything that plays on the Mac, through ScreenCaptureKit. No extra driver (like BlackHole or Loopback) and no change to your sound output. Tapedeck's own sounds are left out.
- **WAV, 48 kHz / 24 bit** – the format editing programs expect.
- **Edit before saving** – after *stop* the window *Schnitt* opens. Nothing is written to your disk until you press *sichern*; until then the recording is a temporary file.
- **Cut** – set *in* and *out*, *schnitt* removes that part and closes the gap; the join is shown as a piece of splicing tape. ⌘Z undoes every step.
- **J / K / L** as in editing programs: L plays forward, J backwards, pressing again plays faster (2×, 4×); K stops. Hold K and tap J or L to step one frame.
- **Add audio files** – *anfügen* appends one or more audio files (WAV, AIFF, MP3, M4A …) at the end of the timeline. They are converted to the recording's format; your original files are never changed.
- **Move clips** – every piece of the timeline is a clip: the recording, each added file and each part left over after a cut. Drag a clip with the mouse to put it somewhere else; the other clips make room.
- **Safe** – closing the editor window or quitting asks whether to save or discard the recording. Quitting during a recording asks too. If Tapedeck crashes or is force-quit while the editor is open, macOS reopens the editor with the recording the next time you start Tapedeck.

## Usage

<p align="center"><img src="assets/screenshots/editor.png" width="820" alt="Editor window Schnitt: the tape timeline with two clips joined by splicing tape, an In/Out range and the red playhead; below, rows of piano keys and the knobs zoom and höhe"></p>

1. Press *aufnahme* (or the space bar). The key stays down and the counter runs while Tapedeck records.
2. Press *stop* (or the space bar). The editor opens.
3. Edit, then *sichern* and choose where the WAV goes – or *verwerfen* to delete the recording.

| Key | Action |
|---|---|
| Space | play / stop |
| J · K · L | backwards · stop · forwards (again = faster) |
| K + J / K + L, ← / → | one frame (25 fps) back / forward, with sound |
| I · O | set in · out |
| X | cut out in to out (no in = from the start, no out = to the end) |
| ⌘Z | undo |
| ⌘+ · ⌘− · ⌘0 | zoom in · out · whole recording |
| ↩ | save (*sichern*) |

- **Click** on the tape to move the playhead. **Drag** a clip to move it. To scrub, drag in the strip with the time marks at the top of the timeline.
- **Knobs:** drag up or down to turn them. *zoom* goes from the whole recording to the closest view, *höhe* makes the waveform taller for quiet recordings.

## Requirements

- macOS 13 Ventura or later, Apple Silicon or Intel

## Install

1. Download `Tapedeck-<version>.dmg` from [Releases](../../releases) and open it.
2. Drag `Tapedeck.app` onto the **Programme** (Applications) folder in the window that opens.

<p align="center"><img src="assets/screenshots/dmg.png" width="460" alt="Download image window: Tapedeck.app, a brush arrow and the Applications folder"></p>

### First launch: “Apple could not verify …”

Tapedeck is open source and is not signed with a paid Apple Developer certificate. macOS therefore blocks the first launch. You only need to allow it **once**:

1. Double-click `Tapedeck.app`. macOS shows a warning – click **Done** (or **OK**).
2. Open **System Settings → Privacy & Security**.
3. Scroll down to *“Tapedeck” was blocked …* and click **Open Anyway**.
4. Confirm with your password and click **Open Anyway** again.

Alternatively, in Terminal:

```
xattr -dr com.apple.quarantine /Applications/Tapedeck.app
```

### Permission to record

The first recording asks for permission: macOS treats recording system audio like screen recording. Allow Tapedeck under **System Settings → Privacy & Security → Screen & System Audio Recording** (macOS 13/14: *Screen Recording*) and start Tapedeck again. Tapedeck only records sound, never the screen.

## Build

Requires the Xcode Command Line Tools.

```
./build.sh     # → Tapedeck.app (universal, ad-hoc signed)
./dmg.sh       # → Tapedeck.dmg (download image with window layout; asks once for Finder automation)
```

`Tapedeck.app/Contents/MacOS/Tapedeck --edit file.wav` opens a copy of a WAV in the editor without recording.

Tapedeck was called *SystemRecorder* until version 1.0.

## License

GPL-3.0-or-later – see [LICENSE](LICENSE). © 2026 Moritz Poth. Comes without any warranty.

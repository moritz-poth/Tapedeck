# Tapedeck

Tiny macOS app (SwiftUI, macOS 13+): records the system audio to WAV 48 kHz / 24 bit, then a cut editor in the look of a 1960s tape deck. UI in German only (owner's decision). Shared app rules: `~/.claude/skills/moe-apps/SKILL.md`.

- `main.swift` recorder + record window, `editor.swift` cut editor, `deck.swift` look (keys, counter, knobs, icon), `updater.swift` GitHub updater, `help.swift` About + manual (`help/de.md`).
- Build: `./build.sh` (version in `VERSION=`), release files: `./dmg.sh` → `Tapedeck.dmg` + signed `Tapedeck-<version>.zip` + `.sig` (key "Tapedeck update key" in the login Keychain, `scripts/update-key.swift`).
- Test instances share the bundle id and saved window state with the installed app: start them with `-ApplePersistenceIgnoreState YES`, never discard an editor you did not open.

## DMG window

Shared look (moe-apps "DMG window"), drawn by `scripts/make-dmg-background.swift`. **Left colour: tape brown #2A2623**, the brown of the editor's timeline (owner's decision 2026-11-18, after petrol, orange and a lighter brown #96836B were rejected). Known trade-off, accepted by the owner: the Finder draws the icon labels black in both appearances, so the name "Tapedeck" under the app icon is barely readable on it (1.1:1); the icon itself stands out strongly (11:1).

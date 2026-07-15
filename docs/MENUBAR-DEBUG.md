# Menubar invisibility on macOS 26 (Tahoe) — investigation log

**Symptom (2026-05-12)**: `Voice-to-Text.app` and `Utilities.app` both ran (PIDs alive, logs writing) but their `NSStatusItem`s never appeared in the menubar on any of the 3 displays.

**Resolution**: renamed bundle ids (`com.dailybrief.voice-to-text` → `-2` suffix, same for `utilities`). Icons immediately reappeared.

> **Current id (2026-07):** the app now ships as `com.whisperown.app` — a fresh
> string with no poisoning history, i.e. exactly the fix this log prescribes. If a
> rebuilt icon ever goes invisible again, the move is the same: pick a brand-new
> bundle id string (change it in both `Info.plist` and `build.sh`).

## Isolation steps that pinpointed bundle-id poisoning

1. Minimal probe with bundle id `com.dailybrief.probe-app` → icon visible.
2. Minimal probe rebuilt with bundle id `com.dailybrief.voice-to-text` → invisible.
3. Same minimal code, renamed bundle id `com.dailybrief.vtt-isolation-test` → visible.

So: same code, same `.app` structure, same ad-hoc sign — only the *bundle id string* differs. macOS had silently put two specific ids on a hide-list.

## What got ruled out

| Hypothesis | Verdict |
|---|---|
| Menubar overflow / notch clipping | No — confirmed on all 3 displays |
| `LSUIElement` misconfig | No — both Info.plist have `LSUIElement=true` |
| Persisted "drag-off" hide on app's own NSUserDefaults | No — domain only had `WhisperBackend` |
| Tahoe `NSStatusItem Visible Item-N` hide in `com.apple.controlcenter` | No — flipped all 11 to `1`, still hidden |
| Ad-hoc sign rejected by Tahoe | No — probe with same sign worked |
| LaunchServices state | No — same `.app` with different id worked |
| Code-level bug in app | No — minimal binary with poisoned id also invisible |
| `trackedApplications.isAllowed = false` | No — both ids had `isAllowed = true` in the registry |

## Where the hide-state likely lives (unconfirmed)

Searched and found bundle id references but no clear "hidden" flag in:

- `~/Library/Group Containers/group.com.apple.controlcenter/Library/Preferences/group.com.apple.controlcenter.plist` — `trackedApplications` blob (the obvious place; `isAllowed=true` for ours)
- `~/Library/Biome/streams/restricted/App.MenuItem/local/...` — Biome menu bar telemetry
- `~/Library/IntelligencePlatform/graph.db` — Apple Intelligence app knowledge graph
- `~/Library/DuetExpertCenter/_ATXDataStore.db` — Siri suggestions / context
- `~/Library/Preferences/com.apple.universalaccessAuthWarning.plist` — TCC warning shown tracking

The cache may be in `cfprefsd` in-memory state, or in an undocumented field of the `trackedApplications` Codable blob we didn't decode. The pragmatic fix (rename) was faster than continuing to dig.

## Diagnostic recipes that helped

```sh
# Confirm scene-discard in unified log (the smoking gun for poisoned bundles):
log show --last 1m --process "Voice-to-Text" --info | grep -iE "scene invalid|discarded|FBSWorkspaceScenesClient failed"

# Dump Tahoe's tracked-apps allowlist (base64 blob inside the plist):
defaults export com.apple.controlcenter - \
  | plutil -extract trackedApplications raw -o /tmp/tracked.bin - \
  && base64 -D < /tmp/tracked.bin > /tmp/tracked.plist \
  && plutil -p /tmp/tracked.plist

# Minimal status-item probe to prove the system itself is fine:
cat <<'EOF' > /tmp/probe.swift
import Cocoa
class D: NSObject, NSApplicationDelegate {
    var item: NSStatusItem!
    func applicationDidFinishLaunching(_ n: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.autosaveName = "Probe"
        item.isVisible = true
        item.button?.title = "PROBE"
        let m = NSMenu(); m.addItem(NSMenuItem(title: "Quit", action: #selector(NSApp.terminate(_:)), keyEquivalent: "q"))
        item.menu = m
    }
}
let app = NSApplication.shared; let d = D(); app.delegate = d
app.setActivationPolicy(.accessory); app.run()
EOF
swiftc /tmp/probe.swift -o /tmp/probe && /tmp/probe
```

## Permanent mitigations now in code

Both apps:

```swift
let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
statusItem.autosaveName = "<unique-name>"   // stable per-item name
statusItem.isVisible = true                  // explicit visibility
```

If this ever recurs after another Tahoe migration, the playbook is: rename bundle id again, rebuild, re-grant TCC.

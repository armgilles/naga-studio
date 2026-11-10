<p align="center">
  <img src="docs/icon.png" width="128" height="128" alt="Naga Studio icon">
</p>

<h1 align="center">Naga Studio</h1>

<p align="center">
  An open-source macOS app for the Razer Naga V3 Pro.<br>
  Remap the buttons, set the scroll direction, and see the battery in your menu bar.
</p>

<p align="center">
  <a href="https://github.com/marclou/naga-studio/releases/latest"><b>Download for macOS</b></a>
</p>

![The side view with the 12-button grid, live button presses and the action library](docs/screenshot-side.png)

## Features

- **Scroll direction for the Naga only.** Pick standard or natural scrolling for the mouse while your trackpad keeps its own setting.
- **Remap buttons.** The 12 side buttons, right click, wheel click and wheel tilt can trigger mouse clicks, copy and paste, tabs, Mission Control, Spotlight, screenshots, media keys, any keyboard shortcut you record, a text snippet, or an app.
- **Optional physical keyboard modifiers.** Keyboard assignments can use the Control, Shift, Option and Command keys you are holding, including changes while a mouse button stays down.
- **Live view.** Buttons light up on the drawing as you press them, and pressing a button selects it.
- **Profiles.** Keep separate button setups and switch between them from the window or the menu bar.
- **Battery in the menu bar.** Read over Bluetooth from the mouse itself.
- **Detect.** If a button sends something unexpected, press Detect and then the button to bind it.
- Runs in the background and can open at login.

![The top view with a callout for every button](docs/screenshot-top.png)

## Install

1. Download `Naga-Studio-<version>.zip` from the [latest release](https://github.com/marclou/naga-studio/releases/latest), unzip it, and drag **Naga Studio** to your Applications folder.
2. Open it. The app isn't notarized by Apple, so macOS blocks the first launch. Go to **System Settings → Privacy & Security**, scroll down, and click **Open Anyway**.
   If macOS says the app is damaged, run this once in Terminal:
   ```sh
   xattr -dr com.apple.quarantine "/Applications/Naga Studio.app"
   ```
3. Allow **Accessibility** when asked (System Settings → Privacy & Security → Accessibility → Naga Studio). macOS requires it before any app can read and remap input.
4. Allow **Bluetooth** when asked. It's only used to read the battery level.

Requires macOS 15 or later on Apple silicon or Intel. Tested with the Naga V3 Pro over Bluetooth.

## Physical keyboard modifiers

1. Select a remappable button and record a keyboard shortcut, or choose a keyboard-based preset.
2. Enable **Keep physical modifiers** in that button's inspector.
3. Keep Naga Studio running, then hold keyboard modifiers while using the mouse button.

For example, record just `1` and enable the option:

| Keyboard keys held | Mouse button produces |
| --- | --- |
| None | `1` |
| Control | `Control+1` |
| Shift | `Shift+1` |
| Option | `Option+1` |
| Command | `Command+1` |
| Control and Shift | `Control+Shift+1` |

This is not a recorded fixed combination. The emitted key uses the **union of the assignment's recorded modifiers and the physical modifiers**. For example, an assignment recorded as `Control+1` produces `Control+Shift+1` while Shift is held. Left and right modifier keys are tracked separately; releasing one does not cancel the other.

Modifier changes during a held button pass through as keyboard events, without releasing and retyping the assigned key. Subsequent repeats and the final key-up use the current modifiers. What an application does with a modifier change after the initial key-down depends on that application's input handling. Wheel tilts remain debounced down/up pulses, not held keys.

The option applies to all remappable inputs: all side buttons, right click, wheel click, both wheel tilts, and additional buttons **only if Detect receives an identifiable event from them**. It does not unlock left click or make firmware-only buttons interceptable. It is not available for mouse-click, text, media or app-launch actions; those keep their existing meaning.

The option is off by default, including in existing profiles. Existing fixed shortcuts and stored key combinations are preserved. The choice is saved per button in each profile, copied when duplicating a profile, and cleared when resetting the profile or replacing the assignment with a non-keyboard action.

**Permissions and lifetime:** Accessibility is required. If the event tap still cannot start, allow Input Monitoring in Privacy & Security as prompted by the app. Bluetooth permission only concerns the battery. Assignments are processed by the running app, not written to the mouse's onboard memory. Closing the window is fine, but quitting the app stops remapping. Disabling remapping, changing profiles or assignments, detecting inputs, disconnecting the mouse, sleeping, quitting, or an event-tap interruption releases output owned by the app without releasing physically held modifiers.

## Build from source

You need Xcode 26 (Swift 6.2).

```sh
git clone https://github.com/marclou/naga-studio.git
cd naga-studio
./scripts/build-app.sh --install
```

The script builds a universal app into `build/` and installs it in `/Applications`. Builds are ad-hoc signed, so macOS asks for Accessibility again after each rebuild. To keep the permission, sign with your own certificate:

```sh
SIGN_IDENTITY="Apple Development" ./scripts/build-app.sh --install
```

`./scripts/build-app.sh --zip` also packages a zip for a release, and `NagaStudio --render-preview <folder>` renders the screenshots above.

### Tests

```sh
./scripts/test.sh
swift build -c release --arch arm64
swift build -c release --arch x86_64
```

Tests use the bundled Swift Testing framework without third-party dependencies. With full Xcode, `swift test` also works directly. The script additionally supplies the framework/runtime paths needed by standalone Command Line Tools.

The tests inject device origins, hardware key state, time and output emission. They never create a live event tap, post real keystrokes, require a connected mouse, or write to the user's settings. Coverage includes legacy profiles, fixed shortcuts, routing, dynamic combinations, left/right modifiers, simultaneous actions and shared output ownership, repeats, tilt pulses, lifecycle cleanup, and persistence in an isolated preferences domain.

Unit tests do **not** establish hardware or application compatibility. Hardware validation is still required for USB as well as Bluetooth: check device attribution, every detectable button, held-key repeats, modifier changes during holds, simultaneous keyboard/mouse keys, profile changes, disconnects, permission changes and event-tap recovery. Do not infer USB support from simulated events or from the existing Bluetooth testing note.

## How it works

- **No kernel extension.** Naga Studio is a user-space driver: an event tap sees input before other apps do and rewrites what comes from the Naga.
- **Only the Naga is touched.** Each event is matched to the device that sent it, so your keyboard and trackpad pass through as they are.
- **Physical modifiers** are observed through hardware `.flagsChanged` events and the public `CGEventSource.keyState(.hidSystemState, key:)` API, including an initial snapshot. Mouse-event flags are not used as keyboard state. App-generated events carry a marker and are excluded; their private event-source state is separate from the hardware state. No additional HID reader is installed, and no typed text is collected for diagnostics.
- **Battery** comes from Razer's Bluetooth vendor service, using the protocol documented by [open-snek](https://github.com/gh123man/open-snek).
- **Privacy.** The app has no network code, no analytics and no accounts. Settings stay in your Mac's user defaults.

## Limitations

- DPI, scroll mode, the AI Prompt button and the ring finger button are handled by the mouse and usually send nothing to the Mac. Detect shows whether one does.
- Left click can't be remapped, so you can't lock yourself out.
- Some Naga units report a full battery until the battery gauge calibrates after a full charge.
- Only the Naga V3 Pro has been tested. Other Naga models may work.
- Device attribution still depends on dynamically loaded system symbols. If those symbols are unavailable, remapping stays stopped and the app explains the failure; it never falls back to intercepting every keyboard. Unidentified keyboard events pass through, even if their key code matches a held remapping. If a Naga repeat or release loses attribution, it cannot safely be claimed as a mouse event; disabling remapping clears any remaining app-owned output.
- Wheel click retains the existing narrow system-event heuristic while a Naga is connected, because macOS can omit its device. This is not reliable device attribution when another mouse is also connected. Other unidentified mouse buttons are not claimed by that heuristic.

## Credits

- Razer Bluetooth protocol notes: [open-snek](https://github.com/gh123man/open-snek)
- Font: [Chakra Petch](https://fonts.google.com/specimen/Chakra+Petch), SIL Open Font License 1.1

## License

[MIT](LICENSE). Naga Studio isn't affiliated with or endorsed by Razer. Razer and Naga are trademarks of Razer Inc.

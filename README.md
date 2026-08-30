<p align="center">
  <img src="Design/NuphyBarAppIcon.svg" width="128" height="128" alt="NuphyBar logo">
</p>

<h1 align="center">NuphyBar</h1>

<p align="center">Show local AI agent status on compatible keyboard lighting.</p>

<p align="center">
  <a href="README.zh-CN.md">简体中文</a> ·
  <a href="https://github.com/itsmaiGe/NuphyBar/releases/latest">Download</a> ·
  <a href="https://x.com/Samoye">Maige on X</a>
</p>

NuphyBar is a lightweight native macOS menu-bar app. It receives lifecycle events from Codex, Claude Code, Antigravity, OpenCode, and other local agents, then sends compact HID reports using the selected keyboard protocol. NuPhy firmware renders animations locally; the AULA F99 Pro uses its stock real-time RGB mode for solid full-key colors.

It never reads or stores keystrokes and does not stream animation frames.

> [!IMPORTANT]
> The firmware in the current Release is **only for the NuPhy Air60 V2 ANSI**. Never flash the Air60 V2 binary to an Air75 V2, Air96 V2, Halo, Gem80, or any other model. A firmware image for the wrong model can make the keyboard unusable.

## Light states

| Agent state | Air60 V2 right side light |
|---|---|
| Idle | No override; stock rainbow/battery effect returns |
| Working | A continuous blue brightness wave moves across all five LEDs |
| Waiting/error | An amber double pulse on all five LEDs |
| Complete | A green breathing effect on all five LEDs |

The stock cyan Caps Lock indicator remains on the left side. Agent state only uses the right side light.

The Halo75 V2 ANSI port uses seven distinct states over USB and a safe three-state subset over Bluetooth. See [`firmware/halo75-v2-ansi`](firmware/halo75-v2-ansi) for its exact color plan and current verification status.

The **AULA F99 Pro** Bluetooth path uses the stock non-persistent `0x88` real-time RGB command. It changes the full key backlight without writing keyboard configuration flash. The stock real-time mode expires unless refreshed, so NuphyBar resends the current color once per second while this keyboard is connected. Idle and complete are both solid green; working, tool use, and errors are red; output is yellow; waiting is blue. The independent right light bar is not used because its HID configuration path persists changes to flash.

## Keyboard compatibility

### Implemented and physically verified

| Model | Transport | Status | Light area |
|---|---|---|---|
| **Air60 V2 ANSI** | Bluetooth Low Energy | Supported | Five right-side RGB LEDs |
| **Halo75 V2 ANSI QMK** | Wired USB Raw HID | Supported on the tested keyboard | Five upper-left RGB LEDs, indices 83–87 |
| **Halo75 V2 ANSI QMK** | Bluetooth Low Energy | Core path verified; release validation pending | Five upper-left RGB LEDs, indices 83–87 |
| **AULA F99 Pro** | Bluetooth Low Energy as `AULA-F99Pro 5.0` | Supported on the tested keyboard | Full key RGB backlight |

Air60 V2 Bluetooth typing, the left Caps Lock indicator, every Agent state, reconnection, and sustained typing stability have been tested on real hardware.

Halo75 V2 Bluetooth typing, Caps Lock, all three compact states, idle restoration, and keyboard power-cycle reconnection were verified on the target keyboard on 2026-08-28. The app reopened the BLE HID session and resent the current state with zero output-report errors. Sleep/wake, BLE2/BLE3 channel switching, sustained typing, and official recovery remain before release support.

AULA F99 Pro BLE discovery, configuration reads, stock color indices, all seven NuphyBar states, and the non-persistent full-key real-time RGB command were verified on the target keyboard on 2026-08-28. Its right light bar was confirmed to ignore standard host LED reports and real-time RGB zone modes. The protocol behavior matches the public [AULA F99 direct-mode capture](https://gitlab.com/CalcProgrammer1/OpenRGB/-/work_items/5166).

### Port-ready, but each model needs its own firmware

| Model | Expected effort | Why |
|---|---:|---|
| **Air75 V2** | Low to medium | Same Air V2 QMK family and the same left/right side-light roles |
| **Air96 V2** | Low to medium | Same Air V2 QMK family; NuPhy's own firmware already maps Num Lock to the right side light |

These models can reuse NuphyBar's HID state protocol and effect model, but their LED indices, function addresses, firmware baseline, and memory layout must be verified independently. **The Air60 V2 `.bin` cannot be reused.**

### Feasible with model-specific visual design

| Model | Available lighting | Notes |
|---|---|---|
| Halo65 V2 QMK | Halolight / nameplate | Needs a ring or segmented effect rather than a five-step bar |
| Halo96 V2 QMK | Halolight / right light | NuPhy's firmware already contains a right-side Num Lock indication path |
| Gem80 tri-mode | RGB light bar / nameplate | Only the Bluetooth-capable tri-mode variant is in scope |

### Not currently supported

- Air V1, Halo V1, Field75, and other models on the older NuPhy firmware line;
- Air60 HE, Air75 HE, Field75 HE, and other HE/IO models;
- Air V3, Halo V2 IO, Kick75 IO, BH65, and other NuPhy IO products;
- the wired-only Gem80, because USB support is currently scoped to the exact Halo75 V2 ANSI Raw HID profile.

NuPhy IO and QMK are different firmware stacks. Having a light bar is not sufficient for this patch. See NuPhy's [firmware catalog](https://nuphy.com/pages/firmware) and [QMK firmware releases](https://nuphy.com/pages/qmk-firmwares).

## Architecture

NuphyBar uses an event-driven path. The Mac sends the current state; the keyboard generates the animation locally.

```mermaid
flowchart TB
    A["① Agent hook records a lifecycle event"]
    B["② Atomic state file + macOS notification"]
    C["③ NuphyBar combines active sessions"]
    D["④ Persistent HID session sends one state report"]
    E["⑤ Keyboard firmware renders every frame"]
    A --> B --> C --> D
    D -->|Bluetooth LED/RGB report or USB Raw HID| E
```

| Component | Responsibility | What it does not do |
|---|---|---|
| Agent hook | Atomically update local state and post a system notification | Control the keyboard directly |
| NuphyBar | Combine concurrent sessions and send the displayed state using the selected keyboard protocol | Stream animation frames |
| Keyboard | Render a local NuPhy animation or an AULA solid color | Read Agent content |

NuPhy keyboards receive one report per displayed state. The AULA F99 Pro receives a one-second keepalive for its current solid color because its stock real-time mode expires. NuphyBar never streams animation frames such as “light LED 1, then LED 2.”

The local state file is the durable source of truth; the macOS notification is only the wake-up signal. NuphyBar reads the file at launch and whenever a lifecycle event arrives, then creates one timer for the next state expiration. Normal operation has no Agent-state polling. If system notification registration fails, a five-second fallback poll keeps the app functional.

### Connection recovery in 0.5.9

Earlier releases repeatedly scanned for the keyboard and opened it for each check or command. NuphyBar 0.5.9 instead keeps one non-exclusive HID manager active and listens for macOS device connection/removal callbacks.

```mermaid
flowchart LR
    A["HID ready"]
    B["Discard stale session"]
    C["Retry after 1 · 2 · 5 · 10 · 30 s"]
    D["Replay latest Agent state"]
    A -->|report failure or Mac wake| B --> C --> D --> A
```

- A failed output report invalidates the old HID session instead of immediately hammering the same stale device handle.
- Mac wake proactively rebuilds the HID session; the user does not need to power-cycle the keyboard.
- When delivery becomes ready again, NuphyBar replays the current combined Agent state.
- If another Agent event arrives while a report is being sent, it is coalesced into one immediate follow-up refresh.
- Complete and error indications expire after about 15 seconds using an exact deadline, then idle lighting is restored.

### How one byte represents the state

NuphyBar does not add a private BLE GATT service. It reuses the keyboard's existing standard LED output report:

| HID bit | Value | NuphyBar meaning |
|---|---:|---|
| Num Lock | `0x01` | Working |
| Caps Lock | `0x02` | Reserved for the stock left Caps indicator |
| Scroll Lock | `0x04` | Waiting/error |
| Num + Scroll | `0x05` | Complete |
| No Num/Scroll | `0x00` | Idle; restore the stock effect |

The complete report is only two bytes: `[Report ID 1, state mask]`. Caps Lock is added independently, so the stock left indicator remains functional.

Only the Num and Scroll bits are available, so the safe protocol supports three non-idle states. Error and waiting intentionally share the amber attention effect. A distinct fourth state would require a new wireless protocol rather than another value in this two-bit channel.

### Halo75 V2 ANSI protocols

The wired Halo port uses the existing QMK/VIA Raw HID interface at usage page `0xFF60`, usage `0x61`. Reports are 32 bytes, start with the `NB` signature and protocol version, carry one state byte, and end with an XOR checksum. The custom firmware changes the USB product string to `NuPhy Halo75 V2 NuphyBar`, so the app does not mistake stock firmware for a compatible device.

Raw HID carries seven values: idle, thinking, tool running, outputting, permission required, complete, and error. The app still sends only when the displayed state changes. Hardware battery, Caps Lock, sleep, and radio indications run after the Agent overlay and therefore keep priority.

Bluetooth reuses the same standard two-byte LED Output Report as the Air60 V2. The Halo wireless module copies the host LED mask into `dev_info.rf_led` while BLE1, BLE2, or BLE3 is connected. The firmware ignores the Caps Lock bit and maps working to slow red breathing, waiting/error to fast blue breathing, complete to solid green, and idle to the stock effect. The 2.4 GHz transport is not enabled by this port.

### Why this does not interfere with typing

Early experiments streamed animation frames over Bluetooth. Real hardware eventually froze the light strip and stopped typing. The release design no longer does that:

- NuphyBar sends one HID report only when the final display state changes;
- the keyboard retains NuPhy's stock wireless polling interval;
- every wave, pulse, and breathing frame is generated by a local keyboard timer.

Bluetooth therefore receives only an occasional state value, not an animation frame rate. Typing and animation stay on separate paths.

## Air60 V2 release firmware

`stable-v7` is not a rebuild of an older public QMK tree. It applies an audited minimal hook to NuPhy's official Air60 V2 v2.1.5 firmware:

- official baseline SHA-256: `cd0425f548a01416d1c3c25208ff74867fffd20165520c7c2eaa56000ff347bf`
- NuphyBar firmware SHA-256: `c573c7939a53994b50f29313744f27f9af30b90cd064f13fc019f87710b89ac0`
- only four official bytes at `0x080028EA–0x080028ED` are changed;
- those bytes redirect the original `sys_led_show()` call to a hook at `0x08010E00`;
- the hook calls the original `sys_led_show()` first, preserving Caps Lock;
- USB and idle states return without overriding stock behavior;
- the added effect code is 332 bytes and uses no `.data` or `.bss`;
- UART, RF polling, key reports, sleep, pairing, and USB input are untouched;
- the builder verifies machine-code signatures at critical official functions and refuses the wrong baseline;
- the verifier proves that only the call site and appended hook differ from the official image.

The source, reproducible builder, and tests are in [`firmware/air60-v2`](firmware/air60-v2).

> [!NOTE]
> While an Agent is active, its state temporarily replaces the right-side battery indication. Stock battery/rainbow lighting returns at idle. Do not rely on the right side light as your only battery check during a long task.

## Install NuphyBar

Requirements:

- macOS 14 or later;
- an Apple Silicon Mac;
- a supported NuPhy keyboard with compatible custom firmware, or an AULA F99 Pro using its stock firmware;
- Bluetooth Low Energy for the Air60 V2 and AULA F99 Pro ports, or Bluetooth Low Energy and wired USB for the Halo75 V2 ANSI port.

Steps:

1. Download `NuphyBar-0.5.9-macOS-arm64.dmg` from [Releases](https://github.com/itsmaiGe/NuphyBar/releases/latest).
2. Open the DMG and drag NuphyBar to Applications.
3. On first launch, if macOS blocks the app, Control-click it and choose Open, or approve it in System Settings → Privacy & Security.
4. Grant Input Monitoring when prompted. This allows HID output to the keyboard; NuphyBar does not read or store keystrokes.
5. Reopen NuphyBar and confirm the exact keyboard model and Bluetooth connection on the Keyboard tab.
6. Enable the desired integrations on the Agent tab, then start a new task in that agent.

The Release DMG is ad-hoc signed and is not yet notarized with an Apple Developer ID. Its full source, build script, and checksums are public.

## Agent integrations

| Agent | Integration | Main lifecycle events |
|---|---|---|
| Codex | `~/.codex/hooks.json` | prompt submit, permission, tool completion, stop |
| Claude Code | `~/.claude/settings.json` | prompt, permission, input notification, tool completion, session end |
| Antigravity | `~/.gemini/config/plugins/nuphybar` | model invocation, fully-idle completion, execution error |
| OpenCode | global local plugin | busy, idle, error, permission |
| Grok Build | personal hooks file | prompt, tool, failure, permission, stop |
| Hermes | local lifecycle plugin | LLM call, approval, session completion |
| OpenClaw | managed local hook | message received, result sent, stop |

The installer changes only entries that it owns or marks. It refuses to overwrite an unmarked user file with the same name. Codex may still ask you to trust each newly installed hook.

Display priority is:

```text
error/waiting > tool running > outputting > working > complete > idle
```

One completed session never hides another session that is still working. Completion is retained for about 15 seconds. Active states do not expire and remain visible until an explicit lifecycle event ends the session.

## Flash the Air60 V2 firmware

Read [`firmware/air60-v2/README.md`](firmware/air60-v2/README.md) first. In short:

1. Verify that the keyboard is a **NuPhy Air60 V2 ANSI**.
2. Export the current VIA keymap.
3. Download `NuphyBar-Air60-V2-stable-v7.bin` and verify its SHA-256.
4. Keep NuPhy's [official Air60 V2 v2.1.5 recovery firmware](https://nuphy.com/pages/qmk-firmwares) ready.
5. Connect USB and enter STM32 DFU. The NuPhy/QMK source documents holding the top-left Esc key while plugging in; you can also follow [NuPhy's update instructions](https://nuphy.com/pages/update-instructions).
6. Select the correct `.bin` in [QMK Toolbox](https://github.com/qmk/qmk_toolbox/releases) and flash it. Never unplug or power off during the write.
7. Restart, switch back to Bluetooth, verify typing and Caps Lock first, then test NuphyBar states.

Advanced users may use the following only after confirming that the detected STM32 DFU device is the intended keyboard:

```bash
dfu-util -a 0 -s 0x08000000:leave -D NuphyBar-Air60-V2-stable-v7.bin
```

Flashing is a destructive checkpoint. Never let a script infer the model, and never begin without a recovery image.

## Build the macOS app

Requires macOS 14+ and the Swift 6.1 toolchain.

```bash
git clone https://github.com/itsmaiGe/NuphyBar.git
cd NuphyBar
swift test
./script/package_release.sh
```

The DMG is written to `dist/NuphyBar-0.5.9-macOS-arm64.dmg`.

To build, install, and run locally:

```bash
./script/build_and_run.sh
```

## Rebuild the firmware

Install the build tools:

```bash
brew install arm-none-eabi-gcc@8 arm-none-eabi-binutils dfu-util
```

Download NuPhy's official Air60 V2 ANSI v2.1.5 firmware and run:

```bash
./firmware/air60-v2/build.sh \
  /path/to/QMK_firmware_nuphy_air60_v2_ansi_v2.1.5.bin
```

The build runs effect and Thumb branch tests, validates the official baseline, compiles the hook, adds the DFU suffix, and verifies the final layout. GCC 8.5.0 reproduces the `stable-v7` Release binary byte for byte.

For the Halo75 V2 ANSI USB and Bluetooth port, use an official NuPhy QMK checkout and Docker or QMK CLI:

```bash
./firmware/halo75-v2-ansi/test.sh
./firmware/halo75-v2-ansi/build.sh /path/to/nuphy-src/qmk_firmware
```

The builder accepts only the audited official commit and produces `NuphyBar-Halo75-V2-ANSI.bin`. It does not flash the keyboard.

## Ask Codex or Claude Code to port/flash firmware

Ready-to-use local coding-agent prompts and mandatory safety checkpoints are provided here:

- [中文：让 AI 编写、移植和刷写固件](docs/AI_FIRMWARE_GUIDE.zh-CN.md)
- [English: AI-assisted firmware porting and flashing](docs/AI_FIRMWARE_GUIDE.en.md)

AI may inspect source, implement effects, run tests, and compile. **Entering DFU, confirming the exact model, and authorizing the final flash must remain a separate human confirmation step.**

## Privacy and security

- no keystroke reading, logging, or uploading;
- hooks send only the provider, coarse state, and a local session identifier;
- the state file stays local and contains no prompts or responses;
- no cloud service, analytics SDK, or background network API;
- config edits preserve unrelated user settings and refuse unmarked conflicts.

See [`SECURITY.md`](SECURITY.md). Never attach sensitive local configuration to a public issue.

## Repository layout

```text
Sources/
  AgentLightApp/      macOS menu app and settings UI
  AgentLightCore/     state aggregation, hook mapping, integration installer
  AgentLightHID/      NuPhy BLE and USB HID discovery and output reports
  AgentLightCLI/      short-lived helper bundled inside the app
firmware/air60-v2/    stable-v7 hook, builder, verifier, and tests
firmware/halo75-v2-ansi/ Halo75 USB/BLE overlay, builder, and tests
Design/               source artwork for the app and menu-bar logos
script/               app build, local install, and DMG packaging
Tests/                Swift tests
```

## License

- macOS app, ordinary project scripts, and documentation: [`MIT`](LICENSE)
- QMK/NuPhy-derived code and patches under `firmware/`: [`GPL-2.0-or-later`](firmware/LICENSE-GPL-2.0-or-later.md)
- third-party Agent icons and trademarks belong to their owners and are used only for identification; see [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).

NuphyBar is a community project and is not affiliated with or endorsed by NuPhy, OpenAI, Anthropic, or any other agent vendor.

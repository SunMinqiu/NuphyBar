# Halo75 V2 ANSI USB firmware

This port targets only the NuPhy Halo75 V2 ANSI in wired USB mode. It controls the five LEDs in the upper-left status light at RGB Matrix indices 83 through 87. Do not flash its output on an ISO keyboard, another Halo size, or a NuPhy IO model.

The source baseline is NuPhy's official `nuphy-src/qmk_firmware` commit `4223dece7852b9fd9abd7c61559272241ef4a223`, dated 2025-03-25. The audited Halo75 V2 ANSI tree is `601063bb3bf91073d364063e69fedddbbef1e049`. NuPhy's official Halo75 V2 ANSI v2.1.5 recovery image has SHA-256 `4393adb563b93051552af1161a9f3c460d549adea413e1dca3ab8a27505d61c0`.

The app sends one checksummed 32-byte Raw HID report when the state changes. The firmware renders all animation frames locally and leaves the stock Halolight untouched while idle. The USB product string is changed to `NuPhy Halo75 V2 NuphyBar`, so the app never mistakes stock firmware for a compatible device.

| State | Upper-left light |
| --- | --- |
| Idle | Stock effect |
| Thinking | Slow red breathing |
| Tool running | Solid red |
| Outputting | Slow yellow breathing |
| Permission required | Fast blue breathing |
| Complete | Solid green |
| Error | Fast red flashing |

With ordinary Codex Hooks, `UserPromptSubmit` and `PostToolUse` map to thinking, `PreToolUse` maps to tool running, `PermissionRequest` maps to permission required, and `Stop` maps to complete. Hooks do not expose streamed response deltas, so outputting is available in the protocol and CLI but is not inferred from `PostToolUse`.

Run the host-side model tests with:

```bash
./firmware/halo75-v2-ansi/test.sh
```

Build from an official NuPhy QMK checkout with:

```bash
./firmware/halo75-v2-ansi/build.sh /path/to/nuphy-src/qmk_firmware
```

The dedicated output is `NuphyBar-Halo75-V2-ANSI-USB.bin` in the repository root. Before physical testing, export the VIA layout and obtain the official Halo75 V2 ANSI recovery firmware. Flashing requires a separate explicit confirmation.

The pinned Docker toolchain produces a 67,718-byte image with SHA-256:

```text
f31e5917e473f3385e2ce3ee41edf72d6d82fba9a0c7f61ccc3a487d1d3bd260
```

Two clean builds produced the same file byte for byte.

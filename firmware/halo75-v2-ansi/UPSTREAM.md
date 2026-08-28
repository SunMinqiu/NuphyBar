# Upstream firmware notice

The Halo75 V2 ANSI USB port is derived from NuPhy's QMK source and remains licensed under GPL-2.0-or-later.

Upstream references:

- NuPhy QMK source: <https://github.com/nuphy-src/qmk_firmware>
- exact source commit: `4223dece7852b9fd9abd7c61559272241ef4a223`
- Halo75 V2 ANSI tree: `601063bb3bf91073d364063e69fedddbbef1e049`
- NuPhy QMK firmware catalog: <https://nuphy.com/pages/qmk-firmwares>
- official Halo75 V2 ANSI v2.1.5 recovery image: <https://cdn.shopify.com/s/files/1/0268/7297/1373/files/QMK_firmware_nuphy_halo75_v2_ansi_v2.1.5.bin?v=1741067981>
- official recovery SHA-256: `4393adb563b93051552af1161a9f3c460d549adea413e1dca3ab8a27505d61c0`
- NuPhy update instructions: <https://nuphy.com/pages/update-instructions>

The builder creates a detached worktree at the exact source commit, applies the small source overlay in this directory, and compiles the existing `via` keymap. It does not include NuPhy's source tree or recovery binary in this repository.

The pinned build container is `qmkfm/qmk_cli@sha256:b7d7fa8fb4432b569931de5ad59098cb788f440ed61a62c5126746b71aee0f4a`, which contains arm-none-eabi-gcc 15.2.0. Version strings are skipped so clean builds are reproducible. The resulting 67,718-byte firmware has SHA-256 `f31e5917e473f3385e2ce3ee41edf72d6d82fba9a0c7f61ccc3a487d1d3bd260`.


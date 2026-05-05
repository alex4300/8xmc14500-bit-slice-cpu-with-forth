# Forth Block Storage

> ⚠ **This document was written for the BSRAM era and is now historical. The BSRAM emulator was removed in Phase C (2026-04-25); all blocks now live exclusively on SD over SPI.**
>
> For the current architecture see [CLAUDE.md → Word inventory](../CLAUDE.md#word-inventory-rom) and [CLAUDE.md → SD-Card over SPI](../CLAUDE.md#sd-card-over-spi).

## TL;DR (current state, post-Phase-D)

- **All blocks** are 256-byte SD sectors, addressed by 2-cell `( hi lo )`.
- **Sector 0:0** — boot block (magic header `\ 8xMC14500\r\n` + auto-load command).
- **Sector 0:1..0:255** — direct user space (typically: source upload at 0:100..0:138, raw HEDIT, ad-hoc storage). Not managed by files-FS.
- **Sector 1:0** — files-FS directory (16 slots × 16 bytes).
- **Sector 1:1+** — files registered via `REGISTER`.

Block API (all 2-cell `( hi lo )`):

- `BLOCK ( hi lo -- )` — loads sector into BLOCK_BUF at RAM 0x0200.
- `LOAD ( hi lo -- )` — `BLOCK` + interpret-from-buffer.
- `THRU ( h1 l1 h2 l2 -- )` — interpret blocks h1:l1..h2:l2 as one continuous source. ROM `rch_uart` advances the THRU counter on block-end and seamlessly loads the next.
- `UPDATE / FLUSH` — mark dirty / write back to SD.
- `B@ ( offset -- byte )` — read byte at BLOCK_BUF[offset].
- `RXBLK ( hi lo -- )` — receive 256 B from UART, store in block, FLUSH.
- `LIST ( hi lo -- )` — `BLOCK` + `DUMP` (hex+ASCII view).
- `HEDIT ( hi lo -- | -- )` — full-screen hex editor.

For the auto-load workflow + onboarding sequence see [README.md → Host-side block upload](../README.md#host-side-block-upload-phase-d--sd-only).

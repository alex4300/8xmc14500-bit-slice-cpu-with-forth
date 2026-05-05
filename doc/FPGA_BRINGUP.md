# FPGA Bring-Up Guide (Tang Primer 20K)

Step-by-step to get the MC14500 CPU + Forth running on real silicon.

## Hardware

- **SoM:** Sipeed **Tang Primer 20K** (note: *Primer*, not Nano — different board, different pinout)
- **Dock:** Tang Primer 20K Dock (HDMI version)
- **FPGA:** Gowin GW2A-LV18PG256C8/I7 (PG256 BGA package, ~20K LUTs, BSRAM)
- **UART bridge:** CH340 on the dock (USB-C to host)
- **Clock:** 27 MHz onboard oscillator (no PLL — direct)
- **Reset:** S0 / KEY0 button on the dock

The constraints file is `constraints/tang_primer_20k.cst`.

## Toolchain (open-source)

You need: **yosys**, **nextpnr-himbaechel** (with apicula), **gowin_pack**, **openFPGALoader**.

The simplest setup is the [oss-cad-suite](https://github.com/YosysHQ/oss-cad-suite-build) bundle — it contains all four. After extracting:

```bash
export PATH="$HOME/Downloads/oss-cad-suite/bin:$PATH"
```

(This project's Makefile expects `gowin_pack` on `PATH` — if it's missing the
final pack step fails with `gowin_pack: No such file or directory`, while
synth + route already succeeded. Just re-run with `PATH=...` set.)

### Verify

```bash
yosys -V
nextpnr-himbaechel --help
gowin_pack --help
openFPGALoader --version
```

## First flash

```bash
# 1. Build Forth ROM (auto-runs as bitstream dependency, but explicit is fine)
make build/forth.mem

# 2. Synthesize + place+route + pack
make bitstream

# 3a. Flash to FPGA SRAM (volatile — gone after power cycle)
make flash

# 3b. Or flash to external SPI flash (persistent across power-off)
make flash-bit
```

## Talking to the board

Once flashed, the dock appears as a USB-UART on your host:

- **macOS:** `/dev/cu.usbserial-*` (CH340 device)
- **Linux:** `/dev/ttyUSB0` or `/dev/ttyACM0`

Use a serial terminal at **115200 8-N-1 with software flow control** (XON/XOFF).
Without flow control, fast paste loses characters — the on-FPGA RX FIFO sends
0x13/0x11 to throttle the host, but only if the terminal acts on them.

```bash
# tio — recommended, has -f soft for software flow control
tio -b 115200 -m INLCRNL -f soft /dev/cu.usbserial-XXXX

# picocom alternative
picocom -b 115200 --imap lfcrlf /dev/ttyUSB0
```

Press S0 (reset) — the boot sequence prints:

```
ok
>
```

Now you have a Forth REPL on your own CPU on your own FPGA. Try:

```
3 5 + .                       → 8
: DOUBLE DUP + ;
7 DOUBLE .                    → 14
: UP 10 0 DO I . LOOP ;  UP   → 0 1 2 3 4 5 6 7 8 9
200 100 UM* D.                → 20000     ( 16-bit unsigned multiply )
: HELLO S" Hi from MC14500" TYPE CR ;  HELLO   → Hi from MC14500
```

`.` and `D.` print signed decimal. `.S` shows the data stack in hex.

### Pre-built block library

The bitstream embeds a 32-block BSRAM "disk" (8 KB) initialized from `asm/demo/blocks.fth`.
Pasting Forth source over UART loses characters on large bursts even with XON/XOFF
(host-side paste buffers outrun the FPGA). Loading from blocks sidesteps that — the FPGA
reads out of its own BSRAM at full speed.

| Block | Contents |
|-------|----------|
| 0 | Auto-boot: defines `THRU` and `LIST`, chains through the editor, ends at MENU |
| 1 | GPIO LED library (LED2-5 via MMIO) |
| 2 | Sierpinski triangle demo (`SIERP`) |
| 3 | `FACT` — factorial |
| 4 | `FIB` — Fibonacci |
| 5 | Return-stack test (`RSTEST`) |
| 6-8 | RC4 cipher — `6 LOAD RC4` → `BB F3 16 E8 D9 40 AF 0A D3` |
| 10-12, 14, 29 | Line editor + DUMP + `.CH` (↵ for LF). Auto-loaded at boot. |
| 13 | RC4-encrypted block demo (`XBLK`) |
| 15-28 | **Hex editor (HEDIT)** — auto-loaded. `HEDIT` or `N HEDIT`. Keys: arrows, Tab=mode, Enter→0x0A shown as `↵`, BS/^X/^N=del-left/del/ins, ^O=save, ^R=revert, ^F/^B=next/prev block, ESC=save+quit, ^C=discard+quit. Status: `BLK=NN` + `*` when unflushed. |
| 30-39 | **Mandelbrot** — `30 LOAD MANDEL` (~11.5 s @ 27 MHz for default 24×12). 8.8 signed fixed-point. Block 33 has `WIDTH`/`HEIGHT`/`STEP-X`/`STEP-Y`/`MAXITER` CONSTANTs — edit with HEDIT to resize. |
| 40 | `MENU` welcome banner — auto-runs at boot, callable anytime. |

```
6 LOAD          ( block 6 chains → 7 → 8 )
RC4             → cipher: BB F3 16 E8 D9 40 AF 0A D3

10 LOAD         ( editor: EDIT, .LINE, DUMP, dirty-safe LIST )
2 BLOCK  3 .LINE   ( inspect line 3 of block 2 without reloading )
3 EDIT new content  ( up to 16 chars, Enter ends, spaces pad )
UPDATE FLUSH     ( persist to BSRAM; re-flash for true persistence )
```

To modify and re-bake: edit `asm/demo/blocks.fth`, `make bitstream`, `make flash-bit`.

**Heads-up on persistence:** the on-chip BSRAM is **volatile** — blocks you
`UPDATE FLUSH` survive the session but vanish on power-off. `make flash-bit`
is currently the only way to get truly persistent block data (it bakes the
current `blocks.fth` into the SPI flash alongside the bitstream).

## LED status indicators

LEDs on the Dock are active-low. The mapping in `mc14500_top.v`:

| LED | Source | Meaning |
|-----|--------|---------|
| 0 | `heartbeat[25]` | Heartbeat (~0.4 Hz blink) — top-level alive |
| 1 | `!debug_halted` | CPU running (lit = not halted) |
| 2 | `gpio_out[0]` | User GPIO bit 0 (write `0x7FF4`) |
| 3 | `gpio_out[1]` | User GPIO bit 1 |
| 4 | `gpio_out[2]` | User GPIO bit 2 |
| 5 | `gpio_out[3]` | User GPIO bit 3 |

LEDs 2–5 are CPU-controllable from Forth — write a 4-bit value to MMIO `0x7FF4`:

```forth
: LED 0x7FF4 ! ;        ( pattern -- )
0xF LED                 ( all 4 user LEDs on )
0 LED                   ( all off )
```

If LED 0 doesn't blink, the bitstream didn't load (or the clock pin is wrong).
If LED 0 blinks but LED 1 stays off, the CPU halted — verify `build/forth.mem` is current.

## Storage

The FPGA build embeds a **64-block × 256-byte BSRAM "disk"** (16 KB total) initialized from `asm/demo/blocks.fth`. Block 0 boots automatically; the boot loader chains through the editor and demo blocks, ending at `MENU` (block 40), which prints a welcome banner.

To rebuild storage from edited `blocks.fth`:

```bash
make build/storage_init.vh   # auto-runs as bitstream dependency
make bitstream
make flash-bit               # persistent
```

For full block-storage details (BLOCK / LOAD / FLUSH / .fth syntax) see [BLOCKS.md](BLOCKS.md).

## Troubleshooting

**`gowin_pack: No such file or directory`** at the very end of `make bitstream`
- Synth + place+route succeeded; just `gowin_pack` isn't on `PATH`. Set `PATH` to your toolchain bin (e.g. `~/Downloads/oss-cad-suite/bin`) and re-run `make bitstream` — it picks up where it left off.

**`openFPGALoader: FTDI interface not found`**
- Linux: install udev rules
  ```bash
  sudo cp /usr/local/share/openFPGALoader/99-openfpgaloader.rules /etc/udev/rules.d/
  sudo udevadm control --reload-rules && sudo udevadm trigger
  ```
- macOS: unplug/replug the USB cable, or try with `sudo`.

**Pasting Forth source loses characters**
- Terminal isn't using software flow control. Add `-f soft` to `tio` (or the equivalent in your terminal) so 0x13/0x11 from the FPGA actually pause the host.
- Last resort: load via blocks (`N LOAD`) instead of pasting.

**No UART output**
- Check pin assignments in `constraints/tang_primer_20k.cst` against your dock revision.
- Loopback test: short `M11` (uart_tx) to `T13` (uart_rx) on the dock — characters typed in the terminal should echo back. (`make loopback-test` flashes a wire-only loopback bitstream for this.)

**CPU hangs on first boot after flashing**
- The BSRAM-backed RAM/ROM needs a full reset. `mc14500_top.v` already holds reset for 256 cycles after power-on; if it still doesn't come up, hit S0.

**Synthesis hits a yosys hang on `opt_merge`**
- Caused by mixing BRAM read/write into one `always` block. Keep them separate (the existing CPU and storage modules already do this — see `mc14500_top.v` for the pattern). Documented in `feedback_yosys_bsram_inference.md`.

## Next steps

1. **SD card storage** — wire microSD on the dock to the storage MMIO (`0x7FF8-0x7FFA`) for blocks beyond 64.
2. **HDMI text terminal** — use the dock's HDMI TX to render a character display from a small framebuffer.
3. **PLL clock-up** — the GW2A has a PLL; current 27 MHz is very comfortable (Fmax ~59 MHz after 15-bit-PC + 32-block storage), 50–75 MHz should be reachable.

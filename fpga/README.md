# fpga/: the Pocket implementation

The FPGA side of the Radio-86RK core for the Analogue Pocket (Cyclone V 5CEBA4F23C8, Quartus Prime Lite 25.1std). It is self-contained: the SD package in `../package/` only needs the bitstream that this directory builds.

The Radio-86RK machine is the Karabas core (`rk86_machine`, `rk86_video`, `rk86_video_stream`). `fpga/` reads it only through `RK86_CORE_DIR`, the core's `src` directory; the default is `../../cores/karabas-go-core-rk86/src`, the submodule. The core sources are never copied or patched. Moving `fpga/` elsewhere means changing `RK86_CORE_DIR`.

Clocks: [../README.md](../README.md#how-the-clocks-work).

## Directories

| Path | Content |
|---|---|
| `apf/`, `core/` | the APF template (open-fpga/core-template da3a021) with the Analogue notices; `core/core_top.v` holds the pins, the bridge, the PLL and one instance of `pocket_system` |
| `rtl/` | our logic; `pocket_system.v` is everything behind the template, `radio86rk_pocket.v` is the board around the machine |
| `quartus/` | `ap_core.qsf`, `create_project.tcl`, the CDC and timing report scripts |
| `sim/` | `run_sim.py` and `frame_compare.py`; `unit/` module TBs, `system/` the TB of `pocket_system`, `memory/` the Pocket memory for the core's machine TB, `negative/` faults as `.patch`, `golden/` the POC frames |

## Bridge map

Registers decode all 32 address bits. Status (`rtl/pocket_system.v`) and the interact registers (`rtl/pocket_interact.v`) answer `0x0000_0000-0x0000_01FF`; the mux in `core/core_top.v` sends `0xF8xx_xxxx` to the APF command block. Any other address in the window reads 0.

| Address | Use |
|---|---|
| 0x0000_0000 | Identity, `0x524B4D31` |
| 0x0000_0008 | Flags: bit 0 boot done (PLL lock), 1 setup done, 2 `reset_n`, 3 assets valid, 4 memory ready |
| 0x0000_0014 | Asset status (loading, valid and error bits of monitor, font, ROM disk; `pocket_boot_assets.v`) |
| 0x0000_001C, 0x20, 0x3C | CRC32 of the monitor, the font, the ROM disk |
| 0x0000_0024 | CPU address (low 16 bits) |
| 0x0000_0028 | Count of native frames |
| 0x0000_0034 | Keyboard panel: bit 7 panel open, bits 6:0 selected key id (0..66) |
| 0x0000_0044 | Keyboard state: bit 0 RUS (`rus_mode`), 1 SS (Shift) line, 2 US (Ctrl) line, 3 RUS line, 4 Shift latch, 5 Dock keyboard |
| 0x0000_0030, 0x38, 0x40 | Read 0 (the POC's D/Enter injection, game keys and cartridge guard are removed) |
| 0x0000_0100 | Action (write): 1 Reset, 2 Cold boot; one clock pulse; reads 0 |
| 0x0000_0104 | Sound, bit 0, default 1 |
| 0x0000_0108 | Text colour, bit 0: 0 white, 1 green |
| 0x0000_010C | Keys: 0 Cursor, 1 Digits 7-8-9-6, 2 Digits 8-4-6-2, 3 WASD (writes above 3 are ignored) |
| 0x0000_0110 | Keys on: 0 D-pad, 1 A B X Y (writes above 1 are ignored) |
| 0x0000_0114 | Escape: 0 Select, 1 Start, 2 None (writes above 2 are ignored) |
| 0x0000_0118 | Keyboard colours: 0 Pink (v1.1), 1 Grey (v1.4), 2 Mono (writes above 2 are ignored) |
| 0x0000_011C-0x0000_0144 | Reserved; read 0, writes ignored |
| 0x2000_0000, 0x2100_0000, 0x2200_0000 | Data slots 0, 1, 2 (below) |
| 0x2300_0000 | Reserved: slot 3, tape image |
| 0xF8xx_xxxx | APF |

The interact registers have no reset. Pocket OS writes the saved values while `reset_n` is low and reads them back every frame; the initial values are the defaults of `package/core/interact.json`.

## On-screen keyboard (K1)

- `rtl/pocket_keyboard.v`: the buttons as keyboard lines. The 64 matrix keys, and SS (Shift), US (Ctrl) and RUS/LAT as separate lines (ids 64..66), are pulled low and ANDed with the mapped keys. It also holds the panel state: open, selection, the Shift latch. Timings (tap, chord window, RUS minimum, minimum hold, auto-repeat) are parameters in milliseconds.
- `rtl/pocket_k1_panel.v`: draws the 284 x 82 panel in the 12.288 MHz output stage (`pocket_frame_video.v`), 3 clocks of latency; the picture path is delayed to match. It reads the state once per frame (at x = 0, y = 0).
- `rtl/pocket_k1_layout.vh`: generated key table, labels, small glyphs and palettes. Do not edit it. The single source is `scripts/k1/layout.py`; regenerate with `python -B scripts/k1/gen_verilog.py` (a test checks the file is up to date). The labels come from the monitor's key decoder, run on `BIOS.BIN` by `scripts/k1/monitor_decoder.py`.
- `rtl/pocket_bus_cdc.v` (+ `.sdc`): a toggle handshake that carries the state word from `clk_74a` to the video clock whole. The constraint cuts the held-word path and the two token paths; the synchronizer stages stay timed.
- Test model, not RTL (nothing includes it): `rtl/pocket_key_defs.vh`: `native_character`, the model of the monitor's decoder (FF06), checked against all 512 key and modifier cases.

The state bus (78 bits, `clk_74a` to the video clock):

| Bits | Meaning |
|---|---|
| 0 | panel open |
| 7:1 | selected key id |
| 8 | RUS (`rus_mode`) |
| 9, 10, 11 | SS (Shift), US (Ctrl), RUS lines pulled |
| 75:12 | matrix line k pulled, at bit 12+k |
| 77:76 | palette: 0 Pink, 1 Grey, 2 Mono |

## Data slots

From `package/core/data.json`. The sizes are exact.

| Id | Name | File | Address | Size (bytes) | Required |
|---|---|---|---|---|---|
| 0 | Monitor | monitor.bin | 0x2000_0000 | 2048 | yes |
| 1 | Font | font.bin | 0x2100_0000 | 1024 | yes |
| 2 | ROM disk | romdisk.bin | 0x2200_0000 | 32256 | no |

A missing or bad monitor or font holds the CPU in reset and shows the red diagnostic frame. A missing ROM disk is legal: A000-BFFF reads FF. The sizes and CRCs are in [../package/assets.json](../package/assets.json).

## Build and tests

Prerequisites: Quartus Prime Lite 25.1std (`QUARTUS_ROOT`, or `quartus_sh` on PATH), Icarus Verilog 13 (`IVERILOG` or `--iverilog`), Python 3, PowerShell 7. The ROM disk is fetched into `build/assets` by `scripts/fetch_assets.py`.

```text
pwsh -File scripts/build.ps1                       build in build/quartus, then scripts/check_build.py
python -B fpga/sim/run_sim.py                      every test that is not slow
python -B fpga/sim/run_sim.py --slow               adds the system scenarios
python -B fpga/sim/run_sim.py --negative           each fault must fail with its named error
python -B fpga/sim/run_sim.py boot menu            named tests only
```

Tests of the keyboard:

- `keyboard`: the buttons, the chord, L and R, navigation and auto-repeat, with five faults.
- `k1_panel`: the panel in the output stage, 7 states, every pixel compared with the Python model (`scripts/k1/layout.py`).
- `bus_cdc`: the handshake with random gaps and a destination reset.
- `k1` (slow, about 40 minutes): the system scenario. It opens the panel, types through it, and captures 7 frames (Shift latch, RUS, Ctrl, three palettes). `python -B scripts/k1/check_frames.py build/sim/k1` compares each panel with the model.
- `python -B -m unittest scripts/tests/test_k1_layout.py` (needs `IVERILOG`): the key table, the generated file, `native_character` against the monitor's decoder (512 cases) and every `k1_*` function against the model.

The core's machine TB runs on the Pocket memory (`pocket_memory.v`) in place of the core's own model (`--iverilog` is needed when `iverilog` is not on PATH):

```text
python -B cores/karabas-go-core-rk86/src/sim/machine/run_machine_sim.py [--iverilog PATH] --mem fpga/sim/memory/tb_rk86_mem.v fpga/rtl/pocket_memory.v
```

`scripts/check_build.py` checks every Quartus build (no errors, timing met). Simulation and build results are not hardware verification.

## Licences

`apf/` and `core/` carry the Analogue notices (see `apf/TEMPLATE-NOTICES.md`). The rest of `fpga/` is BSD-3-Clause. All parts: [../LICENSES.md](../LICENSES.md).

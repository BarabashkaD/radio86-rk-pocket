# AGENTS.md

Instructions for coding agents. User docs: `README.md`. Design, bridge map, data slots: `fpga/README.md`. Also `LICENSES.md`, `CHANGELOG.md`.

## 1. Repository

openFPGA core of the Radio-86RK (KR580VM80A, an i8080 clone) for the Analogue Pocket. Version 0.8.1 (2026-11-11).

- Identity (`package/core/core.json`, `package/platform/radio86rk.json`, `scripts/package.py`): author `BarabashkaD`, shortname `Radio86RK`, core id `BarabashkaD.Radio86RK`; platform `radio86rk` ("Radio-86RK", category Computer); one bitstream `bitstream.rbf_r`; dock yes, analog output no, sleep no.
- Machine: `rk86_machine16` from the submodule, used unchanged: the original's 16 MHz timing, each chip (8224 and К155ИЕ4 clocks, 8080, 8257, 8275, 8255, video path, board glue) to its data sheet. Where the data sheets are silent, the decisions and planned real-hardware checks are in the fork's `src/rtl/rk86_16/README.md`.
- This repo: the Pocket board around the machine (clock enable, memory, slot loading, ROM disk device (the A000-BFFF block, second 8255), buttons, K1 on-screen keyboard, raster, display window, frame buffer, audio, Core Settings).
- Device Cyclone V `5CEBA4F23C8`; Quartus Prime Lite 25.1std.

| Path | Content |
|---|---|
| root | `README.md`, `CHANGELOG.md`, `LICENSE` (BSD-3-Clause), `LICENSES.md`, `AGENTS.md` |
| `fpga/` | RTL, APF template, Quartus project, simulation (section 5) |
| `cores/karabas-go-core-rk86/` | submodule: the fork with the machine, monitor, font, game tapes, its tests |
| `package/` | SD package definitions, `assets.json`, `romdisks.txt` template |
| `scripts/` | build, checks, assets, packaging, K1 tools, ROM disk tools, remote simulation, Python tests |
| `images/` | README pictures |
| `build/` | all generated output (ignored) |

## 2. Dependencies

- **Submodule** `cores/karabas-go-core-rk86`: `https://github.com/BarabashkaD/karabas-go-core-rk86` (fork of andykarpov/karabas-go-core-rk86), branch `rk86-16mhz`; the pin: `git ls-tree HEAD cores/karabas-go-core-rk86`.
  - Read only through `RK86_CORE_DIR` (the fork's `src`; default `cores/karabas-go-core-rk86/src`) by `fpga/quartus/create_project.tcl`, `fpga/sim/run_sim.py`, `fpga/sim/run_core_machine.py`, `scripts/package.py`.
  - Used from it, nothing else: `src/rtl/rk86_16/`; `src/rk86_machine16.prj` (source list: `k580vm80a.v`, `rk86_clocks16.v`, `k580vv55.v`, `k580vt57.v`, `k580vg75.v`, `rk86_video16.v`, `rk86_machine16.v`); `src/sim/machine16/` (runner, `cpu_power_up.vh`, `tb_rk86_mem16.v`); `src/sim/negative.py`; `src/roms/BIOS.BIN`, `src/roms/FONT.BIN`; `pk/` (game tapes). `cart_ppi` takes only `k580vv55.v`.
  - Before touching `radio86rk_pocket.v`, `pocket_memory.v`, `pocket_cart_ppi.v` or `pocket_raster.v`: read the fork's `src/rtl/rk86_16/README.md`, the file headers, the header of `rk86_machine16.v` (ports, glue). The fork's `docs/integration.md` describes the Karabas `rk86_machine`, not this core.
  - Planned: the chip models and the machine move out of the Karabas fork into their own repositories.
- **APF template**: `fpga/apf/`, `fpga/core/` from open-fpga/core-template `da3a021`, with the Analogue notices (`fpga/apf/TEMPLATE-NOTICES.md`).
- **Assets** (`package/core/data.json`; size, CRC32, SHA256, source in `package/assets.json`):

| Slot | File | Size | Source | Required |
|---|---|---|---|---|
| 0 | `monitor.bin` | 2048 | fork `src/roms/BIOS.BIN` | yes |
| 1 | `font.bin` | 1024 | fork `src/roms/FONT.BIN` | yes |
| 2 | `romdisk.bin` | 32256 | skiselev/radio-86rk `Software/rom_disk.bin` at `c5e9cb7` | no (any image up to 32768 bytes) |

- Files are loaded byte by byte as they are (`pocket_slot_loader`), no checks; the CRC32 and SHA256 check only fetching and packaging.
- Slot 2 `parameters` 75 (user-reloadable, core-specific, read-only, core reset while loading); slots 0 and 1: 10. A reload restarts the machine with the RAM kept.
- `scripts/fetch_assets.py`: the ROM disk, its GPL-3.0 licence and Kiselev's `rom_loader.asm` (for `test_romdisk.py`) into `build/assets`, checked. Never commit the ROM disk.
- Game disks: `scripts/romdisk/build_romdisks.py` puts the 48 tapes of `pk/` into `build/romdisks/romdisk-1.bin` .. `romdisk-9.bin` (32256 bytes each, fixed table `DISKS`) with the loader `scripts/romdisk/rom_loader_games.asm` (GPL-3.0), plus `romdisks.json` and `romdisks.txt`. `package.py` builds the same disks into every package and lists their games in `info.txt`; `package/romdisks.txt` is the template of the package's `romdisks.txt` (`@GAME_DISKS@` replaced).
- The font is also in the bitstream: `fpga/rtl/native_font.vh` (K1 panel).
- **Licences**: `LICENSES.md`, one row per part.

## 3. Prerequisites

- Quartus Prime Lite **25.1std** exactly (`scripts/build.ps1` refuses others): `QUARTUS_ROOT` = the `quartus` directory, or `quartus_sh` on PATH; Windows layout (`bin64\quartus_sh.exe`).
- Icarus Verilog 13 (`iverilog` and `vvp` in one directory): `IVERILOG`, `--iverilog PATH`, or PATH.
- Python 3 (standard library only), PowerShell 7 (`pwsh`), git (faults use `git apply`).
- Network once for `scripts/fetch_assets.py`.
- Optional: the rk86-vvp container for remote simulation (`scripts/docker2tests/README.md`).
- Clone with submodules: `git clone --recursive <repo url>`, or `git submodule update --init --recursive`.
- Environment: `QUARTUS_ROOT`, `IVERILOG`, `RK86_CORE_DIR` (optional), `RK86_VVP_HOST`, `RK86_VVP_KEY` (remote runs).

## 4. Rules

- **Fork**: never copy or patch its sources; read them only through `RK86_CORE_DIR`. A change is made in the fork and comes in by moving the pin (`git -C cores/karabas-go-core-rk86 checkout <sha>`, `git add cores/karabas-go-core-rk86`). When the pin moves, update the pinned links in `fpga/README.md`. A change in `src/rtl/rk86_16/` needs the fork's own tests (`run_machine16_sim.py --negative`). `rk86_machine` belongs to the Karabas boards; the Pocket does not build it.
- **Faults**: unified-diff `.patch` files (from `git diff`, paths relative to the repo root) in `fpga/sim/negative/`, applied to copies under `build/sim` by `run_sim.py` with `git apply`. Never edit sources with text-replacement scripts. When a patch's target changes, regenerate the patch.
- **K1 table**: `fpga/rtl/pocket_k1_layout.vh` is generated; edit `scripts/k1/layout.py` and run `python -B scripts/k1/gen_verilog.py`. `test_k1_layout.py` fails when it is stale.
- **Core Settings size**: Pocket OS 2.7 refuses a core whose list options total 97 or more (66 loads). `package.py` allows at most 20 list options and 16 items, ids unique and not 0-2. Keep in sync: `package/core/interact.json`, `fpga/rtl/pocket_interact.v` (0x100-0x118, range checks), `scripts/tests/test_package.py` names, bridge map in `fpga/README.md`, controls in `package/core/info.txt` and `README.md`.
- **Template**: our logic stays out of `fpga/apf/`, `fpga/core/` beyond instances and wiring; `core_top.v` instantiates one `pocket_system`, the rest is in `fpga/rtl/`.
- **Files**: LF, final newline. `.gitattributes` is `* -text`: git keeps bytes as they are.
- **`info.txt`**: ASCII only, exactly one `Credits:` line (`package.py` inserts the game list before it).
- **Outputs** go to `build/` (ignored). Never commit bitstreams, assets or zips.
- **Claims**: simulation and build results are not hardware results. Hardware runs are the maintainer's; never report hardware behaviour from simulation.
- **Git**: commit or push only when asked; never rewrite published history.
- **Releases**: the openFPGA library's updater takes every GitHub release with a `.zip` within about 30 minutes (pre-release flag ignored). Create drafts, check, then publish; never publish a test build. The updater finds the files by `author.shortname`; a bad `date_release` or empty `platform_ids` breaks the library's update job (`package.py` checks both).
- **Privacy**: no absolute local paths, host or user names, IPs or emails in committed files; paths relative to the repo or from env vars.
- **Test tiers** (section 6): quick for every commit; sanity (`boot`) first after an RTL, TB or pin change; standard after an RTL or TB change; full once before a push; release before a package goes to the Pocket (only the ROM disk scenarios the change touches). Choose by the files changed; docs only: `check_repo.py`. Long system scenarios: at most two at once, each in its own `run_sim.py` call, never the same one twice at once; stop at the first failure.

## 5. Sources

### `fpga/rtl/` (BSD-3-Clause)

| File | Role |
|---|---|
| `pocket_system.v` | everything behind the template: slot loader, interact registers, board, frame banks, audio, PLL watchdog, resets; status registers (identity `0x524B4D31`) |
| `radio86rk_pocket.v` | the board around `rk86_machine16`, one clock `clk_74a`: `ce16` (64 of 297 ticks), reset (144 `ce16`), memory, font, ROM disk, keyboard, `pocket_raster` and display window, beeper (INTE) |
| `pocket_memory.v` | RAM 0000-7FFF and monitor (8000-87FF of the array), one byte-wide port at `bus_a` (CPU, or 8257 while AEN), loader port in reset; output follows `bus_a`; no write during AEN or while `rom`; no wait states; RUS shadow. A DMA read is decoded like a CPU read: the 8275 gets the byte of whatever is at the 8257's address (this memory, an 8255, the 8275) |
| `pocket_cold_clear.v` | clears the 32 KB RAM at the first boot and on Cold boot |
| `pocket_slot_loader.v` | data-slot writes: each bridge word as 4 bytes into the monitor, font or ROM disk; bytes beyond the requested size dropped; `assets_valid` |
| `pocket_rom8.v` | byte memory, one write and one read port (1 clk latency): font, ROM disk |
| `pocket_cart_ppi.v` | the A000-BFFF block (second 8255; the machine's `ext_rd_n`, `ext_we_n`, `ext_di`, the fork's "window"): the fork's `k580vv55` with Kiselev's ROM disk wiring (port B, PC0-PC6 ROM address; port A ROM data while PC7 is a low output); its A1, A0 from `bus_a`, also during DMA |
| `pocket_keyboard.v` | buttons as keyboard lines (64 matrix + SS, US, RUS), K1 panel state, Shift latch; timings in ms parameters |
| `pocket_remap.v` | button map from Keys, Keys on, Escape |
| `pocket_k1_panel.v` | the 284 x 82 K1 panel in the 12.288 MHz output stage, 3-stage pipeline |
| `pocket_k1_layout.vh` | generated key table, labels, glyphs, palettes (do not edit) |
| `pocket_bus_cdc.v` | toggle handshake of the 78-bit panel state, `clk_74a` to the video clock |
| `pocket_raster.v` | native raster: dots from the HRTC fall, lines from the VRTC fall; frame start only for 200-1023 lines of 256-1023 dots; holds when the syncs stop |
| `pocket_window.v` | the 408 x 300 display window (dots `X0` = 42 to 449, lines 0-299); `X0` is also `WINDOW_X0` in `run_sim.py` |
| `pocket_frame_video.v` | dual-clock ping-pong frame banks, 60 Hz output, K1 overlay, red diagnostic frame input (undriven) |
| `pocket_audio.v` | beeper level to 48 kHz signed 16-bit I2S with a DC blocker |
| `pocket_interact.v` | Core Settings registers 0x100-0x144; no reset, defaults from `interact.json` |
| `pocket_pll_watchdog.v` | restarts the video/audio PLL after 2^21 clk (28 ms) without lock |
| `native_font.vh` | the font as Verilog functions (6 x 8) |
| `pocket_key_defs.vh` | test model only (`native_character`, the monitor's FF06 decoder) |
| `pocket_machine_cdc.sdc`, `pocket_audio_cdc.sdc`, `pocket_bus_cdc.sdc` | CDC constraints: cut first synchronizer stages only; fail loudly when register names change |

### Other `fpga/`

- `core/`: `core_top.v` (pins, bridge mux, PLL, one `pocket_system`), `core_bridge_cmd.v`, `mf_pllbase*` (12.288 MHz PLL), `core_constraints.sdc`. `apf/`: unchanged template, `TEMPLATE-NOTICES.md`.
- `quartus/`: `ap_core.qsf`; `create_project.tcl` (project in a build dir, `fpga/rtl/*.v` plus `rk86_machine16.prj`, `VERILOG_CONSTANT_LOOP_LIMIT 40000`); report-only `report_pocket_machine_cdc.tcl`, `report_pocket_audio_cdc.tcl`, `report_pocket_timing.tcl` (`quartus_sta -t` in a build dir).
- `sim/`:
  - `run_sim.py` (runner, `TESTS`); `frame_compare.py` (1-bit 408 x 300 frame vs golden, one cell tolerance; `--cursor cursor.txt --x0 N` masks the cursor cell); `run_core_machine.py` (fork's `machine16` on `pocket_memory`, then fault `memory_dropped_after_rd`, must fail with `ERROR: dma byte`).
  - `unit/`: one TB per module (`tb_slot_loader`, `tb_bus_cdc`, `tb_cart_ppi`, `tb_cold_clear`, `tb_cpu16`, `tb_frame_colour`, `tb_frame_video`, `tb_k1_panel`, `tb_native_audio`, `tb_pll_watchdog`, `tb_pocket_interact`, `tb_pocket_keyboard`, `tb_pocket_memory`, `tb_pocket_raster`, `tb_pocket_window`); `cpu16/cpu_test.asm` (assembled with `scripts/romdisk/asm8080.py`).
  - `system/`: `tb_system.v` (`pocket_system` with a PLL stub, `+scenario=`; stops when no plausible frame comes within 2 s simulated; writes `cursor.txt`) and `power_up.vh` (includes the fork's `cpu_power_up.vh`).
  - `memory/tb_rk86_mem16.v`: `pocket_memory` as the memory model of the fork's `machine16` TB.
  - `negative/`: fault patches (each listed in `run_sim.py` with its expected error). `golden/`: `monitor-boot.hex`, `rom-disk-menu.hex`, SHA256 in `golden/README.md`.

### `scripts/`

| File | Use |
|---|---|
| `build.ps1` | Quartus build into `build/quartus` (`-BuildDir`, `-QuartusRoot`), then `check_build.py` |
| `check_build.py` | 0 errors, no critical warning but `ALLOWED_CRITICAL`, 5 slack kinds non-negative in 4 corners, `ap_core.rbf` present |
| `fetch_assets.py` | fetch and check ROM disk, licence, Kiselev's loader source (`--record-licence`) |
| `romdisk/asm8080.py` | two-pass 8080 assembler (Kiselev's syntax) |
| `romdisk/rom_loader_games.asm`, `romdisk/loader.py` | games menu loader (GPL-3.0; keys 0-9, A-Y; Z clears RAM), `games_loader()` |
| `romdisk/emu8080.py` | small 8080 emulator with monitor stubs, for the tests |
| `romdisk/build_romdisks.py` | the 9 game disks into `build/romdisks` (`--pk`, `--out`); `build()`, `metadata()` used by `package.py` |
| `package.py` | SD package and zip; openFPGA field and interact limits; bit-reversed RBF; icon and platform image; game disks, `romdisks.txt`, games in `info.txt`; library zip check |
| `k1/layout.py` | single source of the K1 table, labels, navigation, model `render_panel` |
| `k1/gen_verilog.py` | writes `pocket_k1_layout.vh` (`--out PATH`) |
| `k1/monitor_decoder.py` | runs the monitor's decoder (FE72) from `BIOS.BIN`; prints the 64 x 8 table |
| `k1/render.py`, `k1/check_frames.py` | panel model to PNG/GIF; captured panels vs model |
| `check_repo.py` | tracked files: LF, final newline, no links into `docs/`, no absolute local paths (`EXEMPT_PREFIXES`, `LEGACY`) |
| `ci/unit-tests.ps1`, `ci/package-dry-run.ps1` | Python tests as in CI (a skip fails); `package.py` with a stand-in bitstream |
| `docker2tests/` | rk86-vvp container and `remote_sim.py` (its `README.md`, section 9) |
| `tests/test_package.py` | package and definition limits, `romdisks.txt`, `info.txt` game list, game disks |
| `tests/test_k1_layout.py` | key table, decoder, generated file, Verilog vs model (needs iverilog) |
| `tests/test_check_repo.py` | `check_repo.py`; fails while a fixed file is still in `LEGACY` |
| `tests/test_core_machine_subset.py` | `run_core_machine.py` matches the pinned fork runner |
| `tests/test_frame_compare.py` | the cursor mask of `frame_compare.py` |
| `tests/test_romdisk.py` | assembler (Kiselev's loader byte-exact), games loader, every key of every disk; needs `fetch_assets.py` |

### `package/`

`core/core.json` (version, date filled by `package.py`), `data.json`, `interact.json`, `input.json`, `video.json` (408 x 300, 34:25), `audio.json`, `variants.json`, `updaters.json` (`declare_ai` only), `info.txt` (shown on the Pocket), `platform/radio86rk.json`, `assets.json`, `romdisks.txt` (template).

## 6. Build and test

From the repo root; Python with `-B`.

```text
python -B scripts/fetch_assets.py                  assets into build/assets (every system scenario reads romdisk.bin)
python -B fpga/sim/run_sim.py                      every test that is not slow (unit TBs)
python -B fpga/sim/run_sim.py --negative           also each fault: it must fail with its named error
python -B fpga/sim/run_sim.py --slow               adds the system scenarios
python -B fpga/sim/run_sim.py boot menu            named tests only
python -B fpga/sim/run_sim.py --iverilog PATH ...  iverilog not on PATH and IVERILOG unset
```

Outputs: `build/sim/<test>/`. Pass: `vvp` exits 0, a `PASS` line, no `ERROR`/`FATAL`, frame compare passes where set.

### Tests (`TESTS` in `run_sim.py`)

| Test | Kind | Time |
|---|---|---|
| `cart_ppi`, `audio`, `bus_cdc`, `keyboard`, `frame_video`, `frame_colour`, `k1_panel`, `slot_loader`, `memory`, `cold_clear`, `window`, `interact`, `raster`, `watchdog` | unit | all with faults about 15 min at 2 jobs |
| `cpu16` | slow: `cpu_test.asm` on `rk86_machine16` with `pocket_memory` (through `fpga/sim/memory/tb_rk86_mem16.v`); phase 7 a DMA block in the monitor ROM (the 8275 must take the program bytes); faults `cpu16_bus_bit`, `cpu16_startup_decode` | 7 min |
| `boot` | system: slots, cold clear, monitor to FE63, frame vs `monitor-boot.hex` (cursor masked), beeper follows INTE, native frame period 319 920 `ce16` | 16-30 min |
| `powerup` | system: randomised CRT and DMA registers, frame vs `monitor-boot.hex` | 21 min |
| `nocart`, `reset`, `relock`, `system_watchdog` | system | 15, 60, 40, 31 min |
| `system_k1_panel` | system (scenario `k1_panel`): the panel with the machine frozen (`ce16` held low), 3 captures; then `python -B scripts/k1/check_frames.py build/sim/system_k1_panel --expect 3` | 23 min with the machine running; frozen: to be measured |
| `keytap` | system: an 80 ms and a 1 ms button tap reach the monitor (`pocket_keyboard` on real milliseconds; INFO: the time to the delivery); fault `keytap/min_hold_short` | not measured yet |
| `k1` | system: 7 panel captures; then `python -B scripts/k1/check_frames.py build/sim/k1` | 105 min |
| `menu` | ROM disk: frame vs `rom-disk-menu.hex` | 155 min |
| `xonix`, `dpddt` | ROM disk | 190, 182 min |
| `game` | ROM disk: disk 9 from `build/romdisks` (build first), XONIX1 by key B | 189 min |
| `tetris` | kept, skipped unless named (`run_sim.py tetris`); its D-pad mapping is to be reviewed | |

Times: measured 2026-11-11 on a 10-CPU host with several runs in parallel.

### Test tiers

Choose by `git diff --name-only <base>...HEAD` plus uncommitted changes.

| Tier | When | Tests | Time |
|---|---|---|---|
| quick | every commit | `check_repo.py`; Python tests of the changed scripts or data (`unit-tests.ps1` runs all); `run_sim.py --negative <unit TBs whose files or patches changed>` | 1-15 min |
| sanity | first system check after an RTL, TB or pin change | `run_sim.py boot` | 16-30 min |
| standard | after an RTL or TB change | quick, sanity, the scenarios of the changed modules (table below); `run_sim.py --negative cpu16` and `run_core_machine.py` after a change of `pocket_memory.v` or `fpga/sim/memory/` (7 min; 25-30 min, then its fault as long); package dry run after a change of `package/` or package scripts; Quartus build (10 min) after a change of `fpga/core/`, `fpga/apf/`, `fpga/quartus/` or an `.sdc` | 30 min to 2 h |
| full | once before a push | every unit TB with faults; `run_sim.py --negative cpu16`; `unit-tests.ps1`; `boot`, `powerup`, `nocart`, `reset`, `relock`, `system_watchdog`, `system_k1_panel`, `run_sim.py --negative keytap`, `k1` (with `check_frames.py`); `run_core_machine.py`; the fork's runner with `--negative` (unit TBs 2 h 8 min at 2 jobs, `machine16` with faults 2 h at 4 jobs); `package-dry-run.ps1`; `build.ps1` | about 6 h in parallel |
| release | before a package goes to the Pocket | full, the ROM disk scenarios the change touches (`menu`, `xonix`, `dpddt`, `game`), then `package.py` on the real build | up to +3.5 h |

| Changed | Standard | Release adds |
|---|---|---|
| `pocket_keyboard.v`, `pocket_remap.v` | `system_k1_panel`, `keytap` | `k1` |
| `pocket_k1_panel.v`, `pocket_k1_layout.vh`, `native_font.vh`, `scripts/k1/` | `system_k1_panel` | `k1` |
| `pocket_bus_cdc.v` | `system_k1_panel`, `relock` | |
| `pocket_frame_video.v` | `boot`, `system_k1_panel`, `relock` | |
| `pocket_raster.v`, `pocket_window.v` | `boot` | `menu` |
| `pocket_memory.v`, `pocket_cold_clear.v` | `boot`, `reset`, `cpu16`, `run_core_machine.py` | `menu` |
| `pocket_slot_loader.v`, `pocket_rom8.v` | `boot`, `nocart` | `menu` |
| `pocket_cart_ppi.v` | `nocart` | `menu`, `xonix` |
| `pocket_audio.v` | `relock` (`audio` checks the samples) | |
| `pocket_pll_watchdog.v` | `system_watchdog`, `relock` | |
| `pocket_interact.v` | `boot`, `reset` | |
| `radio86rk_pocket.v` | `boot`, `nocart`, `reset`, `system_k1_panel` | `menu` |
| `pocket_system.v`, `tb_system.v`, `power_up.vh` | `boot`, `nocart`, `reset`, `relock`, `system_watchdog`, `system_k1_panel` | `menu` |
| `scripts/romdisk/` | (`test_romdisk.py` in quick) | `game` |
| a new module | the `pocket_system.v` row | `menu` |

Always the full tier: a pin move, a change of `.gitattributes`, of a golden frame, or of the iverilog version.

### The fork's tests

```text
python -B fpga/sim/run_core_machine.py [--iverilog PATH] [--frames N]
python -B cores/karabas-go-core-rk86/src/sim/machine16/run_machine16_sim.py [--iverilog PATH] [--negative] [--list] [TEST ...]
```

- `run_core_machine.py`: `machine16` with `--mem fpga/sim/memory/tb_rk86_mem16.v fpga/rtl/pocket_memory.v` (absolute paths), then the fault `memory_dropped_after_rd` on a copy under `build/sim/core_machine/`.
- The fork's runner: `clocks16`, `vv55`, `vt57`, `vt57_func`, `vg75`, `vg75_dma`, `vg75_attr`, `video16`, `machine16`, each with faults in `src/sim/machine16/negative/`.
- Both write into the fork's ignored `build/sim/machine16/`.

### Remote simulation

`scripts/docker2tests/remote_sim.py` runs `run_sim.py` (`--runner pocket`) or the fork's runner (`--runner fork`) in the rk86-vvp container with the same pass rules; setup and options in `scripts/docker2tests/README.md`, section 9.

### Python tests, K1 generator

```text
pwsh -File scripts/ci/unit-tests.ps1                     all Python tests as in CI (a skip fails)
python -B -m unittest scripts/tests/test_package.py
python -B -m unittest scripts/tests/test_k1_layout.py     (Verilog part needs iverilog)
python -B scripts/check_repo.py
python -B scripts/k1/gen_verilog.py
python -B scripts/k1/monitor_decoder.py
```

### Quartus build (about 10 min)

```text
pwsh -File scripts/build.ps1 [-BuildDir <dir>] [-QuartusRoot <quartus dir>]
python -B scripts/check_build.py build/quartus
```

`build.ps1` recreates the build dir, runs `create_project.tcl`, compiles (`compile.log`), runs `check_build.py`. Output `build/quartus/output_files/ap_core.rbf`.

### Package

```text
python -B scripts/package.py --version <version> --date <YYYY-MM-DD> [--build build/quartus] [--assets build/assets] [--output build/package]
```

Writes `build/package/sd/` and `build/package/BarabashkaD.Radio86RK_<version>_<date>.zip`: `Cores/BarabashkaD.Radio86RK/` (bitstream, json, `info.txt`, icon, licences, `APF-NOTICE.txt`), `Assets/radio86rk/BarabashkaD.Radio86RK/` (the three assets, `romdisk-1.bin` .. `romdisk-9.bin`, `romdisks.txt`), `Platforms/` (`radio86rk.json`, `_images/radio86rk.bin`). Without a Quartus build: `pwsh -File scripts/ci/package-dry-run.ps1` (into `build/ci-local/tmp/`; never publish that zip).

### CI (GitHub Actions)

- `checks.yml` (PR to `main`, push to `main`, on demand; Ubuntu, PowerShell steps; job names are the ruleset's status checks, a rename needs the ruleset changed):
  - `Python tests and package checks`: `check_repo.py`, `fetch_assets.py`, `unit-tests.ps1`, `package-dry-run.ps1`;
  - `Unit simulations and faults`: `run_sim.py --negative`;
  - `K1 panel scenario`: `system_k1_panel` and `check_frames.py --expect 3`;
  - `Core machine TB subset`: `run_sim.py --negative cpu16` (the CPU test program on `rk86_machine16` with `pocket_memory`).
- `weekly.yml` (Mondays 03:17 UTC, on demand), one job per runner: `boot`, `powerup`, `nocart`, `reset`, `relock`, `system_watchdog`, `keytap`, `k1` (`check_frames.py --expect 7`); `run_core_machine.py`; the fork's `run_machine16_sim.py --negative <test>`, one job per test (`machine16` with its faults in one job). Re-enable it in the Actions tab after 60 days without activity.
- Time limits (minutes): 2-3 times the remote times above (a GitHub runner's Icarus is that much slower), plus the setup; GitHub stops any job at 360.
  - `checks.yml`: Python 30, unit simulations 60, K1 panel 45, core machine subset (`cpu16`) 60.
  - `weekly.yml`: `boot` 150, `powerup` 120, `nocart` 90, `reset` 240, `relock` 180, `system_watchdog` 150, `keytap` 210, `k1` 340; `run_core_machine.py` 240; fork unit TBs 330 each, `machine16` with its faults 360 (it may reach the cap until the fork runner can run its faults in groups).
- Icarus Verilog 13.0 is built from source (`v13_0`) by `.github/actions/setup-iverilog` and cached.
- Failure artifacts: 7 days, without `cartridge.hex`, `monitor.hex`, `bios.hex`, `font.hex`, `*.vvp`.
- Not in CI: the ROM disk scenarios, the Quartus build, the hardware test.
- `check_repo.py` exempts `fpga/apf/`, `fpga/core/` from the LF rule; `LEGACY` lists today's line-ending exceptions (normalising them is a separate, approved change).

### Install on a Pocket

Unzip the package onto the SD card root; the core appears as "Radio-86RK". Upgrading from 0.5.x: delete `Settings/BarabashkaD.Radio86RK/` first.

## 7. Features (0.8.1)

- `rk86_machine16`: `ce16` on 64 of 297 `clk_74a` ticks (16 MHz timebase); CPU 1.778 MHz (Vslav's 8080); 8257 on Φ2; 8 MHz dots; 516 x 310 raster at 50 Hz; one DMA HOLD period per character.
- The board's address map and DMA wiring, reproduced (`fpga/README.md`, The 16 MHz machine): one device per 8 KB block (A15-A13), each 8255's 4 registers repeating every 4 bytes; the 8257 on channel 2 only, memory to the 8275, MEMR not connected; DMA reads decoded like CPU reads.
- Monitor and font from data slots, as they are: monitor at 8000-87FF of the memory array (read at E000-FFFF), font in its own memory.
- ROM disk on the ports of the second 8255, the A000-BFFF block (optional, every ROM disk byte reads FF when absent; up to 32768 bytes), reloadable from the core's menu with the RAM kept; menu via `R0,1FF,0`, `G0`. Nine game disks in the package.
- K1 on-screen keyboard (L+R): 67 keys, labels from the monitor's decoder, LAT/RUS, Shift latch (L tap), Ctrl (L held), RUS/LAT (R); palettes Pink, Grey, Mono.
- Buttons with the panel closed: Keys (Cursor, Digits 7-8-9-6, Digits 8-4-6-2, WASD), Keys on (D-pad, A B X Y), Escape (Select, Start, None).
- Core Settings: Reset (RAM kept), Cold boot (RAM cleared), Sound, Text colour, Keyboard colours.
- Video: 408 x 300 display window, 60 Hz output, about 25 picture updates per second. Sound: INTE only, 48 kHz I2S.
- PLL watchdog: on lock loss only picture and sound stop.
- Status registers: `fpga/README.md`, Bridge map.

## 8. Limits and known issues

- Hardware: 0.8.0 run on a Pocket by the maintainer (2026-11-11), Tetris included; 0.6.1-0.7.1 on OS 2.7. Nothing else is hardware-verified.
- Not limits (the original's design, reproduced; do not list them here): the fixed address map (one device per 8 KB block, registers repeating) and the 8257 wiring (channel 2 only, memory to the 8275 only, MEMR not connected).
- No savestates, no sleep, no tape (`tape_in` high; slot 3 reserved), Dock USB keyboard unused. Interact 0x11C-0x144 reserved.
- Programs are expected to run slower than in MAME or Emu80 (one HOLD period per character, as the data sheets give it); no real-chip measurement is known.
- About 25 picture updates per second (two frame banks at 60 Hz starts).
- The display window shows text columns 6-73 of 78 (`X0` = 42). Golden frames come from the earlier proof of concept, compared by content with the cursor cell masked.
- 8275 open points: listed in the fork's `src/rtl/rk86_16/README.md` and file headers (SILENT items).
- As on the board, the 8275 has no reset pin and the clock dividers run freely; the system TB sets power-up values via `power_up.vh`; `powerup` randomises CRT and DMA registers.
- The board's analogue video mixer and the monitor CRT are not reproduced: the machine ends at dots, HRTC, VRTC.
- ROM disk distribution undecided (provenance of the programs); `package.py` packs what `assets.json` lists. `updaters.json`: `declare_ai` only (`license` would make updaters ask for a licence file).
- With the panel open the prompt stays under it (CLS clears). A latched Shift is not shown with the panel closed.
- `pocket_keyboard` holds a key at least `MIN_HOLD_MS` (80 ms): two presses closer than that may merge.
- Some ROM disk programs overwrite the menu loader (Xonix at 0000, DP/DDT at 6400): Reset, then `R0,1FF,0`, `G0`.
- The `k1_panel` unit test draws over the red frame of `pocket_frame_video`, which the core does not drive.
- Follow-up: `tetris` stays skipped; its D-pad check is vacuous on the full 8255 and the D-pad mapping is to be reviewed by the maintainer.
- Follow-up: `reset` does not compare the picture after Reset and Cold boot with `golden/monitor-boot.hex` (the 8275 keeps running through the machine reset).
- Follow-up: `powerup` uses Icarus' fixed `$random` sequence (one state, no `+seed`) and randomises only the 8275 parameters and the 8257 address and count.
- Follow-up: 64 KB game disks. A second ROM disk wiring (PC7 = ROM A15, the ROM always enabled: all 24 port lines, 16 address + 8 data) in `pocket_cart_ppi` / `pocket_rom8`, chosen per image; the game disks rebuilt for 64 KB (fewer, larger disks; the loader's table and menu above 8000h). The monitor's `R` (FA68) and the loader's code already take 16-bit ROM addresses. Kiselev's `romdisk.bin` stays a 32 KB image with his wiring (PC7 = ROM enable).
- Follow-up: an 8 MB ROM card for the second 8255 (a bank latch loaded from port B on a PC7 edge: 256 banks of 32 KB, ROM A15-A22), for real boards and as a Pocket emulation mode with the image in external memory; a bank-aware loader that reuses the monitor's `R` (FA68) inside a bank.

# AGENTS.md

Instructions for AI coding agents working in this repository. Human-facing documentation: `README.md` (users), `fpga/README.md` (FPGA design, bridge map, data slots, build and tests), `LICENSES.md`, `CHANGELOG.md`.

## 1. What this repository is

An openFPGA core of the Radio-86RK home computer (KR580VM80A, an i8080 clone) for the Analogue Pocket.

- openFPGA identity (`package/core/core.json`, `package/platform/radio86rk.json`, `scripts/package.py`):
  - author `BarabashkaD`, shortname `Radio86RK`, core id `BarabashkaD.Radio86RK`;
  - platform id `radio86rk` ("Radio-86RK", category Computer);
  - one bitstream `bitstream.rbf_r`; dock supported, no analog output, no sleep.
- The machine itself (CPU, DMA, CRT controller, PPI, address decoding, native video) is the board-neutral part of the Karabas core (`rk86_machine`, `rk86_video`, `rk86_video_stream`), used unchanged from a submodule. This repo adds the Pocket board around it: clocking, memory, asset loading, the ROM disk device, the buttons and the K1 on-screen keyboard, frame buffer, audio, Core Settings.
- Device: Cyclone V `5CEBA4F23C8`; toolchain Quartus Prime Lite 25.1std.

Layout:

| Path | Content |
|---|---|
| repo root | Pocket package docs: `README.md`, `CHANGELOG.md`, `LICENSE` (BSD-3-Clause), `LICENSES.md` |
| `fpga/` | the self-contained FPGA implementation (RTL, APF template, Quartus project, simulation); see section 5 |
| `cores/karabas-go-core-rk86/` | git submodule: the Karabas core (machine sources, monitor ROM, font, its own testbenches) |
| `package/` | SD package definitions (`core/*.json`, `core/info.txt`, `platform/radio86rk.json`) and the asset table `assets.json` |
| `scripts/` | build, build check, asset fetch, packaging, K1 key-table tools (`scripts/k1/`), Python unit tests (`scripts/tests/`) |
| `images/` | README screenshots |
| `build/` | all generated output (ignored by git) |

## 2. Dependencies

- **Karabas core submodule** `cores/karabas-go-core-rk86`, URL `https://github.com/BarabashkaD/karabas-go-core-rk86` (`.gitmodules`), pinned at `c7d7a9288f1fb14e515572e972af3dec34cc5b53` (core PR14, `pocket-base-c7d7a92`).
  - Read only through `RK86_CORE_DIR`, the core's `src` directory; default `cores/karabas-go-core-rk86/src`. Used by `fpga/quartus/create_project.tcl`, `fpga/sim/run_sim.py` and `scripts/package.py`.
  - The machine source list is the core's `src/rk86_machine.prj`; the Quartus project and the system TB read it, nothing is copied.
  - The integration rules (clock enable, reset, power-up values, `cpu_ready`, DMA window, keyboard, video) are in the core's `docs/integration.md`; read it before touching `radio86rk_pocket.v` or `pocket_memory.v`.
  - The negative-test helper `src/sim/negative.py` of the core is imported by `run_sim.py --negative`.
- **APF template**: `fpga/apf/`, `fpga/core/` from open-fpga/core-template `da3a021` with the Analogue notices (`fpga/apf/TEMPLATE-NOTICES.md`).
- **Assets** (data slots, `package/core/data.json`; sizes, CRC32, SHA256 and sources in `package/assets.json`):

| Slot | File | Size | Source | Required |
|---|---|---|---|---|
| 0 | `monitor.bin` | 2048 | core `src/roms/BIOS.BIN` (stock monitor) | yes |
| 1 | `font.bin` | 1024 | core `src/roms/FONT.BIN` | yes |
| 2 | `romdisk.bin` | 32256 | skiselev/radio-86rk `Software/rom_disk.bin` at commit `c5e9cb7` | no (but a present file must have the pinned CRC) |

  - `scripts/fetch_assets.py` downloads the ROM disk and its GPL-3.0 licence into `build/assets` and checks size, CRC32 and SHA256. The ROM disk is never committed.
  - The font is also compiled into the bitstream as `fpga/rtl/native_font.vh` (the K1 panel draws with it, not with slot 1).
- **Licences**: `LICENSES.md` (one row per part). Our code is BSD-3-Clause; the core is modified BSD; template files keep the Analogue notices; the ROM disk is GPL-3.0 with unestablished provenance of the programs inside.

## 3. Prerequisites

- Quartus Prime Lite **25.1std** exactly (`scripts/build.ps1` refuses other versions). `QUARTUS_ROOT` = the `quartus` directory, or `quartus_sh` on PATH. The script calls `bin64\quartus_sh.exe` (Windows layout).
- Icarus Verilog 13 (`iverilog` and `vvp` in the same directory): `IVERILOG`, `--iverilog PATH`, or on PATH.
- Python 3 (standard library only), PowerShell 7 (`pwsh`), git (negative tests use `git apply`).
- Network access once for `scripts/fetch_assets.py`.
- Clone with submodules:

```text
git clone --recursive <repo url>
git submodule update --init --recursive      # in an existing clone
```

Environment variables: `QUARTUS_ROOT`, `IVERILOG`, `RK86_CORE_DIR` (optional override of the core `src` directory).

## 4. Development process rules

- **Karabas core**: never copy or patch the core sources; read them only through `RK86_CORE_DIR`. A core change is made in the core repository and comes in by moving the submodule pin (`git -C cores/karabas-go-core-rk86 checkout <sha>`, then `git add cores/karabas-go-core-rk86`). When the pin moves, update the links to the core docs at the pinned commit in `fpga/README.md`. Changing the CPU divider or anything in `rk86_machine` also changes the Karabas boards, so it needs the core's own proofs.
- **Deliberate test faults** are unified-diff `.patch` files (made with `git diff`, paths relative to the repo root) under `fpga/sim/negative/`, applied to copies under `build/sim` with `git apply` by `run_sim.py`. Never edit sources with text-replacement scripts. A patch must apply exactly: when its target file changes, regenerate the patch.
- **Generated K1 table**: `fpga/rtl/pocket_k1_layout.vh` is generated; do not edit it. Edit `scripts/k1/layout.py` and regenerate with `python -B scripts/k1/gen_verilog.py`. `scripts/tests/test_k1_layout.py` fails when the file is out of date.
- **Core Settings size**: keep `package/core/interact.json` small. Pocket OS 2.7 refuses to start a core whose list options total 97 or more (66 load); `scripts/package.py` enforces at most 20 list options and at most 16 items, ids unique and not 0-2. An interact change must stay in sync with `fpga/rtl/pocket_interact.v` (addresses 0x100-0x118, range checks), the expected names in `scripts/tests/test_package.py`, the bridge map in `fpga/README.md`, and `package/core/info.txt` / `README.md` controls.
- **Toolchain**: Quartus Prime Lite 25.1std is pinned; device 5CEBA4F23C8. Keep our logic out of the APF template files (`fpga/apf/`, `fpga/core/`) beyond instances and wiring: `core_top.v` instantiates one `pocket_system`, everything else lives in `fpga/rtl/`.
- **Files**: LF line endings with a final newline. `.gitattributes` is `* -text`: files are kept byte for byte (patches, Quartus and iverilog read them as is), so git will not fix line endings for you.
- **Outputs**: build, simulation, asset and package outputs go to `build/` (ignored). Do not commit bitstreams, assets or zips.
- **Verification claims**: simulation and build results are not hardware verification. The hardware test on a Pocket is done by the maintainer; never report a feature as working on hardware from simulation.
- **Git**: commit or push only when the maintainer asks; never rewrite published history.
- **Releases and the openFPGA library**: once the core is listed in the openFPGA library, the library's updater picks up every GitHub release with a `.zip` asset within about 30 minutes (it ignores the pre-release flag) and the updater tools offer it to users. Create releases as drafts, check them, then publish; never publish a test build as a release. The updater finds a core's files by `author.shortname` from core.json, and a bad `date_release` or an empty `platform_ids` breaks the library's shared update job, so `package.py` checks both before it writes PASS.
- **Privacy and portability**: no environment-specific values in committed files (no absolute local paths, host or user names, emails); paths relative to the repo or from env vars. The scripts already resolve paths from their own location.
- **Change checklist** (from the existing tests): RTL change -> the unit TB of the module, its negatives, then the slow system scenarios that cover it, then a Quartus build with `check_build.py`. Package change -> `test_package.py` and a `package.py` run.

## 5. Sources

### `fpga/rtl/` (our logic, BSD-3-Clause)

| File | Role (from its header) |
|---|---|
| `pocket_system.v` | everything behind the APF template: asset stores, interact registers, the board, frame banks, audio, PLL watchdog, resets; status registers (identity `0x524B4D31`) |
| `radio86rk_pocket.v` | the Radio-86RK board around `rk86_machine`, `rk86_video`, `rk86_video_stream`, one clock domain `clk_74a` |
| `pocket_memory.v` | RAM 0000-7FFF in block RAM: CPU port with address tag, DMA read port with write forwarding, monitor port, `cpu_ready` by region |
| `pocket_cold_clear.v` | clears the 32 KB RAM through the loader port at the first boot and on Cold boot |
| `pocket_boot_assets.v` | APF data-slot loading of monitor, font, ROM disk; size and CRC checks; asset status |
| `pocket_asset_store.v` | addressed word store / validator used by the asset loader |
| `pocket_cart_ppi.v` | mode-0 8255 subset in A000-BFFF serving the ROM disk |
| `pocket_keyboard.v` | the buttons as keyboard lines (64 matrix lines + SS, US, RUS), K1 panel state, Shift latch; timings as ms parameters |
| `pocket_remap.v` | button-to-key map from Keys, Keys on and Escape settings |
| `pocket_k1_panel.v` | draws the 284 x 82 K1 panel in the 12.288 MHz output stage, 3-stage pipeline |
| `pocket_k1_layout.vh` | generated key table, labels, small glyphs, palettes (do not edit) |
| `pocket_bus_cdc.v` | toggle-handshake crossing of the 78-bit panel state, `clk_74a` to the video clock |
| `pocket_window.v` | the 408 x 300 window of the native dot stream with its own frame markers |
| `pocket_frame_video.v` | dual-clock ping-pong frame banks, 60 Hz output, K1 panel overlay, red diagnostic frame |
| `pocket_audio.v` | Karabas beeper (`pc0 ^ inte`) to 48 kHz signed 16-bit I2S with a DC blocker |
| `pocket_interact.v` | Core Settings registers 0x100-0x144; no reset, defaults from `interact.json` |
| `pocket_pll_watchdog.v` | restarts the video/audio PLL after 2^21 clk (28 ms) without lock |
| `native_font.vh` | the font as Verilog functions (6 x 8) |
| `pocket_key_defs.vh` | test model only (`native_character`, the monitor's FF06 decoder); no RTL includes it |
| `pocket_machine_cdc.sdc`, `pocket_audio_cdc.sdc`, `pocket_bus_cdc.sdc` | CDC constraints; they cut only first synchronizer stages and fail loudly if register names change |

### Other `fpga/` directories

- `fpga/core/`: `core_top.v` (APF template top: pins, bridge mux, PLL, one `pocket_system`), `core_bridge_cmd.v`, `mf_pllbase*` (the 12.288 MHz PLL), `core_constraints.sdc`.
- `fpga/apf/`: unchanged APF template files and `TEMPLATE-NOTICES.md`.
- `fpga/quartus/`: `ap_core.qsf` (device, pins), `create_project.tcl` (creates `ap_core` in a build directory, adds `fpga/rtl/*.v` and the core's `rk86_machine.prj` sources, sets `VERILOG_CONSTANT_LOOP_LIMIT 40000`), `report_pocket_machine_cdc.tcl`, `report_pocket_audio_cdc.tcl`, `report_pocket_timing.tcl` (report-only, run with `quartus_sta -t` inside a build directory).
- `fpga/sim/`:
  - `run_sim.py`: the test runner (section 6); `frame_compare.py`: compares a 1-bit 408 x 300 frame with a golden frame, allowing one character cell (the cursor).
  - `run_core_machine.py`: the CI subset of the core's machine TB on `pocket_memory` (imports the core runner in place).
  - `unit/`: one TB per module (`tb_assets`, `tb_bus_cdc`, `tb_cart_ppi`, `tb_cold_clear`, `tb_frame_colour`, `tb_frame_video`, `tb_k1_panel`, `tb_native_audio`, `tb_pll_watchdog`, `tb_pocket_interact`, `tb_pocket_keyboard`, `tb_pocket_memory`, `tb_pocket_window`).
  - `system/`: `tb_system.v` (`pocket_system` with a PLL stub; scenarios via `+scenario=`) and `power_up.vh` (power-up values of the machine and video).
  - `memory/tb_rk86_mem.v`: `pocket_memory` as the memory model of the core's machine TB.
  - `negative/`: fault `.patch` files, each with the error text it must produce (listed in `run_sim.py`).
  - `golden/`: POC reference frames `monitor-boot.hex`, `rom-disk-menu.hex` with their SHA256 in `golden/README.md`.

### `scripts/`

| File | Use |
|---|---|
| `build.ps1` | Quartus build into `build/quartus` (`-BuildDir`, `-QuartusRoot`), then `check_build.py` |
| `check_build.py` | build gate: full compilation with 0 errors, no critical warning, 5 slack kinds non-negative in all 4 corners, `ap_core.rbf` present |
| `fetch_assets.py` | fetch and check the ROM disk and its licence (`--record-licence` records an empty licence SHA256 once) |
| `package.py` | SD package and zip from a Quartus build; checks openFPGA field limits and the interact limit; bit-reverses the RBF; draws icon and platform image |
| `k1/layout.py` | single source of the K1 key table, labels, navigation and the golden panel model `render_panel` |
| `k1/gen_verilog.py` | writes `fpga/rtl/pocket_k1_layout.vh` (`--out PATH`) |
| `k1/monitor_decoder.py` | runs the monitor's keyboard decoder (FE72) from `BIOS.BIN` in a minimal 8080 model; prints the 64 x 8 table |
| `k1/render.py` | renders the panel model to PNG, frames to GIF |
| `k1/check_frames.py` | compares the panels captured by the `k1` system scenario with the model |
| `check_repo.py` | repository rules on the tracked files: LF, final newline, no links into `docs/`, no absolute local paths (`EXEMPT_PREFIXES`, `LEGACY`: the line-ending exceptions) |
| `ci/unit-tests.ps1` | the Python unit tests as in CI; a skipped test fails |
| `ci/package-dry-run.ps1` | `package.py` with a stand-in bitstream in a temp folder, as in CI |
| `tests/test_package.py` | packaging and definition limits |
| `tests/test_k1_layout.py` | key table, decoder, generated file up to date, Verilog functions vs model (needs iverilog) |
| `tests/test_check_repo.py` | its tests; fails while a fixed file is still in `LEGACY` |
| `tests/test_core_machine_subset.py` | the CI machine subset still matches the pinned core runner |

### `package/`

`core/core.json` (version and date are filled in by `package.py`), `data.json` (slots), `interact.json` (Core Settings), `input.json`, `video.json` (408 x 300, 34:25), `audio.json`, `variants.json`, `updaters.json` (`declare_ai`, for the openFPGA library), `info.txt` (shown on the Pocket), `platform/radio86rk.json`, `assets.json`.

## 6. Build, test, run

All commands from the repo root. Python scripts run with `-B` (no `__pycache__`).

### Assets (needed by most tests and the package)

```text
python -B scripts/fetch_assets.py
```

The `assets` unit test and every system scenario read `build/assets/romdisk.bin`.

### Simulation (`fpga/sim/run_sim.py`, outputs in `build/sim/<test>/`)

```text
python -B fpga/sim/run_sim.py                      every test that is not slow (the unit TBs)
python -B fpga/sim/run_sim.py --negative           also each fault: it must fail with its named error
python -B fpga/sim/run_sim.py --slow               adds the system scenarios (slow)
python -B fpga/sim/run_sim.py boot menu            named tests only
python -B fpga/sim/run_sim.py --iverilog PATH ...  when iverilog is not on PATH and IVERILOG is unset
```

- Unit tests: `cart_ppi`, `audio`, `bus_cdc`, `keyboard`, `frame_video`, `frame_colour`, `k1_panel`, `assets`, `memory`, `cold_clear`, `window`, `interact`, `watchdog`. Fast.
- System scenarios (slow, `tb_system`): `boot`, `powerup` (both compared with `golden/monitor-boot.hex`), `nocart`, `reset`, `relock`, `system_watchdog`, `menu` (compared with `golden/rom-disk-menu.hex`), `xonix`, `dpddt`, `tetris`, `k1`, `system_k1_panel` (scenario `k1_panel`; CI: the panel without the monitor, 3 captures, about 11 min; check with `python -B scripts/k1/check_frames.py build/sim/system_k1_panel --expect 3`). `k1` takes about 40 minutes; check its captures with:

```text
python -B scripts/k1/check_frames.py build/sim/k1
```

- Pass rule: `vvp` exits 0, prints a `PASS` line, no `ERROR`/`FATAL` line, and the frame compare passes where configured.

### Core machine TB on the Pocket memory

```text
python -B cores/karabas-go-core-rk86/src/sim/machine/run_machine_sim.py [--iverilog PATH] --mem fpga/sim/memory/tb_rk86_mem.v fpga/rtl/pocket_memory.v
```

The CI subset: `python -B fpga/sim/run_core_machine.py` (4 of the 6 runs, about 7 min). Both write into the core's ignored `build/sim/machine/`.

### Python unit tests and the K1 generator

```text
python -B -m unittest scripts/tests/test_package.py
python -B -m unittest scripts/tests/test_k1_layout.py     (Verilog part needs IVERILOG or iverilog on PATH)
pwsh -File scripts/ci/unit-tests.ps1                     all Python unit tests as in CI (a skipped test fails)
python -B scripts/check_repo.py                          repository rules on the tracked files
python -B scripts/k1/gen_verilog.py                       regenerate fpga/rtl/pocket_k1_layout.vh
python -B scripts/k1/monitor_decoder.py                   print the decoder table
```

### Quartus build (slow: several minutes)

```text
pwsh -File scripts/build.ps1 [-BuildDir <dir>] [-QuartusRoot <quartus dir>]
python -B scripts/check_build.py build/quartus
```

`build.ps1` deletes and recreates the build directory, runs `create_project.tcl`, compiles (`compile.log` in the build dir), then runs `check_build.py`. Output: `build/quartus/output_files/ap_core.rbf`. Optional CDC/timing reports: `quartus_sta -t <repo>/fpga/quartus/report_pocket_*.tcl` inside the build directory.

### Package

```text
python -B scripts/fetch_assets.py
python -B scripts/package.py --version <version> --date <YYYY-MM-DD> [--build build/quartus] [--assets build/assets] [--output build/package]
```

Writes `build/package/sd/` and `build/package/BarabashkaD.Radio86RK_<version>_<date>.zip` with `Cores/BarabashkaD.Radio86RK/` (bitstream, json incl. `updaters.json`, `info.txt`, icon, licences, `APF-NOTICE.txt`), `Assets/radio86rk/BarabashkaD.Radio86RK/` (the three assets) and `Platforms/` (`radio86rk.json`, `_images/radio86rk.bin`). Every asset is checked against `assets.json`. Then the zip is checked as the openFPGA library's updater reads it (`check_library_zip`).

Without a Quartus build: `pwsh -File scripts/ci/package-dry-run.ps1` (a stand-in bitstream into `build/ci-local/tmp/`, as in CI; never publish that zip).

### CI (GitHub Actions)

- `.github/workflows/checks.yml`, on every PR to `main`, every push to `main` and on demand, 4 jobs on Ubuntu runners with PowerShell steps (a new push to a PR cancels that PR's running checks):
  - `python`: `scripts/check_repo.py` (LF, final newline, no links into `docs/`, no absolute local paths), `scripts/ci/unit-tests.ps1` (the Python unit tests; a skipped test fails the job), `fetch_assets.py`, and `scripts/ci/package-dry-run.ps1` (`package.py` with a 256-byte stand-in `ap_core.rbf` into the runner's temp folder: definitions, assets, zip layout, openFPGA library rules; the zip is not uploaded);
  - `sim-unit`: `run_sim.py --negative` (the unit TBs, then each fault must fail with its own error);
  - `k1-panel`: `run_sim.py system_k1_panel` and `check_frames.py build/sim/system_k1_panel --expect 3` (the panel without the monitor, palettes 0, 1, 2; about 11 min);
  - `core-machine`: `fpga/sim/run_core_machine.py` (the core runner's g, stall, stall_realign, stall_frac on `pocket_memory`; about 7 min).
- The job names `Python tests and package checks`, `Unit simulations and faults`, `K1 panel scenario`, `Core machine TB subset` are the status check names a branch ruleset refers to; renaming a job needs the ruleset changed too.
- `.github/workflows/weekly.yml`, Mondays 03:17 UTC and on demand (the schedule runs from `main`; manual runs work once the file is on `main`, for any branch that has it): the system scenarios `boot`, `powerup`, `nocart`, `reset`, `relock`, `system_watchdog`, `k1` (with `check_frames.py --expect 7`), one per runner, and the full `run_machine_sim.py --mem` command. GitHub pauses scheduled workflows in a public repository after 60 days without activity; re-enable `weekly` in the Actions tab.
- Icarus Verilog 13.0 is built from source (tag `v13_0`, checked against its commit) by `.github/actions/setup-iverilog` and cached.
- On failure a job uploads its output folder for 7 days, without `cartridge.hex` (the ROM disk), `monitor.hex`, `font.hex` and `*.vvp`.
- The machine runs (`run_core_machine.py`, `run_machine_sim.py --mem`) write into the core submodule's ignored `build/sim/machine/`, an exception to "outputs go to `build/`" (section 4): the core runner sets that folder.
- `scripts/check_repo.py` exempts the APF template (`fpga/apf/`, `fpga/core/`) from the LF rule and lists in `LEGACY` the files that have a CR or no final newline today; normalising them is a separate change the maintainer approves (it touches RTL and the fault patch `rom_disk_required.patch`), and that change removes their entries.
- Not in CI: the ROM disk scenarios (`menu`, `xonix`, `dpddt`, `tetris`: 1-2 h each), the Quartus build, the hardware test.
- Every step runs locally in PowerShell from the repo root with the same commands and scripts (iverilog on PATH or `IVERILOG` set; the core's `run_machine_sim.py`, the weekly full machine command, reads only PATH or `--iverilog`, not `IVERILOG`; without `RUNNER_TEMP` the dry run works in `build/ci-local/tmp/`).

### Install on a Pocket

Unzip the package onto the root of the Pocket's SD card. The core appears as "Radio-86RK". Monitor and font are required in the Assets folder; the ROM disk is optional, but another image than the pinned one is an asset error (red frame, CPU held). Upgrading from 0.5.x: delete `Settings/BarabashkaD.Radio86RK/` first. Hardware runs are the maintainer's.

## 7. Features (0.6.2)

- The Karabas core's Radio-86RK machine at the Karabas speed: `clk_74a` (74.25 MHz) with a clock enable on 160 of 297 ticks = 40 MHz average timebase; CPU about 1.43 MHz (40 / 28).
- Monitor and font from data slots, checked by size and CRC32; a bad or missing one holds the CPU in reset and shows a red diagnostic frame.
- ROM disk behind an 8255 in A000-BFFF (optional; absent: reads FF; a wrong CRC is an asset error). Menu via `R0,1FF,0` and `G0`.
- K1 on-screen keyboard (L+R): the 67 real keys, one label per key from the monitor's own decoder, LAT/RUS, Shift latch (L tap), Ctrl (L held), RUS/LAT (R), palettes Pink (v1.1), Grey (v1.4), Mono.
- Button presets with the panel closed: Keys (Cursor, Digits 7-8-9-6, Digits 8-4-6-2, WASD), Keys on (D-pad or A B X Y), Escape (Select, Start, None).
- Core Settings: Reset (RAM kept), Cold boot (RAM cleared), Sound, Text colour (white/green), Keyboard colours.
- Video 408 x 300 at 60 Hz through two frame banks (native frames 41.7 Hz); beeper at 48 kHz I2S.
- PLL watchdog: on lock loss only picture and sound stop; the machine keeps running.
- Status registers on the bridge (identity, flags, asset status, CRCs, CPU address, frame count, panel and keyboard state): `fpga/README.md`, Bridge map.

## 8. Restrictions, known issues, limitations

- 0.6.1 was the first release (0.5.1 and 0.6.0 were pre-releases, `CHANGELOG.md`); 0.6.2 is the same core with new artwork. The maintainer ran both on a Pocket with OS 2.7. Hardware behaviour beyond the maintainer's runs is unverified.
- No savestates (Memories), no sleep (`sleep_supported: false`).
- CPU at about 1.43 MHz, about 20% slower than the original's ~1.78 MHz. The divider is in the Karabas core, so a speed change is a core change that also affects the Karabas boards.
- No tape: `tape_in` is tied high; data slot 3 (0x2300_0000) is reserved for tape images. The Dock USB keyboard is recognized but not used (the second matrix input is tied off). Interact registers 0x11C-0x144 are reserved.
- Pocket OS 2.7 limit on interact list options (section 4; the measurements are in `fpga/README.md`, "Core Settings size limit"); larger menus fail to start the core.
- The ROM disk's public distribution is undecided (programs' provenance not established); `package.py` packs whatever `assets.json` lists. `package/core/updaters.json` declares the AI tool (`declare_ai`); `package.py` allows no other key (`license` would make updaters ask for a licence file).
- With the panel open the prompt stays on the bottom row under the panel (CLS, СТР in RUS, clears the screen). A latched Shift is not shown while the panel is closed.
- `pocket_keyboard` holds a key at least `MIN_HOLD_MS` (80 ms): two B presses closer than that may merge into one.
- The panel can be drawn over the red error frame in simulation; on hardware the keyboard is enabled only with valid assets and ready memory (`radio86rk_pocket.v`), so after an asset error the panel stays closed.
- Some ROM disk programs overwrite the menu loader, as on the real machine: Xonix runs at 0000 (system scenario `xonix`), DP/DDT loads at 6400 and overwrites it too (`package/core/info.txt`). Use Reset, then `R0,1FF,0`, `G0` again.
- From the core (its `docs/integration.md`, Known limits): the DMA, CRT and PPI implement only what the Radio-86RK uses; the CRT and `rk86_video` have no reset and rely on INIT/power-up values (the system TB sets them via `power_up.vh`); field attributes make the picture drift; columns 75-77 of a row are not shown.
- `scripts/build.ps1` expects the Windows Quartus layout (`bin64\quartus_sh.exe`).
- The golden frames come from the earlier proof of concept and are compared by content (one character cell may differ), not by frame number.

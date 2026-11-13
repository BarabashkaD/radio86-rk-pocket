# AGENTS.md

Instructions for coding agents. User docs: `README.md`. Design, bridge map, data slots: `fpga/README.md`. The real J6 bank card (reference only): `hardware/j6-bank-card.md`. Also `LICENSES.md`, `CHANGELOG.md`.

## 1. Repository

openFPGA core of the Radio-86RK (KR580VM80A, an i8080 clone) for the Analogue Pocket. Latest release 0.8.2 (2026-11-11); the unreleased features since then: section 7.

- Identity (`package/core/core.json`, `package/platform/radio86rk.json`, `scripts/package.py`): author `BarabashkaD`, shortname `Radio86RK`, core id `BarabashkaD.Radio86RK`; platform `radio86rk` ("Radio-86RK", category Computer); one bitstream `bitstream.rbf_r`; dock yes, analog output no, sleep no.
- Machine: `rk86_machine16` from the submodule, used unchanged: the original's 16 MHz timing, each chip (8224 and К155ИЕ4 clocks, 8080, 8257, 8275, 8255, video path, board glue) to its data sheet. Where the data sheets are silent, the decisions and planned real-hardware checks are in the fork's `src/rtl/rk86_16/README.md`.
- This repo: the Pocket board around the machine (clock enable, memory, slot loading, the ROM disk in the PSRAM, the A000-BFFF block (second 8255) with the ROM disk cards, buttons, K1 on-screen keyboard, raster, display window, frame buffer, audio, Core Settings), and the software of the card images (J6 card menu, FAT16 card).
- Device Cyclone V `5CEBA4F23C8`; Quartus Prime Lite 25.1std.

| Path | Content |
|---|---|
| root | `README.md`, `CHANGELOG.md`, `LICENSE` (BSD-3-Clause), `LICENSES.md`, `AGENTS.md` |
| `fpga/` | RTL, APF template, Quartus project, simulation (section 5) |
| `cores/karabas-go-core-rk86/` | submodule: the fork with the machine, monitor, font, game tapes, its tests |
| `package/` | SD package definitions, `assets.json`, `romdisks.txt` template |
| `scripts/` | build, checks, assets, packaging, K1 tools, ROM disk and card tools, FAT16 card tools, remote simulation, Python tests |
| `images/` | README pictures |
| `hardware/` | `j6-bank-card.md`: reference design of a real J6 bank card (never built or tested) |
| `build/` | all generated output (ignored) |

## 2. Dependencies

- **Submodule** `cores/karabas-go-core-rk86`: `https://github.com/BarabashkaD/karabas-go-core-rk86` (fork of andykarpov/karabas-go-core-rk86), branch `rk86-16mhz`; the pin: `git ls-tree HEAD cores/karabas-go-core-rk86`.
  - Read only through `RK86_CORE_DIR` (the fork's `src`; default `cores/karabas-go-core-rk86/src`) by `fpga/quartus/create_project.tcl`, `fpga/sim/run_sim.py`, `fpga/sim/run_core_machine.py`, `scripts/package.py`. Exception, to be fixed: `scripts/romdisk/build_romdisks.py` and `scripts/fatcard/fatcard.py` default `--pk` to the submodule's `pk/` (not through `RK86_CORE_DIR`); `test_romdisk.py` and `test_fatcard.py` read the same path.
  - Used from it, nothing else: `src/rtl/rk86_16/`; `src/rk86_machine16.prj` (source list: `k580vm80a.v`, `rk86_clocks16.v`, `k580vv55.v`, `k580vt57.v`, `k580vg75.v`, `rk86_video16.v`, `rk86_machine16.v`); `src/sim/machine16/` (runner, `cpu_power_up.vh`, `tb_rk86_mem16.v`); `src/sim/negative.py`; `src/roms/BIOS.BIN`, `src/roms/FONT.BIN`; `pk/` (game tapes). `cart_ppi` takes only `k580vv55.v`.
  - Before touching `radio86rk_pocket.v`, `pocket_memory.v`, `pocket_cart_ppi.v` or `pocket_raster.v`: read the fork's `src/rtl/rk86_16/README.md`, the file headers, the header of `rk86_machine16.v` (ports, glue). The fork's `docs/integration.md` describes the Karabas `rk86_machine`, not this core.
  - Planned: the chip models and the machine move out of the Karabas fork into their own repositories.
- **APF template**: `fpga/apf/`, `fpga/core/` from open-fpga/core-template `da3a021`, with the Analogue notices (`fpga/apf/TEMPLATE-NOTICES.md`).
- **Assets** (`package/core/data.json`; size, CRC32, SHA256, source in `package/assets.json`):

| Slot | File | Size | Source | Required |
|---|---|---|---|---|
| 0 | `monitor.bin` | 2048 | fork `src/roms/BIOS.BIN` | yes |
| 1 | `font.bin` | 1024 | fork `src/roms/FONT.BIN` | yes |
| 2 | `romdisk.bin` | 32256 | skiselev/radio-86rk `Software/rom_disk.bin` at `c5e9cb7` | no (any image up to 8388608 bytes; up to 32768 a 32 KB ROM (8000-FFFF mirror 0000-7FFF), up to 65536 a 64 KB ROM, above 65536 the J6 bank card) |

- Files are loaded as they are (`pocket_slot_loader`: slots 0 and 1 byte by byte, slot 2 whole bridge words into the PSRAM), no checks; the CRC32 and SHA256 check only fetching and packaging.
- Slot 2 `parameters` 75 (user-reloadable, core-specific, read-only, core reset while loading); slots 0 and 1: 10. A reload restarts the machine with the RAM kept.
- `scripts/fetch_assets.py`: the ROM disk, its GPL-3.0 licence and Kiselev's `rom_loader.asm` (for `test_romdisk.py`) into `build/assets`, checked. Never commit the ROM disk.
- Game disks: `scripts/romdisk/build_romdisks.py` puts the 48 tapes of `pk/` into `build/romdisks/romdisk-1.bin` .. `romdisk-5.bin` (65536 bytes each, a 64 KB ROM; fixed table `DISKS`) with the loader `scripts/romdisk/rom_loader_games.asm` (GPL-3.0), plus `romdisks.json` and `romdisks.txt`. `package.py` builds the same disks into every package and lists their games in `info.txt`; `package/romdisks.txt` is the template of the package's `romdisks.txt` (`@GAME_DISKS@` replaced).
- Card images (the J6 bank card): `python -B scripts/romdisk/card.py [--out DIR] [--title T] [--name NAME ...] [DISK ...]` writes `card.bin` and `card.json` (title, banks with key, name, file, size; `keywait`) into `build/card` (default). Bank 0: the card menu `scripts/romdisk/card_menu.asm` (BSD-3-Clause, 512 bytes, what `R0,1FF,0`, `G0` load; it runs at 7400-75FF), FF to 64 KB; bank n: disk n (a disk up to 32768 bytes padded to 32 KB and written twice, a larger one padded to 64 KB). Default disks: `build/assets/romdisk.bin` and `build/romdisks/romdisk-1.bin` .. `romdisk-5.bin` (7 x 64 KB = 458752 bytes, keys 0-5). At most 19 disks (`loader.MAX_ENTRIES`, fewer with long names; names up to 16 characters). Not in the package, never committed. The system scenario `card` uses `build/card-sim` (menu and disk 2).
- FAT16 card images (the same J6 bank card, all 128 banks): `python -B scripts/fatcard/fatcard.py [--out DIR] [--sim] [--pk DIR] [--romdisk FILE]` writes `fatcard.bin` (8388608 bytes; `.bin` because the ROM disk slot lists only `.bin` files) and `fatcard.json` (`keywait`, files) into `build/fatcard` (default); `--sim` also `card-sim.img` (131072 bytes: banks 0 and 1 of a card with PITON.GAM only) and `card-sim.json` (`keywait`, `start`, `length`, `offset` of PITON's payload) for the system scenario `fatcard`. Needs mtools (section 3) and `build/assets/romdisk.bin`. A FAT16 file system made by `mformat -C -T 16384 -h 1 -s 32 -R 128 -d 1 -r 32 -c 1 -L 64 -N 00000000` (512-byte sectors, 1 sector per cluster, 128 reserved sectors = bank 0, 1 FAT of 64 sectors, 512 root entries), label `RK86CARD`; sector s at bank `s >> 7`, offset `(s & 127) * 512`. Bank 0: sector 0 the boot stage (`boot.asm`: 00-02 mformat's EB 3C 90, 03-05 `C3 3E 00`, the BPB, code 3E-1FD, 55 AA; what `R0,1FF,0`, `G0` load), sectors 1-4 the menu (`menu.asm`, at 6C00), sector 5 the loader (`loader.asm`, at 7400), sectors 6-127 unused. 52 files in the root directory: the 48 tapes of `pk/` (`build_romdisks.pk_files` order), then BASIC, EDASM, EDDIS, OTHELLO extracted from Kiselev's `romdisk.bin` as tapes (`tape.py`; his XONIX and TETRIS are byte-identical to `XONIX1.RKR`, `TETRIS4.RKR`; DP/DDT left out for now, the maintainer's decision: its 6400-76FF overlaps the loader and the monitor's variables). The builder refuses a file whose range ends above 73FF (the loader at 7400-75FF, the monitor from 7600). Not in the package, never committed. Reproducible on every machine: mtools writes FAT times in local time, so `fatcard.py` overwrites the time and date fields of the label and of every file with 2000-01-01 12:00:00 (`fix_times`).
- The font is also in the bitstream: `fpga/rtl/native_font.vh` (K1 panel).
- **Licences**: `LICENSES.md`, one row per part.

## 3. Prerequisites

Platforms: the bitstream builds on Windows only (`scripts/build.ps1` calls `bin64\quartus_sh.exe`). The simulations, the Python tests and the package dry run run on Windows and Linux (CI: Ubuntu 24.04). The remote simulation client is assumed to be Windows (other clients untested).

Versions "here" are the maintainer's Windows host.

| Tool | Version | Source | Needed for |
|---|---|---|---|
| Quartus Prime Lite | **25.1std** exactly (`build.ps1` refuses others), with Cyclone V device support | the Altera (formerly Intel) FPGA download centre: Quartus Prime Lite Edition, 25.1std, Windows; Lite edition, no licence file needed | the bitstream only: `build.ps1`, the `quartus_sta` reports |
| Icarus Verilog | **13.0** exactly (`iverilog -V` prints `13.0`; another version is a full-tier change, section 6) | Windows: MSYS2 UCRT64 `mingw-w64-ucrt-x86_64-iverilog`; Linux: below | every simulation (`run_sim.py`, `run_core_machine.py`, the fork's runner), `test_k1_layout.py` (so `unit-tests.ps1`), the compile side of remote simulation |
| Python | 3.14 (here and in CI); standard library only, nothing to install with pip; older 3.x untested | python.org; Linux: below | every script and test; the commands call `python` |
| PowerShell | 7 (`pwsh`; 7.6 here, the runner's in CI) | Microsoft's PowerShell 7 install instructions (Windows and Linux) | `build.ps1`, `scripts/ci/*.ps1`; `test-remote.ps1` also runs in Windows PowerShell 5.1 |
| git | any current (2.55 here, the runner's in CI) | git-scm.com (Git for Windows); Linux: the distribution's `git` | the clone and the submodule; `run_sim.py --negative` applies the fault patches with `git apply` |
| mtools | 4.0.50 tested on Windows; in CI the Ubuntu 24.04 package (CI prints its version with `mformat --version`); others untested | Windows: MSYS2 UCRT64 `mingw-w64-ucrt-x86_64-mtools`; Linux: the distribution's `mtools` | `mformat`, `mcopy`, `mlabel` (the tests also `mdel`): `fatcard.py`, `test_fatcard.py` (so `unit-tests.ps1` and the quick tier) |
| Docker, OpenSSH client | Docker Desktop or Docker Engine with Compose; the OpenSSH client (`ssh`, `scp`, `ssh-keygen`) | `scripts/docker2tests/README.md`, section 2 | remote simulation only (the rk86-vvp container) |

### Windows

- Quartus: install Quartus Prime Lite 25.1std for Windows from the Altera (formerly Intel) FPGA download centre, with the Cyclone V device support (the Cyclone V device files offered with the installer). Lite edition: no licence file needed. `QUARTUS_ROOT` is the `quartus` folder of the installation, the one holding `bin64\quartus_sh.exe` (for example `<install dir>\quartus`); instead, put that `bin64` folder on PATH or pass `-QuartusRoot`.
- Icarus Verilog and mtools from MSYS2 (msys2.org): install MSYS2, then in its UCRT64 shell `pacman -S mingw-w64-ucrt-x86_64-iverilog mingw-w64-ucrt-x86_64-mtools`. Both land in `<msys2 root>\ucrt64\bin` (`iverilog.exe` and `vvp.exe` in one folder, as the runners need). Put that folder on PATH, or set `IVERILOG` to `<msys2 root>\ucrt64\bin\iverilog.exe` and `MTOOLS_DIR` to `<msys2 root>\ucrt64\bin`. A bare `iverilog` call needs its folder on PATH (its helpers `ivlpp` and `ivl` in `lib\ivl` need the DLLs of `ucrt64\bin`); `run_sim.py`, `remote_sim.py`, `test_k1_layout.py`, the fork's runner and `test-remote.ps1` add the `IVERILOG` folder to PATH themselves, so `IVERILOG` alone is enough for them. mtools runs from its own folder (`MTOOLS_DIR`). MSYS2 is a rolling distribution: `iverilog -V` must print `13.0`; a package update to another version is a version change.
- Python 3.14 from python.org, PowerShell 7, Git for Windows.

### Linux (as CI)

CI (`checks.yml`, `weekly.yml`): `ubuntu-24.04` runners; the steps run in the runner's `pwsh`; Python 3.14 from `actions/setup-python`; Icarus Verilog built from the tag `v13_0` (commit `dfeee909ed9f20b4870dd93423156c0170c0e1ff`) by `.github/actions/setup-iverilog` and cached; mtools from apt (the Python job only); `fetch_assets.py` in every job that reads the assets. The same on another Linux machine:

```text
sudo apt-get install -y git mtools autoconf gperf flex bison g++ make libreadline-dev libbz2-dev zlib1g-dev
git clone --depth 1 --branch v13_0 https://github.com/steveicarus/iverilog.git
git -C iverilog rev-parse HEAD                   # must be dfeee909ed9f20b4870dd93423156c0170c0e1ff
cd iverilog && sh ./autoconf.sh && ./configure --prefix="$HOME/iverilog" && make -j"$(nproc)" && make install
export PATH="$HOME/iverilog/bin:$PATH"           # iverilog -V prints 13.0
```

- Or, on Debian testing, the package of the rk86-vvp container: `iverilog=13.0-2`. A distribution's `iverilog` that is not 13.0 is not usable (check `iverilog -V`).
- PowerShell 7: Microsoft's PowerShell 7 install instructions (Windows and Linux); they install `pwsh`.
- Python: use 3.14 as CI does (python.org or a version manager) and make `python` run it, for example in a virtual environment.

### Environment variables

Nothing needs setting when the tools are on PATH.

| Variable | Meaning | Default | Read by |
|---|---|---|---|
| `QUARTUS_ROOT` | the `quartus` folder holding `bin64\quartus_sh.exe` | from `quartus_sh` on PATH | `build.ps1` (`-QuartusRoot` overrides) |
| `IVERILOG` | the path of `iverilog`; `vvp` from the same folder | `iverilog` on PATH | `run_sim.py`, `run_core_machine.py`, the fork's `run_machine16_sim.py` (`--iverilog` overrides), `test_k1_layout.py`, `remote_sim.py`, `test-remote.ps1` (`-Iverilog` overrides) |
| `MTOOLS_DIR` | the folder holding `mformat`, `mcopy`, `mlabel`, `mdel` | PATH; a wrong `MTOOLS_DIR` is an error, not a fallback | `fatcard.py`, `test_fatcard.py` |
| `RK86_CORE_DIR` | the fork's `src` | `cores/karabas-go-core-rk86/src` | `create_project.tcl`, `run_sim.py`, `run_core_machine.py`, `package.py`, `k1/monitor_decoder.py`, `test_fatcard.py` (`BIOS.BIN`) |
| `RK86_VVP_HOST` | the Docker host of the rk86-vvp container | none (`--host`) | `remote_sim.py` |
| `RK86_VVP_KEY` | the client key text from the container's console | none (`test-remote.ps1`: the clipboard, or the log of a container on this PC) | `remote_sim.py`, `test-remote.ps1` |
| `RK86_VVP_SSH_PORT` | the container's published SSH port | 2222 | `compose.yaml`, `remote_sim.py` (`--port`), `test-remote.ps1` (`-Port`) |

Leave `RK86_CORE_DIR` unset unless compiling from another tree (a worktree for remote runs, `scripts/docker2tests/README.md` section 9): `build_romdisks.py`, `fatcard.py`, `test_romdisk.py` and `test_fatcard.py` read `pk/` from the submodule whatever it says (section 2), so a set value mixes two trees.

### Clone, assets, network

- Clone with the submodule: `git clone --recursive https://github.com/BarabashkaD/radio86-rk-pocket`, or in a clone `git submodule update --init --recursive`. A GitHub source zip (Download ZIP, a release's source archive) has no submodule: `create_project.tcl`, `run_sim.py`, `run_core_machine.py`, `package.py` and the tests that read `BIOS.BIN` or `pk/` fail (`unit-tests.ps1`: "core submodule missing"). The fork's own submodule `modules` is not used (CI checks out without it).
- `python -B scripts/fetch_assets.py` once after the clone: before `unit-tests.ps1` (`test_romdisk.py`, `test_card.py`, `test_fatcard.py` read `build/assets`), `package-dry-run.ps1`, `package.py` and every system scenario. The bitstream does not need it.
- Network: github.com (the clone, the submodule) and raw.githubusercontent.com (`fetch_assets.py`, 60 s timeout; Python urllib's default proxy handling (`HTTPS_PROXY`)); the tool downloads (the Altera download centre, msys2.org, python.org, Microsoft, git-scm.com; on Linux the distribution's mirrors, github.com for the Icarus source); the container build: Docker Hub and the Debian mirrors.

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
| `pocket_system.v` | everything behind the template: slot loader, `pocket_psram` (the cram0 pins), interact registers, board, frame banks, audio, PLL watchdog, resets; APF slot requests held off until the PSRAM is `ready`; status registers (identity `0x524B4D31`) |
| `radio86rk_pocket.v` | the board around `rk86_machine16`, one clock `clk_74a`: `ce16` (64 of 297 ticks), reset (144 `ce16`), memory, font, ROM disk (ports of `pocket_cart_ppi`, bytes from `pocket_psram`; card reset `!apf_reset_n || cold_boot`), keyboard, `pocket_raster` and display window, beeper (INTE) |
| `pocket_memory.v` | RAM 0000-7FFF and monitor (8000-87FF of the array), one byte-wide port at `bus_a` (CPU, or 8257 while AEN), loader port in reset; output follows `bus_a`; no write during AEN or while `rom`; no wait states; RUS shadow. A DMA read is decoded like a CPU read: the 8275 gets the byte of whatever is at the 8257's address (this memory, an 8255, the 8275) |
| `pocket_cold_clear.v` | clears the 32 KB RAM at the first boot and on Cold boot |
| `pocket_slot_loader.v` | data-slot writes: slots 0 and 1 as 4 bytes per bridge word into the monitor or font; slot 2 (23-bit offset, `bridge_address[31:23]`) as whole words to `pocket_psram`; bytes beyond the requested size dropped; no fill; flags of the last ROM disk request: `romdisk_loaded`, `romdisk_64k` (above 32768 bytes), `romdisk_card` (above 65536 bytes); `assets_valid` |
| `pocket_psram.v` | the ROM disk in the PSRAM `cram0` (die 0, asynchronous mode, one state machine on `clk_74a`, 13 ticks per access, DQ sampled a tick before `ce_n`/`oe_n` rise, `ce_n` released after every access): start-up tPU (151 us), BCR write 9D1Fh through CRE, then `ready`; reset only by the power-up reset; packed mapping (word address = ROM A22-A1, A0 picks the byte lane); read latency at most 24 clk; a bridge word at most 26 clk; one bridge word buffered |
| `pocket_psram.sdc` | bounds the 29 cram0 outputs and 16 inputs to one tick; fails loudly when the port count changes |
| `pocket_rom8.v` | byte memory, one write and one read port (1 clk latency): the font only |
| `pocket_cart_ppi.v` | the A000-BFFF block (second 8255; the machine's `ext_rd_n`, `ext_we_n`, `ext_di`, the fork's "window"): the fork's `k580vv55` with a ROM disk on its ports (port A the ROM data, always on), three cards by `wide` (`romdisk_64k`) and `card` (`romdisk_card`), Pocket emulation by image size, not card limits: a 32 KB ROM (`{0, PC6..PC0, PB}`, A15 not wired: 8000-FFFF mirror 0000-7FFF, the maintainer's decision), a 64 KB ROM (`{0, PC7..PC0, PB}`) or the J6 bank card (`{bank, PC7..PC0, PB}`, 128 banks of 64 KB); the bank latch takes PB0-PB6 (PB7 ignored) when PC7 falls and PC0-PC6 are all high after the fall (`pc7_q && pc_pin == 7F`, only while `card`); cleared only by `card_reset` (power-up, slot load, Cold boot), kept on the machine reset; `loaded` low: port A reads FF; ROM address 23 bits to the PSRAM; its A1, A0 from `bus_a`, also during DMA |
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
- `quartus/`: `ap_core.qsf`; `create_project.tcl` (project in a build dir, `fpga/rtl/*.v` plus `rk86_machine16.prj`, `VERILOG_CONSTANT_LOOP_LIMIT 70000`); report-only `report_pocket_machine_cdc.tcl`, `report_pocket_audio_cdc.tcl`, `report_pocket_timing.tcl` (`quartus_sta -t` in a build dir).
- `sim/`:
  - `run_sim.py` (runner, `TESTS`); `frame_compare.py` (1-bit 408 x 300 frame vs golden, one cell tolerance; `--cursor cursor.txt --x0 N` masks the cursor cell); `run_core_machine.py` (fork's `machine16` on `pocket_memory`, then fault `memory_dropped_after_rd`, must fail with `ERROR: dma byte`).
  - `unit/`: one TB per module (`tb_slot_loader`, `tb_bus_cdc`, `tb_cart_ppi`, `tb_cold_clear`, `tb_cpu16`, `tb_frame_colour`, `tb_frame_video`, `tb_k1_panel`, `tb_native_audio`, `tb_pll_watchdog`, `tb_pocket_interact`, `tb_pocket_keyboard`, `tb_pocket_memory`, `tb_pocket_raster`, `tb_pocket_window`, `tb_psram`); `cpu16/cpu_test.asm` (assembled with `scripts/romdisk/asm8080.py`).
  - `system/`: `tb_system.v` (`pocket_system` with a PLL stub, `+scenario=`; stops when no plausible frame comes within 2 s simulated; writes `cursor.txt`) and `power_up.vh` (includes the fork's `cpu_power_up.vh`).
  - `memory/`: `tb_rk86_mem16.v` (`pocket_memory` as the memory model of the fork's `machine16` TB); `psram_model.v` (the PSRAM model: `AW` word address bits, 22 for `tb_psram`, `tb_slot_loader` and `tb_cart_ppi`, 16 (128 KB: card banks 0 and 1) for `tb_system`; an access beyond it is an ERROR, never aliased; checks the data sheet timings, tCEM among them; drives X from the OE#/CE# rise until tOHZ, no output hold; `tb_psram` fails a sample that DQ does not hold for 1 ns).
  - `negative/`: fault patches (each listed in `run_sim.py` with its expected error). `golden/`: `monitor-boot.hex`, `rom-disk-menu.hex`, SHA256 in `golden/README.md`.

### `scripts/`

| File | Use |
|---|---|
| `build.ps1` | Quartus build into `build/quartus` (`-BuildDir`, `-QuartusRoot`), then `check_build.py` |
| `check_build.py` | 0 errors, no critical warning but `ALLOWED_CRITICAL`, 5 slack kinds non-negative in 4 corners, `ap_core.rbf` present |
| `fetch_assets.py` | fetch and check ROM disk, licence, Kiselev's loader source (`--record-licence`) |
| `romdisk/asm8080.py` | two-pass 8080 assembler (Kiselev's syntax) |
| `romdisk/rom_loader_games.asm`, `romdisk/loader.py` | games menu loader (GPL-3.0; keys 0-9, A-Y; Z clears RAM), `games_loader()` |
| `romdisk/build_romdisks.py` | the 5 game disks (64 KB) into `build/romdisks` (`--pk`, `--out`); `build()`, `metadata()` used by `package.py`; `--readme` prints the README's game list |
| `romdisk/card_model.py` | Python model of the J6 bank card (`CardPpi`: the 8255 in mode 0, the three cards by size, the bank event, `card_reset`; `fa68_copy`, the monitor's `R`) |
| `romdisk/card_menu.asm`, `romdisk/card.py` | the card menu (BSD-3-Clause, new code; `SELBK`, then the disk's 0000-01FF by FA68 and `JMP 0`) and the card image builder (`card.bin`, `card.json`; section 2) |
| `romdisk/emu8080.py` | small 8080 emulator with monitor stubs, for the tests; with a `CardPpi`, A000-BFFF are the card's ports and FA68 reads the card; `run_until` (the FAT16 card tests): stops on `stop(pc)` or when F803 finds no key left (`waiting`), stubs closer to the monitor (CLS 1Fh zeroes 76D0-7FF4; a print after a change of the monitor's variables 7600-765F, or a FA68 of 65536 bytes, is `EmuError`); RLC, RRC, RAL, RAR, LHLD, SHLD, XTHL, CMA among its opcodes |
| `fatcard/tape.py` | tape files (`make_tape`: E6, start, end, payload, E6, checksum); `kiselev_files`: the programs of Kiselev's ROM disk as tapes (BASIC padded with zeros to 2117h; DPDDT.RKR extracted but not put on the card) |
| `fatcard/fatcard.py` | the FAT16 card image on mtools (section 2): `format_image`, `label_image`, `add_files`, `install_bank0`, `build_image`; read back by `bpb`, `directory`, `menu_entries`, `cluster_chain`, `read_file`; `loader_window` (the builder's range check); `assemble_boot`, `assemble_menu`, `assemble_loader` with their RAM checks; CLI `--out --sim --pk --romdisk` |
| `fatcard/boot.asm`, `fatcard/menu.asm`, `fatcard/loader.asm` | the card's 8080 code (BSD-3-Clause, new code): boot stage (sector 0: checks the BPB, copies the menu to 6C00), menu (6C00-71FF code and variables, 7200-73FF one directory sector; 20 files per page; SELBK 0 before its key wait), loader (7400-75BF, stack 75C0-75FF; checks the file and the FAT chain of every cluster the load needs, then CLS, copies, SELBK 0, jumps to the start) |
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
| `tests/test_romdisk.py` | assembler (Kiselev's loader byte-exact), games loader, every key of every disk, the README's game list current; needs `fetch_assets.py` |
| `tests/test_card.py` | card model (event, no event, card types and boundaries, card reset), the emulator through the card, card image layout and limits, every key of the card menu reaches its disk's loader, Kiselev's image in a card; needs `fetch_assets.py` |
| `tests/test_fatcard.py` | FAT16 card (80 tests): tapes and Kiselev's files, mtools lookup and calls, BPB and layout, directory rules (deleted, long names, label, a 00 entry), fragmented files and corrupt chains, the builder's checks, the boot stage, the loader (sector edges, both header forms, refusals before RAM is touched, bank 0 after every load and refusal), the menu (paging, a full root directory of 511 files, every file of the card image reaches its start, `Z`, Reset at the key wait); needs mtools and `fetch_assets.py` |

### `package/`

`core/core.json` (version, date filled by `package.py`), `data.json`, `interact.json`, `input.json`, `video.json` (408 x 300, 34:25), `audio.json`, `variants.json`, `updaters.json` (`declare_ai` only), `info.txt` (shown on the Pocket), `platform/radio86rk.json`, `assets.json`, `romdisks.txt` (template).

## 6. Build and test

From the repo root; Python with `-B`.

```text
python -B scripts/fetch_assets.py                  assets into build/assets (every system scenario reads romdisk.bin)
python -B fpga/sim/run_sim.py                      every test that is not slow (unit TBs)
python -B fpga/sim/run_sim.py --negative           also each fault: it must fail with its named error
python -B fpga/sim/run_sim.py --slow               adds the slow tests that are not skipped (cpu16, system scenarios)
python -B fpga/sim/run_sim.py boot menu            named tests only
python -B fpga/sim/run_sim.py --iverilog PATH ...  iverilog not on PATH and IVERILOG unset
```

Inputs built first, or the test fails with a hint: `game` and `menu64` read `build/romdisks` (`python -B scripts/romdisk/build_romdisks.py`); `card` reads `build/card-sim` (`build_romdisks.py`, then `python -B scripts/romdisk/card.py --out build/card-sim build/romdisks/romdisk-2.bin`); `fatcard` (skipped unless named) reads `build/fatcard/card-sim.img` and `card-sim.json` (`python -B scripts/fatcard/fatcard.py --sim`, mtools).

Outputs: `build/sim/<test>/`. Pass: `vvp` exits 0, a `PASS` line, no `ERROR`/`FATAL`, frame compare passes where set.

### Tests (`TESTS` in `run_sim.py`)

| Test | Kind | Time |
|---|---|---|
| `cart_ppi`, `audio`, `bus_cdc`, `keyboard`, `frame_video`, `frame_colour`, `k1_panel`, `slot_loader`, `memory`, `cold_clear`, `window`, `interact`, `raster`, `watchdog`, `psram` | unit; `cart_ppi`, `slot_loader` and `psram` on the PSRAM model (12, 5 and 7 faults) | all with faults about 15 min at 2 jobs; `psram`, `slot_loader`, `cart_ppi` with faults 5 min remote at 6 jobs |
| `cpu16` | slow: `cpu_test.asm` on `rk86_machine16` with `pocket_memory` (through `fpga/sim/memory/tb_rk86_mem16.v`); phase 7 a DMA block in the monitor ROM (the 8275 must take the program bytes); faults `cpu16_bus_bit`, `cpu16_startup_decode`, `cpu16_dma_rom_from_ram` | 7 min |
| `boot` | system: slots, cold clear, monitor to FE63, frame vs `monitor-boot.hex` (cursor masked), beeper follows INTE, native frame period 319 920 `ce16`; fault `beeper_pc0_xor` | 16-30 min |
| `powerup` | system: randomised CRT and DMA registers, frame vs `monitor-boot.hex` | 21 min |
| `nocart`, `reset`, `relock`, `system_watchdog` | system | 15, 60, 40, 31 min |
| `system_k1_panel` | system (scenario `k1_panel`): the panel with the machine frozen (`ce16` held low), 3 captures; then `python -B scripts/k1/check_frames.py build/sim/system_k1_panel --expect 3` | 23 min with the machine running; frozen: to be measured |
| `keytap` | system: an 80 ms and a 1 ms button tap reach the monitor (`pocket_keyboard` on real milliseconds; INFO: the time to the delivery); fault `keytap/min_hold_short` | not measured yet |
| `k1` | system: 7 panel captures; then `python -B scripts/k1/check_frames.py build/sim/k1` | 105 min |
| `xonix` | ROM disk, checkpoints: the loader copied, the menu reached; the menu frame vs `rom-disk-menu.hex`; key 4: XONIX copied to 0000, started, running | about 190 min |
| `menu` | ROM disk, the menu frame only; skipped unless named: `xonix` captures the same frame | 155 min |
| `dpddt` | ROM disk; skipped unless named (`run_sim.py dpddt`): `xonix` covers the same path | 182 min |
| `menu64` | ROM disk: the 64 KB game disk `romdisk-2.bin` from `build/romdisks` in the ROM disk slot through the PSRAM, the 64 KB ROM flags, `R0,1FF,0`, `G0`, the menu | 127 min alone; 120 min remote with 3 other system runs |
| `card` | ROM disk (not in CI): the card image of `build/card-sim` (the card menu in bank 0, disk 2 in bank 1, 131072 bytes; `card.json` gives `keywait`); J6 bank card flags, `R0,1FF,0`, `G0`, the card menu, key 0: bank 1, disk 2's loader started at 0000, its menu; Core Settings Reset keeps the bank, Cold boot clears it | 190 min (remote with 3 other system runs) |
| `fatcard` | ROM disk, skipped unless named (not in `--slow`, not in CI): `build/fatcard/card-sim.img` (131072 bytes, banks 0 and 1 of a FAT16 card with PITON.GAM only; `card-sim.json` gives `keywait`, `start`, `length`, `offset`); J6 bank card flags, `R0,1FF,0`, `G0`, the boot stage, the menu's key wait on bank 0, title and entry on screen; ВК: the loader leaves bank 0, copies PITON.GAM from two clusters, RAM checked, started on bank 0 | about 177 min (remote with up to 3 other system runs, 2026-11-13) |
| `game` | ROM disk, checkpoints: boot with Kiselev's image (32 KB ROM); the ROM disk slot reloaded with disk 2 (`cartridge2.hex` from `build/romdisks`) as the Pocket menu does: 64 KB ROM, RAM kept, monitor restarted; menu, key 9: XONIX1 (above 8000h: ROM A15 = PC7) copied, started, running | about 190 min |
| `tetris` | kept, skipped unless named (`run_sim.py tetris`); its D-pad mapping is to be reviewed | |

Times: measured on a 10-CPU host with several runs in parallel (2026-11-11); `menu64`, `card` and the PSRAM unit tests in the rk86-vvp container (2026-11-13).

### Test tiers

Choose by `git diff --name-only <base>...HEAD` plus uncommitted changes.

| Tier | When | Tests | Time |
|---|---|---|---|
| quick | every commit | `check_repo.py`; Python tests of the changed scripts or data (`unit-tests.ps1` runs all; `test_fatcard.py` needs mtools); `run_sim.py --negative <unit TBs whose files or patches changed>` | 1-15 min |
| sanity | first system check after an RTL, TB or pin change | `run_sim.py boot` | 16-30 min |
| standard | after an RTL or TB change | quick, sanity, the scenarios of the changed modules (table below); `run_sim.py --negative cpu16` and `run_core_machine.py` after a change of `pocket_memory.v` or `fpga/sim/memory/` (7 min; 25-30 min, then its fault as long); package dry run after a change of `package/` or package scripts; Quartus build (10 min) after a change of `fpga/core/`, `fpga/apf/`, `fpga/quartus/` or an `.sdc` | 30 min to 2 h |
| full | once before a push | every unit TB with faults; `run_sim.py --negative cpu16`; `unit-tests.ps1`; `boot`, `powerup`, `nocart`, `reset`, `relock`, `system_watchdog`, `system_k1_panel`, `run_sim.py --negative keytap`, `k1` (with `check_frames.py`); `run_core_machine.py`; the fork's runner with `--negative` (unit TBs 2 h 8 min at 2 jobs, `machine16` with faults 2 h at 4 jobs); `package-dry-run.ps1`; `build.ps1` | about 6 h in parallel |
| release | before a package goes to the Pocket | full, the ROM disk scenarios the change touches (`xonix`, `game`, `card`, `fatcard`), then `package.py` on the real build | up to +3.5 h |

| Changed | Standard | Release adds |
|---|---|---|
| `pocket_keyboard.v`, `pocket_remap.v` | `system_k1_panel`, `keytap` | `k1` |
| `pocket_k1_panel.v`, `pocket_k1_layout.vh`, `native_font.vh`, `scripts/k1/` | `system_k1_panel` | `k1` |
| `pocket_bus_cdc.v` | `system_k1_panel`, `relock` | |
| `pocket_frame_video.v` | `boot`, `system_k1_panel`, `relock` | |
| `pocket_raster.v`, `pocket_window.v` | `boot` | `xonix` |
| `pocket_memory.v`, `pocket_cold_clear.v` | `boot`, `reset`, `cpu16`, `run_core_machine.py` | `xonix` |
| `pocket_slot_loader.v`, `pocket_rom8.v` | `boot`, `nocart`, `menu64` | `xonix`, `card` |
| `pocket_cart_ppi.v` | `nocart`, `menu64`, `card` | `xonix`, `game`, `fatcard` |
| `pocket_psram.v`, `pocket_psram.sdc`, `fpga/sim/memory/psram_model.v` | `psram` (unit, with faults), `boot`, `menu`, `menu64`; Quartus build | `xonix`, `game`, `card` |
| `pocket_audio.v` | `relock` (`audio` checks the samples) | |
| `pocket_pll_watchdog.v` | `system_watchdog`, `relock` | |
| `pocket_interact.v` | `boot`, `reset` | `card` |
| `radio86rk_pocket.v` | `boot`, `nocart`, `reset`, `system_k1_panel` | `xonix`, `card` |
| `pocket_system.v`, `tb_system.v`, `power_up.vh` | `boot`, `nocart`, `reset`, `relock`, `system_watchdog`, `system_k1_panel` | `xonix`, `card`, `fatcard` |
| `scripts/romdisk/` | (`test_romdisk.py`, `test_card.py`, `test_fatcard.py` in quick: `emu8080.py`, `asm8080.py`, `build_romdisks.py`, `card_model.py` are shared); `card`, `fatcard` | `game` |
| `scripts/fatcard/` | (`test_fatcard.py` in quick); `fatcard` (`fatcard.py --sim` first) | |
| a new module | the `pocket_system.v` row | `xonix` |

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
pwsh -File scripts/ci/unit-tests.ps1                     all Python tests as in CI (a skip fails; needs iverilog, mtools, fetch_assets.py first)
python -B -m unittest scripts/tests/test_package.py
python -B -m unittest scripts/tests/test_k1_layout.py     (Verilog part needs iverilog)
python -B -m unittest scripts/tests/test_fatcard.py       (needs mtools)
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

Writes `build/package/sd/` and `build/package/BarabashkaD.Radio86RK_<version>_<date>.zip`: `Cores/BarabashkaD.Radio86RK/` (bitstream, json, `info.txt`, icon, licences, `APF-NOTICE.txt`), `Assets/radio86rk/BarabashkaD.Radio86RK/` (the three assets, `romdisk-1.bin` .. `romdisk-5.bin`, `romdisks.txt`), `Platforms/` (`radio86rk.json`, `_images/radio86rk.bin`). The card images are not in the package. Without a Quartus build: `pwsh -File scripts/ci/package-dry-run.ps1` (into `build/ci-local/tmp/`; never publish that zip).

### CI (GitHub Actions)

- `checks.yml` (PR to `main`, push to `main`, on demand; Ubuntu, PowerShell steps; job names are the ruleset's status checks, a rename needs the ruleset changed):
  - `Python tests and package checks`: iverilog (`.github/actions/setup-iverilog`), `check_repo.py`, `fetch_assets.py`, mtools (apt, prints `mformat --version`), `unit-tests.ps1`, `package-dry-run.ps1`;
  - `Unit simulations and faults`: `run_sim.py --negative`;
  - `K1 panel scenario`: `system_k1_panel` and `check_frames.py --expect 3`;
  - `Core machine TB subset`: `run_sim.py --negative cpu16` (the CPU test program on `rk86_machine16` with `pocket_memory`).
- `weekly.yml` (Mondays 03:17 UTC, on demand), one job per runner: `boot`, `powerup`, `nocart`, `reset`, `relock`, `system_watchdog`, `keytap`, `k1` (`check_frames.py --expect 7`); `run_core_machine.py`; the fork's `run_machine16_sim.py --negative <test>`, one job per test (`machine16` with its faults in one job). Re-enable it in the Actions tab after 60 days without activity.
- Time limits (minutes): 2-3 times the remote times above (a GitHub runner's Icarus is that much slower), plus the setup; GitHub stops any job at 360.
  - `checks.yml`: Python 30, unit simulations 60, K1 panel 45, core machine subset (`cpu16`) 60.
  - `weekly.yml`: `boot` 150, `powerup` 120, `nocart` 90, `reset` 240, `relock` 180, `system_watchdog` 150, `keytap` 210, `k1` 340; `run_core_machine.py` 240; fork unit TBs 330 each, `machine16` with its faults 360 (it may reach the cap until the fork runner can run its faults in groups).
- Icarus Verilog 13.0 is built from source (`v13_0`) by `.github/actions/setup-iverilog` and cached.
- Failure artifacts: 7 days, without `cartridge.hex`, `monitor.hex`, `bios.hex`, `font.hex`, `*.vvp`.
- Not in CI: the ROM disk scenarios (`xonix`, `menu`, `dpddt`, `menu64`, `card`, `fatcard`, `game`, `tetris`), the Quartus build, the hardware test.
- `check_repo.py` exempts `fpga/apf/`, `fpga/core/` from the LF rule; `LEGACY` lists today's line-ending exceptions (normalising them is a separate, approved change).

### Install on a Pocket

Unzip the package onto the SD card root; the core appears as "Radio-86RK". Upgrading from 0.5.x: delete `Settings/BarabashkaD.Radio86RK/` first.

## 7. Features

Unreleased since 0.8.2: the ROM disk in the PSRAM (images up to 8 MB), the J6 bank card, the 32 KB mirror, the J6 card menu and the FAT16 card. The rest is in 0.8.2.

- `rk86_machine16`: `ce16` on 64 of 297 `clk_74a` ticks (16 MHz timebase); CPU 1.778 MHz (Vslav's 8080); 8257 on Φ2; 8 MHz dots; 516 x 310 raster at 50 Hz; one DMA HOLD period per character.
- The board's address map and DMA wiring, reproduced (`fpga/README.md`, The 16 MHz machine): one device per 8 KB block (A15-A13), each 8255's 4 registers repeating every 4 bytes; the 8257 on channel 2 only, memory to the 8275, MEMR not connected; DMA reads decoded like CPU reads.
- Monitor and font from data slots, as they are, in block RAM: monitor at 8000-87FF of the memory array (read at E000-FFFF), font in its own memory.
- ROM disk image from data slot 2 in the PSRAM `cram0` die 0 (asynchronous mode, 13 ticks per access): up to 8388608 bytes; optional (every ROM disk byte reads FF when absent); reloadable from the core's menu with the RAM kept; no fill beyond a shorter image.
- The A000-BFFF block: the second 8255 with the ROM disk on its ports, port A always on; menu via `R0,1FF,0`, `G0`. The card follows the image size (Pocket emulation, not card limits): up to 32768 bytes a 32 KB ROM (A15 not wired: 8000-FFFF mirror 0000-7FFF), up to 65536 a 64 KB ROM (PC7 = ROM A15), above it the J6 bank card.
- The J6 bank card: 128 banks of 64 KB, ROM `{bank, PC7..PC0, PB}`; the bank latch takes PB0-PB6 (PB7 ignored) when PC7 falls with PC0-PC6 high after the fall (`SELBK`: port C FF, port B the bank, bit reset PC7); the monitor's `R` never makes this event. Bank cleared by the card reset (power-up, slot load, Cold boot), kept by Reset.
- Five 64 KB game disks in the package. Built from source, not in the package: the J6 card menu image (`card.py`: `card_menu.asm` in bank 0, whole disks in banks 1..n) and the FAT16 card (`fatcard.py`: 52 tape files; boot stage, file menu with the Cursor preset keys, loader that checks the file and its FAT chain before it writes RAM and ends on bank 0; section 2).
- K1 on-screen keyboard (L+R): 67 keys, labels from the monitor's decoder, LAT/RUS, Shift latch (L tap), Ctrl (L held), RUS/LAT (R); palettes Pink, Grey, Mono.
- Buttons with the panel closed: Keys (Cursor, Digits 7-8-9-6, Digits 8-4-6-2, WASD), Keys on (D-pad, A B X Y), Escape (Select, Start, None).
- Core Settings: Reset (RAM kept, ROM disk bank kept), Cold boot (RAM cleared, bank 0), Sound, Text colour, Keyboard colours.
- Video: 408 x 300 display window, 60 Hz output, about 25 picture updates per second. Sound: INTE only, 48 kHz I2S.
- PLL watchdog: on lock loss only picture and sound stop.
- Status registers: `fpga/README.md`, Bridge map.

## 8. Limits and known issues

- Hardware: 0.8.2 run on a Pocket by the maintainer (2026-11-12), the 64 KB game disks included; 0.8.0 (2026-11-11), Tetris included; 0.6.1-0.7.1 on OS 2.7. Unreleased: the PSRAM test build (10e6cf4, before the J6 bank card) and the test build 0.8.3-j6-test (e2496b7) run on a Pocket by the maintainer (2026-11-13); in the latter `card.bin` (the card menu with Kiselev's disk and the five game disks) and `fatcard.bin` (52 files) worked; no further detail is known. Nothing else is hardware-verified.
- Simulation of the unreleased features: remote runs passed at d768b7a (`cart_ppi` with 12 faults, `slot_loader`, `psram`, `boot`, `nocart`, `reset`, `menu64`, `card`), `boot` again at c49efc4 (the current system TB); `card` re-run at c49efc4: PASS (about 163 min); the system scenario `fatcard` at cf05986: PASS (about 177 min); the release-tier `xonix` and `game` not re-run. Quartus build at e2496b7: PASS, setup slack +1.667 ns, hold +0.120 ns, 69 of 308 RAM blocks, 3327 of 18480 ALMs.
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
- The PSRAM comes up in whatever mode an earlier core left; the controller writes the BCR to 9D1Fh (asynchronous) after tPU at every power-up. Only the power-up resets it.
- ROM disk, no fill: with no image in slot 2 port A reads FF (`loaded`), but beyond a shorter image it reads whatever the PSRAM holds (the tail of an earlier, longer image, or what an earlier core left). Not cleared on a reload. With the 32 KB mirror, 8000-FFFF of a short image (Kiselev's 32256 bytes) reads the image's 0000-7FFF and that tail.
- J6 bank card: the bank cannot be read back (by design; the software that sets it keeps it in RAM). The card menu lists at most 19 disks (fewer with long names) of the 128 banks. Back to the card menu: Cold boot or a slot reload (Reset keeps the bank).
- J6 bank card and FAT16 card: a program that writes A002/A003 (for example LORUNNER.GAM, SDEMISE.GAM drive port C for sound), or Ctrl-C during a load, can leave another bank selected; then Cold boot or a slot reload.
- FAT16 card: the menu lists up to 511 files (512 root entries, one the label; fewer with long names), root directory only, 8.3 names, in directory order; a file runs only when it is a tape (optional E6, start, end, high byte first) below 64 KB whose end is at most 73FF and whose size covers the header and the payload, else it shows `?` and the run key does nothing; no checksum check. The loader checks the file and the FAT chain of every cluster the load needs before it writes RAM; a refusal (`NOT A TAPE`, `BAD FILE`) selects bank 0 and returns to the monitor's prompt. `Z` comes only from the K1 panel (no button sends Z). The menu is on bank 0 only while it waits for a key (KEYNEXT, KEYWAIT; its first count, a page redraw and the run key read bank 1 and higher), so Reset while the menu waits for a key, or after a program started, then `R0,1FF,0`, `G0` brings the menu back (a property of the design, tested in `test_fatcard.py`, not in a system scenario); a Reset during a page change or a load (bank not 0) needs Cold boot or a slot reload. CHESS, PACMAN.GAM and OTHELLO overlap the menu (6C00-73FF): `R0,1FF,0`, `G0` again after them. BASIC.RKR runs to 2117h with zeros (RAM 2000-2117 cleared; Kiselev's loader cleared only 2117h).
- FAT16 card, FAT16 only: a FAT12 volume (fewer than 4085 clusters, about 2 MB or less) is not detected by the boot stage and loads wrong data; build images with `fatcard.py`.
- The `k1_panel` unit test draws over the red frame of `pocket_frame_video`, which the core does not drive.
- Follow-up: `tetris` stays skipped; its D-pad check is vacuous on the full 8255 and the D-pad mapping is to be reviewed by the maintainer.
- Follow-up: `reset` does not compare the picture after Reset and Cold boot with `golden/monitor-boot.hex` (the 8275 keeps running through the machine reset).
- Follow-up: `powerup` uses Icarus' fixed `$random` sequence (one state, no `+seed`) and randomises only the 8275 parameters and the 8257 address and count.
- Follow-up, J6 bank card: writes to the card (PB7 reserved for it); the physical card (memory part, power, PCB, a breadboard check of the RC delay; `hardware/j6-bank-card.md`); the card image in the package (the maintainer's decision).
- Follow-up, FAT16 card: DP/DDT on the card (6400-76FF overlaps the loader 7400-75FF and the monitor's variables 7600-765F: a bank-aware load is needed); menu keys for the presets other than Cursor; key autorepeat of a held button in the menu; the FAT16 image in the package (the maintainer's decision); `--pk` through `RK86_CORE_DIR` (section 2).
- Follow-up: CI runs `test_fatcard.py` with the Ubuntu 24.04 mtools package (CI prints its version with `mformat --version`; tested on Windows: 4.0.50): verified only at the first CI run after a push. `test_fixed_times_whatever_the_time_zone` builds under four `TZ` values and checks the fixed FAT time bytes, so the images do not depend on how that mtools handles time zones or `SOURCE_DATE_EPOCH`.
- `cram1`, SRAM and SDRAM stay tied off in `core_top.v`.

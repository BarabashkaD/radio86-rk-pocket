# Changelog

## 0.8.2 (2026-11-11)

- ROM disk up to 64 KB: data slot 2 takes up to 65536 bytes into a 64 KB memory (32 more M10K blocks). The wiring follows the image size: up to 32768 bytes Kiselev's (PC7 = ROM enable, his `romdisk.bin` unchanged), above it a 64 KB ROM (port B and port C = ROM A0-A15, PC7 = A15, the ROM always on). The monitor's `R` (FA68) already takes 16-bit ROM addresses.
- Game disks: 5 disks of 64 KB (was 9 of 32256 bytes), the same 48 games, menu title "ROM-DISK/64K GAMES n/5". Disks from 0.8.1 and earlier still load (32 KB wiring).
- Tests: `cart_ppi` both wirings (faults `cart_wide_no_a15`, `cart_wide_pc7_off`; `cart_pc7_ignored` regenerated); `slot_loader` 65536 bytes and the wiring flag (faults `romdisk_32k_only`, `wide_at_32k`); `game` boots with Kiselev's image, reloads the ROM disk slot with disk 2 as the Pocket menu does (64 KB wiring, RAM kept), then XONIX1 above 8000h; `menu` checks the 32 KB wiring; `xonix` is the ROM disk run of the release tier (checkpoints: the menu frame vs `rom-disk-menu.hex`, then XONIX; also the 32 KB wiring), `menu` and `dpddt` skipped unless named; `test_romdisk.py` the five disks.
- Remote runs (`scripts/docker2tests/remote_sim.py`): the fork's fault entries with 'anywhere' and its first-error rule; a start confirmed by `run.pid` after a timeout; ssh commands retried on a busy container.

## 0.8.1 (2026-11-11)

The final review's fixes on top of 0.8.0 (fork `rk86-16mhz` d995355).

- 8275: no DMA request after an underrun (a burst space ending at the underrun no longer raises DRQ).
- DMA reads decoded on the system address, as on the board; the ROM disk 8255 takes A1, A0 from the system address.
- Tests: a fault is caught only by its first ERROR line; the 8255 reset mid-run; the A000-BFFF read path; `cpu16` DMA from the ROM; `keytap` (new); `tb_system` limits from measured 16 MHz frames; `system_k1_panel` independent of the machine; CI limits and jobs for the slower machine.
- `cpu16`: phase 7 counted from the write of its result (the RAM starts at 00, so the row 0 check of phase 6 never armed).
- Fork runner: the fault `dma_rom_from_ram` is caught anywhere in the output (its patch also trips the start-up check first).
- The 8257 SI state of the data sheet kept as a patch (`src/rtl/rk86_16/alt/vt57_si_state.patch`), not merged.

## 0.8.0 (not released on its own; in 0.8.1)

Run on a Pocket by the maintainer (2026-11-11), Tetris included.

- Machine: `rk86_machine16` from the fork's `src/rtl/rk86_16/` (branch `rk86-16mhz`), the original's 16 MHz timing, each chip to its data sheet: `ce16` on 64 of 297 `clk_74a` ticks; CPU 1.778 MHz (Vslav's 8080 model); 8257 on Φ2; 8 MHz dots; 50 Hz frames; one DMA HOLD period per character. `rk86_machine` left the Pocket build.
- Memory: one port at `bus_a` (CPU, or DMA while AEN); no wait states.
- DMA reads are decoded like CPU reads, as on the board: the 8275 receives the byte of whatever is at the 8257's address (RAM, an 8255, the 8275, the monitor ROM).
- ROM disk: the A000-BFFF block (second 8255) is the fork's full 8255 model with Kiselev's ROM disk wiring; its A1, A0 come from the system address, also during DMA.
- Video: `pocket_raster` (new) locks to HRTC and VRTC; display window `X0` = 42, one native line per display line; about 25 picture updates per second.
- Sound: INTE only (was `pc0 ^ inte`).
- Start-up mapping of the Радио 1986 board: the monitor at every address until the first read with A15 = 1.
- Tests: the fork's per-chip testbenches and `machine16`; `cpu16`, `raster`; `run_core_machine.py` on `machine16`; cursor-masked frame compare; `tetris` skipped unless named; remote runs with `scripts/docker2tests/remote_sim.py`.
- Licences and credits: Vslav's 8080 model (CC-BY 3.0), the 8257 and 8275 models, the new fork files.

## 0.7.1 (2026-11-09)

Run on a Pocket by the maintainer (2026-11-09), with the game disks. The RTL is that of 0.7.0.

- The ROM disk can be reloaded from the core's menu: `data.json` slot 2 `parameters` 75 (user-reloadable, core-specific, read-only, core held in reset while loading; was 10). The loader takes the new file during that reset and the machine restarts with the RAM kept.
- The package has `romdisks.txt` in its Assets folder (template `package/romdisks.txt`): how to run a program from the ROM disk and how to change the disk, the programs of `romdisk.bin`, and the games of each game disk. `build_romdisks.py` writes each game's title into `romdisks.json`. `info.txt` points to the file and lists the games of each disk by menu key and name, so the list can be read on the Pocket.
- The 9 game disks are in the package, next to Kiselev's `romdisk.bin`: `package.py` builds `romdisk-1.bin` to `romdisk-9.bin` from the Karabas core's `pk/` at every run (no `--romdisks` option, no `_games` zip). LICENSES.md: the game disks are shipped; the provenance of the games stays open.
- Docs: the data slot table in fpga/README.md gives the sizes as maximums and the parameters of each slot.

## 0.7.0 (2026-11-09)

Run on a Pocket by the maintainer (2026-11-09). Includes 0.6.3, which was not released on its own.

- Direct 8-bit loading: the data slots are written byte by byte into the machine's memories (`pocket_slot_loader`: each 32-bit bridge word becomes 4 byte writes, only while the core is held in reset). The monitor sits in the machine's memory array at 8000-87FF (read at E000-FFFF), next to the RAM; the font and the ROM disk have their own byte-wide memories (`pocket_rom8`), which the CPU never writes.
- One port for the RAM and the monitor (`pocket_memory`), as on the original: the CPU, or the DMA while it holds the bus; the DMA read port and its write forwarding are gone. Every memory is built once: 103 of 308 M10K blocks (0.6.3: 173), RAM and monitor 34, ROM disk 32, font 1.
- No checks of the files: no CRC, no coverage, no red error frame (`pocket_boot_assets` and `pocket_asset_store` removed; the `error_sync` endpoint left the CDC constraints and report). Status registers 0x14, 0x1C, 0x20 and 0x3C read 0. `data.json` gives only maximum sizes: monitor 2048, font 1024, ROM disk 32768 bytes; bytes no slot wrote read FF (monitor, ROM disk) or 00 (font). Cold boot clears 0000-7FFF and keeps the monitor.
- `check_build.py` allows one expected critical warning (`ALLOWED_CRITICAL`): Quartus pads the initial contents of the 34816-byte `pocket_memory` to its 16-bit address.
- Tests: unit test `slot_loader` (faults `size_not_limited`, `lane_order`) replaces `assets` (and its faults `rom_disk_required`, `rom_disk_crc_checked`); `memory` and `cold_clear` for the one-port memory, its faults regenerated; the system TB checks the loaded memories; the core machine TB copies the monitor into `pocket_memory`. Test tiers in AGENTS.md section 6.

## 0.6.3 (2026-11-09, not released)

- The ROM disk slot accepts any image of 32256 bytes: its CRC is no longer checked (`pocket_asset_store` parameter `CHECK_CRC`, 0 for the ROM disk only), only reported in the status register 0x3C. The monitor and the font keep their CRC checks. New fault `rom_disk_crc_checked` of the `assets` unit test.
- Game disks: `scripts/romdisk/build_romdisks.py` builds the 48 game tape images of the Karabas core (`pk/`, the duplicates included) into 9 ROM disks with a menu loader derived from Sergey Kiselev's (`scripts/romdisk/rom_loader_games.asm`, GPL-3.0: keys 0-9 then A-Y, Z clears RAM). They are built locally, not in the package. Tools: an 8080 assembler (it reproduces Kiselev's loader byte for byte) and a small 8080 emulator; `scripts/tests/test_romdisk.py` starts every game of every disk from its menu key in the emulator.
- The games loader copies and starts a game on the monitor's stack (76CF), not inside its own table: after Reset, `G7416` shows the menu again with an intact table (before, the selected entry and the one before it no longer loaded). The emulator's monitor stubs now use the stack as deeply as the real calls; new tests `test_menu_again_after_a_game` and `test_game_starts_with_the_monitor_stack`.
- System scenario `game`: disk 9, the menu, XONIX1 by the key B, on the whole core (local, about 1.5 h).
- `fetch_assets.py` also fetches Kiselev's loader source (`sources` in `assets.json`); in CI the assets are fetched before the Python unit tests.

## 0.6.2 (2026-11-08)

- The 0.6.1 core (the same bitstream) with new artwork, run on a Pocket (OS 2.7) by the maintainer.
- CI (GitHub Actions): `checks` on every PR and push to `main` (Python tests, repository rules, asset check, package dry run with the openFPGA library check, unit simulations with their faults, the `system_k1_panel` test, the core's machine TB subset on the Pocket memory); `weekly` (the long system scenarios and the full machine TB). Icarus Verilog 13.0 is built from source and cached. Failure artifacts leave out the ROM disk.
- `scripts/check_repo.py`, `scripts/ci/unit-tests.ps1`, `scripts/ci/package-dry-run.ps1`, `fpga/sim/run_core_machine.py`, and the system test `system_k1_panel` (scenario `k1_panel`).
- Icon and platform image in 8-bit greyscale: the frame and the text, with a drop shadow, on a vertical grey gradient (more than 16 grey levels), so the openFPGA library makes 8-bit greyscale PNGs of them instead of 1-bit black and white. The platform image reads "RADIO-86RK" (was "RK86").

## 0.6.1 (2026-11-08)

- The first release (0.5.1 and 0.6.0 were pre-releases): the 0.6.0 core, run on a Pocket (OS 2.7) by the maintainer, with the package and documentation changes below.
- README: photos of the core on a Pocket; credits (Dmitry Tselikov's replica, the Karabas core and its ports, Sergey Kiselev's re-make); Status, Features and Install (upgrade step, the ROM disk in the zip and its CRC check); a new section on running programs from the ROM disk; the English (LAT) key names. The clocks section moved to `fpga/README.md`.
- `fpga/README.md`: the architecture (the machine shared with the Karabas boards, a diagram and a side-by-side table), the clocks, and the Core Settings size limit measured on the hardware (moved from the README).
- `info.txt`: the English key names of the default layout; ROM disk item 4 (Xonix) also overwrites the menu loader. `input.json`: the L button is named "Shift / Ctrl".
- `scripts/k1/monitor_decoder.py` reads `BIOS.BIN` through `RK86_CORE_DIR`.
- `AGENTS.md`: instructions for coding agents.
- `updaters.json` declares the AI tool used to develop the core (`declare_ai`: Claude), for the openFPGA library and the updater tools. `scripts/package.py` checks it and checks the zip as the library's updater reads it.
- `fpga/apf/TEMPLATE-NOTICES.md`: the note says where the core is published (it claimed no public redistribution); `LICENSES.md` lists `APF-NOTICE.txt` in the package.

## 0.6.0 (pre-release, 2026-11-08)

- K1 on-screen keyboard: the real 67-key layout of the Radio-86RK keyboard (64 matrix keys, SS (Shift), US (Ctrl), RUS/LAT), drawn in the 12.288 MHz output stage over the bottom of the picture. The old two-page panel (ABC/FX) is removed.
- One label per key, from the monitor's own key decoder: the active alphabet, the shifted symbols with Shift, the control codes and the function names (VK, ZB, STR, ...) with Ctrl. A held key and the modifiers are lit.
- Colour palettes as a Core Setting, "Keyboard colours": Pink (v1.1), Grey (v1.4), Mono (follows Text colour).
- Buttons with the panel open: L+R opens and closes it; the D-pad selects with auto-repeat; B presses the selected key (held while B is held); A Space, Y ZB, X VK, Start AR2; Select + D-pad the arrows. L tap latches Shift, L held is Ctrl, R is RUS/LAT. The keys are lines of the keyboard matrix, as on the real machine.
- The panel state crosses to the screen clock by a toggle handshake (`pocket_bus_cdc`); the status registers 0x34 and 0x44 have new layouts.
- Checked in simulation (unit tests, the `k1` system scenario with the panel compared with the model) and by a Quartus 25.1std build (timing met in 4 corners). Runs on a Pocket (OS 2.7).
- README: screenshots of the keyboard in the LAT and RUS layouts (frames of the system simulation).

## 0.5.1 (pre-release, 2026-11-08)

- The POC 0.4.0-native on the production core modules (Karabas core PR14, `c7d7a92`): monitor, ROM disk, on-screen keyboard, beeper.
- Button remapping (Core Settings: Keys, Keys on and Escape; the Custom map was dropped after the hardware finding on interact.json size), Reset, Cold boot, Sound, Text colour.
- PLL relock: a watchdog restarts the PLL; the machine keeps running.
- Package: `scripts/package.py` makes the SD zip from a Quartus build; the assets are checked by size, CRC32 and SHA256.
- Documentation: `README.md` (install, controls, clocks, the measured interact.json limit), `fpga/README.md` (bridge map, data slots, build and tests), `LICENSES.md`.
- Checked in simulation and by a Quartus 25.1std build (timing met in 4 corners). First run on a Pocket (OS 2.7): the core starts and works.

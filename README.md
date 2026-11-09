# Radio-86RK for Analogue Pocket

An openFPGA core of the Radio-86RK home computer for the [Analogue Pocket](https://www.analogue.co/pocket).

<p>
  <img src="images/pocket_hello.jpeg" alt="The Radio-86RK monitor prompt on an Analogue Pocket" width="250">
  <img src="images/pocket_onscreen_keyboard.jpeg" alt="The on-screen keyboard on an Analogue Pocket" width="250">
  <img src="images/pocket_tetris.jpeg" alt="Tetris from the ROM disk on an Analogue Pocket" width="250">
</p>

The core is built on these works:

- **The FPGA replica of the Radio-86RK** by Dmitry Tselikov (2010-2011): the CPU (KR580VM80A), DMA, CRT controller, PPI and the video. The [FPGA page of his site](http://bashkiria-2m.narod.ru/index/fpga/0-12) has the original project for the Altera DE1.
- **The [Karabas Go core](https://github.com/andykarpov/karabas-go-core-rk86)**, maintained by Andy Karpov: the replica ported to the Aeon Lite by Dmitriy Schapotschkin, to the ZX UNO by Andy Karpov and to the Karabas Go by Oleh Chastukhin. This core uses its machine, its monitor ROM and its font. The board-neutral machine (`rk86_machine`) comes from the modernization branch of the fork [BarabashkaD/karabas-go-core-rk86](https://github.com/BarabashkaD/karabas-go-core-rk86/tree/c7d7a9288f1fb14e515572e972af3dec34cc5b53), proposed upstream; it is the submodule `cores/karabas-go-core-rk86`.
- **The [Radio-86RK](https://github.com/skiselev/radio-86rk)** by Sergey Kiselev, a modern re-make of the Radio-86RK: the source of the ROM disk (`Software/rom_disk.bin`) and of the 67-key keyboard design and its colours (v1.1, v1.4).

## Status

The latest version is [0.6.2](https://github.com/BarabashkaD/radio86-rk-pocket/releases/tag/v0.6.2): the core of 0.6.1, the first release, with new artwork. It carries the on-screen keyboard K1 of 0.6.0: the full 67-key layout of the real Radio-86RK keyboard. It runs on a Pocket (OS 2.7). Changes: [CHANGELOG.md](CHANGELOG.md).

## Features

- The Radio-86RK machine of the Karabas core: CPU, DMA, CRT controller, PPI, the monitor and the font. The CPU runs at 1.43 MHz, as on the Karabas boards; the original ran at about 1.78 MHz ([How the clocks work](fpga/README.md#how-the-clocks-work)).
- The ROM disk with its menu of programs (included in the package), or any other ROM disk image of up to 32768 bytes, such as the 9 game disks built from the games of the Karabas core ([Game disks](#game-disks)).
- The on-screen keyboard (L+R): the 67 real keys, LAT and RUS layouts, Shift and Ctrl, three colour palettes.
- Button presets for games: cursor keys, digits 7-8-9-6 or 8-4-6-2, WASD, on the D-pad or on A B X Y.
- Beeper sound at 48 kHz, text colour, Reset (keeps memory) and Cold boot in Core Settings.
- The picture at 60 Hz through a frame buffer. If the clock of the screen and sound is disturbed (its PLL loses lock), the program keeps running (checked in simulation).
- Not yet: savestates, sleep, tape images, the Dock USB keyboard.

## Install

1. Download `BarabashkaD.Radio86RK_<version>_<date>.zip` from the [latest release](https://github.com/BarabashkaD/radio86-rk-pocket/releases).
2. Upgrading from 0.5.x: first delete `Settings/BarabashkaD.Radio86RK/` on the SD card (the Core Settings changed).
3. Unzip it onto the root of the Pocket's SD card. It adds `Cores/BarabashkaD.Radio86RK/`, `Assets/radio86rk/BarabashkaD.Radio86RK/`, `Platforms/radio86rk.json` and `Platforms/_images/radio86rk.bin`. The core appears in the Pocket menu as "Radio-86RK" (category Computer).

The monitor (`monitor.bin`) and the font (`font.bin`) in the Assets folder are required. The zip also includes the ROM disk (`romdisk.bin`, GPL-3.0, see [LICENSES.md](LICENSES.md)). It is optional: without it, the window A000-BFFF reads FF. The files are loaded as they are, with no checks: a monitor of up to 2048 bytes, a font of up to 1024 bytes and a ROM disk image of up to 32768 bytes are accepted under their names, for example one of the game disks built by `scripts/romdisk/build_romdisks.py` as `romdisk.bin`. A wrong file just runs as it is, as on the original computer: put the right file back and start the core again.

## Building from source

Clone with `git clone --recursive`, or run `git submodule update --init --recursive` in an existing clone. Then build the package with `pwsh -File scripts/build.ps1`, `python -B scripts/fetch_assets.py` and `python -B scripts/package.py --version <version> --date <YYYY-MM-DD>`.

- FPGA implementation: [fpga/README.md](fpga/README.md) (architecture, clocks, bridge map, data slots, build and tests).
- Licences of all parts: [LICENSES.md](LICENSES.md).

## Running programs from the ROM disk

The ROM disk holds BASIC, EDITOR/ASSEMBLER, EDITOR/DISASSEMBLER, DP/DDT, and the games Xonix, Othello and Tetris. The monitor copies its loader into memory and starts it:

1. Start the core. The monitor shows `РАДИО-86РК` and the prompt `-->`.
2. Open the on-screen keyboard with L+R. Select each key with the D-pad and press it with B.
3. Type `R0,1FF,0` and press CR (Enter; the X button does the same). The monitor copies the first 512 bytes of the ROM disk, the loader, to address 0000.
4. Type `G0` and press CR. The loader starts and shows its menu.
5. Press the digit of a program, for example `6` for Tetris. Close the keyboard with L+R to see the whole screen.

![The ROM disk menu after R0,1FF,0 and G0](images/rom-disk-menu.png)

The picture is the reference frame of the `menu` test of the system simulation (the core's frame matches it), at 2x.

- Tetris first asks for your level (0-7): type a digit. It is played with the digits 7 (left), 8 (rotate), 9 (right), 6 (faster) and Space (drop); S pauses. With Core Settings > Keys = Digits 7-8-9-6 the D-pad sends them (Left 7, Up 8, Right 9, Down 6) and A sends Space.
- Some programs load over the loader, as on the real machine: Xonix runs at 0000, and DP/DDT overwrites it too. To get back to the menu, use Core Settings > Reset, then type `R0,1FF,0` and `G0` again.
- Without `romdisk.bin`, the window A000-BFFF reads FF and `G0` does not show the menu.

## Game disks

`scripts/romdisk/build_romdisks.py` builds the 48 game tape images of the Karabas core (`cores/karabas-go-core-rk86/pk`) into 9 ROM disks: `build/romdisks/romdisk-1.bin` to `romdisk-9.bin`, 32256 bytes each, and `build/romdisks/romdisks.txt`, the list of their keys, games and titles. Each disk starts with a menu loader made from Sergey Kiselev's (`scripts/romdisk/rom_loader_games.asm`, GPL-3.0). The game disks are not in the release zip.

1. Run `python -B scripts/romdisk/build_romdisks.py`.
2. On the SD card, keep `Assets/radio86rk/BarabashkaD.Radio86RK/romdisk.bin` under another name, then copy a game disk there as `romdisk.bin`.
3. Start the core and type `R0,1FF,0` and `G0` as above. The menu `ROM-DISK/32K GAMES <n>/9` lists the games with the keys `0` to `9`, then letters `A` to `Y` for the entries after the tenth (disk 9 uses `A`, `B`, `C`); `Z` clears the memory 0000-73FF. To choose another game, use Core Settings > Reset, then type `R0,1FF,0` and `G0` again. `G7416` alone shows the menu again too, unless the game has overwritten the loader at 7400-75FF.

Tape images do not record where a program starts: each game is started at its load address, as the menu loader does for every entry. A game that needs another start address does not start this way.

## On-screen keyboard

The keyboard opens with L+R at the bottom of the screen. It has the 67 keys of the real Radio-86RK in their real places, and each key shows what it types now: Latin letters in LAT mode, Cyrillic in RUS mode (R switches), the second symbols while Shift is latched, the control names while Ctrl (L) is held. The pictures are frames of the core's video output in the system simulation, at 2x.

English (LAT) layout, the mode after start; the selection on G. The function keys have English names here: CR Enter, BS Backspace, ESC, CLS clear screen, LF line feed, CTL Ctrl, SHF Shift. This README uses these names.

![The on-screen keyboard in LAT mode](images/keyboard-lat.png)

Russian (RUS) layout, after R; the key names are in Russian too: ВК (CR), ЗБ (BS), АР2 (ESC), СТР (CLS), ПС (LF), УС (CTL), СС (SHF):

![The on-screen keyboard in RUS mode](images/keyboard-rus.png)

Core Settings > Keyboard colours: Pink (the v1.1 board), Grey (the v1.4 board: a blue board with grey keys) or Mono (follows Text colour).

## Controls

From the core's `info.txt`:

- On-screen keyboard: the real 67 keys, one label per key from the active alphabet. L+R opens and closes it. Core Settings > Keyboard colours: Pink (v1.1), Grey (v1.4) or Mono (follows Text colour).
- With the keyboard open: D-pad selects a key; B presses it (held while B is held); A Space, Y BS (Backspace), X CR (Enter), Start ESC; Select + D-pad the arrows.
- L tap latches Shift (the next L tap releases it); L held is Ctrl; R is RUS/LAT. These work with the keyboard open or closed.
- The prompt stays on the bottom row, under the keyboard. Press CLS (clear screen) to bring it to the top, or close the keyboard with L+R.
- Keyboard closed: the buttons follow Core Settings > Keys (Cursor, Digits 7-8-9-6, Digits 8-4-6-2, WASD), Keys on (D-pad or A B X Y) and Escape (Select, Start or None).
- Keys on D-pad: A Space, B CR, X BS, Y Y. Keys on A B X Y: X Up, B Down, Y Left, A Right; D-pad Right Space, Down CR, Up BS, Left Y.
- Escape: the chosen button sends ESC, the other sends CR; None: both send CR.
- Core Settings: Reset keeps memory, Cold boot clears it; Sound; Text colour.
- ROM disk: type `R0,1FF,0` then CR, then `G0` then CR for its menu.
- ROM disk items 3 (DP/DDT) and 4 (Xonix) overwrite the menu loader, as on the real machine; use Reset.
- No Memories (savestates) and no sleep.

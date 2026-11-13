# Radio-86RK for Analogue Pocket

An openFPGA core of the Radio-86RK home computer for the [Analogue Pocket](https://www.analogue.co/pocket).

<p>
  <img src="images/pocket_hello.jpeg" alt="The Radio-86RK monitor prompt on an Analogue Pocket" width="250">
  <img src="images/pocket_onscreen_keyboard.jpeg" alt="The on-screen keyboard on an Analogue Pocket" width="250">
  <img src="images/pocket_tetris.jpeg" alt="Tetris from the ROM disk on an Analogue Pocket" width="250">
</p>

## Status

- Latest release: [0.8.2](https://github.com/BarabashkaD/radio86-rk-pocket/releases/tag/v0.8.2) (2026-11-11), run on a Pocket by the maintainer. Changes: [CHANGELOG.md](CHANGELOG.md).
- Not released yet: ROM disk images up to 8 MB in the Pocket's PSRAM, the J6 bank card, the 32 KB mirror, the J6 card menu (`card.bin`) and the FAT16 card (`fatcard.bin`).
- An earlier PSRAM test build (10e6cf4, before the J6 card) ran on a Pocket by the maintainer (2026-11-13).
- The test build 0.8.3-j6-test with these changes ran on a Pocket by the maintainer (2026-11-13): `card.bin` and `fatcard.bin` worked.

## Features

- The original's timing: 16 MHz timebase, CPU 1.778 MHz, 8 MHz dots, 50 Hz frames. CPU, DMA, CRT controller and PPI follow their data sheets; the video DMA takes CPU time as on the original ([fpga/README.md](fpga/README.md#the-16-mhz-machine)).
- ROM disk with a program menu, and 5 game disks (64 KB each) with 48 games, in the package.
- Any ROM disk image up to 8 MB, kept in the Pocket's PSRAM and reloadable from the core's menu. Images above 64 KB are a bank card: a card of whole disks with a card menu, or a FAT16 card of tape files with a file menu. Both are built from source ([ROM disks and cards](#rom-disks-and-cards)).
- On-screen keyboard (L+R): the 67 real keys, LAT and RUS, Shift and Ctrl, three palettes.
- Button presets for games: cursor keys, digits 7-8-9-6 or 8-4-6-2, WASD, on the D-pad or A B X Y.
- Screen: 408 x 300 at 60 Hz, about 25 picture updates per second. Sound: the beeper (INTE), 48 kHz.
- Core Settings: Reset (keeps memory), Cold boot, Sound, Text colour, Keyboard colours.
- Not supported: savestates, sleep, tape images, the Dock USB keyboard.

## Install

1. Download `BarabashkaD.Radio86RK_<version>_<date>.zip` from the [releases](https://github.com/BarabashkaD/radio86-rk-pocket/releases).
2. Upgrading from 0.5.x: delete `Settings/BarabashkaD.Radio86RK/` on the SD card.
3. Unzip onto the SD card root. The core appears as "Radio-86RK" (category Computer).

`Assets/radio86rk/BarabashkaD.Radio86RK/` holds `monitor.bin` and `font.bin` (required), `romdisk.bin` (optional), the game disks `romdisk-1.bin` to `romdisk-5.bin` and `romdisks.txt`. Files are loaded as they are, with no checks (monitor up to 2048 bytes, font 1024, ROM disk 8388608).

## ROM disks and cards

The ROM disk is a memory card on the ports of the second 8255 (the A000-BFFF block; the connector J6 on Sergey Kiselev's re-make): port B and port C give the address, port A reads the byte. The image size picks the card:

| Image size | Card | Example |
|---|---|---|
| up to 32 KB | 32 KB ROM; A15 is not wired, so 8000-FFFF repeat 0000-7FFF | `romdisk.bin` (Kiselev's ROM disk) |
| above 32 KB, up to 64 KB | 64 KB ROM, PC7 = A15 | the game disks |
| above 64 KB, up to 8 MB | J6 bank card: 128 banks of 64 KB | `card.bin`, `fatcard.bin` |

- To change the ROM disk while the core runs: in the core's menu, load the ROM disk slot again and pick a `.bin` file. The machine restarts with memory kept. At the next start `romdisk.bin` is loaded again.
- Without an image every ROM disk byte reads FF. Bytes beyond the end of an image are not cleared: they still hold a longer image's bytes, or whatever an earlier core left in the PSRAM.
- Every disk and card starts the same way: `R0,1FF,0` and CR, then `G0` and CR.

### The ROM disk menu

`romdisk.bin` holds BASIC, EDITOR/ASSEMBLER, EDITOR/DISASSEMBLER, DP/DDT, Xonix, Othello and Tetris.

1. Open the on-screen keyboard (L+R); D-pad selects, B presses.
2. Type `R0,1FF,0` and CR (X), then `G0` and CR. The menu appears.
3. Press the program's digit, e.g. `6` for Tetris. Close the keyboard with L+R.

![The ROM disk menu after R0,1FF,0 and G0](images/rom-disk-menu.png)

- Tetris: level 0-7, then 7 left, 8 rotate, 9 right, 6 faster, Space drop, S pause. Keys = Digits 7-8-9-6 puts them on the D-pad, Space on A.
- Xonix and DP/DDT overwrite the menu loader: Core Settings > Reset, then `R0,1FF,0`, `G0` again.

### The bank card

An image above 64 KB is a J6 bank card. Old programs and the monitor's `R` see the selected bank as a plain 64 KB ROM. A program selects another bank with a port C sequence the monitor never makes (PC7 falls while PC0-PC6 stay high; the bank comes from port B).

- Power-up, a load of the ROM disk slot and Core Settings > Cold boot select bank 0. Core Settings > Reset keeps the bank, as a real card has no reset line on J6.
- A program that writes A002/A003 (for example LORUNNER.GAM and SDEMISE.GAM drive port C for sound), or Ctrl-C during a load, can leave another bank selected. Then Cold boot or load the ROM disk slot again.
- The bank cannot be read back.
- Card images are not in the package; build them (below).
- A reference design of a real card for J6 (never built): [hardware/j6-bank-card.md](hardware/j6-bank-card.md).

### J6 card menu

A card of whole disks: bank 0 holds the card menu, each further bank one disk with its own menu.

```text
git clone --recursive <repo url>
python -B scripts/fetch_assets.py
python -B scripts/romdisk/build_romdisks.py
python -B scripts/romdisk/card.py
```

`card.py` writes `build/card/card.bin` (458752 bytes) and `card.json`: key `0` is `romdisk.bin` (KISELEV), keys `1`-`5` the game disks 1-5. Other disks: `python -B scripts/romdisk/card.py [--out DIR] [--title T] [--name NAME ...] DISK ...` (up to 19 disks, fewer with long names; names up to 16 characters; a disk of up to 64 KB each).

1. Copy `card.bin` to `Assets/radio86rk/BarabashkaD.Radio86RK/` and load it in the ROM disk slot from the core's menu (or copy it as `romdisk.bin`).
2. `R0,1FF,0`, `G0`: the card menu. Press a disk's key: that disk's own menu appears, as if it were the only disk.
3. Core Settings > Reset keeps the chosen disk: `R0,1FF,0`, `G0` shows its menu again.
4. Back to the card menu: Core Settings > Cold boot (clears memory) or load the ROM disk slot again; then `R0,1FF,0`, `G0`.

### FAT16 card

An 8 MB card image that is a FAT16 file system: 52 tape files (the 48 game tapes, and BASIC, EDITOR/ASSEMBLER, EDITOR/DISASSEMBLER and Othello from Kiselev's ROM disk). Bank 0 holds a boot stage, a file menu and a loader.

The builder needs mtools: on Windows the MSYS2 UCRT64 package `mingw-w64-ucrt-x86_64-mtools`, on Linux `apt install mtools`; set `MTOOLS_DIR` to their directory, or put them on PATH.

```text
git clone --recursive <repo url>
python -B scripts/fetch_assets.py
python -B scripts/fatcard/fatcard.py
```

`fatcard.py` writes `build/fatcard/fatcard.bin` (8388608 bytes) and `fatcard.json` (the file list).

1. Copy `fatcard.bin` to `Assets/radio86rk/BarabashkaD.Radio86RK/` and load it in the ROM disk slot from the core's menu.
2. `R0,1FF,0`, `G0`: the menu, 20 files per page, each with its load addresses.
3. Close the on-screen keyboard; Core Settings > Keys = Cursor (another preset sends digits or letters, which the menu ignores).
   - Keys on D-pad: D-pad Up and Down move the marker, Left and Right turn the page, B (CR) or A (Space) runs the file; X (BS) does nothing in the menu.
   - Keys on A B X Y: X (Up) and B (Down) move, Y (Left) and A (Right) turn the page, D-pad Down (CR) or Right (Space) runs; D-pad Up (BS) does nothing.
   - `Z` on the on-screen keyboard zeroes 0000-6BFF.
4. Back to the menu: Core Settings > Reset, then `R0,1FF,0`, `G0` (also while the menu waits for a key). After a Reset during a page change or a load: Cold boot or load the ROM disk slot again first. There is no shortcut like `G7416`.

- A line with `?` instead of addresses is not a tape the loader takes; it does not run. A tape: optional E6, start, end (high byte first), the bytes; it must load into 0000-73FF and be below 64 KB. The checksum is not checked. The loader checks the file, and the FAT chain of every cluster the load needs, before it writes memory; a refusal (`NOT A TAPE`, `BAD FILE`) returns to the monitor's prompt.
- The menu shows the root directory in its order: 8.3 names, up to 511 files; files added with mtools appear too.
- FAT16 only: a FAT12 volume (fewer than 4085 clusters, about 2 MB or less) is not detected by the boot stage and loads wrong data; build images with `fatcard.py`.
- CHESS, PACMAN.GAM and Othello load over the menu (6C00-73FF); `R0,1FF,0`, `G0` loads it again.
- BASIC: the file runs to 2117h with zeros, so RAM 2000-2117 is cleared (Kiselev's loader cleared only 2117h).
- DP/DDT is not on the card yet: it loads to 6400-76FF, over the loader and the monitor's variables.

## Game disks

`romdisk-1.bin` to `romdisk-5.bin` (64 KB each; core 0.8.2 or later, an older core refuses them): the 48 game tapes of the Karabas core, each disk with a menu loader derived from Sergey Kiselev's (`scripts/romdisk/rom_loader_games.asm`, GPL-3.0). `romdisks.txt` and the core's info list the games too.

<!-- game disks: python -B scripts/romdisk/build_romdisks.py --readme -->
**`romdisk-1.bin`** (9 games)

| Key | Game | Title |
|---|---|---|
| 0 | CHERV | Червяк |
| 1 | CHESS | Шахматы |
| 2 | KROK | Крок |
| 3 | SKACHKI | Еще одни скачки |
| 4 | SKVOTCH | Сквош |
| 5 | SOS1 | SOS - 1 вариант |
| 6 | SOS2 | SOS - 2 вариант |
| 7 | TENNIS | Еще один теннис |
| 8 | UDAW | Удав |

**`romdisk-2.bin`** (10 games)

| Key | Game | Title |
|---|---|---|
| 0 | KRESTNO.GAM | Крестики-нолики |
| 1 | KRESTNO.RKR | Крестики-нолики |
| 2 | MAZE | Maze |
| 3 | PACMAN1 | Еще один пакман |
| 4 | PAKET2 | Пакет из 4 игр |
| 5 | PITON | Питон |
| 6 | TETRIS1 | Тетрис - 1 вариант |
| 7 | UTKA | Утка |
| 8 | VOLCANO | Вулкан |
| 9 | XONIX1 | Ксоникс-микрон |

**`romdisk-3.bin`** (10 games)

| Key | Game | Title |
|---|---|---|
| 0 | DIVERSE | Диверсант |
| 1 | LABYRINT | Лабиринт |
| 2 | LEST | Лестница |
| 3 | PACMAN | Еще один pacman |
| 4 | PINGPONG | Еще один пинг-понг |
| 5 | PVO | ПВО-87 |
| 6 | SLAMS | Slams |
| 7 | SPITON | Super Piton (говорящий !) |
| 8 | STRANGER | Strangers |
| 9 | TOCHKI | "Жизнь" с разнотипными точками |

**`romdisk-4.bin`** (9 games)

| Key | Game | Title |
|---|---|---|
| 0 | BOMBER | Бомбардировщик |
| 1 | CIRCUS | Цирк |
| 2 | GFIRE | Cross Fire |
| 3 | GLASS1 | Стакан - 1 вариант |
| 4 | GLASS2 | Стакан - 2 вариант |
| 5 | PAKET | Пакет из 6 игр |
| 6 | XONIX | Ксоникс |
| 7 | XONIXZM | Пакет из 2 игр (xonix, змея) |
| 8 | ZMEI | Змей-горыныч |

**`romdisk-5.bin`** (10 games)

| Key | Game | Title |
|---|---|---|
| 0 | LESTN1 | Лестница-1 |
| 1 | LORUNNER | Lode Runner |
| 2 | PACMAN | Еще один пакман (колобок) |
| 3 | PUSHER | Pusher |
| 4 | RIKOSHET | Рикошет |
| 5 | SDEMISE | Spy's demise |
| 6 | TAPPER | Barmen |
| 7 | TETR2 | Еще один тетрис |
| 8 | TETRIS4 | Тетрис - 4 вариант |
| 9 | ZAGIB | Загибон |
<!-- end of game disks -->

- Load a disk from the core's menu, or copy it as `romdisk.bin`. The [J6 card menu](#j6-card-menu) puts all five on one card.
- `R0,1FF,0`, `G0`: keys `0`-`9`, then `A`-`Y`; `Z` clears 0000-73FF. Another game: Reset, then `R0,1FF,0`, `G0`, or `G7416` if the loader at 7400-75FF is intact.
- Each game starts at its load address; a game that needs another start address does not start.

## On-screen keyboard

L+R opens it at the bottom of the screen. Each key shows what it types now: LAT or RUS (R switches), shifted symbols with Shift latched, control names with Ctrl (L) held.

![The on-screen keyboard in LAT mode](images/keyboard-lat.png)

RUS key names: ВК (CR), ЗБ (BS), АР2 (ESC), СТР (CLS), ПС (LF), УС (CTL), СС (SHF).

![The on-screen keyboard in RUS mode](images/keyboard-rus.png)

## Controls

- Keyboard open: D-pad selects; B presses (held while held); A Space, Y BS, X CR, Start ESC; Select + D-pad the arrows.
- L tap latches Shift (next tap releases); L held is Ctrl; R is RUS/LAT. Open or closed.
- With the keyboard open the prompt stays on the bottom row; CLS brings it to the top.
- Keyboard closed: Core Settings > Keys (Cursor, Digits 7-8-9-6, Digits 8-4-6-2, WASD), Keys on (D-pad or A B X Y), Escape (Select, Start or None).
- Keys on D-pad: A Space, B CR, X BS, Y Y. Keys on A B X Y: X Up, B Down, Y Left, A Right; D-pad Right Space, Down CR, Up BS, Left Y.
- Escape: the chosen button sends ESC, the other CR; None: both CR.

## Building from source

```text
git clone --recursive https://github.com/BarabashkaD/radio86-rk-pocket
cd radio86-rk-pocket
python -B scripts/fetch_assets.py
pwsh -File scripts/build.ps1
python -B scripts/package.py --version <version> --date <YYYY-MM-DD>
```

- Prerequisites (versions, sources, environment variables: [AGENTS.md, section 3](AGENTS.md#3-prerequisites)): Quartus Prime Lite 25.1std with Cyclone V device support (no licence file needed; the bitstream only); Icarus Verilog 13.0 (the simulations and the Python tests); Python 3.14 (standard library only); PowerShell 7; git; mtools (the FAT16 card and its tests). Tools on PATH need no environment variables.
- The bitstream builds on Windows only; the simulations, the Python tests and the package dry run (`pwsh -File scripts/ci/package-dry-run.ps1`) also on Linux, as in CI.
- A GitHub source zip has no submodule (`cores/karabas-go-core-rk86`): clone with `--recursive`. `fetch_assets.py` needs the network once (GitHub).
- The card images are built separately ([J6 card menu](#j6-card-menu), [FAT16 card](#fat16-card)); the FAT16 card and its tests need mtools (`MTOOLS_DIR` or PATH).

Design, build and tests: [fpga/README.md](fpga/README.md). Instructions for coding agents: [AGENTS.md](AGENTS.md).

## Credits

- **Dmitry Tselikov**: the FPGA Radio-86RK replica (2010-2011; [his FPGA page](http://bashkiria-2m.narod.ru/index/fpga/0-12)); his DMA and CRT models are the base of this core's 8257 and 8275.
- **[Karabas Go core](https://github.com/andykarpov/karabas-go-core-rk86)** by Andy Karpov, with ports by Dmitriy Schapotschkin and Oleh Chastukhin: the monitor, font and game tapes. The machine `rk86_machine16` is in the fork [BarabashkaD/karabas-go-core-rk86](https://github.com/BarabashkaD/karabas-go-core-rk86), branch `rk86-16mhz`, `src/rtl/rk86_16/`.
- **Vslav** (1801BM1): the 8080 model, CC-BY 3.0 (<https://creativecommons.org/licenses/by/3.0/>), from the [Apogee core](https://github.com/MiSTer-devel/Apogee_MiSTer) at `4b37da2`.
- **Sorgelig**: the [Apogee core](https://github.com/MiSTer-devel/Apogee_MiSTer) for MiSTer, source of the 8080, 8257 and 8275 models.
- **Sergey Kiselev**: the [Radio-86RK re-make](https://github.com/skiselev/radio-86rk): the ROM disk, the keyboard design and colours, the schematics this core follows with the original's (Радио 1986 No. 4-5).

Licences: [LICENSES.md](LICENSES.md).

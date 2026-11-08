# Radio-86RK for Analogue Pocket

An openFPGA core of the Radio-86RK home computer for the Analogue Pocket. It is built on the machine of the [Karabas core](https://github.com/andykarpov/karabas-go-core-rk86) (`cores/karabas-go-core-rk86`, a submodule), Dmitry Tselikov's FPGA replica of the Radio-86RK.

Status: in development, version 0.6.0, not released. Version 0.6.0 with the new on-screen keyboard runs on a Pocket (OS 2.7).

- FPGA implementation: [fpga/README.md](fpga/README.md) (bridge map, data slots, build and tests)
- Licences of all parts: [LICENSES.md](LICENSES.md)

Clone with `git clone --recursive`, or run `git submodule update --init --recursive` in an existing clone.

## Install

Unzip the package `BarabashkaD.Radio86RK_<version>_<date>.zip` onto the root of the Pocket's SD card. It adds `Cores/BarabashkaD.Radio86RK/`, `Assets/radio86rk/BarabashkaD.Radio86RK/` and `Platforms/radio86rk.json`. The core appears in the Pocket menu as "Radio-86RK". The monitor and the font are required in the Assets folder; the ROM disk is optional (without it, the window A000-BFFF reads FF).

Build the package with `pwsh -File scripts/build.ps1`, `python -B scripts/fetch_assets.py` and `python -B scripts/package.py --version <version> --date <YYYY-MM-DD>`. Details: [fpga/README.md](fpga/README.md). The package is not released yet.

## On-screen keyboard

The keyboard opens with L+R at the bottom of the screen. It has the 67 keys of the real Radio-86RK in their real places, and each key shows what it types now: Latin letters in LAT mode, Cyrillic in RUS mode (R switches), the second symbols while Shift is latched, the control names while Ctrl (L) is held. The pictures are frames of the core's video output in the system simulation, at 2x.

English (LAT) layout, the mode after start; the selection on G:

![The on-screen keyboard in LAT mode](images/keyboard-lat.png)

Russian (RUS) layout, after R; the key names are in Russian too (ВК Enter, ЗБ Backspace, АР2 Esc, СТР clear screen, ПС line feed, УС Ctrl, СС Shift):

![The on-screen keyboard in RUS mode](images/keyboard-rus.png)

## Controls

From the core's `info.txt`:

- On-screen keyboard: the real 67 keys, one label per key from the active alphabet. L+R opens and closes it. Core Settings > Keyboard colours: Pink (v1.1), Grey (v1.4) or Mono (follows Text colour).
- With the keyboard open: D-pad selects a key; B presses it (held while B is held); A Space, Y ZB (Backspace), X VK (Enter), Start AR2 (Esc); Select + D-pad the arrows.
- L tap latches Shift (the next L tap releases it); L held is Ctrl; R is RUS/LAT. These work with the keyboard open or closed.
- The prompt stays on the bottom row, under the keyboard. Press STR (clear screen) to bring it to the top, or close the keyboard with L+R.
- Panel closed: the buttons follow Core Settings > Keys (Cursor, Digits 7-8-9-6, Digits 8-4-6-2, WASD), Keys on (D-pad or A B X Y) and Escape (Select, Start or None).
- Keys on D-pad: A Space, B VK, X ZB, Y Y. Keys on A B X Y: X Up, B Down, Y Left, A Right; D-pad Right Space, Down VK, Up ZB, Left Y.
- Escape: the chosen button sends AR2 (Esc), the other sends VK; None: both send VK.
- Core Settings: Reset keeps memory, Cold boot clears it; Sound; Text colour.
- ROM disk: type `R0,1FF,0` then Enter, then `G0` then Enter for its menu.
- ROM disk item 3 (DP/DDT) overwrites the menu loader, as on the real machine; use Reset.
- No Memories (savestates) and no sleep.

## Measured Pocket limit: interact.json

On Pocket OS 2.7 the first version of the core did not start: the Pocket stopped right after opening interact.json (the log shows Opening /Cores/BarabashkaD.Radio86RK/interact.json, then the error; a working core goes on to `video.json`). Variants of the file, tried on the hardware:

| file | items | list options in total | result |
|---|---|---|---|
| empty | 0 | 0 | loads |
| 5 basic items | 5 | 7 | loads |
| 5 basic + 2 Map lists of 16 | 7 | 39 | loads |
| 15 items, Map lists cut to 2 options | 15 | 27 | loads |
| a working core (Vector06C) | 12 | 66 | loads |
| 15 items, Map lists of 9 options | 15 | 97 | fails |
| the first shipped file | 15 | 167 | fails |

The documented limits (16 items, 16 options per list, 23-character names) were all met, so the Pocket has an undocumented limit on the total size of the lists, somewhere between 66 and 97 options. Core Settings of this core are therefore kept small (7 items, 11 list options in total; scripts/tests/test_package.py checks at most 20 options).

## How the clocks work

```text
Pocket (APF) clk_74a = 74.25 MHz
 |
 +--> clock enable: 160 of every 297 ticks ----> 40 MHz timebase (on average exactly 40.000 MHz)
 |     the Radio-86RK machine, the memory, the        |
 |     keyboard, the ROM disk, the bridge             +--> CPU: one step every 28  = 40 / 28 = about 1.43 MHz
 |                                                    +--> screen: one dot every 3 = 13.33 MHz
 |                                                    +--> a frame every 959 760   = 41.7 frames per second
 |                                                                  |
 |                                                              frame buffer (two banks)
 |                                                                  |
 +--> PLL ---> clk_core_12288 = 12.288 MHz ------------> Pocket screen: 60 Hz, 408 x 300 shown
                                         ------------> sound: 48 kHz I2S (the beeper)
```

- **The machine runs on `clk_74a`,** the 74.25 MHz clock the Pocket gives every core, not on a PLL clock. It advances only when a clock enable is high: on 160 of every 297 ticks. On average that is exactly 74.25 × 160 / 297 = **40 MHz**, the master timebase of the Karabas core; on the Karabas boards it is a real 40 MHz clock with the enable always on.
  - Programs run at exactly the Karabas core's speed, with no drift.
  - Single steps are 13.5 or 26.9 ns apart instead of an even 25 ns. Nothing outside sees that jitter: the picture is re-timed by the frame buffer, and the sound is sampled at 48 kHz.
- **From the 40 MHz timebase** the core derives the CPU, the screen dots and the frames (the Karabas core's `docs/integration.md`, section 2). The CPU takes a step every 28 timebase steps: **40 / 28 ≈ 1.43 MHz**.
  - The original Radio-86RK's CPU ran at about **1.78 MHz**, so the replica's CPU is about 20% slower. Why, how to reach the original speed, and a configurable speed with turbo modes are planned follow-up tasks.
- **The PLL is used only for the Pocket's screen and sound.** It makes 12.288 MHz, which APF requires for the 60 Hz video output and the 48 kHz audio. A frame buffer with two banks sits between the machine's 41.7 Hz frames and the 60 Hz screen.
- **If the PLL loses lock** (rare: a power transient, ESD), only the picture and sound stop. The machine, its memory and the running program go on. A watchdog restarts the PLL if it does not lock again by itself within 28 ms, and the picture comes back with the program still running.

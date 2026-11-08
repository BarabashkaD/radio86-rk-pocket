# Changelog

## 0.6.0 (in development)

- K1 on-screen keyboard: the real 67-key layout of the Radio-86RK keyboard (64 matrix keys, SS (Shift), US (Ctrl), RUS/LAT), drawn in the 12.288 MHz output stage over the bottom of the picture. The old two-page panel (ABC/FX) is removed.
- One label per key, from the monitor's own key decoder: the active alphabet, the shifted symbols with Shift, the control codes and the function names (VK, ZB, STR, ...) with Ctrl. A held key and the modifiers are lit.
- Colour palettes as a Core Setting, "Keyboard colours": Pink (v1.1), Grey (v1.4), Mono (follows Text colour).
- Buttons with the panel open: L+R opens and closes it; the D-pad selects with auto-repeat; B presses the selected key (held while B is held); A Space, Y ZB, X VK, Start AR2; Select + D-pad the arrows. L tap latches Shift, L held is Ctrl, R is RUS/LAT. The keys are lines of the keyboard matrix, as on the real machine.
- The panel state crosses to the screen clock by a toggle handshake (`pocket_bus_cdc`); the status registers 0x34 and 0x44 have new layouts.
- Checked in simulation (unit tests, the `k1` system scenario with the panel compared with the model) and by a Quartus 25.1std build (timing met in 4 corners). Runs on a Pocket (OS 2.7).
- README: screenshots of the keyboard in the LAT and RUS layouts (frames of the system simulation).

## 0.5.1 (in development)

- The POC 0.4.0-native on the production core modules (Karabas core PR14, `c7d7a92`): monitor, ROM disk, on-screen keyboard, beeper.
- Button remapping (Core Settings: Keys, Keys on and Escape; the Custom map was dropped after the hardware finding on interact.json size), Reset, Cold boot, Sound, Text colour.
- PLL relock: a watchdog restarts the PLL; the machine keeps running.
- Package: `scripts/package.py` makes the SD zip from a Quartus build; the assets are checked by size, CRC32 and SHA256.
- Documentation: `README.md` (install, controls, clocks, the measured interact.json limit), `fpga/README.md` (bridge map, data slots, build and tests), `LICENSES.md`.
- Checked in simulation and by a Quartus 25.1std build (timing met in 4 corners). First run on a Pocket (OS 2.7): the core starts and works.

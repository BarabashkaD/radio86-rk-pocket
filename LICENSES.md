# Licences

One row per part. Nothing here is legal advice; open items are marked.

| Part | Where | Licence | Note |
|---|---|---|---|
| Our code: `fpga/rtl`, `fpga/quartus`, `fpga/sim`, `scripts/`, `package/` | this repository | BSD-3-Clause, `LICENSE` | Includes modules from the earlier proof of concept of this core. |
| The Karabas core (Radio-86RK machine, `rk86_machine`, `rk86_video`, CPU, DMA, CRT, PPI) | submodule `cores/karabas-go-core-rk86` | modified BSD, `src/LICENSE.TXT` of the core | Dmitry Tselikov (2011), ported by Andy Karpov and Oleh Chastukhin. Copied into the SD package as `LICENSE-karabas-core.txt`. |
| APF template files | `fpga/apf/`, `fpga/core/` | Analogue EULA notices in the files, `fpga/apf/TEMPLATE-NOTICES.md` | open-fpga/core-template da3a021. The notices stay with these files only; our logic stays out of `core_top.v` beyond instances and wiring. |
| ROM disk `romdisk.bin` | slot 2, not committed | GPL-3.0 (skiselev/radio-86rk, https://github.com/skiselev/radio-86rk; Sergey Kiselev, the ROM disk and the keyboard design) | Open: the provenance of the program binaries inside is not established. Public distribution is decided at release. The licence text goes into the package as `LICENSE-romdisk.txt`. |
| Monitor `monitor.bin` | core `src/roms/BIOS.BIN` | in the core repository (modified BSD) | Original Radio-86RK monitor. |
| Font `font.bin` | core `src/roms/FONT.BIN` | in the core repository (modified BSD) | Also built into the bitstream for the on-screen keyboard: `fpga/rtl/native_font.vh`. |
| Font in the bitstream | `fpga/rtl/native_font.vh` | as the font above | The keyboard panel (`pocket_k1_panel.v`) draws with this table, not with the slot-1 font. |
| `declare_ai` in `updaters.json` | not yet written | openFPGA inventory rule | Open, to be decided before 1.0.0. There is no `updaters.json` and no inventory entry in version 1. |

The SD package contains `LICENSE.txt` (ours), `LICENSE-karabas-core.txt` and `LICENSE-romdisk.txt` in `Cores/BarabashkaD.Radio86RK/`.

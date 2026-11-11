# Licences

One row per part. Not legal advice; open items are marked.

| Part | Where | Licence | Note |
|---|---|---|---|
| Our code: `fpga/rtl`, `fpga/quartus`, `fpga/sim`, `scripts/`, `package/` | this repository | BSD-3-Clause, `LICENSE` | Except the games menu loader (next row). |
| Games menu loader `scripts/romdisk/rom_loader_games.asm` | this repository | GPL-3.0, `scripts/romdisk/COPYING` | Derived from Sergey Kiselev's `Software/src/rom_loader.asm` (skiselev/radio-86rk at `c5e9cb7`); changes in its header. The first 512 bytes of every game disk. |
| Game disks `romdisk-1.bin` to `romdisk-9.bin` | built by `scripts/package.py` from the Karabas core's `pk/`, in the package's Assets folder; not committed | loader GPL-3.0; games as in the Karabas core's `pk/` | Open: provenance and licences of the games (a 1999 collection). |
| Karabas core fork: monitor, font, `pk/`, `src/rtl/rk86_16/` | submodule `cores/karabas-go-core-rk86` | modified BSD, the core's `src/LICENSE.TXT` | Dmitry Tselikov (2011), ported by Andy Karpov and Oleh Chastukhin. In the package as `LICENSE-karabas-core.txt`. The Pocket builds only `src/rtl/rk86_16/` (next rows). |
| 8080 model `k580vm80a.v` | the fork's `src/rtl/rk86_16/`, in the bitstream | CC-BY 3.0, <https://creativecommons.org/licenses/by/3.0/>; attribution required | Vslav (1801BM1), 2014, file header kept. From MiSTer-devel/Apogee_MiSTer (<https://github.com/MiSTer-devel/Apogee_MiSTer>) `rtl/k580vm80a.v` at `4b37da2`; line endings changed only. Credited in `README.md` and the Credits line of `info.txt`. |
| 8257 and 8275 models `k580vt57.v`, `k580vg75.v` | the fork's `src/rtl/rk86_16/`, in the bitstream | modified BSD, the core's `src/LICENSE.TXT` | Dmitry Tselikov (2011) with Sorgelig's changes, from Apogee_MiSTer at `4b37da2`; rewritten to the Intel data sheets (changes in the headers). |
| `k580vv55.v`, `rk86_clocks16.v`, `rk86_video16.v`, `rk86_machine16.v`, `rk86_machine16.prj` | the fork's `src/rtl/rk86_16/` and `src/`, in the bitstream | modified BSD, the core's `src/LICENSE.TXT` | New in the fork: 8255, 8224 and К155ИЕ4 clocks, video path, machine. |
| APF template files | `fpga/apf/`, `fpga/core/` | Analogue notices in the files, `fpga/apf/TEMPLATE-NOTICES.md` | open-fpga/core-template da3a021. Our logic stays out of `core_top.v` beyond instances and wiring. |
| ROM disk `romdisk.bin` | slot 2, not committed | GPL-3.0 (skiselev/radio-86rk, <https://github.com/skiselev/radio-86rk>) | Open: provenance of the programs inside. Public distribution decided at release. In the package as `LICENSE-romdisk.txt`. |
| Monitor `monitor.bin` | the fork's `src/roms/BIOS.BIN` | modified BSD (core repository) | The original Radio-86RK monitor. |
| Font `font.bin` | the fork's `src/roms/FONT.BIN` | modified BSD (core repository) | Also in the bitstream as `fpga/rtl/native_font.vh` (the K1 panel). |
| `declare_ai` | `package/core/updaters.json` | openFPGA library field | `["Claude"]`: developed with Claude (Anthropic) as a coding agent. |

The package's `Cores/BarabashkaD.Radio86RK/` holds `LICENSE.txt`, `LICENSE-karabas-core.txt`, `LICENSE-romdisk.txt` and `APF-NOTICE.txt`. The CC-BY 3.0 attribution of the 8080 model is the Credits line of `info.txt`.

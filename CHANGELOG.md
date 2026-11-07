# Changelog

## 0.5.1 (in development)

- The POC 0.4.0-native on the production core modules (Karabas core PR14, `c7d7a92`): monitor, ROM disk, on-screen keyboard, beeper.
- Button remapping (Core Settings: Keys, Keys on and Escape; the Custom map was dropped after the hardware finding on interact.json size), Reset, Cold boot, Sound, Text colour.
- PLL relock: a watchdog restarts the PLL; the machine keeps running.
- Package: `scripts/package.py` makes the SD zip from a Quartus build; the assets are checked by size, CRC32 and SHA256.
- Documentation: `fpga/README.md` (bridge map, data slots), `docs/asset-policy.md`, `docs/licences.md`, `docs/hardware-checklist.md`.
- Checked in simulation and by a Quartus 25.1std build (timing met in 4 corners, see `docs/quartus-warning-audit.md`). Not yet run on hardware.

# POC frames for the parity check (spec 9.7)

One-bit 408 x 300 frames written by $writememh in the POC simulations (POC commit a6373ed).

| File | POC run | SHA256 |
|---|---|---|
| monitor-boot.hex | pocket-machine-functional-r3/frame.hex: the stock monitor after boot | bfd2f2c3e0c15629982b819a72eb45c4684121e235a1ed48d218da6172518519 |
| rom-disk-menu.hex | pocket-handheld-v040-full-r3/cart-menu-frame.hex: the ROM disk menu after R0,1FF,0 and G0 | d29d433da97cc31133a9fc7d5a44bf76ed40eb4f2d1819d25b2967be42d47bea |

The POC CRT had an added reset, so the frames are compared by content (frame_compare.py: equal outside one character cell, the cursor), not by frame number.

The on-screen keyboard panel is not visible in the ROM disk menu frame (cartridge-menu.png shows only the 408 x 300 text screen, no panel).
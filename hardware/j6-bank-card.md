# J6 bank card: reference design

**Reference design, never built or tested.** Not built, not breadboarded, not simulated at the gate or analogue level. The core on the Pocket models the card's rule (a one-tick event in `fpga/rtl/pocket_cart_ppi.v`), not this circuit; simulation of the core is not a result for this card. The open electrical items are listed at the end.

A ROM disk card for the Radio-86RK's second 8255 (the A000-BFFF block; on Sergey Kiselev's re-make 1.4 the 26-pin connector J6) that holds up to 8 MB. The computer is unchanged: hardware, monitor, 8255. J6 carries only the 24 port lines, +5 V and GND (no reset, no clock, no bus signals), so all new logic is on the card.

## Address

| Card address | Source |
|---|---|
| A0-A7 | port B pins |
| A8-A15 | port C pins |
| A16-A22 | bank latch Q0-Q6 |
| D0-D7 | to port A |

128 banks of 64 KB = 8 MB. Port A always carries the memory byte (no output enable). Reads have no side effects: the monitor's `R` (FA68), Kiselev's loader and the games loaders read any of the 65536 addresses of the current bank as from a plain 64 KB ROM.

The FAT16 card image of this repository (`scripts/fatcard/`, the README's FAT16 card) fills all 128 banks of the same card with one FAT16 file system; its software is in bank 0 and uses only reads and the bank-select event below.

## The bank-select event

**PC7 falls and, after the fall, PC0-PC6 are all high** (port C FF to 7F; a port C write of 7F over 80..FE fires too). At that moment the bank latch takes the port B pins: PB0-PB6 = bank (A16-A22); PB7 is latched but unused (reserved: a later write-mode flag, or a 16 MB card).

Regular access never makes it. The monitor's `R` (FA68) sets the mode once per call (ports B and C = 00), then writes port B and port C for every byte: port C only stays, goes up by one, drops to 00 (mode set, all bits at once) or wraps FF to 00 (an `R` whose end is below its start). An 8255 reset turns the ports into inputs: the lines go high (pull-ups), PC7 rises, no event.

The bank number cannot be read back; the software that sets it keeps it in RAM.

Bank-select routine (computer side):

```text
SELBK:  MOV  B,A          ; A = bank 0..127
        MVI  A,90h
        STA  0A003h       ; mode: A in, B and C out, all 00
        MVI  A,0FFh
        STA  0A002h       ; port C = FF
        MOV  A,B
        STA  0A001h       ; port B = bank
        MVI  A,0Eh
        STA  0A003h       ; bit reset PC7: port C FF -> 7F, the card latches port B
        RET
```

Reading any 23-bit address: `SELBK` with A16-A22, then FA68 with A0-A15. A copy across a 64 KB boundary is two calls.

## Reset

- Power-on clears the bank to 0 (an RC reset on the card).
- The computer's reset button does not reach the card (no reset on J6): the bank survives it, the selected disk stays selected.
- Back to bank 0 by hand: the monitor's `M` on A003 (90), A002 (FF), A001 (00), A003 (0E), or by power.

## Schematic

```text
  PB0..PB7 ──┬────────────────────────────► MEM A0..A7
             └────────► U5 74HCT273 D0..D7   Q0..Q6 ──► MEM A16..A22 ; Q7 spare
                                             CLK ◄── U4 Q ; /MR ◄── power-on reset
  PC0..PC6 ──┬────────────────────────────► MEM A8..A14
             └► U2 74HCT30 (8th input +5V) ─► /ALL ─► U3a inv ─► ALL ─► U4 D
  PC7 ───────┬────────────────────────────► MEM A15
             ├► U3b inv ──────────────────► U4 /CLR      (Q held 0 while PC7 high)
             └► R 1k ─┬─► U3c Schmitt inv ─► U4 CLK      (rises ~1 us after PC7 falls)
                      C 1 nF to GND
  PA0..PA7 ◄───────────────────────────────  MEM D0..D7
  MEM /CE, /OE = GND; /WE = +5V (10k). Power-on reset: RC ─► U3d, U3e ─► U5 /MR.
  10k pull-ups on PB0-7, PC0-7. U3 = 74HCT14, U4 = 74HCT74 (half).
  U4 /PRE = +5 V. Unused U3/U4 inputs (U3f, the other half of U4) tied to GND or +5 V.
```

- U4 /PRE must be tied to +5 V: a floating HCT /PRE can set Q at random and latch a bank by itself.

- Trigger: PC7 falls with PC0-PC6 high; the delayed clock samples ALL = 1, Q rises, U5 latches port B.
- Counting up (7E to 7F, 7F to 80): PC7 does not fall, U4 is not clocked. Mode set from FFxx: PC0-PC6 fall with PC7; by the delayed edge ALL is 0, Q stays 0.
- HCT parts: the КР580ВВ55А is NMOS with TTL output levels (VOH min 2.4 V).
- RC delay 0.5-2 us: longer than the bit skew of one 8255 write, and meant to end before the next port A read; how soon that read comes depends on the program (open items, RC delay).

## J6 pin-out

From the Kiselev 1.4 netlist (<https://github.com/skiselev/radio-86rk>); check it against the board before building.

| Pins | Signals |
|---|---|
| 1, 3, 5, ..., 15 (odd) | PC0-PC7 |
| 2, 4, 6, ..., 16 (even) | PA0-PA7 |
| 17, 19, 21, 23 | PB7, PB6, PB5, PB4 |
| 18, 20, 22, 24 | PB0, PB1, PB2, PB3 |
| 25 | +5 V (through F1) |
| 26 | GND |

## Open items (to settle before a PCB)

- **Memory part and supply**: 5 V 8 MB parallel parts are rare: two 5 V 4 MB flashes with A22 on /CE, or one 3.3 V 64 Mbit flash with level shifters (then a 3.3 V regulator and the HCT levels on its outputs).
- **F1 current**: the card's supply comes through the fuse F1 on J6 pin 25; its rating against the memory's and the logic's current is not checked.
- **RC delay**: the 1 k / 1 nF values and the delay (about 1-2.3 us with the 74HCT14 thresholds for tau = 1 us) are to be confirmed on a scope on the RC node, on a breadboard. The margin is thin: a program that reads port A right after the PC7 bit reset (STA, then MOV A,M) reads it about 3 us later at 1.78 MHz, against a delay of up to about 2.3 us.
- **PC7 load**: the RC hangs on PC7, which also drives MEM A15 and U3b. An NMOS КР580ВВ55А sinks only about 1.7 mA at VOL 0.45 V; discharging 1 nF through 1 k draws more at first. Buffer PC7 through a Schmitt inverter before the RC, or use a higher R and a lower C.
- **Port A as output**: memory /OE is tied to GND, so a program that makes port A an output (for example mode 80h, J6 used for another device) drives against the memory outputs. Series resistors on PA0-PA7, or a note for users.
- **Power-on reset vs the machine's reset**: the card's own RC power-on reset clears the bank; the computer's reset does not reach J6. Whether the card's RC reset ends after the supply and the 8255 are stable, and how the card behaves on a brief supply dip, is not checked.
- **Writes**: not designed (PB7 reserved).

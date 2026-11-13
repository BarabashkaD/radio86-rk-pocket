"""Python model of the J6 bank card: a ROM disk on the second 8255 (A000-BFFF) with a bank latch.

Follows the fork's k580vv55.v for the port logic (mode 0 only). Card type by image size:
up to 32768 bytes the 32 KB mirror {0, PC6..PC0, PB}; up to 65536 bytes {0, PC7..PC0, PB};
up to 8388608 bytes the bank card {bank[6:0], PC7..PC0, PB}.

Bank select event: PC7 falls and, after the fall, PC0-PC6 are all high; the bank latch takes PB0-PB6.
The bank is cleared by card_reset() only (power-up, slot load, Cold boot), not by a machine reset.
"""

MAX_IMAGE = 8 * 1024 * 1024


class CardPpi:
    def __init__(self, image):
        self.image = bytes(image)
        n = len(self.image)
        if n > MAX_IMAGE:
            raise ValueError('image of %d bytes is above %d' % (n, MAX_IMAGE))
        self.kind = 'mirror' if n <= 32768 else 'plain' if n <= 65536 else 'bank'
        self.bank = 0
        self._reset_ports()

    def _reset_ports(self):
        """8255 reset: all ports inputs, latches 00, pins FF."""
        self.latch_a = self.latch_b = self.latch_c = 0
        self.oe_b = 0
        self.oe_c = 0
        self._prev_pc = 0xFF

    def card_reset(self):
        self.bank = 0

    @property
    def pb(self):
        return (self.oe_b & self.latch_b) | (~self.oe_b & 0xFF)

    @property
    def pc(self):
        return (self.oe_c & self.latch_c) | (~self.oe_c & 0xFF)

    def _event(self):
        new = self.pc
        if self._prev_pc & 0x80 and not new & 0x80 and new & 0x7F == 0x7F and self.kind == 'bank':
            self.bank = self.pb & 0x7F
        self._prev_pc = new

    def write(self, reg, value):
        value &= 0xFF
        reg &= 3
        if reg == 0:
            self.latch_a = value
        elif reg == 1:
            self.latch_b = value
        elif reg == 2:
            self.latch_c = value
            self._event()
        elif value & 0x80:  # mode set
            if value & 0x64:  # bits 6, 5 (group A mode) and 2 (group B mode)
                raise ValueError('only mode 0 is modelled: control %02X' % value)
            self.latch_a = self.latch_b = self.latch_c = 0
            self.oe_b = 0 if value & 0x02 else 0xFF
            self.oe_c = (0 if value & 0x08 else 0xF0) | (0 if value & 0x01 else 0x0F)
            self._event()
        else:  # bit set/reset of port C
            bit = (value >> 1) & 7
            self.latch_c = (self.latch_c & ~(1 << bit) & 0xFF) | ((value & 1) << bit)
            self._event()

    def rom_address(self):
        pc = self.pc
        if self.kind == 'mirror':
            pc &= 0x7F
        a = pc << 8 | self.pb
        if self.kind == 'bank':
            a |= self.bank << 16
        return a

    def read_a(self):
        # Bytes beyond the image read FF here; the RTL reads stale PSRAM there, so never compare the
        # model and the RTL beyond an image.
        a = self.rom_address()
        return self.image[a] if a < len(self.image) else 0xFF

    def read(self, reg):
        reg &= 3
        if reg == 0:
            return self.read_a()
        if reg == 1:
            return self.pb
        if reg == 2:
            return self.pc
        return 0xFF


def fa68_copy(card, hl, de):
    """The monitor's FA68 (R) on the card: mode set 90h, then HL..DE inclusive with a 16-bit wrap
    (the byte where HL == DE is the last one, so DE = HL - 1 copies 65536 bytes). Returns the bytes."""
    out = bytearray()
    card.write(3, 0x90)
    hl &= 0xFFFF
    de &= 0xFFFF
    while True:
        card.write(1, hl & 0xFF)
        card.write(2, hl >> 8)
        out.append(card.read_a())
        if hl == de:
            return bytes(out)
        hl = (hl + 1) & 0xFFFF

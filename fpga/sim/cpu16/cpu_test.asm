; The CPU test program of tb_cpu16 (fpga/sim/unit/tb_cpu16.v; spec 9.1-2): it replaces the monitor
; (F800-FFFF) in rk86_machine16. Assembled by scripts/romdisk/asm8080.py (run_sim.py cpu16_inputs).
;
; Start-up (GLUE-11, GLUE-12): after RESET the monitor answers every address, RAM and every device off,
; until the first read with A15 = 1. The first bytes run at 0000: a keyboard 8255 mode word (80h: port A
; an output) and a RAM write (55h to 0020), both of which must be lost; then JMP START, whose fetch at
; F8xx ends start-up as the monitor's first JMP does.
; From START: the 8275 and the 8257 programmed as the monitor does (FACF-FAFA), then the phases while the
; DMA takes one HOLD period per character. Phase n stores its result at 0000 + n: 00 = pass, else the
; number of the first failing case; START sets every result to FF first, so a phase that never ran fails.
; The end writes A5 to 0010 and loops at DONE.
;   1  RAM: the pattern i XOR 5Ah at 0100-01FF written with STAX, read with LDAX (case 1), MOV A,M (2)
;   2  PUSH B, D, H, PSW and POP B, D, H, PSW (each pair gets another's value); the registers and SP saved
;      at 0044-004D and compared (cases 1-10: L H E D C B, the flag byte, A, SP low, SP high); CALL / RET
;      nested 8 deep (11 the return count, 12 SP at the deepest call, 13 SP after the returns)
;   3  the flags: 20 cases with fixed operands, A and the flag byte S Z 0 AC 0 P 1 CY checked (CHK)
;   4  the keyboard 8255: port A an input before the mode word (FF, case 1), 8Ah (the monitor's mode, F836):
;      the output latch reset by the mode word (00, case 2), written and read back (3Ch case 3, C3h case 4)
;   5  EI, NOPs, DI: INTE checked by the testbench (the result byte only marks that the phase ran); then
;      about a frame of delay, so that the testbench's underrun check spans a whole frame before phase 6
;   6  the monitor's tape exit (FC0F-FC27, with the 8257 stopped first): E008 80, E004 D0 76, E005 23 49,
;      C001 27, C001 E0 (Preset Counters), E008 A4; about 40 000 Φ; Load Cursor (FD8C) C001 80, C000 00,
;      C000 00; about 3 frames (the testbench logs the address of row 0 in each frame)
;   7  a DMA block in the monitor ROM (review A I2: the DMA reads by the system address, so E000-FFFF
;      is the monitor during AEN too): the 8257 stopped, channel 2 at DMATAB (128 bytes of 00-7F, no
;      8275 special codes; count 407Fh, autoload), A4h, about 2.3 frames; the testbench checks every
;      byte the 8275 takes from E000-FFFF against the program byte at its address. Then 80h, 76D0,
;      4923, A4h again, as the monitor's video init (FACE) programs the 8257
RES     EQU 0000H           ; results: RES + phase
MARK    EQU 0010H           ; A5 at the end
NESTSP  EQU 0040H           ; phase 2: SP at the deepest call
SAVE    EQU 0044H           ; phase 2: the registers after the pops
STACK   EQU 7600H

        ORG 0F800H
        MVI A,80H           ; start-up: a mode word to the keyboard 8255 (must be lost)
        STA 8003H
        MVI A,55H           ; start-up: a RAM write (must be lost)
        STA 0020H
        JMP START           ; the fetch at F8xx (A15 = 1) ends start-up

START:  LXI SP,STACK
        MVI A,0FFH          ; every result "not run"
        STA RES+1
        STA RES+2
        STA RES+3
        STA RES+4
        STA RES+5
        STA RES+6
        STA RES+7
; the 8275 and the 8257 as the monitor (FACF-FAFA): Reset 4D 1D 99 93, Start Display 27, the IR wait,
; then the 8257 mode 80, channel 2 address 76D0, count 4923, mode A4
        LXI H,0C001H
        MVI M,00H
        DCX H
        MVI M,4DH
        MVI M,1DH
        MVI M,99H
        MVI M,93H
        INX H
        MVI M,27H
        MOV A,M
IRW:    MOV A,M
        ANI 20H
        JZ IRW
        LXI H,0E008H
        MVI M,80H
        MVI L,04H
        MVI M,0D0H
        MVI M,76H
        INR L
        MVI M,23H
        MVI M,49H
        MVI L,08H
        MVI M,0A4H

;---------------- phase 1: RAM pattern
        LXI D,0100H
P1W:    MOV A,E
        XRI 5AH
        STAX D
        INR E
        JNZ P1W
P1R:    MOV A,E             ; E is 00 again: D E = 0100
        XRI 5AH
        MOV B,A
        LDAX D
        CMP B
        JNZ P1F1
        INR E
        JNZ P1R
        LXI H,0100H
P1M:    MOV A,L
        XRI 5AH
        CMP M
        JNZ P1F2
        INR L
        JNZ P1M
        XRA A
        JMP P1E
P1F1:   MVI A,1
        JMP P1E
P1F2:   MVI A,2
P1E:    STA RES+1

;---------------- phase 2: PUSH / POP, CALL / RET
        LXI B,1122H
        LXI D,3344H
        LXI H,0A5D7H        ; A A5, flags D7 (S Z AC P CY and bit 1)
        PUSH H
        POP PSW
        LXI H,5566H
        PUSH B
        PUSH D
        PUSH H
        PUSH PSW
        LXI B,0
        LXI D,0
        LXI H,0
        XRA A
        POP B               ; B A5, C D7 (the PSW)
        POP D               ; D 55, E 66 (H L)
        POP H               ; H 33, L 44 (D E)
        POP PSW             ; A 11, flags 22: S Z AC P CY 0, read back 02 (bit 5 always 0, bit 1 always 1)
        SHLD SAVE           ; 0044 L, 0045 H
        XCHG
        SHLD SAVE+2         ; 0046 E, 0047 D
        MOV H,B
        MOV L,C
        SHLD SAVE+4         ; 0048 C, 0049 B
        PUSH PSW
        POP H
        SHLD SAVE+6         ; 004A flags, 004B A
        LXI H,0
        DAD SP
        SHLD SAVE+8         ; 004C 004D SP, back at STACK
        LXI H,SAVE
        LXI D,P2T
        MVI C,1
P2C:    LDAX D
        CMP M
        JNZ P2F
        INX H
        INX D
        INR C
        MOV A,C
        CPI 11
        JNZ P2C
        MVI B,8             ; CALL / RET nested 8 deep
        MVI C,0
        CALL NEST
        MOV A,C
        MVI C,11
        CPI 8
        JNZ P2F
        MVI C,12
        LHLD NESTSP         ; SP at the deepest call: STACK - 2 * 8
        MOV A,H
        CPI 75H
        JNZ P2F
        MOV A,L
        CPI 0F0H
        JNZ P2F
        MVI C,13
        LXI H,0
        DAD SP
        MOV A,H
        CPI 76H
        JNZ P2F
        MOV A,L
        CPI 00H
        JNZ P2F
        MVI C,0
P2F:    MOV A,C
        STA RES+2
        LXI SP,STACK        ; a failed case may leave words on the stack
        JMP PH3

P2T:    DB 44H,33H,66H,55H,0D7H,0A5H,02H,11H,00H,76H

NEST:   DCR B
        JZ NBOT
        CALL NEST
        INR C
        RET
NBOT:   LXI H,0
        DAD SP
        SHLD NESTSP
        INR C
        RET

;---------------- phase 3: the flags. Each case: C = the case number, A and the flags from H L via
; PUSH H / POP PSW, the operation, CALL CHK with the expected A and flag byte after the CALL.
PH3:    XRA A
        STA RES+3
        MVI C,1             ; ADD 2E + 74 = A2: S, AC (E + 4 carries out of bit 3), P odd
        LXI H,2E02H
        PUSH H
        POP PSW
        MVI B,74H
        ADD B
        CALL CHK
        DB 0A2H,92H
        MVI C,2             ; ADD 80 + 80 = 00: Z, P even, CY
        LXI H,8002H
        PUSH H
        POP PSW
        MVI B,80H
        ADD B
        CALL CHK
        DB 00H,47H
        MVI C,3             ; ADC FF + 00 + CY = 00: Z, AC, P, CY
        LXI H,0FF03H
        PUSH H
        POP PSW
        MVI B,00H
        ADC B
        CALL CHK
        DB 00H,57H
        MVI C,4             ; SUB 05 - 01 = 04: AC (5 + E + 1 carries out of bit 3), no borrow
        LXI H,0502H
        PUSH H
        POP PSW
        MVI B,01H
        SUB B
        CALL CHK
        DB 04H,12H
        MVI C,5             ; SUB 10 - 20 = F0: S, AC (0 + F + 1), P, CY (borrow)
        LXI H,1002H
        PUSH H
        POP PSW
        MVI B,20H
        SUB B
        CALL CHK
        DB 0F0H,97H
        MVI C,6             ; SBB 10 - 01 - CY = 0E: no AC (0 + E + 0), no borrow
        LXI H,1003H
        PUSH H
        POP PSW
        MVI B,01H
        SBB B
        CALL CHK
        DB 0EH,02H
        MVI C,7             ; ANA F0 AND 0F = 00: Z, P, AC = bit 3 of A OR bit 3 of B (1), CY 0
        LXI H,0F003H
        PUSH H
        POP PSW
        MVI B,0FH
        ANA B
        CALL CHK
        DB 00H,56H
        MVI C,8             ; ANA F3 AND 37 = 33: P, AC = 0 OR 0, AC and CY cleared
        LXI H,0F313H
        PUSH H
        POP PSW
        MVI B,37H
        ANA B
        CALL CHK
        DB 33H,06H
        MVI C,9             ; ORA 03 OR 80 = 83: S, AC and CY cleared
        LXI H,0313H
        PUSH H
        POP PSW
        MVI B,80H
        ORA B
        CALL CHK
        DB 83H,82H
        MVI C,10            ; XRA 5A XOR 5A = 00: Z, P; S AC CY cleared
        LXI H,5A93H
        PUSH H
        POP PSW
        MVI B,5AH
        XRA B
        CALL CHK
        DB 00H,46H
        MVI C,11            ; CMP 42, 42: A kept, Z, AC (2 + D + 1), P of the difference 00
        LXI H,4202H
        PUSH H
        POP PSW
        MVI B,42H
        CMP B
        CALL CHK
        DB 42H,56H
        MVI C,12            ; CMP 01, 02: A kept, difference FF: S, P, CY (borrow), no AC (1 + D + 1)
        LXI H,0102H
        PUSH H
        POP PSW
        MVI B,02H
        CMP B
        CALL CHK
        DB 01H,87H
        MVI C,13            ; INR A FF = 00: Z, AC, P; CY kept (1)
        LXI H,0FF03H
        PUSH H
        POP PSW
        INR A
        CALL CHK
        DB 00H,57H
        MVI C,14            ; DCR A 10 = 0F: P, no AC (10 + FF: 0 + F); CY kept (1)
        LXI H,1003H
        PUSH H
        POP PSW
        DCR A
        CALL CHK
        DB 0FH,07H
        MVI C,15            ; DAD D F234 + 1F00 = 1134: CY, the other flags kept (D6); A = H
        LXI H,00D6H
        PUSH H
        POP PSW
        LXI H,0F234H
        LXI D,1F00H
        DAD D
        MOV A,H
        CALL CHK
        DB 11H,0D7H
        MVI C,16            ; RAL 80, CY 0 = 00, CY 1; Z not set
        LXI H,8002H
        PUSH H
        POP PSW
        RAL
        CALL CHK
        DB 00H,03H
        MVI C,17            ; RAR 02, CY 1 = 81, CY 0
        LXI H,0203H
        PUSH H
        POP PSW
        RAR
        CALL CHK
        DB 81H,02H
        MVI C,18            ; DAA 9B (AC 0, CY 0) = 01, AC, CY (Intel's DAA example)
        LXI H,9B02H
        PUSH H
        POP PSW
        DAA
        CALL CHK
        DB 01H,13H
        MVI C,19            ; ADD 38 + 45 = 7D, DAA = 83: S, AC (D + 6), no CY
        LXI H,3802H
        PUSH H
        POP PSW
        MVI B,45H
        ADD B
        DAA
        CALL CHK
        DB 83H,92H
        MVI C,20            ; ADD 29 + 18 = 41 with AC, DAA = 47: P, AC 0 (1 + 6), no CY
        LXI H,2902H
        PUSH H
        POP PSW
        MVI B,18H
        ADD B
        DAA
        CALL CHK
        DB 47H,06H
        JMP PH4

; CHK: compares A and the flag byte with the two bytes after the CALL; on a mismatch the first failing
; case (C) goes to RES+3; returns past the two bytes.
CHK:    PUSH PSW
        POP D               ; D = A, E = flags
        POP H               ; HL = the expected bytes
        MOV A,M
        CMP D
        INX H
        JNZ CHKF
        MOV A,M
        CMP E
        JNZ CHKF
        INX H
        PCHL
CHKF:   INX H
        LDA RES+3
        ORA A
        JNZ CHKX
        MOV A,C
        STA RES+3
CHKX:   PCHL

;---------------- phase 4: the keyboard 8255 (8000-9FFF)
PH4:    MVI C,1
        LDA 8000H           ; port A an input (the start-up mode word lost): the pins, FF
        CPI 0FFH
        JNZ P4F
        MVI A,8AH           ; the monitor's mode (F836): A out, B in, C upper in, C lower out
        STA 8003H
        MVI C,2
        LDA 8000H           ; the mode word resets the output latch
        CPI 00H
        JNZ P4F
        MVI C,3
        MVI A,3CH
        STA 8000H
        LDA 8000H           ; an output port reads its latch
        CPI 3CH
        JNZ P4F
        MVI C,4
        MVI A,0C3H
        STA 8000H
        LDA 8000H
        CPI 0C3H
        JNZ P4F
        MVI C,0
P4F:    MOV A,C
        STA RES+4

;---------------- phase 5: EI, DI (INTE checked by the testbench)
        EI
        NOP
        NOP
        NOP
        NOP
        DI
        XRA A
        STA RES+5
        LXI D,875           ; about 21 000 Φ, a frame with the DMA: the testbench's underrun check
        CALL DELAY          ; (armed one frame after the 8257 mode A4h) then spans a whole frame

;---------------- phase 6: the tape exit with Preset Counters, then Load Cursor
        LXI H,0E008H
        MVI M,80H           ; the 8257 stopped (as before a tape operation)
        LXI H,0E004H        ; FC0F
        MVI M,0D0H
        MVI M,76H
        INX H
        MVI M,23H
        MVI M,49H
        MVI A,27H
        STA 0C001H
        MVI A,0E0H          ; Preset Counters
        STA 0C001H
        MVI L,08H
        MVI M,0A4H          ; FC27
        LXI D,1667          ; about 40 000 Φ (24 per pass)
        CALL DELAY
        MVI A,80H           ; Load Cursor (FD8C) at 0, 0
        STA 0C001H
        LXI H,0
        MOV A,L
        STA 0C000H
        MOV A,H
        STA 0C000H
        LXI D,2667          ; about 64 000 Φ: 3 frames with the DMA
        CALL DELAY
        XRA A
        STA RES+6

;---------------- phase 7: a DMA block in the monitor ROM, then the monitor's 8257 block again
        LXI H,0E008H
        MVI M,80H           ; the 8257 stopped
        LXI D,DMATAB
        MVI L,04H
        MOV M,E             ; channel 2 address DMATAB
        MOV M,D
        INR L
        MVI M,7FH           ; count 407Fh: 128 transfers, DMA read
        MVI M,40H
        MVI L,08H
        MVI M,0A4H
        LXI D,2000          ; about 48 000 Φ: 2.3 frames with the DMA
        CALL DELAY
        MVI L,08H           ; (DELAY keeps H L)
        MVI M,80H
        MVI L,04H
        MVI M,0D0H
        MVI M,76H
        INR L
        MVI M,23H
        MVI M,49H
        MVI L,08H
        MVI M,0A4H
        XRA A
        STA RES+7

        MVI A,0A5H
        STA MARK
DONE:   JMP DONE

; DELAY: DE passes of 24 Φ
DELAY:  DCX D
        MOV A,D
        ORA E
        JNZ DELAY
        RET

; phase 7's DMA block: (i * 37 + 11) AND 7Fh, i = 0..127 (no 8275 special code F0-F3)
DMATAB: DB 0BH,30H,55H,7AH,1FH,44H,69H,0EH,33H,58H,7DH,22H,47H,6CH,11H,36H
        DB 5BH,00H,25H,4AH,6FH,14H,39H,5EH,03H,28H,4DH,72H,17H,3CH,61H,06H
        DB 2BH,50H,75H,1AH,3FH,64H,09H,2EH,53H,78H,1DH,42H,67H,0CH,31H,56H
        DB 7BH,20H,45H,6AH,0FH,34H,59H,7EH,23H,48H,6DH,12H,37H,5CH,01H,26H
        DB 4BH,70H,15H,3AH,5FH,04H,29H,4EH,73H,18H,3DH,62H,07H,2CH,51H,76H
        DB 1BH,40H,65H,0AH,2FH,54H,79H,1EH,43H,68H,0DH,32H,57H,7CH,21H,46H
        DB 6BH,10H,35H,5AH,7FH,24H,49H,6EH,13H,38H,5DH,02H,27H,4CH,71H,16H
        DB 3BH,60H,05H,2AH,4FH,74H,19H,3EH,63H,08H,2DH,52H,77H,1CH,41H,66H
        END

; ---------------------------------------------------------------------------
; SLOTS for the KIM-1 / PAL-2  --  a three-reel slot machine on the six LEDs
;
; STUB: this only checks that the toolchain builds.  It returns straight to
; the monitor.  See README.md for the design.
;
; Assembles with ca65 (plain 6502) and kim.inc.  To move it into
; KIM-1_Development, copy this file into its Programs folder; nothing else
; is needed.
;
; Start at $0200.
; ---------------------------------------------------------------------------

        .include "kim.inc"

        .segment "ZEROPAGE"
; (zero-page variables go here)

        .segment "CODE"
start:
        jmp     START           ; back to the monitor

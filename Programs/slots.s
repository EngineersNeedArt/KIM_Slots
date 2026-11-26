; ---------------------------------------------------------------------------
; SLOTS for the KIM-1 / PAL-2  --  a three-reel slot machine on the six LEDs
;
; Start at $0200.  Fits the stock 1K.  See README.md for the full design.
;
; DISPLAY   digits 1-3 = reels, digits 4-6 = credits (right-aligned,
;           leading zeros blank).  Symbols: cherry "d", toothpicks "||",
;           BAR (three bars), 7.
; PLAY      INTRO "SLO7S": any key.  READY: press and release any key to
;           spin (1 credit).  Reels stop left to right.  Wins count up;
;           BAR BAR BAR blinks the reels, 7 7 7 chases a blank across them.
;           Out of credits: "LOSt", GO starts over with 20 credits.
; KEYS      the monitor's GETKEY, port A set to inputs first (as horserace.s).
;           ST and RS are hardware keys and can't be read.
; TIMING    one pass = key read + game logic + one scan of the six digits,
;           about 6.5 ms.  All the rates below count passes, so tune them on
;           the hardware.
; RANDOM    16-bit xorshift, stepped every pass.  The user RIOT timer (left
;           free-running at 1 MHz) is mixed in when the spin key goes down
;           and again when it comes up.  The three stops are chosen then; the
;           reels only show the result.
; PAYOUTS   bet 1 credit; the payout is the credits paid back.  Odds are out
;           of 512 (8 x 8 x 8 stops).  Cherries only count from the left:
;             7    7    7     pays 50     1 way
;             BAR  BAR  BAR   pays 15     4 ways
;             ||   ||   ||    pays  5    12 ways
;             d    d    d     pays  4    27 ways
;             d    d    any   pays  2    45 ways  (reel 3 not a cherry)
;             d    any  any   pays  1   120 ways  (reel 2 not a cherry)
;           Anything else pays nothing, e.g. "|| d d" or "7 7 BAR".
;           209 wins in 512; returns 488/512, about 95%.
;
; Assembles with ca65 (plain 6502) and kim.inc.  To move it into
; KIM-1_Development, copy this file into its Programs folder; nothing else
; is needed.
; ---------------------------------------------------------------------------

        .include "kim.inc"

; ---- tuning (counts are passes of ~6.5 ms) ----------------------------------
START_CREDITS = $20         ; BCD, 0-99
SPEED       = 10            ; passes per frame, all reels (3 frames per symbol)
SPIN_FIRST  = 150           ; minimum spin before reel 1 may stop (~1 s)
STOP_GAP    = 120           ; then each next reel may stop this much later
COUNT_RATE  = 15            ; count-up: one credit per this many (~10/s)
HOLD        = 110           ; pause after a spin's result (~0.7 s)
BAR_RATE    = 20            ; BAR BAR BAR blink step
SEVEN_RATE  = 10            ; 7 7 7 chase step (faster)
DEBOUNCE    = 8             ; key must read "none" this many passes to be up
ON_TIME     = 125           ; per-digit delay loop count, ~1 ms (8 cycles each)

; ---- display ----------------------------------------------------------------
DIGIT_FIRST = $09           ; SBD value for the leftmost digit
                            ; ($09,$0B,...,$13 as in blinken.s)
CHERRY      = $5E           ; b c d e g  "d"
TOOTH       = $36           ; b c e f    "||"
BAR         = $49           ; a d g
SEVEN       = $07           ; a b c

; ---- states -----------------------------------------------------------------
ST_INTRO    = 0
ST_READY    = 1
ST_SPIN     = 2
ST_SCORE    = 3
ST_LOST     = 4

; ---- zero-page variables (all cleared at start) ------------------------------
        .zeropage
vars:
state:      .res 1
rng:        .res 2          ; xorshift state (lo, hi); never both zero
key:        .res 1          ; last key code seen down
down:       .res 1          ; nonzero while a key is held
upcnt:      .res 1          ; debounce countdown while the key reads "none"
pressed:    .res 1          ; nonzero for the one pass a key goes down
released:   .res 1          ; nonzero for the one pass it comes up
armed:      .res 1          ; READY saw the key go down (so its release spins)
cred:       .res 1          ; credits, BCD tens/units
credh:      .res 1          ; credits, BCD hundreds (0-9)
ridx:       .res 3          ; reel frame index, 0-23 (multiple of 3 = whole)
tgt:        .res 3          ; frame index each reel stops on
rcnt:       .res 3          ; passes until each reel's next frame
cur:        .res 1          ; reel now allowed to stop; 3 = all stopped
stoptimer:  .res 1          ; passes until reel "cur" may stop
sym:        .res 3          ; result symbols (segment bytes)
pay:        .res 1          ; credits still to count up
ctimer:     .res 1          ; passes until the next counted credit
wait:       .res 1          ; hold countdown after the result
mask:       .res 1          ; lit reels: bit 0 = reel 1 ... bit 2 = reel 3
flen:       .res 1          ; flash pattern length (0 = no flash)
fstart:     .res 1          ; flash pattern start in flash_tab
fidx:       .res 1          ; step within the pattern
frate:      .res 1          ; passes per step
ftimer:     .res 1          ; passes until the next step
disp:       .res 6          ; segments for the six digits, left to right
tmp:        .res 1
vars_end:

; ---------------------------------------------------------------------------
        .code
start:
        cld
        ldx #vars_end-vars-1
        lda #0
clear:  sta vars,x
        dex
        bpl clear
        lda #$7F
        sta SADD                ; PA0-PA6 segment outputs
        lda #$1F
        sta SBDD                ; PB0-PB4: serial idle bit + digit decoder
        sta T1_NOIRQ            ; start the user timer; it free-runs after
        inc rng                 ; nonzero seed
        lda #%111
        sta mask
        jsr reset_credits

main:   jsr keys
        jsr rand                ; step the generator every pass
        jsr dispatch
        jsr build
        jsr scan
        jmp main

; run the handler for the current state (it returns to main)
dispatch:
        lda state
        asl
        tax
        lda handlers+1,x
        pha
        lda handlers,x
        pha
        rts

handlers:
        .word intro-1, ready-1, spin-1, score-1, lost-1

; ---- INTRO: "SLO7S", any key ------------------------------------------------
intro:  lda pressed
        beq rts1
to_ready:
        lda #ST_READY
        sta state
        lda #0
        sta armed
rts1:   rts

; ---- LOST: "LOSt", GO starts over ---------------------------------------------
lost:   lda pressed
        beq rts1
        lda key
        cmp #KEY_GO
        bne rts1
        jsr reset_credits
        jmp to_ready

; ---- READY: press, then release, any key to spin ----------------------------
ready:  lda pressed
        beq @rel
        lda TIMER_READ          ; key down: stir the low byte
        eor rng
        sta rng
        lda #1
        sta armed
@rel:   lda released
        beq rts1
        lda armed
        beq rts1
        lda TIMER_READ          ; key up: stir the high byte
        eor rng+1
        sta rng+1
        ora rng
        bne @seeded
        inc rng                 ; xorshift must never be all zero
@seeded:
        ; bet one credit
        sed
        sec
        lda cred
        sbc #1
        sta cred
        lda credh
        sbc #0
        sta credh
        cld
        ; choose the result: a stop 0-7 per reel from the high bits
        ldx #2
@pick:  jsr rand
        lda rng+1
        lsr
        lsr
        lsr
        lsr
        lsr                     ; 0-7
        sta tmp
        asl                     ; (carry clear: A <= 14)
        adc tmp                 ; x3 = frame index of the whole symbol
        sta tgt,x
        lda #1
        sta rcnt,x              ; every reel moves on the next pass
        dex
        bpl @pick
        lda #0
        sta cur
        lda #SPIN_FIRST
        sta stoptimer
        lda #ST_SPIN
        sta state
        rts

; ---- SPIN: run the reels, stop them left to right ----------------------------
spin:   lda stoptimer
        beq @reels
        dec stoptimer
@reels: ldx #2
@reel:  cpx cur
        bcc @next               ; reel is already stopped
        dec rcnt,x
        bne @next
        lda #SPEED
        sta rcnt,x
        ldy ridx,x              ; next frame, wrapping at 24
        iny
        cpy #24
        bne @set
        ldy #0
@set:   sty ridx,x
        cpx cur                 ; the reel that may stop next?
        bne @next
        lda stoptimer
        bne @next
        tya
        cmp tgt,x
        bne @next
        inc cur                 ; it lands on its target: stop it
        lda #STOP_GAP
        sta stoptimer
@next:  dex
        bpl @reel
        lda cur
        cmp #3
        beq score_setup
        rts

; ---- all stopped: work out the payout ---------------------------------------
score_setup:
        ldx #2
@sym:   lda roff,x
        clc
        adc tgt,x
        tay
        lda reels,y             ; a static frame's byte is the symbol
        sta sym,x
        dex
        bpl @sym
        lda #0
        sta pay
        sta flen
        lda sym
        cmp sym+1
        bne @cherry
        cmp sym+2
        bne @cherry
        ldx #3                  ; three of a kind: which symbol?
@find:  cmp sym_tab,x
        beq @found
        dex
        bne @find               ; x = 0 (SEVEN) if nothing else matched
@found: lda pay3,x
        sta pay
        cpx #2
        bcs @go                 ; only 7 7 7 (x=0) and BAR (x=1) flash
        lda fl_start,x
        sta fstart
        tay
        lda flash_tab,y
        sta mask
        lda fl_len,x
        sta flen
        lda fl_rate,x
        sta frate
        sta ftimer
        lda #0
        sta fidx
        beq @go                 ; (always)
@cherry:                        ; cherries count from the left
        cmp #CHERRY
        bne @go
        inc pay
        lda sym+1
        cmp #CHERRY
        bne @go
        inc pay
@go:    lda #COUNT_RATE
        sta ctimer
        lda #HOLD
        sta wait
        lda #ST_SCORE
        sta state
        rts

; ---- SCORE: count the winnings up, flash, then hold --------------------------
score:  jsr flash
        lda pay
        beq score_hold
        dec ctimer
        bne rts2
        lda #COUNT_RATE
        sta ctimer
        dec pay
        ; credits + 1, stopping at 999
        lda credh
        cmp #9
        bne @add
        lda cred
        cmp #$99
        beq rts2
@add:   sed
        clc
        lda cred
        adc #1
        sta cred
        lda credh
        adc #0
        sta credh
        cld
rts2:   rts
score_hold:
        dec wait
        bne rts2
        lda #%111               ; flashing over: all reels lit
        sta mask
        lda #0
        sta flen
        lda cred
        ora credh
        beq go_lost
        jmp to_ready
go_lost:
        lda #ST_LOST
        sta state
        rts

; step the flash pattern, if any
flash:  lda flen
        beq rts2
        dec ftimer
        bne rts2
        lda frate
        sta ftimer
        ldy fidx
        iny
        cpy flen
        bcc @set
        ldy #0
@set:   sty fidx
        tya
        clc
        adc fstart
        tay
        lda flash_tab,y
        sta mask
        rts

reset_credits:
        lda #START_CREDITS
        sta cred
        lda #0
        sta credh
        rts

        .segment "HIGH"         ; $1780: keys and random numbers

; ---- keys: read once per pass, debounce the release --------------------------
; sets pressed/released for one pass each; key = code while down
keys:   lda #0
        sta pressed
        sta released
        sta SADD                ; port A = inputs, so GETKEY can read the keypad
        jsr GETKEY              ; key code in A, KEY_NONE ($15) if none
        ldx #$7F                ; back to outputs for the display
        stx SADD
        ldx #$1F
        stx SBDD
        cmp #KEY_NONE
        beq @none
        sta key
        lda #DEBOUNCE
        sta upcnt
        lda down
        bne rts3
        inc down
        inc pressed
        rts
@none:  lda down
        beq rts3
        dec upcnt
        bne rts3
        lda #0
        sta down
        inc released
rts3:   rts

; ---- 16-bit xorshift (7, 9, 8), John Metcalf -----------------------------------
rand:   lda rng+1
        lsr
        lda rng
        ror
        eor rng+1
        sta rng+1               ; high part of x ^= x << 7 done
        ror                     ; A = x >> 9, high bit from the low byte
        eor rng
        sta rng                 ; x ^= x >> 9 and low part of x ^= x << 7
        eor rng+1
        sta rng+1               ; x ^= x << 8
        rts

        .segment "PAGE1"        ; $0100: display (stack keeps the top of page 1)

; ---- build the six digits for this pass ------------------------------------------
build:  lda state
        ldy #0
        cmp #ST_INTRO
        beq @msg
        ldy #6
        cmp #ST_LOST
        beq @msg
        ; reels, blanked where the flash mask is 0
        lda mask
        sta tmp
        ldx #0
@reel:  lda #0
        lsr tmp
        bcc @put
        lda roff,x
        clc
        adc ridx,x
        tay
        lda reels,y
@put:   sta disp,x
        inx
        cpx #3
        bne @reel
        ; credits, right-aligned, leading zeros blank
        lda #0
        sta tmp                 ; 0 while still in leading zeros
        lda credh
        jsr @lead
        sta disp+3
        lda cred
        lsr
        lsr
        lsr
        lsr
        jsr @lead
        sta disp+4
        lda cred
        and #$0F
        tax
        lda TABLE,x             ; the units digit always shows
        sta disp+5
        rts
@lead:  tax                     ; A = digit -> segments, or 0 if leading
        ora tmp
        beq @blank
        sta tmp
        lda TABLE,x
@blank: rts
@msg:   ldx #0
@copy:  lda msgs,y
        sta disp,x
        iny
        inx
        cpx #6
        bne @copy
        rts

; ---- scan the six digits once, ~1 ms each ----------------------------------------
scan:   ldx #0
        ldy #DIGIT_FIRST
@digit: lda #0
        sta SAD                 ; blank before changing digit
        sty SBD
        lda disp,x
        sta SAD
        lda #ON_TIME
        sta tmp
@on:    dec tmp
        bne @on
        iny
        iny
        inx
        cpx #6
        bne @digit
        lda #0
        sta SAD
        rts

; ---------------------------------------------------------------------------
        .segment "ZPDATA"       ; tables live in zero page, loaded from tape

; Reel frames: static, scroll1, scroll2 per stop, symbols moving up.
; Reel 1  C T B C 7 C T B
; Reel 2  T C B 7 C T B C
; Reel 3  C T C T 7 T C B
reels:
        .byte $5E,$63,$15, $36,$2A,$48, $49,$41,$0D, $5E,$6B,$45
        .byte $07,$02,$0C, $5E,$63,$15, $36,$2A,$48, $49,$41,$0D
        .byte $36,$22,$0C, $5E,$6B,$49, $49,$49,$45, $07,$02,$0C
        .byte $5E,$63,$15, $36,$2A,$48, $49,$41,$0D, $5E,$63,$15
        .byte $5E,$63,$15, $36,$22,$0C, $5E,$63,$15, $36,$2A,$44
        .byte $07,$02,$14, $36,$22,$0C, $5E,$6B,$49, $49,$41,$0D
roff:   .byte 0, 24, 48         ; each reel's start in reels

; three of a kind: symbol and payout (x = 0 and 1 flash)
sym_tab:.byte SEVEN, BAR, TOOTH, CHERRY
pay3:   .byte 50, 15, 5, 4

; flash masks: bit 0 = reel 1 (leftmost) ... bit 2 = reel 3
flash_tab:
        .byte %110, %111, %101, %111, %011, %111   ; 7 7 7: blank moves left to right
        .byte %111, %000                           ; BAR: all blink
fl_start:.byte 0, 6             ; index 0 = 7 7 7, 1 = BAR
fl_len: .byte 6, 2
fl_rate:.byte SEVEN_RATE, BAR_RATE

; messages, left to right
msgs:   .byte $00, $6D, $38, $3F, $07, $6D  ; " SLO7S"
        .byte $00, $38, $3F, $6D, $78, $00  ; " LOSt "

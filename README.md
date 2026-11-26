# Slots

A three-reel slot machine for the MOS KIM-1, built for and tested on the
PAL-2. It runs on the six built-in 7-segment LEDs and fits in the stock 1K.

Status: playable. It has been tested in a 6502 emulator with the monitor's
GETKEY stubbed out, but not yet on the PAL-2. The speeds and delays are
first guesses, to be tuned on the hardware.

## Building

The tools are ca65 and ld65 (from cc65), plus `srec_cat` (from SRecord), which
turns the binaries into a MOS Technology paper tape.

In VS Code, open `Programs/slots.s` and run the default build task
(Shift-Cmd-B). The tape lands in `build/slots.pap`. Load it on the PAL-2 and
start at $0200. The tape also loads zero page, page 1 and $1780.

`kim.cfg`, `Programs/kim.inc` and `.vscode/tasks.json` are copies from
`KIM-1_Development`. If Slots moves there, only `slots.s` needs to be copied
into its `Programs` folder.

## Display

```
  digit:   1      2      3      4      5      6
         reel 1 reel 2 reel 3  ------ credits ------
```

Credits are shown right-aligned with leading zeros blanked, for example
`C T B _ 2 0`. That leaves a gap between the reels and the credits.

## Symbols

| Symbol | Shape | Segments | Byte |
|---|---|---|---|
| cherry | "d" | b c d e g | $5E |
| toothpicks | "\|\|" | b c e f | $36 |
| BAR | three bars | a d g | $49 |
| 7 | "7" | a b c | $07 |

Segment bits: a = bit 0 (top), b = 1, c = 2, d = 3 (bottom), e = 4, f = 5,
g = 6 (middle).

## Reels

There are 8 stops per reel. Reel 3 swaps a BAR for toothpicks, so BAR BAR BAR
is rarer.

| | Cherry | Toothpicks | BAR | 7 | Order |
|---|---|---|---|---|---|
| Reel 1 | 3 | 2 | 2 | 1 | `C T B C 7 C T B` |
| Reel 2 | 3 | 2 | 2 | 1 | `T C B 7 C T B C` |
| Reel 3 | 3 | 3 | 1 | 1 | `C T C T 7 T C B` |

No symbol is next to itself, including around the wrap.

### Scrolling

Symbols move **up**. Each symbol takes 3 frames: **static**, **scroll1**
(shifted up one level) and **scroll2** (shifted up two levels). The next symbol
on the strip comes in from below. The shifted frames are precomputed, because
the segment bits do not move with a simple shift.

- scroll1: the current symbol's g→a, e→f, c→b, d→g; the next symbol's a→d.
- scroll2: the current symbol's d→a; the next symbol's a→g, f→e, b→c, g→d.

Each reel is one 24-byte table with the three frames interleaved. A single
index walks it and wraps at 24. The reel shows a whole symbol when the
index is a multiple of 3.

```
Reel 1: $5E $63 $15  $36 $2A $48  $49 $41 $0D  $5E $6B $45
        $07 $02 $0C  $5E $63 $15  $36 $2A $48  $49 $41 $0D
Reel 2: $36 $22 $0C  $5E $6B $49  $49 $49 $45  $07 $02 $0C
        $5E $63 $15  $36 $2A $48  $49 $41 $0D  $5E $63 $15
Reel 3: $5E $63 $15  $36 $22 $0C  $5E $63 $15  $36 $2A $44
        $07 $02 $14  $36 $22 $0C  $5E $6B $49  $49 $41 $0D
```

A known quirk: when a BAR follows a cherry, or a 7 follows a BAR, some
in-between frames look exactly like BAR ($49). The BAR seems to arrive early
or stay a little longer.

## Pay table

The bet is 1 credit per spin. Payouts are the credits paid back. Cherries
count from the left.

| Result | Ways (of 512) | Pays |
|---|---|---|
| 7 7 7 | 1 | 50 |
| BAR BAR BAR | 4 | 15 |
| toothpicks ×3 | 12 | 5 |
| cherry cherry cherry | 27 | 4 |
| cherry cherry – | 45 | 2 |
| cherry – – | 120 | 1 |

The return is 488/512, about 95.3%. A spin wins 209 times in 512, about 41%.

The game starts with 20 credits, and credits stop at 999. They are stored
as BCD.

## Randomness

The result is chosen when the spin starts. The reels are only a show.

- Timer: the user RIOT's interval timer at $1700. Start it once by writing
  `T1_NOIRQ`. After it reaches zero, it keeps counting down at 1 MHz, so it
  runs freely.
- Read `TIMER_READ` ($1706) when the spin key goes down, and again when it
  comes up. Mix both reads into a 16-bit xorshift generator.
- The generator is also stepped once every pass of the main loop.
- Take each reel's stop (0–7) from the generator's high bits. The target
  index in the reel's table is `stop × 3`.
- Keep the key-polling loop an odd number of cycles long, so the timer
  reads can land on every value.
- To test, fix the seed to replay a known run of spins.

## State machine

```
 INTRO ─any key─▶ READY ─any key─▶ SPINNING ─all stopped─▶ SCORE ─credits > 0─▶ READY
 "SLO7S"                                                     │
                                                       credits = 0
                                                             ▼
                              READY ◀──── GO ──────────── LOST "LOSt"
```

- **INTRO** shows ` SLO7S`. Any key goes to READY.
- **READY** shows the reels and the credits. Pressing and releasing any key
  starts a spin. The spin begins on the release, like letting go of a
  lever.
- **SPINNING** takes 1 credit and updates the display at once. It picks the
  three stops, then starts all reels at different speeds. Reel 1 runs a
  minimum time, then stops when its index reaches its target. Reels 2 and 3
  each stop about a second after the reel before them. Keys are ignored.
- **SCORE**
  - No win: hold the reels a moment, then go on.
  - Win: count the credits up one at a time, about 10 per second.
  - Big win (payout of 15 or more): the reels flash during the count-up.
  - When done, go to LOST if the credits are 0, otherwise to READY.
- **LOST** comes after SCORE's hold, so the losing reels are seen first,
  then shows ` LOSt `. GO resets the
  credits to 20 and goes to READY.

ST and RS are wired to the hardware, so they can't be game keys. "Any key"
means the hex keys plus AD, DA, +, GO and PC.

### Flashing

Each step of a flash pattern is a 3-bit mask of which reels are lit. In the
masks below, reel 1 is the rightmost bit.

| Win | Pattern | Effect |
|---|---|---|
| BAR BAR BAR | `%111 %000` | all reels blink |
| 7 7 7 (faster) | `%110 %111 %101 %111 %011 %111` | a blank moves left to right |

The same code runs both patterns. Only the table, its length and the rate
differ.

### Letters

| Char | Segments | Byte |
|---|---|---|
| S | a c d f g | $6D |
| L | d e f | $38 |
| O | a b c d e f | $3F |
| 7 | a b c | $07 |
| t | d e f g | $78 |

## Memory (stock 1K, `kim.cfg`)

| Area | Use |
|---|---|
| $0000–$006F | tables: reel frames, pay table, flash patterns, messages |
| $0070–$0098 | variables (cleared at start) |
| $0100–$018A | display: build the digits and scan them |
| $018B–$01FF | stack |
| $0200–$03DA | start, main loop, states, scoring |
| $1780–$17CB | keys and random numbers |

The code is about 690 bytes, too big for $0200–$03FF alone, so it is
spread over these areas, as `baseball.s` does.

The display is driven directly through `SAD`/`SBD`, without the monitor's
display routines. Keys use the monitor's GETKEY with port A switched to
inputs, as in `horserace.s`.

## Timing

One pass of the main loop reads the keys, runs the current state and scans
the six digits once, about 1 ms each. A pass is about 6.5 ms. Every rate is
a count of passes, set at the top of `slots.s`:

| Constant | Value | Meaning |
|---|---|---|
| `SPEED1`–`SPEED3` | 4, 5, 6 | passes per frame for each reel |
| `SPIN_FIRST` | 150 | minimum spin before reel 1 may stop (~1 s) |
| `STOP_GAP` | 120 | wait before the next reel may stop (~0.8 s) |
| `COUNT_RATE` | 15 | passes per counted credit (~10/s) |
| `HOLD` | 110 | pause after the result (~0.7 s) |
| `BAR_RATE`, `SEVEN_RATE` | 20, 10 | flash step rates |
| `DEBOUNCE` | 8 | passes of "no key" before a release counts |

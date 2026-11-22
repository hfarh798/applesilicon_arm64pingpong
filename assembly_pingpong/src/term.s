// term.s - raw mode, keyboard input, output, frame timing
//
// two input modes:
//   kitty  - terminals with the kitty keyboard protocol (kitty, ghostty,
//            wezterm, iterm2) send real press/release events, so ST_HELD is
//            exact
//   legacy - everything else (Terminal.app etc) just sends bytes + autorepeat.
//            a key counts as held for a few frames after each event, tuned to
//            the measured repeat rate so movement is smooth and stops quickly
//            on release

.include "defs.inc"

.equ TERMIOS_SIZE,      72
.equ T_IFLAG,           0
.equ T_LFLAG,           24
.equ T_CC,              32
.equ VMIN,              16
.equ VTIME,             17
.equ ICRNL,             0x100           // c_iflag
.equ IXON,              0x200
.equ ECHO,              0x008           // c_lflag
.equ ISIG,              0x080
.equ ICANON,            0x100
.equ IEXTEN,            0x400

.equ INBUF_SIZE,        256

.equ EV_RELEASE,        3               // kitty event types: 1 press, 2 repeat, 3 release
.equ CTRL_MOD,          4               // kitty modifier bit (value is 1 + bits)

// Legacy hold windows, in frames.
.equ HOLD_TAP,          6               // a single press
.equ HOLD_SLACK,        3               // added to the repeat interval
.equ REPEAT_WINDOW,     36              // events closer than this form one hold
.equ REPEAT_DEFAULT,    6               // repeat interval guess until measured

// Private input state.
.equ IN_KITTY,          0               // terminal answered the kitty query
.equ IN_REPEAT,         4               // measured auto-repeat interval
.equ IN_TIMERS,         8               // 4 bytes: hold frames left per movement key
.equ IN_STREAKS,        12              // 4 bytes: consecutive repeats per key
.equ IN_LAST,           16              // 4 words: frame of each key's last event
.equ IN_SIZE,           32

    .text
    .p2align 2

// term_init: put stdin in raw, non-blocking mode and switch to the
// alternate screen. Returns w0 = 0 on success, 1 if stdin is not a tty.
    .globl _term_init
_term_init:
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp

    mov     x0, #0
    MOV32   x1, TIOCGETA
    LOAD    x2, saved_tio
    SYSCALL SYS_IOCTL
    b.cs    1f

    LOAD    x2, saved_tio                   // raw_tio = saved_tio, minus cooking
    LOAD    x3, raw_tio
    ldp     q0, q1, [x2]
    stp     q0, q1, [x3]
    ldp     q0, q1, [x2, #32]
    stp     q0, q1, [x3, #32]
    ldr     x4, [x2, #64]
    str     x4, [x3, #64]

    ldr     x4, [x3, #T_IFLAG]
    mov     x5, #(ICRNL | IXON)
    bic     x4, x4, x5
    str     x4, [x3, #T_IFLAG]
    ldr     x4, [x3, #T_LFLAG]
    mov     x5, #(ECHO | ISIG | ICANON | IEXTEN)
    bic     x4, x4, x5                      // handle ctrl-c ourselves so tty gets restored
    str     x4, [x3, #T_LFLAG]
    strb    wzr, [x3, #(T_CC + VMIN)]       // read() returns at once, even if empty
    strb    wzr, [x3, #(T_CC + VTIME)]

    mov     x0, #0
    MOV32   x1, TIOCSETA
    mov     x2, x3
    SYSCALL SYS_IOCTL

    LOAD    x0, input
    mov     w1, #REPEAT_DEFAULT
    str     w1, [x0, #IN_REPEAT]

    LOAD    x0, seq_enter
    mov     x1, #SEQ_ENTER_LEN
    bl      _write_all
    mov     w0, #0
    ldp     x29, x30, [sp], #16
    ret
1:  mov     w0, #1
    ldp     x29, x30, [sp], #16
    ret

// term_restore: leave the alternate screen and restore the original settings.
    .globl _term_restore
_term_restore:
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp
    LOAD    x0, seq_leave
    mov     x1, #SEQ_LEAVE_LEN
    bl      _write_all
    mov     x0, #0
    MOV32   x1, TIOCSETA
    LOAD    x2, saved_tio
    SYSCALL SYS_IOCTL
    ldp     x29, x30, [sp], #16
    ret

// write_all: x0 = buffer, x1 = length. Writes everything to stdout.
    .globl _write_all
_write_all:
    stp     x29, x30, [sp, #-32]!
    mov     x29, sp
    stp     x19, x20, [sp, #16]
    mov     x19, x0
    mov     x20, x1
1:  cbz     x20, 2f
    mov     x0, #1
    mov     x1, x19
    mov     x2, x20
    SYSCALL SYS_WRITE
    b.cs    2f
    add     x19, x19, x0
    sub     x20, x20, x0
    b       1b
2:  ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

// poll_input: decode pending input into ST_KEYS (this frame) and ST_HELD.
    .globl _poll_input
_poll_input:
    stp     x29, x30, [sp, #-80]!
    mov     x29, sp
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]
    stp     x23, x24, [sp, #48]
    stp     x25, x26, [sp, #64]
    str     wzr, [x28, #ST_KEYS]

    LOAD    x0, input                       // legacy: every hold window ticks down
    ldr     s0, [x0, #IN_TIMERS]
    movi    v1.8b, #1
    uqsub   v0.8b, v0.8b, v1.8b
    str     s0, [x0, #IN_TIMERS]

    mov     x0, #0
    LOAD    x1, inbuf
    mov     x2, #INBUF_SIZE
    SYSCALL SYS_READ
    b.cs    Lpoll_done
    cmp     x0, #0
    b.le    Lpoll_done
    LOAD    x19, inbuf                      // x19 = cursor, x20 = end
    add     x20, x19, x0

Lpoll_next:
    cmp     x19, x20
    b.hs    Lpoll_done
    ldrb    w0, [x19], #1
    cmp     w0, #27
    b.eq    Lpoll_escape
    bl      key_bits
    mov     w1, #1
    bl      key_event
    b       Lpoll_next

Lpoll_escape:
    cmp     x19, x20
    b.hs    Lpoll_esc_key
    ldrb    w0, [x19]
    cmp     w0, #'['
    b.eq    Lpoll_csi
    cmp     w0, #'O'                        // SS3 arrows: ESC O A..D
    b.ne    Lpoll_esc_key
    add     x1, x19, #1
    cmp     x1, x20
    b.hs    Lpoll_esc_key
    ldrb    w0, [x1]
    add     x19, x19, #2
    mov     w1, #1
    b       Lpoll_arrow
Lpoll_esc_key:                              // a lone Esc
    mov     w0, #K_BACK
    mov     w1, #1
    bl      key_event
    b       Lpoll_next

// CSI: ESC [ [private] key [: ...] [; mods [: event]] final
Lpoll_csi:
    add     x19, x19, #1
    mov     w22, #0                         // key
    mov     w23, #1                         // modifiers (1 = none)
    mov     w24, #1                         // event type (1 = press)
    mov     w25, #0                         // slot: 0 key, 1 mods, 2 event,
    mov     w26, #0                         //       3 ignored, 4 key extras
    cmp     x19, x20                        // private marker < = > ?
    b.hs    Lpoll_next
    ldrb    w0, [x19]
    sub     w1, w0, #'<'
    cmp     w1, #3
    b.hi    Lcsi_param
    mov     w26, #1
    add     x19, x19, #1
Lcsi_param:
    cmp     x19, x20
    b.hs    Lpoll_next                      // truncated: drop it
    ldrb    w0, [x19], #1
    sub     w1, w0, #'0'
    cmp     w1, #9
    b.hi    Lcsi_sep
    mov     w2, #10
    cbnz    w25, 1f
    madd    w22, w22, w2, w1
    b       Lcsi_param
1:  cmp     w25, #1
    b.ne    2f
    madd    w23, w23, w2, w1
    b       Lcsi_param
2:  cmp     w25, #2
    b.ne    Lcsi_param
    madd    w24, w24, w2, w1
    b       Lcsi_param
Lcsi_sep:
    cmp     w0, #';'
    b.ne    2f
    mov     w1, #3                          // key (or its extras) -> modifiers
    cmp     w25, #0
    ccmp    w25, #4, #4, ne
    b.ne    1f
    mov     w1, #1
    mov     w23, #0
1:  mov     w25, w1
    b       Lcsi_param
2:  cmp     w0, #':'
    b.ne    4f
    cbnz    w25, 3f
    mov     w25, #4                         // key:alternates
    b       Lcsi_param
3:  cmp     w25, #1
    b.eq    31f
    cmp     w25, #2                         // a third sub-field is ignored
    b.ne    Lcsi_param
    mov     w25, #3
    b       Lcsi_param
31: mov     w25, #2                         // modifiers:event
    mov     w24, #0
    b       Lcsi_param
4:  cmp     w0, #0x40
    b.lo    Lcsi_param                      // intermediate byte
    cbnz    w26, Lcsi_private
    mov     w1, w24
    cmp     w0, #'u'
    b.ne    Lpoll_arrow
    cmp     w22, #'c'                       // Ctrl-C in kitty mode
    b.ne    5f
    sub     w2, w23, #1
    tbz     w2, #2, 5f
    mov     w0, #K_QUIT
    b       6f
5:  mov     w0, w22
    bl      key_bits
6:  mov     w1, w24
    bl      key_event
    b       Lpoll_next
Lcsi_private:
    cmp     w0, #'u'                        // "ESC [ ? flags u": kitty is supported
    b.ne    Lpoll_next
    LOAD    x0, input
    mov     w1, #1
    str     w1, [x0, #IN_KITTY]
    str     wzr, [x28, #ST_HELD]
    b       Lpoll_next

Lpoll_arrow:                                // w0 = final byte, w1 = event type
    sub     w0, w0, #'A'
    cmp     w0, #3
    b.hi    Lpoll_next
    LOAD    x2, arrow_bits
    ldrh    w0, [x2, w0, uxtw #1]
    bl      key_event
    b       Lpoll_next

Lpoll_done:
    LOAD    x0, input                       // legacy: held = live hold windows
    ldr     w1, [x0, #IN_KITTY]
    cbnz    w1, 1f
    ldr     s0, [x0, #IN_TIMERS]
    cmtst   v0.8b, v0.8b, v0.8b
    LOAD    x1, move_bits
    ldr     d1, [x1]
    and     v0.8b, v0.8b, v1.8b
    addv    b0, v0.8b
    umov    w1, v0.b[0]
    str     w1, [x28, #ST_HELD]
1:  ldp     x25, x26, [sp, #64]
    ldp     x23, x24, [sp, #48]
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #80
    ret

// key_bits: w0 = character code. Returns its key bits in w0 (0 if unmapped).
key_bits:
    LOAD    x1, keymap                      // { char, bits } pairs, 0-terminated
1:  ldrh    w2, [x1], #4
    cbz     w2, 2f
    cmp     w2, w0
    b.ne    1b
    ldurh   w0, [x1, #-2]
    ret
2:  mov     w0, #0
    ret

// key_event: w0 = key bits, w1 = event type (1 press, 2 repeat, 3 release).
key_event:
    cbz     w0, 9f
    ldr     w2, [x28, #ST_HELD]
    cmp     w1, #EV_RELEASE
    b.ne    1f
    bic     w2, w2, w0
    str     w2, [x28, #ST_HELD]
    ret
1:  ldr     w3, [x28, #ST_KEYS]
    orr     w3, w3, w0
    str     w3, [x28, #ST_KEYS]
    LOAD    x9, input
    ldr     w3, [x9, #IN_KITTY]
    cbz     w3, 2f
    and     w3, w0, #K_MOVE                 // kitty: held until released
    orr     w2, w2, w3
    str     w2, [x28, #ST_HELD]
    ret

2:  ldr     w4, [x28, #ST_FRAME]            // legacy: open a hold window per key
    mov     w3, #0                          // movement key index
3:  lsr     w5, w0, w3
    tbz     w5, #0, 6f
    add     x6, x9, #IN_LAST
    ldr     w7, [x6, w3, uxtw #2]
    str     w4, [x6, w3, uxtw #2]
    sub     w7, w4, w7                      // frames since this key's last event
    add     x6, x9, #IN_STREAKS
    ldrb    w8, [x6, w3, uxtw]
    mov     w10, #HOLD_TAP
    cmp     w7, #REPEAT_WINDOW
    b.ls    4f
    mov     w8, #0                          // a fresh press
    b       5f
4:  cmp     w8, #0                          // an auto-repeat: the first one follows
    cinc    w8, w8, eq                      // the long initial delay, later ones
    b.eq    41f                             // give the true repeat interval
    cmp     w7, #2                          // (ignore bursts read in one frame)
    b.lo    41f
    str     w7, [x9, #IN_REPEAT]
    mov     w8, #2
41: ldr     w10, [x9, #IN_REPEAT]
    add     w10, w10, #HOLD_SLACK
5:  strb    w8, [x6, w3, uxtw]
    add     x6, x9, #IN_TIMERS
    strb    w10, [x6, w3, uxtw]
6:  add     w3, w3, #1
    cmp     w3, #4
    b.lo    3b
9:  ret

// frame_wait: sleep until the next frame tick of the hardware counter.
    .globl _frame_wait
_frame_wait:
    stp     x29, x30, [sp, #-32]!
    mov     x29, sp
    mrs     x0, cntvct_el0
    ldr     x1, [x28, #ST_NEXT_TICK]
    ldr     x2, [x28, #ST_FRAME_TICKS]
    add     x1, x1, x2
    subs    x3, x1, x0                      // ticks left in this frame
    b.gt    1f
    str     x0, [x28, #ST_NEXT_TICK]        // running late: resync, no sleep
    b       2f
1:  str     x1, [x28, #ST_NEXT_TICK]
    mrs     x4, cntfrq_el0
    MOV32   x5, 1000000
    mul     x3, x3, x5
    udiv    x3, x3, x4                      // -> microseconds
    stp     xzr, x3, [sp, #16]              // struct timeval { 0 s, x3 us }
    mov     x0, #0
    mov     x1, #0
    mov     x2, #0
    mov     x3, #0
    add     x4, sp, #16
    SYSCALL SYS_SELECT                      // select() w/ no fds as a sleep
2:  ldp     x29, x30, [sp], #32
    ret

// --- data ---

    .section __TEXT,__const
    .p2align 3
move_bits:                                  // bit of each movement key index
    .byte   K_UP1, K_UP2, K_DN1, K_DN2, 0, 0, 0, 0
keymap:
    .hword  'w', K_UP1,    'W', K_UP1,    's', K_DN1,    'S', K_DN1
    .hword  'a', K_LEFT,   'A', K_LEFT,   'd', K_RIGHT,  'D', K_RIGHT
    .hword  13,  K_ENTER,  10,  K_ENTER,  ' ', K_ENTER | K_PAUSE
    .hword  'p', K_PAUSE,  'P', K_PAUSE,  'q', K_BACK,   'Q', K_BACK
    .hword  27,  K_BACK,   3,   K_QUIT
    .hword  0,   0
arrow_bits:                                 // final byte 'A', 'B', 'C', 'D'
    .hword  K_UP2, K_DN2, K_RIGHT, K_LEFT

// Enter: alt screen, hide cursor, no wrap, clear, then push kitty keyboard
// flags (disambiguate | event types | all keys as escapes) and query support.
seq_enter:
    .ascii  "\033[?1049h\033[?25l\033[?7l\033[2J\033[>11u\033[?u"
.equ SEQ_ENTER_LEN, . - seq_enter
seq_leave:
    .ascii  "\033[<u\033[0m\033[2J\033[?7h\033[?25h\033[?1049l"
.equ SEQ_LEAVE_LEN, . - seq_leave

    .zerofill __DATA,__bss,saved_tio,TERMIOS_SIZE,4
    .zerofill __DATA,__bss,raw_tio,TERMIOS_SIZE,4
    .zerofill __DATA,__bss,inbuf,INBUF_SIZE,4
    .zerofill __DATA,__bss,input,IN_SIZE,4

// main.s - entry point + main loop
// per frame: poll input, update, draw, flush, wait for next tick

.include "defs.inc"

.equ FPS,               60

    .text
    .p2align 2

    .globl _main
_main:
    stp     x29, x30, [sp, #-32]!
    mov     x29, sp
    stp     x19, x28, [sp, #16]
    LOAD    x28, state

    bl      _term_init
    cbnz    w0, Lmain_notty
    bl      boot

Lmain_frame:
    bl      _poll_input
    ldr     w0, [x28, #ST_KEYS]
    tst     w0, #K_QUIT
    b.ne    Lmain_quit

    LOAD    x19, screens
    ldr     w0, [x28, #ST_SCREEN]
    add     x1, x19, x0, lsl #4
    ldr     x1, [x1]                        // update
    blr     x1

    bl      _clear_layers
    ldr     w0, [x28, #ST_SCREEN]           // update may have switched screens
    add     x1, x19, x0, lsl #4
    ldr     x1, [x1, #8]                    // draw
    blr     x1
    bl      _flush

    ldr     w0, [x28, #ST_RUNNING]
    cbz     w0, Lmain_quit
    ldr     w0, [x28, #ST_FRAME]
    add     w0, w0, #1
    str     w0, [x28, #ST_FRAME]
    bl      _frame_wait
    b       Lmain_frame

Lmain_quit:
    bl      _term_restore
    mov     w0, #0
    b       Lmain_exit

Lmain_notty:
    mov     x0, #2
    LOAD    x1, msg_notty
    mov     x2, #MSG_NOTTY_LEN
    SYSCALL SYS_WRITE
    mov     w0, #1

Lmain_exit:
    ldp     x19, x28, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

// boot: one-time initialisation, then open the menu.
boot:
    mrs     x0, cntvct_el0                  // free-running counter: seed + clock
    orr     w1, w0, #1                      // xorshift state must be non-zero
    str     w1, [x28, #ST_RNG]
    str     x0, [x28, #ST_NEXT_TICK]
    mrs     x1, cntfrq_el0
    mov     x2, #FPS
    udiv    x1, x1, x2
    str     x1, [x28, #ST_FRAME_TICKS]

    mov     w0, #1
    str     w0, [x28, #ST_RUNNING]
    str     w0, [x28, #ST_PLAYERS]
    mov     w0, #DIFF_NORMAL
    str     w0, [x28, #ST_DIFF]
    b       _menu_enter

// --- data ---

    .section __DATA,__const
    .p2align 3
screens:                                    // { update, draw } per screen
    .quad   _menu_update, _menu_draw        // SCR_MENU
    .quad   _play_update, _play_draw        // SCR_PLAY
    .quad   _over_update, _over_draw        // SCR_OVER

    .section __TEXT,__const
msg_notty:
    .ascii  "pong: stdin must be a terminal\n"
.equ MSG_NOTTY_LEN, . - msg_notty

    .zerofill __DATA,__bss,state,ST_SIZE,4

// game.s - paddles, ball, cpu player, scoring, play + game over screens
// positions are in pixels (2 per cell each direction), 8.8 fixed point

.include "defs.inc"

// Field layout, in pixels.
.equ WALL_TOP,          1               // lower half of text row 0
.equ FIELD_TOP,         2               // first playable row
.equ FIELD_BOT,         44              // first row of the bottom wall
.equ NET_X,             PX_W / 2 - 1    // 2 pixels wide, straddling the centre
.equ PAD_W,             2
.equ PAD_H,             10
.equ PAD_L_X,           4
.equ PAD_R_X,           PX_W - PAD_L_X - PAD_W
.equ BALL_W,            2               // 2x1 px looks square in a terminal
.equ BALL_H,            1
.equ SCORE_Y,           4
.equ WIN_SCORE,         7               // score font only has 0-9

// Text layout, in cells.
.equ LABEL_Y,           8
.equ STATUS_Y,          SCR_H - 1

// Motion, fixed point per frame.
.equ PAD_MIN,           FIELD_TOP << FP
.equ PAD_MAX,           (FIELD_BOT - PAD_H) << FP
.equ PAD_CENTER,        ((FIELD_TOP + FIELD_BOT - PAD_H) / 2) << FP
.equ PAD_SPEED,         1 << FP         // 1px/frame (fractional looked jittery)
.equ BALL_MIN_Y,        FIELD_TOP << FP
.equ BALL_MAX_Y,        (FIELD_BOT - BALL_H) << FP
.equ BALL_START_X,      (PX_W / 2 - BALL_W / 2) << FP
.equ BALL_START_Y,      ((FIELD_TOP + FIELD_BOT - BALL_H) / 2) << FP
.equ SERVE_VX,          320
.equ BALL_ACCEL,        20              // added to |vx| on every return
.equ BALL_MAX_VX,       640             // keep < 4px/frame or it skips the paddle
.equ BALL_ANGLE,        36              // vy per pixel off the paddle centre, /256
.equ HIT_REACH,         ((PAD_H + BALL_H) << (FP - 1)) + (1 << FP)
                                        // max centre distance for a hit
                                        // (+1px of slack)
.equ SERVE_DELAY,       50              // frames

    .text
    .p2align 2

// game_start: begin a fresh match with the current player count.
    .globl _game_start
_game_start:
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp
    stp     wzr, wzr, [x28, #ST_SCORES]
    str     wzr, [x28, #ST_PAUSED]
    mov     w0, #PAD_CENTER
    stp     w0, w0, [x28, #ST_PADS]
    mov     w0, #SCR_PLAY
    str     w0, [x28, #ST_SCREEN]
    bl      _rand                           // coin toss for the first serve
    mov     w1, #SERVE_VX
    neg     w2, w1
    tst     w0, #1
    csel    w0, w1, w2, eq
    ldp     x29, x30, [sp], #16
    b       serve

// play_update: one frame of the match.
    .globl _play_update
_play_update:
    stp     x29, x30, [sp, #-32]!
    mov     x29, sp
    stp     x19, x20, [sp, #16]
    ldr     w19, [x28, #ST_KEYS]

    tst     w19, #K_BACK
    b.eq    1f
    bl      _menu_enter
    b       Lplay_done
1:  tst     w19, #K_PAUSE
    b.eq    2f
    ldr     w0, [x28, #ST_PAUSED]
    eor     w0, w0, #1
    str     w0, [x28, #ST_PAUSED]
2:  ldr     w0, [x28, #ST_PAUSED]
    cbnz    w0, Lplay_done

    ldr     w20, [x28, #ST_PLAYERS]
    add     x0, x28, #ST_PADS               // left: W/S (+ arrows when solo)
    mov     w1, #K_UP1
    mov     w2, #K_DN1
    cmp     w20, #1
    b.ne    3f
    mov     w1, #K_UP
    mov     w2, #K_DOWN
3:  bl      steer
    add     x0, x28, #(ST_PADS + 4)         // right: arrows, or the CPU
    cmp     w20, #1
    b.eq    4f
    mov     w1, #K_UP2
    mov     w2, #K_DN2
    bl      steer
    b       5f
4:  bl      cpu_move

5:  ldr     w0, [x28, #ST_SERVE]            // ball waits out the serve delay
    cbz     w0, 6f
    sub     w0, w0, #1
    str     w0, [x28, #ST_SERVE]
    b       Lplay_done
6:  bl      ball_step
Lplay_done:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

// steer: x0 = paddle, w1 = up-key mask, w2 = down-key mask.
// Moves at a constant speed for exactly as long as a key is held.
steer:
    ldr     w3, [x28, #ST_HELD]
    ldr     w4, [x0]
    tst     w3, w1
    b.eq    1f
    sub     w4, w4, #PAD_SPEED
1:  tst     w3, w2
    b.eq    store_paddle
    add     w4, w4, #PAD_SPEED
    // fall through

// store_paddle: x0 = paddle, w4 = new top row; clamps it to the field.
store_paddle:
    mov     w5, #PAD_MIN
    cmp     w4, w5
    csel    w4, w5, w4, lt
    mov     w5, #PAD_MAX
    cmp     w4, w5
    csel    w4, w5, w4, gt
    str     w4, [x0]
    ret

// cpu_move: x0 = paddle. Chase the ball (plus an aiming error) while it
// approaches, otherwise drift back to the centre, at the difficulty's speed.
cpu_move:
    mov     w5, #PAD_CENTER
    ldr     w1, [x28, #ST_BALL_VX]
    cmp     w1, #0
    b.le    1f
    ldr     w5, [x28, #ST_BALL_Y]
    ldr     w1, [x28, #ST_CPU_AIM]
    add     w5, w5, w1
    mov     w1, #((PAD_H - BALL_H) << (FP - 1))
    sub     w5, w5, w1                      // ball level with the paddle's middle
1:  ldr     w4, [x0]
    ldr     w1, [x28, #ST_DIFF]
    LOAD    x2, cpu_speed
    ldrh    w1, [x2, w1, uxtw #1]
    sub     w5, w5, w4                      // step = clamp(target - pos, +/-speed)
    neg     w2, w1
    cmp     w5, w1
    csel    w5, w1, w5, gt
    cmp     w5, w2
    csel    w5, w2, w5, lt
    add     w4, w4, w5
    b       store_paddle

// cpu_new_aim: pick a fresh aiming error, wider on easier settings.
cpu_new_aim:
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp
    bl      _rand
    and     w0, w0, #0xfff
    sub     w0, w0, #2048                   // +/-8 pixels
    ldr     w1, [x28, #ST_DIFF]
    LOAD    x2, cpu_error
    ldrh    w1, [x2, w1, uxtw #1]
    mul     w0, w0, w1
    asr     w0, w0, #8
    str     w0, [x28, #ST_CPU_AIM]
    ldp     x29, x30, [sp], #16
    ret

// ball_step: move the ball, bounce it off walls and paddles, detect points.
ball_step:
    stp     x29, x30, [sp, #-48]!
    mov     x29, sp
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]
    ldp     w19, w20, [x28, #ST_BALL_X]     // x, y
    ldp     w21, w22, [x28, #ST_BALL_VX]    // vx, vy

    add     w0, w20, w22                    // vertical: walls
    mov     w1, w22
    mov     w2, #BALL_MIN_Y
    mov     w3, #BALL_MAX_Y
    bl      _reflect
    mov     w20, w0
    mov     w22, w1
    add     w19, w19, w21

    // A paddle is hit whenever the ball overlaps its column and comes close
    // enough vertically, so edge hits and late saves count.
    tbz     w21, #31, Lball_right
    mov     w0, #((PAD_L_X + PAD_W) << FP)  // moving left
    cmp     w19, w0
    b.ge    Lball_store                     // not there yet
    mov     w1, #((PAD_L_X - BALL_W) << FP)
    cmp     w19, w1
    b.le    1f                              // already behind the paddle
    ldr     w1, [x28, #ST_PADS]
    bl      hit_offset
    cbz     w1, Lball_store
    mov     w19, #((PAD_L_X + PAD_W) << FP) // place it on the face
    b       Lball_bounce
1:  mov     w0, #-(BALL_W << FP)
    cmp     w19, w0
    b.gt    Lball_store
    mov     w0, #1                          // out on the left: right scores
    b       Lball_point

Lball_right:
    mov     w0, #((PAD_R_X - BALL_W) << FP)
    cmp     w19, w0
    b.le    Lball_store
    mov     w1, #((PAD_R_X + PAD_W) << FP)
    cmp     w19, w1
    b.ge    1f
    ldr     w1, [x28, #(ST_PADS + 4)]
    bl      hit_offset
    cbz     w1, Lball_store
    mov     w19, #((PAD_R_X - BALL_W) << FP)
    b       Lball_bounce
1:  mov     w0, #(PX_W << FP)
    cmp     w19, w0
    b.lt    Lball_store
    mov     w0, #0                          // out on the right: left scores
    b       Lball_point

Lball_bounce:                               // w0 = offset from the paddle centre
    mov     w1, #BALL_ANGLE                 // the further out, the steeper
    mul     w22, w0, w1
    asr     w22, w22, #8
    cmp     w21, #0
    cneg    w0, w21, lt                     // speed up
    add     w0, w0, #BALL_ACCEL
    mov     w1, #BALL_MAX_VX
    cmp     w0, w1
    csel    w0, w1, w0, gt
    cmp     w21, #0
    cneg    w21, w0, gt                     // reverse
    bl      _rand
    and     w0, w0, #15                     // bit of randomness
    sub     w0, w0, #8
    add     w22, w22, w0
    bl      cpu_new_aim

Lball_store:
    stp     w19, w20, [x28, #ST_BALL_X]
    stp     w21, w22, [x28, #ST_BALL_VX]
    b       Lball_done

Lball_point:
    stp     w19, w20, [x28, #ST_BALL_X]     // leave it off screen
    bl      award_point

Lball_done:
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret

// hit_offset: w1 = paddle top, w20 = ball y (caller's register).
// Returns w0 = ball centre minus paddle centre, and w1 = 1 if that is a hit.
hit_offset:
    sub     w0, w20, w1
    sub     w0, w0, #((PAD_H - BALL_H) << (FP - 1))
    cmp     w0, #0
    cneg    w2, w0, lt
    mov     w3, #HIT_REACH
    cmp     w2, w3
    cset    w1, le
    ret

// award_point: w0 = scoring side. Ends the match or serves to the loser.
award_point:
    add     x1, x28, #ST_SCORES
    ldr     w2, [x1, w0, uxtw #2]
    add     w2, w2, #1
    str     w2, [x1, w0, uxtw #2]
    cmp     w2, #WIN_SCORE
    b.lo    1f
    str     w0, [x28, #ST_WINNER]
    mov     w1, #SCR_OVER
    str     w1, [x28, #ST_SCREEN]
    ret
1:  mov     w1, #SERVE_VX
    neg     w2, w1
    cmp     w0, #0
    csel    w0, w1, w2, eq
    // fall through

// serve: w0 = horizontal velocity. Centre the ball and start the countdown.
serve:
    stp     x29, x30, [sp, #-32]!
    mov     x29, sp
    str     x19, [sp, #16]
    mov     w19, w0
    mov     w0, #BALL_START_X
    mov     w1, #BALL_START_Y
    stp     w0, w1, [x28, #ST_BALL_X]
    bl      _rand
    and     w0, w0, #0xff
    sub     w0, w0, #128
    stp     w19, w0, [x28, #ST_BALL_VX]
    mov     w0, #SERVE_DELAY
    str     w0, [x28, #ST_SERVE]
    bl      cpu_new_aim
    ldr     x19, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

// play_draw: field, scores, paddles, ball, status bar, pause overlay.
    .globl _play_draw
_play_draw:
    stp     x29, x30, [sp, #-32]!
    mov     x29, sp
    stp     x19, x20, [sp, #16]

    mov     w0, #0                          // walls
    mov     w1, #WALL_TOP
    mov     w2, #PX_W
    mov     w3, #1
    mov     w4, #C_DIM
    bl      _pix_rect
    mov     w0, #0
    mov     w1, #FIELD_BOT
    mov     w2, #PX_W
    mov     w3, #1
    mov     w4, #C_DIM
    bl      _pix_rect

    mov     w19, #FIELD_TOP                 // dashed net
1:  mov     w0, #NET_X
    mov     w1, w19
    mov     w2, #2
    mov     w3, #2
    mov     w4, #C_DIM
    bl      _pix_rect
    add     w19, w19, #4
    cmp     w19, #FIELD_BOT
    b.lt    1b

    mov     w0, #(PX_W / 4 - 6)             // scores
    mov     w1, #SCORE_Y
    ldr     w2, [x28, #ST_SCORES]
    mov     w3, #C_LEFT
    bl      _draw_digit
    mov     w0, #(PX_W * 3 / 4 - 6)
    mov     w1, #SCORE_Y
    ldr     w2, [x28, #(ST_SCORES + 4)]
    mov     w3, #C_RIGHT
    bl      _draw_digit

    ldr     w1, [x28, #ST_PADS]             // paddles
    asr     w1, w1, #FP
    mov     w0, #PAD_L_X
    mov     w2, #PAD_W
    mov     w3, #PAD_H
    mov     w4, #C_LEFT
    bl      _pix_rect
    ldr     w1, [x28, #(ST_PADS + 4)]
    asr     w1, w1, #FP
    mov     w0, #PAD_R_X
    mov     w2, #PAD_W
    mov     w3, #PAD_H
    mov     w4, #C_RIGHT
    bl      _pix_rect

    ldr     w0, [x28, #ST_SERVE]            // ball, blinking before the serve
    cbz     w0, 2f
    ldr     w0, [x28, #ST_FRAME]
    tbnz    w0, #3, 3f
2:  ldr     w0, [x28, #ST_BALL_X]
    asr     w0, w0, #FP
    ldr     w1, [x28, #ST_BALL_Y]
    asr     w1, w1, #FP
    mov     w2, #BALL_W
    mov     w3, #BALL_H
    mov     w4, #C_BALL
    bl      _pix_rect

3:  ldr     w20, [x28, #ST_PLAYERS]         // names
    mov     w0, #(SCR_W / 4)
    mov     w1, #LABEL_Y
    LOAD    x2, str_p1
    mov     w3, #C_LEFT
    bl      _draw_text_c
    LOAD    x2, str_cpu
    LOAD    x0, str_p2
    cmp     w20, #2
    csel    x2, x0, x2, eq
    mov     w0, #(SCR_W * 3 / 4)
    mov     w1, #LABEL_Y
    mov     w3, #C_RIGHT
    bl      _draw_text_c

    LOAD    x2, str_keys_solo               // status bar
    LOAD    x0, str_keys_l
    cmp     w20, #2
    csel    x2, x0, x2, eq
    mov     w0, #1
    mov     w1, #STATUS_Y
    mov     w3, #C_LEFT
    bl      _draw_text
    mov     w0, #CENTER_X
    mov     w1, #STATUS_Y
    LOAD    x2, str_status
    mov     w3, #C_DIM
    bl      _draw_text_c
    LOAD    x2, str_keys_r                  // right: keys, or the CPU's level
    cmp     w20, #2
    b.eq    4f
    ldr     w0, [x28, #ST_DIFF]
    LOAD    x1, _diff_names
    ldr     x2, [x1, w0, uxtw #3]
4:  mov     w0, #(SCR_W - 5)
    mov     w1, #STATUS_Y
    mov     w3, #C_RIGHT
    bl      _draw_text_c

    ldr     w0, [x28, #ST_PAUSED]           // pause overlay
    cbz     w0, 5f
    mov     w0, #(CENTER_X - 12)
    mov     w1, #9
    mov     w2, #24
    mov     w3, #5
    mov     w4, #C_TEXT
    bl      _draw_box
    mov     w0, #CENTER_X
    mov     w1, #10
    LOAD    x2, str_paused
    mov     w3, #C_TEXT
    bl      _draw_text_c
    mov     w0, #CENTER_X
    mov     w1, #12
    LOAD    x2, str_pause_hint
    mov     w3, #C_DIM
    bl      _draw_text_c

5:  ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

// over_update: Enter for a rematch, Q / Esc for the menu.
    .globl _over_update
_over_update:
    ldr     w0, [x28, #ST_KEYS]
    tst     w0, #K_ENTER
    b.eq    1f
    b       _game_start
1:  tst     w0, #K_BACK
    b.eq    2f
    b       _menu_enter
2:  ret

// over_draw: the final field with the result on top.
    .globl _over_draw
_over_draw:
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp
    bl      _play_draw
    mov     w0, #(CENTER_X - 20)
    mov     w1, #9
    mov     w2, #40
    mov     w3, #7
    mov     w4, #C_TEXT
    bl      _draw_box

    ldr     w0, [x28, #ST_WINNER]           // headline: win_texts[winner][players - 1]
    ldr     w1, [x28, #ST_PLAYERS]
    sub     w1, w1, #1
    add     w1, w1, w0, lsl #1
    LOAD    x2, win_texts
    ldr     x2, [x2, w1, uxtw #3]
    add     w3, w0, #C_LEFT                 // in the winner's colour
    mov     w0, #CENTER_X
    mov     w1, #11
    bl      _draw_text_c
    mov     w0, #CENTER_X
    mov     w1, #13
    LOAD    x2, str_over_hint
    mov     w3, #C_DIM
    bl      _draw_text_c
    ldp     x29, x30, [sp], #16
    ret

// rand: xorshift32. Returns w0.
    .globl _rand
_rand:
    ldr     w0, [x28, #ST_RNG]
    eor     w0, w0, w0, lsl #13
    eor     w0, w0, w0, lsr #17
    eor     w0, w0, w0, lsl #5
    str     w0, [x28, #ST_RNG]
    ret

// reflect: w0 = position, w1 = velocity, w2 = low, w3 = high.
// Clamps the position to [low, high], turning the velocity away from the edge.
    .globl _reflect
_reflect:
    cmp     w0, w2
    b.ge    1f
    mov     w0, w2
    cmp     w1, #0
    cneg    w1, w1, lt
    ret
1:  cmp     w0, w3
    b.le    2f
    mov     w0, w3
    cmp     w1, #0
    cneg    w1, w1, gt
2:  ret

// --- data ---

    .section __TEXT,__const
    .p2align 1
cpu_speed:                                  // paddle speed per difficulty
    .hword  88, 136, 194
cpu_error:                                  // aiming error scale (/256 of +/-8 px)
    .hword  320, 240, 128

str_p1:         .asciz "PLAYER 1"
str_p2:         .asciz "PLAYER 2"
str_cpu:        .asciz "CPU"
str_keys_solo:  .ascii "W/S "
                .byte  G_UP, G_DOWN, 0
str_keys_l:     .asciz "W/S"
str_keys_r:     .byte  G_UP, '/', G_DOWN, 0
str_status:     .ascii "FIRST TO "
                .byte  '0' + WIN_SCORE
                .ascii "  "
                .byte  G_DOT
                .ascii "  P PAUSE  "
                .byte  G_DOT
                .asciz "  Q MENU"
str_paused:     .asciz "P A U S E D"
str_pause_hint: .ascii "P resume  "
                .byte  G_DOT
                .asciz "  Q menu"
str_you_win:    .asciz "YOU WIN!"
str_p1_wins:    .asciz "PLAYER 1 WINS!"
str_cpu_wins:   .asciz "THE CPU WINS!"
str_p2_wins:    .asciz "PLAYER 2 WINS!"
str_over_hint:  .ascii "ENTER rematch  "
                .byte  G_DOT
                .asciz "  Q menu"

    .section __DATA,__const
    .p2align 3
win_texts:                                  // [winner][players - 1]
    .quad   str_you_win, str_p1_wins
    .quad   str_cpu_wins, str_p2_wins

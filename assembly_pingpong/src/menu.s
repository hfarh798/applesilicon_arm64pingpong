// menu.s - title screen / menu, with the bouncing demo ball

.include "defs.inc"

.equ TITLE_X,           20              // pixels; 30-wide art at 4x2 per '#'
.equ TITLE_Y,           4
.equ TITLE_ROWS,        7
.equ SHADOW_OFF,        2               // full cell so colours don't clash
.equ TAGLINE_Y,         11
.equ ITEMS_Y,           13              // items sit on every other row
.equ HINT_Y,            SCR_H - 2
.equ SEL_W,             30              // highlight bar width

.equ ITEM_1P,           0
.equ ITEM_2P,           1
.equ ITEM_DIFF,         2
.equ ITEM_QUIT,         3
.equ MENU_ITEMS,        4               // must be power of 2 (wraps with and)

.equ DEMO_MAX_X,        (PX_W - 2) << FP  // 2x1 pixel ball
.equ DEMO_MAX_Y,        (PX_H - 1) << FP

    .text
    .p2align 2

// menu_enter: switch to the menu and launch the demo ball.
    .globl _menu_enter
_menu_enter:
    mov     w0, #SCR_MENU
    str     w0, [x28, #ST_SCREEN]
    mov     w0, #(24 << FP)
    mov     w1, #(8 << FP)
    stp     w0, w1, [x28, #ST_BALL_X]
    mov     w0, #220
    mov     w1, #90
    stp     w0, w1, [x28, #ST_BALL_VX]
    ret

    .globl _menu_update
_menu_update:
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp
    ldr     w9, [x28, #ST_KEYS]
    tst     w9, #K_BACK
    b.ne    Lmenu_quit

    ldr     w10, [x28, #ST_MENU_SEL]        // move the selection
    tst     w9, #K_UP
    b.eq    1f
    sub     w10, w10, #1
1:  tst     w9, #K_DOWN
    b.eq    2f
    add     w10, w10, #1
2:  and     w10, w10, #(MENU_ITEMS - 1)
    str     w10, [x28, #ST_MENU_SEL]

    cmp     w10, #ITEM_DIFF                 // left/right/enter change difficulty
    b.ne    4f
    ldr     w11, [x28, #ST_DIFF]
    tst     w9, #K_LEFT
    b.eq    3f
    add     w11, w11, #(DIFF_COUNT - 1)
3:  tst     w9, #(K_RIGHT | K_ENTER)
    cinc    w11, w11, ne
    cmp     w11, #DIFF_COUNT
    b.lo    5f
    sub     w11, w11, #DIFF_COUNT
5:  str     w11, [x28, #ST_DIFF]
    b       Lmenu_demo

4:  tst     w9, #K_ENTER
    b.eq    Lmenu_demo
    cmp     w10, #ITEM_QUIT
    b.eq    Lmenu_quit
    add     w0, w10, #1                     // ITEM_1P -> 1 player, ITEM_2P -> 2
    str     w0, [x28, #ST_PLAYERS]
    ldp     x29, x30, [sp], #16
    b       _game_start

Lmenu_quit:
    str     wzr, [x28, #ST_RUNNING]
    ldp     x29, x30, [sp], #16
    ret

Lmenu_demo:                                 // bounce the ball around the screen
    ldr     w0, [x28, #ST_BALL_X]
    ldr     w1, [x28, #ST_BALL_VX]
    add     w0, w0, w1
    mov     w2, #0
    mov     w3, #DEMO_MAX_X
    bl      _reflect
    str     w0, [x28, #ST_BALL_X]
    str     w1, [x28, #ST_BALL_VX]
    ldr     w0, [x28, #ST_BALL_Y]
    ldr     w1, [x28, #ST_BALL_VY]
    add     w0, w0, w1
    mov     w2, #0
    mov     w3, #DEMO_MAX_Y
    bl      _reflect
    str     w0, [x28, #ST_BALL_Y]
    str     w1, [x28, #ST_BALL_VY]
    ldp     x29, x30, [sp], #16
    ret

    .globl _menu_draw
_menu_draw:
    stp     x29, x30, [sp, #-48]!
    mov     x29, sp
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    ldr     w0, [x28, #ST_BALL_X]           // demo ball, behind everything
    asr     w0, w0, #FP
    ldr     w1, [x28, #ST_BALL_Y]
    asr     w1, w1, #FP
    mov     w2, #2
    mov     w3, #1
    mov     w4, #C_DIM
    bl      _pix_rect

    mov     w0, #(TITLE_X + SHADOW_OFF)     // title with a drop shadow
    mov     w1, #(TITLE_Y + SHADOW_OFF)
    mov     w6, #C_SHADOW
    bl      draw_title
    mov     w0, #TITLE_X
    mov     w1, #TITLE_Y
    mov     w6, #C_TITLE
    bl      draw_title

    mov     w0, #CENTER_X
    mov     w1, #TAGLINE_Y
    LOAD    x2, str_tagline
    mov     w3, #C_DIM
    bl      _draw_text_c

    ldr     w20, [x28, #ST_MENU_SEL]
    mov     w19, #0                         // item index
Lmenu_item:
    LOAD    x0, menu_items
    ldr     x21, [x0, x19, lsl #3]
    cmp     w19, #ITEM_DIFF
    b.ne    1f
    ldr     w0, [x28, #ST_DIFF]
    LOAD    x1, diff_items
    ldr     x21, [x1, x0, lsl #3]
1:  mov     w22, #C_TEXT
    cmp     w19, w20
    b.ne    2f
    mov     w22, #C_SEL                     // highlight bar under the selection
    mov     w0, #(CENTER_X - SEL_W / 2)
    mov     w1, #ITEMS_Y
    add     w1, w1, w19, lsl #1
    mov     w2, #SEL_W
    mov     w3, #1
    mov     w4, #' '
    mov     w5, #C_SEL
    bl      _fill_rect
2:  mov     w0, #CENTER_X
    mov     w1, #ITEMS_Y
    add     w1, w1, w19, lsl #1
    mov     x2, x21
    mov     w3, w22
    bl      _draw_text_c
    add     w19, w19, #1
    cmp     w19, #MENU_ITEMS
    b.lo    Lmenu_item

    mov     w0, #CENTER_X
    mov     w1, #HINT_Y
    LOAD    x2, str_menu_hint
    mov     w3, #C_DIM
    bl      _draw_text_c

    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret

// draw_title: w0 = x, w1 = y, w6 = colour.
draw_title:
    LOAD    x2, title_art
    mov     w3, #TITLE_ROWS
    mov     w4, #4
    mov     w5, #2
    b       _draw_art

// --- data ---

    .section __TEXT,__const
title_art:
    .asciz  "#####    ####   ##  ##   #### "
    .asciz  "##  ##  ##  ##  ### ##  ##  ##"
    .asciz  "##  ##  ##  ##  ######  ##    "
    .asciz  "#####   ##  ##  ## ###  ## ###"
    .asciz  "##      ##  ##  ##  ##  ##  ##"
    .asciz  "##      ##  ##  ##  ##  ##  ##"
    .asciz  "##       ####   ##  ##   #####"

str_tagline:    .ascii "~ "
                .byte  G_DOT
                .ascii " written in pure ARM64 assembly "
                .byte  G_DOT
                .asciz " ~"
str_item_1p:    .asciz "1 PLAYER   vs   CPU"
str_item_2p:    .asciz "2 PLAYERS"
str_item_quit:  .asciz "QUIT"
str_diff_easy:  .ascii "DIFFICULTY  "
                .asciz "<  EASY  >"
str_diff_norm:  .ascii "DIFFICULTY  "
                .asciz "<  NORMAL  >"
str_diff_hard:  .ascii "DIFFICULTY  "
                .asciz "<  HARD  >"
str_easy:       .asciz "EASY"
str_normal:     .asciz "NORMAL"
str_hard:       .asciz "HARD"
str_menu_hint:  .byte  G_UP, G_DOWN
                .ascii " select    "
                .byte  G_LEFT, G_RIGHT
                .asciz " difficulty    ENTER start    Q quit"

    .section __DATA,__const
    .p2align 3
menu_items:                                 // the difficulty row comes from diff_items
    .quad   str_item_1p, str_item_2p, 0, str_item_quit
diff_items:
    .quad   str_diff_easy, str_diff_norm, str_diff_hard
    .globl _diff_names
_diff_names:
    .quad   str_easy, str_normal, str_hard

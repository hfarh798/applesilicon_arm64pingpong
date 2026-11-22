// render.s - drawing + flushing to the terminal
//
// two layers:
//   text:   SCR_W x SCR_H halfwords. low byte = glyph (0 = transparent,
//           ascii, or a G_* code >= 0x80), high byte = colour
//   pixels: PX_W x PX_H bytes, one colour index each (0 = empty)
//
// flush merges them into one buffer and does a single write(). text wins if
// it's set, otherwise the 2x2 pixels in the cell turn into a quadrant char
// in the highest priority colour.

.include "defs.inc"

.equ GRID_BYTES,        SCR_W * SCR_H * 2
.equ PIX_BYTES,         PX_W * PX_H
.equ OUTBUF_SIZE,       65536
.equ DIGIT_BYTES,       20              // 5 rows of "xxx\0"
.equ CR_BG,             14              // colour record: has-background flag
.equ CR_LEN,            15              //                sequence length

    .text
    .p2align 2

// clear_layers: make the text layer transparent and the pixel layer empty.
    .globl _clear_layers
_clear_layers:
    movi    v0.16b, #0
    LOAD    x0, grid
    mov     x1, #(GRID_BYTES / 32)
1:  stp     q0, q0, [x0], #32
    subs    x1, x1, #1
    b.ne    1b
    LOAD    x0, pix
    mov     x1, #(PIX_BYTES / 32)
2:  stp     q0, q0, [x0], #32
    subs    x1, x1, #1
    b.ne    2b
    ret

// --- pixels ---

// pix_rect: w0 = x, w1 = y, w2 = width, w3 = height, w4 = colour. Clipped.
    .globl _pix_rect
_pix_rect:
    add     w2, w2, w0                      // right edge (exclusive)
    add     w3, w3, w1                      // bottom edge (exclusive)
    cmp     w0, #0
    csel    w0, wzr, w0, lt
    cmp     w1, #0
    csel    w1, wzr, w1, lt
    mov     w6, #PX_W
    cmp     w2, w6
    csel    w2, w6, w2, gt
    mov     w6, #PX_H
    cmp     w3, w6
    csel    w3, w6, w3, gt
    cmp     w0, w2
    b.ge    3f
    cmp     w1, w3
    b.ge    3f
    LOAD    x7, pix
    mov     w6, #PX_W
1:  madd    w8, w1, w6, w0
    add     x8, x7, w8, uxtw                // first pixel of this row
    sub     w9, w2, w0
2:  strb    w4, [x8], #1
    subs    w9, w9, #1
    b.ne    2b
    add     w1, w1, #1
    cmp     w1, w3
    b.lt    1b
3:  ret

// draw_art: blow up ASCII art into the pixel layer, each '#' becoming an
// sx x sy block. w0 = x, w1 = y, x2 = art (rows of NUL-terminated strings),
// w3 = rows, w4 = sx, w5 = sy, w6 = colour.
    .globl _draw_art
_draw_art:
    stp     x29, x30, [sp, #-80]!
    mov     x29, sp
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]
    stp     x23, x24, [sp, #48]
    stp     x25, x26, [sp, #64]
    mov     w19, w0                         // left edge
    mov     w20, w1                         // current y
    mov     x21, x2                         // art cursor
    mov     w22, w3                         // rows left
    mov     w23, w4
    mov     w24, w5
    mov     w25, w6
Lart_row:
    cbz     w22, Lart_done
    mov     w26, w19                        // current x
Lart_char:
    ldrb    w0, [x21], #1
    cbz     w0, Lart_row_end
    cmp     w0, #'#'
    b.ne    1f
    mov     w0, w26
    mov     w1, w20
    mov     w2, w23
    mov     w3, w24
    mov     w4, w25
    bl      _pix_rect
1:  add     w26, w26, w23
    b       Lart_char
Lart_row_end:
    add     w20, w20, w24
    sub     w22, w22, #1
    b       Lart_row
Lart_done:
    ldp     x25, x26, [sp, #64]
    ldp     x23, x24, [sp, #48]
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #80
    ret

// draw_digit: w0 = x, w1 = y (pixels), w2 = digit 0..9, w3 = colour.
// 12x10 pixels, i.e. 6x5 cells.
    .globl _draw_digit
_draw_digit:
    LOAD    x9, digit_art
    mov     w10, #DIGIT_BYTES
    umaddl  x2, w2, w10, x9
    mov     w6, w3
    mov     w3, #5
    mov     w4, #4
    mov     w5, #2
    b       _draw_art

// --- text ---

// fill_rect: w0 = x, w1 = y, w2 = width, w3 = height, w4 = glyph, w5 = colour.
// Text layer, in cells. Clipped.
    .globl _fill_rect
_fill_rect:
    add     w2, w2, w0
    add     w3, w3, w1
    cmp     w0, #0
    csel    w0, wzr, w0, lt
    cmp     w1, #0
    csel    w1, wzr, w1, lt
    mov     w6, #SCR_W
    cmp     w2, w6
    csel    w2, w6, w2, gt
    mov     w6, #SCR_H
    cmp     w3, w6
    csel    w3, w6, w3, gt
    cmp     w0, w2
    b.ge    3f
    cmp     w1, w3
    b.ge    3f
    orr     w4, w4, w5, lsl #8              // packed cell
    LOAD    x7, grid
    mov     w6, #SCR_W
1:  madd    w8, w1, w6, w0
    add     x8, x7, w8, uxtw #1
    sub     w9, w2, w0
2:  strh    w4, [x8], #2
    subs    w9, w9, #1
    b.ne    2b
    add     w1, w1, #1
    cmp     w1, w3
    b.lt    1b
3:  ret

// draw_text: w0 = x, w1 = y, x2 = NUL-terminated string, w3 = colour.
    .globl _draw_text
_draw_text:
    cmp     w1, #SCR_H
    b.hs    3f                              // row off screen
    LOAD    x9, grid
    mov     w10, #(SCR_W * 2)
    umaddl  x9, w1, w10, x9                 // start of the row
    lsl     w3, w3, #8
1:  ldrb    w4, [x2], #1
    cbz     w4, 3f
    cmp     w0, #SCR_W
    b.hs    2f                              // column off screen
    orr     w4, w4, w3
    strh    w4, [x9, w0, uxtw #1]
2:  add     w0, w0, #1
    b       1b
3:  ret

// draw_text_c: like draw_text, but w0 is the column to centre on.
    .globl _draw_text_c
_draw_text_c:
    mov     x9, x2
1:  ldrb    w10, [x9], #1
    cbnz    w10, 1b
    sub     x9, x9, x2
    sub     w9, w9, #1                      // length
    sub     w0, w0, w9, lsr #1
    b       _draw_text

// draw_box: w0 = x, w1 = y, w2 = width (>= 3), w3 = height (>= 2), w4 = colour.
// A rounded frame with a blank interior; must lie fully on screen.
    .globl _draw_box
_draw_box:
    LOAD    x9, grid
    mov     w10, #SCR_W
    madd    w11, w1, w10, w0
    add     x9, x9, w11, uxtw #1            // top-left cell
    lsl     w4, w4, #8
    MOV32   w12, (G_TL | (G_HLINE << 8) | (G_TR << 16))
    MOV32   w13, (G_VLINE | (' ' << 8) | (G_VLINE << 16))
    MOV32   w14, (G_BL | (G_HLINE << 8) | (G_BR << 16))
    sub     w15, w3, #1
    mov     w11, #0                         // row index
1:  cmp     w11, #0                         // pick { left, fill, right } glyphs
    csel    w5, w12, w13, eq
    cmp     w11, w15
    csel    w5, w14, w5, eq
    and     w6, w5, #0xff
    orr     w6, w6, w4
    strh    w6, [x9]
    ubfx    w6, w5, #8, #8
    orr     w6, w6, w4
    add     x7, x9, #2
    sub     w8, w2, #2
2:  strh    w6, [x7], #2
    subs    w8, w8, #1
    b.ne    2b
    lsr     w6, w5, #16
    orr     w6, w6, w4
    strh    w6, [x7]
    add     x9, x9, #(SCR_W * 2)
    add     w11, w11, #1
    cmp     w11, w3
    b.lt    1b
    ret

// --- flush ---

// flush: composite both layers, centred in the terminal, and write them out.
    .globl _flush
_flush:
    stp     x29, x30, [sp, #-112]!
    mov     x29, sp
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]
    stp     x23, x24, [sp, #48]
    stp     x25, x26, [sp, #64]
    str     x27, [sp, #80]

    mov     x0, #1
    MOV32   x1, TIOCGWINSZ
    add     x2, sp, #96
    SYSCALL SYS_IOCTL
    ldrh    w21, [sp, #96]                  // rows
    ldrh    w22, [sp, #98]                  // cols
    b.cc    1f
    mov     w21, #SCR_H                     // not a tty: assume it fits
    mov     w22, #SCR_W
1:  LOAD    x19, outbuf                     // x19 = output cursor
    mov     x0, x19                         // begin a synchronized update
    LOAD    x1, seq_begin
    mov     x2, #SEQ_BEGIN_LEN
    bl      emit_bytes
    mov     x19, x0

    orr     w0, w21, w22, lsl #16           // clear once after a resize
    ldr     w1, [x28, #ST_TERM_SIZE]
    cmp     w0, w1
    b.eq    2f
    str     w0, [x28, #ST_TERM_SIZE]
    mov     x0, x19
    LOAD    x1, seq_clear
    mov     x2, #SEQ_CLEAR_LEN
    bl      emit_bytes
    mov     x19, x0
2:  cmp     w21, #SCR_H
    b.lo    Lflush_small
    cmp     w22, #SCR_W
    b.lo    Lflush_small

    sub     w21, w21, #SCR_H                // 1-based top row of the grid
    lsr     w21, w21, #1
    add     w21, w21, #1
    sub     w22, w22, #SCR_W                // 1-based left column
    lsr     w22, w22, #1
    add     w22, w22, #1
    LOAD    x20, grid                       // x20 = text cell
    LOAD    x27, pix                        // x27 = top-left pixel of the cell
    LOAD    x25, colors
    LOAD    x26, glyphs
    LOAD    x0, quad_bits                   // v16 = { 1, 2, 4, 8 }: pixel -> mask bit
    ldr     d16, [x0]
    mov     w23, #SCR_H                     // rows left
    mov     w24, #C_DEFAULT                 // active colour (seq_begin resets it)

Lflush_row:
    mov     w0, #0x5b1b                     // "\e[" row ";" col "H"
    strh    w0, [x19], #2
    mov     x0, x19
    mov     w1, w21
    bl      emit_uint
    mov     w1, #';'
    strb    w1, [x0], #1
    mov     w1, w22
    bl      emit_uint
    mov     w1, #'H'
    strb    w1, [x0], #1
    mov     x19, x0
    mov     w15, #SCR_W                     // cells left

Lflush_cell:
    ldrh    w0, [x20], #2
    ands    w1, w0, #0xff                   // w1 = glyph
    lsr     w2, w0, #8                      // w2 = colour
    b.ne    Lflush_emit                     // text covers the pixels
    ldrh    w3, [x27]                       // TL | TR << 8
    ldrh    w4, [x27, #PX_W]                // BL | BR << 8
    orr     w3, w3, w4, lsl #16
    mov     w1, #' '
    mov     w2, #C_DEFAULT
    cbz     w3, Lflush_emit                 // no pixels
    fmov    s0, w3
    umaxv   b1, v0.8b                       // strongest colour present
    umov    w2, v1.b[0]
    cmtst   v0.8b, v0.8b, v0.8b             // which quadrants are lit
    and     v0.8b, v0.8b, v16.8b
    addv    b0, v0.8b
    umov    w1, v0.b[0]
    orr     w1, w1, #G_QUAD

Lflush_emit:                                // w1 = glyph, w2 = colour
    add     x27, x27, #2
    cmp     w2, w24
    b.eq    2f
    add     x3, x25, x2, lsl #4             // x3 = new colour record
    cmp     w1, #' '                        // spaces w/o a background don't
    b.ne    1f                              // need a colour change
    ldrb    w4, [x3, #CR_BG]
    add     x5, x25, x24, lsl #4
    ldrb    w5, [x5, #CR_BG]
    orr     w4, w4, w5
    cbz     w4, 2f
1:  mov     w24, w2
    ldr     q0, [x3]
    str     q0, [x19]
    ldrb    w3, [x3, #CR_LEN]
    add     x19, x19, x3
2:  tbnz    w1, #7, 3f
    strb    w1, [x19], #1                   // ASCII
    b       4f
3:  and     w1, w1, #0x7f
    ldr     w1, [x26, x1, lsl #2]           // 3-byte UTF-8 glyph
    str     w1, [x19]
    add     x19, x19, #3
4:  subs    w15, w15, #1
    b.ne    Lflush_cell

    add     x27, x27, #PX_W                 // skip the cell row's lower pixels
    add     w21, w21, #1
    subs    w23, w23, #1
    b.ne    Lflush_row
    b       Lflush_write

Lflush_small:
    mov     x0, x19
    LOAD    x1, msg_small
    mov     x2, #MSG_SMALL_LEN
    bl      emit_bytes
    mov     x19, x0

Lflush_write:
    mov     x0, x19                         // end the synchronized update
    LOAD    x1, seq_end
    mov     x2, #SEQ_END_LEN
    bl      emit_bytes
    LOAD    x1, outbuf
    sub     x1, x0, x1
    LOAD    x0, outbuf
    bl      _write_all

    ldr     x27, [sp, #80]
    ldp     x25, x26, [sp, #64]
    ldp     x23, x24, [sp, #48]
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #112
    ret

// emit_uint: x0 = output cursor, w1 = value. Returns x0 past the digits.
emit_uint:
    mov     w2, w1
    mov     x3, x0
    mov     w4, #10
1:  add     x3, x3, #1                      // one byte per digit
    udiv    w2, w2, w4
    cbnz    w2, 1b
    mov     x0, x3
2:  udiv    w2, w1, w4                      // fill backwards
    msub    w5, w2, w4, w1
    add     w5, w5, #'0'
    strb    w5, [x3, #-1]!
    mov     w1, w2
    cbnz    w1, 2b
    ret

// emit_bytes: x0 = output cursor, x1 = source, x2 = length. Returns x0.
emit_bytes:
    cbz     x2, 2f
1:  ldrb    w3, [x1], #1
    strb    w3, [x0], #1
    subs    x2, x2, #1
    b.ne    1b
2:  ret

// --- data ---

// A 16-byte colour record: SGR escape, zero padding, has-background flag in
// byte 14, length in byte 15.
.macro COLOR seq, bg
0:  .ascii  "\seq"
1:  .space  14 - (1b - 0b)
    .byte   \bg, 1b - 0b
.endm

    .section __TEXT,__const
    .p2align 4
colors:
    COLOR   "\033[0m", 0                    // C_DEFAULT
    COLOR   "\033[0;34m", 0                 // C_SHADOW  blue
    COLOR   "\033[0;90m", 0                 // C_DIM
    COLOR   "\033[0;1;96m", 0               // C_TITLE   bright cyan
    COLOR   "\033[0;1;96m", 0               // C_LEFT    bright cyan
    COLOR   "\033[0;1;95m", 0               // C_RIGHT   bright magenta
    COLOR   "\033[0;1;93m", 0               // C_BALL    bright yellow
    COLOR   "\033[0;1;97m", 0               // C_TEXT    bold white
    COLOR   "\033[0;1;30;46m", 1            // C_SEL     black on cyan

    .p2align 3
quad_bits:
    .byte   1, 2, 4, 8, 0, 0, 0, 0

    .p2align 2
glyphs:                                     // UTF-8 for 0x80 onwards, 4-byte stride
    .byte   0x20, 0x20, 0x20, 0             // (mask 0 is drawn as a plain blank)
    .byte   0xe2, 0x96, 0x98, 0             // U+2598
    .byte   0xe2, 0x96, 0x9d, 0             // U+259D
    .byte   0xe2, 0x96, 0x80, 0             // U+2580
    .byte   0xe2, 0x96, 0x96, 0             // U+2596
    .byte   0xe2, 0x96, 0x8c, 0             // U+258C
    .byte   0xe2, 0x96, 0x9e, 0             // U+259E
    .byte   0xe2, 0x96, 0x9b, 0             // U+259B
    .byte   0xe2, 0x96, 0x97, 0             // U+2597
    .byte   0xe2, 0x96, 0x9a, 0             // U+259A
    .byte   0xe2, 0x96, 0x90, 0             // U+2590
    .byte   0xe2, 0x96, 0x9c, 0             // U+259C
    .byte   0xe2, 0x96, 0x84, 0             // U+2584
    .byte   0xe2, 0x96, 0x99, 0             // U+2599
    .byte   0xe2, 0x96, 0x9f, 0             // U+259F
    .byte   0xe2, 0x96, 0x88, 0             // U+2588
    .byte   0xe2, 0x94, 0x82, 0             // U+2502
    .byte   0xe2, 0x94, 0x80, 0             // U+2500
    .byte   0xe2, 0x95, 0xad, 0             // U+256D
    .byte   0xe2, 0x95, 0xae, 0             // U+256E
    .byte   0xe2, 0x95, 0xb0, 0             // U+2570
    .byte   0xe2, 0x95, 0xaf, 0             // U+256F
    .byte   0xe2, 0x86, 0x91, 0             // U+2191
    .byte   0xe2, 0x86, 0x93, 0             // U+2193
    .byte   0xe2, 0x86, 0x90, 0             // U+2190
    .byte   0xe2, 0x86, 0x92, 0             // U+2192
    .byte   0xe2, 0x80, 0xa2, 0             // U+2022

digit_art:                                  // 3x5 score digits
    .asciz  "###", "# #", "# #", "# #", "###"
    .asciz  " # ", "## ", " # ", " # ", "###"
    .asciz  "###", "  #", "###", "#  ", "###"
    .asciz  "###", "  #", " ##", "  #", "###"
    .asciz  "# #", "# #", "###", "  #", "  #"
    .asciz  "###", "#  ", "###", "  #", "###"
    .asciz  "###", "#  ", "###", "# #", "###"
    .asciz  "###", "  #", "  #", "  #", "  #"
    .asciz  "###", "# #", "###", "# #", "###"
    .asciz  "###", "# #", "###", "  #", "###"

seq_begin:                                  // synchronized output on, reset colour
    .ascii  "\033[?2026h\033[0m"
.equ SEQ_BEGIN_LEN, . - seq_begin
seq_end:
    .ascii  "\033[?2026l"
.equ SEQ_END_LEN, . - seq_end
seq_clear:
    .ascii  "\033[2J"
.equ SEQ_CLEAR_LEN, . - seq_clear
msg_small:
    .ascii  "\033[H\033[0mPlease enlarge the terminal to at least 80 x 24."
.equ MSG_SMALL_LEN, . - msg_small

    .zerofill __DATA,__bss,grid,GRID_BYTES,4
    .zerofill __DATA,__bss,pix,PIX_BYTES,4
    .zerofill __DATA,__bss,outbuf,OUTBUF_SIZE,4

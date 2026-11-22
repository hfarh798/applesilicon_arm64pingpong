// defs.inc - shared constants and macros
//
// NOTE: x28 = pointer to the global state block. set once in main, never
// changed after that.

// --- macros ---

// Load the address of a symbol.
.macro LOAD reg, sym
    adrp    \reg, \sym@PAGE
    add     \reg, \reg, \sym@PAGEOFF
.endm

// Load a 32-bit constant that does not fit a single mov.
.macro MOV32 reg, imm
    movz    \reg, #((\imm) & 0xffff)
    movk    \reg, #(((\imm) >> 16) & 0xffff), lsl #16
.endm

// Darwin system call: number in x16, trap with svc #0x80, carry set on error.
.macro SYSCALL num
    mov     x16, #\num
    svc     #0x80
.endm

// --- kernel ---

.equ SYS_READ,          3
.equ SYS_WRITE,         4
.equ SYS_IOCTL,         54
.equ SYS_SELECT,        93

.equ TIOCGETA,          0x40487413      // _IOR('t', 19, struct termios)
.equ TIOCSETA,          0x80487414      // _IOW('t', 20, struct termios)
.equ TIOCGWINSZ,        0x40087468      // _IOR('t', 104, struct winsize)

// --- screen ---
//
// two layers get combined into the terminal output each frame:
//   text   SCR_W x SCR_H character cells (opaque wherever something is drawn)
//   pixels PX_W x PX_H colour indices, each cell showing a 2x2 block of them
//          using the unicode quadrant block chars

.equ SCR_W,             80
.equ SCR_H,             24
.equ CENTER_X,          SCR_W / 2
.equ PX_W,              SCR_W * 2
.equ PX_H,              SCR_H * 2

.equ FP,                8               // positions are 8.8 fixed point pixels

// Colours: index into the SGR table in render.s. Where pixels of different
// colours share a cell, the highest index wins, so the order is a priority.
.equ C_DEFAULT,         0               // also "empty" in the pixel layer
.equ C_SHADOW,          1
.equ C_DIM,             2
.equ C_TITLE,           3
.equ C_LEFT,            4               // left player  (C_LEFT + 1 must be C_RIGHT)
.equ C_RIGHT,           5               // right player
.equ C_BALL,            6
.equ C_TEXT,            7
.equ C_SEL,             8               // has a background colour

// Text glyphs: grid bytes >= 0x80 expand to UTF-8 characters.
// 0x80 + mask (1..15) are the quadrant blocks, mask bits TL=1 TR=2 BL=4 BR=8.
.equ G_QUAD,            0x80
.equ G_VLINE,           0x90            // U+2502
.equ G_HLINE,           0x91            // U+2500
.equ G_TL,              0x92            // U+256D
.equ G_TR,              0x93            // U+256E
.equ G_BL,              0x94            // U+2570
.equ G_BR,              0x95            // U+256F
.equ G_UP,              0x96            // U+2191
.equ G_DOWN,            0x97            // U+2193
.equ G_LEFT,            0x98            // U+2190
.equ G_RIGHT,           0x99            // U+2192
.equ G_DOT,             0x9a            // U+2022

// --- input ---

// Key bits, used both for "pressed this frame" (ST_KEYS) and, for the four
// movement keys, "held down right now" (ST_HELD).
.equ K_UP1,             1 << 0          // W
.equ K_UP2,             1 << 1          // up arrow
.equ K_DN1,             1 << 2          // S
.equ K_DN2,             1 << 3          // down arrow
.equ K_LEFT,            1 << 4
.equ K_RIGHT,           1 << 5
.equ K_ENTER,           1 << 6
.equ K_PAUSE,           1 << 7
.equ K_BACK,            1 << 8          // Q / Esc
.equ K_QUIT,            1 << 9          // Ctrl-C
.equ K_UP,              K_UP1 | K_UP2
.equ K_DOWN,            K_DN1 | K_DN2
.equ K_MOVE,            K_UP | K_DOWN

// --- state ---

.equ SCR_MENU,          0               // screens (index into the table in main.s)
.equ SCR_PLAY,          1
.equ SCR_OVER,          2

.equ DIFF_EASY,         0
.equ DIFF_NORMAL,       1
.equ DIFF_HARD,         2
.equ DIFF_COUNT,        3

.equ ST_SCREEN,         0
.equ ST_KEYS,           4               // keys pressed (or auto-repeated) this frame
.equ ST_HELD,           8               // movement keys currently held
.equ ST_RUNNING,        12
.equ ST_FRAME,          16
.equ ST_MENU_SEL,       20
.equ ST_DIFF,           24
.equ ST_PLAYERS,        28              // 1 = vs CPU, 2 = two players
.equ ST_PAUSED,         32
.equ ST_SERVE,          36              // frames until the ball launches
.equ ST_CPU_AIM,        40              // CPU aiming error (fixed point)
.equ ST_RNG,            44
.equ ST_WINNER,         48              // 0 = left, 1 = right
.equ ST_BALL_X,         52              // ball: x, y, vx, vy (fixed point pixels)
.equ ST_BALL_Y,         56              //   (the menu reuses it for its demo ball)
.equ ST_BALL_VX,        60
.equ ST_BALL_VY,        64
.equ ST_PADS,           68              // top of the left, then the right paddle
.equ ST_SCORES,         76              // left score, then right score
.equ ST_TERM_SIZE,      84              // last seen terminal size (rows | cols << 16)
.equ ST_NEXT_TICK,      88              // u64: counter value of the next frame
.equ ST_FRAME_TICKS,    96              // u64: counter ticks per frame
.equ ST_SIZE,           112

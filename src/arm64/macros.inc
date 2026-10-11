// Helpers shared by the AArch64 sources (src/arm64/*.S).

// xd = address of a symbol defined in this executable (PC-relative, PIE safe)
.macro ADR_L xd, sym
        adrp    \xd, \sym
        add     \xd, \xd, :lo12:\sym
.endm

// xd = value of a pointer-sized libc data symbol through the GOT (stderr)
.macro LDR_GOT xd, sym
        adrp    \xd, :got:\sym
        ldr     \xd, [\xd, :got_lo12:\sym]
        ldr     \xd, [\xd]
.endm

// xd = xn + imm for any imm < 2^24 (add only takes 12 bits, optionally << 12)
.macro ADDL xd, xn, imm
.if (\imm) < 4096
        add     \xd, \xn, #(\imm)
.else
        add     \xd, \xn, #((\imm) & 0xfff)
        add     \xd, \xd, #((\imm) >> 12), lsl #12
.endif
.endm

// 64-bit constant into xd
.macro MOV64 xd, imm
        movz    \xd, #((\imm) & 0xffff)
        movk    \xd, #(((\imm) >> 16) & 0xffff), lsl #16
        movk    \xd, #(((\imm) >> 32) & 0xffff), lsl #32
        movk    \xd, #(((\imm) >> 48) & 0xffff), lsl #48
.endm

// 32-bit constant into wd
.macro MOV32 wd, imm
        movz    \wd, #((\imm) & 0xffff)
        movk    \wd, #(((\imm) >> 16) & 0xffff), lsl #16
.endm

// sd = a float constant given by its bit pattern (clobbers w16)
.macro FCONST sd, bits
        MOV32   w16, \bits
        fmov    \sd, w16
.endm

// Frame with the link register and all of x19..x28 saved, then \frame
// bytes of locals at [sp] (multiple of 16). x29 points at the saved pair.
.macro ENTER frame=0
        stp     x29, x30, [sp, #-96]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        stp     x21, x22, [sp, #32]
        stp     x23, x24, [sp, #48]
        stp     x25, x26, [sp, #64]
        stp     x27, x28, [sp, #80]
.if \frame
        sub     sp, sp, #\frame
.endif
.endm
.macro UNFRAME frame=0
.if \frame
        add     sp, sp, #\frame
.endif
        ldp     x19, x20, [sp, #16]
        ldp     x21, x22, [sp, #32]
        ldp     x23, x24, [sp, #48]
        ldp     x25, x26, [sp, #64]
        ldp     x27, x28, [sp, #80]
        ldp     x29, x30, [sp], #96
.endm
.macro LEAVE frame=0
        UNFRAME \frame
        ret
.endm

// Smaller frames: link register plus 2 or 4 callee-saved registers
.macro ENTER2
        stp     x29, x30, [sp, #-32]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
.endm
.macro LEAVE2
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #32
        ret
.endm
.macro ENTER4
        stp     x29, x30, [sp, #-48]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        stp     x21, x22, [sp, #32]
.endm
.macro LEAVE4
        ldp     x19, x20, [sp, #16]
        ldp     x21, x22, [sp, #32]
        ldp     x29, x30, [sp], #48
        ret
.endm

// Loads of a constant or a global through adrp + :lo12: (the target must be
// aligned to the access size). xt is clobbered.
.macro LDRS sd, sym, xt
        adrp    \xt, \sym
        ldr     \sd, [\xt, :lo12:\sym]
.endm

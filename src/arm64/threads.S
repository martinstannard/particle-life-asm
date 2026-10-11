// Multi-threaded step, AArch64 port of src/threads.S: persistent pthreads
// that sleep on a pthread barrier between steps. Within a step: force pass
// with cells handed out in chunks from a shared atomic counter (dynamic
// schedule), then the four parallel-bin phases of sim.S, separated by a
// spinning barrier.
//
// Memory ordering. x86 is TSO, AArch64 is weakly ordered, so every handoff
// carries explicit acquire/release semantics (ARMv8.0: exclusives, no LSE
// atomics on the Cortex-A72):
//   * spin barrier arrival: LDAXR/STLXR increment of spin_count (acquire +
//     release), so each arrival publishes the thread's writes of the phase
//     and the last arrival has acquired all of them;
//   * the last thread resets the count and then STLR's the new generation;
//     the others spin on LDAR of the generation. Release/acquire is
//     cumulative on ARMv8 (other-multi-copy atomic), so every write made by
//     any thread before the barrier is visible to every thread after it;
//   * the generation is read with LDAR before arriving: the STLXR of the
//     arrival is ordered after that read, so a waiter can never read the
//     generation of the barrier it is waiting for;
//   * the chunk counter only distributes cells (relaxed LDXR/STXR): the
//     data the kernels write is published by the barrier that follows;
//   * the start of a step goes through pthread_barrier_wait, which is a full
//     barrier (it orders thread 0's next_cell/chunk setup and the swapped
//     particle set before the workers read them).
// Threads are not pinned: the dynamic cell chunks already absorb a thread
// that is descheduled for a while, and on a 4-core Pi the main thread also
// renders and presents, so leaving placement to the scheduler is cheaper
// than fighting it.

        .include "layout.inc"
        .include "macros.inc"

.set MAXTHREADS, 64

        .bss
        .balign 64
bar_start:  .skip 64            // pthread_barrier_t (32 bytes on aarch64 glibc)
next_cell:  .skip 64            // own cache line
spin_count: .skip 64
spin_gen:   .skip 64
chunk:      .skip 4
        .balign 8
tids:       .skip 8 * MAXTHREADS

        .text

// int pl_threads_start(u32 n): start n-1 workers (caller is thread 0).
        .globl pl_threads_start
        .type pl_threads_start, %function
pl_threads_start:
        ENTER
        mov     w19, w0
        cmp     w19, #MAXTHREADS
        b.ls    1f
        mov     w19, #MAXTHREADS
1:      ADR_L   x20, pl
        cmp     w19, #1
        b.hi    2f
        mov     w9, #1
        str     w9, [x20, #PL_NTHREADS]
        mov     w0, #0
        LEAVE
2:      ADR_L   x0, bar_start
        mov     x1, #0
        mov     w2, w19
        bl      pthread_barrier_init
        mov     w21, #1
3:      cmp     w21, w19
        b.hs    4f
        ADR_L   x0, tids
        add     x0, x0, x21, lsl #3
        mov     x1, #0
        ADR_L   x2, worker
        mov     x3, x21
        bl      pthread_create
        cbnz    w0, 9f
        add     w21, w21, #1
        b       3b
4:      str     w19, [x20, #PL_NTHREADS]
        mov     w0, #0
9:      LEAVE

// grab chunks of cells until none are left
run_chunks:
        ENTER
        ADR_L   x19, pl
        ADR_L   x20, next_cell
        LDRS    w21, chunk, x9
1:      ldxr    w0, [x20]                       // relaxed fetch-add
        add     w1, w0, w21
        stxr    w2, w1, [x20]
        cbnz    w2, 1b
        ldr     w22, [x19, #PL_NCELLS]
        cmp     w0, w22
        b.hs    2f
        add     w1, w0, w21
        cmp     w1, w22
        csel    w1, w22, w1, hi
        ldr     x9, [x19, #PL_KERNEL]
        blr     x9
        b       1b
2:      LEAVE

// sense-free spinning barrier over all NTHREADS threads (see the header)
spin_barrier:
        ENTER2
        ADR_L   x19, spin_gen
        ldar    w20, [x19]                      // generation of this barrier
        ADR_L   x9, spin_count
1:      ldaxr   w0, [x9]
        add     w0, w0, #1
        stlxr   w1, w0, [x9]
        cbnz    w1, 1b
        ADR_L   x10, pl
        ldr     w10, [x10, #PL_NTHREADS]
        cmp     w0, w10
        b.ne    2f
        str     wzr, [x9]                       // ordered before the release below
        add     w20, w20, #1
        stlr    w20, [x19]                      // release everyone
        LEAVE2
2:      mov     w11, #4096                      // spin a while, then yield the CPU
3:      yield
        ldar    w0, [x19]
        cmp     w0, w20
        b.ne    4f
        subs    w11, w11, #1
        b.ne    3b
        bl      sched_yield
        ldar    w0, [x19]
        cmp     w0, w20
        b.eq    2b
4:      LEAVE2

// one step on thread w0
step_job:
        ENTER2
        mov     w19, w0
        bl      run_chunks
        bl      spin_barrier
        mov     w0, w19
        bl      pl_pbin_count
        bl      spin_barrier
        mov     w0, w19
        bl      pl_pbin_sum
        bl      spin_barrier
        mov     w0, w19
        bl      pl_pbin_offsets
        bl      spin_barrier
        mov     w0, w19
        bl      pl_pbin_scatter
        bl      spin_barrier
        LEAVE2

worker:                                         // x0 = thread index
        ENTER2
        mov     w19, w0
1:      ADR_L   x0, bar_start
        bl      pthread_barrier_wait
        mov     w0, w19
        bl      step_job
        b       1b

// void pl_mt_step(void): one full step (forces + bin) on all threads
        .globl pl_mt_step
        .type pl_mt_step, %function
pl_mt_step:
        ENTER2
        ADR_L   x19, pl
        // histograms: NTHREADS * (ncells + 1)
        ldr     w9, [x19, #PL_NCELLS]
        add     w9, w9, #1
        ldr     w10, [x19, #PL_NTHREADS]
        mul     w20, w9, w10
        LDRS    w11, pbin_cap, x12
        cmp     w20, w11
        b.ls    1f
        LDRS    x0, pbin_hist, x12
        bl      free
        lsl     x0, x20, #2
        bl      malloc
        cbz     x0, 9f
        ADR_L   x12, pbin_hist
        str     x0, [x12]
        ADR_L   x12, pbin_cap
        str     w20, [x12]
1:      ADR_L   x9, next_cell
        str     wzr, [x9]
        ldr     w9, [x19, #PL_NCELLS]
        ldr     w10, [x19, #PL_NTHREADS]
        lsl     w10, w10, #4                    // ~16 chunks per thread
        udiv    w9, w9, w10
        cmp     w9, #1
        csinc   w9, w9, wzr, hs                 // max(chunk, 1)
        ADR_L   x10, chunk
        str     w9, [x10]
        ADR_L   x0, bar_start
        bl      pthread_barrier_wait
        mov     w0, #0
        bl      step_job
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #32
        b       pl_swap_sets
9:      bl      abort

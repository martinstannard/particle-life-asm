# Multi-threaded step: persistent pthreads that sleep on a pthread barrier
# between steps. Within a step: force pass with cells handed out in chunks
# from a shared atomic counter (dynamic schedule, because clustered particles
# make per-cell work very uneven), then the four parallel-bin phases of
# sim.S, separated by a spinning barrier.

        .intel_syntax noprefix
        .include "layout.inc"

.set MAXTHREADS, 64

        .bss
        .balign 64
bar_start:  .skip 64
next_cell:  .skip 64            # own cache line
spin_count: .skip 64
spin_gen:   .skip 64
chunk:      .skip 4
tids:       .skip 8 * MAXTHREADS

        .text

# int pl_threads_start(u32 n): start n-1 workers (caller is thread 0).
        .globl pl_threads_start
pl_threads_start:
        push    rbx
        push    r12
        push    r13                     # rsp aligned
        mov     r12d, edi
        cmp     r12d, MAXTHREADS
        jbe     1f
        mov     r12d, MAXTHREADS
1:      cmp     r12d, 1
        ja      2f
        mov     dword ptr [rip + pl + PL_NTHREADS], 1
        xor     eax, eax
        jmp     9f
2:      lea     rdi, [rip + bar_start]
        xor     esi, esi
        mov     edx, r12d
        call    pthread_barrier_init@PLT
        mov     ebx, 1
3:      cmp     ebx, r12d
        jae     4f
        lea     rdi, [rip + tids]
        lea     rdi, [rdi + rbx*8]
        xor     esi, esi
        lea     rdx, [rip + worker]
        mov     ecx, ebx
        call    pthread_create@PLT
        test    eax, eax
        jnz     9f
        inc     ebx
        jmp     3b
4:      mov     [rip + pl + PL_NTHREADS], r12d
        xor     eax, eax
9:      pop     r13
        pop     r12
        pop     rbx
        ret

# grab chunks of cells until none are left
run_chunks:
        push    rbx
        push    r12
        push    r13
        lea     r13, [rip + pl]
1:      mov     ebx, [rip + chunk]
        mov     eax, ebx
        lock xadd [rip + next_cell], eax
        mov     edi, eax
        mov     r12d, [r13 + PL_NCELLS]
        cmp     edi, r12d
        jae     2f
        lea     esi, [edi + ebx]
        cmp     esi, r12d
        cmova   esi, r12d
        call    [r13 + PL_KERNEL]
        jmp     1b
2:      pop     r13
        pop     r12
        pop     rbx
        ret

# sense-free spinning barrier over all NTHREADS threads
spin_barrier:
        mov     edx, [rip + spin_gen]
        mov     eax, 1
        lock xadd [rip + spin_count], eax
        inc     eax
        cmp     eax, [rip + pl + PL_NTHREADS]
        jne     1f
        mov     dword ptr [rip + spin_count], 0
        lock inc dword ptr [rip + spin_gen]
        ret
1:      mov     ecx, 4096               # spin a while, then yield the CPU
2:      pause
        cmp     [rip + spin_gen], edx
        jne     3f
        dec     ecx
        jnz     2b
        push    rdx
        call    sched_yield@PLT         # rsp aligned (caller frame + push)
        pop     rdx
        cmp     [rip + spin_gen], edx
        je      1b
3:      ret

# one step on thread edi
step_job:
        push    rbx                     # rsp aligned
        mov     ebx, edi
        call    run_chunks
        call    spin_barrier
        mov     edi, ebx
        call    pl_pbin_count
        call    spin_barrier
        mov     edi, ebx
        call    pl_pbin_sum
        call    spin_barrier
        mov     edi, ebx
        call    pl_pbin_offsets
        call    spin_barrier
        mov     edi, ebx
        call    pl_pbin_scatter
        call    spin_barrier
        pop     rbx
        ret

worker:                                 # edi = thread index
        push    rbx                     # rsp aligned
        mov     ebx, edi
1:      lea     rdi, [rip + bar_start]
        call    pthread_barrier_wait@PLT
        mov     edi, ebx
        call    step_job
        jmp     1b

# void pl_mt_step(void): one full step (forces + bin) on all threads
        .globl pl_mt_step
pl_mt_step:
        push    rbx                     # rsp aligned
        # histograms: NTHREADS * (ncells + 1)
        mov     eax, [rip + pl + PL_NCELLS]
        inc     eax
        imul    eax, [rip + pl + PL_NTHREADS]
        cmp     eax, [rip + pbin_cap]
        jbe     1f
        mov     ebx, eax
        mov     rdi, [rip + pbin_hist]
        call    free@PLT
        mov     edi, ebx
        shl     rdi, 2
        call    malloc@PLT
        test    rax, rax
        jz      9f
        mov     [rip + pbin_hist], rax
        mov     [rip + pbin_cap], ebx
1:      mov     dword ptr [rip + next_cell], 0
        mov     eax, [rip + pl + PL_NCELLS]
        mov     ecx, [rip + pl + PL_NTHREADS]
        shl     ecx, 4                  # ~16 chunks per thread
        xor     edx, edx
        div     ecx
        mov     ecx, 1
        cmp     eax, ecx
        cmovb   eax, ecx
        mov     [rip + chunk], eax
        lea     rdi, [rip + bar_start]
        call    pthread_barrier_wait@PLT
        xor     edi, edi
        call    step_job
        pop     rbx
        jmp     pl_swap_sets
9:      call    abort@PLT

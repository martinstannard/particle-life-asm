# Multi-threaded force pass: persistent pthreads, two barriers per step,
# cells handed out in chunks from a shared atomic counter (dynamic schedule,
# because clustered particles make per-cell work very uneven).

        .intel_syntax noprefix
        .include "layout.inc"

.set MAXTHREADS, 64

        .bss
        .balign 64
bar_start:  .skip 64
bar_end:    .skip 64
next_cell:  .skip 64            # own cache line
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
        lea     rdi, [rip + bar_end]
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

worker:
        push    rbx                     # rsp aligned
1:      lea     rdi, [rip + bar_start]
        call    pthread_barrier_wait@PLT
        call    run_chunks
        lea     rdi, [rip + bar_end]
        call    pthread_barrier_wait@PLT
        jmp     1b

# void pl_mt_forces(void): run the force kernel over all cells on all threads
        .globl pl_mt_forces
pl_mt_forces:
        push    rbx                     # rsp aligned
        mov     dword ptr [rip + next_cell], 0
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
        call    run_chunks
        lea     rdi, [rip + bar_end]
        call    pthread_barrier_wait@PLT
        pop     rbx
        ret

/*
 * Copyright (c) 2022, Intel Corporation
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#include <xtensa_asm2_s.h>
#include <zephyr/offsets.h>
#include <offsets_short.h>
#include <zephyr/syscall.h>
#include <zephyr/zsr.h>

#include <xtensa/config/core-isa.h>

/**
 *  syscall number     arg1, arg2, arg3, arg4, arg5, arg6
 *  --------------     ----------------------------------
 *  a2                 a6,   a3,   a4,   a5,   a8,   a9
 *
 **/
.pushsection .text.xtensa_do_syscall, "ax"
.global	xtensa_do_syscall
.align	4
xtensa_do_syscall:
#if XCHAL_HAVE_THREADPTR == 0
	wsr a2, ZSR_SYSCALL_SCRATCH
	rsync

	movi a0, xtensa_is_user_context_epc
	rsr.epc1 a2
	bne a0, a2, _not_checking_user_context

	addi a2, a2, 3
	wsr.epc1 a2

	movi a0, PS_RING_MASK
	rsr.ps a2
	and a2, a2, a0

	/* Need to set return to 1 if RING != 0,
	 * so we won't be leaking which ring we are in
	 * right now.
	 */
	beqz a2, _is_user_context_return

	movi a2, 1

_is_user_context_return:
	rsr a0, ZSR_A0SAVE

	rfe

_not_checking_user_context:
	rsr a2, ZSR_SYSCALL_SCRATCH
#endif

	/* Need to disable any interrupts while we are saving
	 * register content to avoid any interferences.
	 */
	rsil a0, 0xf

	rsr a0, ZSR_CPU
	l32i a0, a0, ___cpu_t_current_OFFSET
	l32i a0, a0, _thread_offset_to_psp

	addi a0, a0, -___xtensa_irq_bsa_t_SIZEOF

	s32i a1, a0, ___xtensa_irq_bsa_t_scratch_OFFSET
	s32i a2, a0, ___xtensa_irq_bsa_t_a2_OFFSET
	s32i a3, a0, ___xtensa_irq_bsa_t_a3_OFFSET
	rsr a2, ZSR_A0SAVE
	s32i a2, a0, ___xtensa_irq_bsa_t_a0_OFFSET
	rsr.ps a2
	movi a3, ~PS_OWB_MASK & ~PS_EXCM_MASK
	and a2, a2, a3
	s32i a2, a0, ___xtensa_irq_bsa_t_ps_OFFSET

	/* Manipulate PC where we will return to after syscall.
	 * This is needed as syscall will stash the PC where
	 * the syscall instruction locates, instead of
	 * the instruction after it. We need to increment it to
	 * execute the next instruction when we return.
	 * The instruction size is 3 bytes, so lets just add it.
	 */
	rsr.epc1 a3
	addi a3, a3, 3
	s32i a3, a0, ___xtensa_irq_bsa_t_pc_OFFSET

	/* Need to setup PS so we can spill all registers.
	 * EXCM and RING bits need to be cleared as CPU
	 * needs to run in kernel and non-exception modes
	 * for window rotation to work.
	 */
	rsr.ps a3
	movi a2, ~(PS_EXCM | PS_RING_MASK)
	and a3, a3, a2
	wsr.ps a3
	rsync
	l32i a2, a0, ___xtensa_irq_bsa_t_a2_OFFSET
	l32i a3, a0, ___xtensa_irq_bsa_t_a3_OFFSET
	SPILL_ALL_WINDOWS

	rsr a0, ZSR_CPU
	l32i a0, a0, ___cpu_t_current_OFFSET
	l32i a0, a0, _thread_offset_to_psp
	addi a0, a0, -___xtensa_irq_bsa_t_SIZEOF

	mov a1, a0

	ODD_REG_SAVE a0, a1

	call0 xtensa_save_high_regs

	l32i a2, a1, 0
	l32i a2, a2, ___xtensa_irq_bsa_t_a2_OFFSET
	movi a0, K_SYSCALL_LIMIT
	bgeu a2, a0, _bad_syscall

_id_ok:
	/* Find the function handler for the given syscall id. */
	movi a3, _k_syscall_table
	addx4 a2, a2, a3
	l32i a2, a2, 0

#if XCHAL_HAVE_THREADPTR
	/* Clear up the threadptr because it is used
	 * to check if a thread is running on user mode. Since
	 * we are in a interruption we don't want the system
	 * thinking it is possibly running in user mode.
	 */
#ifdef CONFIG_THREAD_LOCAL_STORAGE
	movi a0, is_user_mode@tpoff
	rur.THREADPTR a3
	add a0, a3, a0

	movi a3, 0
	s32i a3, a0, 0
#else
	movi a0, 0
	wur.THREADPTR a0
#endif
#endif /* XCHAL_HAVE_THREADPTR */

	/* Set syscall parameters by moving them into place before we do
	 * a call4 for the syscall function itself.
	 * arg1 = a6
	 * arg2 = a3 (clobbered above, so we need to reload it)
	 * arg3 = a4
	 * arg4 = a5
	 * arg5 = a8
	 * arg6 = a9
	 */
	mov a10, a8
	mov a11, a9
	mov a8, a4
	mov a9, a5

	/* Stack frame pointer is the 7th argument to z_mrsh_*()
	 * as ssf, and must be put on stack to be consumed.
	 *
	 * Subtract 16 bytes as stack needs to be 16-byte aligned.
	 */
	mov a3, a1
	addi a1, a1, -16
	s32i a3, a1, 0

	l32i a3, a1, 16
	l32i a7, a3, ___xtensa_irq_bsa_t_a3_OFFSET


	/* Since we are unmasking EXCM, we need to set RING bits to kernel
	 * mode, otherwise we won't be able to run the exception handler in C.
	 */
	movi a0, PS_WOE|PS_CALLINC(0)|PS_UM|PS_INTLEVEL(0)
	wsr.ps a0
	rsync

	callx4 a2

	/* Going back before stack frame pointer on stack to
	 * actual the stack frame. So restoration of registers
	 * can be done properly when finishing syscalls.
	 */
	addi a1, a1, 16

	/* copy return value. Lets put it in the top of stack
	 * because registers will be clobbered in
         * xtensa_restore_high_regs
	 */
	l32i a3, a1, 0
	s32i a6, a3, ___xtensa_irq_bsa_t_a2_OFFSET

_syscall_returned:
	/* Disable interrupts as we are restoring context. */
	rsil a0, 0xf

	call0 xtensa_restore_high_regs

	ODD_REG_RESTORE a3, a1

#if XCHAL_HAVE_THREADPTR
#ifdef CONFIG_THREAD_LOCAL_STORAGE
	l32i a3, a1, ___xtensa_irq_bsa_t_threadptr_OFFSET
	movi a0, is_user_mode@tpoff
	add a0, a3, a0
	movi a3, 1
	s32i a3, a0, 0
#endif
#endif /* XCHAL_HAVE_THREADPTR */

	l32i a3, a1, ___xtensa_irq_bsa_t_ps_OFFSET
	wsr.ZSR_EPS a3

	l32i a3, a1, ___xtensa_irq_bsa_t_pc_OFFSET
	wsr.ZSR_EPC a3

	l32i a0, a1, ___xtensa_irq_bsa_t_a0_OFFSET
	l32i a2, a1, ___xtensa_irq_bsa_t_a2_OFFSET
	l32i a3, a1, ___xtensa_irq_bsa_t_a3_OFFSET

	l32i a1, a1, ___xtensa_irq_bsa_t_scratch_OFFSET
	rsync

	rfi ZSR_RFI_LEVEL

_bad_syscall:
	movi a2, K_SYSCALL_BAD
	j _id_ok

.popsection

/* FUNC_NORETURN void xtensa_userspace_enter(k_thread_entry_t user_entry,
 *					   void *p1, void *p2, void *p3,
 *					   uint32_t stack_end,
 *					   uint32_t stack_start)
 *
 * A one-way trip to userspace.
 */
.global xtensa_userspace_enter
.type xtensa_userspace_enter, @function
.align 4
xtensa_userspace_enter:
	/* Call entry to set a bit in the windowstart and
	 * do the rotation, but we are going to set our own
	 * stack.
	 */
	entry a1, 16

	SPILL_ALL_WINDOWS

	/* We have to switch to kernel stack before spill kernel data and
	 * erase user stack to avoid leak from previous context.
	 */
	mov a1, a7 /* stack start (low address) */

	rsr a0, ZSR_CPU
	l32i a0, a0, ___cpu_t_current_OFFSET

	addi a1, a1, -28
	s32i a0, a1, 24
	s32i a2, a1, 20
	s32i a3, a1, 16
	s32i a4, a1, 12
	s32i a5, a1, 8
	s32i a6, a1, 4
	s32i a7, a1, 0

	l32i a6, a1, 24
	call4 xtensa_user_stack_perms

	l32i a6, a1, 24
#ifdef CONFIG_XTENSA_MMU
#ifdef CONFIG_XTENSA_MMU_FLUSH_AUTOREFILL_DTLBS_ON_SWAP
	call4 xtensa_swap_update_page_tables
#else
	SWAP_PAGE_TABLE a6, a3, a7
#endif
#endif
#ifdef CONFIG_XTENSA_MPU
	call4 xtensa_mpu_map_write
#endif

#if XCHAL_HAVE_THREADPTR
#ifdef CONFIG_THREAD_LOCAL_STORAGE
	rur.threadptr a3
	movi a0, is_user_mode@tpoff
	add a0, a3, a0
	movi a3, 1
	s32i a3, a0, 0
#else
	rsr a3, ZSR_CPU
	l32i a3, a3, ___cpu_t_current_OFFSET
	wur.THREADPTR a3
#endif
#endif /* XCHAL_HAVE_THREADPTR */

	/* Set now z_thread_entry parameters, we are simulating a call4
	 * call, so parameters start at a6, a7, ...
	 */
	l32i a6, a1, 20
	l32i a7, a1, 16
	l32i a8, a1, 12
	l32i a9, a1, 8

	/* Go back to user stack */
	l32i a1, a1, 4

	/* Disabling interrupts as we need to use ZSR_EPC and ZSR_EPS */
	rsil a0, 0xf

	movi a0, z_thread_entry
	wsr.ZSR_EPC a0

	/* Configuring PS register.
	 * We have to set callinc as well, since the called
	 * function will do "entry"
	 */
#ifdef CONFIG_XTENSA_MMU
	movi a0, PS_WOE|PS_CALLINC(1)|PS_UM|PS_RING(2)
#endif
#ifdef CONFIG_XTENSA_MPU
	/* MPU only has RING 0 and 1. */
	movi a0, PS_WOE|PS_CALLINC(1)|PS_UM|PS_RING(1)
#endif

	wsr.ZSR_EPS a0

	/* Wipe out a0 (thre is no return from this function */
	movi a0, 0

	rfi ZSR_RFI_LEVEL

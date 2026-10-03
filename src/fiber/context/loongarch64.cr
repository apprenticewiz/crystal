{% skip_file unless flag?(:loongarch64) %}

class Fiber
  # :nodoc:
  def makecontext(stack_ptr, fiber_main) : Nil
    # in LoongArch64, the context switch push/pop 11 registers and 8 FPU
    # registers, and two more to store the argument of `fiber_main` (+ padding
    # and alignment), we thus reserve space for 22 pointers:
    @context.stack_top = (stack_ptr - 22).as(Void*)
    @context.resumable = 1

    stack_ptr[-2] = self.as(Void*)      # $a0: puts `self` as first argument for `fiber_main`
    stack_ptr[-14] = fiber_main.pointer # $ra: initial `resume` will `jr` to this address
  end

  # :nodoc:
  @[NoInline]
  @[Naked]
  def self.swapcontext(current_context, new_context) : Nil
    #                  $a0            , $a1

    # preserve/restore the LP64 callee-saved registers:
    # $s0-$s8   ($r23-$r31)
    # $fp       ($r22)
    # $ra       ($r1)
    # $fs0-$fs7 ($f24-$f31), only the low 64 bits are callee-saved
    # $a0       self argument (initial call)
    #
    # LLVM inline asm uses `$` for operands, so register names are written as
    # `$$reg`.
    #
    # Eventually reset $ra to zero to avoid the unwinder to mistake the
    # context switch as a regular call.
    {% begin %}
      asm("
      addi.d  $$sp, $$sp, -176
      fst.d   $$fs0, $$sp, 0
      fst.d   $$fs1, $$sp, 8
      fst.d   $$fs2, $$sp, 16
      fst.d   $$fs3, $$sp, 24
      fst.d   $$fs4, $$sp, 32
      fst.d   $$fs5, $$sp, 40
      fst.d   $$fs6, $$sp, 48
      fst.d   $$fs7, $$sp, 56
      st.d    $$ra, $$sp, 64
      st.d    $$fp, $$sp, 72
      st.d    $$s0, $$sp, 80
      st.d    $$s1, $$sp, 88
      st.d    $$s2, $$sp, 96
      st.d    $$s3, $$sp, 104
      st.d    $$s4, $$sp, 112
      st.d    $$s5, $$sp, 120
      st.d    $$s6, $$sp, 128
      st.d    $$s7, $$sp, 136
      st.d    $$s8, $$sp, 144
      st.d    $$a0, $$sp, 160       // push 1st argument (+ alignment)
      st.d    $$a1, $$sp, 168

      st.d    $$sp, $$a0, 0         // current_context.stack_top = sp
      {% unless flag?(:without_mt) %}
      dbar    0                     // barrier: ensure registers are stored
      {% end %}
      addi.d  $$t0, $$zero, 1       // current_context.resumable = 1
      st.d    $$t0, $$a0, 8

      st.d    $$zero, $$a1, 8       // new_context.resumable = 0
      ld.d    $$sp, $$a1, 0         // sp = new_context.stack_top

      ld.d    $$a0, $$sp, 160       // pop 1st argument (+ alignment)
      ld.d    $$a1, $$sp, 168
      ld.d    $$s8, $$sp, 144
      ld.d    $$s7, $$sp, 136
      ld.d    $$s6, $$sp, 128
      ld.d    $$s5, $$sp, 120
      ld.d    $$s4, $$sp, 112
      ld.d    $$s3, $$sp, 104
      ld.d    $$s2, $$sp, 96
      ld.d    $$s1, $$sp, 88
      ld.d    $$s0, $$sp, 80
      ld.d    $$fp, $$sp, 72
      ld.d    $$ra, $$sp, 64
      fld.d   $$fs7, $$sp, 56
      fld.d   $$fs6, $$sp, 48
      fld.d   $$fs5, $$sp, 40
      fld.d   $$fs4, $$sp, 32
      fld.d   $$fs3, $$sp, 24
      fld.d   $$fs2, $$sp, 16
      fld.d   $$fs1, $$sp, 8
      fld.d   $$fs0, $$sp, 0
      addi.d  $$sp, $$sp, 176

      // avoid a stack corruption that will confuse the unwinder
      move    $$t0, $$ra            // save ra
      move    $$ra, $$zero          // reset ra
      jr      $$t0                  // jump to new pc value
      ")
    {% end %}
  end
end

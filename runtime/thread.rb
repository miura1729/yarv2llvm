#
# Runtime Library
#   Thread class --- for create native-thread
#
#   This file uses Unsafe objects
#
module LLVM::Runtime
  YARV2LLVM::define_macro :define_thread_structs do |system|
    
    if system[0][0].type.constant == :WIN32 then
      native_thread_t = "VALUE"
      rb_thread_lock_t = "VALUE"
      jmp_buf = "VALUE, " * 52
    else
      native_thread_t = "P_VALUE, VALUE"
      rb_thread_lock_t = "VALUE"
      jmp_buf = "VALUE, " * 52
    end

<<`EOS`
  VALUE = RubyHelpers::VALUE
  LONG  = LLVM::Type::Int32Ty
  VOID  = LLVM::Type::VoidTy
  P_VALUE = LLVM::pointer(VALUE)

  ROBJECT = LLVM::struct [VALUE, VALUE, LONG, LONG, P_VALUE]
  RDATA = LLVM::struct [VALUE, VALUE, VALUE, VALUE, VALUE]

  RB_ISEQ_T = LLVM::struct [
    VALUE,                      # TYPE instruction sequence type
    VALUE,                      # name Iseq Name
    P_VALUE,                    # iseq (insn number and operands)
  ]

  RB_CONTROL_FRAME_T = LLVM::struct [
    VALUE,                      # PC cfp[0]
    VALUE,                      # SP cfp[0]
    VALUE,                      # BP cfp[0]
    RB_ISEQ_T,                  # BP cfp[0]
  ]

  RB_BLOCK_T = LLVM::struct [
    VALUE,
  ]

  RB_VM_T = LLVM::struct [
   VALUE,                     # self
  ]

  RB_THREAD_ID_T = VALUE

  RB_THREAD_T = LLVM::struct [
   VALUE,               # self
   RB_VM_T,                     # VM

   P_VALUE,                     # stack
   LONG,                        # stack_size
   RB_CONTROL_FRAME_T,          # cfp
   LONG,                        # safe_level
   LONG,                        # raised_flag
   VALUE,                       # last_status

   [LONG, :state],                        # state

   RB_BLOCK_T,                  # passed_block
   
   VALUE,                       # top_self
   VALUE,                       # top_wrapper

   P_VALUE,                     # *local_lfp
   VALUE,                       # local_svar
   
   RB_THREAD_ID_T,              # thred_id
   LONG,                        # status
   [LONG, :priority],           # priority
   LONG,                        # slice

   #{native_thread_t},          # native_thread_data
   P_VALUE,                     # blocking_region_buffer

   [VALUE, :thgroup],           # thgroup
   VALUE,                       # value

   VALUE,                       # errinfo
   VALUE,                       # thrown_errinfo
   LONG,                        # exec_signal

   LONG,                        # interrupt_flag
   #{rb_thread_lock_t},         # interrupt_lock
   VALUE,                       # unblock_func
   VALUE,                       # unblock_arg
   VALUE,                       # locking_mutex
   VALUE,                       # keeping_mutexes
   LONG,                        # transaction_for_lock

   VALUE,                       # tag
   VALUE,                       # trap_tag

   LONG,                        # parse_in_eval
   LONG,                        # mild_compile_error

   VALUE,                       # local_strage
#   VALUE,                      # value_cahce
#   P_VALUE,                      # value_cahce_ptr

  VALUE,                        # join_list_next
  VALUE,                        # join_list_head

  [VALUE, :first_proc],           # first_proc
  [VALUE, :first_args],           # first_args
  [VALUE, :first_func],           # first_func

  P_VALUE,                      # machine_stack_start
  P_VALUE,                      # machine_stack_end
  LONG,                         # machine_stack_maxsize

  #{jmp_buf}                    # machine_regs
  LONG,                         # mark_stack_len

  VALUE,                        # start_insn_usage

  VALUE,                        # event_hooks
  LONG,                         # event_flags]
  
  VALUE,                        # fiber
  VALUE,                        # root_fiber
  #{jmp_buf}                    # root_jmpbuf

  LONG,                         # method_missing_reason
  LONG,                         # abort_on_exception
  ]
EOS
  end

  define_thread_structs(:LINUX)

  def get_thread(thobj)
    thval2 = YARV2LLVM::LLVMLIB::unsafe(thobj, RDATA)
    YARV2LLVM::LLVMLIB::unsafe(thval2[4], RB_THREAD_T)
  end

  def y2l_create_thread(fn, args)
    type = LLVM::function(VALUE, [VALUE])
    YARV2LLVM::LLVMLIB::define_external_function(:rb_thread_alloc, 
                                                 'rb_thread_alloc', 
                                                 type)
    thval = rb_thread_alloc(Thread)
    th = get_thread(thval)
    th[:first_func] = fn
    th[:first_proc] = YARV2LLVM::LLVMLIB::unsafe(0, VALUE) # false
    th[:first_args] = args

    type = LLVM::function(VALUE, [])
    YARV2LLVM::LLVMLIB::define_external_function(:rb_thread_current, 
                                                 'rb_thread_current', 
                                                 type)
    curth = get_thread(rb_thread_current)
    th[:priority] = curth[:priority]
    th[:thgroup] = curth[:thgroup]

    thval
  end
end

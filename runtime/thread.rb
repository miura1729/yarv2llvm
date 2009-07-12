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
      def_rb_thread_lock_t = "RB_THREAD_LOCK_T = VALUE"
      def_jmp_buf = "JMP_BUF = LLVM::array(VALUE, 52)"
    else
      native_thread_t = "P_VALUE, VALUE"
      def_rb_thread_lock_t = "RB_THREAD_LOCK_T = LLVM::array(VALUE, 6)"
      def_jmp_buf = "JMP_BUF = LLVM::array(VALUE, 52)"
    end

<<`EOS`
  VALUE = LLVM::MACHINE_WORD
  LONG  = LLVM::MACHINE_WORD
  VOID  = LLVM::Type::VoidTy
  P_VALUE = LLVM::pointer(VALUE)
  #{def_jmp_buf}
  #{def_rb_thread_lock_t}

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
   VALUE,                       # self
   RB_THREAD_LOCK_T,            # global_vm_lock

   VALUE,                       # main_thread
   VALUE,                       # running_thread
   
   [VALUE, :living_threads],     # living_threads
   VALUE,                        # thgroup_default

   LONG,                        # running
   LONG,                        # thread_abort_on_exception
   LONG,                        # trace_flag
   LONG,                        # sleeper

  ]

  RB_THREAD_ID_T = VALUE

  RB_THREAD_T = LLVM::struct [
   VALUE,               # self
   [RB_VM_T, :vm],                     # VM

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
   
   [RB_THREAD_ID_T, :thread_id], # thred_id
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
   RB_THREAD_LOCK_T,            # interrupt_lock
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
  [LONG, :machine_stack_maxsize], # machine_stack_maxsize

  JMP_BUF,                      # machine_regs
  LONG,                         # mark_stack_len

  VALUE,                        # start_insn_usage

  VALUE,                        # event_hooks
  LONG,                         # event_flags]
  
  VALUE,                        # fiber
  VALUE,                        # root_fiber
  JMP_BUF,                    # root_jmpbuf

  LONG,                         # method_missing_reason
  LONG,                         # abort_on_exception
  ]

  # pthread structure
  PTHREAD_ATTR_T = LLVM::array(VALUE, 9) # 32bit 64bit is 7
  PTHREAD_ATTR_PTR = LLVM::pointer(PTHREAD_ATTR_T)
EOS
  end

  define_thread_structs(:LINUX)

  type = LLVM::function(VALUE, [VALUE])
  YARV2LLVM::LLVMLIB::define_external_function(:rb_thread_alloc, 
                                               'rb_thread_alloc', 
                                               type)


  type = LLVM::function(VALUE, [])
  YARV2LLVM::LLVMLIB::define_external_function(:rb_thread_current, 
                                               'rb_thread_current', 
                                               type)


  type = LLVM::function(VOID, [VALUE, VALUE, VALUE])
  YARV2LLVM::LLVMLIB::define_external_function(:st_insert, 
                                               'st_insert',
                                               type)


  # Pthread API
  type = LLVM::function(LONG, [VALUE])
  YARV2LLVM::LLVMLIB::define_external_function(:pthread_attr_init,
                                               'pthread_attr_init',
                                               type)

  type = LLVM::function(LONG, [VALUE, LONG])
  YARV2LLVM::LLVMLIB::define_external_function(:pthread_attr_setstacksize,
                                               'pthread_attr_setstacksize',
                                               type)


  type = LLVM::function(LONG, [VALUE, LONG])
  YARV2LLVM::LLVMLIB::define_external_function(:pthread_attr_setdetachstate,
                                               'pthread_attr_setdetachstate',
                                               type)

  type = LLVM::function(LONG, [RB_THREAD_ID_T, VALUE, VALUE, RB_THREAD_T])
  YARV2LLVM::LLVMLIB::define_external_function(:pthread_create,
                                               'pthread_create',
                                               type)

  PTHREAD_CREATE_JOINABLE = 0
  PTHREAD_CREATE_DETACHED = 1


  def thread_start_func_2(th, stack_start, register_stack_start)
    
  end

  def get_thread(thobj)
    thval2 = YARV2LLVM::LLVMLIB::unsafe(thobj, RDATA)
    YARV2LLVM::LLVMLIB::unsafe(thval2[4], RB_THREAD_T)
  end

  def y2l_create_thread(fn, args)
    thval0 = rb_thread_alloc(Thread)
    thval = YARV2LLVM::LLVMLIB::safe(thval0)

    th = get_thread(thval)
    th[:first_func] = fn
    th[:first_proc] = YARV2LLVM::LLVMLIB::unsafe(0, VALUE) # false
    th[:first_args] = args

    curth = get_thread(rb_thread_current)
    th[:priority] = curth[:priority]
    th[:thgroup] = curth[:thgroup]

    st_insert(th[:vm][:living_threads], thval, th[:thread_id])
    native_thread_create(th)
    thval
  end

  def thread_start_func_1(th_ptr)
    stack_start = YARV2LLVM::LLVMLIB::alloca(LONG)
    thread_start_func_2(th_ptr, stack_start, nil)
  end

  def native_thread_create(th)
    stack_size = 64 * 1024
    space = stack_size / 5
    th[:machine_stack_maxsize] = stack_size - space
    attr = YARV2LLVM::LLVMLIB::alloca(PTHREAD_ATTR_T)

    attrus = YARV2LLVM::LLVMLIB::unsafe(attr, VALUE)
    stack_sizeus = YARV2LLVM::LLVMLIB::unsafe(stack_size, LONG)
    pthread_attr_init(attrus)

    # PTHREAD_CREATE_DETACHED = 1
    pthread_attr_setdetachstate(attrus, 
                                YARV2LLVM::LLVMLIB::unsafe(1, LONG))

    pthread_create(th[:thread_id], 
                   attrus, 
                   YARV2LLVM::LLVMLIB::get_address_of_method(:Runtime, 
                                                             :thread_start_func_1), 
                   th)

    th
  end
end

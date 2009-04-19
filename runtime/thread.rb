#
# Runtime Library
#   Thread class --- for create native-thread
#
#   This file uses Unsafe objects
#
module LLVM::Runtime
  VALUE = RubyHelpers::VALUE
  LONG  = LLVM::Type::Int32Ty

  P_VALUE = LLVM::pointer(VALUE)

  RB_CONTROL_FRAME_T = LLVM::struct [
    VALUE,
  ]

  RB_BLOCK_T = LLVM::struct [
    VALUE,
  ]

  RB_VM_T = LLVM::struct [
   VALUE,                     # self
  ]

  RB_THREAD_T = LLVM::struct [
   VALUE,                       # self
   RB_VM_T,                     # VM

   P_VALUE,                     # stack
   LONG,                        # stack_size
   RB_CONTROL_FRAME_T,          # cfp
   LONG,                        # safe_level
   LONG,                        # raised_flag
   VALUE,                       # last_status

   LONG,                        # state

   RB_BLOCK_T,                  # passed_block
   
   VALUE,                       # top_self
   VALUE,                       # top_wrapper

   P_VALUE,                     # *local_lfp
   VALUE,                       # local_svar
  ]

  def y2l_create_thread
    type = LLVM::function(RB_THREAD_T, [VALUE])
    YARV2LLVM::LLVMLIB::define_external_function(:rb_thread_alloc, 
                                                 'rb_thread_alloc', 
                                                 type)
    tklass = YARV2LLVM::LLVMLIB::unsafe(Thread, VALUE)
    rb_thread_alloc(tklass)
    nil
  end
end

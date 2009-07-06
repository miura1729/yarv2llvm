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
    else
      native_thread_t = "P_VALUE, VALUE"
    end
    
    code = "VALUE = RubyHelpers::VALUE
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
   [VALUE, :self],               # self
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
   LONG,                        # priority
   LONG,                        # slice

   #{native_thread_t},           # native_thread_data
   P_VALUE,                     # blocking_region_buffer

   [VALUE, :thgroup],           # thgroup
  ]"
    `#{code}`
  end

  define_thread_structs(:LINUX)

  def y2l_create_thread
    type = LLVM::function(VALUE, [VALUE])
    YARV2LLVM::LLVMLIB::define_external_function(:rb_thread_alloc, 
                                                 'rb_thread_alloc', 
                                                 type)
    thval = rb_thread_alloc(Thread)
    thval2 = YARV2LLVM::LLVMLIB::unsafe(thval, RDATA)
    th = YARV2LLVM::LLVMLIB::unsafe(thval2[4], RB_THREAD_T)
    th[:state]
    thval
  end
end

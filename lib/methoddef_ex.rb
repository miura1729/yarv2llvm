require 'llvm'
# Define method type and name information not compatible with CRuby
include LLVM

module Transaction
end

module YARV2LLVM

class LLVM_Struct
  def initialize(type, member)
    @type = type
    @member = member
  end
  
  attr_accessor :type
  attr_accessor :member
end
  
class LLVM_Pointer
  def initialize(type, member)
    @type = type
    @member = member
  end
  
  attr_accessor :type
  attr_accessor :member
end

class LLVM_Function
  include LLVMUtil

  def initialize(type, ret, arga)
    @type = type
    @ret_type = ret
    @arg_type = arga
  end
  
  attr_accessor :type
  attr_accessor :ret_type
  attr_accessor :arg_type

  def arg_type_raw
    @arg_type.map {|e| get_raw_llvm_type(e) }
  end
end

module MethodDefinition
  include LLVMUtil

  InlineMethod_YARV2LLVM = {
    :get_interval_cycle => {
      :inline_proc =>
        lambda {|para|
          info = para[:info]
          rettype = RubyType.fixnum(info[3], "Return type of gen_interval_cycle")
          prevvalp = add_global_variable("interval_cycle", 
                                     Type::Int64Ty, 
                                     0.llvm(Type::Int64Ty))
          @expstack.push [rettype,
            lambda {|b, context|
              prevval = b.load(prevvalp)
              ftype = Type.function(Type::Int64Ty, [])
              fname = 'llvm.readcyclecounter'
              func = context.builder.external_function(fname, ftype)
              curval = b.call(func)
              diffval = b.sub(curval, prevval)
              rc = b.trunc(diffval, Type::Int32Ty)
              b.store(curval, prevvalp)
              context.rc = rc
              context
          }]
      }
    },

  },

  InlineMethod_LLVM = {
    :struct => {
      :inline_proc => lambda {|para|
        info = para[:info]
        tarr = para[:args][0]
        rtarr = tarr[0].content
        rtarr2 = rtarr.map {|e| get_raw_llvm_type(e)}

        struct = Type.pointer(Type.struct(rtarr2))
        struct0 = LLVM_Struct.new(struct, rtarr)
        mess = "return type of LLVM::struct"
        type = RubyType.value(info[3], mess, LLVM_Struct)
        type.type.content = struct0
        @expstack.push [type,
          lambda {|b, context|
            context.rc = struct0.llvm
            context
          }
        ]
      }
    },

    :pointer => {
      :inline_proc => lambda {|para|
        info = para[:info]
        tarr = para[:args][0]
        dstt = tarr[0].content
        ptr = Type.pointer(dstt.type)
        ptr0 = LLVM_Pointer.new(ptr, dstt)
        type.type.content =ptr0
        mess = "return type of LLVM_Pointer"
        type = RubyType.value(info[3], mess, LLVM_Pointer)
        @expstack.push [type,
          lambda {|b, context|
            context.rc = ptr0.llvm
            context
          }
        ]
      }
    },

    :function => {
      :inline_proc => lambda {|para|
        info = para[:info]
        ret = para[:args][1]
        arga = para[:args][0]
        rett = ret[0].content
        argta = arga[0].content

        argta2 = argta.map {|e| get_raw_llvm_type(e)}

        func = Type.function(rett, argta2)
        funcobj = LLVM_Function.new(func, rett, argta)
        mess = "return type of LLVM_Function"
        type = RubyType.value(info[3], mess, LLVM_Function)
        type.type.content = funcobj
        @expstack.push [type,
          lambda {|b, context|
            context.rc = funcobj.llvm
            context
          }
        ]
      }
    },
  },

  InlineMethod_LLVMLIB = {
    :unsafe => {
      :inline_proc => lambda {|para|
        info = para[:info]
        ptr = para[:args][1]
        mess = "return type of LLVMLIB::unsafe"
        objtype = para[:args][0][0].content
        unsafetype = RubyType.unsafe(info[3], mess, objtype)
        @expstack.push [unsafetype,
          lambda {|b, context|
            ptr0 = ptr[1].call(b, context).rc
            newptr = unsafetype.type.from_value(ptr0, b, context)
            context.rc = newptr
            context
          }
        ]
      }
    },

    :safe => {
      :inline_proc => lambda {|para|
        info = para[:info]
        ptr = para[:args][0]
        ptrllvm = ptr[0].type.type
        mess = "return type of LLVMLIB::safe"
        safetype = RubyType.new(VALUE, info[3], mess)
        @expstack.push [safetype,
          lambda {|b, context|
            ptr0 = ptr[1].call(b, context).rc
            safetype.type = PrimitiveType.new(ptr[0].type.type, nil)
            newptr = safetype.type.to_value(ptr0, b, context)
            context.rc = newptr
            context
          }
        ]
      }
    },

    :define_external_function => {
      :inline_proc => lambda {|para|
        info = para[:info]
        sigobj = para[:args][0]
        cfnobj = para[:args][1]
        rfnobj = para[:args][2]
        
        sig = sigobj[0].content
        cfuncname = cfnobj[0].content
        rfuncname = rfnobj[0].content
        mess = "External function: #{cfuncname}"
        functype = RubyType.unsafe(info[3], mess, sig)
        argtype = sig.arg_type_raw.map do |e|
          RubyType.unsafe(info[3], nil, e)
        end
        mess = "ret type of #{rfuncname}"
        rettype = RubyType.unsafe(info[3], mess, sig.ret_type)
        MethodDefinition::CMethod[nil][rfuncname] = {
          :cname => cfuncname,
          :argtype => argtype,
          :rettype => rettype,
          :send_self => false
        }
        @expstack.push [functype,
          lambda {|b, context|
            context.rc = 4.llvm
            context
          }
        ]
      }
    },
  },

  InlineMethod_Transaction = {
    :begin_transaction => {
      :inline_proc => lambda {|para|
        info = para[:info]
        if OPTION[:cache_instance_variable] == false then
          mess = "Please option \':cache_instance_variable\' to true"
          mess += "if you use Transaction mixin"
          raise mess
        end

        oldrescode = @rescode
        @rescode = lambda {|b, context|
          context = oldrescode.call(b, context)
          
          context.user_defined[:transaction] ||= {}
          trcontext = context.user_defined[:transaction]

          orgvtab = {}
          orgvtabinit = {}
          trcontext[:original_instance_vars_local] = orgvtab
          trcontext[:original_instance_vars_init] = orgvtabinit

          vtab = context.instance_vars_local_area
          vtab2 = vtab.clone
          vtab.each do |name, area|
            vtab[name] = b.alloca(VALUE, 1)
            orgvtabinit[name] = b.alloca(VALUE, 1)
          end

          lbody = context.builder.create_block
          trcontext[:body] = lbody
          b.br(lbody)
          
          fmlab = context.curln
          context.blocks[fmlab] = lbody
          
          b.set_insert_point(lbody)
          
          vtab2.each do |name, area|
            orgvtab[name] = area
            oval = b.load(area)
            b.store(oval, vtab[name])
            b.store(oval, orgvtabinit[name])
          end
          trcontext[:original_instance_vars_area] = vtab
          
          context
        }
      }
    },

    :commit => {
      :inline_proc => lambda {|para|
        info = para[:info]

        oldrescode = @rescode
        @rescode = lambda {|b, context|
          context = oldrescode.call(b, context)

          trcontext = context.user_defined[:transaction]
          if trcontext == nil then
            raise "commit must use with begin_transaction"
          end

          vtab = context.instance_vars_local_area
          orgvtab = trcontext[:original_instance_vars_local]
          vtabinit = trcontext[:original_instance_vars_init]
          vtabarea = trcontext[:original_instance_vars_area]

          if vtab.size == 1 then
            # Can commit lock-free
            orgarea = orgvtab.to_a[0][1]
            orgvalue = b.load(vtabinit.to_a[0][1])
            newvalue = b.load(vtabarea.to_a[0][1])

            ftype = Type.function(VALUE, [P_VALUE, VALUE, VALUE])
            fname = "llvm.atomic.cmp.swap.i32.p0i32"
            func = context.builder.external_function(fname, ftype)
            actval = b.call(func, orgarea, orgvalue, newvalue)

            lexit = context.builder.create_block
            lretry = trcontext[:body]
            fmlab = context.curln
            context.blocks[fmlab] = lexit

            cmp = b.icmp_eq(orgvalue, actval)
            b.cond_br(cmp, lexit, lretry)

            b.set_insert_point(lexit)
          else
            # Lock base commit
            raise "Not implement yet in #{info[3]}"
          end
          
          vtab.each do |name, area|
            vtab[name] = orgvtab[name]
          end

          context
        }
      }
   },

    :abort => {
      :inline_proc => lambda {|para|
        oldrescode = @rescode
        @rescode = lambda {|b, context|
          context = oldrescode.call(b, context)

          trcontext = context.user_defined[:transaction]
          if trcontext == nil then
            raise "abort must use with begin_transaction"
          end
          vtab = context.instance_vars_local_area
          orgvtab = trcontext[:original_instance_vars_local]
        
          vtab.each do |name, area|
            vtab[name] = orgvtab[name]
          end

          context
        }
      }
    },

    :do_retry => {
      :inline_proc => lambda {|para|
        oldrescode = @rescode
        @rescode = lambda {|b, context|
          context = oldrescode.call(b, context)

          trcontext = context.user_defined[:transaction]
          if trcontext == nil then
            raise "abort must use with begin_transaction"
          end

          lexit = context.builder.create_block
          lretry = trcontext[:body]
          fmlab = context.curln
          context.blocks[fmlab] = lexit

          b.br(lretry)

          b.set_insert_point(lexit)
          context
        }
      }
    }
  }

  InlineMethod[:YARV2LLVM] = InlineMethod_YARV2LLVM
  InlineMethod[:"YARV2LLVM::LLVMLIB"] = InlineMethod_LLVMLIB
  InlineMethod[:"LLVM"] = InlineMethod_LLVM
  InlineMethod[:Transaction] = InlineMethod_Transaction
end
end

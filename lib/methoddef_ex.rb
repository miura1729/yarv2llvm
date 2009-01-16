require 'llvm'
# Define method type and name information not compatible with CRuby
include LLVM

module Transaction
end

module YARV2LLVM
module MethodDefinition
  include LLVMUtil

  InlineMethod_YARV2LLVM = {
    :get_interval_cycle => {
      :inline_proc =>
        lambda {|para|
          info = para[:info]
          rettype = RubyType.fixnum(info[3], "Return type of gen_interval_cycle")
          glno = add_global_variable("interval_cycle", 
                                     Type::Int64Ty, 
                                     0.llvm(Type::Int64Ty))
          @expstack.push [rettype,
            lambda {|b, context|
              prevvalp = context.builder.global_variable
              prevvalp = b.struct_gep(prevvalp, glno)
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

  }

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

          vtab = context.instance_vars_local
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

          vtab = context.instance_vars_local
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
          vtab = context.instance_vars_local
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
          vtab = context.instance_vars_local
          orgvtab = trcontext[:original_instance_vars_local]
        
          vtab.each do |name, area|
            vtab[name] = orgvtab[name]
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
  InlineMethod[:Transaction] = InlineMethod_Transaction
end
end

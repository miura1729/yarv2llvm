require 'llvm'
# Define method type and name information
include LLVM
module YARV2LLVM
module MethodDefinition

  # Use ruby internal and ignor in yarv2llvm.
  SystemMethod = {
    :"core#define_method" => 
      {:args => 1}
  }
  
  # method inline or need special process
  InlineMethod =  {
    :[]= => {
      :inline_proc => 
        lambda {
          val = @expstack.pop
          idx = @expstack.pop
          arr = @expstack.pop
          RubyType.resolve
          if arr[0].type then
            val[0].add_same_type(arr[0].type.element_type)
            arr[0].type.element_type.add_same_type(val[0])
          end

          oldrescode = @rescode
          v = nil
          @rescode = lambda {|b, context|
            context = oldrescode.call(b, context)

            val[0].add_same_type(arr[0].type.element_type)
            arr[0].type.element_type.add_same_type(val[0])
            RubyType.resolve

            case arr[0].type
            when ArrayType
              ftype = Type.function(Type::VoidTy, 
                                    [VALUE, Type::Int32Ty, VALUE])
              func = context.builder.external_function('rb_ary_store', ftype)
              context = val[1].call(b, context)
              v = context.rc
              context = idx[1].call(b, context)
              i = context.rc
              context = arr[1].call(b, context)
              a = context.rc
              vval = val[0].type.to_value(v, b, context)
              b.call(func, a, i, vval)
              arr[0].type.element_content[i] = v
              context
            else
              # Todo: []= handler of other type
              raise "Unkonw type #{arr[0].type.inspect2}"
            end
          }
          @expstack.push [val[0],
            lambda {|b, context|
              context.rc = v
              context}]
      },
    },

    :to_f => {
      :inline_proc => 
        lambda {
          recv = @expstack.pop

          @expstack.push [RubyType.float(@info[3], 'Return type of to_f'),
            lambda {|b, context|
              context = recv.call(b, context)
              val = context.rc
              case val[0].type.llvm
              when Type::DoubleTy
                context.rc = val
              when Type::Int32Ty
                context.rc = b.si_to_fp(val)
              end
              context}]
        },
      },

    :p => {
      :inline_proc =>
        lambda {
          pterm = @expstack.pop
          @expstack.push [pterm[0], 
            lambda {|b, context|
              context = pterm[1].call(b, context)
              pobj = context.rc
              ftype = Type.function(Type::VoidTy, [VALUE])
              func = @builder.external_function('rb_p', ftype)
              b.call(func, pterm[0].type.to_value(pobj, b, context))
              context}]
        }
     }
  }
  
  # can be maped to C function
  CMethod = {
    :sqrt => 
      {:rettype => Type::DoubleTy,
      :argtype => [Type::DoubleTy],
      :cname => "sqrt"}
  }

  # definition by yarv2llvm and arg/return type is C type (int, float, ...)
  RubyMethod = {}

  # stub for RubyCMethod. arg/return type is always VALUE
  RubyMethodStub = {}
end
end
  

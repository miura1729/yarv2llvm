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
      :argtype => [ArrayType.new(nil), Type::Int32Ty, nil],
      :inline_proc => 
        lambda {
          val = @expstack.pop
          idx = @expstack.pop
          arr = @expstack.pop
          RubyType.resolve
          val[0].add_same_type(arr[0].type.element_type)
          arr[0].type.element_type.add_same_type(val[0])
            
          oldrescode = @rescode
          v = nil
          @rescode = lambda {|b, context|
            context = oldrescode.call(b, context)
            ftype = Type.function(Type::VoidTy, [VALUE, Type::Int32Ty, VALUE])
            func = context.builder.external_function('rb_ary_store', ftype)
            context = val[1].call(b, context)
            v = context.rc
            context = idx[1].call(b, context)
            i = context.rc
            context = arr[1].call(b, context)
            a = context.rc
            b.call(func, a, i, val[0].type.to_value(v, b, context))
            context
          }
          @expstack.push [val[0],
            lambda {|b, context|
              context.rc = v
              context}]
      },
    },
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
  

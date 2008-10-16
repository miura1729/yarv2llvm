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
      :inline_proc_traverse => 
          lambda {
            val = @expstack.pop
            idx = @expstack.pop
            arr = @expstack.pop
            @expstack.push [arr[0].type.elemeht_type, 0.llvm]
          },
      :inline_proc_codegen =>
        lambda {|b, context|
      },
    }
  }
  
  # can be maped to C function
  CMethod = {
    :sqrt => 
      {:rettype => Type::FloatTy,
      :argtype => [Type::FloatTy],
      :cname => "sqrtf"}
  }

  # definition by yarv2llvm and arg/return type is C type (int, float, ...)
  RubyMethod = {}

  # stub for RubyCMethod. arg/return type is always VALUE
  RubyMethodStub = {}
end
end
  

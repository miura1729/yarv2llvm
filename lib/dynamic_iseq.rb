#
# dynamic_iseq.rb - Get iseq of method dynamically with LLVM
#
require 'llvm'

module VMLib
  class DynamicInstSeq
    include LLVM
    include RubyInternals

    NODE = Type.struct([Type::Int32Ty, P_CHAR, VALUE, VALUE, VALUE])
    P_NODE = Type.pointer(NODE)
    
    def initialize
      @module = LLVM::Module.new('dynamic_iseq')
      ExecutionEngine.get(@module)

      # Using Ruby API
      ftype = Type.function(P_NODE, [VALUE])
      mbody = @module.external_function('rb_method_body', ftype)

      # entry point
      ftype = Type.function(VALUE, [VALUE])
      @iseq_of = @module.get_or_insert_function('iseq_of', ftype)
      
      # method body
      b = @iseq_of.create_block.builder
      mt = @iseq_of.arguments[0]
      node = b.call(mbody, mt)
      body0 = b.struct_gep(node, 3)
      body1 = b.bit_cast(body0, Type.pointer(P_NODE))
      body = b.load(body1)
      b.return(body)
    end

    def iseq_of(met)
      ExecutionEngine.run_function(@iseq_of, met)
    end
  end
end


if __FILE__ == $0 then
  def fact(x)
    if x == 1 then
      1
    else
      fact(x - 1) * x
    end
  end
  
  a = VMLib::DynamicInstSeq.new
  p a.iseq_of(method(:fact)).to_a
end

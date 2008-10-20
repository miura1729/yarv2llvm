require 'rubygems'
require 'tempfile'
require 'llvm'

require 'lib/instruction.rb'
require 'lib/type.rb'
require 'lib/llvmbuilder.rb'
require 'lib/methoddef.rb'
require 'lib/vmtraverse.rb'

def pppp(n)
#  p n
end

class Float
  def llvm
    LLVM::Value.get_double_constant(self)
  end
end

class Symbol
  def llvm
    immediate
  end
end

module LLVM::RubyInternals
  RFLOAT = Type.struct([RBASIC, Type::DoubleTy])
  P_RFLOAT = Type.pointer(RFLOAT)
end

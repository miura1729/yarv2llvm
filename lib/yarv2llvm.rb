require 'rubygems'
require 'tempfile'
require 'llvm'

require 'lib/llvmutil.rb'
require 'lib/instruction.rb'
require 'lib/type.rb'
require 'lib/llvmbuilder.rb'
require 'lib/methoddef.rb'
require 'lib/vmtraverse.rb'

def pppp(n)
#  p n
end

module YARV2LLVM
OPTION = {
  :disasm => false,
  :optimize => true,
  :dump_yarv => false,
  :write_bc => false,
  :func_signature => false,
}
end

class Float
  def llvm
    LLVM::Value.get_double_constant(self)
  end
end

class String
  def llvm(b)
    b.create_global_string_ptr(self)
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

=begin
class LLVM::Builder
  alias :org_load :load
  def load(rptr, volatilep = nil)
    begin
      org_load(rptr, volatilep)
    rescue ArgumentError
      org_load(rptr)
    end
  end

  alias :org_store :store
  def store(val, rptr, volatilep = nil)
    begin
      org_store(val, rptr, volatilep)
    rescue ArgumentError
      org_store(val, rptr)
    end
  end
end
=end

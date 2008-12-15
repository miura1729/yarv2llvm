require 'rubygems'
require 'tempfile'
require 'llvm'

require 'lib/llvmutil.rb'
require 'lib/instruction.rb'
require 'lib/type.rb'
require 'lib/llvmbuilder.rb'
require 'lib/methoddef.rb'
require 'lib/intruby.rb'
require 'lib/vmtraverse.rb'

def pppp(n)
#  p n
end

module YARV2LLVM
DEF_OPTION = {
  :disasm => false,
  :optimize => true,
  :dump_yarv => false,
  :write_bc => false,
  :func_signature => false,

  :array_range_check => true,

  :cache_instance_variable => false,
}
OPTION = {}

# From gc.c in ruby1.9
#     *  sizeof(RVALUE) is
#     *  20 if 32-bit, double is 4-byte aligned
#     *  24 if 32-bit, double is 8-byte aligned
#     *  40 if 64-bit
RVALUE_SIZE = 20
RUBY_SYMBOL_FLAG = 0xe

PROFILE_RAW_DATA = []
end

class Object
  def llvm
    immediate
  end
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

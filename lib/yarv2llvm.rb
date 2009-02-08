require 'rubygems'
require 'tempfile'
require 'llvm'

require 'lib/llvmutil.rb'
require 'lib/instruction.rb'
require 'lib/type.rb'
require 'lib/llvmbuilder.rb'
require 'lib/methoddef.rb'
require 'lib/methoddef_ex.rb'
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

  :cache_instance_variable => true,
  :strict_type_inference => false,

  :inline_block => false,

  :type_message => true,
}
OPTION = {}

# Protect from GC
EXPORTED_OBJECT = {}

# From gc.c in ruby1.9
#     *  sizeof(RVALUE) is
#     *  20 if 32-bit, double is 4-byte aligned
#     *  24 if 32-bit, double is 8-byte aligned
#     *  40 if 64-bit
RVALUE_SIZE = 20
RUBY_SYMBOL_FLAG = 0xe

TRACE_INFO = []
end

class Object
  def llvm
    YARV2LLVM::EXPORTED_OBJECT[self] = true
    immediate
  end

  # from ActiveSupport
  def subclasses_of(*superclasses)
    subclasses = []
    ObjectSpace.each_object(Class) do |k|
      next if # Exclude this class if
        (k.ancestors & superclasses).empty? || # It's not a subclass of our supers
        superclasses.include?(k) || # It *is* one of the supers
        /^[A-Z]/ !~ k.to_s ||
        eval("! defined?(::#{k})") || # It's not defined.
        eval("::#{k}").object_id != k.object_id
      subclasses << k
    end
    subclasses
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
    YARV2LLLVM::EXPORTED_OBJECT[self] = true
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

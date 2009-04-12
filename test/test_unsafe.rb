#
# Test for unsafe extention
#
require 'test/unit'
require 'yarv2llvm'
class UnsafeTests < Test::Unit::TestCase

  def test_unsafe
    YARV2LLVM::compile(<<-EOS, {:disasm => true, :dump_yarv => true, :optimize=> false})
def unsafe
#  rbasic = LLVM::struct([RubyHelpers::VALUE, LLVM::Type::Int32Ty])
  type = LLVM::struct([RubyHelpers::VALUE, LLVM::Type::Int32Ty, RubyHelpers::VALUE, RubyHelpers::VALUE])
  a = [:a, :b]
  foo = YARV2LLVM::LLVMLIB::unsafe(a, type)
  YARV2LLVM::LLVMLIB::safe(foo[1])
end
EOS
p unsafe.to_s(16)
  end
end

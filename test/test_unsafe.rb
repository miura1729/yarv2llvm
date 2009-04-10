#
# Test for unsafe extention
#
require 'test/unit'
require 'yarv2llvm'
class UnsafeTests < Test::Unit::TestCase

  def test_unsafe
    YARV2LLVM::compile(<<-EOS, {:disasm => true, :dump_yarv => true, :optimize=> false})
def unsafe
  type = LLVM::Type.struct([RubyHelpers::VALUE, RubyHelpers::VALUE])
  foo = YARV2LLVM::LLVMLIB::unsafe([:a], type)
  foo[0]
  1
end
EOS
   assert_equal(int1, 1)
  end
end

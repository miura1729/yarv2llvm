#
# Test for unsafe extention
#
require 'test/unit'
require 'yarv2llvm'
class UnsafeTests < Test::Unit::TestCase

  def test_unsafe
    YARV2LLVM::compile(<<-EOS, {:disasm => true, :dump_yarv => true, :optimize=> false})
def unsafe
  type = LLVM::struct([RubyHelpers::VALUE, RubyHelpers::VALUE])
  a = [:a]
  foo = YARV2LLVM::LLVMLIB::unsafe(a, type)
  foo[1]
  a
end
EOS
   assert_equal(int1, 1)
  end
end

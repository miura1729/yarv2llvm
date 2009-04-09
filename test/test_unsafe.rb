#
# Test for unsafe extention
#
require 'test/unit'
require 'yarv2llvm'
class UnsafeTests < Test::Unit::TestCase

  def test_unsafe
    YARV2LLVM::compile(<<-EOS, {:disasm => true, :dump_yarv => true, :optimize=> false})
def unsafe
  foo = YARV2LLVM::LLVMLIB::unsafe([:a], RubyHelpers::VALUE)
  foo[0]
  1
end
EOS
   assert_equal(int1, 1)
  end
end

#
# Test for common sub-expression elimination, copy propagation
#
require 'test/unit'
require 'yarv2llvm'
class CompileTests < Test::Unit::TestCase
  def test_array1
    YARV2LLVM::compile(<<-EOS, {:disasm => false, :dump_yarv => false, :optimize=> false})
def array1
  a = [1, 2, 3, 4, 5]
  a[0] + a[1] + a[2]
end
EOS
   assert_equal(array1, 6)
  end

  def test_array2
    YARV2LLVM::compile(<<-EOS, {:disasm => true, :dump_yarv => false, :optimize=> false})
def array2
  a = [1, 2, 3, 4, 5]
  a[0] = 2
  a[1] = 4
  a[2] = 6
  a[0] + a[1] + a[2]
end
EOS
   assert_equal(array2, 12)
  end

  def test_array3
    YARV2LLVM::compile(<<-EOS, {:disasm => true, :dump_yarv => false, :optimize=> false})
def array3
  a = [1, 2, 3, 4, 5]
  i = 0
  a[i] = 2
  a[i] + a[1] + a[2]
end
EOS
   assert_equal(array3, 7)
  end
end

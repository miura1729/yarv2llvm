require 'test/unit'
require 'yarv2llvm'

class CompileTests < Test::Unit::TestCase
  

  def test_fib
    YARV2LLVM::compile(<<-EOS
def fib(n)
  if n < 2 then
    1
  else
    fib(n - 1) + fib(n - 2)
  end
end
EOS
)
    assert_equal(fib(35), 14930352)
  end

  def test_array
    YARV2LLVM::compile(<<-EOS
def arr(n)
  a = []
  a[0] = 0
  a[1] = 1
  a[2] = 4
  a[3] = 9
  a[n]
end
EOS
)
   assert_equal(arr(0), 0)
   assert_equal(arr(1), 1)
   assert_equal(arr(2), 4)
   assert_equal(arr(3), 9)
  end
end

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
  b = []
  a = []
  a[0] = 0
  a[1] = 1
  a[2] = 4
  a[3] = 9
  b[0] = 1.0
  b[1] = 2.0
  b[2] = 3.0
  b[3] = 4.0
  b[0] = b[n]
  b[n]
end
EOS
)
   assert_equal(arr(0), 1.0)
   assert_equal(arr(1), 2.0)
   assert_equal(arr(2), 3.0)
   assert_equal(arr(3), 4.0)
  end

  def test_double
    YARV2LLVM::compile(<<-EOS
def dtest(n)
  (Math.sqrt(n) * 2.0 + 1.0) / 3.0
end
EOS
)
   assert_equal(dtest(2.0), (Math.sqrt(2.0) * 2.0 + 1.0) / 3.0)
 end
end

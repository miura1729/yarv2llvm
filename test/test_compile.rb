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
def arr()
  a = []
  a[1] + 1
end
EOS
)
   assert_equal(arr, 1)
  end
end

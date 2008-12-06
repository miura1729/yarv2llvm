require 'test/unit'
require 'yarv2llvm'

class OptionTests < Test::Unit::TestCase
  def test_optiion
    YARV2LLVM::compile(<<-EOS , {:optimize => false, :disasm => true, :dump_yarv =>true})
def fib_opt(n)
  if n < 2 then
    1
  else
    fib_opt(n - 1) + fib_opt(n - 2)
  end
end
EOS

    assert_equal(fib_opt(35), 14930352)
  end

  def test_optiion2
    YARV2LLVM::compile(<<-EOS , {:func_signature => true})
def fib_opt2(n)
  if n < 2 then
    1
  else
    fib_opt2(n - 1) + fib_opt2(n - 2)
  end
end
EOS

    assert_equal(fib_opt2(35), 14930352)
  end
end




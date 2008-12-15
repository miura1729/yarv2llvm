require 'test/unit'
require 'yarv2llvm'

class DebugTests < Test::Unit::TestCase

  def test_trace_func
    YARV2LLVM::compile(<<-EOS, {})
module YARV2LLVM
  def trace_func(event, line)
    p line
  end
end

def fib(n)
  if n < 2 then
    1
  else
    fib(n - 1) + fib(n - 2)
  end
end
EOS

   p fib(5)
  end
end

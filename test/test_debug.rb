require 'test/unit'
require 'yarv2llvm'

class DebugTests < Test::Unit::TestCase

  def test_trace_func
    YARV2LLVM::compile(<<-EOS, {disasm: true})
module YARV2LLVM
  def trace_func(event, line)
    p event
    p line
    p "----"
    p self
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

   p fib(2)
  end
end

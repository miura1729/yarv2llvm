require 'test/unit'
require 'yarv2llvm'

class DebugTests < Test::Unit::TestCase

  def test_trace_func
    YARV2LLVM::compile(<<-EOS, {dump_yarv: true, disasm: true, optimize: true})
module YARV2LLVM
  def trace_func(event, no)
    p event
    p no
    p TRACE_INFO[no]
    get_interval_cycle
    p get_interval_cycle
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

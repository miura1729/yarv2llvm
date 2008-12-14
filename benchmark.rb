#!/bin/env ruby
# 
# yarv2llvm convert yarv to LLVM and define LLVM executable as Ruby method.
#
#
require 'lib/yarv2llvm'

if __FILE__ == $0 then
require 'benchmark'

def fib(n)
  if n < 2 then
    1
  else
    fib(n - 1) + fib(n - 2)
  end
end

YARV2LLVM::compile( <<EOS
=begin
def fact(n)
  n
end
=end

def llvmfib(n)
#  fact(3.9)
  if n < 2 then
    1
  else
    llvmfib(n - 1) + llvmfib(n - 2)
  end
end

EOS
)
Benchmark.bm do |x|
  x.report("Ruby   "){  p fib(35)}
  x.report("llvm   "){  p llvmfib(35)}
end
#p fact(5.0)
end # __FILE__ == $0


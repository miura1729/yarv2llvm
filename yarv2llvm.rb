#!/bin/env ruby
# 
# yarv2llvm convert yarv to LLVM and define LLVM executable as Ruby method.
#
#
require 'lib/yarv2llvm'

if __FILE__ == $0 then
  YARV2LLVM::compile_file(ARGV[0])
end # __FILE__ == $0


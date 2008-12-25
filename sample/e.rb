require 'yarv2llvm'
YARV2LLVM::compile_file('sample/e-aux.rb', {:optimize => true, :disasm => true, :dump_yarv =>true, :array_range_check => false, :write_bc => false})
p compute_e()

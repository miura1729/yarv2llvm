#!/bin/env ruby
# 
# yarv2llvm convert yarv to LLVM and define LLVM executable as Ruby method.
#
#
require 'lib/yarv2llvm'

if __FILE__ == $0 then
  require 'optparse'
  
  preload = []
  opt = OptionParser.new
  y2lopt = {}

  opt.on('-O', '--[no-]optimize', 
         'Execute optimize (use "opt" in llvm)') do |f|
    y2lopt[:optimize] = f
  end

  opt.on('--[no-]disasm', 
         'Disassemble generated llvm code') do |f|
    y2lopt[:disasm] = f
  end

  opt.on('--[no-]dump-yarv', 
         'Dump generated yarv code') do |f|
    y2lopt[:disasm] = f
  end

  opt.on('--write-bc[=File]', 
         'Dump generated llvm bitcode to file(default is yarv.bc)') do |f|
    y2lopt[:disasm] = f
  end

  opt.on('--[no-]func-signature', 
         'Display type inferenced inforamtion about function and local variable') do |f|
    y2lopt[:disasm] = f
  end

  opt.on('-r FILE', 
         'Execute FILE by Ruby1.9 before compile main program') do |f|
    rf = File.read(f)
    prog = eval(rf)
    is = RubyVM::InstructionSequence.compile( prog, f, 1, 
            {  :peephole_optimization    => true,
               :inline_const_cache       => false,
               :specialized_instruction  => true,}).to_a
    preload.push VMLib::InstSeqTree.new(nil, is)
  end
  
  opt.parse!(ARGV)

  YARV2LLVM::compile_file(ARGV[0], y2lopt, preload)
end # __FILE__ == $0


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

  opt.on('--[no-]strict-type-inference', 
         'When occur type conflict, compile stop.') do |f|
    y2lopt[:strict_type_inderence] = f
  end

  opt.on('--[no-]inline-block', 
         'Inline block when compile "each" method.') do |f|
    y2lopt[:inline_block] = f
  end

  opt.on('--[no-]array-range-check', 
         'Raise exception when refer out of range of array or hash') do |f|
    y2lopt[:array_range_check] = f
  end

  opt.on('--[no-]cache-instance-variable', 
         'Cache instance varibale table (It is dangerous)') do |f|
    y2lopt[:cache_instance_variable] = f
  end

  opt.on('--[no-]disasm', 
         'Disassemble generated llvm code') do |f|
    y2lopt[:disasm] = f
  end

  opt.on('--[no-]dump-yarv', 
         'Dump generated yarv code') do |f|
    y2lopt[:dump_yarv] = f
  end

  opt.on('--write-bc[=File]', 
         'Dump generated llvm bitcode to file(default is yarv.bc)') do |f|
    y2lopt[:disasm] = f
  end

  opt.on('--[no-]func-signature', 
         'Display type inferenced inforamtion about function and local variable') do |f|
    y2lopt[:disasm] = f
  end
  
  opt.parse!(ARGV)

  YARV2LLVM::compile_file(ARGV[0], y2lopt, preload)
end # __FILE__ == $0


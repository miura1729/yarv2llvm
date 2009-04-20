#!/bin/ruby 
#
#  Traverse YARV and generate Ruby
#

if __FILE__ == $0 then
  require 'lib/yarv2llvm.rb'
end

module YARV2LLVM
  class YarvTranslatorToRuby<YarvVisitor
    def initialize(iseq, bind, preload)
      super(iseq, preload)
      @generated_code = Hash.new("")
      @labels = []
      @expstack = []
    end

    def run
      super
      res = ""
      @labels.each do |l|
        res = res + @generated_code[l]
      end
      print res, "\n"
    end

    def visit_block_start(code, ins, local_vars, ln, info)
      lbase = ([nil, nil] + code.header['locals'].reverse)
      lbase.each_with_index do |n, i|
        local_vars[i] = {
          :name => n, 
          :type => RubyType.new(nil, info[3], n),
          :area => nil}
      end
    end

    def visit_block_end(code, ins, local_vars, ln, info)
    end

    def visit_local_block_start(code, ins, local_vars, ln, info)
      @labels.push ln
    end

    def visit_local_block_end(code, ins, local_vars, ln, info)
    end

    def visit_default(code, ins, local_vars, ln, info)
    end

    def visit_number(code, ins, local_vars, ln, info)
    end

    def visit_getlocal(code, ins, local_vars, ln, info)
      voff = ins[1]
      @expstack.push local_vars[voff][:name]
    end

    def visit_setlocal(code, ins, local_vars, ln, info)
      voff = ins[1]
      val = @expstack.pop
      @generated_code[ln] = "#{@generated_code[ln]}\n#{local_vars[voff][:name]} = #{val}"
    end

    # getspecial
    # setspecial

    def visit_getdynamic(code, ins, local_vars, ln, info)
    end

    def visit_setdynamic(code, ins, local_vars, ln, info)
    end

    def visit_getinstancevariable(code, ins, local_vars, ln, info)
    end

    def visit_setinstancevariable(code, ins, local_vars, ln, info)
    end

    # getclassvariable
    # setclassvariable

    def visit_getconstant(code, ins, local_vars, ln, info)
    end

    def visit_setconstant(code, ins, local_vars, ln, info)
    end

    def visit_getglobal(code, ins, local_vars, ln, info)
    end

    def visit_setglobal(code, ins, local_vars, ln, info)
    end

    def visit_putnil(code, ins, local_vars, ln, info)
      @expstack.push 'nil'
    end

    def visit_putself(code, ins, local_vars, ln, info)
      @expstack.push 'self'
    end

    def visit_putobject(code, ins, local_vars, ln, info)
      p1 = ins[1].to_s
      @expstack.push p1
    end

    # putspecialobject
    
    def visit_putiseq(code, ins, local_vars, ln, info)
    end

    def visit_putstring(code, ins, local_vars, ln, info)
      p1 = ins[1].to_s
      @expstack.push p1
    end

    def visit_concatstrings(code, ins, local_vars, ln, info)
      nele = ins[1]
      eles = []
      nele.times do
        eles.push @expstack.pop
      end
      @expstack.push eles.join
    end

    def visit_tostring(code, ins, local_vars, ln, info)
      v = @expstack.pop
      @expstack.push ("\"#{v.to_s}\"")
    end

    # toregexp

    def visit_newarray(code, ins, local_vars, ln, info)
      nele = ins[1]
      inits = []
      nele.times {|n|
        inits.push @expstack.pop
      }
      @expstack.push inits
    end

    def visit_duparray(code, ins, local_vars, ln, info)
      srcarr = ins[1]
      @expstack.push srcarr.dup
    end

      # expandarray
    # concatarray
    # splatarray
    # checkincludearray
    # newhash

    def visit_newrange(code, ins, local_vars, ln, info)
    end

    def visit_pop(code, ins, local_vars, ln, info)
      @generated_code[ln] = "#{@generated_code[ln]}\n#{@expstack.pop}\n"
    end

    def visit_dup(code, ins, local_vars, ln, info)
      @expstack.push @expstack.last
    end

    def visit_dupn(code, ins, local_vars, ln, info)
    end

    # swap
    # reput
    # topn
    # setn
    # adjuststack
  
    # defined

    def visit_trace(code, ins, local_vars, ln, info)
    end

    def visit_defineclass(code, ins, local_vars, ln, info)
    end

    def visit_send(code, ins, local_vars, ln, info)
      mname = ins[1]
      nargs = ins[2]
      res = mname
      args = []
      nargs.times do
        args.push @expstack.pop
      end
      @expstack.push "#{mname}(#{args.reverse.join(',')})"
    end

    # invokesuper

    def visit_invokeblock(code, ins, local_vars, ln, info)
      narg = ins[1]
      args = []
      narg.times do |n|
        args.push @expstack.pop
      end
      @expstack.push "yield(#{args.reverse.join(',')})"
    end

    def visit_leave(code, ins, local_vars, ln, info)
      ret = @expstack.pop
      @generated_code[ln] = "#{@generated_code[ln]}\nreturn (#{ret})"
    end

    # finish
    
    # throw

    def visit_jump(code, ins, local_vars, ln, info)
    end

    def visit_branchif(code, ins, local_vars, ln, info)
      cond = @expstack.pop
      lab = ins[1]
      if @labels.include?(lab) then
        @generated_code[lab] = "while #{cond} do\n#{@generated_code[lab]}"
        @generated_code[ln] = "#{@generated_code[ln]}\nend"
      else
        @generated_code[lab] = "end\n#{@generated_code[lab]}"
        @generated_code[ln] = "#{@generated_code[ln]}\nif #{cond} then"
      end
    end

    def visit_branchunless(code, ins, local_vars, ln, info)
      cond = @expstack.pop
      lab = ins[1]
      if @generated_code[lab] != "" then
        @generated_code[lab] = "while !#{cond} do\n#{@generated_code[lab]}"
        @generated_code[ln] = "#{@generated_code[lab]}\nend"
      else
        @generated_code[lab] = "end\n#{@generated_code[lab]}"
        @generated_code[ln] = "#{@generated_code[ln]}\nif #{cond} then"
      end
    end

    # getinlinecache
    # onceinlinecache
    # setinlinecache
    # opt_case_dispatch
    # opt_checkenv
  
    def visit_opt_plus(code, ins, local_vars, ln, info)
      b = @expstack.pop
      a = @expstack.pop
      @expstack.push "((#{a}) + (#{b}))"
    end

    def visit_opt_minus(code, ins, local_vars, ln, info)
      b = @expstack.pop
      a = @expstack.pop
      @expstack.push "((#{a}) - (#{b}))"
    end

    def visit_opt_mult(code, ins, local_vars, ln, info)
      b = @expstack.pop
      a = @expstack.pop
      @expstack.push "((#{a}) * (#{b}))"
    end

    def visit_opt_div(code, ins, local_vars, ln, info)
      b = @expstack.pop
      a = @expstack.pop
      @expstack.push "((#{a}) / (#{b}))"
    end

    def visit_opt_mod(code, ins, local_vars, ln, info)
      b = @expstack.pop
      a = @expstack.pop
      @expstack.push "((#{a}) % (#{b}))"
    end

    def visit_opt_eq(code, ins, local_vars, ln, info)
      b = @expstack.pop
      a = @expstack.pop
      @expstack.push "((#{a}) == (#{b}))"
    end

    def visit_opt_neq(code, ins, local_vars, ln, info)
      b = @expstack.pop
      a = @expstack.pop
      @expstack.push "((#{a}) != (#{b}))"
    end

    def visit_opt_lt(code, ins, local_vars, ln, info)
      b = @expstack.pop
      a = @expstack.pop
      @expstack.push "((#{a}) < (#{b}))"
    end

    def visit_opt_le(code, ins, local_vars, ln, info)
      b = @expstack.pop
      a = @expstack.pop
      @expstack.push "((#{a}) <= (#{b}))"
    end

    def visit_opt_gt(code, ins, local_vars, ln, info)
      b = @expstack.pop
      a = @expstack.pop
      @expstack.push "((#{a}) > (#{b}))"
    end

    def visit_opt_ge(code, ins, local_vars, ln, info)
      b = @expstack.pop
      a = @expstack.pop
      @expstack.push "((#{a}) <= (#{b}))"
    end

    def visit_opt_ltlt(code, ins, local_vars, ln, info)
      b = @expstack.pop
      a = @expstack.pop
      @expstack.push "((#{a}) << (#{b}))"
    end

    def visit_opt_aref(code, ins, local_vars, ln, info)
      a = @expstack.pop
      b = @expstack.pop
      @expstack.push "(#{a}[#{b}])"
    end

    # opt_aset
    # opt_length
    # opt_succ
    # opt_not
    # opt_regexpmatch1
    # opt_regexpmatch2
    # opt_call_c_function
  
    # bitblt
    # answer
  end
end

if __FILE__ == $0 then
  prog = <<-EOS
a = Math.sin(10)
while a == 1 do 
   p 2 
end
if a == 1 then
  1
else
  3
end
EOS
  is = RubyVM::InstructionSequence.compile( prog, "foo", 1, 
            {  :peephole_optimization    => true,
               :inline_const_cache       => false,
               :specialized_instruction  => true,}).to_a
  p is
  iseq = VMLib::InstSeqTree.new(nil, is)
  YARV2LLVM::YarvTranslatorToRuby.new(iseq, binding, []).run
end

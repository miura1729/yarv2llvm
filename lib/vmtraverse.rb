require 'instruction'
require 'llvm'
include LLVM
include RubyInternals

class Context
  def initialize(local_vars)
    @local_vars = local_vars
    @rc = nil
  end

  attr_accessor :local_vars
  attr_accessor :rc
end

class DmyBlock
  def load(addr)
    p "Load (#{addr})"
    addr
  end

  def store(addr, value)
    p "Store (#{addr}), (#{value})"
    nil
  end

  def add(addr, value)
    p "add (#{addr}), (#{value})"
    nil
  end

  def alloca(type, num)
    p "Alloca #{type}, #{num}"
  end
end

class Type
  def initialize
  end

  def self.int
    
  end

  def self.uint
    
  end

  def self.float
    
  end

  def self.class2type(klass)
    
  end
end

class YarvVisitor
  def initialize(iseq)
    @iseq = iseq
  end

  def run
    @iseq.traverse_code([nil, nil, nil]) do |code, info|
      local = []
      ([nil, :self] + code.header['locals'].reverse).each_with_index do |n, i|
        local[i] = {:name => n, :type => nil, :area => nil}
      end
      code.lblock_list.each do |ln|
        p ln
        visit_block_start(code, nil, local, ln, info)
        code.lblock[ln].each do |ins|
          opname = ins[0].to_s
          send(("visit_" + opname).to_sym, code, ins, local, ln, info)
        end
        visit_block_end(code, nil, local, ln, info)
      end
    end
  end

  def method_missing(name, code, ins, local, ln, info)
    visit_default(code, ins, local, ln, info)
  end
end

class YarvTranslator<YarvVisitor
  def initialize(iseq)
    super(iseq)
    @stack = []
    @rescode = lambda {|b, context| context}
    @code_per_block = {}
  end

  def visit_block_start(code, ins, local, ln, info)
    oldrescode = @rescode
    @rescode = lambda {|b, context|
      context = oldrescode.call(b, context)
      context.local_vars.each_with_index {|vars, n|
        lv = b.alloca(Type::FloatTy, 1)
        vars[:area] = lv
      }
      context
    }
  end

  def visit_block_end(code, ins, local, ln, info)
    @rescode.call(DmyBlock.new, Context.new(local))
    @rescode = lambda {|b, context| context}
  end

  def visit_default(code, ins, local, ln, info)
    p ins
  end

  def visit_send(code, ins, local, ln, info)
    p ins
  end

  def visit_putobject(code, ins, local, ln, info)
    p1 = ins[1]
    @stack.push [Type.class2type(p.class), 
      lambda {|b, context| 
        p1.llvm 
        context
      }]
  end

  def visit_getlocal(code, ins, local, ln, info)
    p1 = ins[1]
    type = local[p1][:type]
    @stack.push [type,
      lambda {|b, context|
        context.rc = b.load(context.local_vars[p1][:area])
        context
      }]
  end

  def visit_setlocal(code, ins, local, ln, info)
    p1 = ins[1]
    dsttype = local[p1][:type]

    src = @stack.pop
    srctype = src[0]
    srcvalue = src[1]

#    if dsttype.compatible?(srctype) then
    if dsttype and dsttype != srctype
      raise "Type error #{ins}"
    else
#      dsttype.set_type(srctype)
      dsttype = srctype
    end

    oldrescode = @rescode
    @rescode = lambda {|b, context|
      context = oldrescode.call(b, context)
      context = srcvalue.call(b, context)
      lvar = context.local_vars[p1]
      context.rc = b.store(lvar[:area], context.rc)
      context
    }
  end

  def visit_opt_plus(code, ins, local, ln, info)
    s1 = @stack.pop
    s2 = @stack.pop
    oldrescode = @rescode
    @stack.push [nil, 
      lambda {|b, context|
        context = s1[1].call(b, context)
        s1val = context.rc
        context = s2[1].call(b, context)
        s2val = context.rc
        context.rc = b.add(s1val, s2val)
        context
      }
      ]
  end

  def visit_opt_minus(code, ins, local, ln, info)
    visit_opt_plus(code, ins, local, ln, info)
  end

  def visit_opt_mult(code, ins, local, ln, info)
    visit_opt_plus(code, ins, local, ln, info)
  end

  def visit_opt_div(code, ins, local, ln, info)
    visit_opt_plus(code, ins, local, ln, info)
  end
end
=begin
  def visit_opt_minus(code, ins, local, ln, info)
    s1 = @stack.pop
    s2 = @stack.pop
#    @stack.push "#{s2} - #{s1}"
  end

  def visit_opt_mult(code, ins, local, ln, info)
    s1 = @stack.pop
    s2 = @stack.pop
#    @stack.push "#{s2} * #{s1}"
  end

  def visit_opt_div(code, ins, local, ln, info)
    s1 = @stack.pop
    s2 = @stack.pop
#    @stack.push "#{s2} / #{s1}"
  end
end
=end

include VMLib
is = RubyVM::InstructionSequence.compile(File.read(ARGV[0])).to_a
iseq = InstSeqTree.new(nil, is)
YarvTranslator.new(iseq).run

=begin
stack = []
iseq.traverse_code([nil, nil, nil]) do |code, info|
  code.lblock_list.each do |ln|
    p ln
    local = ["", :self] + code.header['locals'].reverse
    p local
    code.lblock[ln].each do |ins|
      p ins
      nm = ins[0]
      p1 = ins[1]
      case nm 
      when :send
        if p1 == :"core#define_method" then
          s1 = stack.pop
          s2 = stack.pop
          p "def #{s1}"
        else
          res = ""
          p2 = ins[2]
          p2.times do |n|
            res += stack.pop.to_s
            res += ','
          end
          res.chop!
          stack.push "#{p1}(#{res})"
        end
      when :getlocal
        stack.push local[p1]
      when :setlocal
        src = stack.pop
        p "#{local[p1]} = #{src}"
      when :putobject
        stack.push p1
      when :opt_plus
        s1 = stack.pop
        s2 = stack.pop
        stack.push "#{s2} + #{s1}"
      when :opt_minus
        s1 = stack.pop
        s2 = stack.pop
        stack.push "#{s2} - #{s1}"
      when :opt_mult
        s1 = stack.pop
        s2 = stack.pop
        stack.push "#{s2} * #{s1}"
      when :opt_div
        s1 = stack.pop
        s2 = stack.pop
        stack.push "#{s2} / #{s1}"
      when :opt_eq
        s1 = stack.pop
        s2 = stack.pop
        stack.push "#{s2} == #{s1}"

      when :branchunless
        s1 = stack.pop
        p "if #{s1} then"
      end
    end
  end
end

=end

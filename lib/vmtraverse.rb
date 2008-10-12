require 'tempfile'
require 'llvm'

require 'instruction'
require 'methoddef'

def pppp(n)
#  p n
end

class Symbol
  def llvm
    immediate
  end
end

module YARV2LLVM
include LLVM
include RubyInternals

class Context
  def initialize(local)
    @local_vars = local
    @rc = nil
    @org = nil
    @blocks = {}
    @block_value = {}
    @last_stack_value = nil
    @jump_hist = {}
    @curln = nil
  end

  attr_accessor :local_vars
  attr_accessor :rc
  attr_accessor :org
  attr_accessor :blocks
  attr_accessor :last_stack_value
  attr_accessor :jump_hist
  attr_accessor :curln
  attr_accessor :block_value
end

class DmyBlock
  def load(addr)
    pppp "Load (#{addr})"
    addr
  end

  def store(value, addr)
    pppp "Store (#{value}), (#{addr})"
    nil
  end

  def add(p1, p2)
    pppp "add (#{p1}), (#{p2})"
  end

  def sub(p1, p2)
    pppp "sub (#{p1}), (#{p2})"
  end

  def mul(p1, p2)
    pppp "mul (#{p1}), (#{p2})"
  end

  def div(p1, p2)
    pppp "div (#{p1}), (#{p2})"
  end

  def icmp_eq(p1, p2)
    pppp "icmp_eq (#{p1}), (#{p2})"
  end

  def fcmp_ueq(p1, p2)
    pppp "fcmp_eq (#{p1}), (#{p2})"
  end

  def alloca(type, num)
    @@num ||= 0
    @@num += 1
    pppp "Alloca #{type}, #{num}"
    "[#{@@num}]"
  end

  def set_insert_point(n)
    pppp "set_insert_point #{n}"
  end

  def cond_br(cond, th, el)
    pppp "cond_br #{cond} #{th} #{el}"
  end

  def return(rc)
    pppp "return #{rc}"
  end

  def call(name, *args)
    pppp "call #{name}(#{args.join(',')})"
  end
end

class RubyType
  @@type_table = []
  def initialize(type, name = nil)
    @name = name
    @type = type
    @resolveed = false
    @same_type = []
    @@type_table.push self
  end

  attr_accessor :type
  attr_accessor :resolveed
  attr :name

  def add_same_type(type)
    @same_type.push type
  end

  def self.resolve
    @@type_table.each do |ty|
      ty.resolveed = false
    end

    @@type_table.each do |ty|
      ty.resolve
    end
  end

  def resolve
    if @resolveed then
      return
    end

    if @type then
      @resolveed = true
      @same_type.each do |ty|
        if ty.type and ty.type != @type then
          raise "Type error #{ty.name}(#{ty.type}) and #{@name}(#{@type})"
        else
          ty.type = @type
          ty.resolve
        end
      end
    end
  end

  def self.fixnum
    RubyType.new(Type::Int32Ty)
  end

  def self.float
    RubyType.new(Type::FloatTy)
  end

  def self.symbol
    RubyType.new(Type::VALUE)
  end

  def self.typeof(obj)
    case obj
    when Fixnum
      RubyType.fixnum

    when Float
      RubyType.float

    when Symbol
      RubyType.symbol

    else
      raise "Unsupported type #{obj}"
    end
  end
end

class LLVMBuilder
  include RubyHelpers
  def initialize
    @module = LLVM::Module.new('yarv2llvm')
    @externed_function = {}
    ExecutionEngine.get(@module)
  end

  RFLOAT = Type.struct([RBASIC, Type::FloatTy])
  def make_stub(name, rett, argt, orgfunc)
    sname = "__stub_" + name
    stype = Type.function(Type::VALUE, [Type::VALUE] * argt.size)
    @stubfunc = @module.get_or_insert_function(sname, stype)
    eb = @stubfunc.create_block
    b = eb.builder
    argv = []
    argt.each_with_index do |ar, n|
      case ar
      when Type::FloatTy
        argv.push b.struct_gep(@stubfunc.arguments[n], 1)

      when Type::Int32Ty
        x = b.lshr(@stubfunc.arguments[n], 1.llvm)
        argv.push x
      end
    end
    ret = b.call(orgfunc, *argv)
    case rett
    when Type::FloatTy
    when Type::Int32Ty
      x = b.shl(ret, 1.llvm)
      x = b.or(FIXNUM_FLAG, x)
      b.return(x)
    end
    MethodDefinition::RubyMethodStub[name] = {
      :sname => sname,
      :stub => @stubfunc,
      :argt => argt,
      :type => stype}
  end

  def define_function(name, rett, argt)
    type = Type.function(rett, argt)
    @func = @module.get_or_insert_function(name, type)
    @stub = make_stub(name, rett, argt, @func)

    MethodDefinition::RubyMethod[name.to_sym] = {
      :rettype => rett,
      :argtype => argt,
      :func   => @func,
    }
      
    eb = @func.create_block
    eb.builder
  end

  def arguments
    @func.arguments
  end

  def create_block
    @func.create_block
  end

  def external_function(name, type)
    if rc = @externed_function[name] then
      rc
    else
      @externed_function[name] = @module.external_function(name, type)
    end
  end

  def optimize
    bitout =  Tempfile.new('bit')
    @module.write_bitcode("#{bitout.path}")
    File.popen("/usr/local/bin/opt -O3 -f #{bitout.path}") {|fp|
      @module = LLVM::Module.read_bitcode(fp.read)
    }
    MethodDefinition::RubyMethodStub.each do |nm, val|
      val[:stub] = @module.get_or_insert_function(val[:sname], val[:type])
    end
  end

  def disassemble
    @module.write_bitcode("yarv.bc")
    p @module
  end
end

class YarvVisitor
  def initialize(iseq)
    @iseq = iseq
  end

  def run
    @iseq.traverse_code([nil, nil, nil]) do |code, info|
      local = []
      visit_block_start(code, nil, local, nil, info)

      code.lblock_list.each do |ln|
        visit_local_block_start(code, ln, local, ln, info)

        code.lblock[ln].each do |ins|
          opname = ins[0].to_s
          send(("visit_" + opname).to_sym, code, ins, local, ln, info)
        end

        visit_local_block_end(code, ln, local, ln, info)
      end

      visit_block_end(code, nil, local, nil, info)
    end
  end

  def method_missing(name, code, ins, local, ln, info)
    visit_default(code, ins, local, ln, info)
  end
end

class YarvTranslator<YarvVisitor
  def initialize(iseq)
    super(iseq)
    @expstack = []
    @rescode = lambda {|b, context| context}
    @builder = LLVMBuilder.new
    @jump_hist = {}
    @prev_label = nil
    @is_live = nil
  end

  def run
    super

    @builder.optimize
#    @builder.disassemble
    
  end
  
  def get_or_create_block(ln, b, context)
    if context.blocks[ln] then
      context.blocks[ln]
    else
      context.blocks[ln] = @builder.create_block
    end
  end
  
  def visit_local_block_start(code, ins, local, ln, info)
    oldrescode = @rescode
    live =  @is_live

    @is_live = nil
    if @expstack.size > 0 then
      valexp = @expstack.pop
    end
    @jump_hist[ln] ||= []
    @jump_hist[ln].push @prev_label
    @rescode = lambda {|b, context|
      context = oldrescode.call(b, context)
      blk = get_or_create_block(ln, b, context)
      if live then
        if valexp then
          bval = [valexp[0], valexp[1].call(b, context).rc]
          context.block_value[context.curln] = bval
        end
        b.br(blk)
        context.jump_hist[ln] ||= []
        context.jump_hist[ln].push context.curln
      end
      context.curln = ln
      b.set_insert_point(blk)
      context
    }

    if live and valexp then
#      check_same_type_2arg_static(r1, r2)
      n = 0
      while n < @jump_hist[ln].size - 1 do
#        valexp[0].add_same_type(@expstack[@expstack.size-n - 1][0])
        n += 1
      end
      @expstack.push [valexp[0],
        lambda {|b, context|
          blocks = []
          if context.curln then
            rc = b.phi(context.block_value[context.jump_hist[ln][0]][0].type)
            
            context.jump_hist[ln].reverse.each do |lab|
              rc.add_incoming(context.block_value[lab][1], context.blocks[lab])
            end

            context.rc = rc
          end
          context
        }]
    end
  end
  
  def visit_local_block_end(code, ins, local, ln, info)
    # This if-block inform next calling visit_local_block_start
    # must generate jump statement.
    # You may worry generate wrong jump statement but return
    # statement. But in this situration, visit_local_block_start
    # don't call before visit_block_start call.
    if @is_live == nil then
      @is_live = true
      @prev_label = ln
    end
    # p @expstack.map {|n| n[1]}
  end
  
  def visit_block_start(code, ins, local, ln, info)
    ([nil, :self] + code.header['locals'].reverse).each_with_index do |n, i|
      local[i] = {:name => n, :type => RubyType.new(nil, n), :area => nil}
    end
    numarg = code.header['misc'][:arg_size]

    # regist function to RubyCMthhod for recursive call
    if info[1] then
      if MethodDefinition::RubyMethod[info[1]] then
        raise "#{info[1]} is already defined"
      else
        MethodDefinition::RubyMethod[info[1]]= {}
      end
    end

    oldrescode = @rescode
    @rescode = lambda {|b, context|
      context = oldrescode.call(b, context)
      context.local_vars.each_with_index {|vars, n|
        if vars[:type].type then
          lv = b.alloca(vars[:type].type, 1)
          vars[:area] = lv
        else
          vars[:area] = nil
        end
      }

      # Copy argument in reg. to allocated area
      arg = @builder.arguments
      lvars = context.local_vars
      1.upto(numarg) do |n|
        b.store(arg[n - 1], lvars[-n][:area])
      end

      context
    }
  end
  
  def visit_block_end(code, ins, local, ln, info)
    RubyType.resolve

    numarg = code.header['misc'][:arg_size]
=begin
    # write function prototype
    print "#{info[1]} :("
    1.upto(numarg) do |n|
      print "#{local[-n][:type].type}, "
    end
    print ") -> #{@expstack.last[0].type}\n"
=end

    argtype = []
    1.upto(numarg) do |n|
      argtype[n - 1] = local[-n][:type].type
    end

    pppp "define #{info[1]}"
    pppp @expstack
    if @expstack.last and info[1] then
      b = @builder.define_function(info[1].to_s, 
                                   @expstack.last[0].type, argtype)
      context = @rescode.call(b, Context.new(local))
      p1 = @expstack.pop
      b.return(p1[1].call(b, context).rc)
      pppp "ret type #{p1[0].type}"
      pppp "end"
    end

    @rescode = lambda {|b, context| context}
  end
  
  def visit_default(code, ins, local, ln, info)
#    pppp ins
  end
  
  def visit_putnil(code, ins, local, ln, info)
    # Nil is not support yet.
=begin
    @expstack.push [RubyType.typeof(nil), 
      lambda {|b, context| 
        nil
      }]
=end
  end

  def visit_putobject(code, ins, local, ln, info)
    p1 = ins[1]
    @expstack.push [RubyType.typeof(p1), 
      lambda {|b, context| 
        pppp p1
        context.rc = p1.llvm 
        context.org = p1
        context
      }]
  end
  
  def visit_getlocal(code, ins, local, ln, info)
    p1 = ins[1]
    type = local[p1][:type]
    @expstack.push [type,
      lambda {|b, context|
        context.rc = b.load(context.local_vars[p1][:area])
        context.org = local[p1][:name]
        context
      }]
  end
  
  def visit_setlocal(code, ins, local, ln, info)
    p1 = ins[1]
    dsttype = local[p1][:type]
    
    src = @expstack.pop
    srctype = src[0]
    srcvalue = src[1]

    srctype.add_same_type(dsttype)
    dsttype.add_same_type(srctype)

    oldrescode = @rescode
    @rescode = lambda {|b, context|
      context = oldrescode.call(b, context)
      context = srcvalue.call(b, context)
      context.last_stack_value = context.rc
      lvar = context.local_vars[p1]
      context.rc = b.store(context.rc, lvar[:area])
      context.org = lvar[:name]
      context
    }
  end

  def visit_send(code, ins, local, ln, info)
    p1 = ins[1]
    if MethodDefinition::SystemMethod[p1]
      return
    end

    if funcinfo = MethodDefinition::CMethod[p1] then
      rettype = RubyType.new(funcinfo[:rettype])
      argtype = funcinfo[:argtype].map {|ts| RubyType.new(ts)}
      cname = funcinfo[:cname]
      
      if argtype.size == ins[2] then
        argtype2 = argtype.map {|tc| tc.type}
        ftype = Type.function(rettype.type, argtype2)
        func = @builder.external_function(cname, ftype)

        p = []
        0.upto(ins[2] - 1) do |n|
          p[n] = @expstack.pop
          if p[n][0].type and p[n][0].type != argtype[n].type then
            raise "arg error"
          else
            p[n][0].add_same_type argtype[n]
            argtype[n].add_same_type p[n][0]
          end
        end
          
        @expstack.push [rettype,
          lambda {|b, context|
            args = []
            p.each do |pe|
              args.push pe[1].call(b, context).rc
            end
            # p cname
            # print func
            context.rc = b.call(func, *args)
            context
          }
        ]
        return
      end
    end
    if MethodDefinition::RubyMethod[p1] then
      pppp "RubyMethod called #{p1.inspect}"
      p = []
      0.upto(ins[2] - 1) do |n|
        p[n] = @expstack.pop
      end
      @expstack.push [RubyType.new(rettype),
        lambda {|b, context|
          minfo = MethodDefinition::RubyMethod[p1]
          func = minfo[:func]
          args = []
          p.each do |pe|
            args.push pe[1].call(b, context).rc
          end
          context.rc = b.call(func, *args)
          context
        }]
      return
    end
  end

  def visit_branchunless(code, ins, local, ln, info)
    s1 = @expstack.pop
    oldrescode = @rescode
    lab = ins[1]
    valexp = nil
    if @expstack.size > 0 then
      valexp = @expstack.pop
    end
    bval = nil
    @is_live = false
    iflab = nil
    @jump_hist[lab] ||= []
    @jump_hist[lab].push ln
    @rescode = lambda {|b, context|
      oldrescode.call(b, context)
      eblock = @builder.create_block
      iflab = context.curln
      context.curln = (context.curln.to_s + "_1").to_sym
      context.blocks[context.curln] = eblock
      tblock = get_or_create_block(lab, b, context)
      if valexp then
        bval = [valexp[0], valexp[1].call(b, context).rc]
        context.block_value[iflab] = bval
      end
      b.cond_br(s1[1].call(b, context).rc, eblock, tblock)
      context.jump_hist[lab] ||= []
      context.jump_hist[lab].push context.curln
      b.set_insert_point(eblock)

      context
    }
    if valexp then
      @expstack.push [valexp[0], 
        lambda {|b, context| 
          context.rc = context.block_value[iflab][1]
          context}]

    end
  end

  def visit_branchif(code, ins, local, ln, info)
    s1 = @expstack.pop
    oldrescode = @rescode
    lab = ins[1]
    valexp = nil
    if @expstack.size > 0 then
      valexp = @expstack.pop
    end
    bval = nil
#    @is_live = false
    iflab = nil
    @jump_hist[lab] ||= []
    @jump_hist[lab].push ln
    @rescode = lambda {|b, context|
      oldrescode.call(b, context)
      tblock = get_or_create_block(lab, b, context)
      iflab = context.curln

      eblock = @builder.create_block
      while context.blocks[context.curln] do
        context.curln = (context.curln.to_s + "_1").to_sym
      end
      context.blocks[context.curln] = eblock
      if valexp then
        bval = [valexp[0], valexp[1].call(b, context).rc]
        context.block_value[iflab] = bval
      end
      b.cond_br(s1[1].call(b, context).rc, tblock, eblock)
      context.jump_hist[lab] ||= []
      context.jump_hist[lab].push context.curln
      b.set_insert_point(eblock)

      context
    }
    if valexp then
      @expstack.push [valexp[0], 
        lambda {|b, context| 
          context.rc = context.block_value[iflab][1]
          context}]

    end
  end

  def visit_jump(code, ins, local, ln, info)
    lab = ins[1]
    fmlab = nil
    oldrescode = @rescode
    valexp = nil
    if @expstack.size > 0 then
      valexp = @expstack.pop
    end
    bval = nil
    @is_live = false
    @jump_hist[lab] ||= []
    @jump_hist[lab].push ln
    @rescode = lambda {|b, context|
      oldrescode.call(b, context)
      jblock = get_or_create_block(lab, b, context)
      if valexp then
        bval = [valexp[0], valexp[1].call(b, context).rc]
        fmlab = context.curln
        context.block_value[fmlab] = bval
      end
      b.br(jblock)
      context.jump_hist[lab] ||= []
      context.jump_hist[lab].push context.curln

      context
    }
    if valexp then
      @expstack.push [valexp[0], 
        lambda {|b, context| 
          context.rc = context.block_value[fmlab][1]
          context
        }]

    end
  end

  def visit_dup(code, ins, local, ln, info)
    s1 = @expstack.pop
    @expstack.push [s1[0],
      lambda {|b, context|
        context.rc = context.last_stack_value
        context
      }]
    @expstack.push s1
  end
  
  def check_same_type_2arg_static(p1, p2)
    p1[0].add_same_type(p2[0])
    p2[0].add_same_type(p1[0])
  end
  
  def check_same_type_2arg_gencode(b, context, p1, p2)
    if p1[0].type == nil then
      if p2[0].type == nil then
        print "ambious type #{p2[1].call(b, context).org}\n"
      else
        p1[0].type = p2[0].type
      end
    else
      if p2[0].type and p1[0].type != p2[0].type then
        print "diff type #{p1[1].call(b, context).org}\n"
      else
        p2[0].type = p1[0].type
      end
    end
  end

  def gen_common_opt_2arg(b, context, s1, s2)
    check_same_type_2arg_gencode(b, context, s1, s2)
    context = s1[1].call(b, context)
    s1val = context.rc
    #        pppp s1[0]
    context = s2[1].call(b, context)
    s2val = context.rc

    [s1val, s2val, context]
  end

  def visit_opt_plus(code, ins, local, ln, info)
    s2 = @expstack.pop
    s1 = @expstack.pop
    #    p @expstack
    check_same_type_2arg_static(s1, s2)
    
    @expstack.push [s1[0], 
      lambda {|b, context|
        s1val, s2val, context = gen_common_opt_2arg(b, context, s1, s2)
        context.rc = b.add(s1val, s2val)
        context
      }
    ]
  end
  
  def visit_opt_minus(code, ins, local, ln, info)
    s2 = @expstack.pop
    s1 = @expstack.pop
    check_same_type_2arg_static(s1, s2)
    
    @expstack.push [s1[0], 
      lambda {|b, context|
        s1val, s2val, context = gen_common_opt_2arg(b, context, s1, s2)
        context.rc = b.sub(s1val, s2val)
        context
      }
    ]
  end
  
  def visit_opt_mult(code, ins, local, ln, info)
    s2 = @expstack.pop
    s1 = @expstack.pop
    check_same_type_2arg_static(s1, s2)
    
    @expstack.push [s1[0], 
      lambda {|b, context|
        s1val, s2val, context = gen_common_opt_2arg(b, context, s1, s2)
        context.rc = b.mul(s1val, s2val)
        context
      }
    ]
  end
  
  def visit_opt_div(code, ins, local, ln, info)
    s2 = @expstack.pop
    s1 = @expstack.pop
    check_same_type_2arg_static(s1, s2)
    
    @expstack.push [s1[0], 
      lambda {|b, context|
        s1val, s2val, context = gen_common_opt_2arg(b, context, s1, s2)
        case s1[0].type
        when Type::FloatTy
          context.rc = b.fdiv(s1val, s2val)
        when Type::Int32TY
          context.rc = b.sdiv(s1val, s2val)
        end
        context
      }
    ]
  end

  def visit_opt_eq(code, ins, local, ln, info)
    s2 = @expstack.pop
    s1 = @expstack.pop
    check_same_type_2arg_static(s1, s2)
    
    @expstack.push [nil, 
      lambda {|b, context|
        s1val, s2val, context = gen_common_opt_2arg(b, context, s1, s2)
        case s1[0].type
          when Type::FloatTy
          context.rc = b.fcmp_ueq(s1val, s2val)

          when Type::Int32Ty
          context.rc = b.icmp_eq(s1val, s2val)
        end
        context
      }
    ]
  end

  def visit_opt_lt(code, ins, local, ln, info)
    s2 = @expstack.pop
    s1 = @expstack.pop
    check_same_type_2arg_static(s1, s2)
    
    @expstack.push [nil, 
      lambda {|b, context|
        s1val, s2val, context = gen_common_opt_2arg(b, context, s1, s2)
        case s1[0].type
          when Type::FloatTy
          context.rc = b.fcmp_ult(s1val, s2val)

          when Type::Int32Ty
          context.rc = b.icmp_slt(s1val, s2val)
        end
        context
      }
    ]
  end
  
  def visit_opt_gt(code, ins, local, ln, info)
    s2 = @expstack.pop
    s1 = @expstack.pop
    check_same_type_2arg_static(s1, s2)
    
    @expstack.push [nil, 
      lambda {|b, context|
        s1val, s2val, context = gen_common_opt_2arg(b, context, s1, s2)
        case s1[0].type
          when Type::FloatTy
          context.rc = b.fcmp_ugt(s1val, s2val)

          when Type::Int32Ty
          context.rc = b.icmp_sgt(s1val, s2val)
        end
        context
      }
    ]
  end
end

def compile_file(fn)
  is = RubyVM::InstructionSequence.compile( File.read(fn), fn, 1, 
            {  :peephole_optimization    => true,
               :inline_const_cache       => false,
               :specialized_instruction  => true,}).to_a
  compcommon(is)
end

def compile(str)
  is = RubyVM::InstructionSequence.compile( str, "<llvm2ruby>", 1, 
            {  :peephole_optimization    => true,
               :inline_const_cache       => false,
               :specialized_instruction  => true,}).to_a
  compcommon(is)
end

def compcommon(is)
  iseq = VMLib::InstSeqTree.new(nil, is)
  YarvTranslator.new(iseq).run
  MethodDefinition::RubyMethodStub.each do |key, m|
    name = key
    n = 0
    args = m[:argt].map {|x|  n += 1; "p" + n.to_s}.join(',')
    df = "def #{key}(#{args});LLVM::ExecutionEngine.run_function(YARV2LLVM::MethodDefinition::RubyMethodStub['#{key}'][:stub], #{args});end" 
    eval df, TOPLEVEL_BINDING
  end
end

module_function :compile_file
module_function :compile
module_function :compcommon

end

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
def llvmfib(n)
  if n < 2 then
    1
  else
    llvmfib(n - 1) + llvmfib(n - 2) + 0
  end
end
EOS
)
Benchmark.bm do |x|
  x.report("Ruby   "){  p fib(35)}
  x.report("llvm   "){  p llvmfib(35)}
end
end # __FILE__ == $0



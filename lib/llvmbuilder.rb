#!/bin/ruby
#
#  Abstruct layer of llvmruby
#

module YARV2LLVM

class LLVMBuilder
  include LLVM
  include RubyHelpers

  def initialize
    @module = LLVM::Module.new('yarv2llvm')
    @externed_function = {}
    @func = nil
    @global_ptr = nil
    @builder_to_func = {}
    ExecutionEngine.get(@module)
  end
  
  def init
    @module = LLVM::Module.new('yarv2llvm')
    @externed_function = {}
  end

  def to_label(rec, s)
    to_label_aux(rec) + "_" + to_label_aux(s)
  end

  def to_label_aux(s)
    ns = s.gsub(/_/, "__")
    ns.gsub!(/=/, "_e")
    ns.gsub!(/!/, "_b")
    ns.gsub!(/@/, "_a")
    ns.gsub!(/\?/, "_q")
    ns.gsub!(/\+/, "_p")
    ns
  end

  def make_stub(recklass, name, rett, argt, orgfunc)
    pppp "Make stub #{name}"
    sname = "__stub_" + to_label(recklass.to_s, name)
    nargs = argt.size
    if recklass == nil then
      argt.unshift RubyType.value
    end
    stype = Type.function(VALUE, [VALUE] * argt.size)
    @stubfunc = @module.get_or_insert_function(sname, stype)
    eb = @stubfunc.create_block
    b = eb.builder
    argv = []
    context = Context.new([], self)

    argt.each_with_index do |ar, n|
      v = ar.type.from_value(@stubfunc.arguments[n], b, context)
      argv.push v
    end

    if recklass == nil then
      argv.shift
    end

    ret = b.call(orgfunc, *argv)

    x = rett.type.to_value(ret, b, context)
    b.return(x)

    MethodDefinition::RubyMethodStub[name] = {
      :sname => sname,
      :stub => @stubfunc,
      :argt => argt,
      :type => stype,
      :receiver => recklass,
      :outputp => false}
    pppp "Make stub #{name} end"
  end

  def define_function(recklass, name, rett, argt, is_mkstub)
    argtl = argt.map {|a| a.type.llvm}
    rettl = rett.type.llvm
    type = Type.function(rettl, argtl)
    fname = to_label(recklass.to_s, name)
    @func = @module.get_or_insert_function(fname, type)
    
    if is_mkstub then
      @stub = make_stub(recklass, name, rett, argt, @func)
    end

    MethodDefinition::RubyMethod[name.to_sym][recklass][:func] = @func

    eb = @func.create_block
    b =eb.builder
    @builder_to_func[b] = @func
    b
  end

  def select_func(b)
    @func = @builder_to_func[b]
  end
  
  def define_function_raw(name, type)
    @func = @module.get_or_insert_function(name, type)
    b = @func.create_block.builder
    @builder_to_func[b] = @func
    b
  end

  def get_or_insert_function(recklass, name, type)
    ns = to_label(recklass.to_s, name.to_s)
    @module.get_or_insert_function(ns, type)
  end

  def get_or_insert_function_raw(name, type)
    @module.get_or_insert_function(name, type)
  end
  
  def define_global_variable(type, init)
    @global_ptr = @module.global_variable(type, init)
  end

  def global_variable
    @global_ptr
  end

  def arguments
    @func.arguments
  end

  def create_block
    @func.create_block
  end

  def current_function
    @func
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
      if nm then
        nn = val[:sname]
        val[:stub] = @module.get_or_insert_function(nn, val[:type])
      end
    end
  end

  def disassemble
    p @module
  end

  def write_bc(nfn)
    fn = "yarv.bc"
    if nfn.is_a?(String) then
      fn = nfn
    end
    @module.write_bitcode(fn)
  end
end

end # module YARV2LLVM

#!/bin/ruby 
#
#  Traverse YARV instruction array
#

module YARV2LLVM
class Context
  def initialize(local, builder)
    @local_vars = local
    @rc = nil
    @org = nil
    @blocks = {}
    @block_value = {}
    @curln = nil
    @builder = builder
    @current_frame = nil
    @array_alloca_area = nil
    @array_alloca_size = nil
    @loop_cnt_alloca_area = []
    @loop_cnt_alloca_size = nil
    @instance_var_tab = nil
    @instance_vars_local = nil
    @instance_vars_local_area = nil
    @inline_args = nil
    @is_live = true

    @user_defined = {}
  end

  attr_accessor :local_vars
  attr_accessor :rc
  attr_accessor :org
  attr_accessor :blocks
  attr_accessor :curln
  attr_accessor :block_value
  attr_accessor :current_frame
  attr_accessor :array_alloca_area
  attr_accessor :array_alloca_size
  attr_accessor :loop_cnt_alloca_area
  attr_accessor :loop_cnt_alloca_size
  attr_accessor :instance_var_tab
  attr_accessor :instance_vars_local
  attr_accessor :instance_vars_local_area
  attr_accessor :inline_args
  attr_accessor :is_live
  attr :builder
  attr :frame_struct
  attr :user_defined
end

class YarvVisitor
  def initialize(iseq, preload)
    @iseqs = preload
    @iseqs.push iseq
  end

  def run
    curlinno = 0
    @iseqs.each do |iseq|
      action = lambda {|code, info|
        info[3] = "#{code.header['filename']}:#{curlinno}"
         
        if code.header['type'] == :block then
          info[1] = (info[1].to_s + '+blk+' + code.info[2].to_s).to_sym
        end
        
        local_vars = []
        visit_block_start(code, nil, local_vars, nil, info)
        curln = nil
        code.lblock_list.each do |ln|
          visit_local_block_start(code, ln, local_vars, ln, info)
          
          curln = ln
          code.lblock[ln].each do |ins|
            if ins.is_a?(Fixnum) then
              curlinno = ins
              visit_number(code, ins, local_vars, curln, info)
            else
              info[3] = "#{code.header['filename']}:#{curlinno}"
              opname = ins[0].to_s
              send(("visit_" + opname).to_sym, code, ins, local_vars, curln, info)
            end
            
            case ins[0]
            when :branchif, :branchunless, :jump
              curln = (curln.to_s + "_1").to_sym
            end
          end
          visit_local_block_end(code, ln, local_vars, curln, info)
        end
        
        visit_block_end(code, nil, local_vars, nil, info)
      }

      iseq.traverse_code([nil, nil, nil, nil], action)
    end
  end

  def method_missing(name, code, ins, local_vars, ln, info)
    visit_default(code, ins, local_vars, ln, info)
  end
end

class YarvTranslator<YarvVisitor
  include LLVM
  include RubyHelpers
  include LLVMUtil

  @@builder = LLVMBuilder.new
  @@instance_num = 0
  def initialize(iseq, bind, preload)
    super(iseq, preload)
    @@instance_num += 1

    # Pack of utilty method for llvm code generation
    @builder = @@builder
    @builder.init
    
    # bindig of caller of LLVM::compile function.
    @binding = bind

    # Expression stack. YARV stack operation is simulated by this stack.
    @expstack = []

    # Generate function of llvm code for current block
    @rescode = lambda {|b, context| context}

    # Hash function name to generate function.
    # When this value call by call method, generate llvm code correspond 
    # to function name.
    @generated_code = {}
    @generated_define_func = {}

    # Hash name of local block to name of local block jump to the 
    # local block of the key
    @jump_from = {}
    
    # Name of prevous local block. This uses 
    # This variable uses only record @jump_from. This process need
    # name of current local block and previous local block.
    @prev_label = nil

    # True means reach end of block thus must insert jump instruction
    # False meams not reach end of block thus insert nothing
    # nil means under processing and don't kown true or false.
    @is_live = nil

    # Struct of frame. Various size of variable in the frame, so to access
    # the frame it is define the struct of frame as structure of LLVM.
    @frame_struct = {}

    # Hash code object to local variable information.
    @locals = {}

    # Trie means current method include 
    # invokeblock instruction (yield statement)
    @have_yield = false

    # Size of alloca area for call rb_ary_new4 and new
    #  nil is not allocate
    @array_alloca_size = nil

    @loop_cnt_alloca_size = 0
    @loop_cnt_current = 0

    # Table of instance variable. The table contains type information.
    @instance_var_tab = Hash.new {|hash, klass|
      hash[klass] = Hash.new {|ivtab, ivname|
        ivtab[ivname] = {}
      }
    }

    # Table of instanse variable which is used current block
    @instance_vars_local = {}

    # Table of type of constant.
    @constant_type_tab = Hash.new {|hash, klass|
      hash[klass] = {}
    }

    # Information of global variables by malloc
    @global_malloc_area_tab = []

    # Number of trace(for profile speed up)
    @trace_no = 0

    @global_var_tab = Hash.new {|gltab, glname|
      gltab[glname] = {}
    }
  end

  include IntRuby
  def run
    super

    # generate code for access Ruby internal
    if OPTION[:cache_instance_variable] then
      if @instance_var_tab.size != 0 then
        gen_ivar_ptr(@builder)
      end
    end
    
    @generated_define_func.each do |klass, value|
      value.each do |name, gen|
        if name then
          gen.call(nil)
        end
      end
    end

    initfunc = gen_init_ruby(@builder)

    @generated_code.each do |klass, value|
      value.each do |name, gen|
        if name then
          gen.call
        end
      end
    end

    if OPTION[:write_bc] then
      @builder.write_bc(OPTION[:write_bc])
    end

    if OPTION[:optimize] then
      @builder.optimize
    end

    deffunc = gen_define_ruby(@builder)

    if OPTION[:disasm] then
      @builder.disassemble
    end

    LLVM::ExecutionEngine.run_function(deffunc)
    LLVM::ExecutionEngine.run_function(initfunc)
  end
  
  def visit_block_start(code, ins, local_vars, ln, info)
    @have_yield = false

    @array_alloca_size = nil
    @loop_cnt_alloca_size = 0
    @loop_cnt_current = 0

    @instance_vars_local = {}

    @have_yield = false
    lbase = ([nil, nil, nil, nil] + code.header['locals'].reverse)
    lbase.each_with_index do |n, i|
      local_vars[i] = {
        :name => n, 
        :type => RubyType.new(nil, info[3], n),
        :area => nil}
    end
    local_vars[0][:type] = RubyType.new(P_CHAR, info[3], "Parent frame")
    local_vars[1][:type] = RubyType.new(MACHINE_WORD, info[3], 
                                        "Pointer to block")
    local_vars[2][:type] = RubyType.from_sym(info[0], info[3], "self")
    local_vars[3][:type] = RubyType.new(Type::Int32Ty, info[3], 
                                        "Exception Status")

    # Argument parametor |...| is omitted.
    an = code.header['locals'].size + 1
    dn = code.header['misc'][:local_size]
    if an < dn then
      (dn - an).times do |i|
        local_vars.push({
          :type => RubyType.new(nil),
          :area => nil
        })
      end
    end

    @locals[code] = local_vars
    numarg = code.header['misc'][:arg_size]

    # regist function to RubyMthhod for recursive call
    if info[1] then
      minfo = MethodDefinition::RubyMethod[info[1]][info[0]]
      if minfo == nil then
        minfo = MethodDefinition::RubyMethod[info[1]][nil]
        if minfo then
          MethodDefinition::RubyMethod[info[1]][info[0]] = minfo
        end
      end
      if !minfo.is_a?(Hash) then
        argt = []
        1.upto(numarg) do |n|
          argt[n - 1] = local_vars[-n][:type]
        end
        #        argt.push local_vars[2][:type]
        # self
        if info[0] or code.header['type'] != :method then
          argt.push RubyType.value(info[3])
        end
        if code.header['type'] == :block or @have_yield then
          argt.push local_vars[0][:type]
          argt.push local_vars[1][:type]
        end

        MethodDefinition::RubyMethod[info[1]][info[0]]= {
          :defined => true,
          :argtype => argt,
          :rettype => RubyType.new(nil, info[3], "Return type of #{info[1]}")
        }
      elsif minfo[:defined] then
        raise "#{info[1]} is already defined in #{info[3]}"

      else
        # already Call but defined(forward call)
        argt = minfo[:argtype]
        1.upto(numarg) do |n|
          argt[n - 1].add_same_value local_vars[-n][:type]
          local_vars[-n][:type].add_same_type argt[n - 1]
        end

        minfo[:defined] = true
      end
    end

    oldrescode = @rescode
    @rescode = lambda {|b, context|
      context = oldrescode.call(b, context)

      # Make structure corrsponding struct of stack frame
      frst = make_frame_struct(context.local_vars)
      frstp = Type.pointer(frst)
      @frame_struct[code] = frstp
      curframe = b.alloca(frst, 1)
      context.current_frame = curframe

      if context.array_alloca_size then
        context.array_alloca_area = b.alloca(VALUE, context.array_alloca_size)
      end

      if ncnt = context.loop_cnt_alloca_size then
        ncnt.times do |i|
          area =  b.alloca(Type::Int32Ty, 1)
          context.loop_cnt_alloca_area.push area
        end
      end

      # Generate pointer to variable access
      context.local_vars.each_with_index {|vars, n|
        lv = b.struct_gep(curframe, n)
        vars[:area] = lv
      }

      # Copy argument in reg. to allocated area
      unless arg = context.inline_args then
        arg = context.builder.arguments
      end
      lvars = context.local_vars
      1.upto(numarg) do |n|
        b.store(arg[n - 1], lvars[-n][:area])
      end

      blkpoff = numarg
      # Store self
      if info[0] or code.header['type'] != :method then
        b.store(arg[numarg], lvars[2][:area])
        blkpoff = blkpoff + 1
      end

      # Store parent frame as argument
      if arg[blkpoff] then
        b.store(arg[blkpoff], lvars[0][:area])
        b.store(arg[blkpoff + 1], lvars[1][:area])
      end

      context.instance_vars_local.each do |key, cnt|
        # Instance variable cache is illigal for undefined instance variable.
        # Method "initialize" appear undefined instance variable, so in 
        # "initailze" instance variable cache is off.
        if cnt > 0 and 
           OPTION[:cache_instance_variable] and 
           info[1] != :initialize then

          # define inline cache area
          oldindex = add_global_variable("old_index", VALUE, -1.llvm)
          ftype = Type.function(P_VALUE, [VALUE, VALUE, P_VALUE])
          func = context.builder.get_or_insert_function_raw('llvm_ivar_ptr', ftype)
          ivid = ((key.object_id << 1) / RVALUE_SIZE)
          slf = b.load(context.local_vars[2][:area])

          vptr = b.call(func, slf, ivid.llvm, oldindex)
          context.instance_vars_local_area[key] = vptr
        else
          context.instance_vars_local_area[key] = nil
        end
      end

      context
    }
  end
  
  def visit_block_end(code, ins, local_vars, ln, info)
    RubyType.resolve

    numarg = code.header['misc'][:arg_size]

    argtype = []
    1.upto(numarg) do |n|
      argtype[n - 1] = local_vars[-n][:type]
    end

    # Self
    # argtype.push local_vars[2][:type]
    if info[0] or code.header['type'] != :method then
      argtype.push RubyType.value(info[3])
    end
    
    if code.header['type'] == :block or @have_yield then
      # Block frame
      argtype.push local_vars[0][:type]

      # Block pointer
      argtype.push local_vars[1][:type]
    end

    rescode = @rescode
    have_yield = @have_yield
    array_alloca_size = @array_alloca_size
    loop_cnt_alloca_size = @loop_cnt_alloca_size
    instance_vars_local = @instance_vars_local

    rett2 = nil
    if info[1] then
      rett2 = MethodDefinition::RubyMethod[info[1]][info[0]][:rettype]
    end

    if rett2 == nil # or rett2.type == nil then
      rett2 = RubyType.value(info[3], "nil", NilClass)
    end

    b = nil
    inlineargs = nil
    @generated_define_func[info[0]] ||= {}
    @generated_define_func[info[0]][info[1]] = lambda {|iargs|
      inlineargs = iargs
      if OPTION[:func_signature] then
        # write function prototype
        print "#{info[0]}##{info[1]} :("
        print argtype.map {|e|
          e.inspect2
        }.join(', ')
        print ") -> #{rett2.inspect2}\n"
        print "-- local variable --\n"
        print local_vars.map {|e|
          if e then
            type = e[:type]
            if type then
              "#{type.name} : #{type.inspect2} \n"
            else
              "#{type.name} : nil \n"
            end
          end
        }.join
        print "---\n"
      end

      if info[1] then
        pppp "define #{info[1]}"
        pppp @expstack
      
        1.upto(numarg) do |n|
          if argtype[n - 1].type == nil then
#            raise "Argument type is ambious #{local_vars[-n][:name]} of #{info[1]} in #{info[3]}"
            argtype[n - 1].type = PrimitiveType.new(VALUE, nil)
          end
        end

        blkpoff = numarg
        if info[0] or code.header['type'] != :method then
          if argtype[numarg].type == nil then
#            raise "Argument type is ambious self #{info[1]} in #{info[3]}"
            argtype[numarg].type = PrimitiveType.new(VALUE, nil)
          end
          blkpoff = blkpoff + 1
        end

        if code.header['type'] == :block or have_yield then
          if argtype[blkpoff].type == nil then
#            raise "Argument type is ambious parsnt frame #{info[1]} in #{info[3]}"
            argtype[blkpoff].type = PrimitiveType.new(VALUE, nil)
          end
          if argtype[blkpoff + 1].type == nil then
#            raise "Block function pointer is ambious parsnt frame #{info[1]} in #{info[3]}"
            argtype[blkpoff + 1].type = PrimitiveType.new(VALUE, nil)
          end

        end

        is_mkstub = true
        if code.header['type'] == :block or 
           have_yield or 
           info[0] == :YARV2LLVM then
          is_mkstub = false
        end
      else
        argtype = []
        is_mkstub = false
      end

      if inlineargs then
        b = inlineargs[0]
      else
        b = @builder.define_function(info[0], info[1].to_s, 
                                     rett2, argtype, is_mkstub)
      end
    }

    @generated_code[info[0]] ||= {}
    @generated_code[info[0]][info[1]] = lambda {
      context = Context.new(local_vars, @builder)
      context.array_alloca_size = array_alloca_size
      context.loop_cnt_alloca_size = loop_cnt_alloca_size
      context.instance_vars_local = instance_vars_local
      context.instance_vars_local_area = {}
      context.block_value[nil] = [RubyType.value(info[3]), 4.llvm]
      context.builder.select_func(b)

      if inlineargs then
        context.inline_args = inlineargs[1]
      else
        context.inline_args = nil
      end
      pppp "ret type #{rett2.type}"
      pppp "end"

      context = rescode.call(b, context)
      context.rc
    }

#    @expstack = []
    @rescode = lambda {|b, context| context}
  end
  
  def visit_local_block_start(code, ins, local_vars, ln, info)
    oldrescode = @rescode
    live =  @is_live
    if live == nil and info[1] == nil then
      live = true
    end

    @is_live = nil
    @jump_from[ln] ||= []
    @jump_from[ln].push @prev_label
    valexp = nil
    if live and @expstack.size > 0 then
      valexp = @expstack.pop
    end

    @rescode = lambda {|b, context|
      context = oldrescode.call(b, context)
      blk = get_or_create_block(ln, b, context)

      if live and context.is_live then
        if valexp then
          bval = [valexp[0], valexp[1].call(b, context).rc]
          context.block_value[context.curln] = bval
        end
        b.br(blk)
      end
      context.is_live = true

      context.curln = ln
      RubyType.clear_content
      b.set_insert_point(blk)
      context
    }

    if valexp then
      n = 1
      v2 = nil
      commer_label = @jump_from[ln]

      # value of block is stored in @expstack
      clsize = commer_label.size 
      while n < clsize do
        if v2 = @expstack.pop then
          valexp[0].add_same_value(v2[0])
          v2[0].add_same_value(valexp[0])
        end
        n += 1
      end

      rc = nil
      oldrescode2 = @rescode
      @rescode = lambda {|b, context|
        context = oldrescode2.call(b, context)
        if ln then
          # foobar It is ad-hoc
          if commer_label[0] == nil then
            commer_label.shift
          end
          
          if commer_label.size > 0 and 
             context.block_value[commer_label[0]] then
            phitype = RubyType.new(nil)
            commer_label.uniq.reverse.each do |lab|
              bval = context.block_value[lab]
              if bval then
                bval[0].add_same_type phitype
              else
                newtype = RubyType.value(info[3], "block value for #{lab}")
                context.block_value[lab] = []
                context.block_value[lab][0] = newtype
                context.block_value[lab][1] = 4.llvm
                newtype.add_same_type phitype
              end
            end
            RubyType.resolve
            rc = b.phi(phitype.type.llvm)
            commer_label.uniq.reverse.each do |lab|
              if context.blocks[lab] then
                rc.add_incoming(context.block_value[lab][1], 
                                context.blocks[lab])
              end
            end
          end
          
          context.rc = rc
        end
        context
      }

      @expstack.push [valexp[0],
                      lambda {|b, context|
                        if rc then
                          context.rc = rc
                        else
                          context.rc = 4.llvm
                        end
                        context
                      }]
    end
  end
  
  def visit_local_block_end(code, ins, local_vars, ln, info)
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
  
  def visit_default(code, ins, local_vars, ln, info)
    pppp "Unprocessed instruction #{ins}"
  end

  def visit_number(code, ins, local_vars, ln, info)
  end

  def visit_getlocal(code, ins, local_vars, ln, info)
    voff = ins[1]
    if code.header['type'] == :block then
      acode = code
      slev = 0
      while acode.header['type'] == :block
        acode = acode.parent
        slev = slev + 1
      end
      get_from_parent(voff, slev, acode, ln, info)
    else
      get_from_local(voff, local_vars, ln, info)
    end
  end
  
  def visit_setlocal(code, ins, local_vars, ln, info)
    voff = ins[1]
    src = @expstack.pop

    if code.header['type'] == :block then
      acode = code
      slev = 0
      while acode.header['type'] == :block
        acode = acode.parent
        slev = slev + 1
      end
      store_to_parent(voff, slev, src, acode, ln, info)

    else
      store_to_local(voff, src, local_vars, ln, info)
    end
  end

  # getspecial
  # setspecial

  def visit_getdynamic(code, ins, local_vars, ln, info)
    slev = ins[2]
    voff = ins[1]
    if slev == 0 then
      get_from_local(voff, local_vars, ln, info)
    else
      acode = code
      slev.times { acode = acode.parent}
      get_from_parent(voff, slev, acode, ln, info)
    end
  end

  def visit_setdynamic(code, ins, local_vars, ln, info)
    slev = ins[2]
    voff = ins[1]
    src = @expstack.pop
    if slev == 0 then
      store_to_local(voff, src, local_vars, ln, info)
    else
      acode = code
      slev.times { acode = acode.parent}
      store_to_parent(voff, slev, src, acode, ln, info)
    end
  end

  def visit_getinstancevariable(code, ins, local_vars, ln, info)
    ivname = ins[1]
    @instance_vars_local[ivname] ||= 0
    @instance_vars_local[ivname] += 1
    type = @instance_var_tab[info[0]][ivname][:type]
    unless type
      type = RubyType.new(nil, info[3], "#{info[0]}##{ivname}")
      @instance_var_tab[info[0]][ivname][:type] = type
    end
    @expstack.push [type,
      lambda {|b, context|
        if vptr = context.instance_vars_local_area[ivname] then
          val = b.load(vptr)
          if type.type then
            context.rc = type.type.from_value(val, b, context)
          else
            print "Unkonwn type of instance variable in #{info[3]}\n"
            context.rc = val
          end
        else
          ftype = Type.function(VALUE, [VALUE, VALUE])
          func = context.builder.external_function('rb_ivar_get', ftype)
          ivid = ((ivname.object_id << 1) / RVALUE_SIZE)
          slf = b.load(context.local_vars[2][:area])
          val = b.call(func, slf, ivid.llvm)
          context.rc = type.type.from_value(val, b, context)
        end
        context
      }]
  end

  def visit_setinstancevariable(code, ins, local_vars, ln, info)
    ivname = ins[1]
    @instance_vars_local[ivname] ||= 0
    @instance_vars_local[ivname] += 1
    dsttype = @instance_var_tab[info[0]][ivname][:type]
    unless dsttype
      dsttype = RubyType.new(nil, info[3], "#{info[0]}##{ivname}")
      @instance_var_tab[info[0]][ivname][:type] = dsttype
    end
    src = @expstack.pop
    srctype = src[0]
    srcvalue = src[1]
    
    srctype.add_same_value(dsttype)
    dsttype.add_same_value(srctype)

    oldrescode = @rescode
    @rescode = lambda {|b, context|
      pppp "Setinstancevariable start"
      context = oldrescode.call(b, context)
      context = srcvalue.call(b, context)
      srcval = context.rc
      srcval2 = srctype.type.to_value(srcval, b, context)

      RubyType.resolve
      dsttype.type = dsttype.type.dup_type
      dsttype.type.content = srcval

      context.rc = srcval
      if vptr = context.instance_vars_local_area[ivname] then
        b.store(srcval2, vptr)

      else
        ftype = Type.function(VALUE, [VALUE, VALUE, VALUE])
        func = context.builder.external_function('rb_ivar_set', ftype)
        ivid = ((ivname.object_id << 1) / RVALUE_SIZE)
        slf = b.load(context.local_vars[2][:area])
      
        b.call(func, slf, ivid.llvm, srcval2)
      end
      context.org = dsttype.name
      pppp "Setinstancevariable end"
      context
    }
  end

  # getclassvariable
  # setclassvariable

  def visit_getconstant(code, ins, local_vars, ln, info)
    klass = @expstack.pop
    val = nil
    cname = ins[1]
    const_path = cname.to_s
    kn = klass[0].name
    unless kn == "nil" or kn == nil then
      const_path = "#{kn}::#{const_path}"
    end

    val = nil
    if eval("defined? #{const_path}", @binding) then
      val = eval(const_path, @binding)
    elsif info[0] then
      const_path = "#{info[0]}::#{const_path}"
      if eval("defined? #{const_path}", @binding) then
        val = eval(const_path, @binding)
      end
    end

    type = @constant_type_tab[@binding][cname]
    if type == nil then
      type = RubyType.typeof(val, info[3], cname)
      @constant_type_tab[@binding][cname] = type
    end
    @expstack.push [type,
      lambda {|b, context|
        if val then
          context.rc = val.llvm
        else
          # slf = b.load(context.local_vars[2][:area])
          #slf = eval("self", @binding).llvm
          slf = Object.llvm

          coid = ((cname.object_id << 1) / RVALUE_SIZE)

          ftype = Type.function(VALUE, [VALUE, VALUE])
          func = context.builder.external_function('rb_const_get', ftype)
          context.rc = b.call(func, slf, coid.llvm)
        end

        context.org = ins[1]
        context
      }]
  end

  def visit_setconstant(code, ins, local_vars, ln, info)
    val = @expstack.pop
    const_path = ins[1].to_s
    if info[0] then
      const_path = "#{info[0]}::#{const_path}"
    end
    if val[0].type.constant then
      eval("#{const_path} = #{val[0].type.constant}", @binding)
    else
      @constant_type_tab[@binding][ins[1]] = val[0]
      oldrescode = @rescode
      cname = ins[1]
      @rescode = lambda {|b, context|
        context = oldrescode.call(b, context)
        # slf = b.load(context.local_vars[2][:area])
        #slf = eval("self", @binding).llvm
        slf = Object.llvm

        context = val[1].call(b, context)
        srcval = context.rc
        srcval2 = val[0].type.to_value(srcval, b, context)
        
        ftype = Type.function(VALUE, [VALUE, VALUE, VALUE])
        func = context.builder.external_function('rb_const_set', ftype)
        
        coid = ((cname.object_id << 1) / RVALUE_SIZE)

        b.call(func, slf, coid.llvm, srcval2)
        context.rc = srcval2
        context.org = cname
        
        context
      }
    end
  end

  def visit_getglobal(code, ins, local_vars, ln, info)
    glname = ins[1]
    type = @global_var_tab[glname][:type]
    unless type 
      type = RubyType.new(nil, info[3], "$#{glname}")
      @global_var_tab[glname][:type] = type
      areap = add_global_variable("glarea_ptr", VALUE, 4.llvm)
      @global_var_tab[glname][:area] = areap
    end
    areap = @global_var_tab[glname][:area]
    @expstack.push [type,
      lambda {|b, context|
        ftype = Type.function(VALUE, [VALUE])
        area = nil
        if  info[1] == :initialize or
            info[1] == :trace_func or 
            info[1] == nil then
          func1 = context.builder.external_function('rb_global_entry', ftype)
          glid = ((glname.object_id << 1) / RVALUE_SIZE)
          area = b.call(func1, glid.llvm)
        else
          area = b.load(areap)
        end
          
        func1 = context.builder.external_function('rb_gvar_get', ftype)
        val = b.call(func1, area)
        context.rc = type.type.from_value(val, b, context)
        context
      }]
  end

  def visit_setglobal(code, ins, local_vars, ln, info)
    glname = ins[1]
    
    dsttype = @global_var_tab[glname][:type]
    unless dsttype
      dsttype = RubyType.new(nil, info[3], "$#{glname}")
      @global_var_tab[glname][:type] = dsttype
      areap = add_global_variable("glarea_ptr", VALUE, 4.llvm)
      @global_var_tab[glname][:area] = areap
    end
    areap = @global_var_tab[glname][:area]

    src = @expstack.pop
    srctype = src[0]
    srcvalue = src[1]
    
    srctype.add_same_value(dsttype)
    dsttype.add_same_value(srctype)

    oldrescode = @rescode
    @rescode = lambda {|b, context|
      context = oldrescode.call(b, context)
      context = srcvalue.call(b, context)
      srcval = context.rc
      srcval2 = srctype.type.to_value(srcval, b, context)

      dsttype.type = dsttype.type.dup_type
      dsttype.type.content = srcval

      area = nil
      if info[1] == :initialize or 
         info[1] == :trace_func or 
         info[1] == nil then
        ftype = Type.function(VALUE, [VALUE])
        func1 = context.builder.external_function('rb_global_entry', ftype)
        glid = ((glname.object_id << 1) / RVALUE_SIZE)
        area = b.call(func1, glid.llvm)
      else
        area = b.load(areap)
      end

      ftype2 = Type.function(VALUE, [VALUE, VALUE])
      func2 = context.builder.external_function('rb_gvar_set', ftype2)

      b.call(func2, area, srcval2)
      context.org = dsttype.name

      context
    }
  end

  def visit_putnil(code, ins, local_vars, ln, info)
    @expstack.push [RubyType.value(info[3], "nil", NilClass), 
      lambda {|b, context| 
        context.rc = 4.llvm   # 4 means nil
        context
      }]
  end

  def visit_putself(code, ins, local_vars, ln, info)
    type = local_vars[2][:type]
    #type = RubyType.new(nil, info[3], "self")
    @expstack.push [type,
      lambda  {|b, context|
        if type.type then
          slf = b.load(context.local_vars[2][:area])
          context.org = "self"
          context.rc = type.type.from_value(slf, b, context)
        end
        context}]
  end

  def visit_putobject(code, ins, local_vars, ln, info)
    p1 = ins[1]
    type = RubyType.typeof(p1, info[3], p1)
    orgtype = type.type
    type.type.constant = p1
    @expstack.push [type, 
      lambda {|b, context| 
        pppp p1
        case type.type.llvm
        when Type::Int1Ty
          context.rc = type.type.from_value(p1.llvm, b, context)
        when VALUE
          context.rc = orgtype.to_value(p1.llvm, b, context)
        when P_CHAR
          context.rc = p1.llvm(b)
        else
          context.rc = p1.llvm
        end
        context.org = p1
        context
      }]
  end

  # putspecialobject

  def visit_putiseq(code, ins, local_vars, ln, info)
  end

  def visit_putstring(code, ins, local_vars, ln, info)
    p1 = ins[1]
    @expstack.push [RubyType.typeof(p1, info[3], p1), 
      lambda {|b, context| 
        context.rc = p1.llvm(b)
        context.org = p1
        context
      }]
  end

  def visit_concatstrings(code, ins, local_vars, ln, info)
    nele = ins[1]
    rett = RubyType.value(info[3], "return type tostring", String)
    eles = []
    nele.times do
      eles.push @expstack.pop
    end
    eles.reverse!
    @expstack.push [rett, lambda {|b, context|
      ftype = Type.function(VALUE, [P_CHAR, Type::Int32Ty])
      funcnewstr = context.builder.external_function('rb_str_new', ftype)
      istr = b.int_to_ptr(0.llvm, P_CHAR)
      rs = b.call(funcnewstr, istr, 0.llvm)
      ftype = Type.function(VALUE, [VALUE, VALUE])
      funcapp = context.builder.external_function('rb_str_append', ftype)
      eles.each do |ele|
        context = ele[1].call(b, context)
        ev = ele[0].type.to_value(context.rc, b, context)
        b.call(funcapp, rs, ev)
      end
      context.rc = rs
      context
    }]
  end

  def visit_tostring(code, ins, local_vars, ln, info)
    v = @expstack.pop
    rett = RubyType.value(info[3], "return type tostring", String)
    @expstack.push [rett, lambda {|b, context|
      context = v[1].call(b, context)
      obj = context.rc
      objval = v[0].type.to_value(obj, b, context)
      ftype = Type.function(VALUE, [VALUE])
      fname = "rb_obj_as_string"
      func = context.builder.external_function(fname, ftype)
      rc = b.call(func, objval) 
      context.rc = rc
      context
    }]
  end

  # toregexp

  def visit_newarray(code, ins, local_vars, ln, info)
    nele = ins[1]
    inits = []
    etype = nil
    atype = RubyType.array(info[3])
    nele.times {|n|
      v = @expstack.pop
      inits.push v
      if etype and etype.llvm != v[0].type.llvm then
        mess = "Element of array must be same type in yarv2llvm #{etype.inspect2} expected but #{v[0].inspect2} in #{info[3]}"
        if OPTION[:strict_type_inference] then
          raise mess
        else
          print mess, "\n"
        end
      end
      etype = v[0].type
      atype.type.element_type.conflicted_types[etype.llvm] = etype
    }
    arraycurlevel = @expstack.size
    if nele != 0 then
      if @array_alloca_size == nil or @array_alloca_size < nele + arraycurlevel then
        @array_alloca_size = nele + arraycurlevel
      end
    end
    
    inits.reverse!
    if inits[0] then
      atype.type.element_type.add_same_type(inits[0][0])
      inits[0][0].add_same_type(atype.type.element_type)
    end
    @expstack.push [atype,
      lambda {|b, context|
        if nele == 0 then
          ftype = Type.function(VALUE, [])
          func = context.builder.external_function('rb_ary_new', ftype)
          rc = b.call(func)
          context.rc = rc
          pppp "newarray END"
        else
          initsize = inits.size
          initarea = context.array_alloca_area
          initarea2 =  b.gep(initarea, arraycurlevel.llvm)
          inits.each_with_index do |e, n|
            context = e[1].call(b, context)
            sptr = b.gep(initarea2, n.llvm)
            if e[0].type then
              rcvalue = e[0].type.to_value(context.rc, b, context)
            else
              rcvalue = context.rc
            end
            b.store(rcvalue, sptr)
          end

          ftype = Type.function(VALUE, [Type::Int32Ty, P_VALUE])
          func = context.builder.external_function('rb_ary_new4', ftype)
          rc = b.call(func, initsize.llvm, initarea2)
          context.rc = rc
        end
        context
      }]
  end

  def visit_duparray(code, ins, local_vars, ln, info)
    srcarr = ins[1]
    srcarr.each do |e|
      if e.is_a?(String) then
        visit_putstring(code, [:putstring, e], local_vars, ln, info)
      else
        visit_putobject(code, [:putobject, e], local_vars, ln, info)
      end
    end

    visit_newarray(code, [:newarray, srcarr.size], local_vars, ln, info)
  end

  # expandarray
  # concatarray
  # splatarray
  # checkincludearray
  # newhash

  def visit_newrange(code, ins, local_vars, ln, info)
    lst = @expstack.pop
    fst = @expstack.pop
    flg = ins[1]
    rtype = RubyType.range(fst[0], lst[0], flg, info[3])
    @expstack.push [rtype,
       lambda {|b, context|
         case fst[0].type.llvm
         when Type::Int32Ty
           valint = fst[1].call(b, context).rc
           rtype.type.first.type.constant = valint

         when VALUE
           val = fst[1].call(b, context).rc
           valint = b.ashr(val, 1.llvm)
           rtype.type.first.type.constant = valint

         else
           raise "Not support type #{fst[0].type.inspect2} in Range"
         end

         case lst[0].type.llvm
         when Type::Int32Ty
           valint = lst[1].call(b, context).rc
           valint = b.add(valint, 1.llvm) if flg == 0
           rtype.type.last.type.constant = valint

         when VALUE
           val = lst[1].call(b, context).rc
           valint = b.ashr(val, 1.llvm)
           valint = b.add(valint, 1.llvm) if flg == 0
           rtype.type.last.type.constant = valint

         else
           raise "Not support type #{lst[0].type.inspect2} in Range"
         end

         context.rc = 4.llvm
         context
    }]
  end

  def visit_pop(code, ins, local_vars, ln, info)
    exp = @expstack.pop
    oldrescode = @rescode
    @rescode = lambda {|b, context|
      context = oldrescode.call(b, context)
      if exp then
=begin
        RubyType.resolve
        if exp[0].type == nil then
          exp[0].type = PrimitiveType.new(VALUE, nil)
          exp[0].clear_same
        end
=end
        context.rc = exp[1].call(b, context)
      end

      context
    }
  end
  
  def visit_dup(code, ins, local_vars, ln, info)
    s1 = @expstack.pop
    stacktop_value = nil
    @expstack.push [s1[0],
      lambda {|b, context|
        context.rc = stacktop_value
        context
      }]

    @expstack.push [s1[0],
      lambda {|b, context|
        context = s1[1].call(b, context)
        stacktop_value = context.rc
        context
      }]
  end

  def visit_dupn(code, ins, local_vars, ln, info)
    s = []
    n = ins[1]
    n.times do |i|
      s.push @expstack.pop
    end
    s.reverse!
    
    stacktop_value = []
    n.times do |i|
      @expstack.push [s[i][0],
        lambda {|b, context|
          context.rc = stacktop_value[i]
          context
        }]
    end
      
    n.times do |i|
      @expstack.push [s[i][0],
        lambda {|b, context|
          context = s[i][1].call(b, context)
          stacktop_value[i] = context.rc
          context
        }]
    end
  end

  # swap
  # reput
  # topn
  # setn
  # adjuststack
  
  # defined

  def visit_trace(code, ins, local_vars, ln, info)
    curtrace_no = @trace_no
    evt = ins[1]
    TRACE_INFO[curtrace_no] = [evt, info.clone]
    @trace_no += 1
    if info[0] == :YARV2LLVM or info[1] == nil then
      return
    end
    if minfo = MethodDefinition::RubyMethod[:trace_func][:YARV2LLVM] then
      argt = minfo[:argtype]
      istdetect = false
      if argt[0].type == nil then
        RubyType.fixnum.add_same_type argt[0]
        istdetect = true
      end
      if argt[1].type == nil then
        RubyType.fixnum.add_same_type argt[1]
        istdetect = true
      end
      if istdetect then
        RubyType.resolve
      end
    end
        
    oldrescode = @rescode
    lno = info[3]
    @rescode = lambda {|b, context|
      context = oldrescode.call(b, context)
      if minfo = MethodDefinition::RubyMethod[:trace_func][:YARV2LLVM] then
        argt = minfo[:argtype]
        istdetect = false
        if argt[0].type == nil then
          RubyType.fixnum.add_same_type argt[0]
          istdetect = true
        end
        if argt[1].type == nil then
          RubyType.fixnum.add_same_type argt[1]
          istdetect = true
        end
        if istdetect then
          RubyType.resolve
        end
        if info[0] == nil then
          slf = 4.llvm
        else
          slf = b.load(context.local_vars[2][:area])
        end
        func = minfo[:func]
        EXPORTED_OBJECT[lno] = true
        b.call(func, evt.llvm, curtrace_no.llvm, slf)
      end
      context
    }
  end

  def visit_defineclass(code, ins, local_vars, ln, info)
    action = lambda {|code, info|
      if MethodDefinition::RubyMethod[info[1]][info[0]] == nil then
        MethodDefinition::RubyMethod[info[1]][info[0]] = true
      end
    }
    sup = @expstack.pop
    supklass = sup[0].klass
    if supklass == :NilClass then
      sup = nil
    end
    code.traverse_code(info.clone, action)
    case ins[3]
    when 0
      if sup then
        eval("class #{ins[1]}<#{supklass};end", @binding)
      else
        eval("class #{ins[1]};end", @binding)
      end
    when 2
      eval("module #{ins[1]};end", @binding)
    end
  end
  
  include SendUtil
  def visit_send(code, ins, local_vars, ln, info)
    mname = ins[1]
    nargs = ins[2]
    isfunc = ((ins[4] & 8) != 0) # true: function type, false: method type
    args = []
    0.upto(nargs - 1) do |n|
      args[n] = @expstack.pop
    end
    
    receiver = nil
    if !isfunc then
      receiver = @expstack.pop
    else
      @expstack.pop
    end

    RubyType.resolve
    recklass = receiver ? receiver[0].klass : nil

    minfo, func = gen_method_select(recklass, info[0], mname)
    if minfo then
      pppp "RubyMethod called #{mname.inspect}"

      para = gen_arg_eval(args, receiver, ins, local_vars, info, minfo, mname)
      @expstack.push [minfo[:rettype],
        lambda {|b, context|
          recklass = receiver ? receiver[0].klass : nil
          minfo, func = gen_method_select(recklass, info[0], mname)
          if func then
            gen_call(func, para ,b, context)
          else
            raise "Undefined method \"#{mname}\" in #{info[3]}"
          end
        }]
      return
    end

    funcinfo = nil
    if MethodDefinition::CMethod[recklass] then
      funcinfo = MethodDefinition::CMethod[recklass][mname]
    end

    if funcinfo then
      rettype = funcinfo[:rettype]
      argtype = funcinfo[:argtype]
      unless rettype.is_a?(RubyType) then
        rettype = RubyType.new(rettype, 
                               info[3], 
                               "return type of #{mname} in forward call")
        argtype = funcinfo[:argtype].map {|ts| RubyType.new(ts, info[3])}
      end
      cname = funcinfo[:cname]
      send_self = funcinfo[:send_self]
      argnum = ins[2]
      if send_self then
        argnum += 1
      end
      
      if argtype.size == argnum then
        argtype2 = argtype.map {|tc| tc.type.llvm}
        ftype = Type.function(rettype.type.llvm, argtype2)
        func = @builder.external_function(cname, ftype)

        if send_self then
          para = gen_arg_eval(args, receiver, ins, local_vars, info, nil, mname)
          slf = para.pop
          para.unshift slf
        else
          para = gen_arg_eval(args, nil, ins, local_vars, info, nil, mname)
        end

        args.each_with_index do |pe, n|
          pe[0].add_same_type argtype[n]
          argtype[n].add_same_value pe[0]
        end
          
        @expstack.push [rettype,
          lambda {|b, context|
            gen_call(func, para, b, context)
          }
        ]
        return
      end
    end

#    if MethodDefinition::RubyMethod[mname][recklass] == nil then
#        MethodDefinition::RubyMethod[mname][nil] == nil then
      if funcinfo = MethodDefinition::SystemMethod[mname] then
        return
      end

      funcinfo = get_inline_function(recklass, info[0], mname)
      if funcinfo and 
        para = {:info => info, 
                :ins => ins,
                :code => code,
                :args => args, 
                :receiver => receiver, 
                :local => local_vars}
        instance_exec(para, &funcinfo[:inline_proc])
        return
      end
#    end

    # Undefined method, it may be forward call.
    pppp "RubyMethod forward called #{mname.inspect}"

    # minfo doesn't exist yet
    para = gen_arg_eval(args, receiver, ins, local_vars, info, nil, mname)

    rett = RubyType.new(nil, info[3], "Return forward type of #{mname}")
    @expstack.push [rett,
      lambda {|b, context|
        recklass = receiver ? receiver[0].klass : nil
        minfo, func = gen_method_select(recklass, info[0], mname)
        if minfo == nil then
          # Retry for generate dynamic dispatch.
          minfo, func = gen_method_select(recklass, nil, mname)
        end

        nargt = minfo[:argtype]
        nargt.each_with_index do |ele, n|
          para[n][0].add_same_type ele
          ele.add_same_type ele
        end
        rett.add_same_type minfo[:rettype]
        minfo[:rettype].add_same_type rett
        RubyType.resolve

        if func then
          gen_call(func, para, b, context)
        else
          p recklass
          raise "Undefined method \"#{mname}\" in #{info[3]}"
        end
      }]

    dst = MethodDefinition::RubyMethod[mname]
    klass = [recklass, info[0], nil].find {|k|
      dst[k]
    }
    dst[klass] = {
      :defined => false,
      :argtype => para.map {|ele| ele[0]},
      :rettype => rett
    }

    return
  end

  # invokesuper

  def visit_invokeblock(code, ins, local_vars, ln, info)
    @have_yield = true

    narg = ins[1]
    arg = []
    narg.times do |n|
      arg.push @expstack.pop
    end
    arg.reverse!
    slf = local_vars[2]
    arg.push [slf[:type], lambda {|b, context|
        context.rc = b.load(slf[:area])
        context}]
    frame = local_vars[0]
    arg.push [frame[:type], lambda {|b, context|
        context.rc = b.load(frame[:area])
        context}]
    bptr = local_vars[1]
    arg.push [bptr[:type], lambda {|b, context|
        context.rc = b.load(bptr[:area])
        context}]
    
    rett = RubyType.new(nil, info[3], "Return type of yield")
    @expstack.push [rett, lambda {|b, context|
        fptr_i = b.load(context.local_vars[1][:area])
        RubyType.resolve
        # type error check
        arg.map {|e|
          if e[0].type == nil then
            # raise "Return type is ambious #{e[0].name} in #{e[0].line_no}"
            e[0].type = PrimitiveType.new(VALUE, nil)
          end
        }
        if rett.type == nil then
          # raise "Return type is ambious #{rett.name} in #{rett.line_no}"
          rett.type = PrimitiveType.new(VALUE, nil)
        end

        ftype = Type.function(rett.type.llvm, 
                              arg.map {|e| e[0].type.llvm})
        fptype = Type.pointer(ftype)
        fptr = b.int_to_ptr(fptr_i, fptype)
        argval = []
        arg.each do |e|
          context = e[1].call(b, context)
          argval.push context.rc
        end
        context.rc = b.call(fptr, *argval)
        context
      }]
  end

  def visit_leave(code, ins, local_vars, ln, info)
    retexp = nil
    retexp = @expstack.pop
    if retexp == nil then
      rett2 = RubyType.value(info[3], "Return type of #{info[1]}")
      retexp = [rett2, lambda {|b, context|
                  context.rc = 4.llvm
                  context
                }]
    end

    if info[1] then
      rett2 = MethodDefinition::RubyMethod[info[1]][info[0]][:rettype]
#      rett2.add_same_type retexp[0]
      retexp[0].add_same_type rett2
      RubyType.resolve
    end

    oldrescode = @rescode
    @rescode = lambda {|b, context|

      context = oldrescode.call(b, context)
      if context.inline_args then
        context = retexp[1].call(b, context)
      else
        if rett2.type == nil then
          # raise "Return type is ambious #{info[1]} in #{info[3]}"
          rett2.type = PrimitiveType.new(VALUE, nil)
        end

        context = retexp[1].call(b, context)
        context.is_live = false
        rc = context.rc
        if rc then
          b.return(rc)
        else
          b.return(4.llvm)  # nil
        end
      end

      context
    }
  end

  # finish

  # throw

  def visit_jump(code, ins, local_vars, ln, info)
    lab = ins[1]
    fmlab = nil
    oldrescode = @rescode
    valexp = nil
    if @expstack.size > 0 then
      valexp = @expstack.pop
    end
    bval = nil
    @is_live = false
    @jump_from[lab] ||= []
    @jump_from[lab].push ln
    @rescode = lambda {|b, context|
      oldrescode.call(b, context)
      jblock = get_or_create_block(lab, b, context)
      fmlab = context.curln
      if valexp then
        bval = [valexp[0], valexp[1].call(b, context).rc]
        context.block_value[fmlab] = bval
      end
      b.br(jblock)

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

  def visit_branchif(code, ins, local_vars, ln, info)
    cond = @expstack.pop
    oldrescode = @rescode
    lab = ins[1]
    valexp = nil
    if @expstack.size > 0 then
      valexp = @expstack.pop
    end
    bval = nil
#    @is_live = false
    iflab = nil
    @jump_from[lab] ||= []
    @jump_from[lab].push (ln.to_s + "_1").to_sym
    @rescode = lambda {|b, context|
      oldrescode.call(b, context)
      tblock = get_or_create_block(lab, b, context)
      iflab = context.curln

      eblock = context.builder.create_block
      context.curln = (context.curln.to_s + "_1").to_sym
      context.blocks[context.curln] = eblock
      if valexp then
        bval = [valexp[0], valexp[1].call(b, context).rc]
        context.block_value[iflab] = bval
      end
      condval = cond[1].call(b, context).rc
      if cond[0].type.llvm == VALUE then
        condval = cond[0].type.from_value(condval, b, context)
      end
      b.cond_br(condval, tblock, eblock)
      RubyType.clear_content
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

  def visit_branchunless(code, ins, local_vars, ln, info)
    cond = @expstack.pop
    oldrescode = @rescode
    lab = ins[1]
    valexp = nil
    if @expstack.size > 0 then
      valexp = @expstack.pop
    end
    bval = nil
#    @is_live = false
    iflab = nil
    @jump_from[lab] ||= []
    @jump_from[lab].push (ln.to_s + "_1").to_sym
    @rescode = lambda {|b, context|
      oldrescode.call(b, context)
      eblock = context.builder.create_block
      iflab = context.curln
      context.curln = (context.curln.to_s + "_1").to_sym
      context.blocks[context.curln] = eblock
      tblock = get_or_create_block(lab, b, context)
      if valexp then
        context = valexp[1].call(b, context)
        bval = [valexp[0], context.rc]
        context.block_value[iflab] = bval
      end

      condval = cond[1].call(b, context).rc
      if cond[0].type.llvm == VALUE then
        condval = cond[0].type.from_value(condval, b, context)
      end
      b.cond_br(condval, eblock, tblock)
      RubyType.clear_content
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

  # getinlinecache
  # onceinlinecache
  # setinlinecache
  # opt_case_dispatch
  # opt_checkenv
  
  def visit_opt_plus(code, ins, local_vars, ln, info)
    s = []
    s[1] = @expstack.pop
    s[0] = @expstack.pop
    check_same_type_2arg_static(s[0], s[1])
    rettype = s[0][0].dup_type
    
    @expstack.push [rettype,
      lambda {|b, context|
        sval = []
        sval, context, constp = gen_common_opt_2arg(b, context, s[0], s[1])
        if constp then
          rc = sval[0] + sval[1]
          rettype.type.constant = rc
          context.rc = rc.llvm
          return context
        end

        case s[0][0].type.llvm
        when Type::DoubleTy, Type::Int32Ty
          context.rc = b.add(sval[0], sval[1])
          
        when VALUE
          if s[0][0].conflicted_types.size == 1 and
             s[1][0].conflicted_types.size == 1 then
            conf1 = s[0][0].conflicted_types.to_a[0]
            at1 = conf1[1]
            al1 = at1.llvm
            conf2 = s[1][0].conflicted_types.to_a[0]
            at2 = conf2[1]
            al2 = at2.llvm
            if al1 == al2 then
              case al1
              when Type::DoubleTy, Type::Int32Ty
                s1ne = at1.from_value(sval[0], b, context)
                s2ne = at2.from_value(sval[1], b, context)
                addne = b.add(s1ne, s2ne)
                context.rc = at1.to_value(addne, b, context)
              end
            else
              # Generic + dispatch
            end
          else
            # Generic + dispatch
          end
        end

        context
      }
    ]
  end
  
  def visit_opt_minus(code, ins, local_vars, ln, info)
    s = []
    s[1] = @expstack.pop
    s[0] = @expstack.pop
    check_same_type_2arg_static(s[0], s[1])
    
    @expstack.push [s[0][0].dup_type,
      lambda {|b, context|
        sval = []
        sval, context, constp = gen_common_opt_2arg(b, context, s[0], s[1])
        if constp then
          rc = sval[0] - sval[1]
          rettype.type.constant = rc
          context.rc = rc.llvm
          return context
        end

        case s[0][0].type.llvm
        when Type::DoubleTy, Type::Int32Ty
          context.rc = b.sub(sval[0], sval[1])
          
        when VALUE
          if s[0][0].conflicted_types.size == 1 and
             s[1][0].conflicted_types.size == 1 then
            conf1 = s[0][0].conflicted_types.to_a[0]
            at1 = conf1[1]
            al1 = at1.llvm
            conf2 = s[1][0].conflicted_types.to_a[0]
            at2 = conf2[1]
            al2 = at2.llvm
            if al1 == al2 then
              case al1
              when Type::DoubleTy, Type::Int32Ty
                s1ne = at1.from_value(sval[0], b, context)
                s2ne = at2.from_value(sval[1], b, context)
                subne = b.sub(s1ne, s2ne)
                context.rc = at1.to_value(subne, b, context)
              end
            else
              # Generic + dispatch
            end
          else
            # Generic + dispatch
          end
        end

        context
      }
    ]
  end
  
  def visit_opt_mult(code, ins, local_vars, ln, info)
    s2 = @expstack.pop
    s1 = @expstack.pop
    check_same_type_2arg_static(s1, s2)
    
    @expstack.push [s1[0].dup_type,
      lambda {|b, context|
        sval = []
        sval, context, constp = gen_common_opt_2arg(b, context, s1, s2)
        if constp then
          rc = sval[0] * sval[1]
          rettype.type.constant = rc
          context.rc = rc.llvm
          return context
        end

        case s1[0].type.llvm
        when Type::DoubleTy, Type::Int32Ty
          context.rc = b.mul(sval[0], sval[1])
          
        when VALUE
          s1int = b.ashr(sval[0], 1.llvm)
          s2int = b.ashr(sval[1], 1.llvm)
          mulint = b.mul(sval[0], sval[1])
          x = b.shl(mulint, 1.llvm)
          context.rc = b.or(FIXNUM_FLAG, x)

        else
          raise "Unsupported type #{s1[0].inspect2}"
        end
        context
      }
    ]
  end
  
  def visit_opt_div(code, ins, local_vars, ln, info)
    s2 = @expstack.pop
    s1 = @expstack.pop
    check_same_type_2arg_static(s1, s2)
    
    @expstack.push [s1[0].dup_type,
      lambda {|b, context|
        sval = []
        sval, context, constp = gen_common_opt_2arg(b, context, s1, s2)
        if constp then
          rc = sval[0] / sval[1]
          rettype.type.constant = rc
          context.rc = rc.llvm
          return context
        end

        case s1[0].type.llvm
        when Type::DoubleTy
          context.rc = b.fdiv(sval[0], sval[1])

        when Type::Int32Ty
          context.rc = b.sdiv(sval[0], sval[1])

        else
          raise "Unsupported type #{s1[0].inspect2}"
        end
        context
      }
    ]
  end

  def visit_opt_mod(code, ins, local_vars, ln, info)
    s2 = @expstack.pop
    s1 = @expstack.pop
    rettype = nil
    if s1[0].type.llvm == P_CHAR then
      rettype = RubyType.value(info[3], "return type of %")
    else
      check_same_type_2arg_static(s1, s2)
      rettype = s1[0].dup_type
    end

    @expstack.push [rettype,
      lambda {|b, context|
        sval = []
        sval, context, constp = gen_common_opt_2arg(b, context, s1, s2)
        if constp then
          rc = sval[0] % sval[1]
          rettype.type.constant = rc
          context.rc = rc.llvm
          return context
        end

        # It is right only s1 and s2 is possitive.
        # It must generate more complex code when s1 and s2 are negative.
        case s1[0].type.llvm
        when Type::DoubleTy
          context.rc = b.frem(sval[0], sval[1])

        when Type::Int32Ty
          context.rc = b.srem(sval[0], sval[1])

        when P_CHAR
          s1value = s1[0].type.to_value(sval[0], b, context)
          s2value = s2[0].type.to_value(sval[1], b, context)
          ftype = Type.function(VALUE, [VALUE, VALUE])
          func = context.builder.external_function('rb_str_format_m', ftype)
          context.rc = b.call(func, s1value, s2value)

        else
          raise "Unsupported type #{s1[0].inspect2}"
        end

        context
      }]
  end

  def visit_opt_eq(code, ins, local_vars, ln, info)
    s2 = @expstack.pop
    s1 = @expstack.pop
    check_same_type_2arg_static(s1, s2)
    
    @expstack.push [RubyType.new(nil), 
      lambda {|b, context|
        sval = []
        sval, context, constp = gen_common_opt_2arg(b, context, s1, s2)
        if constp then
          rc = (sval[0] == sval[1])
          rettype.type.constant = rc
          if rc then
            context.rc = b.bit_cast(1.llvm, Type::Int1Ty)
          else
            context.rc = b.bit_cast(0.llvm, Type::Int1Ty)
          end
          return context
        end

        case s1[0].type.llvm
        when Type::DoubleTy
          context.rc = b.fcmp_ueq(sval[0], sval[1])

        when Type::Int32Ty
          context.rc = b.icmp_eq(sval[0], sval[1])

        when VALUE
          vv1 = s1[0].type.to_value(sval[1], b, context)
          vv2 = s2[0].type.to_value(sval[0], b, context)
          context.rc = b.icmp_eq(vv1, vv2)
        end
        context
      }
    ]
  end

  def visit_opt_neq(code, ins, local_vars, ln, info)
    s2 = @expstack.pop
    s1 = @expstack.pop
    check_same_type_2arg_static(s1, s2)
    
    @expstack.push [RubyType.new(nil), 
      lambda {|b, context|
        sval = []
        sval, context, constp = gen_common_opt_2arg(b, context, s1, s2)
        if constp then
          rc = (sval[0] != sval[1])
          rettype.type.constant = rc
          if rc then
            context.rc = b.bit_cast(1.llvm, Type::Int1Ty)
          else
            context.rc = b.bit_cast(0.llvm, Type::Int1Ty)
          end
          return context
        end

        case s1[0].type.llvm
        when Type::DoubleTy
          context.rc = b.fcmp_une(sval[0], sval[1])

        when Type::Int32Ty
          context.rc = b.icmp_ne(sval[0], sval[1])

        when VALUE
          vv1 = s1[0].type.to_value(sval[1], b, context)
          vv2 = s2[0].type.to_value(sval[0], b, context)
          context.rc = b.icmp_ne(vv1, vv2)
        end
        context
      }
    ]
  end

  def visit_opt_lt(code, ins, local_vars, ln, info)
    s2 = @expstack.pop
    s1 = @expstack.pop
    check_same_type_2arg_static(s1, s2)
    
    @expstack.push [RubyType.new(nil), 
      lambda {|b, context|
        sval = []
        sval, context, constp = gen_common_opt_2arg(b, context, s1, s2)
        if constp then
          rc = (sval[0] < sval[1])
          rettype.type.constant = rc
          if rc then
            context.rc = b.bit_cast(1.llvm, Type::Int1Ty)
          else
            context.rc = b.bit_cast(0.llvm, Type::Int1Ty)
          end
          return context
        end

        case s1[0].type.llvm
        when Type::DoubleTy
          context.rc = b.fcmp_ult(sval[0], sval[1])

        when Type::Int32Ty
          context.rc = b.icmp_slt(sval[0], sval[1])
          
        else
          raise "Unsupported type #{s1[0].inspect2}"
        end
        context
      }
    ]
  end

  def visit_opt_le(code, ins, local_vars, ln, info)
    s2 = @expstack.pop
    s1 = @expstack.pop
    check_same_type_2arg_static(s1, s2)
    
    @expstack.push [RubyType.new(nil), 
      lambda {|b, context|
        sval = []
        sval, context, constp = gen_common_opt_2arg(b, context, s1, s2)
        if constp then
          rc = (sval[0] <= sval[1])
          rettype.type.constant = rc
          if rc then
            context.rc = b.bit_cast(1.llvm, Type::Int1Ty)
          else
            context.rc = b.bit_cast(0.llvm, Type::Int1Ty)
          end
          return context
        end

        case s1[0].type.llvm
        when Type::DoubleTy
          context.rc = b.fcmp_ule(sval[0], sval[1])

        when Type::Int32Ty
          context.rc = b.icmp_sle(sval[0], sval[1])

        else
          raise "Unsupported type #{s1[0].inspect2}"
        end
        context
      }
    ]
  end
  
  def visit_opt_gt(code, ins, local_vars, ln, info)
    s2 = @expstack.pop
    s1 = @expstack.pop
    check_same_type_2arg_static(s1, s2)
    
    @expstack.push [RubyType.new(nil), 
      lambda {|b, context|
        sval = []
        sval, context, constp = gen_common_opt_2arg(b, context, s1, s2)
        if constp then
          rc = (sval[0] > sval[1])
          rettype.type.constant = rc
          if rc then
            context.rc = b.bit_cast(1.llvm, Type::Int1Ty)
          else
            context.rc = b.bit_cast(0.llvm, Type::Int1Ty)
          end
          return context
        end

        case s1[0].type.llvm
        when Type::DoubleTy
          context.rc = b.fcmp_ugt(sval[0], sval[1])

        when Type::Int32Ty
          context.rc = b.icmp_sgt(sval[0], sval[1])

        else
          raise "Unsupported type #{s1[0].inspect2}"
        end
        context
      }
    ]
  end

  def visit_opt_ge(code, ins, local_vars, ln, info)
    s2 = @expstack.pop
    s1 = @expstack.pop
    check_same_type_2arg_static(s1, s2)
    
    @expstack.push [RubyType.new(nil), 
      lambda {|b, context|
        sval = []
        sval, context, constp = gen_common_opt_2arg(b, context, s1, s2)
        if constp then
          rc = (sval[0] >= sval[1])
          rettype.type.constant = rc
          if rc then
            context.rc = b.bit_cast(1.llvm, Type::Int1Ty)
          else
            context.rc = b.bit_cast(0.llvm, Type::Int1Ty)
          end
          return context
        end

        case s1[0].type.llvm
        when Type::DoubleTy
          context.rc = b.fcmp_uge(sval[0], sval[1])

        when Type::Int32Ty
          context.rc = b.icmp_sge(sval[0], sval[1])

        else
          raise "Unsupported type #{s1[0].inspect2}"
        end
        context
      }
    ]
  end


  def visit_opt_ltlt(code, ins, local_vars, ln, info)
    s2 = @expstack.pop
    s1 = @expstack.pop
    rettype = s1[0].dup_type
    if s1[0].type and s1[0].type.klass != Array then
      check_same_type_2arg_static(s1, s2)
    end

    @expstack.push [rettype,
      lambda {|b, context|
        sval = []
        sval, context, constp = gen_common_opt_2arg(b, context, s1, s2)
        if constp then
          rc = sval[0] << sval[1]
          rettype.type.constant = rc
          context.rc = rc.llvm
          return context
        end

        # It is right only s1 and s2 is possitive.
        # It must generate more complex code when s1 and s2 are negative.
        case s1[0].type.klass
        when :Fixnum
          context.rc = b.shl(sval[0], sval[1])

        when :Array
          raise "Unsupported type #{s1[0].inspect2}"

        else
          raise "Unsupported type #{s1[0].inspect2}"
        end

        context
      }]
  end

  def visit_opt_aref(code, ins, local_vars, ln, info)
    idx = @expstack.pop
    arr = @expstack.pop
    if arr[0].type.is_a?(ArrayType) then
      fix = RubyType.fixnum(info[3])
      idx[0].add_same_type(fix)
      fix.add_same_value(idx[0])
    end

    RubyType.resolve
    # AbstrubctContainorType is type which have [] and []= as method.
    if arr[0].type == nil then
      arr[0].type = AbstructContainerType.new(nil)
    end

    @expstack.push [arr[0].type.element_type, 
      lambda {|b, context|
        pppp "aref start"
        case arr[0].klass
        when :Array
          context = idx[1].call(b, context)
          idxp = context.rc
          if OPTION[:array_range_check] then
            context = arr[1].call(b, context)
            arrp = context.rc
            ftype = Type.function(VALUE, [VALUE, Type::Int32Ty])
            func = context.builder.external_function('rb_ary_entry', ftype)
            av = b.call(func, arrp, idxp)
            arrelet = arr[0].type.element_type.type
            if arrelet then
              context.rc = arrelet.from_value(av, b, context)
            else
              context.rc = av
            end
            context

          else
            if cont = arr[0].type.element_content[idxp] then
              # Content of array corresponding index exists
              context.rc = cont
            else
              if arr[0].type.ptr then
                # Array body in register
                abdy = arr[0].type.ptr
              else
                context = arr[1].call(b, context)
                arrp = context.rc
                arrp = b.int_to_ptr(arrp, P_RARRAY)
                abdyp = b.struct_gep(arrp, 3)
                abdy = b.load(abdyp)
                arr[0].type.ptr = abdy
              end
              avp = b.gep(abdy, idxp)
              av = b.load(avp)
              arrelet = arr[0].type.element_type.type
              context.rc = arrelet.from_value(av, b, context)
              arr[0].type.element_content[idxp] = av
            end
            context
          end

        when :Hash
          context = idx[1].call(b, context)
          idxp = context.rc
          idxval = idx[0].type.to_value(idxp, b, context)
          context = arr[1].call(b, context)
          arrp = context.rc
          ftype = Type.function(VALUE, [VALUE, VALUE])
          func = context.builder.external_function('rb_hash_aref', ftype)
          av = b.call(func, arrp, idxval)
          arrelet = arr[0].type.element_type.type
          context.rc = arrelet.from_value(av, b, context)
          
          context

        when :String
          raise "Not impremented String::[] in #{info[3]}"
          context

        when :Struct
          context = idx[1].call(b, context)
          idxp = context.rc
          idxval = idx[0].type.to_value(idxp, b, context)
          context = arr[1].call(b, context)
          arrp = context.rc
          ftype = Type.function(VALUE, [VALUE, VALUE])
          func = context.builder.external_function('rb_struct_aref', ftype)
          av = b.call(func, arrp, idxval)
          arrelet = arr[0].type.element_type.type
          context.rc = arrelet.from_value(av, b, context)
          
          context
        else
          # Todo: Hash table?
          raise "Not impremented #{arr[0].inspect2} in #{info[3]}"
          context
        end
      }
    ]
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

  private

  def get_from_local(voff, local_vars, ln, info)
    # voff + 2 means yarv2llvm uses extra 4 arguments block 
    # frame, block ptr, self, exception status
    # Maybe in Ruby 1.9 extra arguments is 2. So offset is shifted.
    voff = voff + 2
    type = local_vars[voff][:type]
    @expstack.push [type,
      lambda {|b, context|
        unless context.rc = type.type.content
          context.rc = b.load(context.local_vars[voff][:area])
        end
        context.org = local_vars[voff][:name]
        context
      }]
  end

  def store_to_local(voff, src, local_vars, ln, info)
    voff = voff + 2
    dsttype = local_vars[voff][:type]
    srctype = src[0]
    srcvalue = src[1]

    srctype.add_same_value(dsttype)
    dsttype.add_same_value(srctype)

    oldrescode = @rescode
    @rescode = lambda {|b, context|
      pppp "Setlocal start"
      context = oldrescode.call(b, context)
      context = srcvalue.call(b, context)
      srcval = context.rc
      lvar = context.local_vars[voff]

      dsttype.type = dsttype.type.dup_type
      dsttype.type.content = srcval

      context.rc = b.store(srcval, lvar[:area])
      context.org = lvar[:name]
      pppp "Setlocal end"
      context
    }
  end

  def get_from_parent(voff, slev, acode, ln, info)
    voff = voff + 2
    alocal = @locals[acode][voff]
    type = alocal[:type]

    @expstack.push [type,
      lambda {|b, context|
        unless context.rc = type.type.content
          if context.inline_args then
            varp = alocal[:area]
          else
            fcp = context.local_vars[0][:area]
            slev.times do
              fcp = b.load(fcp)
              fcp = b.bit_cast(fcp, Type.pointer(P_CHAR))
            end
            frstruct = @frame_struct[acode]

            fi = b.ptr_to_int(fcp, MACHINE_WORD)
            frame = b.int_to_ptr(fi, frstruct)
            varp = b.struct_gep(frame, voff)
          end

          context.rc = b.load(varp)
        end

        context.org = alocal[:name]
        context
      }]
  end

  def store_to_parent(voff, slev, src, acode, ln, info)
    voff = voff + 2
    alocal = @locals[acode][voff]
    dsttype = alocal[:type]

    srctype = src[0]
    srcvalue = src[1]

    srctype.add_same_value(dsttype)
    dsttype.add_same_value(srctype)

    oldrescode = @rescode
    @rescode = lambda {|b, context|
      context = oldrescode.call(b, context)
      context = srcvalue.call(b, context)
      rval = context.rc

      dsttype.type = dsttype.type.dup_type
      dsttype.type.content = rval

      if context.inline_args then
        lvar = alocal[:area]
      else
        fcp = context.local_vars[0][:area]
        (slev).times do
          fcp = b.bit_cast(fcp, Type.pointer(P_CHAR))
          fcp = b.load(fcp)
        end
        frstruct = @frame_struct[acode]
        fi = b.ptr_to_int(fcp, MACHINE_WORD)
        frame = b.int_to_ptr(fi, frstruct)
        lvar = b.struct_gep(frame, voff)
      end

      context.rc = b.store(rval, lvar)
      context.org = alocal[:name]
      context
    }
  end

  def gen_init_ruby(builder)
    ftype = Type.function(VALUE, [])
    b = builder.define_function_raw('init_ruby', ftype)
    initfunc = builder.current_function
    member = []
    initarg = []

    @global_var_tab.each do |name, info|
      ftype1 = Type.function(VALUE, [VALUE])
      func1 = builder.external_function('rb_global_entry', ftype1)
      glid = ((name.object_id << 1) / RVALUE_SIZE)
      area = b.call(func1, glid.llvm)
      dst = info[:area] 
      b.store(area, dst)
    end

    @generated_define_func.each do |klass, defperklass|
      if klass then
        klassval = Object.const_get(klass, true)
      else
        klassval = 4
      end
      defperklass[nil].call([b, [klassval.llvm]])
    end
    klasses = @generated_code.keys.reverse
    klasses.each do |klass|
      defperklass = @generated_code[klass]
      defperklass[nil].call
    end

    b.return(4.llvm)
    initfunc
  end

  def gen_define_ruby(builder)
    ftype = Type.function(VALUE, [])
    fname = "define_ruby"
    b = builder.define_function_raw(fname, ftype)

#=begin
    ftype = Type.function(Type::VoidTy, [VALUE, P_CHAR, VALUE, Type::Int32Ty])
    funcm = builder.external_function('rb_define_method', ftype)
    ftype = Type.function(Type::VoidTy, [P_CHAR, VALUE, Type::Int32Ty])
    funcg = builder.external_function('rb_define_global_function', ftype)
    MethodDefinition::RubyMethodStub.each do |name, klasstab|
      klasstab.each do |rec, m|
        unless m[:outputp]
          nameptr = name.llvm(b)
          stubval = b.ptr_to_int(m[:stub], VALUE)
          if rec then
            recptr = Object.const_get(rec)
            b.call(funcm, recptr.llvm, nameptr, stubval, 
                   (m[:argt].size - 1).llvm)
          else
            b.call(funcg, nameptr, stubval, (m[:argt].size - 1).llvm)
          end
          m[:outputp] = true
        end
      end
    end
#=end

    b.return(4.llvm)
    builder.current_function
  end
end

def compile_file(fn, opt = {}, preload = [], bind = TOPLEVEL_BINDING)
  is = RubyVM::InstructionSequence.compile( File.read(fn), fn, 1, 
            {  :peephole_optimization    => true,
               :inline_const_cache       => false,
               :specialized_instruction  => true,}).to_a
  compcommon(is, opt, preload, bind)
end

def compile(str, opt = {}, preload = [], bind = TOPLEVEL_BINDING)
  line = 1
  file = "<llvm2ruby>"
  if /^(.+?):(\d+)(?::in `(.*)')?/ =~ caller[0] then
    file = $1
    line = $2.to_i + 1
    method = $3
  end
  is = RubyVM::InstructionSequence.compile( str, file, line, 
            {  :peephole_optimization    => true,
               :inline_const_cache       => false,
               :specialized_instruction  => true,}).to_a
  compcommon(is, opt, preload, bind)
end

def compcommon(is, opt, preload, bind)
  DEF_OPTION.each do |key, value|
    OPTION[key] = value
  end
  opt.each do |key, value|
    OPTION[key] = value
  end
  iseq = VMLib::InstSeqTree.new(nil, is)
  if OPTION[:dump_yarv] then
    p iseq.to_a
  end
  YarvTranslator.new(iseq, bind, preload).run
=begin
  MethodDefinition::RubyMethodStub.each do |key, m|
    name = key
    n = 0
    args = ""
    args2 = ""

    m[:argt].pop
    if m[:argt] != [] then
      args = m[:argt].map {|x|  n += 1; "p" + n.to_s}.join(',')
      args2 = ', ' + args
    end
    args2 = ", self" + args2 

#    df = "def #{key}(#{args});LLVM::ExecutionEngine.run_function(YARV2LLVM::MethodDefinition::RubyMethodStub['#{key}'][:stub]#{args2});end" 
    df = "def #{key}(#{args});LLVM::ExecutionEngine.run_function(YARV2LLVM::MethodDefinition::RubyMethodStub['#{key}'][:stub]#{args2});end" 
    eval df, bind
  end
=end
end

module_function :compile_file
module_function :compile
module_function :compcommon
end

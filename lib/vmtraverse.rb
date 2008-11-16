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
  end

  attr_accessor :local_vars
  attr_accessor :rc
  attr_accessor :org
  attr_accessor :blocks
  attr_accessor :curln
  attr_accessor :block_value
  attr_accessor :current_frame
  attr :builder
  attr :frame_struct
end

class YarvVisitor
  def initialize(iseq)
    @iseq = iseq
  end

  def run
    @iseq.traverse_code([nil, nil, nil, nil]) do |code, info|
      ccde = code
      while ccde.header['type'] == :block
        info[1] = (info[1].to_s + '_blk_' + ccde.info[2].to_s).to_sym
        ccde = ccde.parent
      end

      local = []
      visit_block_start(code, nil, local, nil, info)
      curln = nil
      code.lblock_list.each do |ln|
        visit_local_block_start(code, ln, local, ln, info)

        curln = ln
        code.lblock[ln].each do |ins|
          if ins.is_a?(Fixnum) then
            info[3] = ins
          else
            opname = ins[0].to_s
            send(("visit_" + opname).to_sym, code, ins, local, curln, info)
          end

          case ins[0]
          when :branchif, :branchunless, :jump
            curln = (curln.to_s + "_1").to_sym
          end
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
  include LLVM
  include RubyHelpers
  include LLVMUtil

  @@builder = LLVMBuilder.new
  def initialize(iseq, bind)
    super(iseq)

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
    
  end

  def run
    super
    @generated_code.each do |fname, gen|
      gen.call
    end

    if OPTION[:optimize] then
      @builder.optimize
    end
    if OPTION[:disasm] then
      @builder.disassemble
    end
    if OPTION[:write_bc] then
      @builder.write_bc(OPTION[:write_bc])
    end
  end
  
  def visit_block_start(code, ins, local, ln, info)
    @have_yield = false
    ([nil, nil, nil] + code.header['locals'].reverse).each_with_index do |n, i|
      local[i] = {
        :name => n, 
        :type => RubyType.new(nil, info[3], n),
        :area => nil}
    end
    local[0][:type] = RubyType.new(P_CHAR, info[3], "Parent frame")
    local[1][:type] = RubyType.new(MACHINE_WORD, info[3], "Pointer to block")
    local[2][:type] = RubyType.new(nil, info[3], "self")

    # Argument parametor |...| is omitted.
    an = code.header['locals'].size + 1
    dn = code.header['misc'][:local_size]
    if an < dn then
      (dn - an).times do |i|
        local.push({
          :type => RubyType.new(nil),
          :area => nil
        })
      end
    end

    @locals[code] = local
    numarg = code.header['misc'][:arg_size]

    # regist function to RubyCMthhod for recursive call
    if info[1] then
      minfo = MethodDefinition::RubyMethod[info[1]]
      if minfo == nil then
        argt = []
        1.upto(numarg) do |n|
          argt[n - 1] = local[-n][:type]
        end
        #        argt.push local[2][:type]
        # self
        argt.push RubyType.value
        if code.header['type'] == :block or @have_yield then
          argt.push local[0][:type]
          argt.push local[1][:type]
        end
        MethodDefinition::RubyMethod[info[1]]= {
          :defined => true,
          :argtype => argt,
          :rettype => RubyType.new(nil, info[3], "return type of #{info[1]}")
        }
      elsif minfo[:defined] then
        raise "#{info[1]} is already defined in #{info[3]}"

      else
        # already Call but defined(forward call)
        argt = minfo[:argtype]
        1.upto(numarg) do |n|
          argt[n - 1].add_same_type local[-n][:type]
          local[-n][:type].add_same_type argt[n - 1]
        end
        argt[numarg - 1].add_same_type local[-numarg][:type]
        local[-numarg][:type].add_same_type argt[numarg - 1]
        
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
      # Generate pointer to variable access
      context.local_vars.each_with_index {|vars, n|
        lv = b.struct_gep(curframe, n)
        vars[:area] = lv
      }

      # Copy argument in reg. to allocated area
      arg = context.builder.arguments
      lvars = context.local_vars
      1.upto(numarg) do |n|
        b.store(arg[n - 1], lvars[-n][:area])
      end

      # Store self
      b.store(arg[numarg], lvars[2][:area])

      # Store parent frame as argument
      if arg[numarg + 1] then
        b.store(arg[numarg + 1], lvars[0][:area])
        b.store(arg[numarg + 2], lvars[1][:area])
      end

      context
    }
  end
  
  def visit_block_end(code, ins, local, ln, info)
    RubyType.resolve

    numarg = code.header['misc'][:arg_size]

    argtype = []
    1.upto(numarg) do |n|
      argtype[n - 1] = local[-n][:type]
    end

    # Self
    # argtype.push local[2][:type]
    argtype.push RubyType.value
    
    if code.header['type'] == :block or @have_yield then
      # Block frame
      argtype.push local[0][:type]

      # Block pointer
      argtype.push local[1][:type]
    end

    if info[1] then
      if @expstack.last then
        retexp = @expstack.pop
      else
        retexp = [RubyType.value, lambda {|b, context|
            context.rc = 4.llvm
            context
          }]
      end
      rescode = @rescode
      rett2 = MethodDefinition::RubyMethod[info[1]][:rettype]
      rett2.add_same_type retexp[0]
      retexp[0].add_same_type rett2
      RubyType.resolve

=begin
    # write function prototype
    if info[1] then
      print "#{info[1]} :("
      print argtype.map {|e|
          e.inspect2
        }.join(', ')
      print ") -> #{retexp[0].inspect2}\n"
      p "foo"
    end
=end
      have_yield = @have_yield

      @generated_code[info[1]] = lambda {
        pppp "define #{info[1]}"
        pppp @expstack
      
        1.upto(numarg) do |n|
          if argtype[n - 1].type == nil then
            raise "Argument type is ambious #{local[-n][:name]} of #{info[1]} in #{info[3]}"
          end
        end

        if argtype[numarg].type == nil then
          raise "Argument type is ambious self #{info[1]} in #{info[3]}"
        end

        if code.header['type'] == :block or have_yield then
          if argtype[numarg + 1].type == nil then
            raise "Argument type is ambious parsnt frame #{info[1]} in #{info[3]}"
          end
          if argtype[numarg + 2].type == nil then
            raise "Block function pointer is ambious parsnt frame #{info[1]} in #{info[3]}"
          end

        end
        if retexp[0].type == nil then
          raise "Return type is ambious #{info[1]} in #{info[3]}"
        end

        is_mkstub = true
        if code.header['type'] == :block or have_yield then
          is_mkstub = false
        end

        b = @builder.define_function(info[1].to_s, 
                                   retexp[0], argtype, is_mkstub)
        context = Context.new(local, @builder)
        context = rescode.call(b, context)
        b.return(retexp[1].call(b, context).rc)

        pppp "ret type #{retexp[0].type}"
        pppp "end"
      }
    end

#    @expstack = []
    @rescode = lambda {|b, context| context}
  end
  
  def visit_local_block_start(code, ins, local, ln, info)
    oldrescode = @rescode
    live =  @is_live

    @is_live = nil
    if live and @expstack.size > 0 then
      valexp = @expstack.pop
    end
    
    @jump_from[ln] ||= []
    @jump_from[ln].push @prev_label
    @rescode = lambda {|b, context|
      context = oldrescode.call(b, context)
      blk = get_or_create_block(ln, b, context)
      if live then
        if valexp then
          bval = [valexp[0], valexp[1].call(b, context).rc]
          context.block_value[context.curln] = bval
        end
        b.br(blk)
      end
      context.curln = ln
      b.set_insert_point(blk)
      context
    }

    if valexp then
      n = 0
      v2 = nil
      commer_label = @jump_from[ln]
      while n < commer_label.size - 1 do
        if v2 = @expstack[@expstack.size - n - 1] then
          valexp[0].add_same_type(v2[0])
          v2[0].add_same_type(valexp[0])
        end
        n += 1
      end
      @expstack.pop
      @expstack.push [valexp[0],
        lambda {|b, context|
          if ln then
            # foobar It is ad-hoc
            if commer_label[0] == nil then
              commer_label.shift
            end
            rc = b.phi(context.block_value[commer_label[0]][0].type.llvm)
            
            commer_label.reverse.each do |lab|
              rc.add_incoming(context.block_value[lab][1], 
                              context.blocks[lab])
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
  
  def visit_default(code, ins, local, ln, info)
    pppp "Unprocessed instruction #{ins}"
  end

  def visit_getlocal(code, ins, local, ln, info)
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
      get_from_local(voff, local, ln, info)
    end
  end
  
  def visit_setlocal(code, ins, local, ln, info)
    voff = ins[1]
    src = @expstack.pop

    if code.header['type'] == :block then
      acode = code
      slev = 0
      while acode.header['type'] == :block
        acode = acode.parent
        slev = slev + 1
      end
      store_from_parent(voff, slev, src, acode, ln, info)

    else
      store_from_local(voff, src, local, ln, info)
    end
  end

  # getspecial
  # setspecial

  def visit_getdynamic(code, ins, local, ln, info)
    slev = ins[2]
    voff = ins[1]
    if slev == 0 then
      get_from_local(voff, local, ln, info)
    else
      acode = code
      slev.times { acode = acode.parent}
      get_from_parent(voff, slev, acode, ln, info)
    end
  end

  def visit_setdynamic(code, ins, local, ln, info)
    slev = ins[2]
    voff = ins[1]
    src = @expstack.pop
    if slev == 0 then
      store_from_local(voff, src, local, ln, info)
    else
      acode = code
      slev.times { acode = acode.parent}
      store_from_parent(voff, slev, src, acode, ln, info)
    end
  end

  # getinstancevariable
  # setinstancevariable
  # getclassvariable
  # setclassvariable

  def visit_getconstant(code, ins, local, ln, info)
    val = eval(ins[1].to_s, @binding)
    @expstack.push [RubyType.typeof(val, info[3], ins[1]),
      lambda {|b, context|
        context.rc = val.llvm
        context.org = ins[1]
        context
      }]
  end

  def visit_setconstant(code, ins, local, ln, info)
    val = @expstack.pop
    eval("#{ins[1].to_s} = #{val[0].name}", @binding)
  end

  # getglobal
  # setglobal

  def visit_putnil(code, ins, local, ln, info)
    # Nil is not support yet.
=begin
    @expstack.push [RubyType.value(info[3], "nil"), 
      lambda {|b, context| 
        context.rc = 4.llvm   # 4 means nil
        context
      }]
=end
  end

  def visit_putself(code, ins, local, ln, info)
    type = local[2][:type]
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

  def visit_putobject(code, ins, local, ln, info)
    p1 = ins[1]
    @expstack.push [RubyType.typeof(p1, info[3], p1), 
      lambda {|b, context| 
        pppp p1
        context.rc = p1.llvm 
        context.org = p1
        context
      }]
  end

  # putspecialobject
  # putiseq

  def visit_putstring(code, ins, local, ln, info)
    p1 = ins[1]
    @expstack.push [RubyType.typeof(p1, info[3], p1), 
      lambda {|b, context| 
        context.rc = p1.llvm(b)
        context.org = p1
        context
      }]
  end

  # concatstrings
  # tostring
  # toregexp

  def visit_newarray(code, ins, local, ln, info)
    nele = ins[1]
    inits = []
    nele.times {|n|
      v = @expstack.pop
      inits.push v
    }
    inits.reverse!
    @expstack.push [RubyType.new(ArrayType.new(nil), info[3]),
      lambda {|b, context|
        if nele == 0 then
          ftype = Type.function(VALUE, [])
          func = context.builder.external_function('rb_ary_new', ftype)
          rc = b.call(func)
          context.rc = rc
          pppp "newarray END"
        else
          # TODO: eval inits and call rb_ary_new4
          raise "Initialized array not implemented in #{info[3]}"
        end
        context
      }]
  end
  
  # duparray
  # expandarray
  # concatarray
  # splatarray
  # checkincludearray
  # newhash
  # newrange

  def visit_pop(code, ins, local, ln, info)
    exp = @expstack.pop
    oldrescode = @rescode
    @rescode = lambda {|b, context|
      context = oldrescode.call(b, context)
      if exp then
        if exp[0].type == nil then
          exp[0].type = PrimitiveType.new(VALUE)
          exp[0].clear_same_type
        end
        context.rc = exp[1].call(b, context)
      end
      context
    }
  end
  
  def visit_dup(code, ins, local, ln, info)
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

  # dupn
  # swap
  # reput
  # topn
  # setn
  # adjuststack
  
  # defined
  # trace

  # defineclass
  
  include SendUtil
  def visit_send(code, ins, local, ln, info)
    mname = ins[1]
    
    if funcinfo = MethodDefinition::SystemMethod[mname] then
      funcinfo[:args].downto(1) do |n|
        @expstack.pop
      end
      return
    end

    if funcinfo = MethodDefinition::InlineMethod[mname] then
      @info = info
      instance_eval &funcinfo[:inline_proc]
      return
    end

    if funcinfo = MethodDefinition::CMethod[mname] then
      rettype = RubyType.new(funcinfo[:rettype], info[3], "return type of #{mname}")
      argtype = funcinfo[:argtype].map {|ts| RubyType.new(ts, info[3])}
      cname = funcinfo[:cname]
      
      if argtype.size == ins[2] then
        argtype2 = argtype.map {|tc| tc.type.llvm}
        ftype = Type.function(rettype.type.llvm, argtype2)
        func = @builder.external_function(cname, ftype)

        p = []
        0.upto(ins[2] - 1) do |n|
          p[n] = @expstack.pop
          p[n][0].add_same_type argtype[n]
          argtype[n].add_same_type p[n][0]
        end
          
        @expstack.push [rettype,
          lambda {|b, context|
            gen_call(func, p, b, context)
          }
        ]
        return
      end
    end

    if minfo = MethodDefinition::RubyMethod[mname] then
      pppp "RubyMethod called #{mname.inspect}"
      para = gen_arg_eval(@expstack, ins, local, info, minfo)
      @expstack.push [minfo[:rettype],
        lambda {|b, context|
          minfo = MethodDefinition::RubyMethod[mname]
          func = minfo[:func]
          gen_call(func, para ,b, context)
        }]
      return
    end

    # Undefined method, it may be forward call.
    pppp "RubyMethod forward called #{mname.inspect}"

    # minfo doesn't exist yet
    para = gen_arg_eval(@expstack, ins, local, info, nil)

    rett = RubyType.new(nil, info[3], "Return type of #{mname}")
    @expstack.push [rett,
      lambda {|b, context|
        argtype = para.map {|ele|
          if ele[0].type then
            ele[0].type.llvm
          else
            VALUE
          end
        }
        ftype = Type.function(rett.type.llvm, argtype)
        func = context.builder.get_or_insert_function(mname, ftype)
        args = []
        gen_call(func, para, b, context)

      }]

    MethodDefinition::RubyMethod[mname]= {
      :defined => false,
      :argtype => para.map {|ele| ele[0]},
      :rettype => rett
    }

    return
  end

  # invokesuper

  def visit_invokeblock(code, ins, local, ln, info)
    @have_yield = true

    narg = ins[1]
    arg = []
    narg.times do |n|
      arg.push @expstack.pop
    end
    arg.reverse!
    slf = local[2]
    arg.push [slf[:type], lambda {|b, context|
        context.rc = b.load(slf[:area])
        context}]
    frame = local[0]
    arg.push [frame[:type], lambda {|b, context|
        context.rc = b.load(frame[:area])
        context}]
    bptr = local[1]
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
            raise "Return type is ambious #{e[0].name} in #{e[0].line_no}"
          end
        }
        if rett.type == nil then
          raise "Return type is ambious #{rett.name} in #{rett.line_no}"
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

  # leave
  # finish

  # throw

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
    @jump_from[lab] ||= []
    @jump_from[lab].push ln
    @rescode = lambda {|b, context|
      oldrescode.call(b, context)
      jblock = get_or_create_block(lab, b, context)
      if valexp then
        bval = [valexp[0], valexp[1].call(b, context).rc]
        fmlab = context.curln
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
      b.cond_br(s1[1].call(b, context).rc, tblock, eblock)
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

  def visit_branchunless(code, ins, local, ln, info)
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
      b.cond_br(s1[1].call(b, context).rc, eblock, tblock)
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
        case s1[0].type.llvm
        when Type::DoubleTy
          context.rc = b.fdiv(s1val, s2val)
        when Type::Int32Ty
          context.rc = b.sdiv(s1val, s2val)
        end
        context
      }
    ]
  end

  def visit_opt_mod(code, ins, local, ln, info)
    s2 = @expstack.pop
    s1 = @expstack.pop
    check_same_type_2arg_static(s1, s2)
    
    @expstack.push [s1[0], 
      lambda {|b, context|
        s1val, s2val, context = gen_common_opt_2arg(b, context, s1, s2)
        # It is right only s1 and s2 is possitive.
        # It must generate more complex code when s1 and s2 are negative.
        case s1[0].type.llvm
        when Type::DoubleTy
          context.rc = b.frem(s1val, s2val)
        when Type::Int32Ty
          context.rc = b.srem(s1val, s2val)
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
        case s1[0].type.llvm
          when Type::DoubleTy
          context.rc = b.fcmp_ueq(s1val, s2val)

          when Type::Int32Ty
          context.rc = b.icmp_eq(s1val, s2val)
        end
        context
      }
    ]
  end

  def visit_opt_neq(code, ins, local, ln, info)
    s2 = @expstack.pop
    s1 = @expstack.pop
    check_same_type_2arg_static(s1, s2)
    
    @expstack.push [nil, 
      lambda {|b, context|
        s1val, s2val, context = gen_common_opt_2arg(b, context, s1, s2)
        case s1[0].type.llvm
          when Type::DoubleTy
          context.rc = b.fcmp_une(s1val, s2val)

          when Type::Int32Ty
          context.rc = b.icmp_ne(s1val, s2val)
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
        case s1[0].type.llvm
          when Type::DoubleTy
          context.rc = b.fcmp_ult(s1val, s2val)

          when Type::Int32Ty
          context.rc = b.icmp_slt(s1val, s2val)
        end
        context
      }
    ]
  end

  def visit_opt_le(code, ins, local, ln, info)
    s2 = @expstack.pop
    s1 = @expstack.pop
    check_same_type_2arg_static(s1, s2)
    
    @expstack.push [nil, 
      lambda {|b, context|
        s1val, s2val, context = gen_common_opt_2arg(b, context, s1, s2)
        case s1[0].type.llvm
          when Type::DoubleTy
          context.rc = b.fcmp_ule(s1val, s2val)

          when Type::Int32Ty
          context.rc = b.icmp_sle(s1val, s2val)
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
        case s1[0].type.llvm
          when Type::DoubleTy
          context.rc = b.fcmp_ugt(s1val, s2val)

          when Type::Int32Ty
          context.rc = b.icmp_sgt(s1val, s2val)
        end
        context
      }
    ]
  end

  def visit_opt_ge(code, ins, local, ln, info)
    s2 = @expstack.pop
    s1 = @expstack.pop
    check_same_type_2arg_static(s1, s2)
    
    @expstack.push [nil, 
      lambda {|b, context|
        s1val, s2val, context = gen_common_opt_2arg(b, context, s1, s2)
        case s1[0].type.llvm
          when Type::DoubleTy
          context.rc = b.fcmp_uge(s1val, s2val)

          when Type::Int32Ty
          context.rc = b.icmp_sge(s1val, s2val)
        end
        context
      }
    ]
  end


  # otp_ltlt

  def visit_opt_aref(code, ins, local, ln, info)
    idx = @expstack.pop
    arr = @expstack.pop
    if arr[0].type.is_a?(ArrayType) then
      fix = RubyType.fixnum(info[3])
      idx[0].add_same_type(fix)
      fix.add_same_type(idx[0])
      RubyType.resolve
    end

    RubyType.resolve
    # if index is integer then arr inference to Array type.
    if arr[0].type == nil and idx[0].type.llvm == Type::Int32Ty then
      arr[0].type = ArrayType.new(nil)
    end
    
    @expstack.push [arr[0].type.element_type, 
      lambda {|b, context|
        pppp "aref start"
        if arr[0].type.is_a?(ArrayType) then
          context = idx[1].call(b, context)
          idxp = context.rc
          context = arr[1].call(b, context)
          arrp = context.rc
          ftype = Type.function(VALUE, [VALUE, Type::Int32Ty])
          func = context.builder.external_function('rb_ary_entry', ftype)
          av = b.call(func, arrp, idxp)
          context.rc = arr[0].type.element_type.type.from_value(av, b, context)
          context
        else
          # Todo: Hash table?
          raise "Not impremented in #{info[3]}"
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

  def get_from_local(voff, local, ln, info)
    # voff + 1 means yarv2llvm uses extra 3 arguments block 
    # frame, block ptr, self
    # Maybe in Ruby 1.9 extra arguments is 2. So offset is shifted.
    voff = voff + 1
    type = local[voff][:type]
    @expstack.push [type,
      lambda {|b, context|
        context.rc = b.load(context.local_vars[voff][:area])
        context.org = local[voff][:name]
        context
      }]
  end

  def store_from_local(voff, src, local, ln, info)
    voff = voff + 1
    dsttype = local[voff][:type]
    srctype = src[0]
    srcvalue = src[1]

    srctype.add_same_type(dsttype)
    dsttype.add_same_type(srctype)

    oldrescode = @rescode
    @rescode = lambda {|b, context|
      pppp "Setlocal start"
      context = oldrescode.call(b, context)
      context = srcvalue.call(b, context)
      lvar = context.local_vars[voff]
      context.rc = b.store(context.rc, lvar[:area])
      context.org = lvar[:name]
      pppp "Setlocal end"
      context
    }
  end

  def get_from_parent(voff, slev, acode, ln, info)
    voff = voff + 1
    alocal = @locals[acode][voff]
    type = alocal[:type]

    @expstack.push [type,
      lambda {|b, context|
        fcp = context.local_vars[0][:area]
        slev.times do
          fcp = b.load(fcp)
        end
        frstruct = @frame_struct[acode]
        fi = b.ptr_to_int(fcp, MACHINE_WORD)
        frame = b.int_to_ptr(fi, frstruct)

        varp = b.struct_gep(frame, voff)
        context.rc = b.load(varp)
        context.org = alocal[:name]
        context
      }]
  end

  def store_from_parent(voff, slev, src, acode, ln, info)
    voff = voff + 1
    alocal = @locals[acode][voff]
    dsttype = alocal[:type]

    srctype = src[0]
    srcvalue = src[1]

    srctype.add_same_type(dsttype)
    dsttype.add_same_type(srctype)

    oldrescode = @rescode
    @rescode = lambda {|b, context|
      context = oldrescode.call(b, context)
      context = srcvalue.call(b, context)
      rval = context.rc

      fcp = context.local_vars[0][:area]
      (slev).times do
        fcp = b.load(fcp)
      end
      frstruct = @frame_struct[acode]
      fi = b.ptr_to_int(fcp, MACHINE_WORD)
      frame = b.int_to_ptr(fi, frstruct)
      
      lvar = b.struct_gep(frame, voff)
      context.rc = b.store(rval, lvar)
      context.org = alocal[:name]
      context
    }
  end
end

def compile_file(fn, opt = {}, bind = TOPLEVEL_BINDING)
  is = RubyVM::InstructionSequence.compile( File.read(fn), fn, 1, 
            {  :peephole_optimization    => true,
               :inline_const_cache       => false,
               :specialized_instruction  => true,}).to_a
  compcommon(is, opt, bind)
end

def compile(str, opt = {}, bind = TOPLEVEL_BINDING)
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
  compcommon(is, opt, bind)
end

def compcommon(is, opt, bind)
  opt.each do |key, value|
    OPTION[key] = value
  end
  iseq = VMLib::InstSeqTree.new(nil, is)
  if OPTION[:dump_yarv] then
    p iseq.to_a
  end
  YarvTranslator.new(iseq, bind).run
  MethodDefinition::RubyMethodStub.each do |key, m|
    name = key
    n = 0
    m[:argt].pop
    if m[:argt] == [] then
      args = ""
      args2 = ", self"
    else
      args = m[:argt].map {|x|  n += 1; "p" + n.to_s}.join(',')
      args2 = ', ' + args + ", self"
    end
#    df = "def #{key}(#{args});LLVM::ExecutionEngine.run_function(YARV2LLVM::MethodDefinition::RubyMethodStub['#{key}'][:stub]#{args2});end" 
    df = "def #{key}(#{args});LLVM::ExecutionEngine.run_function(YARV2LLVM::MethodDefinition::RubyMethodStub['#{key}'][:stub]#{args2});end" 
    eval df, bind
  end
end

module_function :compile_file
module_function :compile
module_function :compcommon
end

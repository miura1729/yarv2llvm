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
    @blocks_head = {}
    @blocks_tail = {}
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
    @inline_caller_context = nil
    @inline_caller_code = nil
    @is_live = true
    @exit_block = nil

    @user_defined = {}
  end

  attr_accessor :local_vars
  attr_accessor :rc
  attr_accessor :org
  attr_accessor :blocks_head
  attr_accessor :blocks_tail
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
  attr_accessor :inline_caller_context
  attr_accessor :inline_caller_code
  attr_accessor :is_live
  attr_accessor :exit_block

  attr :builder
  attr :frame_struct
  attr :user_defined
end

class YarvVisitor
  def initialize(iseq, preload)
    @iseqs = preload
    @iseqs.push iseq
  end

  def reset_state
    @jump_from = {}
    @prev_label = nil
    @is_live = nil
    @frame_struct = {}
    @locals = {}
    @have_yield = false
    @have_throw = false

    @array_alloca_size = nil
    @loop_cnt_alloca_size = 0
    @loop_cnt_current = 0
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
        isblkfst = true
        curln = nil
        code.lblock_list.each do |ln|
          
          curln = ln
          islocfst = true
          code.lblock[ln].each do |ins|
            if ins.is_a?(Fixnum) then
              curlinno = ins
              visit_number(code, ins, local_vars, curln, info)
            elsif ins == nil then
              # Do nothing
            else
              info[3] = "#{code.header['filename']}:#{curlinno}"

              if isblkfst then
                visit_block_start(code, nil, local_vars, nil, info)
                isblkfst = false
              end

              if islocfst then
                visit_local_block_start(code, ln, local_vars, ln, info)
                islocfst = false
              end

              opname = ins[0].to_s
              send(("visit_" + opname).to_sym, code, ins, local_vars, curln, info)
            end
            
            case ins[0]
            when :branchif, :branchunless
              curln = (curln.to_s + "_1").to_sym
            end
          end
          visit_local_block_end(code, ln, local_vars, curln, info)
        end
        
        visit_block_end(code, nil, local_vars, nil, info)
      }

      iseq.traverse_code([nil, nil, nil, nil], action)
      reset_state
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
    
    # local variable push stack as result
    @is_push_result_lblock = {}


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

    # True means current method include 
    # invokeblock instruction (yield statement)
    @have_yield = false

    # True means current method include 
    # throw instruction (break, next, continue, redo in block statement)
    @have_throw = false

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

    # Sequence Number of trace(for profile speed up)
    @trace_no = 0

    # Sequence numner of macro. Increment every macro call
    @macro_seq_no = 0

    # List of using method that is defined by Ruby system
    @using_method_list = Hash.new {|hash, klass|
      hash[klass] = {}
    }

    # Table of Context object
    @context_tab = {}

    # Table of inlined block code
    @inline_code_tab = {}

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
    gen_get_method_cfunc(@builder)
    gen_get_method_cfunc_singleton(@builder)
    
    if OPTION[:func_signature] then
      @instance_var_tab.each do |clname, ivtab|
        print "#{clname}\n"
        ivtab.each do |ivname, ivinfo|
          print "  #{ivname} #{ivinfo[:type].inspect2}\n"
        end
        print "\n"
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
          gen.call(nil)
        end
      end
    end

    if OPTION[:write_bc] then
      @builder.write_bc(OPTION[:write_bc])
    end

    if OPTION[:optimize] then
      initfunc = @builder.optimize
    end

    if OPTION[:post_optimize] then
      @builder.post_optimize
      initfunc = @builder.optimize
    end

    deffunc = gen_define_ruby(@builder)

    if OPTION[:disasm] then
      @builder.disassemble
    end

    unless OPTION[:compile_only]
      LLVM::ExecutionEngine.run_function(deffunc)
      LLVM::ExecutionEngine.run_function(initfunc)
    end
  end
  
  def compile_for_macro(str, lmac, para)
    lmac.each do |mname, val|
      MethodDefinition::InlineMethod[nil][mname] = {
        :inline_proc => lambda {|pa|
          @expstack.push [val[0],
            lambda {|b, context|
              context = val[1].call(b, context)
              context
            }]
        }
      }
    end

    is = RubyVM::InstructionSequence.compile(str, "macro", 0, 
            {  :peephole_optimization    => true,
               :inline_const_cache       => false,
               :specialized_instruction  => true,}).to_a
    is_body = is[11]
    is_body.unshift :label_start
    is_body.push :label_end
    is_body.each_with_index do |e, i|
      if e.is_a?(Symbol) then
        is_body[i] = "mac#{@macro_seq_no}_#{e.to_s}".to_sym
      else
        if e[0] == :leave then
          e[0] = :jump
          e[1] = :label_end
        end

        if e[0] == :jump or e[0] == :branchif or e[0] == :branchunless then
          e[1] = "mac#{@macro_seq_no}_#{e[1].to_s}".to_sym
        end
      end
    end
    iseq = VMLib::InstSeqTree.new(nil, is)
    para[:code].merge_other_iseq(iseq)
    iseq.clear_related_iseq
    @macro_seq_no += 1
    run_once(iseq, 0, para)
  end

  def run_once(iseq, curlinno, para)
    curlinno = 0
    isnotfst = false
    isstartcall = false
    local_vars = para[:local]

    action = lambda {|code, info|
      info[3] = "#{code.header['filename']}:#{curlinno}"
      
      if code.header['type'] == :block then
        info[1] = (info[1].to_s + '+blk+' + code.info[2].to_s).to_sym
      end
      
      if isnotfst then
        visit_block_start(code, nil, local_vars, nil, info)
        isstartcall = true
      end
      curln = nil
      code.lblock_list.each do |ln|
        if isnotfst then
          visit_local_block_start(code, ln, local_vars, ln, info)
        else
          isnotfst = true
        end
        
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
      if isstartcall then
        visit_block_end(code, nil, local_vars, nil, info)
      end
      
      visit_local_block_start(nil, nil, local_vars, "mac#{@macro_seq_no}_label_end2".to_sym, para[:info])
    }

    iseq.traverse_code(para[:info], action)
  end

  def visit_block_start(code, ins, local_vars, ln, info)
    @have_yield = false
    @have_throw = false

    @array_alloca_size = nil
    @loop_cnt_alloca_size = 0
    @loop_cnt_current = 0

    @instance_vars_local = {}

    minfo = nil
    if info[1] then
      minfo = MethodDefinition::RubyMethod[info[1]][info[0]]
      if minfo == nil then
        minfo = MethodDefinition::RubyMethod[info[1]][nil]
        if minfo then
          MethodDefinition::RubyMethod[info[1]][info[0]] = minfo
        end
      end
    end

    lbase = ([nil, nil, nil, nil] + code.header['locals'].reverse)
    lbase.each_with_index do |n, i|
      local_vars[i] = {
        :name => n, 
        :type => RubyType.new(nil, info[3], n),
        :area_type => RubyType.new(nil, info[3], "area of #{n}"),
        :area => nil}
    end
    local_vars[0][:type] = RubyType.new(P_CHAR, info[3], "Parent frame")
    local_vars[1][:type] = RubyType.new(Type::Int32Ty, info[3], 
                                        "Pointer to block")
    sty = nil
    if minfo.is_a?(Hash) and sty = minfo[:self] then
      local_vars[2][:type] = sty
    else
      local_vars[2][:type] = RubyType.from_sym(info[0], info[3], "self")
    end
    local_vars[3][:type] = RubyType.new(Type::Int32Ty, info[3], 
                                        "Exception Status")

    # Argument parametor |...| is omitted.
    an = code.header['locals'].size + 1
    dn = code.header['misc'][:local_size]
    if an < dn then
      (dn - an).times do |i|
        local_vars.push({
          :type => RubyType.new(nil),
          :area_type => RubyType.new(nil),
          :area => nil
        })
      end
    end

    local_vars.each do |e|
      e[:type].is_arg = true
    end
    local_vars[2][:type].is_arg = nil

    @locals[code] = local_vars
    numarg = code.header['misc'][:arg_size]

    # regist function to RubyMthhod for recursive call
    if info[1] then
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
          :self    => local_vars[2][:type],
          :rettype => RubyType.new(nil, info[3], "Return type of #{info[1]}"),
          :have_throw => nil,
          :have_yield => nil,
          :yield_argtype => nil,
          :yield_rettype => nil,
          :copy_rettype => false,
        }
      elsif minfo[:defined] then
#        raise "#{info[1]} is already defined in #{info[3]}"

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
      
      curframe = nil
      if context.current_frame then
        curframe = context.current_frame
      else
        # Make structure corrsponding struct of stack frame
        frst = make_frame_struct(context.local_vars)
        frstp = Type.pointer(frst)
        @frame_struct[code] = frstp
        curframe = b.alloca(frst, 1)
        context.current_frame = curframe
        if OPTION[:inline_block] then
          action = lambda {|code, info|
            if @inline_code_tab[code] then
              lcontext = @context_tab[code]
              lfrst = make_frame_struct(lcontext.local_vars)
              lfrstp = Type.pointer(lfrst)
              @frame_struct[code] = lfrstp
              lcurframe = b.alloca(lfrst, 1)
              lcontext.current_frame = lcurframe
            end
          }
          code.traverse_code_block(info.clone, action)
        end
      end
      
      if @inline_code_tab[code] == nil then
        if context.array_alloca_size then
          context.array_alloca_area = b.alloca(VALUE, context.array_alloca_size)
        end
        
        if OPTION[:inline_block] then
          action = lambda {|code, info|
            if @inline_code_tab[code] then
              lcontext = @context_tab[code]
              if lcontext.array_alloca_size then
                newarea = b.alloca(VALUE, lcontext.array_alloca_size)
                lcontext.array_alloca_area = newarea
              end
            end
          }
          code.traverse_code_block(info.clone, action)
        end
      end

      if @inline_code_tab[code] == nil then
        if ncnt = context.loop_cnt_alloca_size then
          ncnt.times do |i|
            area =  b.alloca(MACHINE_WORD, 1)
            context.loop_cnt_alloca_area.push area
          end
        end
        if OPTION[:inline_block] then
          action = lambda {|code, info|
            if @inline_code_tab[code] then
              lcontext = @context_tab[code]
              if ncnt = lcontext.loop_cnt_alloca_size then
                ncnt.times do |i|
                  area =  b.alloca(MACHINE_WORD, 1)
                  lcontext.loop_cnt_alloca_area.push area
                end
              end
            end
          }
          code.traverse_code_block(info.dup, action)
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
        dsttype = lvars[-n][:type]
        srcval = arg[n - 1]
        srcval = implicit_type_conversion(b, context, srcval, dsttype)
        b.store(srcval, lvars[-n][:area])
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
    have_throw = @have_throw
    array_alloca_size = @array_alloca_size
    loop_cnt_alloca_size = @loop_cnt_alloca_size
    instance_vars_local = @instance_vars_local

    if MethodDefinition::RubyMethod[info[1]][info[0]].is_a?(Hash) then
      MethodDefinition::RubyMethod[info[1]][info[0]][:have_throw] = have_throw
      MethodDefinition::RubyMethod[info[1]][info[0]][:have_yield] = have_yield
    end

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
    orggen_deffunc = @generated_define_func[info[0]][info[1]]
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

        if rett2.type.is_a?(UnsafeType) or
            argtype.any? {|e| e.type.is_a?(UnsafeType)} then
          is_mkstub = false
        end
      else
        argtype = []
        is_mkstub = false
      end

      if inlineargs == nil and @inline_code_tab[code] == nil then
        b = @builder.define_function(info[0], info[1].to_s, 
                                     rett2, argtype, is_mkstub)
      end

      if orggen_deffunc then
        orggen_deffunc.call(iargs)
      end
    }

    context = Context.new(local_vars, @builder)
    context.array_alloca_size = array_alloca_size
    context.loop_cnt_alloca_size = loop_cnt_alloca_size
    context.instance_vars_local = instance_vars_local
    context.instance_vars_local_area = {}
    context.block_value[nil] = [RubyType.value(info[3]), 4.llvm]
    @context_tab[code] = context

    @generated_code[info[0]] ||= {}
    orggen_code = @generated_code[info[0]][info[1]]
    @generated_code[info[0]][info[1]] = lambda { |iargs|
      if iargs then
        inlineargs = iargs
      end

      if inlineargs then
        b = inlineargs[2]
        @builder.select_func(b)
        context.exit_block = get_or_create_block("__exit_block", b, context)
      end
      context.builder.select_func(b)

      if iargs then
        context.inline_args = iargs[0]
        context.inline_caller_context = iargs[3]
        context.inline_caller_code = iargs[1]
        b = iargs[2]
        context.builder.select_func(b)
      else
        if inlineargs then
          context.inline_args = inlineargs[0]
        else
          context.inline_args = nil
        end
        context.inline_caller_context = nil
        context.inline_caller_code = nil
      end
      pppp "ret type #{rett2.type}"
      pppp "end"

      context = rescode.call(b, context)
      if orggen_code then
        orggen_code.call(iargs)
      end

      context
    }

#    @expstack = []
    @rescode = lambda {|b, context| context}
  end
  
  def visit_local_block_start(code, ins, local_vars, ln, info)
    @is_push_result_lblock[ln] = true
    oldrescode = @rescode
    live =  @is_live
    if live == nil and info[1] == nil then
      live = true
    end

    @is_live = nil
    @jump_from[ln] ||= []
    if live then
      @jump_from[ln].push @prev_label
    end
    valexp = nil
#    if live and @expstack.size > 0 then
    if @jump_from[ln].last == @prev_label and @expstack.size > 0 then
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
      commer_label.each do |ll|
        if @is_push_result_lblock[ll] then
          if v2 = @expstack.pop then
            valexp[0].add_same_value(v2[0])
            v2[0].add_same_value(valexp[0])
          end
        end
      end

=begin
      clsize = commer_label.size
      while n < clsize do
        if v2 = @expstack.pop then
           valexp[0].add_same_value(v2[0])
           v2[0].add_same_value(valexp[0])
        end
        n += 1
      end
=end

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
            phitype = RubyType.new(nil, info[3])
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
            labels = commer_label.uniq.select {|e| context.blocks_tail[e]}
            if labels.size > 0 then
              rc = b.phi(phitype.type.llvm)
              labels.reverse.each do |lab|
                rc.add_incoming(context.block_value[lab][1], 
                                context.blocks_tail[lab])
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
    end
    @prev_label = ln

    # p @expstack.map {|n| n[1]}
  end
  
  def visit_default(code, ins, local_vars, ln, info)
    p ins
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
    type.extent = :instance
    type.slf = local_vars[2][:type]

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
    srctype = nil
    srcvalue = nil
    if src then
      srctype = src[0]
      srcvalue = src[1]
    else
      p ins
      p info
      raise
    end
    
    srctype.add_same_value(dsttype)
    dsttype.add_same_value(srctype)
    srctype.extent = :instance
    srctype.slf = local_vars[2][:type]

    oldrescode = @rescode
    @rescode = lambda {|b, context|
      pppp "Setinstancevariable start"
      context = oldrescode.call(b, context)
      context = srcvalue.call(b, context)
      srcval = context.rc

      RubyType.resolve
      dsttype.type = dsttype.type.dup_type
      dsttype.type.content = srcval

      context.rc = srcval
      if vptr = context.instance_vars_local_area[ivname] then
        if dsttype.type.llvm == Type::DoubleTy then
          dbl = b.load(vptr)
          dbl_val = b.int_to_ptr(dbl, P_RFLOAT)
          dp = b.struct_gep(dbl_val, 1)
          b.store(srcval, dp)
        else
          srcval2 = srctype.type.to_value(srcval, b, context)
          b.store(srcval2, vptr)
        end

      else
        srcval2 = srctype.type.to_value(srcval, b, context)
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
      type.type.constant = val
      @constant_type_tab[@binding][cname] = type
    end
    @expstack.push [type,
      lambda {|b, context|
        if !UNDEF.equal?(type.type.constant) then
          context.rc = type.type.constant.llvm

        elsif !UNDEF.equal?(type.type.content) then
          context.rc = type.type.content.llvm

        elsif val then
          context.rc = val.llvm
        else
          slf = Object.llvm

          coid = ((cname.object_id << 1) / RVALUE_SIZE)

          ftype = Type.function(VALUE, [VALUE, VALUE])
          func = context.builder.external_function('rb_const_get', ftype)
          val = b.call(func, slf, coid.llvm)
          context.rc = type.type.from_value(val, b, context)
        end

        context.org = ins[1]
        context
      }]
  end

  def visit_setconstant(code, ins, local_vars, ln, info)
    val = @expstack.pop
    const_klass = nil
    if info[0] then
      const_klass = eval(info[0].to_s)
    else
      const_klass = Object
    end
    val[0].extent = :global
    if val[0].type and !UNDEF.equal?(val[0].type.constant) then
      const_klass.const_set(ins[1], val[0].type.constant)
    else
      @constant_type_tab[@binding][ins[1]] = val[0]
      oldrescode = @rescode
      cname = ins[1]
      @rescode = lambda {|b, context|
        context = oldrescode.call(b, context)
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
      type = RubyType.value(info[3], "#{glname}")
      @global_var_tab[glname][:type] = type
      areap = add_global_variable("glarea_ptr", VALUE, 4.llvm)
      @global_var_tab[glname][:area] = areap
      type.extent = :global
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
    srctype.extent = :global

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
    type.type.content = p1

    @expstack.push [type, 
      lambda {|b, context| 
        pppp p1
        case type.type.llvm
        when Type::Int1Ty
          context.rc = type.type.from_value(p1.llvm, b, context)
        when VALUE
          context.rc = orgtype.to_value(p1.llvm, b, context)
        when P_CHAR
          context.rc = p1.llvm2(b)
        else
          context.rc = p1.llvm
        end
        context.org = p1
        context
      }]
  end

  def visit_putspecialobject(code, ins, local_vars, ln, info)
  end

  def visit_putiseq(code, ins, local_vars, ln, info)
  end

  def visit_putstring(code, ins, local_vars, ln, info)
    p1 = ins[1]
    type = RubyType.typeof(p1, info[3], p1)
    type.type.constant = p1
    type.type.content = p1

    @expstack.push [type, 
      lambda {|b, context| 
        ftype = Type.function(VALUE, [P_CHAR])
        func = context.builder.external_function('rb_str_new_cstr', ftype)
        context.rc = b.call(func, p1.llvm2(b))
        context.org = p1
        context
      }]
  end

  def visit_concatstrings(code, ins, local_vars, ln, info)
    nele = ins[1]
    rett = RubyType.value(info[3], "return type concatstring", String)
    eles = []
    nele.times do
      eles.push @expstack.pop
    end
    eles.reverse!
    @expstack.push [rett, lambda {|b, context|
      ftype = Type.function(VALUE, [P_CHAR, MACHINE_WORD])
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
      atype.type.element_type.conflicted_types[v[0].klass] = etype
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

    constarrp = inits.all? {|e| !UNDEF.equal?(e[0].content)}
    if constarrp then
      arr = inits.map {|e| e[0].content}
      atype.type.content = arr
      EXPORTED_OBJECT[arr] = true
      @expstack.push [atype,
        lambda {|b, context|
          context.rc = arr.llvm
          context
      }]
    else
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
          
            ftype = Type.function(VALUE, [MACHINE_WORD, P_VALUE])
            func = context.builder.external_function('rb_ary_new4', ftype)
            rc = b.call(func, initsize.llvm, initarea2)
            context.rc = rc
          end
          context
       }]
    end
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

  def visit_expandarray(code, ins, local_vars, ln, info)
    siz = ins[1]
    flag = ins[2]
    arr = @expstack.pop
    val = nil
    siz.times do |i|
      @expstack.push [arr[0],
        lambda {|b, context|
          unless val then
            context = arr[1].call(b, context)
            val = context.rc
          end
          ftype = Type.function(VALUE, [VALUE, MACHINE_WORD])
          func = context.builder.external_function('rb_ary_entry', ftype)
          av = b.call(func, val, i.llvm)
          context.rc = av
          context
        }]
    end
  end

  # concatarray
  # splatarray
  # checkincludearray

  def visit_newhash(code, ins, local_vars, ln, info)
    nele = ins[1]
    inits = []
    htype = RubyType.value(info[3], "Return type of newhash", Hash)

    nele.times do |n|
      k = @expstack.pop
      v = @expstack.pop
      inits.push [k, v]
    end

    @expstack.push [htype,
      lambda {|b, context|
        ftype = Type.function(VALUE, [])
        func = context.builder.external_function('rb_hash_new', ftype)
        rc = b.call(func)
        context.rc = rc
        context
    }]
  end

  def visit_newrange(code, ins, local_vars, ln, info)
    lst = @expstack.pop
    fst = @expstack.pop
    exclflg = ins[1]
    rtype = RubyType.range(fst[0], lst[0], (exclflg == 0), info[3])
    @expstack.push [rtype,
       lambda {|b, context|
         case fst[0].type.llvm
         when Type::Int32Ty
           valfst = nil
           valfstint = fst[1].call(b, context).rc
           rtype.type.first.type.constant = valfstint

         when VALUE
           valfst = fst[1].call(b, context).rc
           valfstint = b.ashr(val, 1.llvm)
           rtype.type.first.type.constant = valfstint

         else
           raise "Not support type #{fst[0].type.inspect2} in Range"
         end

         case lst[0].type.llvm
         when Type::Int32Ty
           vallst = nil
           vallstint = lst[1].call(b, context).rc
#           valint = b.add(valint, 1.llvm) if exclflg == 0
           rtype.type.last.type.constant = vallstint

         when VALUE
           vallst = lst[1].call(b, context).rc
           vallstint = b.ashr(val, 1.llvm)
#           valint = b.add(valint, 1.llvm) if exclflg == 0
           rtype.type.last.type.constant = vallstint

         else
           raise "Not support type #{lst[0].type.inspect2} in Range"
         end

         if valfst == nil then
           valfst = fst[0].type.to_value(valfstint, b, context)
         end
         if vallst == nil then
           vallst = lst[0].type.to_value(vallstint, b, context)
         end
         ftype = Type.function(VALUE, [VALUE, VALUE, Type::Int32Ty])
         fname = 'rb_range_new'
         builder = context.builder
         func = builder.external_function(fname, ftype)
         context.rc = b.call(func, valfst, vallst, exclflg.llvm)
         context
    }]
  end

  def visit_pop(code, ins, local_vars, ln, info)
    if @is_live != false then
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
    else
      @expstack.pop
    end
  end
  
  def visit_dup(code, ins, local_vars, ln, info)
    s1 = @expstack.pop
    stacktop_value = nil
    @expstack.push [s1[0],
      lambda {|b, context|
        if stacktop_value then
          context.rc = stacktop_value
        else
          context = s1[1].call(b, context)
          stacktop_value = context.rc
        end
        context
      }]

    @expstack.push [s1[0],
      lambda {|b, context|
        if stacktop_value then
          context.rc = stacktop_value
        else
          context = s1[1].call(b, context)
          stacktop_value = context.rc
        end
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

  def visit_swap(code, ins, local_vars, ln, info)
    s1 = @expstack.pop
    s2 = @expstack.pop
    @expstack.push [s1[0],
      lambda {|b, context|
        context = s1[1].call(b, context)
        context
      }]

    @expstack.push [s1[0],
      lambda {|b, context|
        context = s2[1].call(b, context)
        context
      }]
  end

  # reput

  def visit_topn(code, ins, local_vars, ln, info)
    n = ins[1] + 1
    s1 = @expstack[-n]
    stacktop_value = nil
    @expstack[-n] = 
        [s1[0],
         lambda {|b, context|
           if stacktop_value then
             context.rc = stacktop_value
           else
             context = s1[1].call(b, context)
             stacktop_value = context.rc
           end
           context
         }]

    @expstack.push [s1[0],
      lambda {|b, context|
        if stacktop_value then
          context.rc = stacktop_value
        else
          context = s1[1].call(b, context)
          stacktop_value = context.rc
        end
        context
      }]
  end

  def visit_setn(code, ins, local_vars, ln, info)
    n = ins[1] + 1
    s1 = @expstack[-1]
    stacktop_value = nil
#    rettype = RubyType.new(nil, info[3])
#    s1[0].add_same_type rettype
    @expstack[-n] = 
        [s1[0],
         lambda {|b, context|
           if stacktop_value then
             context.rc = stacktop_value
           else
             context = s1[1].call(b, context)
             stacktop_value = context.rc
           end
           context
         }]

    @expstack[-1] = [s1[0],
      lambda {|b, context|
        if stacktop_value then
          context.rc = stacktop_value
        else
          context = s1[1].call(b, context)
          stacktop_value = context.rc
        end
        context
      }]
  end

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

    if do_function(receiver, info, ins, local_vars, args, mname, 0) then
      return
    end

    if do_cfunction(receiver, info, ins, local_vars, args, mname) then
      return
    end

    if funcinfo = MethodDefinition::SystemMethod[mname] then
      return
    end

    sender_env = {
      :info => info,
      :ins => ins,
      :ln => ln,
      :code => code,
      :args => args, 
      :receiver => receiver, 
      :local => local_vars,
    }

    if do_macro(mname, sender_env) then
      return
    end

    if do_inline_function(receiver, info, mname, sender_env)
      return
    end

    # Undefined method, it may be forward call.
    pppp "RubyMethod forward called #{mname.inspect}"

    recklass = receiver ? receiver[0].klass : nil
    rectype = receiver ? receiver[0] : nil

    # minfo doesn't exist yet
    para = gen_arg_eval(args, receiver, ins, local_vars, info, nil, mname)

    curlevel = @expstack.size
    npara = para.size
    if npara != 0 then
      if @array_alloca_size == nil or @array_alloca_size < npara + curlevel then
        @array_alloca_size = npara + curlevel
      end
    end

    rett = RubyType.new(nil, info[3], "Return forward type of #{mname}")
    @expstack.push [rett,
      lambda {|b, context|
        recklass = receiver ? receiver[0].klass : nil
        rectype = receiver ? receiver[0] : nil
        minfo, func = gen_method_select(rectype, info[0], mname)
        if minfo == nil then
          # Retry for generate dynamic dispatch.
          minfo, func = gen_method_select(rectype, nil, mname)
        end

        if func then
          nargt = minfo[:argtype]
          nargt.each_with_index do |ele, n|
            para[n][0].add_same_type ele
            ele.add_same_type para[n][0]
          end
          rett.add_same_type minfo[:rettype]
          minfo[:rettype].add_same_type rett
          RubyType.resolve

          if !with_selfp(receiver, info[0], mname) then
            para.pop
          end
          gen_call(func, para, b, context)
        else
          RubyType.value.add_same_type rett
          RubyType.resolve

	  gen_call_from_ruby(rett, rectype, mname, para, curlevel, b, context)
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
#    @have_yield = true
    set_have_yield(info, true)

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

    minfo = MethodDefinition::RubyMethod[info[1]][info[0]]
    minfo[:yield_argtype] = arg.map {|e| e[0]}
    minfo[:yield_rettype] = rett

    @expstack.push [rett, 
      lambda {|b, context|
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
          val = context.rc
          val = implicit_type_conversion(b, context, val, e[0])
          argval.push val
        end
        context.rc = b.call(fptr, *argval)
        context
      }]
  end

  def visit_leave(code, ins, local_vars, ln, info)
    retexp = nil
    retexp = @expstack.pop
    if @is_live == false then
      return
    end

    rett2 = nil
    if code.lblock_list.last != ln then
      @is_live = false
    end

    if retexp == nil then
      rett2 = RubyType.value(info[3], "Return type of #{info[1]}")
      retexp = [rett2, lambda {|b, context|
                  context.rc = 4.llvm
                  context
                }]
    end

    if info[1] then
      rett2 = MethodDefinition::RubyMethod[info[1]][info[0]][:rettype]
      retexp[0].add_same_type rett2
      # RubyType.resolve
    end
    retexp[0].extent = :global

    oldrescode = @rescode
    @rescode = lambda {|b, context|
      context = oldrescode.call(b, context)
      if rett2 == nil then
        rett2 = RubyType.new(nil)
      end

      if rett2.type == nil then
        retexp[0].add_same_type rett2
        RubyType.resolve
        
        if rett2.type == nil then
          rett2.type = PrimitiveType.new(VALUE, nil)
        end
      end

      context = retexp[1].call(b, context)
      rc = context.rc
      if rett2.type.llvm == VALUE then
        if retexp[0].type then
          rc = retexp[0].type.to_value(rc, b, context)
        end
      end
      if rc == nil then
        rc = 4.llvm
      end

      if context.inline_args then
        context.block_value[ln] = [rett2, rc]
        b.br(context.exit_block)
        if code.lblock_list.last == ln then
          b.set_insert_point(context.exit_block)
        end
      else
        b.return(rc)
      end

      context
    }
  end

  # finish

  EXCEPTION_KIND = {
    2 => :break
  }

  def visit_throw(code, ins, local_vars, ln, info)
    @have_throw = true
    oldrescode = @rescode
    @rescode = lambda {|b, context|
      context = oldrescode.call(b, context)
      kind = EXCEPTION_KIND[ins[1]]
      if lcontext = context.inline_caller_context then
        # Can compile to br instruction because block is inlined.
        lcode = context.inline_caller_code
        et = lcode.header['exception_table']
        et.each do |ele|
          if ele[0] == kind then
            tolab = ele[4]
            context.block_value[tolab] = [RubyType.value, 4.llvm]
            b.br(lcontext.blocks_head[tolab])
            blk = get_or_create_block("throw_dmy", b, context)
            b.set_insert_point(blk)
            break
          end
        end
      else
        # must compile unwind instruction because jump to caller function
      end
      context
    }
  end

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
      RubyType.clear_content

      context
    }
    if valexp then
      @expstack.push [valexp[0],
        lambda {|b, context| 
          if context.block_value[fmlab] then
            context.rc = context.block_value[fmlab][1]
          else
            context.rc = 4.llvm
          end
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
    iflab = nil
    @jump_from[lab] ||= []
    @jump_from[lab].push ln
    @rescode = lambda {|b, context|
      oldrescode.call(b, context)
      tblock = get_or_create_block(lab, b, context)
      iflab = context.curln

      eblock = context.builder.create_block
      context.curln = (context.curln.to_s + "_1").to_sym
      context.blocks_head[context.curln] = eblock
      context.blocks_tail[context.curln] = eblock
      if valexp then
        bval = [valexp[0], valexp[1].call(b, context).rc]
        context.block_value[iflab] = bval
      end
      condval = cond[1].call(b, context).rc
      if cond[0].type.llvm != Type::Int1Ty then
        vcond = cond[0].type.to_value(condval, b, context)
        vcond = b.and(vcond, (~4).llvm)
        condval = b.icmp_ne(vcond, 0.llvm)
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
    @is_push_result_lblock[ln] = false
    @is_push_result_lblock[(ln.to_s + "_1").to_sym] = false
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
    iflab = nil
    @jump_from[lab] ||= []
    @jump_from[lab].push ln
    @rescode = lambda {|b, context|
      oldrescode.call(b, context)
      eblock = context.builder.create_block
      iflab = context.curln
      context.curln = (context.curln.to_s + "_1").to_sym
      context.blocks_head[context.curln] = eblock
      context.blocks_tail[context.curln] = eblock
      tblock = get_or_create_block(lab, b, context)
      if valexp then
        context = valexp[1].call(b, context)
        bval = [valexp[0], context.rc]
        context.block_value[iflab] = bval
      end

      condval = cond[1].call(b, context).rc
      if cond[0].type.llvm != Type::Int1Ty then
        vcond = cond[0].type.to_value(condval, b, context)
        vcond = b.and(vcond, (~4).llvm)
        condval = b.icmp_ne(vcond, 0.llvm)
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
    @is_push_result_lblock[ln] = false
    @is_push_result_lblock[(ln.to_s + "_1").to_sym] = false
  end

  # getinlinecache
  # onceinlinecache
  # setinlinecache

  def visit_opt_case_dispatch(code, ins, local_vars, ln, info)
    @expstack.pop
  end

  # opt_checkenv
  
  def visit_opt_plus(code, ins, local_vars, ln, info)
    s = []
    s[1] = @expstack.pop
    s[0] = @expstack.pop
    rettype = check_same_type_2arg_static(s[0], s[1])
    case s[0][0].type.llvm
    when Type::DoubleTy, Type::Int32Ty
      rettype = s[0][0].dup_type
    else
#      rettype = s[0][0].dup_type
      if s[0][0].type then
        rettype = RubyType.value
      else
        rettype = s[0][0].dup_type
      end
    end
    
    @expstack.push [rettype,
      lambda {|b, context|
        sval = []
        sval, stype, context, constp = gen_common_opt_2arg(b, context, s[0], s[1])
        if constp then
          rc = sval[0] + sval[1]
          rettype.type.constant = rc
          context.rc = rc.llvm
          return context
        end

        case stype[0].klass
        when :Fixnum, :Float
          context.rc = b.add(sval[0], sval[1])

        when :String
          rs0 = sval[0]
          rs1 = sval[1]
          ftype = Type.function(VALUE, [VALUE, VALUE])
          funcapp = context.builder.external_function('rb_str_append', ftype)
          context.rc = b.call(funcapp, rs0, rs1)

        when :Array
          rs0 = sval[0]
          rs1 = sval[1]
          ftype = Type.function(VALUE, [VALUE, VALUE])
          funcapp = context.builder.external_function('rb_ary_plus', ftype)
          context.rc = b.call(funcapp, rs0, rs1)

=begin
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
              else
                raise "Unkown Type VALUE (#{conf1})"
              end
            else
              # Generic + dispatch
            end
=end
          else
            # Generic + dispatch        else
          p info
          p s[0][0].conflicted_types.keys
          raise "Unkown Type #{s[0][0].type.llvm}"
        end

        if rettype.type.llvm == VALUE then
          context.rc = rettype.type.to_value(context.rc, b, context)
        end

        context
      }
    ]
  end
  
  def visit_opt_minus(code, ins, local_vars, ln, info)
    s = []
    s[1] = @expstack.pop
    s[0] = @expstack.pop
    rettype = check_same_type_2arg_static(s[0], s[1])

    @expstack.push [rettype,
      lambda {|b, context|
        sval = []
        sval, stype, context, constp = gen_common_opt_2arg(b, context, s[0], s[1])
        if constp then
          rc = sval[0] - sval[1]
          rettype.type.constant = rc
          context.rc = rc.llvm
          return context
        end

        case stype[0].type.llvm
        when Type::DoubleTy, Type::Int32Ty
          context.rc = b.sub(sval[0], sval[1])
=begin          
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
=end
        else
          # Generic + dispatch
          p info
          p s[0][0].conflicted_types.keys
          raise "Unkown Type #{s[0][0].type.llvm}"
        end

        if rettype.type.llvm == VALUE then
          context.rc = rettype.type.to_value(context.rc, b, context)
        end

        context
      }
    ]
  end
  
  def visit_opt_mult(code, ins, local_vars, ln, info)
    s2 = @expstack.pop
    s1 = @expstack.pop
      
    level = nil
    case s1[0].klass
    when :Array, :String
      level = @expstack.size
      if @array_alloca_size == nil or @array_alloca_size < 1 + level then
        @array_alloca_size = 1 + level
      end
      case s1[0].klass
      when :Array
        rettype = RubyType.array(info[3], "return type of *")
        s1[0].type.element_type.add_same_type(rettype.type.element_type)
      when :String
        rettype = RubyType.string(info[3], "return type of *")
      end

    else
      rettype = check_same_type_2arg_static(s1, s2)
    end

    @expstack.push [rettype,
      lambda {|b, context|
        if s1[0].klass != :Array then
          sval = []
          sval, stype, context, constp = gen_common_opt_2arg(b, context, s1, s2)
          if constp then
            rc = sval[0] * sval[1]
            rettype.type.constant = rc
            context.rc = rc.llvm
            return context
          end
        else
          context = gen_call_from_ruby(rettype, s1[0], :*, [s2, s1], level, 
                                       b, context)
          return context
        end

        case stype[0].klass
        when :Fixnum, :Float
          context.rc = b.mul(sval[0], sval[1])

        when :String
          rs0 = sval[0]
          rs1int = sval[1]
          rs1 = stype[1].type.to_value(rs1int, b, context)
          ftype = Type.function(VALUE, [VALUE, VALUE])
          funcapp = context.builder.external_function('rb_str_times', ftype)
          context.rc = b.call(funcapp, rs0, rs1)

=begin          
        when VALUE
          s1int = b.ashr(sval[0], 1.llvm)
          s2int = b.ashr(sval[1], 1.llvm)
          mulint = b.mul(sval[0], sval[1])
          x = b.shl(mulint, 1.llvm)
          context.rc = b.or(FIXNUM_FLAG, x)
=end

        else
          raise "Unsupported type #{s1[0].inspect2}"
        end

        if rettype.type.llvm == VALUE then
          context.rc = rettype.type.to_value(context.rc, b, context)
        end

        context
      }
    ]
  end
  
  def visit_opt_div(code, ins, local_vars, ln, info)
    s2 = @expstack.pop
    s1 = @expstack.pop
    rettype = check_same_type_2arg_static(s1, s2)
    
    @expstack.push [rettype,
      lambda {|b, context|
        sval = []
        sval, stype, context, constp = gen_common_opt_2arg(b, context, s1, s2)
        if constp then
          rc = sval[0] / sval[1]
          rettype.type.constant = rc
          context.rc = rc.llvm
          return context
        end

        case stype[0].type.llvm
        when Type::DoubleTy
          context.rc = b.fdiv(sval[0], sval[1])

        when Type::Int32Ty
          context.rc = b.sdiv(sval[0], sval[1])

        else
          raise "Unsupported type #{s1[0].inspect2}"
        end

        if rettype.type.llvm == VALUE then
          context.rc = rettype.type.to_value(context.rc, b, context)
        end

        context
      }
    ]
  end

  def visit_opt_mod(code, ins, local_vars, ln, info)
    s2 = @expstack.pop
    s1 = @expstack.pop
    rettype = nil
    if s1[0].type and s1[0].type.klass == :String then
      if @array_alloca_size == nil then
        @array_alloca_size = 1
      end
      rettype = RubyType.value(info[3], "return type of %")
    else
      rettype = check_same_type_2arg_static(s1, s2)
    end

    @expstack.push [rettype,
      lambda {|b, context|
        sval = []
        if s1[0].type.klass == :String then
          context = s1[1].call(b, context)
          s1val = context.rc
          context = s2[1].call(b, context)
          s2val = context.rc

          s1value = s1[0].type.to_value(s1val, b, context)
          s2value = s2[0].type.to_value(s2val, b, context)
          
          if s2[0].type.klass == :Array then
            
          else
            s2len = 1.llvm
            s2ptr = context.array_alloca_area
            b.store(s2value, s2ptr)
            
            ftype = Type.function(VALUE, [LONG, P_VALUE, VALUE])
            func = context.builder.external_function('rb_str_format', ftype)
            context.rc = b.call(func, s2len, s2ptr, s1value)
          end

          return context
        end

        sval, stype, context, constp = gen_common_opt_2arg(b, context, s1, s2)

        if constp then
          rc = sval[0] % sval[1]
          rettype.type.constant = rc
          context.rc = rc.llvm
          return context
        end

        # It is right only s1 and s2 is possitive.
        # It must generate more complex code when s1 and s2 are negative.
        case stype[0].type.llvm
        when Type::DoubleTy
          context.rc = b.frem(sval[0], sval[1])

        when Type::Int32Ty
          context.rc = b.srem(sval[0], sval[1])

        else
          p s1[0].type.klass
          raise "Unsupported type #{s1[0].inspect2}"
        end

        if rettype.type.llvm == VALUE then
          context.rc = rettype.type.to_value(context.rc, b, context)
        end

        context
      }]
  end

  def visit_opt_eq(code, ins, local_vars, ln, info)
    s2 = @expstack.pop
    s1 = @expstack.pop
    check_same_type_2arg_static(s1, s2)
    rett = RubyType.boolean(info[3])
    @expstack.push [rett, 
      lambda {|b, context|
        sval = []
        sval, stype, context, constp = gen_common_opt_2arg(b, context, s1, s2)
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

        case stype[0].klass
        when :Float
          context.rc = b.fcmp_ueq(sval[0], sval[1])

        when :Fixnum
          context.rc = b.icmp_eq(sval[0], sval[1])

        else
          context = gen_call_from_ruby(stype[0], rett, :==, [s1, s2], 0,
                                       b, context)
          ret = context.rc
          context.rc = b.icmp_ne(ret, true.llvm)
        end

        context
      }
    ]
  end

  def visit_opt_neq(code, ins, local_vars, ln, info)
    s2 = @expstack.pop
    s1 = @expstack.pop
    check_same_type_2arg_static(s1, s2)
    rett = RubyType.boolean(info[3])
    
    @expstack.push [rett, 
      lambda {|b, context|
        sval = []
        sval, stype, context, constp = gen_common_opt_2arg(b, context, s1, s2)
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

        case stype[0].klass
        when :Float
          context.rc = b.fcmp_une(sval[0], sval[1])

        when :Fixnum
          context.rc = b.icmp_ne(sval[0], sval[1])

        else
          context = gen_call_from_ruby(stype[0], rett, :==, [s1, s2], 0,
                                       b, context)
          ret = context.rc
          context.rc = b.icmp_eq(ret, true.llvm)
        end

        context
      }
    ]
  end

  def visit_opt_lt(code, ins, local_vars, ln, info)
    s2 = @expstack.pop
    s1 = @expstack.pop
    check_same_type_2arg_static(s1, s2)
    
    @expstack.push [RubyType.boolean(info[3]), 
      lambda {|b, context|
        sval = []
        sval, stype, context, constp = gen_common_opt_2arg(b, context, s1, s2)
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

        case stype[0].type.llvm
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
    
    @expstack.push [RubyType.boolean(info[3]), 
      lambda {|b, context|
        sval = []
        sval, stype, context, constp = gen_common_opt_2arg(b, context, s1, s2)
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

        case stype[0].type.llvm
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
    
    @expstack.push [RubyType.boolean(info[3]), 
      lambda {|b, context|
        sval = []
        sval, stype, context, constp = gen_common_opt_2arg(b, context, s1, s2)
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

        case stype[0].type.llvm
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
    
    @expstack.push [RubyType.boolean(info[3]), 
      lambda {|b, context|
        sval = []
        sval, stype, context, constp = gen_common_opt_2arg(b, context, s1, s2)
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

        case stype[0].type.llvm
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
    if s1[0].type 
      if s1[0].type.klass == :String then
        rettype = check_same_type_2arg_static(s1, s2)
      elsif s1[0].type.klass != :Array then
        rettype = check_same_type_2arg_static(s1, s2)
      end
    end

    @expstack.push [rettype,
      lambda {|b, context|
        sval = []
        sval, stype, context, constp = gen_common_opt_2arg(b, context, s1, s2)
        if constp then
          rc = sval[0] << sval[1]
          rettype.type.constant = rc
          context.rc = rc.llvm
          return context
        end

        # It is right only s1 and s2 is possitive.
        # It must generate more complex code when s1 and s2 are negative.
        case stype[0].type.klass
        when :Fixnum
          context.rc = b.shl(sval[0], sval[1])

        when :Array
          ftype = Type.function(VALUE, [VALUE, VALUE])
          func = context.builder.external_function('rb_ary_push', ftype)
          context.rc = b.call(func, sval[0], sval[1])

        when :String
          ftype = Type.function(VALUE, [VALUE, VALUE])
          func = context.builder.external_function('rb_str_concat', ftype)
          sval[0] = stype[0].type.to_value(sval[0], b, context)
          sval[1] = stype[1].type.to_value(sval[1], b, context)
          rcvalue = b.call(func, sval[0], sval[1])
          context.rc = rettype.type.from_value(rcvalue, b, context)

        else
          raise "Unsupported type #{s1[0].inspect2}"
        end

        context
      }]
  end

  def opt_aref_aux(b, context, arr, idx, rettype, level, info, indx)
    case arr[0].klass
    when :Array
      context = idx[1].call(b, context)
      idxp = context.rc
      if OPTION[:array_range_check] then
        context = arr[1].call(b, context)
        arrp = context.rc
        ftype = Type.function(VALUE, [VALUE, MACHINE_WORD])
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
            embed = context.builder.create_block
            nonembed = context.builder.create_block
            comm = context.builder.create_block
            context = arr[1].call(b, context)
            arrp = context.rc
            arrp = b.int_to_ptr(arrp, P_RARRAY)
            arrhp = b.struct_gep(arrp, 0)
            arrhp = b.struct_gep(arrhp, 0)
            arrh = b.load(arrhp)
            isemb = b.and(arrh, EMBEDER_FLAG.llvm)
            isemb = b.icmp_ne(isemb, 0.llvm)
            b.cond_br(isemb, embed, nonembed)
            
            #  Embedded format
            b.set_insert_point(embed)
            eabdy = b.struct_gep(arrp, 1)
            eabdy = b.int_to_ptr(eabdy, P_VALUE)
            
            b.br(comm)
            
            #  Not embedded format
            b.set_insert_point(nonembed)
            nabdyp = b.struct_gep(arrp, 3)
            nabdy = b.load(nabdyp)
            b.br(comm)
            
            b.set_insert_point(comm)
            abdy = b.phi(P_VALUE)
            abdy.add_incoming(eabdy, embed)
            abdy.add_incoming(nabdy, nonembed)
            arr[0].type.ptr = abdy
            
            context.blocks_tail[context.curln] = comm
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
      context.rc = av
      
      context

    when :String
      raise "Not impremented String::[] #{info[3]}"
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
      context.rc = av
          
      context
      
    when :"YARV2LLVM::LLVMLIB::Unsafe"
      context = arr[1].call(b, context)
      arrp = context.rc
      context = idx[1].call(b, context)
      case arr[0].type.type
      when LLVM_Pointer, LLVM_Array, LLVM_Vector
        idxp = context.rc
        rettype.type.type = arr[0].type.type.member
        addr = b.gep(arrp, idxp)
        context.rc = b.load(addr)

      when LLVM_Struct
        addr = b.struct_gep(arrp, indx)
        context.rc = b.load(addr)

      else
        p arr[0].type.type.class
        raise "Unsupport type #{arr[0].type.type}"
      end
      context

    else
      if level == 0 then
        arr[0].conflicted_types.each do |klass, carr|
          if carr.is_a?(ComplexType) then
            rettype = carr.element_type
            arr[0].type = carr
            res = opt_aref_aux(b, context, arr, idx, rettype, 
                               level + 1, info, indx)
            if res then
              return res
            end
          end
        end
        pp arr[0]
        raise "Not impremented #{arr[0].inspect2} in #{info[3]}"
      else
        nil
      end
    end
  end

  def visit_opt_aref(code, ins, local_vars, ln, info)
    idx = @expstack.pop
    arr = @expstack.pop
    case arr[0].klass
    when :Array
      fix = RubyType.fixnum(info[3])
      idx[0].add_same_type(fix)
      fix.add_same_value(idx[0])
    end

    RubyType.resolve

    # AbstrubctContainorType is type which have [] and []= as method.
    if arr[0].type == nil then
   #   RubyType.new(AbstructContainerType.new(nil)).add_same_type arr[0]
      arr[0].type = AbstructContainerType.new(nil)
    end

    rettype = nil
    indx = nil
    case arr[0].klass
    when :Array                 #, :Object
      rettype = arr[0].type.element_type
      
    when :Struct, :Hash
      rettype = RubyType.value

    when :"YARV2LLVM::LLVMLIB::Unsafe"
      rettype = RubyType.unsafe
      case arr[0].type.type
      when LLVM_Struct
        rindx = idx[0].type.constant
        indx = rindx
        if rindx.is_a?(Symbol) then
          unless indx = arr[0].type.type.index_symbol[rindx]
            raise "Unkown tag #{rindx}"
          end
        end
        rettype.type.type = arr[0].type.type.member[indx]
      end

    when :Object
      rettype = arr[0].type.element_type

    else
      rettype = RubyType.new(nil)
      #      p info
      #      pp arr[0]
      #      raise "Unkown Type #{arr[0].klass}"
    end

    @expstack.push [rettype,
      lambda {|b, context|
        pppp "aref start"
        opt_aref_aux(b, context, arr, idx, rettype, 0, info, indx)
      }
    ]
  end

  # opt_aset

  def visit_opt_length(code, ins, local_vars, ln, info)
    rec = @expstack.pop
    level = @expstack.size
    if @array_alloca_size == nil or @array_alloca_size < 1 + level then
      @array_alloca_size = 1 + level
    end

    rettype = RubyType.fixnum(info[3], "return type of length", Fixnum)
    @expstack.push [rettype, 
      lambda {|b, context|
        case rec[0].type.klass
        when :String
          context = rec[1].call(b, context)
          recval = context.rc
          recval = rec[0].type.to_value(recval, b, context)
          ftype = Type.function(VALUE, [VALUE])
          func = context.builder.external_function('rb_str_length', ftype)
          rcvalue = b.call(func, recval)
          context.rc = rettype.type.from_value(rcvalue, b, context)
          
        when :Array
          context = gen_call_from_ruby(rettype, rec[0], :length, [rec], level, 
                                       b, context)

        else
          raise "Not support type #{rec[0].inspect2} in length"
        end
                      
        context
      }]
  end

  # opt_succ

  def visit_opt_not(code, ins, local_vars, ln, info)
    rec = @expstack.pop

    rettype = RubyType.boolean(info[3], "return type of not")
    @expstack.push [rettype, 
      lambda {|b, context|
        context = rec[1].call(b, context)
        recval = context.rc
        recval = rec[0].type.to_value(recval, b, context)
        bool = b.and(recval, (~4).llvm)

        context.rc = b.icmp_eq(bool, 0.llvm)

        context
      }]
  end

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
        if UNDEF.equal?(context.rc = type.type.content) then
          context.rc = b.load(context.local_vars[voff][:area])
        end

        context.org = local_vars[voff][:name]
        context
      }]
  end

  def store_to_local(voff, src, local_vars, ln, info)
    voff = voff + 2
    dsttype = local_vars[voff][:type]
    areatype = local_vars[voff][:area_type]
    srctype = src[0]
    srcvalue = src[1]

    srctype.add_same_type(dsttype)
    dsttype.add_same_value(srctype)
    srctype.add_extent_base dsttype

    srctype.add_same_type(areatype)
=begin
    RubyType.resolve
    if dsttype.dst_type and 
        dsttype.dst_type.klass == srctype.klass then
      dsttype.type = dsttype.dst_type
    end
=end

    oldrescode = @rescode
    @rescode = lambda {|b, context|
      pppp "Setlocal start"
      context = oldrescode.call(b, context)

      context = srcvalue.call(b, context)
      srcval = context.rc
      srcval = implicit_type_conversion(b, context, srcval, srctype)
        
      lvar = context.local_vars[voff]

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
        if UNDEF.equal?(context.rc = type.type.content) then
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
    areatype = alocal[:area_type]

    srctype = src[0]
    srcvalue = src[1]

    srctype.add_same_type(dsttype)
    dsttype.add_same_value(srctype)
    srctype.add_extent_base dsttype

    srctype.add_same_type(areatype)
=begin
    RubyType.resolve
    if dsttype.dst_type and 
        dsttype.dst_type.klass == srctype.klass then
      dsttype.type = dsttype.dst_type.dup_type
    end
=end

    oldrescode = @rescode
    @rescode = lambda {|b, context|
      context = oldrescode.call(b, context)
      context = srcvalue.call(b, context)
      rval = context.rc
      rval = implicit_type_conversion(b, context, rval, srctype)

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
      defperklass[nil].call([[klassval.llvm], nil, b, nil])
    end
    klasses = @generated_code.keys.reverse
    klasses.each do |klass|
      defperklass = @generated_code[klass]
      defperklass[nil].call(nil)
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
          nameptr = name.llvm2(b)
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

  def set_have_yield(info, val)
    if MethodDefinition::RubyMethod[info[1]][info[0]].is_a?(Hash) then
      MethodDefinition::RubyMethod[info[1]][info[0]][:have_yield] = val
    end
    @have_yield = val
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
  prelude = 'runtime/prelude.rb'
  pcont = File.read(prelude)
  pconty2l = eval(pcont)
  preis = RubyVM::InstructionSequence.compile(pconty2l, prelude, 1,
             { :peephole_optimization    => true,
               :inline_const_cache       => false,
               :specialized_instruction  => true,}).to_a
  preiseq = VMLib::InstSeqTree.new(nil, preis)
  preload.unshift preiseq
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


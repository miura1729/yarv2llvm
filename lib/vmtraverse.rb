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
  end

  attr_accessor :local_vars
  attr_accessor :rc
  attr_accessor :org
  attr_accessor :blocks
  attr_accessor :curln
  attr_accessor :block_value
  attr :builder
end

class YarvVisitor
  def initialize(iseq)
    @iseq = iseq
  end

  def run
    @iseq.traverse_code([nil, nil, nil, nil]) do |code, info|
      if code.header['type'] == :block
        info[1] = (info[1].to_s + '_block').to_sym
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
#        ln = curln
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

  def initialize(iseq, bind)
    super(iseq)
    @builder = LLVMBuilder.new
    @binding = bind
    @expstack = []
    @rescode = lambda {|b, context| context}
    @code_gen = {}
    @jump_hist = {}
    @prev_label = nil
    @is_live = nil
  end

  def run
    super
    @code_gen.each do |fname, gen|
      gen.call
    end
#    @builder.optimize
#    @builder.disassemble
    
  end
  
  def get_or_create_block(ln, b, context)
    if context.blocks[ln] then
      context.blocks[ln]
    else
      context.blocks[ln] = context.builder.create_block
    end
  end
  
  def visit_local_block_start(code, ins, local, ln, info)
    oldrescode = @rescode
    live =  @is_live

    @is_live = nil
    if live and @expstack.size > 0 then
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
      end
      context.curln = ln
      b.set_insert_point(blk)
      context
    }

    if valexp then
      n = 0
      v2 = nil
      commer_label = @jump_hist[ln]
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
  
  def visit_block_start(code, ins, local, ln, info)
    ([nil, :self] + code.header['locals'].reverse).each_with_index do |n, i|
      local[i] = {
        :name => n, 
        :type => RubyType.new(nil, info[3], n),
        :area => nil}
    end
    numarg = code.header['misc'][:arg_size]

    # regist function to RubyCMthhod for recursive call
    if info[1] then
      minfo = MethodDefinition::RubyMethod[info[1]]
      if minfo == nil then
        argt = []
        1.upto(numarg) do |n|
          argt[n - 1] = local[-n][:type]
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
        minfo[:defined] = true
      end
    end

    oldrescode = @rescode
    @rescode = lambda {|b, context|
      context = oldrescode.call(b, context)
      context.local_vars.each_with_index {|vars, n|
        if vars[:type].type then
          lv = b.alloca(vars[:type].type.llvm, 1)
          vars[:area] = lv
        else
          vars[:area] = nil
        end
      }

      # Copy argument in reg. to allocated area
      arg = context.builder.arguments
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

    argtype = []
    1.upto(numarg) do |n|
      argtype[n - 1] = local[-n][:type]
    end

    if @expstack.last and info[1] then
      retexp = @expstack.pop
      code = @rescode
      rett2 = MethodDefinition::RubyMethod[info[1]][:rettype]
      rett2.add_same_type retexp[0]
      retexp[0].add_same_type rett2
      RubyType.resolve

=begin
    # write function prototype
    if info[1] then
      print "#{info[1]} :("
      1.upto(numarg) do |n|
        print "#{local[-n][:type].inspect2}, "
      end
      print ") -> #{retexp[0].inspect2}\n"
    end
=end

      @code_gen[info[1]] = lambda {
        pppp "define #{info[1]}"
        pppp @expstack
      
        b = @builder.define_function(info[1].to_s, 
                                   retexp[0], argtype)
        context = code.call(b, Context.new(local, @builder))
        b.return(retexp[1].call(b, context).rc)

        pppp "ret type #{retexp[0].type}"
        pppp "end"
      }
    end

#    @expstack = []
    @rescode = lambda {|b, context| context}
  end
  
  def visit_default(code, ins, local, ln, info)
#    pppp ins
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
      pppp "Setlocal start"
      context = oldrescode.call(b, context)
      context = srcvalue.call(b, context)
      lvar = context.local_vars[p1]
      context.rc = b.store(context.rc, lvar[:area])
      context.org = lvar[:name]
      pppp "Setlocal end"
      context
    }
  end

  # getspecial
  # setspecial
  # getdynamic
  # setdynamic
  # getinstancevariable
  # setinstancevariable
  # getclassvariable
  # setclassvariable
  # getconstant
  # setconstant
  # getglobal
  # setglobal

  def visit_putnil(code, ins, local, ln, info)
    # Nil is not support yet.
=begin
    @expstack.push [RubyType.typeof(nil), 
      lambda {|b, context| 
        nil
      }]
=end
  end

  # putself

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
  # putstring
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

  # pop
  
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
  
  def visit_send(code, ins, local, ln, info)
    p1 = ins[1]
    if funcinfo = MethodDefinition::SystemMethod[p1] then
      funcinfo[:args].downto(1) do |n|
        @expstack.pop
      end
      return
    end

    if funcinfo = MethodDefinition::InlineMethod[p1] then
      instance_eval &funcinfo[:inline_proc]
      return
    end

    if funcinfo = MethodDefinition::CMethod[p1] then
      rettype = RubyType.new(funcinfo[:rettype], info[3], "return type of #{p1}")
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

    if minfo = MethodDefinition::RubyMethod[p1] then
      pppp "RubyMethod called #{p1.inspect}"
      para = []
      0.upto(ins[2] - 1) do |n|
        v = @expstack.pop

        v[0].add_same_type(minfo[:argtype][n])
        minfo[:argtype][n].add_same_type(v[0])

        para[n] = v
      end
      @expstack.push [minfo[:rettype],
        lambda {|b, context|
          minfo = MethodDefinition::RubyMethod[p1]
          func = minfo[:func]
          args = []
          para.each do |pe|
            context = pe[1].call(b, context)
            args.push context.rc
          end
          context.rc = b.call(func, *args)
          context
        }]
      return
    end

    # Undefined method, it may be forward call.
    para = []
    0.upto(ins[2] - 1) do |n|
      v = @expstack.pop
      para[n] = v
    end
    rett = RubyType.new(nil, info[3], "Return type of #{p1}")
    @expstack.push [rett,
      lambda {|b, context|
        argtype = para.map {|ele|
          ele[0].type.llvm
        }
        ftype = Type.function(rett.type.llvm, argtype)
        func = context.builder.get_or_insert_function(p1, ftype)
        args = []
        para.each do |pe|
          context = pe[1].call(b, context)
          args.push context.rc
        end
        context.rc = b.call(func, *args)
        context
      }]
    MethodDefinition::RubyMethod[p1]= {
      :defined => false,
      :argtype => para.map {|ele| ele[0]},
      :rettype => rett
    }

    return
  end

  # invokesuper
  # invokeblock
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
    @jump_hist[lab] ||= []
    @jump_hist[lab].push (ln.to_s + "_1").to_sym
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
    @is_live = false
    iflab = nil
    @jump_hist[lab] ||= []
    @jump_hist[lab].push (ln.to_s + "_1").to_sym
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
    fix = RubyType.fixnum(info[3])
    idx[0].add_same_type(fix)
    fix.add_same_type(idx[0])
    RubyType.resolve
    if arr[0].type == nil then
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
end

def compile_file(fn, bind = TOPLEVEL_BINDING)
  is = RubyVM::InstructionSequence.compile( File.read(fn), fn, 1, 
            {  :peephole_optimization    => true,
               :inline_const_cache       => false,
               :specialized_instruction  => true,}).to_a
  compcommon(is, bind)
end

def compile(str, bind = TOPLEVEL_BINDING)
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
  compcommon(is, bind)
end

def compcommon(is, bind)
  iseq = VMLib::InstSeqTree.new(nil, is)
  pppp iseq.to_a
  YarvTranslator.new(iseq, bind).run
  MethodDefinition::RubyMethodStub.each do |key, m|
    name = key
    n = 0
    if m[:argt] == [] then
      args = ""
      args2 = ""
    else
      args = m[:argt].map {|x|  n += 1; "p" + n.to_s}.join(',')
      args2 = ', ' + args
    end
    df = "def #{key}(#{args});LLVM::ExecutionEngine.run_function(YARV2LLVM::MethodDefinition::RubyMethodStub['#{key}'][:stub]#{args2});end" 
    pppp df
    eval df, bind
  end
end

module_function :compile_file
module_function :compile
module_function :compcommon
end

module YARV2LLVM
module LLVMUtil
  include LLVM
  include RubyHelpers

  def get_or_create_block(ln, b, context)
    if context.blocks_head[ln] then
      context.blocks_head[ln]
    else
      nb = context.builder.create_block
      context.blocks_head[ln] = nb
      context.blocks_tail[ln] = nb
    end
  end
  
  def check_same_type_2arg_static(p1, p2)
    p1[0].add_same_type(p2[0])
    p2[0].add_same_type(p1[0])
    rettype = p1[0].dup_type
    p2[0].add_same_type rettype

    RubyType.resolve
    if rettype.dst_type then
      rettype.type = rettype.dst_type
    end
    rettype
  end
  
  def primitive_value?(type)
    type.type.llvm == VALUE and
    type.conflicted_types.size == 1    
  end

  def implicit_type_conversion(b, context, val, type)
    if type.dst_type and 
       type.dst_type.llvm == Type::DoubleTy and
       type.type.llvm == Type::Int32Ty then

      val = b.si_to_fp(val, Type::DoubleTy)
    end
    val
  end

  def convert_type_for_2arg_op(b, context, p1, p2)
    RubyType.resolve
    nop = lambda {|val, type| [val, type]}
    val2prim = lambda {|val, type| 
      rval = type.type.from_value(val, b, context)
      ctype = type.conflicted_types.to_a[0]
      rtype = RubyType.new(nil)
      rtype.type = ctype[1]
      [rval, rtype]
    }

    convinfo = nil

    res = [nop, nop]
    if primitive_value?(p1[0]) then
      res[0] = val2prim
    end

    if primitive_value?(p2[0]) then
      res[1] = val2prim
    end

    return res
  end

  def gen_common_opt_2arg(b, context, s1, s2)
    if s1[0].type and s2[0].type and
       !UNDEF.equal?(s1[0].type.constant) and 
       !UNDEF.equal?(s2[0].type.constant) then
      val = [s1[0].type.constant, s2[0].type.constant]
      type = [s1[0], s2[0]]
      return [val, type, context, true]
    end

    convinfo = convert_type_for_2arg_op(b, context, s1, s2)
    context = s1[1].call(b, context)
    s1val = context.rc
    s1type = s1[0]
    s1val, s1type = convinfo[0].call(s1val, s1type)

    context = s2[1].call(b, context)
    s2val = context.rc
    s2type = s2[0]
    s2val, s2type = convinfo[1].call(s2val, s2type)

    if s1type.type.llvm != s2type.type.llvm then
      s1val = implicit_type_conversion(b, context, s1val, s1type)
      s2val = implicit_type_conversion(b, context, s2val, s2type)
    end

    val = [s1val, s2val]
    type = [s1type, s2type]

    [val, type, context, false]
  end

  def make_frame_struct(local_vars)
    member = []
    local_vars.each do |ele|
      if ele[:area_type].dst_type then
        member.push ele[:area_type].dst_type.llvm
      elsif ele[:area_type].type then
        member.push ele[:area_type].type.llvm
      elsif ele[:type].type then
        member.push ele[:type].type.llvm
      else
        member.push VALUE
      end
    end
    Type.struct(member)
  end

  def gen_array_size(b, context, arr)
    recval = context.rc
    aptr = b.int_to_ptr(recval, P_RARRAY)
    lenptr = b.struct_gep(aptr, 1)
    b.load(lenptr)
  end

  def gen_call_var_args_and_self(para, fname, rtype, slf)
    ftype = Type.function(VALUE, [Type::Int32Ty, P_VALUE, VALUE])
    gen_call_var_args_common(para, fname, rtype, ftype) {
      |b, context, func, nele, argarea|
      slfval = slf[1].call(b, context).rc
      b.call(func, nele.llvm, argarea, slfval)
    }
  end

  def gen_call_var_args(para, fname, rtype)
    ftype = Type.function(VALUE, [Type::Int32Ty, P_VALUE])
    gen_call_var_args_common(para, fname, rtype, ftype) {
      |b, context, func, nele, argarea|
      b.call(func, nele.llvm, argarea)
    }
  end

  def gen_call_var_args_common(para, fname, rtype, ftype)
    args = para[:args].reverse
    nele = para[:args].size
    if @array_alloca_size == nil or @array_alloca_size < nele then
      @array_alloca_size = nele
    end
    @expstack.push [rtype,
      lambda {|b, context|
        func = @builder.external_function(fname, ftype)
        
        argarea = context.array_alloca_area
        args.each_with_index {|pterm, i|
          context = pterm[1].call(b, context)
          srcval = context.rc
          src = pterm[0].type.to_value(srcval, b, context)
          dst = b.gep(argarea, i.llvm)
          b.store(src, dst)
        }
        context.rc = yield(b, context, func, nele, argarea)
        context}]
  end

  def add_global_variable(name, type, init)
    @builder.define_global_variable(type, init)
  end

  def gen_binary_operator(para, core)
    arg1 = para[:receiver]
    arg2 = para[:args][0]
    arg1[0].add_same_type arg2[0]
    arg2[0].add_same_type arg1[0]
    @expstack.push [arg1[0],
      lambda {|b, context|
        context = arg1[1].call(b, context)
        val1 = context.rc
        context = arg2[1].call(b, context)
        val2 = context.rc
              
        case arg1[0].type.llvm
        when Type::Int32Ty
          context.rc = core.call(val1, val2, b, context)
        else
          raise "Unsupported type #{arg1[0].inspect2}"
        end
        context}]
  end

  def gen_loop_proc(para)
    ins = para[:ins]
    info = para[:info]
    rec = para[:receiver]
    code = para[:code]
    ins = para[:ins]
    local_vars = para[:local]
    blk = ins[3]
    blab = get_block_label(info[1], blk)
    if OPTION[:inline_block] then
      blkcode = code.blockes[blk[1]]
      @inline_code_tab[blkcode] = code
    end
    recklass = rec ? rec[0].klass : nil
    
    loop_cnt_current = @loop_cnt_current
    @loop_cnt_current += 1
    if @loop_cnt_alloca_size < @loop_cnt_current then
      @loop_cnt_alloca_size = @loop_cnt_current
    end
    
    # argsize is 0(not send index) or 1(send index)
    argsize = code.blockes[ins[3][1]].header['misc'][:arg_size]

    minfo = MethodDefinition::RubyMethod[blab][info[0]]
    if minfo == nil then
      minfo = MethodDefinition::RubyMethod[blab][nil]
    end
    if minfo == nil then
      atype = RubyType.new(nil)
      rtype = RubyType.new(nil)
      argtype = [RubyType.new(nil), RubyType.new(nil), RubyType.new(nil)]
      if argsize == 1 then
        argtype.unshift atype
      end
      minfo = {
        :defined => false,
        :argtype => argtype,
        :self => nil,
        :rettype => rtype,
        :have_throw => nil,
        :have_yield => nil,
        :yield_argtype => nil,
        :yield_rettype => nil,
      }
      MethodDefinition::RubyMethod[blab][info[0]] = minfo
    else
      atype = minfo[:argtype][0]
      rtype = minfo[:rettype]
    end

    if argsize == 1 then
      if rec[0].type.is_a?(ComplexType) then
        rec[0].type.element_type.add_same_type atype
        # atype.add_same_type rec[0].type.element_type
      else
        rec[0].add_same_type atype
        atype.add_same_type rec[0]
      end
    end
    
    lambda {|b, context, lst, led, body, recval, excl|
      if argsize == 1 then
        if rec[0].type.is_a?(ComplexType) then
          rec[0].type.element_type.add_same_type atype
          #  atype.add_same_type rec[0].type.element_type
        else
          rec[0].add_same_type atype
          atype.add_same_type rec[0]
        end
      end
      RubyType.resolve
      
      bcond = context.builder.create_block
      bbody = context.builder.create_block
      bexit = context.builder.create_block
      lcntp = context.loop_cnt_alloca_area[loop_cnt_current]
      lstval = lst.call(b, context)
      ledval = led.call(b, context)
      b.store(lstval, lcntp)
      b.br(bcond)
      
      # loop branch
      b.set_insert_point(bcond)

      clcnt = b.load(lcntp)
      cnd = nil
      if excl then
        cnd = b.icmp_sle(clcnt, ledval)
      else
        cnd = b.icmp_slt(clcnt, ledval)
      end
      b.cond_br(cnd, bbody, bexit)
      
      b.set_insert_point(bbody)
      
      # do type specicated
      bodyrc = body.call(b, context)
      
      # invoke block
      func = minfo[:func]
      if func == nil then
#        if ispassidx then
#          argtype0 = minfo[:argtype][0]
#          recele = rec[0].type.element_type
#          argtype0.add_same_type recele
#          recele.add_same_type argtype0
#          RubyType.resolve
#        end
        
        argtype = minfo[:argtype].map {|ele|
          if ele.type == nil
            VALUE
          else
            ele.type.llvm
          end
        }
        rett = minfo[:rettype]
        rettllvm = rett.type
        if rettllvm == nil then
          rettllvm = VALUE
        else
          rettllvm = rettllvm.llvm
        end
        ftype = Type.function(rettllvm, argtype)
        func = context.builder.get_or_insert_function(recklass, blab.to_s, ftype)
      end
      fm = context.current_frame
      frame = b.bit_cast(fm, P_CHAR)
      slf = b.load(local_vars[2][:area])
      blgenfnc = nil
      if tab = @generated_code[info[0]] then
        blgenfnc = tab[blab]
      end
      if OPTION[:inline_block] and blgenfnc then
        if argsize == 1 then
          args = [[bodyrc, slf, frame, 0.llvm], code, b, context]
        else
          args = [[slf, frame, 0.llvm], code, b, context]
        end
        blgenfnc.call(args)
        @generated_code[info[0]].delete(blab)
        @generated_define_func[info[0]].delete(blab)
      else
        if argsize == 1 then
          b.call(func, bodyrc, slf, frame, 0.llvm)
        else
          b.call(func, slf, frame, 0.llvm)
        end
      end
      
      # update blocks, because make blocks
      fmlab = context.curln
      context.blocks_tail[fmlab] = bexit
      
      nclcnt = b.add(clcnt, 1.llvm)
      b.store(nclcnt, lcntp)
      b.br(bcond)
      b.set_insert_point(bexit)
      context = recval.call(b, context)
#      context.rc = 4.llvm
      context
    }
  end

  def gen_to_i_internal(recv, val, b, context)
    case recv[0].type.llvm
    when Type::DoubleTy
      return b.fp_to_si(val, MACHINE_WORD)
    when Type::Int32Ty
      return val
    else
      raise "Unsupported type #{recv[0].inspect2}"
    end
  end

  def get_raw_llvm_type(e)
    case e
    when LLVM_Struct, LLVM_Pointer, LLVM_Function,
         LLVM_Array, LLVM_Vector
      e.type
    when Array
      get_raw_llvm_type(e[0])
    else
      e
    end
  end
end

module SendUtil
  include LLVM
  include RubyHelpers

  MaxSmallPolymotphicNum = 4
  def gen_method_select(rectype, lexklass, mname)
    mtab = MethodDefinition::RubyMethod[mname].clone
    mtab.delete_if {|klass, info| 
      !info.is_a?(Hash)
    }

    recklass = nil
    if rectype then
      conftype = rectype.conflicted_types
      if conftype.size <= 1 then
        recklass = rectype.klass
      else
        mtab.delete_if {|klass, info| 
          conftype[klass] == nil
        }
      end
    end

    minfo = mtab[recklass]
    if minfo.is_a?(Hash) and minfo[:func] then
      # recklass == nil ->  functional method
      return [minfo, minfo[:func]]
    end

    # inheritance search
    obj = nil
    if recklass then
      obj = Object.nested_const_get(recklass)
    elsif lexklass and rectype == nil then
      # Search lexcal class
      obj = Object.nested_const_get(lexklass)
    end
    if obj then
      obj.ancestors.each do |sup|
        minfo = mtab[sup.name.to_sym]
        if minfo.is_a?(Hash) then
          return [minfo, minfo[:func]]
        end
      end
    end

    candidatenum = mtab.size
    if candidatenum > 1 then
      candidatenum = 0
      mtab.each {|klass, info| 
        if info[:func] then
          candidatenum += 1
        end
      }
    end
#=begin    
    funcinfo = get_inline_function(recklass, lexklass, mname)
    if funcinfo then
     return [nil, nil]
    end
#=end

    if candidatenum == 0 then
      return [nil, nil]

    elsif candidatenum == 1 then
      minfo = nil
      if recklass then
        minfo = mtab[recklass]
      else
        minfo = mtab.values[0]
      end
      if minfo.is_a?(Hash) then
        return [minfo, minfo[:func]]
      else
        return [nil, nil]
      end

    elsif candidatenum < MaxSmallPolymotphicNum then
      # TODO : Use inline hash function generation
      raise("Not implimented polymorphic methed call yet '#{mname}' #{lexklass}")

    else
      # TODO : Use cukko-hasing and inline hash function generation
      raise('Not implimented polymorphic methed call yet')
    end
  end

  def get_inline_function(recklass, lexklass, mname)
    funcinfo = nil
    if recklass then
      obj = Object.nested_const_get(recklass)
    else
      obj = Object.nested_const_get(lexklass)
    end

    if obj then
      obj.ancestors.each do |sup|
        kls = sup.name.to_sym
        if tbl = MethodDefinition::InlineMethod[kls] and
           funcinfo = tbl[mname] then
          return funcinfo
        end
      end
    end

    MethodDefinition::InlineMethod[nil][mname]
  end

  def gen_call(func, arg, b, context)
    args = []
    arg.each do |pe|
      aval = pe[1].call(b, context).rc
      args.push aval
    end

    begin
      context.rc = b.call(func, *args)
    rescue => e
      p func
      p args
      p args.size
      p e
      raise e
    end
    context
  end

  def gen_call_from_ruby(rett, rectype, mname, para, curlevel, b, context)
    if rectype and rectype.klass then
       reck = eval(rectype.klass.to_s)
    else
      reck = Object
    end

#    inst = YARV2LLVM::klass2instance(reck)

    if rectype and rectype.klass2 == Class and 
        reck.singleton_methods.include?(mname) then
      mth = reck.method(mname)
      issing = "_singleton"
      painfo =  mth.parameters
    else
      if rectype == nil or rectype.klass == rectype.klass2 then
        issing = ""
      else
        issing = "_singleton"
      end
      mth = reck.instance_method(mname)
      painfo =  mth.parameters
    end

    ftype = Type.function(VALUE, [VALUE, VALUE, P_VALUE])
    fname = 'llvm_get_method_cfunc' + issing
    ggmc = context.builder.get_or_insert_function_raw(fname, ftype)
    mid = b.ashr(mname.llvm, 8.llvm)
    fcache = add_global_variable("func_cache", VALUE, -1.llvm)
    fp = b.call(ggmc, reck.llvm, mid, fcache)

    if ::YARV2LLVM::variable_argument?(painfo) then
      ftype = Type.function(VALUE, [LONG, P_VALUE, VALUE])
      ftype = Type.pointer(ftype)
      fp = b.int_to_ptr(fp, ftype)
      initarea = context.array_alloca_area
      initarea2 =  b.gep(initarea, curlevel.llvm)
      slfexp = para.pop
      if slfexp then
        context = slfexp[1].call(b, context)
      else
        context.rc = Object.llvm
      end
      slf = context.rc
      para.each_with_index do |e, n|
        context = e[1].call(b, context)
        sptr = b.gep(initarea2, n.llvm)
        if e[0].type then
          rcvalue = e[0].type.to_value(context.rc, b, context)
        else
          rcvalue = context.rc
        end
        b.store(rcvalue, sptr)
      end

      context.rc = b.call(fp, para.size.llvm, initarea2, slf)
    else
      ftype = Type.function(VALUE, [VALUE] * para.size)
      ftype = Type.pointer(ftype)
      fp = b.int_to_ptr(fp, ftype)
      slf = para.pop
      para.unshift slf
      para2 = []
      para.each do |e|
        context = e[1].call(b, context)
        if e[0].type then
          rcvalue = e[0].type.to_value(context.rc, b, context)
        else
          rcvalue = context.rc
        end
        para2.push rcvalue
      end
      context.rc = b.call(fp, *para2)
    end
    context.rc = rett.type.from_value(context.rc, b, context)
    context
  end

  def get_block_label(lab, blk)
    (lab.to_s + '+blk+' + blk[1].to_s).to_sym
  end

  def gen_get_block_ptr(recklass, minfo, b, context)

    func2 = minfo[:func]
    if func2 == nil then
      argtype = minfo[:argtype].map {|ele|
        ele.type.llvm
      }
      rett = minfo[:rettype]
      rettllvm = rett.type
      if rettllvm == nil then
        rettllvm = VALUE
      else
        rettllvm = rettllvm.llvm
      end
      ftype = Type.function(rettllvm, argtype)
      func2 = context.builder.get_or_insert_function(recklass, blab.to_s, ftype)
    end
    context.rc = b.ptr_to_int(func2, MACHINE_WORD)
    context
  end

  def with_selfp(receiver, recklass, mname)
    if receiver then
      return receiver
    end

    if recklass then
      if MethodDefinition::RubyMethod[mname][recklass] then
        return true
      end
      obj = Object.const_get(recklass, true)
      subclasses_of(obj).each do |sub|
        if MethodDefinition::RubyMethod[mname][sub.name.to_sym] then
          return true
        end
      end

      unless obj.is_a?(Class) then
        return nil
      end
      sup = obj.superclass

      while sup.is_a?(Class) do
        if MethodDefinition::RubyMethod[mname][sup.name.to_sym] then
          return true
        end
        sup = sup.superclass
      end
    end

    nil
  end

  def gen_arg_eval(args, receiver, ins, local_vars, info, minfo, mname)
    recklass = receiver ? receiver[0].klass : nil
    blk = ins[3]
    
    para = []
    nargs = ins[2]
    args.each_with_index do |pe, n|
      if minfo then
        pe[0].add_same_type(minfo[:argtype][nargs - n - 1])
        minfo[:argtype][nargs - n - 1].add_same_value(pe[0])
        pe[0].add_extent_base minfo[:argtype][nargs - n - 1]
      end
      para[n] = pe
    end
    para.reverse!
 
    v = nil
    if receiver then
      v = receiver
      args.each do |pe|
        pe[0].slf = v[0]
      end
      if minfo and minfo[:self] then
        v[0].add_same_type minfo[:self]
        minfo[:self].add_same_type v[0]
      end
    else
      v = [local_vars[2][:type], 
        lambda {|b, context|
          context.rc = b.load(context.local_vars[2][:area])
          context}]
    end

    para.push [local_vars[2][:type], lambda {|b, context|
      context = v[1].call(b, context)
      if v[0].type then
        rc = v[0].type.to_value(context.rc, b, context)
        context.rc = rc
      end
      context
    }]

    if blk[0] then
      para.push [local_vars[0][:type], lambda {|b, context|
          #            gen_get_framaddress(@frame_struct[code], b, context)
          fm = context.current_frame
          context.rc = b.bit_cast(fm, P_CHAR)
          context
        }]
      
      blab = get_block_label(info[1], blk)

      minfoy = MethodDefinition::RubyMethod[mname][recklass]

      if minfoy and (yargt = minfoy[:yield_argtype]) then
        minfob = MethodDefinition::RubyMethod[blab][recklass]
        if minfob == nil then
          rtype = RubyType.new(nil)
          argtype = []
          yargt.each do |e|
            argtype.push RubyType.new(nil)
          end
          minfob = {
              :defined => false,
              :argtype => argtype,
              :self => nil,
              :rettype => rtype,
              :have_throw => nil,
              :have_yield => nil,
              :yield_argtype => nil,
              :yield_rettype => nil,
          }
          MethodDefinition::RubyMethod[blab][info[0]] = minfob
        end
        bargt = minfob[:argtype]
        if yargt and bargt then
          yargt.each_with_index do |pe, n|
            pe.add_same_type bargt[n]
            bargt[n].add_same_type pe
          end
        end

        brett = minfob[:rettype]
        yrett = minfoy[:yield_rettype]
        brett.add_same_type yrett
        yrett.add_same_type brett
      end

      para.push [local_vars[1][:type], 
        lambda {|b, context|
          # Send with block may break local frame, so must clear local 
          # value cache
          local_vars.each do |le|
            if le[:type].type then
              le[:type].type.content = UNDEF
            end
          end
          # receiver of block is parent class
          minfo = MethodDefinition::RubyMethod[blab][info[0]]
          gen_get_block_ptr(info[0], minfo, b, context)
        }]
    end

    para
  end
  
  def do_function(receiver, info, ins, local_vars, args, mname, curlevel)
    recklass = receiver ? receiver[0].klass : nil
    rectype = receiver ? receiver[0] : nil
    minfo, func = gen_method_select(rectype, info[0], mname)
    if minfo then
      rettype = minfo[:rettype]
      # rettype = RubyType.new(nil, info[3], "Return type of #{mname}")
      pppp "RubyMethod called #{mname.inspect}"

      para = gen_arg_eval(args, receiver, ins, local_vars, info, minfo, mname)
      if func == nil then
        level = @expstack.size
        if @array_alloca_size == nil or @array_alloca_size < 1 + level then
          @array_alloca_size = 1 + level
        end
      end
      @expstack.push [rettype,
        lambda {|b, context|
          recklass = receiver ? receiver[0].klass : nil
          minfo, func = gen_method_select(rectype, info[0], mname)

          if !with_selfp(receiver, info[0], mname) then
            para.pop
          end

          if func then
            gen_call(func, para ,b, context)
          else
#            p mname
#            p recklass
#            raise "Undefined method \"#{mname}\" in #{info[3]}"
#            rettype = minfo[:rettype]
            rectype = receiver ? receiver[0] : local_vars[2][:type]
            gen_call_from_ruby(rettype, rectype, mname, para, curlevel, b, context)
          end
        }]
      return true
    end

    false
  end

  def do_cfunction(receiver, info, ins, local_vars, args, mname)
    recklass = receiver ? receiver[0].klass : nil
    funcinfo = nil
    if MethodDefinition::CMethod[recklass] then
      funcinfo = MethodDefinition::CMethod[recklass][mname]
    end
    unless funcinfo
      funcinfo = MethodDefinition::CMethod[nil][mname]
    end

    if funcinfo then
      rettype = funcinfo[:rettype]
      argtype = funcinfo[:argtype]
      unless rettype.is_a?(RubyType) then
        rettype = RubyType.from_llvm(rettype, 
                               info[3], 
                               "return type of #{mname} in c call")
        argtype = funcinfo[:argtype].map {|ts| RubyType.from_llvm(ts, info[3], "")}
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

        para = gen_arg_eval(args, receiver, ins, local_vars, info, nil, mname)
        if send_self then
          slf = para.pop
          # Type of 'self' is unkown.
          # Here is do_cfunction, Not ruby method.
          # This is 1st argument of c function.
          slf = [RubyType.new(nil, info[3], "1st arg of #{mname}"),
                 receiver[1]]
          para.unshift slf
        else
          para.pop
        end

        para.each_with_index do |pe, n|
          argtype[n].add_same_value pe[0]
        end

        @expstack.push [rettype,
          lambda {|b, context|
            targs = []
            para.each_with_index do |pe, n|
              aval = pe[1].call(b, context).rc
              if argtype[n].type.llvm != pe[0].type.llvm then
                if pe[0].dst_type and
                   argtype[n].type.llvm == pe[0].dst_type.llvm then
                  aval = implicit_type_conversion(b, context, aval, pe[0])
                else
                  aval1 = pe[0].type.to_value(aval, b, context)
                  aval2 = argtype[n].type.from_value(aval1, b, context)
                  aval = aval2
                end
              end
              targs.push aval
            end

            context.rc = b.call(func, *targs)
            context
          }
        ]
        return true
      end
    end

    false
  end

  def do_macro(mname, _sender_env)
    macroinfo = MethodDefinition::InlineMacro[mname]
    if macroinfo then
      # print macroinfo[:body]
      eval(macroinfo[:body])
      return true
    end

    false
  end

  def do_inline_function(receiver, info, mname, env)
    recklass = receiver ? receiver[0].klass : nil
    funcinfo = get_inline_function(recklass, info[0], mname)
    if funcinfo then
      instance_exec(env, &funcinfo[:inline_proc])
      return true
    end

    false
  end
end
end

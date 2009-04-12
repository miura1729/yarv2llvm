module YARV2LLVM
module LLVMUtil
  include LLVM
  include RubyHelpers

  def get_or_create_block(ln, b, context)
    if context.blocks[ln] then
      context.blocks[ln]
    else
      context.blocks[ln] = context.builder.create_block
    end
  end
  
  def check_same_type_2arg_static(p1, p2)
    p1[0].add_same_type(p2[0])
    p2[0].add_same_type(p1[0])
  end
  
  def check_same_type_2arg_gencode(b, context, p1, p2)
    RubyType.resolve
    if p1[0].type == nil then
      if p2[0].type == nil then
        print "ambious type #{p2[1].call(b, context).org}\n"
      else
        p1[0].type = p2[0].type.dup_type
      end
    else
      if p2[0].type and p1[0].type.llvm != p2[0].type.llvm then
        print "diff type #{p1[1].call(b, context).org}(#{p1[0].inspect2}) and #{p2[1].call(b, context).org}(#{p2[0].inspect2}) \n"
      else
        p2[0].type = p1[0].type.dup_type
      end
    end
  end

  def gen_common_opt_2arg(b, context, s1, s2)
    if !UNDEF.equal?(s1[0].type.constant) and 
       !UNDEF.equal?(s2[0].type.constant) then
      return [s1[0].type.constant, s2[0].type.constant, context, true]
    end

    check_same_type_2arg_gencode(b, context, s1, s2)
    context = s1[1].call(b, context)
    s1val = context.rc
    #        pppp s1[0]
    context = s2[1].call(b, context)
    s2val = context.rc

    [[s1val, s2val], context, false]
  end

  def make_frame_struct(local_vars)
    member = []
    local_vars.each do |ele|
      if ele[:type].type then
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
          raise "Unsupported type #{val[0].inspect2} in |"
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
    blab = (info[1].to_s + '+blk+' + blk[1].to_s).to_sym
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
        :rettype => rtype
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
    
    lambda {|b, context, lst, led, body, recval|
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
      cnd = b.icmp_slt(clcnt, ledval)
      b.cond_br(cnd, bbody, bexit)
      
      b.set_insert_point(bbody)
      
      # do type specicated
      bodyrc = body.call(b, context)
      
      # invoke block
      func = minfo[:func]
      if func == nil then
        if ispassidx then
          argtype0 = minfo[:argtype][0]
          recele = rec[0].type.element_type
          argtype0.add_same_type recele
          recele.add_same_type argtype0
          RubyType.resolve
        end
        
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
      blgenfnc = @generated_code[blab]
      if OPTION[:inline_block] and blgenfnc then
        args = [b, [bodyrc, slf, frame, 0.llvm]]
        blgenfnc.call(args)
        @generated_code.delete(blab)
      else
        if argsize == 1 then
          b.call(func, bodyrc, slf, frame, 0.llvm)
        else
          b.call(func, slf, frame, 0.llvm)
        end
      end
      
      # update blocks, because make blocks
      fmlab = context.curln
      context.blocks[fmlab] = bexit
      
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
      return b.fp_to_si(val, Type::Int32Ty)
    when Type::Int32Ty
      return val
    else
      raise "Unsupported type #{recv[0].inspect2}"
    end
  end

  def get_raw_llvm_type(e)
    case e
    when LLVM_Struct, LLVM_Pointer, LLVM_Function
      e.type
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
    if recklass then
      sup = Object.nested_const_get(recklass)
      while sup do
        minfo = mtab[sup.name.to_sym]
        if minfo.is_a?(Hash) then
          return [minfo, minfo[:func]]
        end
        if sup.is_a?(Class) then
          sup = sup.superclass
        else
          break
        end
      end
    elsif lexklass then
      # Search lexcal class
      sup = Object.nested_const_get(lexklass)
      while sup do
        minfo = mtab[sup.name.to_sym]
        if minfo.is_a?(Hash) then
          return [minfo, minfo[:func]]
        end
        if sup.is_a?(Class) then
          sup = sup.superclass
        else
          break
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
      minfo = mtab.values[0]
      if minfo.is_a?(Hash) then
        return [minfo, minfo[:func]]
      else
        return [nil, nil]
      end

    elsif candidatenum < MaxSmallPolymotphicNum then
      # TODO : Use inline hash function generation
      raise("Not implimented polymorphic methed call yet '#{mname}'")

    else
      # TODO : Use cukko-hasing and inline hash function generation
      raise('Not implimented polymorphic methed call yet')
    end
  end

  def get_inline_function(recklass, lexklass, mname)
    funcinfo = nil
    if recklass and MethodDefinition::InlineMethod[recklass] then
      funcinfo = MethodDefinition::InlineMethod[recklass][mname]
    elsif MethodDefinition::InlineMethod[lexklass] then
      funcinfo = MethodDefinition::InlineMethod[lexklass][mname]
    end
    if funcinfo == nil then
      funcinfo = MethodDefinition::InlineMethod[nil][mname]
    end
    
    funcinfo
  end

  def gen_call(func, arg, b, context)
    args = []
    arg.each do |pe|
      args.push pe[1].call(b, context).rc
    end
    begin
      context.rc = b.call(func, *args)
    rescue
      p func
      p args
      raise
    end
    context
  end

=begin
  def gen_get_framaddress(fstruct, b, context)
    ftype = Type.function(P_CHAR, [Type::Int32Ty])
    func = context.builder.external_function('llvm.frameaddress', ftype)
    fraw = b.call(func, 0.llvm)

    fraw2 = b.bit_cast(fraw, fstruct)
    fraw2 = b.gep(fraw2, -1.llvm)
    fraw = b.bit_cast(fraw2, P_CHAR)
    fraw = b.gep(fraw, -4.llvm)
   
    context.rc = fraw
    context
  end
=end

  def gen_get_block_ptr(recklass, info, blk, b, context)
    blab = (info[1].to_s + '+blk+' + blk[1].to_s).to_sym
    minfo = MethodDefinition::RubyMethod[blab][recklass]

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
    blk = ins[3]
    
    para = []
    nargs = ins[2]
    args.each_with_index do |pe, n|
      if minfo then
        pe[0].add_same_type(minfo[:argtype][nargs - n - 1])
        minfo[:argtype][nargs - n - 1].add_same_value(pe[0])
      end
      para[n] = pe
    end
    para.reverse!
 
    v = nil
    if receiver then
      v = receiver
    else
      v = [local_vars[2][:type], 
        lambda {|b, context|
          context.rc = b.load(context.local_vars[2][:area])
          context}]
    end
    if with_selfp(receiver, info[0], mname) then
      para.push [local_vars[2][:type], lambda {|b, context|
          context = v[1].call(b, context)
          if v[0].type then
            rc = v[0].type.to_value(context.rc, b, context)
            context.rc = rc
          end
          context
        }]
    end
    if blk[0] then
      para.push [local_vars[0][:type], lambda {|b, context|
          #            gen_get_framaddress(@frame_struct[code], b, context)
          fm = context.current_frame
          context.rc = b.bit_cast(fm, P_CHAR)
          context
        }]
      
      para.push [local_vars[1][:type], lambda {|b, context|
          # Send with block may break local frame, so must clear local 
          # value cache
          local_vars.each do |le|
            if le[:type].type then
              le[:type].type.content = UNDEF
            end
          end
          # receiver of block is parent class
          gen_get_block_ptr(info[0], info, blk, b, context)
        }]
    end

    para
  end
end
end

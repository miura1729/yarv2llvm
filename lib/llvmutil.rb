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

  def make_frame_struct(local)
    member = []
    local.each do |ele|
      if ele[:type].type then
        member.push ele[:type].type.llvm
      else
        member.push VALUE
      end
    end
    Type.struct(member)
  end
end

module SendUtil
  include LLVM
  include RubyHelpers

  def gen_call(func, arg, b, context)
    args = []
    arg.each do |pe|
      args.push pe[1].call(b, context).rc
    end
    context.rc = b.call(func, *args)
    context
  end

  def gen_get_framaddress(b, context)
    ftype = Type.function(P_CHAR, [Type::Int32Ty])
    func = context.builder.external_function('llvm.frameaddress', ftype)
    context.rc = b.call(func, 0.llvm)
    context
  end

  def gen_get_block_ptr(info, blk, b, context)
    blab = (info[1].to_s + '_blk_' + blk[1].to_s).to_sym
    minfo = MethodDefinition::RubyMethod[blab]
    func2 = minfo[:func]
    if func2 == nil then
      argtype = minfo[:argtype].map {|ele|
        ele.type.llvm
      }
      rett = minfo[:rettype]
      ftype = Type.function(rett.type.llvm, argtype)
      func2 = context.builder.get_or_insert_function(blab.to_s, ftype)
    end
    context.rc = b.ptr_to_int(func2, MACHINE_WORD)
    context
  end
end
end

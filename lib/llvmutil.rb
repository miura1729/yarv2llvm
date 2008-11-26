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

  def gen_arg_eval(expstack, ins, local, info, minfo)
    isfunc = ((ins[4] & 8) != 0) # true: function type, false: method type
    blk = ins[3]
    
    para = []
    narg = ins[2] - 1
    0.upto(narg) do |n|
      v = @expstack.pop

      if minfo then
        v[0].add_same_type(minfo[:argtype][narg - n])
        minfo[:argtype][narg - n].add_same_value(v[0])
      end

      para[n] = v
    end
    para.reverse!
 
    v = nil
    if !isfunc then
      v = @expstack.pop
    else
      v = [local[2][:type], 
        lambda {|b, context|
          context.rc = b.load(context.local_vars[2][:area])
          context}]
    end
    para.push [local[2][:type], lambda {|b, context|
        context = v[1].call(b, context)
        if v[0].type then
          rc = v[0].type.to_value(context.rc, b, context)
          context.rc = rc
        end
        context
      }]
    if blk[0] then
      para.push [local[0][:type], lambda {|b, context|
          #            gen_get_framaddress(@frame_struct[code], b, context)
          fm = context.current_frame
          context.rc = b.bit_cast(fm, P_CHAR)
          context
        }]
      
      para.push [local[1][:type], lambda {|b, context|
          # Send with block may break local frame, so must clear local 
          # value cache
          local.each do |le|
            if le[:type].type then
              le[:type].type.content = nil
            end
          end
          gen_get_block_ptr(info, blk, b, context)
        }]
    end

    para
  end
end
end

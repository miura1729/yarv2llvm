#
#
#  Define function call of internal access of ruby
#

module LLVM::RubyInternals
  EMBEDER_FLAG = (1 << 13)
  ROBJECT_EMBED_LEN_MAX = 3
  ROBJECT = Type::struct([RBASIC, LONG, P_VALUE, P_CHAR])
end

module YARV2LLVM
module IntRuby
  include LLVM
  include RubyHelpers
  include LLVMUtil

  def gen_ivar_ptr(builder)
    ftype = Type.function(P_VALUE, [VALUE, VALUE])
    b = builder.define_function_raw('llvm_ivar_ptr', ftype)
    args = builder.arguments
    embed = builder.create_block
    nonembed = builder.create_block
    comm = builder.create_block
    rbp = Type.pointer(RBASIC)
    slfop = b.int_to_ptr(args[0], Type.pointer(ROBJECT))
    slf = b.int_to_ptr(args[0], rbp)
    slfhp = b.struct_gep(slf, 0)
    slfh = b.load(slfhp)
    isemb = b.and(slfh, EMBEDER_FLAG.llvm)
    isemb = b.icmp_ne(isemb, 0.llvm)
    b.cond_br(isemb, embed, nonembed)

    b.set_insert_point(embed)
#    elen = ROBJECT_EMBED_LEN_MAX.llvm
    eptr = b.struct_gep(slfop, 1)
    eptr = b.bit_cast(eptr, P_VALUE)
    
    b.br(comm)

    b.set_insert_point(nonembed)
#    lenp = b.struct_gep(slfop, 1)
#    nlen = b.load(lenp)
    ivpp = b.struct_gep(slfop, 2)
    nptr = b.load(ivpp)
    nptr = b.bit_cast(nptr, P_VALUE)
    b.br(comm)

    b.set_insert_point(comm)
#    len = b.phi(LONG)
#    len.add_incoming(elen, embed)
#    len.add_incoming(nlen, nonembed)
    ptr = b.phi(P_VALUE)
    ptr.add_incoming(eptr, embed)
    ptr.add_incoming(nptr, nonembed)
    ivitp = b.struct_gep(slfop, 3)
    iv_index_tbl = b.load(ivitp)

    indexp = b.alloca(VALUE, 1)

    ftype = Type.function(VALUE, [P_CHAR, VALUE, P_VALUE])
    func = builder.external_function('st_lookup', ftype)
    b.call(func, iv_index_tbl, args[1], indexp)
    
    index = b.load(indexp)
    resp = b.gep(ptr, index)
    b.return(resp)
    
  end
end
end

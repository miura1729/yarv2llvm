#
#
#  Define function call of internal access of ruby
#

module LLVM::RubyInternals
  EMBEDER_FLAG = (1 << 13)
  ROBJECT_EMBED_LEN_MAX = 3
  ROBJECT = Type::struct([RBASIC, LONG, P_VALUE, P_VALUE])
  RCLASS = Type::struct([RBASIC, P_VALUE, P_VALUE, P_VALUE])
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

    #  Embedded format
    b.set_insert_point(embed)
    eptr = b.struct_gep(slfop, 1)
    eptr = b.bit_cast(eptr, P_VALUE)

    rbasic = b.struct_gep(slfop, 0)
    klassptr = b.struct_gep(rbasic, 1)
    klass = b.load(klassptr)
    klass = b.int_to_ptr(klass, Type.pointer(RCLASS))
    ivitp = b.struct_gep(klass, 3)
    eiv_index_tbl = b.load(ivitp)
    
    b.br(comm)

    #  Not embedded format
    b.set_insert_point(nonembed)
    ivpp = b.struct_gep(slfop, 2)
    nptr = b.load(ivpp)
    nptr = b.bit_cast(nptr, P_VALUE)

    ivitp = b.struct_gep(slfop, 3)
    niv_index_tbl = b.load(ivitp)

    b.br(comm)

    b.set_insert_point(comm)
    ptr = b.phi(P_VALUE)
    ptr.add_incoming(eptr, embed)
    ptr.add_incoming(nptr, nonembed)

    iv_index_tbl = b.phi(P_VALUE)
    iv_index_tbl.add_incoming(eiv_index_tbl, embed)
    iv_index_tbl.add_incoming(niv_index_tbl, nonembed)


    indexp = b.alloca(VALUE, 1)

    ftype = Type.function(VALUE, [P_VALUE, VALUE, P_VALUE])
    func = builder.external_function('st_lookup', ftype)
    b.call(func, iv_index_tbl, args[1], indexp)
    
    index = b.load(indexp)
    resp = b.gep(ptr, index)
    b.return(resp)
    
  end
end
end

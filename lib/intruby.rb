#
#
#  Define function call of internal access of ruby
#

module LLVM::RubyInternals
  EMBEDER_FLAG = (1 << 13)
  ROBJECT_EMBED_LEN_MAX = 3
  ROBJECT = Type::struct([RBASIC, LONG, P_VALUE, P_VALUE])
  RCLASS = Type::struct([RBASIC, P_VALUE, P_VALUE, P_VALUE])

  P_LONG = Type.pointer(LONG)
  RNODE = Type::struct([LONG,   # flags 0
                        P_CHAR, # nd_file 2
                        VALUE,  # u1
                        VALUE,  # u2
                        VALUE   # u3
                       ])
  P_RNODE = Type.pointer(RNODE)
  METHOD_DEFINITION = Type::struct([LONG, # type
                                    VALUE, # original_id
                                    VALUE, # cfunc
                                    LONG   # alias_count
                                    ])
  P_METHOD_DEFINITION = Type.pointer(METHOD_DEFINITION)

  METHOD_ENTRY = Type::struct([LONG, # flag
                               LONG, # mark
                               P_METHOD_DEFINITION, # def
                               VALUE,  # called_id
                               VALUE # klass
                               ])
  P_METHOD_ENTRY = Type.pointer(METHOD_ENTRY)
  
end

module YARV2LLVM
module IntRuby
  include LLVM
  include RubyHelpers
  include LLVMUtil

  def gen_get_method_cfunc(builder)
    gen_get_method_cfunc_common(builder, false)
  end

  def gen_get_method_cfunc_singleton(builder)
    gen_get_method_cfunc_common(builder, true)
  end

  def gen_get_method_cfunc_common(builder, issing)
    ftype = Type.function(VALUE, [VALUE, VALUE, P_VALUE])
    if issing then
      fn = 'llvm_get_method_cfunc_singleton'
    else
      fn = 'llvm_get_method_cfunc'
    end
    b = builder.define_function_raw(fn, ftype)
    args = builder.arguments
    klass = args[0]
    id = args[1]
    cachep = args[2]

    cachehit = builder.create_block
    cachemiss = builder.create_block

    cache = b.load(cachep)
    ishit = b.icmp_ne(cache, -1.llvm)

    b.cond_br(ishit, cachehit, cachemiss)


    # function pointer  cache hit
    b.set_insert_point(cachehit)
    cfunc = b.load(cachep)
    b.return(cfunc)

    # function pointer cache miss get c function pointer
    b.set_insert_point(cachemiss)
    if issing then
      ftype = Type.function(VALUE, [VALUE])
      sing_class = builder.external_function('rb_singleton_class', ftype)
      klass = b.call(sing_class, klass)
    end

    ftype = Type.function(P_METHOD_ENTRY, [VALUE, VALUE])
#    rmn = builder.external_function('rb_get_method_entry', ftype)
    rmn = builder.external_function('rb_method_entry_get_without_cache', ftype)
    pme = b.call(rmn, klass, id)

    vpmdef = b.struct_gep(pme, 2)
    vmdef =b.load(vpmdef)
    pcfunc = b.struct_gep(vmdef, 2)
    cfunc = b.load(pcfunc)
    b.store(cfunc, cachep)
    b.return(cfunc)
  end

  def gen_ivar_ptr(builder)
    ftype = Type.function(P_VALUE, [VALUE, VALUE, P_VALUE])
    b = builder.define_function_raw('llvm_ivar_ptr', ftype)
    args = builder.arguments
    embed = builder.create_block
    nonembed = builder.create_block
    comm = builder.create_block
    cachehit = builder.create_block
    cachemiss = builder.create_block

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

    oldindex = b.load(args[2])
    ishit = b.icmp_ne(oldindex, -1.llvm)

    b.cond_br(ishit, cachehit, cachemiss)

    # Inline Cache hit
    b.set_insert_point(cachehit)
    index = b.load(args[2])
    resp = b.gep(ptr, index)
    b.return(resp)

    # Inline Cache Misss
    b.set_insert_point(cachemiss)


    indexp = b.alloca(VALUE, 1)

    ftype = Type.function(VALUE, [P_VALUE, VALUE, P_VALUE])
    func = builder.external_function('st_lookup', ftype)
    b.call(func, iv_index_tbl, args[1], indexp)
    
    index = b.load(indexp)
    resp = b.gep(ptr, index)

    b.store(index, args[2])
    b.return(resp)
  end
end
end

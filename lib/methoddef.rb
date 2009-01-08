require 'llvm'
# Define method type and name information
include LLVM
module YARV2LLVM
module MethodDefinition
  include LLVMUtil

  # Use ruby internal and ignor in yarv2llvm.
  SystemMethod = {
#    :"core#define_method" => 
#      {:args => 1},
#    :"core#define_singleton_method" => 
#      {:args => 1}
  }
  
  # method inline or need special process
  InlineMethod_nil =  {
    :"core#define_method" => {
      :inline_proc => 
      lambda {|para|
        # TODO redefine process
      }
    },

    :"core#define_singleton_method" => {
      :inline_proc => 
        lambda {|para|
          # TODO redefine process
        }
    },

    :require => {
      :inline_proc =>
      lambda {|para|
        fn = para[:args][0][0].name
        unless File.exist?(fn)
          nfn = fn + ".rb"
          if File.exist?(nfn) then
            fn = nfn
          end
        end
        is = RubyVM::InstructionSequence.compile( File.read(fn), fn, 1, 
              {  :peephole_optimization    => true,
                 :inline_const_cache       => false,
                 :specialized_instruction  => true,}).to_a
        iseq = VMLib::InstSeqTree.new(nil, is)
        @iseqs.push iseq
      }
    },
          
    :[]= => {
      :inline_proc => 
        lambda {|para|
          val = para[:args][0]
          idx = para[:args][1]
          arr = para[:receiver]
          RubyType.resolve
          if arr[0].type then
            val[0].add_same_value(arr[0].type.element_type)
            arr[0].type.element_type.add_same_value(val[0])
          end

          oldrescode = @rescode
          v = nil
          @rescode = lambda {|b, context|
            context = oldrescode.call(b, context)

            val[0].add_same_type(arr[0].type.element_type)
            arr[0].type.element_type.add_same_value(val[0])
            RubyType.resolve

            case arr[0].type
            when ArrayType
              ftype = Type.function(Type::VoidTy, 
                                    [VALUE, Type::Int32Ty, VALUE])
              func = context.builder.external_function('rb_ary_store', ftype)
              context = val[1].call(b, context)
              v = context.rc
              context = idx[1].call(b, context)
              i = context.rc
              context = arr[1].call(b, context)
              a = context.rc
              vval = val[0].type.to_value(v, b, context)
              b.call(func, a, i, vval)
              arr[0].type.element_content[i] = v
              context
            else
              # Todo: []= handler of other type
              raise "Unkonw type #{arr[0].type.inspect2}"
            end
          }
          @expstack.push [val[0],
            lambda {|b, context|
              context.rc = v
              context}]
      },
    },

    :to_f => {
      :inline_proc => 
        lambda {|para|
          recv = para[:receiver]
          rettype = RubyType.float(para[:info][3], 'Return type of to_f')
          @expstack.push [rettype,
            lambda {|b, context|
              context = recv[1].call(b, context)
              val = context.rc
              case recv[0].type.llvm
              when Type::DoubleTy
                context.rc = val
              when Type::Int32Ty
                context.rc = b.si_to_fp(val, Type::DoubleTy)
              else
                raise "Unsupported type #{recv[0].inspect2}"
              end
              context}]
       },
    },

    :-@ => {
      :inline_proc => 
        lambda {|para|
          recv = para[:receiver]
          @expstack.push [recv[0],
            lambda {|b, context|
              context = recv[1].call(b, context)
              val = context.rc
              case recv[0].type.llvm
              when Type::DoubleTy
                context.rc = b.sub((0.0).llvm, val)
              when Type::Int32Ty
                context.rc = b.sub(0.llvm, val)
              else
                raise "Unsupported type #{val[0].inspect2} in -@"
              end
              context}]
       },
    },

    :p => {
      :inline_proc =>
        lambda {|para|
          pterm = para[:args][0]
          @expstack.push [pterm[0], 
            lambda {|b, context|
              context = pterm[1].call(b, context)
              pobj = context.rc
              ftype = Type.function(Type::VoidTy, [VALUE])
              func = @builder.external_function('rb_p', ftype)
              b.call(func, pterm[0].type.to_value(pobj, b, context))
              context}]
        }
     },

    :print => {
      :inline_proc =>
        lambda {|para|
          info = para[:info]
          rtype = RubyType.value(info[3], "Return type of print")
          gen_call_var_args_and_self(para, 'rb_io_print', rtype,
                                     STDOUT.immediate)
        }
     },

    :puts => {
      :inline_proc =>
        lambda {|para|
          info = para[:info]
          rtype = RubyType.value(info[3], "Return type of print")
          gen_call_var_args_and_self(para, 'rb_io_puts', rtype,
                                     STDOUT.immediate)
        }
     },

    :sprintf => {
      :inline_proc =>
        lambda {|para|
          info = para[:info]
          rtype = RubyType.value(info[3], "Return type of sprint")
          fname = 'rb_f_sprintf'
          gen_call_var_args(para, 'rb_f_sprintf', rtype)
        }
     },

    :size => {
      :inline_proc => 
        lambda {|para|
          rec = para[:receiver]
          info = para[:info]
          rettype = RubyType.fixnum(info[3], "Return type of size")
          @expstack.push [rettype, 
             lambda {|b, context|
                case (rec[0].klass)
                when :Array
                  RubyType.fixnum.add_same_type rettype
                  context = rec[1].call(b, context)
                  arr = context.rc
                  context.rc = gen_array_size(b, context, arr)
                  context
                else
                  raise "Do not supported #{rec[0].inspect}"
                end
             }]
        }
    },

    :times => {
      :inline_proc =>
        lambda {|para|
          rec = para[:receiver]
          rc = nil
          rcval = lambda { rc }
          loop_cnt_current = @loop_cnt_current
          loopproc = gen_loop_proc(para)
          @expstack.push [rec[0],
             lambda {|b, context|
               lst = lambda {|b, context| 0.llvm}
               led = lambda {|b, context|
                 context = rec[1].call(b, context)
                 rc = context.rc
               }
               body = lambda {|b, context|
                 lcntp = context.loop_cnt_alloca_area[loop_cnt_current]
                 rc = b.load(lcntp)
               }
               loopproc.call(b, context, lst, led, body, rcval)
             }]
      }
    },

    :each => {
      :inline_proc =>
        lambda {|para|
          rec = para[:receiver]
          rc = nil
          rcval = lambda { rc }
          loop_cnt_current = @loop_cnt_current
          loopproc = gen_loop_proc(para)
          @expstack.push [rec[0],
             lambda {|b, context|
                case (rec[0].klass)
                when :Array
                  lst = lambda {|b, context| 0.llvm}
                  led = lambda {|b, context|
                    context = rec[1].call(b, context)
                    rc = context.rc
                    gen_array_size(b, context, rc)
                  }
                  body = lambda {|b, context|
                    lcntp = context.loop_cnt_alloca_area[loop_cnt_current]
                    idxp = b.load(lcntp)
                    ftype = Type.function(VALUE, [VALUE, Type::Int32Ty])
                    func = context.builder.external_function('rb_ary_entry', ftype)
                    av = b.call(func, rc, idxp)
                    arrelet = rec[0].type.element_type.type
                    arrelet.from_value(av, b, context)
                  }
                  loopproc.call(b, context, lst, led, body, rcval)

                when :Range
                  lst = lambda {|b, context|
                    context = rec[1].call(b, context)
                    rc = context.rc
                    fstt = rec[0].type.first
                    if fstt.type.constant then
                      fstt.type.constant
                    else
                      rc
                    end
                  }
                  led = lambda {|b, context|
                    lstt = rec[0].type.last
                    if lstt.type.constant then
                      rc = lstt.type.constant
                    else
                      rc = lstt.name.llvm
                    end
                  }
                  body = lambda {|b, context|
                    lcntp = context.loop_cnt_alloca_area[loop_cnt_current]
                    b.load(lcntp)
                  }

                  loopproc.call(b, context, lst, led, body, rcval)
                  
                else
                  raise "Do not supported #{rec[0].inspect}"
                end
            }]
      }
    },

    :new => {
       :inline_proc =>
         lambda {|para|
           rec = para[:receiver]
           args = para[:args]
           nargs = args.size
           if nargs != 0 then
             arraycurlevel = @expstack.size
             if  @array_alloca_size == nil or 
                 @array_alloca_size < nargs +  arraycurlevel then
                @array_alloca_size = nargs + arraycurlevel
             end
           end
           # This rb_class_new_instance needs stack area as arguments
           # in spite of with no arguments.
           if @array_alloca_size == nil then
             @array_alloca_size = 1
           end
           rettype = RubyType.from_sym(rec[0].klass, para[:info][3], nil)
           @expstack.push [rettype, 
             lambda {|b, context|
               cargs = []
               context = rec[1].call(b, context)
               recv = context.rc

               initarea = context.array_alloca_area
               initarea2 =  b.gep(initarea, arraycurlevel.llvm)
               args.each_with_index do |ele, n|
                 context = ele[1].call(b, context)
                 rcvalue = ele[0].type.to_value(context.rc, b, context)
                 sptr = b.gep(initarea2, n.llvm)
                 b.store(rcvalue, sptr)
               end
               ftype = Type.function(VALUE, [Type::Int32Ty, P_VALUE, VALUE])
               fname = 'rb_class_new_instance'
               builder = context.builder
               func = builder.external_function(fname, ftype)
               context.rc = b.call(func, nargs.llvm, initarea2, recv)
               context}]
         }
     },

    :get_interval_cycle => {
      :inline_proc =>
        lambda {|para|
          info = para[:info]
          rettype = RubyType.fixnum(info[3], "Return type of gen_interval_cycle")
          glno = add_global_variable("interval_cycle", 
                                     Type::Int64Ty, 
                                     0.llvm(Type::Int64Ty))
          @expstack.push [rettype,
            lambda {|b, context|
              prevvalp = context.builder.global_variable
              prevvalp = b.struct_gep(prevvalp, glno)
              prevval = b.load(prevvalp)
              ftype = Type.function(Type::Int64Ty, [])
              fname = 'llvm.readcyclecounter'
              func = context.builder.external_function(fname, ftype)
              curval = b.call(func)
              diffval = b.sub(curval, prevval)
              rc = b.trunc(diffval, Type::Int32Ty)
              b.store(curval, prevvalp)
              context.rc = rc
              context
            }]
      }
    }
  }

  InlineMethod_Thread = {
    :new => {
      :inline_proc => lambda {|para|
        info = para[:info]
        ins = para[:ins]
        blk = ins[3]
        local_vars = para[:local]
        nargs = 3
        arraycurlevel = @expstack.size
        if  @array_alloca_size == nil or 
            @array_alloca_size < nargs +  arraycurlevel then
          @array_alloca_size = nargs + arraycurlevel
        end

        rettype = RubyType.value(para[:info][3], "Return type of Thread.new")
        @expstack.push [rettype, 
          lambda {|b, context|
             initarea = context.array_alloca_area
             initarea2 =  b.gep(initarea, arraycurlevel.llvm)
             slfarea = b.gep(initarea2, 0.llvm)
             slfval = b.load(local_vars[2][:area])
             b.store(slfval, slfarea)
             framearea = b.gep(initarea2, 1.llvm)
             frameval = b.load(local_vars[0][:area])
             frameval = b.ptr_to_int(frameval, VALUE)
             b.store(frameval, framearea)
             blkarea = b.gep(initarea2, 2.llvm)
             b.store(0.llvm, blkarea)
             context = gen_get_block_ptr(info[0], info, blk, b, context)
             blkptr = context.rc

             ftype = Type.function(VALUE, [VALUE, P_VALUE])
             fname = 'rb_thread_create'
             func = context.builder.external_function(fname, ftype)
             context.rc = b.call(func, blkptr, initarea2)

             context}]
      }
    },
  }
        

  InlineMethod = {
    nil => InlineMethod_nil,
    :Thread => InlineMethod_Thread,
  }

  
  # can be maped to C function
  CMethod = {
    :Math => {
      :sqrt => 
        {:rettype => Type::DoubleTy,
         :argtype => [Type::DoubleTy],
         :send_self => false,
         :cname => "llvm.sqrt.f64"},
      :sin => 
        {:rettype => Type::DoubleTy,
         :argtype => [Type::DoubleTy],
         :send_self => false,
         :cname => "llvm.sin.f64"},
      :cos => 
        {:rettype => Type::DoubleTy,
         :argtype => [Type::DoubleTy],
         :send_self => false,
         :cname => "llvm.cos.f64"},
     },

    :Float => {
      :** =>
        {:rettype => Type::DoubleTy,
         :argtype => [Type::DoubleTy, Type::DoubleTy],
         :send_self => true,
         :cname => "pow"}
    },

    :Process => {
      :times => 
        {:rettype => RubyType.struct(nil, nil),
         :argtype => [RubyType.value(nil, nil, Process)],
         :send_self => true,
         :cname => "rb_proc_times"},
    },
  }

  # definition by yarv2llvm and arg/return type is C type (int, float, ...)
  RubyMethod =Hash.new {|hash, key| hash[key] = {}}

  # stub for RubyCMethod. arg/return type is always VALUE
  RubyMethodStub = {}
end
end
  

require 'llvm'
# Define method type and name information compatible with CRuby
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
          
    :dup => {
      :inline_proc =>
        lambda {|para|
          info = para[:info]
          rec = para[:receiver]

          @expstack.push [rec[0], 
            lambda {|b, context|
              context = rec[1].call(b, context)
              recobj = context.rc
              ftype = Type.function(VALUE, [VALUE])
              func = @builder.external_function('rb_obj_dup', ftype)
              context.rc = b.call(func, recobj)
              context}]
        }
     },

    :clone => {
      :inline_proc =>
        lambda {|para|
          info = para[:info]
          rec = para[:receiver]

          @expstack.push [rec[0], 
            lambda {|b, context|
              context = rec[1].call(b, context)
              recobj = context.rc
              ftype = Type.function(VALUE, [VALUE])
              func = @builder.external_function('rb_obj_clone', ftype)
              context.rc = b.call(func, recobj)
              context}]
        }
     },

    :[]= => {
      :inline_proc => 
        lambda {|para|
          val = para[:args][0]
          idx = para[:args][1]
          arr = para[:receiver]
          RubyType.resolve
          if arr[0].type.is_a?(ArrayType)  then
            val[0].add_same_type(arr[0].type.element_type)
            arr[0].type.element_type.add_same_type(val[0])
          end
          val[0].add_extent_base arr[0]

          oldrescode = @rescode
          v = nil
          @rescode = lambda {|b, context|
            context = oldrescode.call(b, context)

            case arr[0].type
            when ArrayType
              val[0].add_same_type(arr[0].type.element_type)
              arr[0].type.element_type.add_same_type(val[0])
              RubyType.resolve
              ftype = Type.function(Type::VoidTy, 
                                    [VALUE, MACHINE_WORD, VALUE])
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
            when HashType
#              val[0].add_same_type(arr[0].type.element_type)
#              arr[0].type.element_type.add_same_type(val[0])
              RubyType.resolve
              ftype = Type.function(Type::VoidTy, 
                                    [VALUE, VALUE, VALUE])
              func = context.builder.external_function('rb_hash_aset', ftype)
              context = val[1].call(b, context)
              v = context.rc
              context = idx[1].call(b, context)
              i = context.rc
              context = arr[1].call(b, context)
              a = context.rc
              vval = val[0].type.to_value(v, b, context)
              ival = idx[0].type.to_value(i, b, context)
              b.call(func, a, ival, vval)
              arr[0].type.element_content[i] = v
              context

            when UnsafeType
              context = val[1].call(b, context)
              v = context.rc
              context = arr[1].call(b, context)
              arrp = context.rc
              context = idx[1].call(b, context)
              case arr[0].type.type
              when LLVM_Pointer, LLVM_Array, LLVM_Vector
                idxp = context.rc
                addr = b.gep(arrp, idxp)
                b.store(v, addr)
                context.rc = v

              when LLVM_Struct
                rindx = idx[0].type.constant
                indx = rindx
                if rindx.is_a?(Symbol) then
                  unless indx = arr[0].type.type.index_symbol[rindx]
                    raise "Unkown tag #{rindx}"
                  end
                end
                addr = b.struct_gep(arrp, indx)
                b.store(v, addr)
                context.rc = v
                
              else
                p arr[0].type
                p para[:info]
                p idx[0].type.constant
                raise "Unsupport type #{arr[0].type.type}"
              end
              context

            else
              # Todo: []= handler of other type
              p arr[0]
              p para[:info]
              p idx[0].type.constant
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

    :to_i => {
      :inline_proc => 
        lambda {|para|
          recv = para[:receiver]
          rettype = RubyType.fixnum(para[:info][3], 'Return type of to_i')
          @expstack.push [rettype,
            lambda {|b, context|
              context = recv[1].call(b, context)
              val = context.rc
              context.rc = gen_to_i_internal(recv, val, b, context)
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

    :rand => {
      :inline_proc => 
        lambda {|para|
          info = para[:info]
          @expstack.push [RubyType.float(info[3], "Return type of rand"),
            lambda {|b, context|
              ftype = Type.function(Type::DoubleTy, [])
              func = @builder.external_function('rb_genrand_real', ftype)
              context.rc = b.call(func)
              context}]
       },
    },

    :| => {
      :inline_proc => 
        lambda {|para|
          gen_binary_operator(para, 
            lambda {|v1, v2, b, context|
              b.or(v1, v2)
            })
        },
    },

    :& => {
      :inline_proc => 
        lambda {|para|
          gen_binary_operator(para, 
            lambda {|v1, v2, b, context|
              b.and(v1, v2)
            })
        },
    },

    :sleep => {
      :inline_proc =>
        lambda {|para|
          pterm = para[:args][0]
          @expstack.push [pterm[0], 
            lambda {|b, context|
              context = pterm[1].call(b, context)
              sec = context.rc
              sec = gen_to_i_internal(pterm, sec, b, context)
              ftype = Type.function(Type::VoidTy, [MACHINE_WORD])
              func = @builder.external_function('rb_thread_sleep', ftype)
              b.call(func, sec)
              context}]
        }
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
          stdout = para[:receiver]
          if stdout == nil or stdout[0].klass == :NilClass then
            stdout = [nil, lambda {|b, context| 
                             context.rc = STDOUT.immediate
                             context}]
          end
          gen_call_var_args_and_self(para, 'rb_io_print', rtype, stdout)
        }
     },

    :puts => {
      :inline_proc =>
        lambda {|para|
          info = para[:info]
          rtype = RubyType.value(info[3], "Return type of print")
          stdout = para[:receiver]
          if stdout == nil or stdout[0].klass == :NilClass then
            stdout = [nil, lambda {|b, context| 
                            context.rc = STDOUT.immediate
                            context}]
          end
          gen_call_var_args_and_self(para, 'rb_io_puts', rtype,
                                     stdout)
        }
     },

    :sprintf => {
      :inline_proc =>
        lambda {|para|
          info = para[:info]
          rtype = RubyType.value(info[3], "Return type of sprintf")
          gen_call_var_args(para, 'rb_f_sprintf', rtype)
        }
     },

    :printf => {
      :inline_proc =>
        lambda {|para|
          info = para[:info]
          rec = para[:receiver]
          rtype = RubyType.value(info[3], "Return type of printf")
          stdout = para[:receiver]
          if stdout == nil or stdout[0].klass == :NilClass then
            stdout = [nil, lambda {|b, context| 
                             context.rc = STDOUT.immediate
                             context}]
          end
          gen_call_var_args_and_self(para, 'rb_io_printf', rtype, stdout)
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
          loop_cnt_current = @loop_cnt_current
          loopproc = gen_loop_proc(para)
          rcval = lambda {|b, context| rec[1].call(b, context) }
          @expstack.push [rec[0],
             lambda {|b, context|
               lst = lambda {|b, context| 0.llvm}
               led = lambda {|b, context|
                 context = rec[1].call(b, context)
                 rc = context.rc
                 if rec[0].type.llvm == VALUE then
                   rc = b.ashr(rc, 1.llvm)
                   context.rc = rc
                 end
                 rc
               }
               body = lambda {|b, context|
                 lcntp = context.loop_cnt_alloca_area[loop_cnt_current]
                 rc = b.load(lcntp)
               }
               context = loopproc.call(b, context, lst, led, body, rcval, false)
             }]
      }
    },

    :each => {
      :inline_proc =>
        lambda {|para|
          rec = para[:receiver]
          rc = nil
          loop_cnt_current = @loop_cnt_current
          loopproc = gen_loop_proc(para)
          rcval = lambda {|b, context| rec[1].call(b, context) }
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
                    ftype = Type.function(VALUE, [VALUE, MACHINE_WORD])
                    func = context.builder.external_function('rb_ary_entry', ftype)
                    av = b.call(func, rc, idxp)
                    arrelet = rec[0].type.element_type.type
                    if arrelet
                      arrelet.from_value(av, b, context)
                    else
                      av
                    end
                  }
                  context = loopproc.call(b, context, 
                                          lst, led, body, rcval, false)
                  context

                when :Range
                  lst = lambda {|b, context|
                    context = rec[1].call(b, context)
                    rc = context.rc
                    fstt = rec[0].type.first
                    if !UNDEF.equal?(fstt.type.constant) then
                      fstt.type.constant
                    else
                      rc
                    end
                  }
                  led = lambda {|b, context|
                    lstt = rec[0].type.last
                    res = nil
                    if !UNDEF.equal?(lstt.type.constant) then
                      res = lstt.type.constant
                    else
                      res = lstt.name.llvm
                    end

                    res
                  }
                  body = lambda {|b, context|
                    lcntp = context.loop_cnt_alloca_area[loop_cnt_current]
                    b.load(lcntp)
                  }

                  excl = rec[0].type.excl
                  context = loopproc.call(b, context, 
                                          lst, led, body, rcval, excl)
                  context
                  
                else
                  raise "Do not supported #{rec[0].inspect2}"
                end
            }]
      }
    },

    :new => {
       :inline_proc =>
         lambda {|para|
           rec = para[:receiver]
           args = para[:args].reverse
           nargs = args.size
           arraycurlevel = 0
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
           rettype = RubyType.from_sym(rec[0].klass, para[:info][3], rec[0].klass)
#=begin
           recklass = rec[0].klass
           minfo = MethodDefinition::RubyMethod[:initialize][recklass] 
           unless minfo.is_a?(Hash)
             minfo = {}
             MethodDefinition::RubyMethod[:initialize][recklass] = minfo
             minfo[:argtype] = []
#             (args.size + 1).times {|i|
#               minfo[:argtype][i] = RubyType.new(nil)
#             }
             minfo[:argtype][args.size] = RubyType.new(nil)
             minfo[:rettype] = RubyType.new(nil)
             minfo[:defined] = false
           end

           args.each_with_index do |ele, i|
             if minfo[:argtype][i] == nil then
               minfo[:argtype][i] = RubyType.new(nil)
             end
             minfo[:argtype][i].add_same_type ele[0]
             ele[0].add_same_type minfo[:argtype][i]
             ele[0].add_extent_base minfo[:argtype][i]
             ele[0].slf = rettype
           end
#           minfo[:argtype][-1].add_same_type rec[0]
           rec[0].add_same_type minfo[:argtype][-1]
#=end

           @expstack.push [rettype, 
             lambda {|b, context|
             # print "#{para[:info][1]} #{rettype.name} -> #{rettype.real_extent}\n"
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

    :include => {
      :inline_proc =>
        lambda {|para|
          dstklass = para[:info][0]
          src = para[:args][0]
          srcklass = src[0].klass
          MethodDefinition::RubyMethod.each do |method, klasstab|
            if klasstab[dstklass] == nil and klasstab[srcklass] then
              klasstab[dstklass] = klasstab[srcklass]
            end
          end

          if srccont = MethodDefinition::InlineMethod[srcklass] then
            if dstcont = MethodDefinition::InlineMethod[dstklass] then
              dstcont.merge!(srccont)
            else
              MethodDefinition::InlineMethod[dstklass] = srccont.clone
            end
          end

          if srccont = MethodDefinition::CMethod[srcklass] then
            if dstcont = MethodDefinition::CMethod[dstklass] then
              dstcont.merge!(srccont)
            else
              MethodDefinition::CMethod[dstklass] = srccont.clone
            end
          end
      }
    },

    :first => {
      :inline_proc => 
        lambda {|para|
          info = para[:info]
          rec = para[:receiver]
          rett = RubyType.value(info[3])

          level = @expstack.size
          if @array_alloca_size == nil or @array_alloca_size < 1 + level then
            @array_alloca_size = 1 + level
          end

          @expstack.push [rett, 
            lambda {|b, context|
              context = gen_call_from_ruby(rett, rec[0], :first, [rec], level, 
                                           b, context)
              context}]
      }
    },

    :reverse => {
      :inline_proc => 
        lambda {|para|
          info = para[:info]
          rec = para[:receiver]
          rett = RubyType.array(info[3])

          level = @expstack.size
          if @array_alloca_size == nil or @array_alloca_size < 1 + level then
            @array_alloca_size = 1 + level
          end

          @expstack.push [rett, 
            lambda {|b, context|
              context = gen_call_from_ruby(rett, rec[0], :reverse, [rec], level, 
                                           b, context)
              context}]
      }
    },

    :slice! => {
      :inline_proc => 
        lambda {|para|
          info = para[:info]
          rec = para[:receiver]
          args = para[:args]
          rett = RubyType.array(info[3], "return type of slice!")

          level = @expstack.size
          if @array_alloca_size == nil or @array_alloca_size < 3 + level then
            @array_alloca_size = 3 + level
          end

          @expstack.push [rett, 
            lambda {|b, context|
              pvec = [args[1], args[0], rec]
              context = gen_call_from_ruby(rett, rec[0], :slice!, pvec, level, 
                                           b, context)
              context}]
      }
    },


    :at => {
      :inline_proc => 
        lambda {|para|
          info = para[:info]
          rec = para[:receiver]
          args = para[:args]
          rett = RubyType.new(nil, info[3], "return type of at")
          arr = RubyType.array
          arr.add_same_type rec[0]
          arr.type.element_type.add_same_type rett

          level = @expstack.size
          if @array_alloca_size == nil or @array_alloca_size < 3 + level then
            @array_alloca_size = 3 + level
          end

          @expstack.push [rett,
            lambda {|b, context|
              pvec = [args[0], rec]
              context = gen_call_from_ruby(rett, rec[0], :at, pvec, level, 
                                           b, context)
              context}]
      }
    },
  }

  InlineMethod_Enumerable = {
    :to_a => {
      :inline_proc => 
        lambda {|para|
          info = para[:info]
          rec = para[:receiver]
          rett = RubyType.array(info[3])

          level = @expstack.size
          if @array_alloca_size == nil or @array_alloca_size < 1 + level then
            @array_alloca_size = 1 + level
          end

          @expstack.push [rett, 
            lambda {|b, context|
              context = gen_call_from_ruby(rett, rec[0], :to_a, [rec], level, 
                                           b, context)
              context}]
      }
    },

  }

  InlineMethod_Array = {
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

        rettype = RubyType.value(info[3], "Return type of Thread.new", Thread)
        @expstack.push [rettype, 
          lambda {|b, context|
             initarea = context.array_alloca_area
             initarea2 =  b.gep(initarea, arraycurlevel.llvm)
             slfarea = b.gep(initarea2, 0.llvm)
             slfval = b.load(local_vars[2][:area])
             b.store(slfval, slfarea)
             framearea = b.gep(initarea2, 1.llvm)
             frameval = context.current_frame
             frameval = b.ptr_to_int(frameval, VALUE)
             b.store(frameval, framearea)
             blkarea = b.gep(initarea2, 2.llvm)
             b.store(0.llvm, blkarea)
 
             blab = get_block_label(info[1], blk)
             minfo = MethodDefinition::RubyMethod[blab][info[0]] 
             context = gen_get_block_ptr(info[0], minfo, b, context)
             blkptr = context.rc

             ftype = Type.function(VALUE, [VALUE, VALUE, VALUE])

#             fname = 'y2l_create_thread'
             fname = 'rb_thread_create'

             builder = context.builder

#             func = builder.get_or_insert_function(:Runtime, fname, ftype)
             func = builder.external_function(fname, ftype)

             blab = (info[1].to_s + '+blk+' + blk[1].to_s).to_sym
             stfubc = builder.make_callbackstub(info[0], blab.to_s, 
                                                rettype, para[:args], blkptr)
             stfubc = b.ptr_to_int(stfubc, VALUE)
             argv = b.ptr_to_int(initarea2, VALUE)
             context.rc = b.call(func, stfubc, argv, nil.llvm)

             context}]
      }
    },

    :current => {
      :inline_proc => lambda {|para|
        info = para[:info]
        rettype = RubyType.value(info[3], "Thread object", Thread)
        @expstack.push [rettype, 
          lambda {|b, context|
            ftype = Type.function(VALUE, [])
            fname = 'rb_thread_current'
            builder = context.builder
            func = builder.external_function(fname, ftype)
            context.rc = b.call(func)
            context
        }],
      }
    },

    :pass => {
      :inline_proc => lambda {|para|
        info = para[:info]
        rettype = RubyType.value(info[3], "nil")
        @expstack.push [rettype, 
          lambda {|b, context|
            ftype = Type.function(Type::VoidTy, [])
            fname = 'rb_thread_schedule'
            builder = context.builder
            func = builder.external_function(fname, ftype)
            b.call(func)
            context.rc = 4.llvm
            context
        }]
      }
    },
  }
        

  InlineMethod = {
    nil => InlineMethod_nil,
    :Thread => InlineMethod_Thread,
    :Enumerable => InlineMethod_Enumerable,
    :Array => InlineMethod_Array,
  }

  InlineMacro = {
  }
  
  # can be maped to C function
  CMethod = {
    # For define_external_function
    nil => {}, 

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
      :tan => 
        {:rettype => Type::DoubleTy,
         :argtype => [Type::DoubleTy],
         :send_self => false,
         :cname => "llvm.tan.f64"},
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
  RubyMethod = Hash.new {|hash, key| hash[key] = {}}

  # stub for RubyCMethod. arg/return type is always VALUE
  RubyMethodStub = Hash.new {|hash, key| hash[key] = {}}

  RubyMethodCallbackStub = Hash.new {|hash, key| hash[key] = {}}
end
end
  

#!/bin/ruby 
#
#  Type information class of Ruby or llvm
#

module YARV2LLVM
  include LLVM

class RubyType
  include LLVM
  include RubyHelpers

  @@type_table = []
  def initialize(type, name = nil)
    @name = name
    if type == nil 
      @type = nil
    elsif type.is_a?(ComplexType) then
      @type = type
    else
      @type = PrimitiveType.new(type)
    end
    @resolveed = false
    @same_type = []
    @@type_table.push self
  end

  def inspect2
    if @type then
      @type.inspect2
    else
      'nil'
    end
  end

  attr_accessor :type
  attr_accessor :resolveed
  attr :name

  def add_same_type(type)
    @same_type.push type
  end

  def self.resolve
    @@type_table.each do |ty|
      ty.resolveed = false
    end

    @@type_table.each do |ty|
      ty.resolve
    end
  end

  def resolve
    if @resolveed then
      return
    end

    if @type then
      @resolveed = true
      @same_type.each do |ty|
        if ty.type and ty.type.llvm != @type.llvm then
          raise "Type error #{ty.name}(#{ty.type.inspect2}) and #{@name}(#{@type.inspect2})"
        else
          ty.type = @type
          ty.resolve
        end
      end
    end
  end

  def self.fixnum
    RubyType.new(Type::Int32Ty)
  end

  def self.float
    RubyType.new(Type::DoubleTy)
  end

  def self.symbol
    RubyType.new(VALUE)
  end

  def self.typeof(obj)
    case obj
    when Fixnum
      RubyType.fixnum

    when Float
      RubyType.float

    when Symbol
      RubyType.symbol

    else
      raise "Unsupported type #{obj}"
    end
  end
end

class PrimitiveType
  include LLVM
  include RubyHelpers

  def initialize(type)
    @type = type
  end

  TYPE_HANDLER = {
    Type::Int32Ty =>
      {:inspect => "Int32Ty",

       :to_value => lambda {|val, b, context|
         x = b.shl(val, 1.llvm)
         b.or(FIXNUM_FLAG, x)
       },

       :from_value => lambda {|val, b, context|
         x = b.lshr(val, 1.llvm)
       },
      },

    Type::DoubleTy =>
      {:inspect => "DoubleTy",

       :to_value => lambda {|val, b, context|
        atype = [Type::DoubleTy]
        ftype = Type.function(VALUE, atype)
        func = context.builder.external_function('rb_float_new', ftype)
        b.call(func, val)
       },

       :from_value => lambda {|val, b, context|
        val_ptr = b.int_to_ptr(val, P_RFLOAT)
        dp = b.struct_gep(val_ptr, 1)
        b.load(dp)
       },
      },

    VALUE =>
      {:inspect => "VALUE",

       :to_value => lambda {|val, b, context|
        val
       },

       :from_value => lambda {|val, b, context|
        val
       },
      },
  }

  def to_value(val, b, context)
    TYPE_HANDLER[@type][:to_value].call(val, b, context)
  end

  def from_value(val, b, context)
    TYPE_HANDLER[@type][:from_value].call(val, b, context)
  end

  def inspect2
    if rc = TYPE_HANDLER[@type] then
      rc[:inspect]
    else
      self.inspect
    end
  end

  def llvm
    @type
  end
end

class ComplexType
  def to_value(val, b, context)
    val
  end

  def from_value(val, b, context)
    val
  end
end

class ArrayType<ComplexType
  include LLVM
  include RubyHelpers

  def initialize(etype)
    @element_type = RubyType.new(etype)
  end
  attr :element_type

  def inspect2
    if @element_type then
      "Array of #{@element_type.inspect2}"
    else
      "Array of nil"
    end
  end

  def llvm
    VALUE
  end
end
end

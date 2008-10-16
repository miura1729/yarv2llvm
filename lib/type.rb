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
          raise "Type error #{ty.name}(#{ty.type}) and #{@name}(#{@type})"
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
    RubyType.new(Type::FloatTy)
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
  def initialize(type)
    @type = type
  end

  def inspect2
    case @type
    when Type::Int32Ty
      "Int32Ty"
    when Type::FloatTy
      "FloatTy"
    when Type::VALUE
      "VALUE"
    else
      @type.inspect2
    end
  end

  def llvm
    @type
  end
end

class ComplexType
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

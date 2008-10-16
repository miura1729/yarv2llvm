#!/bin/ruby 
#
#  Type information class of Ruby or llvm
#

module YARV2LLVM
  include LLVM

class RubyType
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
    RubyType.new(RubyInternals::VALUE)
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

  def llvm
    @type
  end
end

class ComplexType
end

class ArrayType<ComplexType
  def initialize(etype)
    @element_type = RubyType.new(etype)
  end
  attr :element_type

  def llvm
    RubyInternals::P_VALUE
  end
end
end

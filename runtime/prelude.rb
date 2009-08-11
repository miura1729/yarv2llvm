# 

YARV2LLVM::define_macro :attr_reader do |arg|
  arg.each do |argele|
    name = argele[0].type.constant
    `def #{name}; @#{name}; end`
  end
end

YARV2LLVM::define_macro :attr do |arg|
  arg.each do |argele|
    name = argele[0].type.constant
    `def #{name}; @#{name}; end`
  end
end


YARV2LLVM::define_macro :attr_accessor do |arg|
  arg.each do |argele|
    name = argele[0].type.constant
    `def #{name}=(val); @#{name} = (val); end;def #{name}; @#{name}; end`
  end
end

YARV2LLVM::define_macro :foobar do |arg|
end

=begin
class Fixnum
  def step(ed, st)
    i = self
    while i * st < ed * st do
      yield i
      i = i + st
    end
  end
end

class Array
  def at(i)
    self[i]
  end
end
=end

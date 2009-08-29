module YARV2LLVM
#=begin

  # type definition of method

  MethodDefinition::RubyMethod[:open][:File] = {
    :argtype => [RubyType.string, RubyType.string],
    :rettype => RubyType.value(nil, "Return type of File#open", IO),
  }

  MethodDefinition::RubyMethod[:read][:IO] = {
    :argtype => [RubyType.fixnum],
    :rettype => RubyType.string(nil, "Return type of File#read"),
  }

  MethodDefinition::RubyMethod[:gets][:IO] = {
    :argtype => [],
    :rettype => RubyType.string(nil, "Return type of File#gets"),
  }

  MethodDefinition::RubyMethod[:count][:String] = {
    :argtype => [RubyType.string],
    :rettype => RubyType.fixnum(nil, "Return type of String#count"),
  }

  rt = RubyType.array(nil, "Return type of String#unpack")
  MethodDefinition::RubyMethod[:unpack][:String] = {
    :argtype => [RubyType.string],
    :rettype => rt,
  }

  st = RubyType.array
  rt = RubyType.array
  rt.add_same_type(st)
  st.add_same_type(rt)
  MethodDefinition::RubyMethod[:[]][:Array] = {
    :self => st,
    :argtype => [RubyType.new(nil), RubyType.new(nil)],
    :rettype => rt,
  }

#=end
end

<<-'EOS'
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

class Fixnum
  def upto(ed)
    i = self
    while i <= ed do
      yield i
      i = i + 1
    end
  end

  def downto(ed)
    i = self
    while i >= ed do
      yield i
      i = i - 1
    end
  end

  def step(ed, st)
    i = self
    if st > 0 then
      while i <= ed do
        yield i
        i = i + st
      end
    else
      while ed <= i do
        yield i
        i = i + st
      end
    end
  end

  def **(n)
    i = self
    r = 1
    n.times do
     r = r * i
    end
    r
  end
end

class Array
  def collect
    res = []
    i = 0
    self.each do |e|
      res[i] = yield e
      i = i + 1
    end

    res
  end
end

class Range
  def collect
    res = []
    i = 0
    self.each do |e|
      res[i] = yield e
      i = i + 1
    end

    res
  end
end
EOS


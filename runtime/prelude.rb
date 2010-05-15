module YARV2LLVM

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

  MethodDefinition::RubyMethod[:unpack][:String] = {
    :argtype => [RubyType.string],
    :rettype => nil,
    :copy_rettype => lambda { |rect, argt|
      rt = RubyType.array(nil, "Return type of String#unpack")
      fmt = argt[0].content
      if !UNDEF.equal?(fmt) then
        fmt.each_char do |ch|
          case ch
          when 'c', 'C', 's', 'S', 'i', 'I', 'l', 'L', 'n', 'N', 'v', 'V'
            RubyType.fixnum.add_same_type(rt.type.element_type)

          when 'a', 'A', 'Z', 'b', 'B', 'h', 'H', 'm', 'M', 'u', 'U', 'w'
            RubyType.string.add_same_type(rt.type.element_type)

          when 'f', 'd', 'e', 'E', 'g', 'G'
            RubyType.float.add_same_type(rt.type.element_type)
          end
        end
      end
      rt
    }
  }

  st = RubyType.array
  rt = RubyType.array
  rt.add_same_type(st)
  st.add_same_type(rt)
  MethodDefinition::RubyMethod[:[]][:Array] = {
    :self => st,
    :argtype => [RubyType.new(nil), RubyType.new(nil)],
    :rettype => rt,
    :copy_rettype => true,
  }

  MethodDefinition::RubyMethod[:at][:Array] = {
    :self => nil,
    :argtype => [RubyType.new(nil)],
    :rettype => nil,
    :copy_rettype => lambda { |rect, argt|
      rt = RubyType.new(nil, "", "return type of at")
      arr = RubyType.array
      arr.add_same_type(rect)
      arr.type.element_type.add_same_type(rt)
      rt
    },
  }

  st = RubyType.array
  rt = RubyType.new(nil)
  rt.add_same_type(st.type.element_type)
  st.type.element_type.add_same_type(rt)
  MethodDefinition::RubyMethod[:first][:Array] = {
    :self => st,
    :argtype => [],
    :rettype => rt,
    :copy_rettype => true,
  }

  st = RubyType.array
  rt = RubyType.array
  rt.add_same_type(st)
  st.add_same_type(rt)
  MethodDefinition::RubyMethod[:reverse][:Array] = {
    :self => st,
    :argtype => [],
    :rettype => rt,
    :copy_rettype => true,
  }


  st = RubyType.array
  rt = RubyType.array
  rt.add_same_type(st)
  st.add_same_type(rt)
  MethodDefinition::RubyMethod[:sort][:AbstructContainer] = {
    :self => st,
    :argtype => [],
    :rettype => rt,
    :copy_rettype => true,
  }

  st = RubyType.array
  rt = RubyType.array
  rt.add_same_type(st)
  st.add_same_type(rt)
  MethodDefinition::RubyMethod[:sort!][:AbstructContainer] = {
    :self => st,
    :argtype => [],
    :rettype => rt,
    :copy_rettype => true,
  }


  st = RubyType.array
  rt = RubyType.array
  rt.add_same_type(st)
  st.add_same_type(rt)
  MethodDefinition::RubyMethod[:uniq!][:AbstructContainer] = {
    :self => st,
    :argtype => [],
    :rettype => rt,
    :copy_rettype => true,
  }

  st = RubyType.array
  rt = RubyType.array
  rt.add_same_type(st)
  st.add_same_type(rt)
  MethodDefinition::RubyMethod[:slice!][:Array] = {
    :self => st,
    :argtype => [RubyType.new(nil), RubyType.new(nil)],
    :rettype => rt,
    :copy_rettype => true,
  }

  MethodDefinition::RubyMethod[:"!~"][:String] = {
    :argtype => [RubyType.new(nil)],
    :rettype => RubyType.boolean,
  }

  MethodDefinition::RubyMethod[:"=~"][:String] = {
    :argtype => [RubyType.new(nil)],
    :rettype => RubyType.boolean,
  }


  MethodDefinition::RubyMethod[:"!~"][:Regexp] = {
    :argtype => [RubyType.string],
    :rettype => RubyType.boolean,
  }

  MethodDefinition::RubyMethod[:"=~"][:Regexp] = {
    :argtype => [RubyType.string],
    :rettype => RubyType.boolean,
  }

  fst = RubyType.new(nil)
  lst = RubyType.new(nil)
  fst.add_same_type(lst)
  lst.add_same_type(fst)
  excl = RubyType.boolean
  rng = RubyType.range(fst, lst, excl)
  MethodDefinition::RubyMethod[:first][:Range] = {
    :self => rng,
    :argtype => [],
    :rettype => fst,
    :copy_rettype => true,
  }

  fst = RubyType.new(nil)
  lst = RubyType.new(nil)
  fst.add_same_type(lst)
  lst.add_same_type(fst)
  excl = RubyType.boolean
  rng = RubyType.range(fst, lst, excl)
  MethodDefinition::RubyMethod[:last][:Range] = {
    :self => rng,
    :argtype => [],
    :rettype => lst,
    :copy_rettype => true,
  }

end

<<-'EOS'
# 
#=begin
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
    res = Array.new
    i = 0
    max = self.size
    while i < max
      res[i] = yield self[i]
      i = i + 1
    end

    res
  end
end

class Range
  def step(st)
    i = self.first
    ed = self.last
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

  def collect
    res = Array.new
    i = 0
    max = self.last
    if self.exclude_end? then
      while i < max do
        res[i] = yield i
        i = i + 1
      end
    else
      while i <= max do
        res[i] = yield i
        i = i + 1
      end
    end

    res
  end
end
#=end
EOS


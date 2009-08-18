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

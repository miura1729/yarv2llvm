class CuckooHash
  PRIMES =  [ 
             3,
             5,
             7,
             8 + 3,
             17,
             16 + 3,
             32 + 5,
             64 + 3,
             128 + 3,
             256 + 27,
             512 + 9,
             1024 + 9,
             2048 + 5,
             4096 + 3,
             8192 + 27,
             16384 + 43,
             32768 + 3,
             65536 + 45,
             131072 + 29,
             262144 + 3,
             524288 + 21,
             1048576 + 7,
             2097152 + 17,
             4194304 + 15,
             8388608 + 9,
             16777216 + 43,
             33554432 + 35,
             67108864 + 15,
             134217728 + 29,
             268435456 + 3,
             536870912 + 11,
             1073741824 + 85,
             0
            ]
  
  def initialize(elements)
    es = elements.size
    @plimepos = 0
    PRIMES.each_with_index do |n, i|
      if es / 2 < n then
        @primepos = i
        break
      end
    end
    @tabsizea = PRIMES[@primepos]
    @tabsizeb = PRIMES[@primepos - 1]
    
    @value = [Array.new(@tabsizea), Array.new(@tabsizeb)]
    @key = [Array.new(@tabsizea), Array.new(@tabsizeb)]
    @hfunc = [gen_hash_function_a(@tabsizea), gen_hash_function_b(@tabsizeb)]
    fill(elements)
  end

  def emit_code
    <<-EOS
def select_method(klass)
  av = [#{(@value[0].map {|n| n.inspect}).join(',')}]
  bv = [#{(@value[1].map {|n| n.inspect}).join(',')}]
  ak = [#{(@key[0].map {|n| n.inspect}).join(',')}]
  bk = [#{(@key[1].map {|n| n.inspect}).join(',')}]
  klassadd = ((klass.__id__ >> 1) << 2)
  ha = (klassadd / 20 + klassadd) % #{@tabsizea}
  if ak[ha] == klassadd then
    return av[ha]
  end
  hb = ((klassadd / 21) + klassadd * 31) % #{@tabsizeb}
  if bk[hb] == klassadd then
    return bv[hb]
  end
  return nil
end
EOS
  end
  
  def fill(elements)
    elements.each do |key, value|
      keyadd = ((key.__id__ >> 1) << 2)
      insert(keyadd, value)
    end
  end
  
  def insert(keyadd, value)
    while true
      @tabsizea.times do 
        hv = @hfunc[0].call(keyadd)
        
        vala = @value[0][hv]
        keyadda = @key[0][hv]
        @value[0][hv] = value
        @key[0][hv] = keyadd
        if vala == nil then
          return true
        end
        keyadd = keyadda
        
        hv = @hfunc[1].call(keyadd)
        valb = @value[1][hv]
        keyaddb = @key[1][hv]
        @value[1][hv] = vala
        @key[1][hv] = keyadd
        if valb == nil then
          return true
        end
        keyadd = keyaddb
        value = valb
      end
      
      rehash
    end
  end
  
  def rehash
    ovalue = @value
    okey = @key
    if @tabsizea == @tabsizeb then
      @primepos += 1
      @tabsizea = PRIMES[@primepos]
    else
      @tabsizeb = PRIMES[@primepos]
    end
    @value = [Array.new(@tabsizea), Array.new(@tabsizeb)]
    @key = [Array.new(@tabsizea), Array.new(@tabsizeb)]
    @hfunc = [gen_hash_function_a(@tabsizea), gen_hash_function_b(@tabsizeb)]
    [0, 1].each do |n|
      okey[n].each_with_index do |ele, i|
        if ele then
          insert(ele, ovalue[n][i])
        end
      end
    end
  end
    
  def gen_hash_function_a(size)
    lambda {|v|
      (v / 20 + v) % size
    }
  end
    
  def gen_hash_function_b(size)
    lambda {|v|
      ((v / 21) + v * 31) % size
    }
  end
end

# test1
c = CuckooHash.new({Array => :array_foo,
                    String => :string_foo,
                    Float => :float_foo,
                    Hash => :hash_foo,
                     Range => :range_foo,
                     Object => :object_foo})

code =  c.emit_code
print code
print "\n  --- OUTPUT --- \n"
eval code
[Array, String, Float, Hash, Range, Object].each do |klass|
  print "#{klass} -> #{select_method(klass)} \n"
end

# test2
class Object
  def subclasses_of(*superclasses)
    subclasses = []
    ObjectSpace.each_object(Class) do |k|
      next if # Exclude this class if
        (k.ancestors & superclasses).empty? || # It's not a subclass of our supers
        superclasses.include?(k) || # It *is* one of the supers
        /^[A-Z]/ !~ k.to_s ||
        eval("! defined?(::#{k})") || # It's not defined.
        eval("::#{k}").object_id != k.object_id
      subclasses << k
    end
    subclasses
  end
end

p "foo"
klasses = subclasses_of(Object)
klasses.push Object
p klasses.size
res ={}
klasses.each do |klass|
  res[klass] = klass.to_s + "_foo"
end

c = CuckooHash.new(res)
code =  c.emit_code
print code
print "\n  --- OUTPUT --- \n"
eval code
[Array, String, Float, Hash, Range, Object].each do |klass|
  print "#{klass} -> #{select_method(klass)} \n"
end

class DmyBlock
  def load(addr)
    pppp "Load (#{addr}) "
    addr
  end

  def store(value, addr)
    pppp "Store (#{value}), (#{addr})"
    nil
  end

  def add(p1, p2)
    pppp "add (#{p1}), (#{p2})"
  end

  def sub(p1, p2)
    pppp "sub (#{p1}), (#{p2})"
  end

  def mul(p1, p2)
    pppp "mul (#{p1}), (#{p2})"
  end

  def div(p1, p2)
    pppp "div (#{p1}), (#{p2})"
  end

  def icmp_eq(p1, p2)
    pppp "icmp_eq (#{p1}), (#{p2})"
  end

  def fcmp_ueq(p1, p2)
    pppp "fcmp_eq (#{p1}), (#{p2})"
  end

  def alloca(type, num)
    @@num ||= 0
    @@num += 1
    pppp "Alloca #{type}, #{num}"
    "[#{@@num}]"
  end

  def set_insert_point(n)
    pppp "set_insert_point #{n}"
  end

  def cond_br(cond, th, el)
    pppp "cond_br #{cond} #{th} #{el}"
  end

  def return(rc)
    pppp "return #{rc}"
  end

  def call(name, *args)
    pppp "call #{name}(#{args.join(',')})"
  end
end


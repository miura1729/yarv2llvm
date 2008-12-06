def make_method_call(recvs)
  recv_addr = []
  addr2func = {}
  recvs.keys.each do |ele|
    addr = ((ele.__id__ >> 1) << 2)
    recv_addr.push addr
    addr2func[addr] = recvs[ele]
  end
  recv_addr.sort!
  functab = []
  recv_addr.each do |ele|
    functab.push addr2func[ele]
  end

  recv_addr_diff = recv_addr.map { |ele|
    ele - recv_addr[0]
  }

  expterms = []
  recv_addr_diff.each_cons(2) do |ele|
    n = 1
    i = 0
    while n <= ele[1] do
      n = n << 1
      i = i + 1
    end
    n = n >> 1
    i = i - 1
    if n > ele[0] and false then
#      expterms.push "(((add >> #{i}) - 1) >> 32) + 1"
      expterms.push "((add - #{i}) >> 32) + 1"
    else
#      expterms.push "((add / #{ele[1]} - 1) >> 32) + 1"
      expterms.push "((add - #{ele[1]}) >> 32) + 1"
    end
  end
  <<"EOS"
def klass2idx(klass)
  add = ((klass.__id__ >> 1) << 2)
  add = add - #{recv_addr[0]}
  functab = #{functab}
  functab[#{expterms.join(' + ')}]
end
EOS
end

met =  make_method_call({Fixnum => :fixnum, 
                          Array => :array, 
                          String => :string, 
                          IO => :io})
print "Generated method\n"
print met
eval met
print "\n-- test ---\n"
[Fixnum, Array, String, IO].each do |c|
  print klass2idx(c)
  print "\n"
end

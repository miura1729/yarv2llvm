require 'yarv2llvm'

    YARV2LLVM::compile(<<-EOS
def arr2(a)
  a[0] = 1.0
  a
end

def arr1()
  a = []
  arr2(a)
  b = "abc"
  a[1] = 41.0
  a[0] + a[1]
end

EOS
)
GC.start
p arr1
GC.start


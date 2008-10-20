require 'yarv2llvm'

    YARV2LLVM::compile(<<-EOS
def arr1()
  a = []
  a[0] = 1
  a[1] = 2
  a[0] + a[1]
end
=begin
def arr2()
  a = []
  a[0] + 1.0
  a
end
=end
EOS
)
GC.start
p arr1
GC.start


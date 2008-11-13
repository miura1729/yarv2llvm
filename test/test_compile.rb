require 'test/unit'
require 'yarv2llvm'

class CompileTests < Test::Unit::TestCase
#=begin
  def test_fib
    YARV2LLVM::compile(<<-EOS
def fib(n)
  if n < 2 then
    1
  else
    fib(n - 1) + fib(n - 2)
  end
end
EOS
)
    assert_equal(fib(35), 14930352)
  end

  def test_array
    YARV2LLVM::compile(<<-EOS
def arr(n)
  b = []
  a = []
  a[0] = 0
  a[1] = 1
  a[2] = 4
  a[3] = 9
  b[0] = 1.0
  b[1] = 2.0
  b[2] = 3.0
  b[3] = 4.0
  b[0] = b[n]
  b[n]
end
EOS
)
   assert_equal(arr(0), 1.0)
   assert_equal(arr(1), 2.0)
   assert_equal(arr(2), 3.0)
   assert_equal(arr(3), 4.0)
  end

  def test_array2
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
   assert_equal(arr1, 42.0)
  end

  def test_double
    YARV2LLVM::compile(<<-EOS
def dtest(n)
  (Math.sqrt(n) * 2.0 + 1.0) / 3.0
end
EOS
)
   assert_equal(dtest(2.0), (Math.sqrt(2.0) * 2.0 + 1.0) / 3.0)
 end

  def test_while
    YARV2LLVM::compile(<<-EOS
def while_test(n)
  i = 0
  r = 0
  while i < n do
    i = i + 1
    r = r + i
  end
  r
end
EOS
)
   assert_equal(while_test(10), 55)
 end

  def test_dup_instruction
    YARV2LLVM::compile(<<-EOS
def dup(n)
  n = n + 0
  a = n
end
EOS
)
   assert_equal(dup(10), 10)
 end

  def arru(n)
    ((n + n) * n - n) % ((n + n * n) / n)
  end

  def test_arithmetic
    YARV2LLVM::compile(<<-EOS
def ari(n)
  ((n + n) * n - n) % ((n + n * n) / n) + 0
end
def arf(n)
  ((n + n) * n - n) % ((n + n * n) / n) + 0.0
end
EOS
)
   assert_equal(ari(10), arru(10))
   assert_equal(arf(10.0), arru(10.0))
 end

  def test_compare
    YARV2LLVM::compile(<<-EOS
def compare(n, m)
  n = n + 0
  m = m + 0
  ((n < m) ? 1 : 0) +
  ((n <= m) ? 2 : 0) +
  ((n > m) ? 4 : 0) +
  ((n >= m) ? 8 : 0)
end
EOS
)
   assert_equal(compare(0, 1), 3)
   assert_equal(compare(1, 1), 10)
   assert_equal(compare(1, 0), 12)
 end

def test_forward_call
    YARV2LLVM::compile(<<-EOS
def f1(n)
  f2(n + 0.5) 
end

def f2(n)
  n
end
EOS
)
   assert_equal(f1(1.0), 1.5)
end
#=end
#=begin
def test_send_with_block
    YARV2LLVM::compile(<<-EOS
def times
  j = 0
  while j < self
    yield j
    j = j + 1
  end
  0
end

def send_with_block(n)
  a = 0
  n = n + 0
  n.times do |i|
    a = a + i
  end
  a
end
EOS
)
assert_equal(send_with_block(100), 4950)
end
#=end

def test_string
    YARV2LLVM::compile(<<-EOS
def tstring
  a = "Hell world"
  a
end
EOS
)
assert_equal(tstring, "Hell world")
end

end

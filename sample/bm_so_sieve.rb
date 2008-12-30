require 'yarv2llvm'
YARV2LLVM::compile(<<-EOS, {})
# from http://www.bagley.org/~doug/shootout/bench/sieve/sieve.ruby
def main
num = 40
count = i = j = 0
#flags0 = Array.new(8192,1)
k = 0
while k < num
  k+=1
  count = 0
  flags = Array.new(8192) #flags0.dup
  i = 2
  while i<8192
    i+=1
    if flags[i] == nil
      # remove all multiples of prime: i
      j = i*i
      while j < 8192
        j += i
        flags[j] = true
      end
      count += 1
    end
  end
end
count
end
EOS

p main


#!/bin/env ruby 
# Compute E without bignum
#
KETA = 257

# dst / n -> dst
def div(n, dst)
  i = 0
  r = 0
  while i < KETA do
    d = dst[i] + r * 10000
    r = d % n
    dst[i] = d / n
    i = i + 1
  end
end

def add(src, dst)
  i = KETA - 1
  c = 0
  while i >= 0 do
    t = src[i] + dst[i] + c
    c = t / 10000
    dst[i] = t % 10000
    i = i - 1
  end
end

def compute_e
  i = 0
  f = 1
  a = []
  b = []
  while i < KETA do
    a[i] = 0
    b[i] = 0
    i = i + 1
  end
  b[0] = 1
  a[0] = 0
  n0 = 1 
  while f == 1 do
    f = 0
    i = 0
    while i < KETA do
      if b[i] != 0 then
        f = 1
        break
      end
      i = i + 1
    end
    add(b, a)
    div(n0, b)
    n0 = n0 + 1
  end
  a
end

require 'yarv2llvm'
module YARV2LLVM
  PROFILER_STATICS = [0.0]
end

YARV2LLVM::compile(<<-EOS, {optimize: false, disasm: true})
module YARV2LLVM
  def trace_func(event, no)
    if event == 1 or event == 8 then # Line or funcdef
      if $fst == 1 then
        $fst = 0
        $prev_no = 0
        get_interval_cycle
      end
      interval = get_interval_cycle.to_f
      PROFILER_STATICS[$prev_no] += interval
      $prev_no = no

      # Profile process dont count
      get_interval_cycle
      nil
    end
  end
end

def fib(n)
  if n < 2 then
    1
  else
    fib(n - 1) + 
    fib(n - 2)
  end
end

require 'sample/e-aux.rb'
EOS

YARV2LLVM::TRACE_INFO.each_with_index do |n, i|
  YARV2LLVM::PROFILER_STATICS[i] = 0.0
end
$fst = 1
p fib(29)
p compute_e

src_content = {}
YARV2LLVM::TRACE_INFO.each do |n|
  fn, ln = n[1][3].split(/:/)
  src_content[fn] = File.readlines(fn)
end

res = Hash.new(0)
YARV2LLVM::TRACE_INFO.each_with_index do |n, i|
  fn, ln = n[1][3].split(/:/)
  res[n[1][3]] += YARV2LLVM::PROFILER_STATICS[i]
end

src_content.each do |fn, cont|
  cont.each_with_index do |srcln, ln|
    re = res[fn + ":" + (ln + 1).to_s].to_i
    if re != 0 then
      printf("%10d %5d:  %s", re, ln + 1, srcln)
    else
      printf("           %5d:  %s", ln + 1, srcln)
    end
  end
end


require 'yarv2llvm'
module YARV2LLVM
  PROFILER_STATICS = []
  PROFILER_STATICS[0] = 0
end

YARV2LLVM::compile(<<-EOS, {})
module YARV2LLVM
  def trace_func(event, no)
    if event == 1 then # Line
      if $fst == 1 then
        get_interval_cycle
        $fst = 0
      end
      next_curtime = get_interval_cycle
      PROFILER_STATICS[no] += $curtime
      
      $curtime = next_curtime
      # Profile process dont count
      get_interval_cycle
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

EOS

YARV2LLVM::TRACE_INFO.each_with_index do |n, i|
  YARV2LLVM::PROFILER_STATICS[i] = 0
end
$fst = 1
$curtime = 0
p fib(10)

src_content = {}
YARV2LLVM::TRACE_INFO.each do |n|
  fn, ln = n[1][3].split(/:/)
  src_content[fn] = File.readlines(fn)
end

res = {}
YARV2LLVM::TRACE_INFO.each_with_index do |n, i|
  fn, ln = n[1][3].split(/:/)
  res[n[1][3]] = YARV2LLVM::PROFILER_STATICS[i]
end

src_content.each do |fn, cont|
  cont.each_with_index do |srcln, ln|
    re = res[fn + ":" + (ln + 1).to_s].to_i
    if re != 0 then
      print "#{re}\t#{ln + 1}:  #{srcln}"
    else
      print "\t#{ln + 1}:  #{srcln}"
    end
  end
end


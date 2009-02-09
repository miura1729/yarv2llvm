require 'yarv2llvm'
module YARV2LLVM
  PROFILER_STATICS = [0.0]
end

END {
  src_content = {}
  YARV2LLVM::TRACE_INFO.each do |n|
    if /^(.*):(.*)/ =~ n[1][3]
      fn = $1
      ln = $2
      src_content[fn] = File.readlines(fn)
    end
  end
  
  res = Hash.new(0)
  YARV2LLVM::TRACE_INFO.each_with_index do |n, i|
    if i != 0 then
      res[n[1][3]] += YARV2LLVM::PROFILER_STATICS[i]
    end
  end
  
  src_content.each do |fn, cont|
    cont.each_with_index do |srcln, ln|
      re = res[fn + ":" + (ln + 1).to_s].to_i
      if re != 0 then
        printf("%13d %5d:  %s", re, ln + 1, srcln)
      else
        printf("              %5d:  %s", ln + 1, srcln)
      end
    end
  end
}

<<-EOS
module YARV2LLVM
  def trace_func(event, no)
    if event == 1 or event == 8 then # Line or funcdef
      interval = get_interval_cycle.to_f
      PROFILER_STATICS[$prev_no] += interval
      $prev_no = no

      # Profile process dont count
      get_interval_cycle
      nil
    end
  end

  i = 0
  TRACE_INFO.each do |n|
    PROFILER_STATICS[i] = 0.0
    i = i + 1
  end
  $prev_no = 0
  get_interval_cycle
end

EOS

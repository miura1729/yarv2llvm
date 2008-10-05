require 'instruction'

include VMLib
is = RubyVM::InstructionSequence.compile(File.read(ARGV[0])).to_a
iseq = InstSeqTree.new(nil, is)

stack = []
iseq.traverse_code([nil, nil, nil]) do |code, info, header|
  code.lblock_list.each do |ln|
    p ln
    local = ["", "self"] + code.header['locals']
    code.lblock[ln].each do |ins|
      nm = ins[0]
      p1 = ins[1]
      case nm 
      when :getlocal
        stack.push local[p1]
      when :setlocal
        src = stack.pop
        p "#{local[p1]} = #{src}"
      when :opt_plus
        s1 = stack.pop
        s2 = stack.pop
        stack.push "#{s1} + #{s2}"
      when :opt_minus
        s1 = stack.pop
        s2 = stack.pop
        stack.push "#{s1} - #{s2}"
      when :opt_mult
        s1 = stack.pop
        s2 = stack.pop
        stack.push "#{s1} * #{s2}"
      when :opt_div
        s1 = stack.pop
        s2 = stack.pop
        stack.push "#{s1} / #{s2}"
      end
    end
  end
end


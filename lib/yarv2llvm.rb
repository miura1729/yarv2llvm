require 'tempfile'
require 'llvm'

require 'lib/instruction.rb'
require 'lib/type.rb'
require 'lib/llvmbuilder.rb'
require 'lib/methoddef.rb'
require 'lib/vmtraverse.rb'

def pppp(n)
#  p n
end

class Symbol
  def llvm
    immediate
  end
end



require 'yarv2llvm'
require 'llvmruby'

module YARV2LLVM
  MethodDefinition::RubyMethod[:get_or_insert_function][:"LLVM::Module"] = {
    :argtype => [RubyType.string, RubyType.value],
    :rettype => RubyType.value(nil, "Return type of Module::get_or_insert_function", :Function),
  }

 
  MethodDefinition::RubyMethod[:create_block][:"LLVM::Function"] = {
    :argtype => [],
    :rettype => RubyType.value(nil, "Return type of Module::get_or_insert_function", :BasicBlock),
  }

 MethodDefinition::RubyMethod[:builder][:"LLVM::BasicBlock"] = {
#    :argtype => [RubyType.value, RubyType.array],
    :argtype => [],
    :rettype => RubyType.value(nil, "Return type of Type::function", :Builder),
  }

end

<<-EOS
nil
EOS


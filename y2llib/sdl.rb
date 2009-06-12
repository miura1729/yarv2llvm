require 'yarv2llvm'
require 'sdl'

module YARV2LLVM
  MethodDefinition::RubyMethod[:open][:"SDL::Screen"] = {
    :argtype => [RubyType.fixnum, RubyType.fixnum, RubyType.fixnum, RubyType.fixnum],
    :rettype => RubyType.value(nil, "Return type of Screen#open", ::SDL::Screen),
  }

  MethodDefinition::RubyMethod[:load_bmp][:"SDL::Surface"] = {
    :argtype => [RubyType.string],
    :rettype => RubyType.value(nil, "Return type of Screen#open", ::SDL::Surface),
  }



  MethodDefinition::RubyMethod[:poll][:"SDL::Event"] = {
    :argtype => [RubyType.string],
    :rettype => RubyType.value(nil, "Return type of Event2#poll", ::SDL::Event2),
  }
end

<<-EOS
nil
EOS

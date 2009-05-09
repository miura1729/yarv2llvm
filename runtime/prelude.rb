# 
YARV2LLVM::define_macro :attr_reader do |arg|
#  arg.each do |argele|
    argele = arg[0]
    name = argele[0].type.constant
    `def #{name}; @#{name}; end`
#  end
end

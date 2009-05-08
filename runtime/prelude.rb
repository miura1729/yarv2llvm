# 
YARV2LLVM::define_macro :attr_reader do |arg|
  name = para[:args][0]
  name = name[0].type.constant
  `def #{name}; @#{name}; end`
end

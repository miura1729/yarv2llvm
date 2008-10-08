# Mapping ruby method to C function.

# Use ruby internal and ignor in yarv2llvm.
module MethodDefinition
  SystemMethod = {
    :"core#define_method" => true
  }
  
  # can be maped to C function
  CMethod = {
    :sqrt => 
      {:rettype => :float,
      :argtype => [:float],
      :cname => "sqrt"}
  }
end
    
  

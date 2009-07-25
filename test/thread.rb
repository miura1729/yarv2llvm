require 'runtime/thread.rb'

def foo
  p Thread.current
  Thread.new do
    100.times do 
      p Thread.current
      puts "bar"
    end
  end

  Thread.new do
    100.times do 
      p Thread.current
      puts "foo"
    end
  end
end

p "create start"
foo
p "create end"

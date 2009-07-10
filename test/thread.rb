require 'runtime/thread.rb'

def foo
Thread.new do
  100.times do 
    puts "foo"
  end
end
end

foo

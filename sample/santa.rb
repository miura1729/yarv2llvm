# santa claus probrem from Beautiful Code 
# orignal program in Haskell

def random_delay
  seed = YARV2LLVM::get_interval_cycle
  n = seed % 5
  n.times do 
    Thread.pass
  end
end

class Elf
  def initialize(no, group)
    @name = no
    @group = group
  end

  def run
    Thread.new {
      while true
        gates = @group.join
        gates[0].pass
        work
        gates[1].pass
        random_delay
      end
    }
    Thread.pass
  end

  def work
    puts sprintf("Meeting %d\n", @name)
  end
end

class Reindeer
  def initialize(no, group)
    @name = no
    @group = group
  end
  
  def run
    Thread.new {
      while true
        gates = @group.join
        gates[0].pass
        work
        gates[1].pass
        Thread.pass
        random_delay
      end
    }
    Thread.pass
  end

  def work
    puts sprintf("Delivering toy %d\n", @name)
  end
end

class Gate
  include Transaction

  def initialize(n)
    @n = n
    @n_left = 0
  end

  def pass
    begin_transaction
      @n_left = @n_left - 1
      if @n_left < 0 then
        Thread.pass
        do_retry
      end
    commit
  end

  def init
    @n_left = @n
  end

  def operate
    init
    begin_transaction
      if @n_left != 0 then
        Thread.pass
        do_retry
      end
    commit
  end
end

class Group
  include Transaction

  def initialize(n)
    @g1 = Gate.new(n)
    @g2 = Gate.new(n)
    @n = n
    @n_left = n
  end

  def gates
    [@g1, @g2]
  end

  def join
    begin_transaction
      @n_left = @n_left - 1
      if @n_left < 0 then
        Thread.pass
        do_retry
      end
    commit
    gates
  end

  def await
    if @n_left > 0 then
      return nil
    end

    @n_left = @n
    return gates
  end
end

class Santa
  def exec(group1, group2)
    while true
      puts "----------"
      choose([group1, group2])
    end
  end

  def run(task, gates)
    puts sprintf("Ho Ho Ho let's task %s ", task)
    gates[0].operate
    gates[1].operate
  end

  def choose(choices)
    if (gates = choices[0].await) != nil then
      run("deliver toys", gates)
      return nil
    elsif (gates = choices[1].await) != nil then
      run("meet in my study", gates)
      return nil
    end
  end
end

p "start"
elfg = Group.new(3)
p "elfg ok"
(1..11).each do |n|
  e = Elf.new(n, elfg)
  e.run
end
p "elf ok"
  
reing = Group.new(9)
p "reig ok"
(1..10).each do |n|
  r = Reindeer.new(n, reing)
  r.run
end
p "reing ok"
  
Santa.new.exec(reing, elfg)


# santa claus probrem from Beautiful Code 
# orignal program in Haskell

def random_delay
  seed = YARV2LLVM::get_interval_cycle
  n = seed % 103
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
        p gates[0]
        work
        gates[1].pass
      end
    }
    Thread.pass
  end

  def work
    puts sprintf("Meeting %d\n", @name)
    random_delay
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
      end
    }
    Thread.pass
  end

  def work
    puts sprintf("Delivering toy %d\n", @name)
    random_delay
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
    @n_left = n
  end

  def new_gates(n)
    @g1 = Gate.new(n)
    @g2 = Gate.new(n)
    @n_left = n
    [@g1, @g2]
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
    if @n_left != 0 then
      return nil
    end
    new_gates(@n_left)
  end
end

class Santa
  def exec(group1, group2)
    while true
      puts "----------"
      choose([group1, group2])
    end
  end

  def run(task, group)
    puts sprintf("Ho Ho Ho let's task %s ", task)
    p "foo"
    group.gates[0].operate
    p "foo"
    group.gates[1].operate
  end

  def choose(choices)
    if (group = choices[0].await) != nil then
      return run("deliver toys", group)
    elsif (group = choices[1].await) != nil then
      return run("meet in my study", group)
    end
  end
end

p "start"
elfg = Group.new(3)
p "elfg ok"
(1..10).each do |n|
  e = Elf.new(n, elfg)
  e.run
end
p "elf ok"
  
reing = Group.new(9)
p "reig ok"
(1..9).each do |n|
  r = Reindeer.new(n, reing)
  r.run
end
p "reing ok"
  
Santa.new.exec(elfg, reing)


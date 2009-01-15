# santa claus probrem from Beautiful Code 
# orignal program in Haskell

class Worker
  def woinit(n)
    @group = Group.new(n)
  end

  def active
    gates = @group.join
    gates[0].pass
    work
    gates[1].pass
  end
end

class Worker1
  def woinit1(n)
    @group = Group.new(n)
  end

  def active1
    gates = @group.join
    gates[0].pass
    work1
    gates[1].pass
  end
end

class Elf<Worker1
  def initialize(no)
    woinit1(no)
    @name = no
    Thread.new {
      while true
        active1
      end
    }
  end

  def work1
    puts sprintf("Meeting %d\n", @name)
  end
end

class Reindeer<Worker
  def initialize(no)
    woinit(no)
    @name = no
    Thread.new {
      while true
        active
      end
    }
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
        do_retry
      end
    commit
  end
end

class Group
  include Transaction

  def initialize(n)
    new_gates(n)
    @n_left = n
  end

  def new_gates(n)
    @g1 = Gate.new(n)
    @g2 = Gate.new(n)
  end

  def gates
    [@g1, @g2]
  end

  def join
    begin_transaction
      @n_left = @n_left - 1
      if @n_left < 0 then
        do_retry
      end
    commit
    gates
  end

  def await
    while @n_left != 0 do
    end
    new_gates(@n_left)
  end
end


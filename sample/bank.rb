#
#  bank simulator for test Transaction mixin
# 
#
class Bank
  include Transaction

  def initialize
    @balance = 0
  end

  def deposit(how)
    begin_transaction
      @balance += how
    commit
  end

  def draw(how)
    begin_transaction
      @balance -= how
    commit
  end

  def balance
    @balance
  end
end

$b = Bank.new
a = 0

Thread.new do
  100.times do 
    puts sprintf "DEPOSIT START: %d", $b.balance
    $b.deposit(1)
    puts sprintf "DEPOSIT END: %d", $b.balance
  end
end


100.times do 
  puts sprintf "DRAW START: %d", $b.balance
  $b.draw(1)
  puts sprintf "DRAW END: %d", $b.balance
end


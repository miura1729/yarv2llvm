
SDL.init(SDL::INIT_VIDEO)
screen = SDL::Screen.open(640, 480, 16, SDL::SWSURFACE)
SDL::WM::set_caption('testsprite.rb','testsprite.rb icon')
image = SDL::Surface.load_bmp("icon.bmp")
image.set_color_key(SDL::SRCCOLORKEY ,0)
$image = image.display_format

class Sprite
  def initialize
    @x=rand * 640.0
    @y=rand * 480.0
    @dx=rand * 11.0 - 5.0
    @dy=rand * 11.0 - 5.0
  end
  
  def move
    @x += @dx
    if @x >= 640.0 then
      @dx *= -1.0
      @x = 639.0
    end
    if @x < 0.0 then
      @dx *= -1.0
      @x = 0.0
    end
    @y += @dy
    if @y >= 480.0 then
      @dy *= -1.0
      @y = 479.0
    end
    @y += @dy
    if @y < 0.0 then
      @dy *= -1.0
      @y = 0.0
    end
    nil
  end
  
  def draw(screen)
    SDL::Surface.blit($image, 0, 0, 32, 32, screen, @x.to_i, @y.to_i)
  end
  
end

sprites = []
for i in 1..100
  sprites.push Sprite.new
end


while true
  while (event = SDL::Event.poll)
    case event
    when SDL::Event::KeyDown, SDL::Event::Quit
      exit
    end
  end
  screen.fill_rect(0, 0, 640, 480, 0)
  
  sprites.each {|i|
    i.move
    i.draw(screen)
  }
  
  screen.update_rect(0, 0, 0, 0)
end



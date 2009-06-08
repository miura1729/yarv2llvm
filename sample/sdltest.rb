SDL.init( SDL::INIT_VIDEO )
screen = SDL::Screen.open(640,480,16,SDL::SWSURFACE)
p screen
for i in 0..255
  for j in 0..255
    screen.fill_rect(i*2 , j*2, 2 ,2 , [i, j, 100])
    nil
  end
end
screen.flip


#image=SDL::Surface.load_bmp 'cursor.bmp'
#SDL::Mouse.set_cursor image,image[0,0],image[1,1],image[7,0],543


while true
  
  while (event = SDL::Event.poll) != nil
    if event.kind_of? SDL::Event::Quit then
      exit
    end
  end
  sleep 0.01
end
=begin
=end

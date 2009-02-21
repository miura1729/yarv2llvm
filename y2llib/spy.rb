require 'yarv2llvm'
require 'webrick'
require 'irb'

class SpyServer
  include WEBrick

  # Top service
  class SpyServletTop<HTTPServlet::AbstractServlet
    def initialize(sv, opt)
      super
    end

    def do_GET(req, res)
      rc = "<html><body>" 
      rc += "<table border>"
      if $pos then
        $pos.each do |key, value|
          rc += "<tr>"
          info = YARV2LLVM::TRACE_INFO[value]
          rc += "<td> #{info[1][0]}</td><td> #{info[1][1]}</td><td> #{info[1][3]}</td>"
          rc += "</tr>"
        end
      end
      rc += "</body> </html>"
      res.body = rc
      res['Content-Type'] = "text/html"
    end
  end

  # Dummy logger
  class DummyLog<BasicLog
    def log(level, data)
    end
  end

  def initialize
    @log = DummyLog.new
    @server = HTTPServer.new(:Port => 80, 
                             :BindAddress => "localhost",
                             :Logger => @log,
                             :AccessLog => [])
    trap("INT"){@server.shutdown}
    @server.mount("/spy", SpyServletTop, nil)
    @server.mount("/spy/update", SpyServletTop, nil)
    @server.start
  end
end

Thread.new {
  server = SpyServer.new
}

=begin
Thread.new {
  while true
    if $pos then
      $pos.each do |key, value|
#        print "#{key}\t #{YARV2LLVM::TRACE_INFO[value]}\n"
      end
    end
    sleep 1
  end
}
=end

<<-EOS
module YARV2LLVM
  $pos = Hash.new
  def trace_func(event, no)
    if rand < 0.1 then
      $pos[Thread.current] = no
    end
  end
end

EOS


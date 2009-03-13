require 'yarv2llvm'
require 'webrick'
require 'irb'

class SpyServer
  include WEBrick

  # Top service
  class SpyServletTop<HTTPServlet::AbstractServlet
HTML_TEMPLATE = <<EOS
<html>
  <style type="text/css">
    table#main {
      border-collapse: collaspe;
      empty-cells: hide;
      border-spacing: 0
    }

   th#tname {
      width: 20ex;
      text-align: left
   }
   th#tclass {
      width: 20ex;
      text-align: left
   }
   th#tmethod {
      width: 20ex;
      text-align: left
   }
   th#tstatus {
      width: 20ex;
      text-align: left
   }
  </style>

  <script type="text/javascript" id="main">
    window.onload = function() {
      var xmlhttp = new XMLHttpRequest();
      xmlhttp.open("GET", "/spy/update.js", true);
      xmlhttp.onreadystatechange=function() {
        if (xmlhttp.readyState == 4) {
          eval(xmlhttp.responseText);
        }
      }
      xmlhttp.send(null);
    };

  </script>
  <body>
    <table id="main">
       <tr>
       <th id="tname"> Name  </th> 
       <th id="tclass"> Class  </th> 
       <th id="tmethod"> Method  </th> 
       <th id="tstatus"> Line number </th> 
       </tr>
       <%= @table_prototye %>
    </table>
  </body>
</html>

EOS

    def initialize(sv, opt)
      super
      table_prototye = ""
      30.times do |i|
        table_prototye += "<tr id=\"tab#{i}\">"
        4.times do |j|
          table_prototye += "<td> <div id=\"tab#{i}-#{j}\" width=\"20em\"> </div></td>"
        end
        table_prototye += "</tr>"
      end
      @table_prototye = table_prototye
      @page = ERB.new(HTML_TEMPLATE).result(binding)
    end

    def do_GET(req, res)
      res.body = @page
      res['Content-Type'] = "text/html"
    end
  end
  
  class SpyServletUpdate<HTTPServlet::AbstractServlet
    SCRIPT_EPILOGUE = <<EOS
    xmlhttp.open("GET", "/spy/update.js", true);
    xmlhttp.onreadystatechange=function() {
       if (xmlhttp.readyState == 4) {
            eval(xmlhttp.responseText);
       }
    }
    xmlhttp.send(null);
EOS
    def do_GET(req, res)
      sleep(1)
      script = ""

      if $spypos then
        i = 0
        $spypos.each do |key, value|
          info = YARV2LLVM::TRACE_INFO[value][1]
          nameno = $spyname[key]
          name = YARV2LLVM::TRACE_INFO[nameno][1][0]
          dest = "document.getElementById(\"tab#{i}-0\").innerHTML"
          script += "#{dest} =  \"#{name}\";\n"
          dest = "document.getElementById(\"tab#{i}-1\").innerHTML"
          script += "#{dest} =  \"#{info[0]}\";\n"
          dest = "document.getElementById(\"tab#{i}-2\").innerHTML"
          script += "#{dest} =  \"#{info[1]}\";\n"
          dest = "document.getElementById(\"tab#{i}-3\").innerHTML"
          if key.status == "run"
            script += "#{dest} =  \"#{info[3]}\";\n"
          else
            script += "#{dest} =  \"Zzz...\";\n"
          end
          i = i + 1
        end
      end

      res.body = script + SCRIPT_EPILOGUE
      res['Content-Type'] = "text/javascript"
    end
  end

  # Dummy logger
  class DummyLog<BasicLog
    def log(level, data)
    end
  end

  def initialize
    @log = DummyLog.new
    @server = HTTPServer.new(:Port => 8088, 
                             :BindAddress => "localhost",
                             :Logger => @log,
                             :AccessLog => [])
    trap("INT"){@server.shutdown}
    @server.mount("/spy/update.js", SpyServletUpdate, nil)
    @server.mount("/spy", SpyServletTop, nil)
    @server.start
  end
end

Thread.new {
  server = SpyServer.new
}

<<-EOS
module YARV2LLVM
  $spypos = Hash.new
  $spyname = Hash.new
  $spythread = Hash.new
  def trace_func(event, no)
    cur = Thread.current
    if $spythread[cur] == nil then
      $spyname[cur] = no
      $spypos[cur] = no
      $spythread[cur] = 0
    elsif event == 8 then
      $spypos[cur] = no
    elsif rand < 0.1 then
      $spypos[cur] = no
    end
  end
end

EOS


require "spec"
require "http/server"
require "log/spec"
require "../src/booth/repository"
require "../src/config"
require "../src/error/usecase"
require "../src/r2/repository"
require "../src/runtime/metrics"
require "../src/status/models"
require "../src/status/repository"
require "../src/status/usecase"
require "../src/statuspage/models"
require "../src/statuspage/repository"
require "../src/steam/repository"
require "../src/youtube/repository"

# 決めた応答を返す試験用のサーバーを立て、その URL を渡す。
#
# 上流を叩かずに、応答の写し取りと失敗の扱いを確かめるためのものである。
# 取得元の spec はどれも同じ形をとるので、ここへ一つ置く。
def with_stub_server(handler : HTTP::Server::Context -> Nil, &)
  server = HTTP::Server.new { |context| handler.call(context) }
  address = server.bind_unused_port("127.0.0.1")
  spawn { server.listen }

  begin
    yield "http://127.0.0.1:#{address.port}"
  ensure
    server.close
  end
end

# 誰も待ち受けていない番号を得る。接続そのものが失敗する場合を試すために使う。
def unused_port : Int32
  server = HTTP::Server.new { }
  address = server.bind_unused_port("127.0.0.1")
  server.close
  address.port
end

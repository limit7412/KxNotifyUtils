require "../spec_helper"
require "http/server"
require "socket"
require "../../src/xsoverlay/websocket_repository"
require "../../src/xsoverlay/udp_repository"

private def message
  Notify::Message.new(
    title: "Discord: 件名",
    body: "本文",
    icon: Notify::Icon.builtin("default"),
    timeout: 6.5,
    sound: "default",
    volume: 0.7,
    source_app: "KxNotifyUtils",
  )
end

private def settings(websocket_port = 0, udp_port = 0)
  XSOverlay::Settings.from_json(%({"websocket_port": #{websocket_port}, "udp_port": #{udp_port}}))
end

# 接続が確立するまで待つ。実サーバ相手のため、時間ではなく状態の変化を待つ。
private def wait_until(timeout = 3.seconds, &block : -> Bool) : Bool
  deadline = Time.monotonic + timeout
  until block.call
    return false if Time.monotonic > deadline
    sleep 5.milliseconds
  end
  true
end

describe XSOverlay::WebsocketRepository do
  it "client クエリパラメータを付けた接続先を組み立てる" do
    XSOverlay::WebsocketRepository.new(settings(websocket_port: 42070)).endpoint
      .should eq "ws://localhost:42070/?client=KxNotifyUtils"
  end

  it "未接続のうちは送信せず false を返す" do
    repository = XSOverlay::WebsocketRepository.new(settings(websocket_port: 1))

    repository.send_message(message).should be_false
  end

  it "接続先が受け取ったエンベロープに通知オブジェクトが入る" do
    received = Channel(String).new(1)
    queries = Channel(String).new(1)
    handler = HTTP::WebSocketHandler.new do |socket, context|
      queries.send(context.request.query || "")
      socket.on_message { |text| received.send(text) }
    end
    server = HTTP::Server.new([handler])
    address = server.bind_unused_port
    spawn { server.listen }

    repository = XSOverlay::WebsocketRepository.new(settings(websocket_port: address.port))
    repository.start
    wait_until { repository.connected? }.should be_true

    repository.send_message(message).should be_true
    envelope = JSON.parse(received.receive)
    envelope["command"].as_s.should eq "SendNotification"
    JSON.parse(envelope["jsonData"].as_s)["title"].as_s.should eq "Discord: 件名"
    queries.receive.should eq "client=KxNotifyUtils"
  ensure
    repository.try(&.stop)
    server.try(&.close)
  end

  it "接続が切れたら再接続して中継が復帰する" do
    connections = Channel(HTTP::WebSocket).new(4)
    received = Channel(String).new(4)
    handler = HTTP::WebSocketHandler.new do |socket, _context|
      connections.send(socket)
      socket.on_message { |text| received.send(text) }
    end
    server = HTTP::Server.new([handler])
    address = server.bind_unused_port
    spawn { server.listen }

    repository = XSOverlay::WebsocketRepository.new(settings(websocket_port: address.port))
    repository.start
    wait_until { repository.connected? }.should be_true

    connections.receive.close
    wait_until { !repository.connected? }.should be_true
    repository.send_message(message).should be_false

    wait_until(10.seconds) { repository.connected? }.should be_true
    repository.send_message(message).should be_true
    received.receive.should_not be_empty
  ensure
    repository.try(&.stop)
    server.try(&.close)
  end
end

describe XSOverlay::UdpRepository do
  it "通知オブジェクトをエンベロープに包まずそのまま送る" do
    listener = UDPSocket.new
    listener.bind "127.0.0.1", 0
    port = listener.local_address.port

    repository = XSOverlay::UdpRepository.new(settings(udp_port: port))
    repository.start
    repository.send_message(message).should be_true

    payload, _ = listener.receive
    json = JSON.parse(payload)
    json["title"].as_s.should eq "Discord: 件名"
    json["audioPath"].as_s.should eq "default"
  ensure
    repository.try(&.stop)
    listener.try(&.close)
  end

  it "ソケットを開いていなければ送信せず false を返す" do
    repository = XSOverlay::UdpRepository.new(settings(udp_port: 42069))

    repository.send_message(message).should be_false
  end
end

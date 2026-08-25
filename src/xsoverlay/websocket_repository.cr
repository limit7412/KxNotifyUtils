require "http/web_socket"
require "log"
require "uri"
require "../notify/models"
require "../notify/repository"
require "./models"

module XSOverlay
  # XSOverlay の WebSocket API へ送るシンク実装（仕様書 4.4 節）。
  #
  # 接続の維持は専用のファイバに閉じ、send_message は接続済みのときだけ送る。
  # 未接続の間に発生した通知はキューせず破棄する。
  # XSOverlay が動いていない状況とは VR 外である可能性が高く、
  # そのとき通知は通常のトーストで見えているため、後からまとめて HMD へ流す価値がないからである。
  class WebsocketRepository < Notify::PostRepository
    Log = ::Log.for("xsoverlay")

    # 再接続の待ち時間。切断が続く間は最大値まで倍にしていく。
    BACKOFF_MIN = 1.second
    BACKOFF_MAX = 30.seconds

    # client クエリパラメータが無いと XSOverlay 側が接続を拒否するため、必ず付与する。
    CLIENT_NAME = "KxNotifyUtils"

    property settings : Settings
    getter? connected : Bool = false

    def initialize(@settings : Settings)
      @socket = nil.as(HTTP::WebSocket?)
      @stopping = false
      @backoff = BACKOFF_MIN
    end

    def sink_id : String
      SINK_ID
    end

    def endpoint : String
      "ws://localhost:#{@settings.websocket_port}/?client=#{URI.encode_path_segment(CLIENT_NAME)}"
    end

    def start : Nil
      @stopping = false
      spawn(name: "xsoverlay-websocket") { maintain_connection }
    end

    def stop : Nil
      @stopping = true
      @connected = false
      socket = @socket
      @socket = nil
      socket.try(&.close) rescue nil
    end

    def send_message(message : Notify::Message) : Bool
      socket = @socket
      return false unless @connected && socket

      envelope = Envelope.for(NotificationObject.from_message(message))
      socket.send(envelope.to_json)
      true
    rescue ex
      Log.warn(exception: ex) { "WebSocket への送信に失敗した" }
      @connected = false
      false
    end

    # 切断を検知したら指数バックオフで再接続する。
    private def maintain_connection : Nil
      until @stopping
        begin
          socket = HTTP::WebSocket.new(URI.parse(endpoint))

          # 接続を張っている間に停止を頼まれていることがある。
          # そのときの @socket はまだ nil で stop が閉じられないため、ここで閉じて抜ける。
          if @stopping
            socket.close rescue nil
            break
          end

          @socket = socket
          @connected = true
          @backoff = BACKOFF_MIN
          Log.info { "XSOverlay へ接続した: #{endpoint}" }

          socket.on_close do |_code, _reason|
            @connected = false
          end
          socket.run
        rescue ex
          Log.debug { "XSOverlay へ接続できない: #{ex.message}" }
        ensure
          @connected = false
          @socket = nil
        end

        break if @stopping
        Log.info { "XSOverlay との接続が切れた。#{@backoff.total_seconds.to_i} 秒後に再接続する" }
        sleep @backoff
        @backoff = {@backoff * 2, BACKOFF_MAX}.min
      end
    end
  end
end

require "log"
require "socket"
require "../notify/models"
require "../notify/repository"
require "./models"

module XSOverlay
  # レガシーの UDP 通知 API へ送るシンク実装（仕様書 4.4 節）。
  #
  # WebSocket に問題が出た場合の退避手段としてのみ残しており、ドキュメント上は非推奨とする。
  # エンベロープには包まず、通知オブジェクトをそのまま送る。
  class UdpRepository < Notify::PostRepository
    Log = ::Log.for("xsoverlay")

    HOST = "127.0.0.1"

    property settings : Settings

    def initialize(@settings : Settings)
      @socket = nil.as(UDPSocket?)
    end

    def sink_id : String
      SINK_ID
    end

    def start : Nil
      open_socket
    end

    def stop : Nil
      @socket.try(&.close) rescue nil
      @socket = nil
    end

    def send_message(message : Notify::Message) : Bool
      # 開けていなければ送るときに開き直す。
      # シンクは設定が変わるまで作り直されないため、ここで開き直さないと
      # 起動時の一度の失敗だけで、以降の通知がすべて捨てられ続ける。
      socket = @socket || open_socket
      return false unless socket

      socket.send(NotificationObject.from_message(message).to_json)
      true
    rescue ex
      Log.warn(exception: ex) { "UDP での送信に失敗した" }
      # 壊れたソケットを持ち続けず、次の通知で開き直す。
      stop
      false
    end

    private def open_socket : UDPSocket?
      socket = UDPSocket.new
      socket.connect(HOST, @settings.udp_port)
      @socket = socket
      Log.info { "XSOverlay へ UDP で送信する: #{HOST}:#{@settings.udp_port}" }
      socket
    rescue ex
      Log.error(exception: ex) { "UDP ソケットを開けなかった" }
      @socket = nil
    end
  end
end

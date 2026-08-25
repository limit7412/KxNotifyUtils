require "json"
require "../notify/models"

# シンク実装：XSOverlay。
# 中立形式の Message を XSOverlay の通知オブジェクトへ変換する（仕様書 4.4 節）。
module XSOverlay
  SINK_ID = "xsoverlay"

  # 送信経路。UDP はレガシー API への退避手段であり、ドキュメント上は非推奨とする。
  enum Transport
    Websocket
    Udp
  end

  # XSOverlay の通知オブジェクト。
  struct NotificationObject
    include JSON::Serializable

    # 1 は通常の通知。2 のメディアプレイヤー連携は本ツールの対象外とする。
    getter type : Int32 = 1
    getter title : String
    getter content : String
    getter timeout : Float64
    getter height : Float64
    getter opacity : Float64
    getter volume : Float64

    @[JSON::Field(key: "audioPath")]
    getter audio_path : String

    @[JSON::Field(key: "useBase64Icon")]
    getter use_base64_icon : Bool

    getter icon : String

    @[JSON::Field(key: "sourceApp")]
    getter source_app : String

    def initialize(
      @title : String,
      @content : String,
      @timeout : Float64,
      @height : Float64,
      @opacity : Float64,
      @volume : Float64,
      @audio_path : String,
      @use_base64_icon : Bool,
      @icon : String,
      @source_app : String,
      @type : Int32 = 1,
    )
    end

    # 中立形式からの変換。
    # コアはそのまま対応づけ、表示ヒントの height と opacity は XSOverlay が解釈できるため反映する。
    def self.from_message(message : Notify::Message) : NotificationObject
      icon = message.icon
      new(
        title: message.title,
        content: message.body,
        timeout: message.timeout,
        height: message.hints.height,
        opacity: message.hints.opacity,
        volume: message.volume,
        audio_path: message.sound,
        use_base64_icon: icon.try(&.base64?) || false,
        icon: icon.try(&.value) || "default",
        source_app: message.source_app,
      )
    end
  end

  # WebSocket API のエンベロープ。
  struct Envelope
    include JSON::Serializable

    getter sender : String
    getter target : String
    getter command : String

    @[JSON::Field(key: "jsonData")]
    getter json_data : String

    @[JSON::Field(key: "rawData")]
    getter raw_data : String?

    def initialize(
      @json_data : String,
      @sender : String = "KxNotifyUtils",
      @target : String = "xsoverlay",
      @command : String = "SendNotification",
      @raw_data : String? = nil,
    )
    end

    def self.for(notification : NotificationObject) : Envelope
      new(json_data: notification.to_json)
    end
  end

  # sinks.xsoverlay セクション（仕様書 5 章）。
  class Settings
    include JSON::Serializable

    property enabled : Bool = true
    property transport : Transport = Transport::Websocket
    property websocket_port : Int32 = 42070
    property udp_port : Int32 = 42069

    PORT_RANGE = 1..65535

    def initialize
    end

    def self.from_section(section : JSON::Any?) : Settings
      return Settings.new if section.nil?
      Settings.from_json(section.to_json)
    end

    def self.validate(section : JSON::Any?) : Array(String)
      settings = begin
        from_section(section)
      rescue ex : JSON::Error
        return ["sinks.xsoverlay の書式が不正である: #{ex.message}"]
      end

      errors = [] of String
      unless PORT_RANGE.includes?(settings.websocket_port)
        errors << "sinks.xsoverlay.websocket_port はポート番号の範囲で指定する"
      end
      unless PORT_RANGE.includes?(settings.udp_port)
        errors << "sinks.xsoverlay.udp_port はポート番号の範囲で指定する"
      end
      errors
    end
  end
end

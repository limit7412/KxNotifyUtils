require "../config/models"

# 中立ドメイン。
# ソースにもシンクにも依存しない通知の形を定義する（仕様書 2.3 節）。
module Notify
  # 通知アイコンの指定。
  # シンク側の組み込みアイコン名か、PNG 画像の base64 表現のどちらかを表す。
  struct Icon
    enum Kind
      # シンクが自前で持つアイコンを名前で指す。v1 では default / warning / error の 3 種。
      Builtin
      # PNG 画像の base64 表現。
      Base64
    end

    getter kind : Kind
    getter value : String

    def initialize(@kind : Kind, @value : String)
    end

    def self.builtin(name : String) : Icon
      new(Kind::Builtin, name)
    end

    def self.base64(data : String) : Icon
      new(Kind::Base64, data)
    end

    def builtin? : Bool
      @kind.builtin?
    end

    def base64? : Bool
      @kind.base64?
    end
  end

  # ソースに依存しない受信通知。
  # ソースは自分の取得結果をこの形に変換して返し、それ以降の処理はソースの素性を見ない。
  struct Incoming
    getter source : String
    getter app_id : String
    getter app_name : String
    getter title : String
    getter body : String
    getter icon : Icon?
    getter created_at : Time

    def initialize(
      @source : String,
      @app_id : String,
      @app_name : String,
      @title : String,
      @body : String,
      @icon : Icon? = nil,
      @created_at : Time = Time.utc,
    )
    end
  end

  # シンクによっては解釈されない表示ヒント（仕様書 2.3 節）。
  # 解釈できないシンクはこれらを無視してよい。
  struct DisplayHints
    getter height : Float64
    getter opacity : Float64

    def initialize(@height : Float64 = 100.0, @opacity : Float64 = 1.0)
    end
  end

  # シンクに依存しない送信通知。
  # どのシンクでも意味を持つコアと、解釈されなくてよい表示ヒントに分けて持つ。
  struct Message
    getter title : String
    getter body : String
    getter icon : Icon?
    getter timeout : Float64
    getter sound : String
    getter volume : Float64
    getter source_app : String
    getter hints : DisplayHints

    def initialize(
      @title : String,
      @body : String,
      @icon : Icon?,
      @timeout : Float64,
      @sound : String,
      @volume : Float64,
      @source_app : String,
      @hints : DisplayHints = DisplayHints.new,
    )
    end
  end
end

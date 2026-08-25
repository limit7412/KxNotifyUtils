require "json"

# ソース実装：Windows のデスクトップ通知。
# NotifListenerShim が返す JSON（仕様書 3.3 節）を読み、中立形式へ橋渡しする。
module WinNotification
  SOURCE_ID = "windows"

  # 通知アクセスの許可状態（仕様書 3.2 節の nls_get_access_status に対応）。
  enum AccessStatus
    Allowed
    Denied
    Unspecified
    # シム側がエラーを返した場合。許可状態が判断できないことを表す。
    Unknown

    def self.from_code(code : Int32) : AccessStatus
      case code
      when 0 then Allowed
      when 1 then Denied
      when 2 then Unspecified
      else        Unknown
      end
    end
  end

  # シムが返す通知 1 件。
  struct Notification
    include JSON::Serializable

    getter id : UInt32
    getter app_id : String = ""
    getter app_name : String = ""
    getter title : String = ""
    getter body : String = ""
    getter created_at : String = ""
    getter icon_png_base64 : String? = nil

    def initialize(
      @id : UInt32,
      @app_id : String = "",
      @app_name : String = "",
      @title : String = "",
      @body : String = "",
      @created_at : String = "",
      @icon_png_base64 : String? = nil,
    )
    end

    # created_at は ISO 8601 で入る。
    # 解釈できない値でも通知そのものは中継したいため、失敗時は現在時刻で代用する。
    def created_time : Time
      Time.parse_rfc3339(@created_at)
    rescue
      Time.utc
    end
  end

  struct NotificationList
    include JSON::Serializable

    getter notifications : Array(Notification) = [] of Notification

    def initialize(@notifications : Array(Notification) = [] of Notification)
    end
  end

  # sources.windows セクション（仕様書 5 章）。
  class Settings
    include JSON::Serializable

    property enabled : Bool = true
    property polling_interval_ms : Int32 = 500

    POLLING_INTERVAL_RANGE = 100..5000

    def initialize
    end

    def self.from_section(section : JSON::Any?) : Settings
      return Settings.new if section.nil?
      Settings.from_json(section.to_json)
    end

    # 設定 GUI と起動時の検証で使う。エラーメッセージの配列を返し、空なら妥当とみなす。
    def self.validate(section : JSON::Any?) : Array(String)
      errors = [] of String
      settings = begin
        from_section(section)
      rescue ex : JSON::Error
        return ["sources.windows の書式が不正である: #{ex.message}"]
      end

      unless POLLING_INTERVAL_RANGE.includes?(settings.polling_interval_ms)
        errors << "sources.windows.polling_interval_ms は " \
                  "#{POLLING_INTERVAL_RANGE.begin} から #{POLLING_INTERVAL_RANGE.end} の範囲で指定する"
      end
      errors
    end
  end
end

require "json"
require "uri"

# ソース実装：外部サービスの障害検知（issue #5）。
#
# VRChat や YouTube の障害を VR の中で知るためのソースである。
# VR プレイ中に「VRChat 側の障害なのか自環境の問題なのか」を切り分けるのが目的であり、
# 稼働状態が変わったときだけ通知を出す。
#
# 取得元は各サービスのステータスページではなく、VRCServiceStatusPanel の配信 JSON である。
# あちらが 1 分ごとに各サービスを見て 4 段階のレベルへ判定済みで配っており、
# 本体側に Statuspage の読み方や合成監視の判定を持ち込まずに済む。
# この JSON の形は VRCServiceStatusPanel の仕様書 4 章にある。
module ServiceStatus
  SOURCE_ID = "service_status"

  # 配信 JSON の読める版。これ以外は読まない。
  # 版が上がるのは互換性のない変更のときであり、古い解釈で読み続けると誤った状態を知らせる。
  SCHEMA_VERSION = 1

  # 配信 JSON の level（4 段階）。
  enum Level
    Operational
    Degraded
    MajorOutage
    # 取得元が判定できなかった。障害ではない。
    Unknown

    # 配信の level は整数で入る。範囲外は判定不能として読む。
    # 取得元が段階を増やしたとき、黙って正常や障害へ倒すよりは知らせないほうが害が小さい。
    def self.from_level(value : Int32) : Level
      Level.from_value?(value) || Level::Unknown
    end

    # 前回との比較に使えるか。Unknown は比較の材料にしない。
    def known? : Bool
      !unknown?
    end
  end

  # 配信 JSON の services の 1 件。判定に使う項目だけを読み、他は読み捨てる。
  struct Service
    include JSON::Serializable

    getter id : String
    getter name : String = ""
    getter level : Int32 = Level::Unknown.value
    getter label : String = ""
    getter note : String = ""

    def initialize(@id : String, @name : String = "", @level : Int32 = 0, @label : String = "", @note : String = "")
    end

    def level_enum : Level
      Level.from_level(@level)
    end
  end

  # 配信 JSON 全体。
  struct Feed
    include JSON::Serializable

    @[JSON::Field(key: "v")]
    getter version : Int32 = 0
    getter generated_unix : Int64 = 0
    # 取得元がどのサービスも取れなかった。中身は前回値であり、今を語っていない。
    getter? stale : Bool = false
    getter services : Array(Service) = [] of Service

    def initialize(@version : Int32 = SCHEMA_VERSION, @generated_unix : Int64 = 0, @stale : Bool = false, @services : Array(Service) = [] of Service)
    end

    def supported? : Bool
      @version == SCHEMA_VERSION
    end
  end

  # 配信に含まれるサービス。設定画面に並べる順序と、設定ファイルの既定に使う。
  #
  # 配信側の並び（VRCServiceStatusPanel の main.cr）に合わせてある。
  # 表示名は配信の name を使うが、画面は取得の前に組み立てるためここにも持つ。
  KNOWN_SERVICES = {
    "vrchat"     => "VRChat",
    "youtube"    => "YouTube",
    "steam"      => "Steam",
    "booth"      => "BOOTH",
    "discord"    => "Discord",
    "cloudflare" => "Cloudflare",
    "twitch"     => "Twitch",
  }

  # 既定で知らせるサービス。issue #5 のコメントで決めた 3 つである。
  DEFAULT_ENABLED_SERVICES = %w[vrchat youtube steam]

  # sources.service_status セクション。
  class Settings
    include JSON::Serializable

    # 配信 JSON の置き場所。
    DEFAULT_FEED_URL = "https://vrc-status.oxymoron.link/v1/status.json"

    # 配信は 1 分ごとに更新される。それより短くしても変化に早く気付けない。
    DEFAULT_POLLING_INTERVAL_S = 60
    POLLING_INTERVAL_RANGE     = 30..3600

    property enabled : Bool = true
    property polling_interval_s : Int32 = DEFAULT_POLLING_INTERVAL_S
    # サービスごとの有効と無効。書かれていない id は無効として扱う。
    # 配信側にサービスが増えても、黙って通知が増えないためである。
    property services : Hash(String, Bool) = Settings.default_services
    # 設定ファイルにだけ持ち、画面には出さない。
    # dev 環境や手元のサーバへ向けて動作を確かめるための項目である。
    property feed_url : String = DEFAULT_FEED_URL

    def initialize
    end

    def self.default_services : Hash(String, Bool)
      KNOWN_SERVICES.keys.to_h { |id| {id, DEFAULT_ENABLED_SERVICES.includes?(id)} }
    end

    def self.from_section(section : JSON::Any?) : Settings
      return Settings.new if section.nil?
      Settings.from_json(section.to_json)
    end

    def service_enabled?(id : String) : Bool
      @services[id]? || false
    end

    # 設定 GUI と起動時の検証で使う。エラーメッセージの配列を返し、空なら妥当とみなす。
    def self.validate(section : JSON::Any?) : Array(String)
      errors = [] of String
      settings = begin
        from_section(section)
      rescue ex : JSON::Error
        return ["sources.service_status の書式が不正である: #{ex.message}"]
      end

      unless POLLING_INTERVAL_RANGE.includes?(settings.polling_interval_s)
        errors << "sources.service_status.polling_interval_s は " \
                  "#{POLLING_INTERVAL_RANGE.begin} から #{POLLING_INTERVAL_RANGE.end} の範囲で指定する"
      end

      uri = URI.parse(settings.feed_url) rescue nil
      unless uri && uri.scheme.in?("http", "https") && uri.host.try(&.empty?) == false
        errors << "sources.service_status.feed_url は http か https の URL で指定する"
      end
      errors
    end
  end
end

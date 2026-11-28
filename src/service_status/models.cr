require "json"
require "uri"

# ソース実装：外部サービスの障害検知（issue #5）。
#
# VRChat や YouTube の障害を VR の中で知るためのソースである。
# VR プレイ中に「VRChat 側の障害なのか自環境の問題なのか」を切り分けるのが目的であり、
# 稼働状態が変わり、その状態が続いたときだけ通知を出す。
#
# 取得元は各サービスのステータスページではなく、集約サーバー（status-server/）の配信 JSON である。
# あちらが 1 分ごとに各サービスを見て 4 段階のレベルへ判定済みで配っており、
# 本体側に Statuspage の読み方や合成監視の判定を持ち込まずに済む。
# この JSON の形は、移設前のリポジトリ（VRCServiceStatusPanel）の仕様書 4 章にある。
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
  # 配信側の並び（status-server/backend の main.cr）に合わせてある。
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

  # 取得元の集約サーバー（status-server/）。設定画面から開けるようにする。
  # 今の状態を見るページと、配信の中身を説明した文書の置き場所である。
  PAGE_URL       = "https://vrc-status.oxymoron.link/index.html"
  REPOSITORY_URL = "https://github.com/limit7412/KxNotifyUtils/tree/master/status-server"

  # 既定で知らせるサービス。issue #5 のコメントで決めた 3 つである。
  DEFAULT_ENABLED_SERVICES = %w[vrchat youtube steam]

  # sources.service_status セクション。
  class Settings
    include JSON::Serializable

    # 配信 JSON の置き場所。prod の配信である。
    DEFAULT_FEED_URL = "https://vrc-status.oxymoron.link/v1/status.json"
    # dev の配信。集約サーバーの変更を prod へ出す前に、ここで確かめる。
    DEV_FEED_URL = "https://vrc-status-dev.oxymoron.link/v1/status.json"

    # 設定ウィンドウで選べる取得先。
    # custom は、設定ファイルへ手で書いた、どちらでもない URL を指す。
    FEED_ENVIRONMENTS = %w[prod dev custom]

    # 配信は 1 分ごとに更新される。それより短くしても変化に早く気付けない。
    DEFAULT_POLLING_INTERVAL_S = 60
    POLLING_INTERVAL_RANGE     = 30..3600

    # 段階が変わってから知らせるまでに、その状態が続くべき長さ（秒）。
    #
    # 配信はおよそ 60 秒ごとに作られるが、生成時刻は取得元の応答待ちで数秒揺れる。
    # 60 の倍数を既定にすると、同じ回数の配信でも揺れ次第で届いたり届かなかったりする。
    # 既定は倍数の中間に置き、「何回続いたら知らせるか」が揺れで変わらないようにする。
    #
    # 150 秒は、正常でない配信が 4 回続いたときに届く。集約サーバーの合成監視は
    # 直近 3 回の観測で判定するため、単発の取得失敗でも一部障害が 3 回（約 120 秒）続く。
    # 4 回目を待てば、単発の失敗は知らせずに済む。
    DEFAULT_DEGRADED_FOR_S = 150
    # 30 秒は、大規模障害の配信が 2 回続いたときに届く。
    DEFAULT_MAJOR_OUTAGE_FOR_S = 30
    # 90 秒は、正常な配信が 3 回続いたときに届く。
    DEFAULT_RECOVERED_FOR_S = 90
    # 0 は、変わった回にそのまま知らせることを表す。
    FOR_RANGE = 0..3600

    property enabled : Bool = true
    property polling_interval_s : Int32 = DEFAULT_POLLING_INTERVAL_S
    property degraded_for_s : Int32 = DEFAULT_DEGRADED_FOR_S
    property major_outage_for_s : Int32 = DEFAULT_MAJOR_OUTAGE_FOR_S
    property recovered_for_s : Int32 = DEFAULT_RECOVERED_FOR_S
    # サービスごとの有効と無効。書かれていない id は無効として扱う。
    # 配信側にサービスが増えても、黙って通知が増えないためである。
    property services : Hash(String, Bool) = Settings.default_services
    # dev 環境や手元のサーバへ向けて動作を確かめるための項目である。
    # 設定ウィンドウには、prod と dev の切り替えとしてだけ出す。出すのはプレリリースの
    # ビルドと、取得先が既に prod でないときに限る（Runtime::SettingsWindow）。
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

    # いまの取得先が、設定ウィンドウの選択肢のどれに当たるか。
    def feed_environment : String
      case @feed_url
      when DEFAULT_FEED_URL then "prod"
      when DEV_FEED_URL     then "dev"
      else                       "custom"
      end
    end

    # 設定ウィンドウで選んだ取得先を feed_url へ直す。
    #
    # custom を選んだときは URL を変えない。custom は「設定ファイルに書いた URL のまま」を
    # 意味し、画面から URL を入力する項目は無いためである。
    def select_feed_environment(environment : String) : Nil
      case environment
      when "prod" then @feed_url = DEFAULT_FEED_URL
      when "dev"  then @feed_url = DEV_FEED_URL
      end
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

      {
        "degraded_for_s"     => settings.degraded_for_s,
        "major_outage_for_s" => settings.major_outage_for_s,
        "recovered_for_s"    => settings.recovered_for_s,
      }.each do |key, value|
        next if FOR_RANGE.includes?(value)
        errors << "sources.service_status.#{key} は #{FOR_RANGE.begin} から #{FOR_RANGE.end} の範囲で指定する"
      end

      uri = URI.parse(settings.feed_url) rescue nil
      unless uri && uri.scheme.in?("http", "https") && uri.host.try(&.empty?) == false
        errors << "sources.service_status.feed_url は http か https の URL で指定する"
      end
      errors
    end
  end
end

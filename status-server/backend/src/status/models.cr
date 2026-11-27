require "json"

# 中核。外部に依存せず、HTTP も JSON の取得も知らない（仕様書 11.3）。
module Status
  # 全サービス共通のレベル（仕様書 3.1）。
  # 配信 JSON にはこの列挙の値がそのまま整数で入る。
  # ワールド側はこの数値で色を引くだけで、判定はすべてここから先で行う。
  enum Level
    Operational
    Degraded
    MajorOutage
    Unknown

    # 配信 JSON の label（仕様書 4）。
    def label : String
      case self
      in Operational
        "Operational"
      in Degraded
        "Degraded"
      in MajorOutage
        "Major Outage"
      in Unknown
        "Unknown"
      end
    end
  end

  # 一回の取得の結果（仕様書 11.4）。ヒステリシスの入力になる。
  enum Outcome
    Success
    Failure
    # bot 検知に相当する応答など、成否を判定できなかった場合（仕様書 3.3）
    Indeterminate
  end

  # 取得元の種別。配信 JSON の source に入る（仕様書 4）。
  # 仕様書 7.4 が予約する reported は第一弾では使わないため持たない。
  enum SourceKind
    Official
    Synthetic

    # 配信 JSON へ入れる文字列。
    def key : String
      case self
      in Official
        "official"
      in Synthetic
        "synthetic"
      end
    end
  end

  # 配信 JSON の components 要素（仕様書 4）。
  struct Component
    include JSON::Serializable

    getter name : String
    getter level : Int32

    def initialize(@name : String, level : Level)
      @level = level.value
    end
  end

  # 一回の取得結果。取得元アダプタが返す唯一の型（仕様書 11.4）。
  # observe は例外を外に出さず、失敗もこの型の outcome として返す。
  struct Observation
    getter service_id : String
    getter outcome : Outcome
    getter checked_at : Time
    getter latency : Time::Span?
    getter note : String
    getter components : Array(Component)?
    # 公式ステータスページから写した level（仕様書 11.5）。
    # 合成監視は履歴から決めるため、そちらの観測では nil になる。
    getter level : Level?
    # 届いたが、一部の経路が落ちている（仕様書 3.3）。
    #
    # Steam はストアだけ、BOOTH は商品ページだけが落ちることがある。
    # そのサービスが使えないわけではないので失敗とは数えず、合成監視は
    # 一段の低下として扱う。
    getter? partial : Bool

    def initialize(
      @service_id : String,
      @outcome : Outcome,
      @checked_at : Time,
      @latency : Time::Span? = nil,
      @note : String = "",
      @components : Array(Component)? = nil,
      @level : Level? = nil,
      @partial : Bool = false,
    )
    end

    def success? : Bool
      outcome.success?
    end
  end

  # サービスごとの直近三回の outcome（仕様書 3.3、11.4）。
  # 新しいものほど後ろに入る。
  struct History
    include JSON::Serializable

    CAPACITY = 3

    getter outcomes : Array(Outcome)

    def initialize(@outcomes : Array(Outcome) = [] of Outcome)
    end

    # 直近三回だけを残した新しい History を返す。
    def push(outcome : Outcome) : History
      History.new((outcomes + [outcome]).last(CAPACITY))
    end

    def failure_count : Int32
      outcomes.count(&.failure?)
    end

    # 直近が bot 検知などで判定できなかったか。
    # 過去ではなく最新の結果だけを見る。判定不能は復旧の有無を語れないため、
    # 一度でも起きたら以後ずっと Unknown になってしまう。
    def indeterminate? : Bool
      outcomes.last?.try(&.indeterminate?) || false
    end

    def empty? : Bool
      outcomes.empty?
    end
  end

  # 配信 JSON の services 要素（仕様書 4）。
  # Observation と History から usecase が生成する。
  struct ServiceStatus
    include JSON::Serializable

    # note の上限。仕様書 4 の「全角換算 40 字」を半角換算で持つ。
    NOTE_MAX_WIDTH = 80

    getter id : String
    getter name : String
    getter level : Int32
    getter label : String
    getter note : String
    getter source : String
    getter url : String
    getter checked_unix : Int64
    getter components : Array(Component)?

    def initialize(
      @id : String,
      @name : String,
      level : Level,
      source : SourceKind,
      @url : String,
      checked_at : Time,
      note : String = "",
      @components : Array(Component)? = nil,
    )
      @level = level.value
      @label = level.label
      @source = source.key
      @checked_unix = checked_at.to_unix
      @note = ServiceStatus.format_note(note)
    end

    # note を一行に整える（仕様書 4）。
    # 改行を含む制御文字を除去し、全角換算 40 字で切り詰める。
    # 整形はここで一度だけ行い、アダプタ側では行わない（仕様書 11.5）。
    def self.format_note(note : String) : String
      truncate(strip_control(note))
    end

    private def self.strip_control(note : String) : String
      String.build do |io|
        note.each_char do |char|
          io << char unless char.control?
        end
      end
    end

    private def self.truncate(note : String) : String
      width = 0
      String.build do |io|
        note.each_char do |char|
          char_width = width_of(char)
          break if width + char_width > NOTE_MAX_WIDTH
          width += char_width
          io << char
        end
      end
    end

    # 半角を 1、全角を 2 として数える。
    # 東アジアの文字幅を厳密に判定はせず、ASCII と半角カナだけを半角として扱う。
    # note は表示の切り詰めにしか使わないため、境界の文字で 1 幅ずれても影響しない。
    private def self.width_of(char : Char) : Int32
      return 1 if char.ascii?
      return 1 if (0xFF61..0xFF9F).includes?(char.ord)
      2
    end
  end

  # 配信 JSON 全体（仕様書 4）。
  struct Feed
    include JSON::Serializable

    # 互換性のない変更で増やす（仕様書 4、9）。
    SCHEMA_VERSION = 1

    # JST は夏時間を持たないため、tzdata に依存せず固定オフセットで扱う。
    # alpine の静的ビルドへ tzdata を同梱せずに済ませる狙いもある。
    JST = Time::Location.fixed(9 * 3600)

    @[JSON::Field(key: "v")]
    getter version : Int32
    getter generated_unix : Int64
    getter generated_jst : String
    getter? stale : Bool
    getter services : Array(ServiceStatus)

    def initialize(generated_at : Time, @stale : Bool, @services : Array(ServiceStatus))
      @version = SCHEMA_VERSION
      @generated_unix = generated_at.to_unix
      @generated_jst = Feed.format_jst(generated_at)
    end

    # Udon 側は ISO 8601 を解析しないため、整形済みの文字列を併せて配る（仕様書 4）。
    def self.format_jst(time : Time) : String
      time.in(JST).to_s("%Y/%m/%d %H:%M")
    end
  end

  # 内部バケットへ保存する状態（仕様書 6、11.4）。
  # 合成監視の履歴と、取得に失敗したときへ引き継ぐ前回値を持つ。
  struct State
    include JSON::Serializable

    # 保存する形の版。中身の意味が変わる直しで増やす。
    #
    # 配信 JSON の v とは別に数える。外へ配るものと内部の記録は変わる理由が
    # 違い、片方の都合でもう片方の版を動かすと、読み手の判断がずれる。
    SCHEMA_VERSION = 1

    # 版を持たない記録は 0 として読む。
    #
    # JSON::Serializable は知らないキーを読み捨てるので、版を持たせずに形を
    # 変えると、古い記録が「履歴が空」として通ってしまう。合成監視の判定が
    # 黙って振り出しに戻るだけなので、気付く手がかりが残らない。
    # 既定値を置けば、版の無い記録を読めないものとして弾ける。
    @[JSON::Field(key: "v")]
    getter version : Int32 = 0

    getter histories : Hash(String, History)
    getter services : Hash(String, ServiceStatus)

    def initialize(
      @histories : Hash(String, History) = {} of String => History,
      @services : Hash(String, ServiceStatus) = {} of String => ServiceStatus,
    )
      @version = SCHEMA_VERSION
    end

    # このコードが読める版か。
    def supported? : Bool
      version == SCHEMA_VERSION
    end

    def history_of(service_id : String) : History
      histories[service_id]? || History.new
    end

    def service_of(service_id : String) : ServiceStatus?
      services[service_id]?
    end
  end
end

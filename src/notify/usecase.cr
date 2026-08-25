require "log"
require "./models"
require "./repository"

module Notify
  # 中継の 1 周期を担うユースケース（仕様書 4.2 節、4.3 節）。
  #
  # 依存するのは SourceRepository と PostRepository の抽象、ソース別の MessageBuilder、
  # そして設定スナップショットだけである。
  # 差分検出はソース実装に、整形はソース側の MessageBuilder に閉じているため、
  # ここが持つのはパイプラインの順序制御と fan-out に限られる。
  class RelayUsecase
    Log = ::Log.for("notify")

    # 中継の一時停止（トレイメニューから切り替える）。
    property paused : Bool = false

    # 設定スナップショット。
    # 差し替えは代入 1 回で済み、周期の途中で新旧が混ざらない（仕様書 4.8.2 節）。
    property config : ::Config::Root

    getter sources : Array(SourceRepository)
    getter sinks : Array(PostRepository)

    # ソース別の直近の観測結果。
    # 設定 GUI がルールの match_app_id を選ばせるための入力補助に使う（仕様書 4.8.1 節）。
    getter observed_apps : Hash(String, String) = {} of String => String

    def initialize(
      @sources : Array(SourceRepository),
      @sinks : Array(PostRepository),
      builders : Array(MessageBuilder),
      @config : ::Config::Root,
    )
      @builders = {} of String => MessageBuilder
      builders.each { |b| @builders[b.source_id] = b }
      @next_due = {} of String => Time::Span
      @relayed = Hash(String, Int32).new(0)
      @delivered = Hash(String, Int32).new(0)
      @dropped = Hash(String, Int32).new(0)
      @stats_since = Time.monotonic
    end

    # ポーリングの 1 拍。
    # 呼び出し間隔よりソースのポーリング間隔のほうが長い場合に備え、ソースごとに次回時刻を持つ。
    #
    # 時刻には単調時計を使う。
    # 壁時計だと、時刻同期や利用者の時計修正でシステム時刻が後退したとき、
    # 時計が元の値へ追いつくまでどのソースもポーリングされなくなるためである。
    def tick(now : Time::Span = Time.monotonic) : Nil
      snapshot = @config
      @sources.each do |source|
        next unless source.ready?
        due = @next_due[source.source_id]?
        next if due && now < due
        @next_due[source.source_id] = now + source.poll_interval

        incomings = begin
          source.poll_new
        rescue ex
          Log.error(exception: ex) { "ソース #{source.source_id} のポーリングに失敗した" }
          next
        end

        next if @paused
        incomings.each { |incoming| relay(incoming, snapshot) }
      end

      flush_stats(now)
    end

    # 1 件の通知をフィルタ、ルール解決、整形、fan-out の順に処理する（仕様書 4.3 節）。
    def relay(incoming : Incoming, snapshot : ::Config::Root = @config) : Bool
      @observed_apps[incoming.app_id] = incoming.app_name

      unless snapshot.filter.allow?(incoming.app_id)
        Log.debug { "フィルタで除外した: #{incoming.source} #{incoming.app_id}" }
        return false
      end

      builder = @builders[incoming.source]?
      unless builder
        Log.error { "ソース #{incoming.source} に対応する MessageBuilder が無い" }
        return false
      end

      settings = snapshot.resolve_rule(incoming.app_id)
      message = builder.build(incoming, settings)
      Log.debug { "中継する: #{incoming.source} #{incoming.app_id} #{message.title}" }
      @relayed[incoming.source] += 1
      deliver(message)
      true
    end

    # 全シンクへ同報する。
    # あるシンクの失敗が他のシンクへの送信を妨げないよう、シンクごとに失敗を閉じ込める。
    def deliver(message : Message) : Nil
      @sinks.each do |sink|
        ok = begin
          sink.send_message(message)
        rescue ex
          Log.error(exception: ex) { "シンク #{sink.sink_id} への送信で例外が出た" }
          false
        end

        if ok
          @delivered[sink.sink_id] += 1
        else
          @dropped[sink.sink_id] += 1
          Log.debug { "シンク #{sink.sink_id} へ送信できず破棄した" }
        end
      end
    end

    # 設定 GUI とトレイメニューから呼ぶ疎通確認用の送信。
    # 実際の中継と同じ整形を通すため、見た目と音をそのまま確認できる。
    def send_test(settings : ::Config::Resolved, source_id : String = "windows") : Nil
      builder = @builders[source_id]? || @builders.first_value?
      return unless builder

      incoming = Incoming.new(
        source: builder.source_id,
        app_id: "kairo.kxnotifyutils",
        app_name: "KxNotifyUtils",
        title: "テスト通知",
        body: "この表示と音で通知が届く。",
      )
      deliver(builder.build(incoming, settings))
    end

    # 中継件数を 1 分ごとにログへ落とす（仕様書 6 章）。
    private def flush_stats(now : Time::Span) : Nil
      return if now - @stats_since < 1.minute
      @stats_since = now

      return if @relayed.empty? && @delivered.empty? && @dropped.empty?
      Log.info do
        "中継件数 ソース別=#{@relayed.to_a.sort_by(&.[0])} " \
        "シンク別=#{@delivered.to_a.sort_by(&.[0])} 破棄=#{@dropped.to_a.sort_by(&.[0])}"
      end
      @relayed.clear
      @delivered.clear
      @dropped.clear
    end
  end
end

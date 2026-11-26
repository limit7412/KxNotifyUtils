require "../spec_helper"

private def history_of(*outcomes : Status::Outcome) : Status::History
  outcomes.reduce(Status::History.new) { |history, outcome| history.push(outcome) }
end

# 決めた結果だけを返す取得元。判定の規則そのものを試すために使う。
#
# started、release、finished を渡すと、呼ばれたことを報せ、合図を待ち、
# 返す直前にもう一度報せる。
# 実行の重なりと結果の届く順を、経過時間ではなく順序で確かめるための仕掛けである。
# 時間で測ると、混んでいるランナーで待ち時間が延びただけで赤くなる。
private class FakeSource < Status::SourceRepository
  getter service_id : String
  getter display_name : String
  getter display_url : String
  getter source_kind : Status::SourceKind

  def initialize(
    @service_id : String,
    @source_kind : Status::SourceKind = Status::SourceKind::Official,
    @observation : Status::Observation? = nil,
    @error : Exception? = nil,
    @started : Channel(Nil)? = nil,
    @release : Channel(Nil)? = nil,
    @finished : Channel(Nil)? = nil,
    @display_name : String = "表示名",
    @display_url : String = "https://example.test",
  )
  end

  def observe : Status::Observation
    @started.try(&.send(nil))
    @release.try(&.receive)

    if error = @error
      raise error
    end

    observation = @observation || raise "観測を渡していない"
    @finished.try(&.send(nil))
    observation
  end
end

# 書いたものと、その順番を覚えておく書き出し先。
private class FakeFeeds < Status::FeedRepository
  getter states = [] of Status::State
  getter feeds = [] of Status::Feed
  getter calls = [] of String

  def initialize(@state : Status::State? = nil)
  end

  def load_state : Status::State?
    @state
  end

  def save_state(state : Status::State) : Nil
    @calls << "state"
    @states << state
  end

  def save_feed(feed : Status::Feed) : Nil
    @calls << "feed"
    @feeds << feed
  end
end

# 書き出しで落ちる書き出し先。R2 の PUT が失敗した場合を模す。
private class BrokenFeeds < FakeFeeds
  def save_feed(feed : Status::Feed) : Nil
    raise IO::Error.new("PUT が失敗した")
  end
end

private NOW = Time.unix(1_756_123_200)

private def success(
  id : String,
  level : Status::Level,
  note : String = "",
  latency : Time::Span? = nil,
  partial : Bool = false,
)
  Status::Observation.new(
    service_id: id,
    outcome: Status::Outcome::Success,
    checked_at: NOW,
    latency: latency,
    note: note,
    level: level,
    partial: partial,
  )
end

private def failure(id : String, note : String = "HTTP 500")
  Status::Observation.new(
    service_id: id,
    outcome: Status::Outcome::Failure,
    checked_at: NOW,
    note: note,
  )
end

private def previous_status(id : String, level : Status::Level, note : String, checked_at : Time)
  Status::ServiceStatus.new(
    id: id,
    name: "表示名",
    level: level,
    source: Status::SourceKind::Official,
    url: "https://example.test",
    checked_at: checked_at,
    note: note,
  )
end

private def refresh(sources : Array(Status::SourceRepository), feeds : FakeFeeds) : Status::Feed
  Status::Usecase.new(sources, feeds).refresh(NOW)
end

# 待って受け取る。来なければ spec を落とす。
# 期待が外れたときに spec 全体が止まったままにならないようにする。
private def receive_within(channel : Channel(T), reason : String) : T forall T
  select
  when value = channel.receive
    value
  when timeout(5.seconds)
    fail reason
  end
end

describe Status::Usecase do
  describe "#refresh" do
    it "公式ステータスページの応答をそのまま写す" do
      source = FakeSource.new(
        service_id: "vrchat",
        observation: success("vrchat", Status::Level::Degraded, "Websocket: Partial Outage"),
      )
      feeds = FakeFeeds.new

      feed = refresh([source] of Status::SourceRepository, feeds)

      service = feed.services.first
      service.id.should eq "vrchat"
      service.level.should eq Status::Level::Degraded.value
      service.note.should eq "Websocket: Partial Outage"
      service.checked_unix.should eq NOW.to_unix
      feed.stale?.should be_false
    end

    # 取得の失敗はこちら側の事情であって、上流が落ちたことではない（仕様書 5.3）。
    it "公式ステータスページを取れなければ前回値を引き継ぐ" do
      checked_at = NOW - 1.minute
      state = Status::State.new(
        services: {
          "vrchat" => previous_status("vrchat", Status::Level::Degraded, "前回の note", checked_at),
        }
      )
      source = FakeSource.new(service_id: "vrchat", observation: failure("vrchat"))

      feed = refresh([source] of Status::SourceRepository, FakeFeeds.new(state))

      service = feed.services.first
      service.level.should eq Status::Level::Degraded.value
      service.note.should eq "前回の note"
      service.checked_unix.should eq checked_at.to_unix
    end

    it "五分取れないままなら判定不能にする" do
      checked_at = NOW - 5.minutes
      state = Status::State.new(
        services: {
          "vrchat" => previous_status("vrchat", Status::Level::Operational, "前回の note", checked_at),
        }
      )
      source = FakeSource.new(service_id: "vrchat", observation: failure("vrchat"))

      feed = refresh([source] of Status::SourceRepository, FakeFeeds.new(state))

      service = feed.services.first
      service.level.should eq Status::Level::Unknown.value
      # 判定できないと言いながら中身を説明し続けることになるので、note も落とす。
      service.note.should eq ""
      # 最後に取れた時刻だけは動かさない。
      service.checked_unix.should eq checked_at.to_unix
    end

    it "境界の手前では前回値を保つ" do
      checked_at = NOW - 5.minutes + 1.second
      state = Status::State.new(
        services: {
          "vrchat" => previous_status("vrchat", Status::Level::Operational, "", checked_at),
        }
      )
      source = FakeSource.new(service_id: "vrchat", observation: failure("vrchat"))

      feed = refresh([source] of Status::SourceRepository, FakeFeeds.new(state))

      feed.services.first.level.should eq Status::Level::Operational.value
    end

    it "一度も取れていなければ判定不能から始める" do
      source = FakeSource.new(service_id: "vrchat", observation: failure("vrchat"))

      feed = refresh([source] of Status::SourceRepository, FakeFeeds.new)

      service = feed.services.first
      service.level.should eq Status::Level::Unknown.value
      # 取得できた時刻が無いことを 0 で表す。
      service.checked_unix.should eq 0
      # 失敗の理由はログに残すもので、表示には出さない。
      service.note.should eq ""
    end

    it "合成監視は履歴から決める" do
      state = Status::State.new(
        histories: {"steam" => history_of(Status::Outcome::Failure)}
      )
      source = FakeSource.new(
        service_id: "steam",
        source_kind: Status::SourceKind::Synthetic,
        observation: failure("steam"),
      )
      feeds = FakeFeeds.new(state)

      feed = refresh([source] of Status::SourceRepository, feeds)

      # 前回と今回で二回失敗しているので全断とみなす（仕様書 3.3）。
      feed.services.first.level.should eq Status::Level::MajorOutage.value
      feeds.states.first.history_of("steam").outcomes.size.should eq 2
    end

    # 届かなかったこと自体が判定の材料なので、前回値へは戻さない。
    it "合成監視は失敗しても最後に見た時刻を進める" do
      state = Status::State.new(
        services: {
          "steam" => previous_status("steam", Status::Level::Operational, "", NOW - 1.hour),
        }
      )
      source = FakeSource.new(
        service_id: "steam",
        source_kind: Status::SourceKind::Synthetic,
        observation: failure("steam"),
      )

      feed = refresh([source] of Status::SourceRepository, FakeFeeds.new(state))

      service = feed.services.first
      service.level.should eq Status::Level::Degraded.value
      service.checked_unix.should eq NOW.to_unix
    end

    # Steam のストアだけ、BOOTH の商品ページだけが落ちた場合にあたる。
    # 届いてはいるので失敗には数えず、一段の低下として扱う。
    it "合成監視は経路の一部の停止を一段の低下として扱う" do
      source = FakeSource.new(
        service_id: "steam",
        source_kind: Status::SourceKind::Synthetic,
        observation: success("steam", Status::Level::Operational, partial: true),
      )
      feeds = FakeFeeds.new

      feed = refresh([source] of Status::SourceRepository, feeds)

      feed.services.first.level.should eq Status::Level::Degraded.value
      # 届いてはいるので、履歴には成功として積む。
      feeds.states.first.history_of("steam").outcomes.should eq [Status::Outcome::Success]
    end

    it "一部が止まっただけの取得元は記録に並べない" do
      source = FakeSource.new(
        service_id: "steam",
        source_kind: Status::SourceKind::Synthetic,
        observation: success("steam", Status::Level::Operational, partial: true),
      )

      Log.capture("status", :warn) do |logs|
        refresh([source] of Status::SourceRepository, FakeFeeds.new)

        logs.empty
      end
    end

    # 東京の Lambda から見た応答は平常時でも 1〜2 秒あり、3 秒を超える回は
    # 日に数回、どれも単発だった。一回の超過で黄にすると、その回だけ点いて
    # 次の回に消える黄が日に数回出る。遅かったことは note で伝え、level は動かさない。
    it "合成監視は遅くても level を下げず note にだけ残す" do
      source = FakeSource.new(
        service_id: "steam",
        source_kind: Status::SourceKind::Synthetic,
        observation: success("steam", Status::Level::Operational, latency: 3.seconds),
      )
      feeds = FakeFeeds.new

      feed = refresh([source] of Status::SourceRepository, feeds)

      service = feed.services.first
      service.level.should eq Status::Level::Operational.value
      service.note.should eq "応答に 3.0 秒"
      # 届いてはいるので、履歴には成功として積む。
      feeds.states.first.history_of("steam").outcomes.should eq [Status::Outcome::Success]
    end

    it "合成監視は基準の手前なら遅さを書かない" do
      source = FakeSource.new(
        service_id: "steam",
        source_kind: Status::SourceKind::Synthetic,
        observation: success("steam", Status::Level::Operational, latency: 3.seconds - 1.millisecond),
      )

      feed = refresh([source] of Status::SourceRepository, FakeFeeds.new)

      service = feed.services.first
      service.level.should eq Status::Level::Operational.value
      service.note.should eq ""
    end

    # level は直近三回から決まるのに、note は今回の観測しか語らない。
    # 今回届いたのに前回が落ちていれば、黄のまま説明が空になる。
    it "合成監視は今回届いても直近の失敗を note に残す" do
      state = Status::State.new(histories: {"steam" => history_of(Status::Outcome::Failure)})
      source = FakeSource.new(
        service_id: "steam",
        source_kind: Status::SourceKind::Synthetic,
        observation: success("steam", Status::Level::Operational),
      )

      feed = refresh([source] of Status::SourceRepository, FakeFeeds.new(state))

      service = feed.services.first
      service.level.should eq Status::Level::Degraded.value
      service.note.should eq "直近 2 回中 1 回届かず"
    end

    # 障害の終わりがけは必ずこの形になる。赤のまま説明が無いのがいちばん困る。
    it "合成監視は二回落ちたあとに届いても赤の理由を残す" do
      state = Status::State.new(
        histories: {"steam" => history_of(Status::Outcome::Failure, Status::Outcome::Failure)},
      )
      source = FakeSource.new(
        service_id: "steam",
        source_kind: Status::SourceKind::Synthetic,
        observation: success("steam", Status::Level::Operational),
      )

      feed = refresh([source] of Status::SourceRepository, FakeFeeds.new(state))

      service = feed.services.first
      service.level.should eq Status::Level::MajorOutage.value
      service.note.should eq "直近 3 回中 2 回届かず"
    end

    it "合成監視は直近の失敗と遅さを並べて残す" do
      state = Status::State.new(histories: {"steam" => history_of(Status::Outcome::Failure)})
      source = FakeSource.new(
        service_id: "steam",
        source_kind: Status::SourceKind::Synthetic,
        observation: success("steam", Status::Level::Operational, latency: 4.6.seconds),
      )

      feed = refresh([source] of Status::SourceRepository, FakeFeeds.new(state))

      feed.services.first.note.should eq "直近 2 回中 1 回届かず、応答に 4.6 秒"
    end

    # 二つの経路を持つ取得元は、どちらが遅いかまで書いて渡してくる。
    # それを秒数で上書きすると、見る先の情報が落ちる。
    it "合成監視は取得元の note があれば遅さを書き足さない" do
      source = FakeSource.new(
        service_id: "steam",
        source_kind: Status::SourceKind::Synthetic,
        observation: success("steam", Status::Level::Operational, note: "ストア: 応答に 4.6 秒", latency: 4.6.seconds),
      )

      feed = refresh([source] of Status::SourceRepository, FakeFeeds.new)

      feed.services.first.note.should eq "ストア: 応答に 4.6 秒"
    end

    it "合成監視は今回届かなければ取得元の理由だけを残す" do
      state = Status::State.new(histories: {"steam" => history_of(Status::Outcome::Failure)})
      source = FakeSource.new(
        service_id: "steam",
        source_kind: Status::SourceKind::Synthetic,
        observation: failure("steam", "Web API に届かない（Read timed out）"),
      )

      feed = refresh([source] of Status::SourceRepository, FakeFeeds.new(state))

      service = feed.services.first
      service.level.should eq Status::Level::MajorOutage.value
      service.note.should eq "Web API に届かない（Read timed out）"
    end

    # observe は例外を出さない契約だが（仕様書 11.4）、破られても他は止めない。
    it "一つの取得元が例外を出しても他のサービスを更新する" do
      broken = FakeSource.new(service_id: "vrchat", error: Exception.new("壊れている"))
      working = FakeSource.new(
        service_id: "discord",
        observation: success("discord", Status::Level::Operational),
      )

      feed = refresh([broken, working] of Status::SourceRepository, FakeFeeds.new)

      feed.services.map(&.id).should eq ["vrchat", "discord"]
      feed.services.first.level.should eq Status::Level::Unknown.value
      feed.services.last.level.should eq Status::Level::Operational.value
    end

    # official の失敗は前回値へ戻るだけで、表示にも stale にも出ない。
    # 記録が唯一の手がかりなので、そこに何が落ちたかを残す。
    it "取れなかった取得元を記録に残す" do
      sources = [
        FakeSource.new(service_id: "vrchat", observation: failure("vrchat", "HTTP 500")),
        FakeSource.new(
          service_id: "discord",
          observation: success("discord", Status::Level::Operational),
        ),
      ] of Status::SourceRepository

      Log.capture("status") do |logs|
        refresh(sources, FakeFeeds.new)

        logs.check(:warn, /vrchat/)
        message = logs.entry.message
        message.should contain("vrchat")
        message.should contain("HTTP 500")
        # 取れたものは並べない。読む相手が要るのは落ちたほうである。
        message.should_not contain("discord")
      end
    end

    it "すべて取れたときは警告を残さない" do
      source = FakeSource.new(
        service_id: "vrchat",
        observation: success("vrchat", Status::Level::Operational),
      )

      # 所要時間は INFO で毎回残るので、警告以上だけを捕まえる。
      Log.capture("status", :warn) do |logs|
        refresh([source] of Status::SourceRepository, FakeFeeds.new)

        logs.empty
      end
    end

    # REPORT 行には実行全体の時間しか出ない。どの上流が遅いかは、ここにしか残らない。
    it "一回の実行の内訳を記録に残す" do
      sources = [
        FakeSource.new(
          service_id: "vrchat",
          observation: success("vrchat", Status::Level::Operational, latency: 412.milliseconds),
        ),
        FakeSource.new(service_id: "discord", observation: failure("discord", "HTTP 500")),
      ] of Status::SourceRepository

      Log.capture("status") do |logs|
        refresh(sources, FakeFeeds.new)

        logs.check(:info, /所要/)
        message = logs.entry.message
        message.should match(/load=\d+ms observe=\d+ms save=\d+ms/)
        message.should match(/vrchat=\d+ms/)
        # 取れなかったものにも時間が付く。タイムアウトで落ちた一つがいちばん知りたいものである。
        message.should match(/discord=\d+ms/)
      end
    end

    # R2 が遅延源のときほど書き出しで落ちる。そのときに限って内訳が抜けてはならない。
    it "書き出しが落ちても内訳を残してから例外を出す" do
      source = FakeSource.new(
        service_id: "vrchat",
        observation: success("vrchat", Status::Level::Operational),
      )

      Log.capture("status") do |logs|
        expect_raises(IO::Error, "PUT が失敗した") do
          refresh([source] of Status::SourceRepository, BrokenFeeds.new)
        end

        logs.check(:info, /所要 .*save=\d+ms/)
      end
    end

    it "ひとつも取れなければ stale にする" do
      source = FakeSource.new(service_id: "vrchat", observation: failure("vrchat"))

      refresh([source] of Status::SourceRepository, FakeFeeds.new).stale?.should be_true
    end

    it "ひとつでも取れれば stale にしない" do
      sources = [
        FakeSource.new(service_id: "vrchat", observation: failure("vrchat")),
        FakeSource.new(service_id: "discord", observation: success("discord", Status::Level::Operational)),
      ] of Status::SourceRepository

      refresh(sources, FakeFeeds.new).stale?.should be_false
    end

    # 結果は先に終わったものから届く。
    # 並びは渡した順に戻し、level はそれを返した取得元へ結びつける。
    # 名前だけを見ても足りない。名前は取得元から取るので、観測と取り違えても
    # 並びは渡した順のままに見え、色だけが入れ替わる。
    it "届いた順によらず、結果を返した取得元に結びつける" do
      hold = Channel(Nil).new
      second_done = Channel(Nil).new(1)
      sources = [
        FakeSource.new(
          service_id: "first",
          observation: success("first", Status::Level::Operational),
          release: hold,
        ),
        FakeSource.new(
          service_id: "second",
          observation: success("second", Status::Level::MajorOutage),
          finished: second_done,
        ),
      ] of Status::SourceRepository
      done = Channel(Status::Feed).new

      spawn { done.send(Status::Usecase.new(sources, FakeFeeds.new).refresh(NOW)) }

      # 二つ目が返すまで一つ目を止めておく。結果は渡した順の逆で届く。
      receive_within(second_done, "二つ目が返らなかった")
      hold.send(nil)

      feed = receive_within(done, "refresh が終わらなかった")

      feed.services.map(&.id).should eq ["first", "second"]
      feed.services.map(&.level).should eq [
        Status::Level::Operational.value,
        Status::Level::MajorOutage.value,
      ]
    end

    it "取得元を並列に呼ぶ" do
      started = Channel(Nil).new(2)
      release = Channel(Nil).new(2)
      sources = [
        FakeSource.new(
          service_id: "a",
          observation: success("a", Status::Level::Operational),
          started: started,
          release: release,
        ),
        FakeSource.new(
          service_id: "b",
          observation: success("b", Status::Level::Operational),
          started: started,
          release: release,
        ),
      ] of Status::SourceRepository
      done = Channel(Status::Feed).new

      spawn { done.send(Status::Usecase.new(sources, FakeFeeds.new).refresh(NOW)) }

      # どちらも解放しないまま、二つとも始まることを見る。
      # 順に呼んでいれば、一つ目が解放を待つあいだ二つ目は始まらないので、
      # 二度目の受け取りが空振りする。
      2.times { receive_within(started, "取得元が並んで始まらなかった") }

      2.times { release.send(nil) }

      receive_within(done, "refresh が終わらなかった").services.size.should eq 2
    end

    # 配信を先にすると、その間に落ちたとき、配っている内容の根拠が内部に残らない。
    it "状態を書いてから配信する" do
      source = FakeSource.new(
        service_id: "vrchat",
        observation: success("vrchat", Status::Level::Operational),
      )
      feeds = FakeFeeds.new

      refresh([source] of Status::SourceRepository, feeds)

      feeds.calls.should eq ["state", "feed"]
    end

    it "次の実行へ引き継ぐ状態を書く" do
      source = FakeSource.new(
        service_id: "vrchat",
        observation: success("vrchat", Status::Level::Degraded, "note"),
      )
      feeds = FakeFeeds.new

      refresh([source] of Status::SourceRepository, feeds)

      state = feeds.states.first
      state.version.should eq Status::State::SCHEMA_VERSION
      state.service_of("vrchat").try(&.note).should eq "note"
      state.history_of("vrchat").outcomes.should eq [Status::Outcome::Success]
    end
  end

  describe ".level_for_synthetic" do
    it "is operational when every recent check succeeded" do
      history = history_of(
        Status::Outcome::Success,
        Status::Outcome::Success,
        Status::Outcome::Success,
      )

      Status::Usecase.level_for_synthetic(history).should eq Status::Level::Operational
    end

    it "is degraded after a single failure" do
      history = history_of(
        Status::Outcome::Success,
        Status::Outcome::Failure,
        Status::Outcome::Success,
      )

      Status::Usecase.level_for_synthetic(history).should eq Status::Level::Degraded
    end

    it "is degraded when the latency threshold was exceeded" do
      history = history_of(
        Status::Outcome::Success,
        Status::Outcome::Success,
        Status::Outcome::Success,
      )

      Status::Usecase.level_for_synthetic(history, degraded: true)
        .should eq Status::Level::Degraded
    end

    it "is a major outage from the second failure" do
      history = history_of(
        Status::Outcome::Failure,
        Status::Outcome::Success,
        Status::Outcome::Failure,
      )

      Status::Usecase.level_for_synthetic(history).should eq Status::Level::MajorOutage
    end

    it "is unknown when the latest response looked like bot detection" do
      history = history_of(
        Status::Outcome::Failure,
        Status::Outcome::Failure,
        Status::Outcome::Indeterminate,
      )

      Status::Usecase.level_for_synthetic(history).should eq Status::Level::Unknown
    end

    it "judges from the current run alone when no history was restored" do
      Status::Usecase.level_for_synthetic(Status::History.new)
        .should eq Status::Level::Operational

      Status::Usecase.level_for_synthetic(history_of(Status::Outcome::Failure))
        .should eq Status::Level::Degraded
    end
  end
end

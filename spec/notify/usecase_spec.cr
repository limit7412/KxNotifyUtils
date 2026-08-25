require "../spec_helper"

private def incoming(app_id = "com.squirrel.Discord.Discord", source = "windows")
  Notify::Incoming.new(
    source: source,
    app_id: app_id,
    app_name: "Discord",
    title: "件名",
    body: "本文",
  )
end

private def build_usecase(sources, sinks, config = Config::Root.default)
  Notify::RelayUsecase.new(
    sources: sources,
    sinks: sinks,
    builders: [WinNotification::MessageBuilder.new(Fakes::Icons.new).as(Notify::MessageBuilder)],
    config: config,
  )
end

describe Notify::RelayUsecase do
  it "各ソースの poll_new の結果をすべてパイプラインに乗せる" do
    source_a = Fakes::Source.new("windows", [[incoming, incoming(app_id: "com.example.A")]])
    sink = Fakes::Sink.new("xsoverlay")
    usecase = build_usecase([source_a.as(Notify::SourceRepository)], [sink.as(Notify::PostRepository)])

    usecase.tick

    sink.sent.size.should eq 2
  end

  it "1 つのソースがポーリングに失敗しても他のソースの中継は続く" do
    broken = Fakes::BrokenSource.new("broken")
    healthy = Fakes::Source.new("windows", [[incoming]])
    sink = Fakes::Sink.new("xsoverlay")
    usecase = build_usecase(
      [broken.as(Notify::SourceRepository), healthy.as(Notify::SourceRepository)],
      [sink.as(Notify::PostRepository)],
    )

    usecase.tick

    sink.sent.size.should eq 1
  end

  it "ポーリング間隔が経過していないソースは呼ばない" do
    source = Fakes::Source.new("windows", [] of Array(Notify::Incoming), 500.milliseconds)
    usecase = build_usecase([source.as(Notify::SourceRepository)], [] of Notify::PostRepository)

    now = Time.utc
    usecase.tick(now)
    usecase.tick(now + 100.milliseconds)
    usecase.tick(now + 600.milliseconds)

    source.poll_count.should eq 2
  end

  it "中継を一時停止している間は送信しない" do
    source = Fakes::Source.new("windows", [[incoming]])
    sink = Fakes::Sink.new("xsoverlay")
    usecase = build_usecase([source.as(Notify::SourceRepository)], [sink.as(Notify::PostRepository)])
    usecase.paused = true

    usecase.tick

    sink.sent.should be_empty
  end

  describe "フィルタ" do
    it "blacklist にある app_id を落とす" do
      config = Config::Root.from_json(%({"filter": {"mode": "blacklist", "apps": ["com.squirrel.Discord"]}}))
      sink = Fakes::Sink.new("xsoverlay")
      usecase = build_usecase([] of Notify::SourceRepository, [sink.as(Notify::PostRepository)], config)

      usecase.relay(incoming).should be_false
      sink.sent.should be_empty
    end

    it "whitelist にある app_id だけを通す" do
      config = Config::Root.from_json(%({"filter": {"mode": "whitelist", "apps": ["com.squirrel.Discord"]}}))
      sink = Fakes::Sink.new("xsoverlay")
      usecase = build_usecase([] of Notify::SourceRepository, [sink.as(Notify::PostRepository)], config)

      usecase.relay(incoming).should be_true
      usecase.relay(incoming(app_id: "Microsoft.OutlookForWindows")).should be_false
      sink.sent.size.should eq 1
    end
  end

  describe "fan-out" do
    it "全シンクへ同報する" do
      first = Fakes::Sink.new("xsoverlay")
      second = Fakes::Sink.new("discord_webhook")
      usecase = build_usecase(
        [] of Notify::SourceRepository,
        [first.as(Notify::PostRepository), second.as(Notify::PostRepository)],
      )

      usecase.relay(incoming)

      first.sent.size.should eq 1
      second.sent.size.should eq 1
    end

    it "1 つのシンクの送信失敗が他のシンクへの送信を妨げない" do
      failing = Fakes::Sink.new("xsoverlay")
      failing.fail = true
      healthy = Fakes::Sink.new("discord_webhook")
      usecase = build_usecase(
        [] of Notify::SourceRepository,
        [failing.as(Notify::PostRepository), healthy.as(Notify::PostRepository)],
      )

      usecase.relay(incoming)

      failing.sent.should be_empty
      healthy.sent.size.should eq 1
    end

    it "シンクが例外を投げても他のシンクへの送信は続く" do
      raising = Fakes::Sink.new("xsoverlay")
      raising.raise_on_send = true
      healthy = Fakes::Sink.new("discord_webhook")
      usecase = build_usecase(
        [] of Notify::SourceRepository,
        [raising.as(Notify::PostRepository), healthy.as(Notify::PostRepository)],
      )

      usecase.relay(incoming)

      healthy.sent.size.should eq 1
    end

    it "送信できなかった通知はキューせず破棄する" do
      sink = Fakes::Sink.new("xsoverlay")
      sink.fail = true
      usecase = build_usecase([] of Notify::SourceRepository, [sink.as(Notify::PostRepository)])

      usecase.relay(incoming)
      sink.fail = false
      usecase.relay(incoming)

      sink.sent.size.should eq 1
    end
  end

  it "対応する MessageBuilder が無いソースの通知は中継しない" do
    sink = Fakes::Sink.new("xsoverlay")
    usecase = build_usecase([] of Notify::SourceRepository, [sink.as(Notify::PostRepository)])

    usecase.relay(incoming(source: "vrchat_log")).should be_false
    sink.sent.should be_empty
  end

  it "テスト通知は編集中の設定を使って全シンクへ送る" do
    sink = Fakes::Sink.new("xsoverlay")
    usecase = build_usecase([] of Notify::SourceRepository, [sink.as(Notify::PostRepository)])

    resolved = Config::Defaults.from_json(%({"volume": 0.9, "title_template": "{title}"})).to_resolved
    usecase.send_test(resolved)

    sink.sent.size.should eq 1
    sink.sent.first.volume.should eq 0.9
    sink.sent.first.title.should eq "テスト通知"
  end

  it "観測した app_id を設定 GUI の入力補助のために覚える" do
    usecase = build_usecase([] of Notify::SourceRepository, [] of Notify::PostRepository)

    usecase.relay(incoming)

    usecase.observed_apps["com.squirrel.Discord.Discord"].should eq "Discord"
  end
end

require "../spec_helper"

private TEXTS = ServiceStatus::Texts.new(
  degraded: "一部で障害が発生",
  major_outage: "大規模な障害が発生",
  recovered: "復旧",
)

private def feed_json(services : Hash(String, Int32), generated : Int64 = 1_i64, stale : Bool = false, version : Int32 = 1) : String
  entries = services.map do |id, level|
    %({"id": "#{id}", "name": "#{id.capitalize}", "level": #{level}, "label": "L#{level}", "note": "note-#{id}"})
  end
  %({"v": #{version}, "generated_unix": #{generated}, "stale": #{stale}, "services": [#{entries.join(",")}]})
end

private def repository(client = Fakes::FeedClient.new, settings = ServiceStatus::Settings.new) : ServiceStatus::Repository
  ServiceStatus::Repository.new(client, settings, TEXTS)
end

describe ServiceStatus::Repository do
  describe "#ingest（差分検出）" do
    it "初回の配信は覚えるだけで、進行中の障害を知らせない" do
      target = repository

      target.ingest(feed_json({"vrchat" => 2, "youtube" => 0})).should be_empty
    end

    it "レベルが変わったサービスだけを Incoming にする" do
      target = repository
      target.ingest(feed_json({"vrchat" => 0, "youtube" => 0}, generated: 1))

      fresh = target.ingest(feed_json({"vrchat" => 1, "youtube" => 0}, generated: 2))

      fresh.size.should eq 1
      incoming = fresh.first
      incoming.source.should eq "service_status"
      incoming.app_id.should eq "service_status.vrchat"
      incoming.app_name.should eq "Vrchat"
      incoming.title.should eq "一部で障害が発生"
      incoming.body.should eq "note-vrchat"
      incoming.icon.should eq Notify::Icon.builtin("warning")
      incoming.created_at.should eq Time.unix(2)
    end

    it "大規模な障害と復旧で文言とアイコンを変える" do
      target = repository
      target.ingest(feed_json({"vrchat" => 0}, generated: 1))

      outage = target.ingest(feed_json({"vrchat" => 2}, generated: 2)).first
      outage.title.should eq "大規模な障害が発生"
      outage.icon.should eq Notify::Icon.builtin("error")

      recovered = target.ingest(feed_json({"vrchat" => 0}, generated: 3)).first
      recovered.title.should eq "復旧"
      recovered.icon.should eq Notify::Icon.builtin("default")
    end

    it "note が空なら label を本文にする" do
      target = repository
      target.ingest(%({"v": 1, "generated_unix": 1, "services": [{"id": "vrchat", "level": 0}]}))

      fresh = target.ingest(
        %({"v": 1, "generated_unix": 2, "services": [{"id": "vrchat", "name": "VRChat", "level": 2, "label": "Major Outage"}]}))

      fresh.first.body.should eq "Major Outage"
      fresh.first.app_name.should eq "VRChat"
    end

    it "無効にしているサービスの変化は知らせない" do
      target = repository
      target.ingest(feed_json({"vrchat" => 0, "discord" => 0}, generated: 1))

      target.ingest(feed_json({"vrchat" => 0, "discord" => 2}, generated: 2)).should be_empty
    end

    it "判定不能を挟んだ往復では知らせない" do
      target = repository
      target.ingest(feed_json({"vrchat" => 0}, generated: 1))

      target.ingest(feed_json({"vrchat" => 3}, generated: 2)).should be_empty
      target.ingest(feed_json({"vrchat" => 0}, generated: 3)).should be_empty
    end

    it "判定不能の間に起きた変化は、判定できるようになった時点で知らせる" do
      target = repository
      target.ingest(feed_json({"vrchat" => 0}, generated: 1))
      target.ingest(feed_json({"vrchat" => 3}, generated: 2))

      target.ingest(feed_json({"vrchat" => 2}, generated: 3)).size.should eq 1
    end

    it "初回から判定不能だったサービスは、判定できた回を初回として覚える" do
      target = repository
      target.ingest(feed_json({"vrchat" => 3}, generated: 1))

      target.ingest(feed_json({"vrchat" => 2}, generated: 2)).should be_empty
      target.ingest(feed_json({"vrchat" => 0}, generated: 3)).size.should eq 1
    end

    it "stale の配信は比べない" do
      target = repository
      target.ingest(feed_json({"vrchat" => 0}, generated: 1))

      target.ingest(feed_json({"vrchat" => 2}, generated: 2, stale: true)).should be_empty
      # stale が明けて障害が続いていれば、そこで知らせる。
      target.ingest(feed_json({"vrchat" => 2}, generated: 3)).size.should eq 1
    end

    it "生成時刻が同じ配信は二度読まない" do
      target = repository
      target.ingest(feed_json({"vrchat" => 0}, generated: 1))

      target.ingest(feed_json({"vrchat" => 2}, generated: 1)).should be_empty
    end

    it "生成時刻を持たない配信は毎回比べる" do
      target = repository
      target.ingest(%({"v": 1, "services": [{"id": "vrchat", "level": 0}]}))

      target.ingest(%({"v": 1, "services": [{"id": "vrchat", "level": 2}]})).size.should eq 1
    end

    it "読めない版の配信は無視する" do
      target = repository
      target.ingest(feed_json({"vrchat" => 0}, generated: 1))

      target.ingest(feed_json({"vrchat" => 2}, generated: 2, version: 2)).should be_empty
      # 版が戻れば続きから比べる。
      target.ingest(feed_json({"vrchat" => 2}, generated: 3)).size.should eq 1
    end

    it "壊れた JSON は無視する" do
      repository.ingest("{ broken").should be_empty
    end
  end

  describe "#settings=" do
    it "無効にしたサービスの記録を捨て、有効に戻したときは初回として覚え直す" do
      target = repository
      target.ingest(feed_json({"vrchat" => 0}, generated: 1))

      disabled = ServiceStatus::Settings.from_json(%({"services": {"vrchat": false}}))
      target.settings = disabled
      target.ingest(feed_json({"vrchat" => 2}, generated: 2)).should be_empty

      target.settings = ServiceStatus::Settings.new
      # 無効にしていた間の変化は知らせない。
      target.ingest(feed_json({"vrchat" => 2}, generated: 3)).should be_empty
      target.ingest(feed_json({"vrchat" => 0}, generated: 4)).size.should eq 1
    end

    it "取得先が変わったら前回値を捨てる" do
      client = Fakes::FeedClient.new
      target = repository(client)
      target.ingest(feed_json({"vrchat" => 0}, generated: 1))

      target.settings = ServiceStatus::Settings.from_json(%({"feed_url": "http://localhost:8000/status.json"}))

      client.reset_count.should eq 1
      target.ingest(feed_json({"vrchat" => 2}, generated: 1)).should be_empty
    end
  end

  describe "#poll_new" do
    it "取れた本文を前回と比べ、次は設定の間隔が過ぎるまで取りに行かない" do
      client = Fakes::FeedClient.new([
        ServiceStatus::Response.body(feed_json({"vrchat" => 0}, generated: 1)),
        ServiceStatus::Response.body(feed_json({"vrchat" => 2}, generated: 2)),
      ])
      target = repository(client)
      target.start

      target.poll_new.should be_empty
      # 間隔が過ぎていないので取りに行かない。
      target.poll_new.should be_empty
      client.urls.size.should eq 1
      client.urls.first.should eq ServiceStatus::Settings::DEFAULT_FEED_URL
    end

    it "取れるまでは次の呼び出しで聞き直す" do
      client = Fakes::FeedClient.new([
        ServiceStatus::Response.pending,
        ServiceStatus::Response.pending,
        ServiceStatus::Response.body(feed_json({"vrchat" => 0}, generated: 1)),
      ])
      target = repository(client)
      target.start

      3.times { target.poll_new }

      client.urls.size.should eq 3
      client.responses.should be_empty
    end

    it "失敗しても例外を上げず、次の間隔で取り直す" do
      client = Fakes::FeedClient.new([ServiceStatus::Response.failed("届かない")])
      target = repository(client)
      target.start

      target.poll_new.should be_empty
    end

    it "poll_interval は設定の間隔より短い" do
      repository.poll_interval.should eq 1.second
    end

    it "開始し直したら前回値と取りかけを捨てる" do
      client = Fakes::FeedClient.new
      target = repository(client)
      target.ingest(feed_json({"vrchat" => 0}, generated: 1))

      target.stop
      target.start

      client.reset_count.should eq 1
      target.ingest(feed_json({"vrchat" => 2}, generated: 2)).should be_empty
    end
  end
end

describe ServiceStatus::MessageBuilder do
  it "Incoming に載せた組み込みアイコンを app 指定でそのまま使う" do
    builder = ServiceStatus::MessageBuilder.new(Fakes::Icons.new)
    incoming = Notify::Incoming.new(
      source: "service_status",
      app_id: "service_status.vrchat",
      app_name: "VRChat",
      title: "一部で障害が発生",
      body: "Login: Partial Outage",
      icon: Notify::Icon.builtin("warning"),
    )

    message = builder.build(incoming, Config::Defaults.new.to_resolved)

    builder.source_id.should eq "service_status"
    message.title.should eq "VRChat: 一部で障害が発生"
    message.icon.should eq Notify::Icon.builtin("warning")
  end
end

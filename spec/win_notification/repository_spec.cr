require "../spec_helper"

private def notifications_json(ids : Array(Int32) = [] of Int32) : String
  entries = ids.map do |id|
    %({"id": #{id}, "app_id": "com.example.App", "app_name": "App", "title": "件名#{id}", "body": "本文"})
  end
  %({"notifications": [#{entries.join(",")}]})
end

describe WinNotification::Repository do
  it "初回のポーリングは既読とみなして空を返す" do
    client = Fakes::ShimClient.new([notifications_json([1, 2])])
    repository = WinNotification::Repository.new(client, WinNotification::Settings.new)

    repository.poll_new.should be_empty
  end

  it "2 回目以降は新しい id の通知だけを返す" do
    client = Fakes::ShimClient.new([
      notifications_json([1, 2]),
      notifications_json([1, 2, 3]),
    ])
    repository = WinNotification::Repository.new(client, WinNotification::Settings.new)
    repository.poll_new

    fresh = repository.poll_new
    fresh.size.should eq 1
    fresh.first.title.should eq "件名3"
    fresh.first.source.should eq "windows"
  end

  it "消えた id を集合から除去し、同じ id が再登場したら新規として扱う" do
    client = Fakes::ShimClient.new([
      notifications_json([1]),
      notifications_json,
      notifications_json([1]),
    ])
    repository = WinNotification::Repository.new(client, WinNotification::Settings.new)
    repository.poll_new
    repository.poll_new.should be_empty

    repository.poll_new.size.should eq 1
  end

  it "アイコンがあれば base64 のアイコンとして中立形式に載せる" do
    client = Fakes::ShimClient.new([
      notifications_json,
      %({"notifications": [{"id": 7, "app_id": "a", "icon_png_base64": "iVBORw0KGgo="}]}),
    ])
    repository = WinNotification::Repository.new(client, WinNotification::Settings.new)
    repository.poll_new

    icon = repository.poll_new.first.icon.should_not be_nil
    icon.base64?.should be_true
    icon.value.should eq "iVBORw0KGgo="
  end

  it "開始し直したら差分検出をやり直し、残っている通知を一斉に中継しない" do
    client = Fakes::ShimClient.new([
      notifications_json([1]),
      notifications_json([1, 2]),
      notifications_json([1, 2]),
    ])
    repository = WinNotification::Repository.new(client, WinNotification::Settings.new)
    repository.poll_new
    repository.poll_new.size.should eq 1

    # 無効にしてから有効に戻す経路。停止と開始をまたいでも既読の扱いは起動時と同じにする。
    repository.stop
    repository.start

    repository.poll_new.should be_empty
  end

  it "ポーリング間隔を設定から取る" do
    settings = WinNotification::Settings.from_json(%({"polling_interval_ms": 250}))
    repository = WinNotification::Repository.new(Fakes::ShimClient.new, settings)

    repository.poll_interval.should eq 250.milliseconds
  end

  it "起動後に許可が取り消されたら中継の対象から外れる" do
    client = Fakes::ShimClient.new
    repository = WinNotification::Repository.new(client, WinNotification::Settings.new, 10.milliseconds)
    repository.start
    repository.ready?.should be_true

    client.status = WinNotification::AccessStatus::Denied
    sleep 20.milliseconds

    repository.ready?.should be_false
  end

  it "許可が戻ったときは差分検出をやり直し、拒否中に届いた通知を一斉に中継しない" do
    client = Fakes::ShimClient.new([
      notifications_json([1]),
      notifications_json([1, 2]),
      notifications_json([1, 2]),
    ])
    repository = WinNotification::Repository.new(client, WinNotification::Settings.new, 10.milliseconds)
    repository.start
    repository.poll_new

    client.status = WinNotification::AccessStatus::Denied
    sleep 20.milliseconds
    repository.ready?.should be_false

    client.status = WinNotification::AccessStatus::Allowed
    sleep 20.milliseconds
    repository.ready?.should be_true

    # 拒否されていた間に届いて通知センターに残っている分は既読として扱う。
    repository.poll_new.should be_empty
  end

  it "通知アクセスが未許可の間は中継の対象にならない" do
    client = Fakes::ShimClient.new
    client.status = WinNotification::AccessStatus::Denied
    repository = WinNotification::Repository.new(client, WinNotification::Settings.new)
    repository.start

    repository.ready?.should be_false
  end
end

describe WinNotification::Settings do
  it "ポーリング間隔が範囲外なら検証で弾く" do
    WinNotification::Settings.validate(JSON.parse(%({"polling_interval_ms": 50}))).should_not be_empty
    WinNotification::Settings.validate(JSON.parse(%({"polling_interval_ms": 500}))).should be_empty
  end
end

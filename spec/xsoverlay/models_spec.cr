require "../spec_helper"

private def message(icon = nil, hints = Notify::DisplayHints.new(175.0, 1.0))
  Notify::Message.new(
    title: "Discord: 件名",
    body: "本文",
    icon: icon,
    timeout: 6.5,
    sound: "default",
    volume: 0.7,
    source_app: "KxNotifyUtils",
    hints: hints,
  )
end

describe XSOverlay::NotificationObject do
  it "中立形式のコアをワイヤ形式へ対応づける" do
    object = XSOverlay::NotificationObject.from_message(message)

    object.type.should eq 1
    object.title.should eq "Discord: 件名"
    object.content.should eq "本文"
    object.timeout.should eq 6.5
    object.audio_path.should eq "default"
    object.volume.should eq 0.7
    object.source_app.should eq "KxNotifyUtils"
  end

  it "表示ヒントの height と opacity も載せる" do
    object = XSOverlay::NotificationObject.from_message(message(hints: Notify::DisplayHints.new(210.0, 0.8)))

    object.height.should eq 210.0
    object.opacity.should eq 0.8
  end

  it "base64 のアイコンでは useBase64Icon を立てる" do
    object = XSOverlay::NotificationObject.from_message(message(icon: Notify::Icon.base64("PNG")))

    object.use_base64_icon.should be_true
    object.icon.should eq "PNG"
  end

  it "組み込みアイコンでは useBase64Icon を立てない" do
    object = XSOverlay::NotificationObject.from_message(message(icon: Notify::Icon.builtin("warning")))

    object.use_base64_icon.should be_false
    object.icon.should eq "warning"
  end

  it "JSON では XSOverlay が読むキー名を使う" do
    json = JSON.parse(XSOverlay::NotificationObject.from_message(message).to_json)

    json["audioPath"].as_s.should eq "default"
    json["useBase64Icon"].as_bool.should be_false
    json["sourceApp"].as_s.should eq "KxNotifyUtils"
  end
end

describe XSOverlay::Envelope do
  it "通知オブジェクトを jsonData に文字列として包む" do
    envelope = XSOverlay::Envelope.for(XSOverlay::NotificationObject.from_message(message))
    json = JSON.parse(envelope.to_json)

    json["sender"].as_s.should eq "KxNotifyUtils"
    json["target"].as_s.should eq "xsoverlay"
    json["command"].as_s.should eq "SendNotification"
    JSON.parse(json["jsonData"].as_s)["title"].as_s.should eq "Discord: 件名"
  end
end

describe XSOverlay::Settings do
  it "transport を websocket と udp で読み分ける" do
    XSOverlay::Settings.from_json(%({"transport": "websocket"})).transport.should eq XSOverlay::Transport::Websocket
    XSOverlay::Settings.from_json(%({"transport": "udp"})).transport.should eq XSOverlay::Transport::Udp
  end

  it "ポート番号が範囲外なら検証で弾く" do
    XSOverlay::Settings.validate(JSON.parse(%({"websocket_port": 0}))).should_not be_empty
    XSOverlay::Settings.validate(JSON.parse(%({"websocket_port": 42070}))).should be_empty
  end
end

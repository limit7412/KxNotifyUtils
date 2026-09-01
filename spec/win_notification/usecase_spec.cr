require "../spec_helper"
require "../../src/runtime/i18n"

private def incoming(title = "件名", body = "本文", app_name = "Discord", icon = nil)
  Notify::Incoming.new(
    source: "windows",
    app_id: "com.squirrel.Discord.Discord",
    app_name: app_name,
    title: title,
    body: body,
    icon: icon,
  )
end

private def settings(**overrides)
  defaults = Config::Defaults.new
  base = defaults.to_resolved
  Config::Resolved.new(
    timeout_mode: overrides[:timeout_mode]? || base.timeout_mode,
    timeout: overrides[:timeout]? || base.timeout,
    dynamic_timeout: overrides[:dynamic_timeout]? || base.dynamic_timeout,
    max_body_length: overrides[:max_body_length]? || base.max_body_length,
    title_template: overrides[:title_template]? || base.title_template,
    icon: overrides[:icon]? || base.icon,
    opacity: overrides[:opacity]? || base.opacity,
    volume: overrides[:volume]? || base.volume,
    sound: overrides[:sound]? || base.sound,
  )
end

describe WinNotification::MessageBuilder do
  # 簡単設定の最短は、今の見え方と比べる起点として fixed の既定に合わせてある（issue #45）。
  #
  # テスト通知の文字数では base + 文字数 / reading_speed が 1.0 を下回り、min でそこまで持ち上がる。
  # 辞書の文言を伸ばすと文字数が増え、min から浮いて 1 秒でなくなる。
  # 起点が黙ってずれないよう、辞書側を変えたときにここが落ちるようにしてある。
  it "最短のプリセットはテスト通知を fixed の既定と同じ 1 秒で出す（issue #45）" do
    builder = WinNotification::MessageBuilder.new(Fakes::Icons.new)
    resolved = settings(
      timeout_mode: Config::TimeoutMode::Dynamic,
      dynamic_timeout: Config::DynamicTimeout::PRESETS["shortest"],
    )

    begin
      Runtime::I18n::LOCALES.each_key do |locale|
        Runtime::I18n.locale = locale
        # 件名と本文と app_name は RelayUsecase#send_test が渡すものに揃える。
        message = builder.build(
          incoming(
            title: Runtime::I18n.t("notify.test.title"),
            body: Runtime::I18n.t("notify.test.body"),
            app_name: "KxNotifyUtils",
          ),
          resolved,
        )

        message.timeout.should eq(Config::Defaults.new.timeout), "ロケール #{locale} で 1 秒にならない"
      end
    ensure
      Runtime::I18n.locale = Runtime::I18n::DEFAULT_LOCALE
    end
  end

  it "title テンプレートを展開する" do
    builder = WinNotification::MessageBuilder.new(Fakes::Icons.new)

    message = builder.build(incoming, settings)
    message.title.should eq "Discord: 件名"
  end

  it "差し込んだ通知の文字列をプレースホルダとして解釈しない" do
    builder = WinNotification::MessageBuilder.new(Fakes::Icons.new)

    message = builder.build(
      incoming(title: "{body}", body: "あ" * 300),
      settings(title_template: "{title}", max_body_length: 10),
    )
    message.title.should eq "{body}"
  end

  it "max_body_length を超える本文を切り詰める" do
    builder = WinNotification::MessageBuilder.new(Fakes::Icons.new)

    message = builder.build(incoming(body: "あ" * 300), settings(max_body_length: 200))
    message.body.size.should eq 201
    message.body.ends_with?("…").should be_true
  end

  it "max_body_length が 0 なら本文を載せない" do
    builder = WinNotification::MessageBuilder.new(Fakes::Icons.new)

    builder.build(incoming(body: "本文"), settings(max_body_length: 0)).body.should eq ""
  end

  it "fixed モードでは timeout をそのまま使う" do
    builder = WinNotification::MessageBuilder.new(Fakes::Icons.new)

    message = builder.build(incoming, settings(timeout_mode: Config::TimeoutMode::Fixed, timeout: 10.0))
    message.timeout.should eq 10.0
  end

  it "dynamic モードでは文字数から表示時間を求め min と max でクランプする" do
    builder = WinNotification::MessageBuilder.new(Fakes::Icons.new)
    dynamic = Config::DynamicTimeout.new(base: 2.0, reading_speed: 12.0, min: 3.0, max: 15.0)

    # 既定の timeout_mode は fixed であるため、ここでは明示して切り替える。
    mode = Config::TimeoutMode::Dynamic

    short = builder.build(
      incoming(title: "", body: ""), settings(timeout_mode: mode, dynamic_timeout: dynamic))
    short.timeout.should eq 3.0

    long = builder.build(
      incoming(body: "あ" * 200), settings(timeout_mode: mode, dynamic_timeout: dynamic))
    long.timeout.should eq 15.0
  end

  describe "アイコンの解決" do
    it "app 指定では通知から取れたアイコンを使う" do
      builder = WinNotification::MessageBuilder.new(Fakes::Icons.new)

      message = builder.build(incoming(icon: Notify::Icon.base64("PNG")), settings(icon: "app"))
      message.icon.should eq Notify::Icon.base64("PNG")
    end

    it "app 指定でアイコンが取れなければ default へ落とす" do
      builder = WinNotification::MessageBuilder.new(Fakes::Icons.new)

      message = builder.build(incoming, settings(icon: "app"))
      message.icon.should eq Notify::Icon.builtin("default")
    end

    it "組み込みアイコン名はそのままシンボル名として載せる" do
      builder = WinNotification::MessageBuilder.new(Fakes::Icons.new)

      message = builder.build(incoming, settings(icon: "warning"))
      message.icon.should eq Notify::Icon.builtin("warning")
    end

    it "ファイルパス指定では読み込んだ PNG を base64 で載せる" do
      icons = Fakes::Icons.new
      icons.files["C:/icons/mail.png"] = "BASE64DATA"
      builder = WinNotification::MessageBuilder.new(icons)

      message = builder.build(incoming, settings(icon: "C:/icons/mail.png"))
      message.icon.should eq Notify::Icon.base64("BASE64DATA")
    end

    it "ファイルが読めなければ default へ落とす" do
      builder = WinNotification::MessageBuilder.new(Fakes::Icons.new)

      message = builder.build(incoming, settings(icon: "C:/icons/missing.png"))
      message.icon.should eq Notify::Icon.builtin("default")
    end
  end

  describe "表示ヒント" do
    it "本文が無い通知は高さを最小にする" do
      builder = WinNotification::MessageBuilder.new(Fakes::Icons.new)

      builder.build(incoming(body: ""), settings).hints.height.should eq 100.0
    end

    it "本文がある通知は高さを上限でクランプする" do
      builder = WinNotification::MessageBuilder.new(Fakes::Icons.new)

      builder.build(incoming(body: "あ" * 500), settings).hints.height.should eq 250.0
    end

    it "opacity をルールから引く" do
      builder = WinNotification::MessageBuilder.new(Fakes::Icons.new)

      builder.build(incoming, settings(opacity: 0.6)).hints.opacity.should eq 0.6
    end
  end
end

require "../spec_helper"

private def usecase(stored : String? = nil, existing_files = [] of String, png_files : Array(String)? = nil)
  repository = Fakes::ConfigRepository.new(stored)
  repository.existing_files = existing_files
  repository.png_files = png_files
  target = Config::Usecase.new(repository)
  # composition root と同じく、組み立てられるシンクの検証を登録する。
  target.register_validator("sinks.xsoverlay") { |section| XSOverlay::Settings.validate(section) }
  {target, repository}
end

describe Config::Usecase do
  # 例外で抜けると load が捕まえられず、既定値で起動するはずの経路がアプリ終了になる。
  it "オブジェクトでない通知先セクションを、例外ではなく検証エラーにする" do
    ["null", "[1, 2]", "3", %("text")].each do |raw|
      target, _ = usecase(stored: %({"sinks": {"xsoverlay": #{raw}}}))

      errors = target.load
      errors.should_not be_empty
      errors.map(&.message).any?(&.includes?("書式")).should be_true
    end
  end

  describe "読めなかった設定ファイルの扱い" do
    # 既定値で書き戻すと、利用者が直す前にルールごと内容を失う。
    it "読めていない間は自動の保存で書き出さず、反映だけを行う" do
      target, repository = usecase(stored: "{ broken")
      target.load.should_not be_empty
      target.readable?.should be_false
      before = repository.save_count

      target.save(target.current.with_steamvr(true, "C:/KxNotifyUtils.exe")).should be_empty

      repository.save_count.should eq before
      target.current.steamvr.auto_launch_registered.should be_true
    end

    it "設定画面からの保存は読めていなくても書き出す" do
      target, repository = usecase(stored: "{ broken")
      target.load
      before = repository.save_count

      target.save(Config::Root.default, overwrite_unreadable: true).should be_empty

      repository.save_count.should eq before + 1
      target.readable?.should be_true
    end
  end

  describe "#load" do
    it "設定ファイルが無ければ初期設定を書き出す" do
      target, repository = usecase
      target.load.should be_empty

      repository.save_count.should eq 1
      target.current.sinks.keys.should eq ["xsoverlay"]
    end

    it "壊れた JSON では直前の有効な設定を維持する" do
      target, _ = usecase(%({"defaults": ))
      before = target.current

      errors = target.load

      errors.should_not be_empty
      target.current.should be before
    end
  end

  describe "#reload" do
    it "不正な設定を読んだら直前の有効な設定を維持する" do
      target, repository = usecase(Config::Root.default.to_json)
      target.load
      applied = [] of Config::Root
      target.on_apply = ->(root : Config::Root) { applied << root; nil }

      repository.stored = %({"sinks": {}})
      errors = target.reload

      errors.should_not be_empty
      applied.should be_empty
      target.current.sinks.keys.should eq ["xsoverlay"]
    end
  end

  describe "#save" do
    it "検証を通った設定だけを保存し、スナップショットを差し替える" do
      target, repository = usecase(Config::Root.default.to_json)
      target.load
      applied = [] of Config::Root
      target.on_apply = ->(root : Config::Root) { applied << root; nil }

      updated = Config::Root.default
      updated.defaults.volume = 0.9

      target.save(updated).should be_empty
      applied.size.should eq 1
      target.current.defaults.volume.should eq 0.9
      repository.save_count.should eq 1
    end

    it "保存しても、それ以前に取り出したスナップショットは変わらない" do
      target, _ = usecase(Config::Root.default.to_json)
      target.load
      before = target.current

      updated = Config::Root.default
      updated.defaults.volume = 0.9
      target.save(updated).should be_empty

      before.defaults.volume.should eq 0.5
      target.current.should_not be before
    end

    it "検証エラーがあるときは保存も反映もしない" do
      target, repository = usecase(Config::Root.default.to_json)
      target.load
      saved_before = repository.save_count

      invalid = Config::Root.default
      invalid.defaults.volume = 2.0

      target.save(invalid).should_not be_empty
      repository.save_count.should eq saved_before
      target.current.defaults.volume.should eq 0.5
    end
  end

  describe "#validate" do
    it "全シンクが無効な設定を弾く" do
      target, _ = usecase
      root = Config::Root.from_json(%({"sinks": {"xsoverlay": {"enabled": false}}}))

      target.validate(root).map(&.section).should contain "通知先"
    end

    it "シンクが 1 つも無い設定を弾く" do
      target, _ = usecase

      target.validate(Config::Root.from_json("{}")).should_not be_empty
    end

    it "組み立てられないシンクだけが有効な設定を弾く" do
      target, _ = usecase
      root = Config::Root.from_json(<<-JSON)
        {"sinks": {"xsoverlay": {"enabled": false}, "discord_webhook": {"enabled": true}}}
        JSON

      target.validate(root).map(&.section).should contain "通知先"
    end

    it "数値範囲を外れた項目を弾く" do
      target, _ = usecase
      root = Config::Root.default
      root.defaults.opacity = 1.5
      root.defaults.timeout = 0.0

      messages = target.validate(root).map(&.message)
      messages.any?(&.includes?("opacity")).should be_true
      messages.any?(&.includes?("timeout")).should be_true
    end

    it "存在しない音声ファイルを指したルールを弾く" do
      target, _ = usecase
      root = Config::Root.default
      rule = Config::Rule.new("com.squirrel.Discord")
      rule.sound = "C:/sounds/missing.wav"
      root.rules << rule

      target.validate(root).map(&.message).any?(&.includes?("sound")).should be_true
    end

    it "存在する音声ファイルは通す" do
      target, _ = usecase(existing_files: ["C:/sounds/discord.wav"])
      root = Config::Root.default
      rule = Config::Rule.new("com.squirrel.Discord")
      rule.sound = "C:/sounds/discord.wav"
      root.rules << rule

      target.validate(root).should be_empty
    end

    it "PNG でないアイコンのファイルを弾く" do
      target, _ = usecase(existing_files: ["C:/icons/notes.txt"], png_files: [] of String)
      root = Config::Root.default
      root.defaults.icon = "C:/icons/notes.txt"

      target.validate(root).map(&.message).any?(&.includes?("PNG")).should be_true
    end

    it "PNG のアイコンは通す" do
      target, _ = usecase(existing_files: ["C:/icons/discord.png"], png_files: ["C:/icons/discord.png"])
      root = Config::Root.default
      root.defaults.icon = "C:/icons/discord.png"

      target.validate(root).should be_empty
    end

    it "空文字列の sound はミュートとして通す" do
      target, _ = usecase
      root = Config::Root.default
      root.defaults.sound = ""

      target.validate(root).should be_empty
    end

    # 画面が入れた係数が保存の検証で弾かれると、段階を選んだ時点で保存できなくなる（issue #45）。
    it "簡単設定のどのプリセットも検証を通る" do
      target, _ = usecase

      Config::DynamicTimeout::PRESETS.each do |name, preset|
        root = Config::Root.default
        root.defaults.timeout_mode = Config::TimeoutMode::Dynamic
        root.defaults.dynamic_timeout = preset

        target.validate(root).should be_empty, "プリセット #{name} が検証を通らない"
      end
    end

    it "match_app_id が空のルールを弾く" do
      target, _ = usecase
      root = Config::Root.default
      root.rules << Config::Rule.new("")

      target.validate(root).map(&.message).any?(&.includes?("match_app_id")).should be_true
    end

    it "アダプタが登録した検証をセクションごとに呼ぶ" do
      target, _ = usecase
      root = Config::Root.from_json(%({"sinks": {"xsoverlay": {"enabled": true, "websocket_port": 0}}}))

      target.validate(root).map(&.message).any?(&.includes?("websocket_port")).should be_true
    end

    it "dynamic_timeout の上下限が正でない設定を弾く" do
      target, _ = usecase
      root = Config::Root.default
      root.defaults.dynamic_timeout = Config::DynamicTimeout.new(base: 2.0, reading_speed: 12.0, min: -10.0, max: -5.0)

      messages = target.validate(root).map(&.message)
      messages.any?(&.includes?("dynamic_timeout.min")).should be_true
      messages.any?(&.includes?("dynamic_timeout.max")).should be_true
    end

    it "max_body_length が上限を超えた設定を弾く" do
      target, _ = usecase
      root = Config::Root.default
      root.defaults.max_body_length = Config::MAX_BODY_LENGTH_RANGE.end + 1

      target.validate(root).map(&.message).any?(&.includes?("max_body_length")).should be_true
    end

    it "有限でない表示時間を弾く" do
      target, _ = usecase
      root = Config::Root.default
      root.defaults.timeout = Float64::NAN
      root.defaults.dynamic_timeout = Config::DynamicTimeout.new(
        base: Float64::NAN,
        reading_speed: Float64::INFINITY,
        min: Float64::NAN,
        max: Float64::INFINITY,
      )

      messages = target.validate(root).map(&.message)
      messages.any?(&.includes?("timeout は")).should be_true
      messages.any?(&.includes?("dynamic_timeout.base")).should be_true
      messages.any?(&.includes?("dynamic_timeout.reading_speed")).should be_true
      messages.any?(&.includes?("dynamic_timeout.min")).should be_true
      messages.any?(&.includes?("dynamic_timeout.max")).should be_true
    end

    it "未知の language を弾く" do
      target, _ = usecase
      root = Config::Root.default
      root.language = "fr"

      target.validate(root).map(&.message).any?(&.includes?("language")).should be_true
    end

    it "auto と ja と en の language は通す" do
      target, _ = usecase
      root = Config::Root.default

      %w[auto ja en].each do |language|
        root.language = language
        target.validate(root).should be_empty
      end
    end

    it "未知の update.channel を弾く" do
      target, _ = usecase
      root = Config::Root.default
      root.update.channel = "nightly"

      target.validate(root).map(&.message).any?(&.includes?("update.channel")).should be_true
    end

    it "stable と test の update.channel は通す" do
      target, _ = usecase
      root = Config::Root.default

      %w[stable test].each do |channel|
        root.update.channel = channel
        target.validate(root).should be_empty
      end
    end

    it "未知の log_level を弾く" do
      target, _ = usecase
      root = Config::Root.default
      root.log_level = "verbose"

      target.validate(root).map(&.message).any?(&.includes?("log_level")).should be_true
    end
  end

  # アプリ自身が書き込む記録（SteamVR の登録、知らせ済みの版）の書き戻し。
  # 利用者の操作を伴わずに走るため、外部の編集を巻き込まないことが要る（issue #15）。
  describe "#record" do
    it "記録を書き戻して動作へ反映する" do
      target, repository = usecase(Config::Root.default.to_json)
      target.load

      target.record(&.with_steamvr(true, "D:/tools/KxNotifyUtils.exe"))

      stored = Config::Root.from_json(repository.stored.not_nil!)
      stored.steamvr.auto_launch_registered.should be_true
      target.current.steamvr.last_exe_path.should eq "D:/tools/KxNotifyUtils.exe"
    end

    # 読み込んでから書き戻すまでの間に手で編集されると、
    # メモリ上のスナップショットで全体を置き換えて編集を失う。
    it "外部の編集を読み直してから記録を載せる" do
      target, repository = usecase(Config::Root.default.to_json)
      target.load

      edited = Config::Root.default
      edited.log_level = "debug"
      repository.edit_externally(edited.to_json)

      target.record(&.with_steamvr(true, "D:/tools/KxNotifyUtils.exe"))

      stored = Config::Root.from_json(repository.stored.not_nil!)
      # 記録は入っている。
      stored.steamvr.auto_launch_registered.should be_true
      # 外部の編集も残っている。
      stored.log_level.should eq "debug"
    end

    # 記録のついでに、利用者が編集の途中のものへ動作を切り替えるわけにはいかない。
    # 反映は「設定を再読み込み」を押したときに行う。
    it "読み直した内容は動作へ反映しない" do
      target, repository = usecase(Config::Root.default.to_json)
      target.load

      edited = Config::Root.default
      edited.log_level = "debug"
      repository.edit_externally(edited.to_json)

      target.record(&.with_steamvr(true, ""))

      target.current.log_level.should eq "info"
    end

    # 読み直せないものへ記録だけを載せることはできない。
    # 全体を上書きすれば書けるが、それでは外部の編集を失う。
    it "読み直せなければ書き戻しを見送る" do
      target, repository = usecase(Config::Root.default.to_json)
      target.load
      repository.edit_externally("{}")
      repository.unreadable = true
      before = repository.save_count

      target.record(&.with_steamvr(true, ""))

      repository.save_count.should eq before
    end

    # 直している途中のファイルを、記録を載せて不正なまま固定しない。
    it "読み直した設定が検証を通らなければ見送る" do
      target, repository = usecase(Config::Root.default.to_json)
      target.load

      broken = Config::Root.default
      broken.log_level = "verbose"
      repository.edit_externally(broken.to_json)
      before = repository.save_count

      target.record(&.with_steamvr(true, ""))

      repository.save_count.should eq before
    end

    # 反映しないまま同期済みとして扱うと、次の record が古い current を基準にする。
    # 一度守った手編集が、次の書き戻しで結局は消える。
    it "反映しなかった後の書き戻しでも手編集が残る" do
      target, repository = usecase(Config::Root.default.to_json)
      target.load

      edited = Config::Root.default
      edited.log_level = "debug"
      repository.edit_externally(edited.to_json)

      # 1 回目。読み直して記録を載せる（反映はしない）。
      target.record(&.with_steamvr(true, "D:/one.exe"))
      # 2 回目。SteamVR の再試行や更新の確認で続けて走る場合にあたる。
      target.record(&.with_steamvr(true, "D:/two.exe"))

      stored = Config::Root.from_json(repository.stored.not_nil!)
      stored.log_level.should eq "debug"
      stored.steamvr.last_exe_path.should eq "D:/two.exe"
    end

    # 読めていない設定へ書き戻すと、利用者のルールごとファイルを失う。
    it "設定を読めていなければ書き戻さない" do
      target, repository = usecase(%({"log_level": "verbose"}))
      target.load
      target.readable?.should be_false
      before = repository.save_count

      target.record(&.with_steamvr(true, ""))

      repository.save_count.should eq before
    end

    # 読み直した設定そのものは反映しないが、記録を落とすと登録が決着しない。
    # steamvr_retry_needed? が成立し続け、60 秒ごとに登録し直すことになる。
    it "外部の編集を反映しない場合でも記録は current へ載せる" do
      target, repository = usecase(Config::Root.default.to_json)
      target.load

      edited = Config::Root.default
      edited.log_level = "debug"
      repository.edit_externally(edited.to_json)

      target.record(&.with_steamvr(true, "D:/tools/KxNotifyUtils.exe"))

      # 記録は反映されている。
      target.current.steamvr.auto_launch_configured.should be_true
      # 外部の編集は反映されていない。
      target.current.log_level.should eq "info"
    end

    # 読んでから書くまでの隙間に編集されると、その編集を書き潰す。
    # 隙間そのものは消せないが、record の中で起こす分は防ぐ。
    it "読んだ後に変更されていたら書き戻しを見送る" do
      target, repository = usecase(Config::Root.default.to_json)
      target.load
      # 更新時刻を読んだ後、書き出しの前に編集される状況を真似る。
      repository.edit_after_next_check = %({"log_level": "debug"})
      before = repository.save_count

      target.record(&.with_steamvr(true, ""))

      repository.save_count.should eq before
      Config::Root.from_json(repository.stored.not_nil!).log_level.should eq "debug"
    end

    it "書けたかどうかを返す" do
      target, _ = usecase(Config::Root.default.to_json)
      target.load

      target.record(&.with_steamvr(true, "")).should be_true
    end

    it "書けなかった場合は偽を返す" do
      target, _ = usecase(%({"log_level": "verbose"}))
      target.load

      target.record(&.with_steamvr(true, "")).should be_false
    end

    # 書き出さないことと反映しないことは別である。
    # 反映しないと自動起動の登録が決着せず、再試行の条件が成立し続ける。
    it "設定を読めていなくても記録は動作へ反映する" do
      target, _ = usecase(%({"log_level": "verbose"}))
      target.load
      target.readable?.should be_false

      target.record(&.with_steamvr(true, "D:/tools/KxNotifyUtils.exe"))

      target.current.steamvr.auto_launch_registered.should be_true
      target.current.steamvr.auto_launch_configured.should be_true
    end

    # 書き出せない状況でも、記録は動作へ反映して呼び出し側へ失敗を返す。
    # 例外で抜けると、反映も戻り値も落ちて、登録が決着しないまま再試行が止まらない。
    it "書き出せなかった場合は反映だけを行って偽を返す" do
      target, repository = usecase(Config::Root.default.to_json)
      target.load
      repository.unwritable = true

      target.record(&.with_steamvr(true, "D:/tools/KxNotifyUtils.exe")).should be_false

      target.current.steamvr.auto_launch_registered.should be_true
      target.current.steamvr.auto_launch_configured.should be_true
    end

    # 読み終えた直後に編集されると、current は読んだ内容のままで更新時刻だけが進む。
    # これを同期済みとして覚えると、次の記録が後から書かれたほうを読み直さずに潰す。
    it "読み込みの直後に編集されていたら、記録の前に読み直す" do
      target, repository = usecase(Config::Root.default.to_json)

      edited = Config::Root.default
      edited.log_level = "debug"
      repository.edit_after_next_load = edited.to_json
      target.load

      target.record(&.with_steamvr(true, "D:/tools/KxNotifyUtils.exe"))

      stored = Config::Root.from_json(repository.stored.not_nil!)
      stored.log_level.should eq "debug"
      stored.steamvr.auto_launch_registered.should be_true
    end

    # 起動時に読めなかったファイルを利用者が直しても、readable? だけを見ていると
    # 「設定を再読み込み」を押すまで記録が一度も残らない。
    it "読めなかった設定が直っていれば記録を書き戻す" do
      target, repository = usecase(%({"log_level": "verbose"}))
      target.load
      target.readable?.should be_false

      repository.edit_externally(Config::Root.default.to_json)
      before = repository.save_count

      target.record(&.with_steamvr(true, "D:/tools/KxNotifyUtils.exe")).should be_true

      repository.save_count.should eq before + 1
      Config::Root.from_json(repository.stored.not_nil!).steamvr.auto_launch_registered.should be_true
    end

    # record が触るのは on_apply が配らない項目だけである。
    # 呼ぶと、記録が書けない間の書き直しのたびに設定全体の再適用が走り、
    # 未確認のチャンネルがあれば 24 時間ごとのはずの更新の確認まで毎分走る。
    it "設定全体の再適用は行わない" do
      target, _ = usecase(Config::Root.default.to_json)
      target.load
      applied = 0
      target.on_apply = ->(_root : Config::Root) do
        applied += 1
        nil
      end

      target.record(&.with_steamvr(true, ""))

      applied.should eq 0
    end

    it "再読み込みの直後に編集されていたら、記録の前に読み直す" do
      target, repository = usecase(Config::Root.default.to_json)
      target.load

      edited = Config::Root.default
      edited.log_level = "debug"
      repository.edit_after_next_load = edited.to_json
      target.reload

      target.record(&.with_steamvr(true, "D:/tools/KxNotifyUtils.exe"))

      stored = Config::Root.from_json(repository.stored.not_nil!)
      stored.log_level.should eq "debug"
      stored.steamvr.auto_launch_registered.should be_true
    end
  end
end

require "../spec_helper"

private def build(exe_path = "D:/tools/KxNotifyUtils.exe")
  repository = Fakes::SteamVRRepository.new
  store = Fakes::ManifestStore.new
  usecase = SteamVR::Usecase.new(repository, store, "C:/AppData/KxNotifyUtils/kxnotifyutils.vrmanifest", exe_path)
  {usecase, repository, store}
end

describe SteamVR::Usecase do
  describe ".build_manifest" do
    it "起動時に解決した実行ファイルの絶対パスを埋める" do
      json = JSON.parse(SteamVR::Usecase.build_manifest("D:/tools/KxNotifyUtils.exe"))
      application = json["applications"][0]

      json["source"].as_s.should eq "builtin"
      application["app_key"].as_s.should eq "kairo.kxnotifyutils"
      application["launch_type"].as_s.should eq "binary"
      application["binary_path_windows"].as_s.should eq "D:/tools/KxNotifyUtils.exe"
      application["is_dashboard_overlay"].as_bool.should be_true
      application["strings"]["ja_jp"]["name"].as_s.should eq "KxNotifyUtils"
    end
  end

  describe "#register" do
    it "vrmanifest を書き出してから登録し、自動起動を有効にする" do
      usecase, repository, store = build

      usecase.register.should be_true
      store.files.keys.should eq ["C:/AppData/KxNotifyUtils/kxnotifyutils.vrmanifest"]
      repository.added_manifests.size.should eq 1
      repository.auto_launch.should be_true
    end

    it "OpenVR が使えないときは登録しない" do
      usecase, repository, store = build
      repository.opened = false

      usecase.register.should be_false
      store.files.should be_empty
    end

    it "マニフェスト登録に失敗したら自動起動を有効にしない" do
      usecase, repository, _ = build
      repository.fail_add = true

      usecase.register.should be_false
      repository.auto_launch.should be_false
    end
  end

  describe "#unregister" do
    it "自動起動を無効にし、登録を外し、生成した vrmanifest も消す" do
      usecase, repository, store = build
      usecase.register

      usecase.unregister.should eq SteamVR::UnregisterResult::Succeeded
      repository.auto_launch.should be_false
      repository.removed_manifests.size.should eq 1
      store.files.should be_empty
    end

    it "自動起動の無効化に失敗したら Failed を返し vrmanifest も残す" do
      usecase, repository, store = build
      usecase.register
      repository.fail_set_auto_launch = true

      usecase.unregister.should eq SteamVR::UnregisterResult::Failed
      store.files.should_not be_empty
    end

    # ファイルを消せなくても SteamVR 側の解除は終わっている。
    # 例外を通すと設定に「登録済み」が残り、次回起動時の同期が登録を復活させる。
    it "vrmanifest を消せなくても解除できたことを返す" do
      usecase, repository, store = build
      usecase.register
      store.fail_delete = true

      usecase.unregister.should eq SteamVR::UnregisterResult::Succeeded
      repository.auto_launch.should be_false
    end

    # 自動起動を切れた事実を落とすと、次回起動時の同期が登録を復活させる。
    it "登録の解除だけに失敗したら AutoLaunchOnly を返し vrmanifest は残す" do
      usecase, repository, store = build
      usecase.register
      repository.fail_remove = true

      usecase.unregister.should eq SteamVR::UnregisterResult::AutoLaunchOnly
      repository.auto_launch.should be_false
      store.files.should_not be_empty
    end
  end

  describe "#sync" do
    it "登録していなければ何もしない" do
      usecase, repository, _ = build
      section = Config::SteamVRSection.new

      usecase.sync(section).outcome.should eq SteamVR::SyncOutcome::UpToDate
      repository.added_manifests.should be_empty
    end

    it "実行ファイルが移動していたら再登録して新しいパスを返す" do
      usecase, repository, _ = build("E:/moved/KxNotifyUtils.exe")
      section = Config::SteamVRSection.new
      section.auto_launch_registered = true
      section.last_exe_path = "D:/tools/KxNotifyUtils.exe"

      result = usecase.sync(section)
      result.outcome.should eq SteamVR::SyncOutcome::Reregistered
      updated = result.section.should_not be_nil
      updated.last_exe_path.should eq "E:/moved/KxNotifyUtils.exe"
      repository.added_manifests.size.should eq 1
    end

    it "パスが変わっておらず vrmanifest も残っていれば再登録しない" do
      usecase, repository, _ = build
      usecase.register
      section = Config::SteamVRSection.new
      section.auto_launch_registered = true
      section.last_exe_path = "D:/tools/KxNotifyUtils.exe"

      usecase.sync(section).outcome.should eq SteamVR::SyncOutcome::UpToDate
      repository.added_manifests.size.should eq 1
    end

    it "SteamVR 側の登録が失われていれば登録し直す" do
      usecase, repository, _ = build
      usecase.register
      repository.auto_launch = false
      section = Config::SteamVRSection.new
      section.auto_launch_registered = true
      section.last_exe_path = "D:/tools/KxNotifyUtils.exe"

      usecase.sync(section).outcome.should eq SteamVR::SyncOutcome::Reregistered
      repository.auto_launch.should be_true
      repository.added_manifests.size.should eq 2
    end

    it "vrmanifest が消えていれば書き直す" do
      usecase, repository, store = build
      section = Config::SteamVRSection.new
      section.auto_launch_registered = true
      section.last_exe_path = "D:/tools/KxNotifyUtils.exe"

      usecase.sync(section).outcome.should eq SteamVR::SyncOutcome::Reregistered
      store.files.should_not be_empty
      repository.added_manifests.size.should eq 1
    end

    # UpToDate と同じ扱いにすると呼び出し側が失敗を知れず、
    # 移動した実行ファイルのパスが次の起動まで直らない。
    it "再登録に失敗したら Failed を返す" do
      usecase, repository, _ = build("E:/moved/KxNotifyUtils.exe")
      repository.fail_add = true
      section = Config::SteamVRSection.new
      section.auto_launch_registered = true
      section.last_exe_path = "D:/tools/KxNotifyUtils.exe"

      result = usecase.sync(section)
      result.outcome.should eq SteamVR::SyncOutcome::Failed
      result.section.should be_nil
    end
  end

  describe "#quit_requested?" do
    it "終了イベントを受けたら SteamVR へ応答してから true を返す" do
      usecase, repository, _ = build
      repository.quit = true

      usecase.quit_requested?.should be_true
      repository.acknowledged.should be_true
    end

    it "終了イベントが無ければ応答しない" do
      usecase, repository, _ = build

      usecase.quit_requested?.should be_false
      repository.acknowledged.should be_false
    end
  end
end

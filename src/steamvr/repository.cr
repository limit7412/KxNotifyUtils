module SteamVR
  # OpenVR 呼び出しの境界（仕様書 4.5 節、4.6 節）。
  # 実装は openvr_repository.cr が openvr_api.dll の動的ロードで提供する。
  abstract class Repository
    # OpenVR を VRApplication_Background で初期化する。成功したら true を返す。
    #
    # SteamVR が動いていなければ失敗する。この種別を選んだのはそのためである（issue #12）。
    abstract def open : Bool

    abstract def close : Nil

    # 初期化に成功していて、以降の呼び出しが有効か。
    abstract def opened? : Bool

    abstract def add_application_manifest(manifest_path : String) : Bool
    abstract def remove_application_manifest(manifest_path : String) : Bool
    abstract def set_auto_launch(app_key : String, enabled : Bool) : Bool
    abstract def auto_launch?(app_key : String) : Bool

    # VREvent_Quit を受け取ったら true を返す。
    abstract def quit_requested? : Bool

    # 終了処理に入る前に SteamVR へ応答する（AcknowledgeQuit_Exiting）。
    abstract def acknowledge_quit : Nil
  end

  # vrmanifest ファイルの読み書きの境界。
  abstract class ManifestStore
    abstract def write(path : String, content : String) : Nil
    abstract def delete(path : String) : Nil
    abstract def exists?(path : String) : Bool
  end

  # 実ファイルに対する ManifestStore 実装。
  class FileManifestStore < ManifestStore
    def write(path : String, content : String) : Nil
      Dir.mkdir_p(File.dirname(path))
      File.write(path, content)
    end

    def delete(path : String) : Nil
      File.delete(path) if File.exists?(path)
    end

    def exists?(path : String) : Bool
      File.exists?(path)
    end
  end
end

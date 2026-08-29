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

  # SteamVR が動いていないときに、その設定ファイルを直に読み書きする境界。
  #
  # OpenVR の IVRApplications は vrserver が動いていないと使えない。
  # #12 で Background 初期化へ変えてから、SteamVR を起動していない手動起動が
  # 想定された使い方になり、そのあいだ登録も解除もできなかった。
  #
  # SteamVR が動いている間は使わない。あちらは設定をメモリに持っており、
  # 終了時に書き戻すため、後ろから書いても消される（ValveSoftware/openvr#1537）。
  # 動いていないときだけ書き、次の起動でそれが読まれる。
  abstract class ApplicationConfig
    # 設定ファイルの置き場所を見つけられたか。
    abstract def available? : Bool

    abstract def add_manifest(manifest_path : String) : Bool
    abstract def remove_manifest(manifest_path : String) : Bool
    abstract def set_auto_launch(app_key : String, enabled : Bool) : Bool
    abstract def auto_launch?(app_key : String) : Bool
  end

  # 設定ファイルを一切触らない ApplicationConfig。
  #
  # Windows 以外や、置き場所を渡さずに Usecase を作る場面の既定である。
  # available? が偽なので、呼び出し側は OpenVR が開けなければ登録できないと判断する。
  class NullApplicationConfig < ApplicationConfig
    def available? : Bool
      false
    end

    def add_manifest(manifest_path : String) : Bool
      false
    end

    def remove_manifest(manifest_path : String) : Bool
      false
    end

    def set_auto_launch(app_key : String, enabled : Bool) : Bool
      false
    end

    def auto_launch?(app_key : String) : Bool
      false
    end
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

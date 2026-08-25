# 実行環境。
# ファイルの置き場所、ログ、スケジューリング、トレイ、設定ウィンドウを担う。
module Runtime
  # 設定、ログ、生成 vrmanifest の置き場所（仕様書 1 章、4.5 節、5 章、6 章）。
  #
  # 配布物は exe 1 ファイルだが、書き込むファイルは %APPDATA%\KxNotifyUtils\ に置く。
  # SteamVR へ渡すマニフェストのパスを exe の置き場所から独立させるための固定であり、
  # exe を移動してもマニフェストの中身を書き換えるだけで追従できる。
  module Paths
    APP_DIRECTORY_NAME = "KxNotifyUtils"

    def self.data_directory : String
      base = ENV["APPDATA"]? || ENV["XDG_CONFIG_HOME"]? || File.join(Path.home.to_s, ".config")
      File.join(base, APP_DIRECTORY_NAME)
    end

    def self.config_path : String
      File.join(data_directory, "config.json")
    end

    def self.log_directory : String
      File.join(data_directory, "logs")
    end

    def self.manifest_path : String
      File.join(data_directory, "kxnotifyutils.vrmanifest")
    end

    # 起動した実行ファイルの絶対パス。
    # vrmanifest の binary_path_windows と、移動の検知に使う。
    def self.executable_path : String
      Process.executable_path || File.expand_path(PROGRAM_NAME)
    end
  end
end

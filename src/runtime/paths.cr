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

    # 取得しておいた新しい実行ファイル（issue #10 第 2 段階）。
    #
    # 置き場所を %APPDATA% ではなく exe の隣にしてあるのは、
    # 置き換えが同じボリューム内のリネームで済むようにするためである。
    # ボリュームをまたぐと、リネームが中身の複写に化けて途中で失敗しうる。
    def self.staged_executable_path : String
      "#{executable_path}.new"
    end

    # 置き換えで退避した古い実行ファイル。次の起動で消す。
    def self.previous_executable_path : String
      "#{executable_path}.old"
    end
  end
end

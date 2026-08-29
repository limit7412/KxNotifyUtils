require "json"
require "log"
require "./repository"

module SteamVR
  # SteamVR の設定ファイルを直に読み書きする ApplicationConfig 実装。
  #
  # 触るのは 2 か所である。
  #
  # - `<config>/appconfig.json` の `manifest_paths`：登録したマニフェストの一覧
  # - `<config>/vrappconfig/<app_key>.vrappconfig`：そのアプリの自動起動の状態
  #
  # どちらも OpenVR の AddApplicationManifest と SetApplicationAutoLaunch が
  # 書き込む先であり、SteamVR は起動時にここから読み直す。
  #
  # SteamVR が動いている間は呼ばない。呼び出し側が OpenVR を使えるかで選び分ける。
  class FileApplicationConfig < ApplicationConfig
    Log = ::Log.for("steamvr")

    # SteamVR がこの綴りで書く。読み書きの往復で形を変えないよう合わせる。
    AUTO_LAUNCH_KEY      = "autolaunch"
    LAST_LAUNCH_TIME_KEY = "last_launch_time"
    MANIFEST_PATHS_KEY   = "manifest_paths"

    def initialize(@directory : String? = nil)
      @directory ||= self.class.locate_directory
    end

    def available? : Bool
      !@directory.nil?
    end

    # appconfig.json の一覧へ足す。既にあれば何もしない。
    def add_manifest(manifest_path : String) : Bool
      update_app_config { |source| self.class.with_manifest(source, manifest_path) }
    end

    def remove_manifest(manifest_path : String) : Bool
      update_app_config { |source| self.class.without_manifest(source, manifest_path) }
    end

    def set_auto_launch(app_key : String, enabled : Bool) : Bool
      path = app_config_path(app_key)
      return false unless path

      begin
        Dir.mkdir_p(File.dirname(path))
        write_atomic(path, self.class.with_auto_launch(read_or_nil(path), enabled))
        true
      rescue exception
        Log.error(exception: exception) { "自動起動の設定を書けなかった: #{path}" }
        false
      end
    end

    def auto_launch?(app_key : String) : Bool
      path = app_config_path(app_key)
      return false unless path

      self.class.auto_launch?(read_or_nil(path))
    end

    # openvrpaths.vrpath の config 配列から設定の置き場所を探す。
    #
    # runtime 配列と同じファイルにあり、SteamVR のインストール先とは別に持たれている。
    # 読めない場合は既定のインストール先を試す。
    def self.locate_directory : String?
      candidates = [] of String

      if local_app_data = ENV["LOCALAPPDATA"]?
        vrpath = File.join(local_app_data, "openvr", "openvrpaths.vrpath")
        if File.exists?(vrpath)
          begin
            JSON.parse(File.read(vrpath))["config"].as_a.each do |entry|
              entry.as_s?.try { |directory| candidates << directory }
            end
          rescue exception
            Log.warn(exception: exception) { "openvrpaths.vrpath を読めなかった: #{vrpath}" }
          end
        end
      end

      if program_files = ENV["ProgramFiles(x86)"]?
        candidates << File.join(program_files, "Steam", "config")
      end

      candidates.find { |directory| Dir.exists?(directory) }
    end

    # 以降は通信もファイルも伴わない組み立てである。spec ではここを直に確かめる。

    # manifest_paths へ足した appconfig.json を返す。
    def self.with_manifest(source : String?, manifest_path : String) : String
      root = parse_object(source)
      paths = manifest_paths(root)

      target = normalize(manifest_path)
      paths << manifest_path unless paths.any? { |entry| normalize(entry) == target }

      root[MANIFEST_PATHS_KEY] = JSON::Any.new(paths.map { |entry| JSON::Any.new(entry) })
      root.to_json
    end

    # manifest_paths から外した appconfig.json を返す。
    def self.without_manifest(source : String?, manifest_path : String) : String
      root = parse_object(source)
      target = normalize(manifest_path)
      paths = manifest_paths(root).reject { |entry| normalize(entry) == target }

      root[MANIFEST_PATHS_KEY] = JSON::Any.new(paths.map { |entry| JSON::Any.new(entry) })
      root.to_json
    end

    # 自動起動の状態を書き換えた .vrappconfig を返す。
    #
    # last_launch_time は SteamVR が持つ値なので、読めたものはそのまま残す。
    # 無ければ SteamVR が新規に書くときと同じ "0" を置く。
    def self.with_auto_launch(source : String?, enabled : Bool) : String
      root = begin
        parse_object(source)
      rescue
        # このファイルは app_key ごとに 1 つで、中身は自動起動の状態だけである。
        # 読めなければ作り直してよい。appconfig.json と違い、他の登録を巻き込まない。
        {} of String => JSON::Any
      end

      root[AUTO_LAUNCH_KEY] = JSON::Any.new(enabled)
      root[LAST_LAUNCH_TIME_KEY] = JSON::Any.new("0") unless root.has_key?(LAST_LAUNCH_TIME_KEY)
      root.to_json
    end

    def self.auto_launch?(source : String?) : Bool
      root = parse_object(source)
      root[AUTO_LAUNCH_KEY]?.try(&.as_bool?) || false
    rescue
      false
    end

    # Windows のパスは大文字小文字を区別せず、区切りも混在しうる。
    # 比較のときだけ揃える。書き込むのは受け取ったままの文字列である。
    def self.normalize(path : String) : String
      path.gsub('/', '\\').downcase
    end

    # 無ければ空の object として扱う。読めなければ投げる。
    #
    # 読めないものを空として扱うと、appconfig.json に入っている
    # 他のアプリの登録を丸ごと消すことになる。
    private def self.parse_object(source : String?) : Hash(String, JSON::Any)
      return {} of String => JSON::Any if source.nil? || source.blank?

      JSON.parse(source).as_h.dup
    end

    private def self.manifest_paths(root : Hash(String, JSON::Any)) : Array(String)
      entries = root[MANIFEST_PATHS_KEY]?.try(&.as_a?)
      return [] of String unless entries

      entries.compact_map(&.as_s?)
    end

    private def app_config_path(app_key : String) : String?
      directory = @directory
      return nil unless directory

      File.join(directory, "vrappconfig", "#{app_key}.vrappconfig")
    end

    private def update_app_config(& : String? -> String) : Bool
      directory = @directory
      return false unless directory

      path = File.join(directory, "appconfig.json")
      begin
        content = yield read_or_nil(path)
        write_atomic(path, content)
        true
      rescue exception
        Log.error(exception: exception) { "appconfig.json を書けなかった: #{path}" }
        false
      end
    end

    private def read_or_nil(path : String) : String?
      File.exists?(path) ? File.read(path) : nil
    end

    # 書きかけを SteamVR に読ませない。
    # appconfig.json は他のアプリの登録も入っており、壊すと巻き添えになる。
    private def write_atomic(path : String, content : String) : Nil
      temporary = "#{path}.tmp"
      File.write(temporary, content)
      File.rename(temporary, path)
    end
  end
end

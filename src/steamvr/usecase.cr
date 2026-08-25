require "json"
require "log"
require "../config/models"
require "./repository"

# SteamVR 連携コンテキスト。
module SteamVR
  # スタートアップ登録と終了イベントの処理（仕様書 4.5 節）。
  class Usecase
    Log = ::Log.for("steamvr")

    APP_KEY = "kairo.kxnotifyutils"

    def initialize(
      @repository : Repository,
      @store : ManifestStore,
      @manifest_path : String,
      @exe_path : String,
    )
    end

    # vrmanifest の内容を組み立てる。
    # 配布物には含めず、起動時に解決した実行ファイルの絶対パスを埋めて書き出す。
    def self.build_manifest(exe_path : String) : String
      JSON.build(indent: 2) do |json|
        json.object do
          json.field "source", "builtin"
          json.field "applications" do
            json.array do
              json.object do
                json.field "app_key", APP_KEY
                json.field "launch_type", "binary"
                json.field "binary_path_windows", exe_path
                json.field "is_dashboard_overlay", true
                json.field "strings" do
                  json.object do
                    json.field "en_us" do
                      json.object do
                        json.field "name", "KxNotifyUtils"
                        json.field "description", "Relays notifications to XSOverlay."
                      end
                    end
                    json.field "ja_jp" do
                      json.object do
                        json.field "name", "KxNotifyUtils"
                        json.field "description", "通知を XSOverlay に中継します。"
                      end
                    end
                  end
                end
              end
            end
          end
        end
      end
    end

    # 実行ファイルが移動したかを、前回登録時のパスとの比較で判定する。
    def moved?(section : ::Config::SteamVRSection) : Bool
      section.last_exe_path != @exe_path
    end

    # 登録。vrmanifest を生成してから OpenVR へ登録し、自動起動を有効にする。
    def register : Bool
      return false unless @repository.opened?

      @store.write(@manifest_path, self.class.build_manifest(@exe_path))
      unless @repository.add_application_manifest(@manifest_path)
        Log.error { "vrmanifest の登録に失敗した: #{@manifest_path}" }
        return false
      end
      unless @repository.set_auto_launch(APP_KEY, true)
        Log.error { "自動起動の有効化に失敗した" }
        return false
      end
      Log.info { "SteamVR へ自動起動を登録した: #{@exe_path}" }
      true
    end

    # 解除。自動起動を無効にし、登録を外し、生成した vrmanifest も消す。
    def unregister : Bool
      return false unless @repository.opened?

      @repository.set_auto_launch(APP_KEY, false)
      @repository.remove_application_manifest(@manifest_path)
      @store.delete(@manifest_path)
      Log.info { "SteamVR の自動起動を解除した" }
      true
    end

    # 毎起動時の同期。
    # 登録済みの記録があり実行ファイルが移動していれば、SteamVR 側のキャッシュを確実に更新するため
    # マニフェストの書き換えだけで済ませず再登録まで行う。
    # 戻り値は steamvr セクションに書き戻すべき内容であり、変更が不要なら nil を返す。
    def sync(section : ::Config::SteamVRSection) : ::Config::SteamVRSection?
      return nil unless @repository.opened?
      return nil unless section.auto_launch_registered

      if !moved?(section) && @store.exists?(@manifest_path)
        return nil
      end

      Log.info { "実行ファイルの位置が変わったため再登録する: #{section.last_exe_path} -> #{@exe_path}" }
      return nil unless register

      updated = ::Config::SteamVRSection.new
      updated.auto_launch_registered = true
      updated.last_exe_path = @exe_path
      updated
    end

    def registered? : Bool
      @repository.opened? && @repository.auto_launch?(APP_KEY)
    end

    # SteamVR の終了要求を受けたかを返す。受けていれば応答を返してから終了処理へ入る。
    def quit_requested? : Bool
      return false unless @repository.opened?
      return false unless @repository.quit_requested?

      @repository.acknowledge_quit
      Log.info { "SteamVR の終了を検知した" }
      true
    end

    def exe_path : String
      @exe_path
    end

    def manifest_path : String
      @manifest_path
    end
  end
end

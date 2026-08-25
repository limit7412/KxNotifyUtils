require "../../src/notify/models"
require "../../src/notify/repository"
require "../../src/win_notification/models"
require "../../src/win_notification/repository"

# 単体テスト用の差し替え実装。
# 外部境界をこれらに置き換えることで、usecase を実 XSOverlay にも実通知にも触れず検証できる。
module Fakes
  class Source < Notify::SourceRepository
    property batches : Array(Array(Notify::Incoming))
    property interval : Time::Span
    property ready : Bool = true
    getter poll_count : Int32 = 0
    getter started : Bool = false

    def initialize(@id : String, @batches : Array(Array(Notify::Incoming)) = [] of Array(Notify::Incoming), @interval : Time::Span = 1.millisecond)
    end

    def source_id : String
      @id
    end

    def poll_interval : Time::Span
      @interval
    end

    def ready? : Bool
      @ready
    end

    def start : Nil
      @started = true
    end

    def poll_new : Array(Notify::Incoming)
      @poll_count += 1
      @batches.shift? || [] of Notify::Incoming
    end
  end

  # poll_new が必ず例外を投げるソース。1 つのソースの失敗が他へ波及しないことの確認に使う。
  class BrokenSource < Notify::SourceRepository
    def initialize(@id : String)
    end

    def source_id : String
      @id
    end

    def poll_interval : Time::Span
      1.millisecond
    end

    def poll_new : Array(Notify::Incoming)
      raise "ポーリングに失敗した"
    end
  end

  class Sink < Notify::PostRepository
    getter sent : Array(Notify::Message) = [] of Notify::Message
    property fail : Bool = false
    property raise_on_send : Bool = false
    # 送信のたびに呼ぶフック。送信の途中で状態が変わる場面を作るために使う。
    property on_send : Proc(Nil) = -> { }

    def initialize(@id : String)
    end

    def sink_id : String
      @id
    end

    def send_message(message : Notify::Message) : Bool
      @on_send.call
      raise "送信に失敗した" if @raise_on_send
      return false if @fail
      @sent << message
      true
    end
  end

  class Icons < Notify::IconRepository
    property files : Hash(String, String) = {} of String => String

    def load_png_base64(path : String) : String?
      @files[path]?
    end
  end

  class ShimClient < WinNotification::ShimClient
    property responses : Array(String)
    property status : WinNotification::AccessStatus = WinNotification::AccessStatus::Allowed
    getter opened : Bool = false

    def initialize(@responses : Array(String) = [] of String)
    end

    def open : Nil
      @opened = true
    end

    def close : Nil
      @opened = false
    end

    def access_status : WinNotification::AccessStatus
      @status
    end

    def request_access : WinNotification::AccessStatus
      @status
    end

    def fetch_json : String
      @responses.shift? || %({"notifications": []})
    end
  end
end

require "../../src/config/repository"
require "../../src/steamvr/repository"

module Fakes
  # ファイルを持たない Config::Repository 実装。
  class ConfigRepository < Config::Repository
    property stored : String?
    property existing_files : Array(String) = [] of String
    property save_count : Int32 = 0

    def initialize(@stored : String? = nil)
    end

    def path : String
      "(memory)"
    end

    def exists? : Bool
      !@stored.nil?
    end

    def load : Config::Root
      Config::Root.from_json(@stored || "{}")
    end

    def save(root : Config::Root) : Nil
      @stored = root.to_json
      @save_count += 1
    end

    def file_exists?(path : String) : Bool
      @existing_files.includes?(path)
    end

    def modified_at : Time?
      nil
    end
  end

  class SteamVRRepository < SteamVR::Repository
    property opened : Bool = true
    property auto_launch : Bool = false
    property quit : Bool = false
    property added_manifests : Array(String) = [] of String
    property removed_manifests : Array(String) = [] of String
    property acknowledged : Bool = false
    property fail_add : Bool = false
    property fail_remove : Bool = false
    property fail_set_auto_launch : Bool = false

    def open : Bool
      @opened = true
    end

    def close : Nil
      @opened = false
    end

    def opened? : Bool
      @opened
    end

    def add_application_manifest(manifest_path : String) : Bool
      return false if @fail_add
      @added_manifests << manifest_path
      true
    end

    def remove_application_manifest(manifest_path : String) : Bool
      return false if @fail_remove
      @removed_manifests << manifest_path
      true
    end

    def set_auto_launch(app_key : String, enabled : Bool) : Bool
      return false if @fail_set_auto_launch
      @auto_launch = enabled
      true
    end

    def auto_launch?(app_key : String) : Bool
      @auto_launch
    end

    def quit_requested? : Bool
      @quit
    end

    def acknowledge_quit : Nil
      @acknowledged = true
    end
  end

  class ManifestStore < SteamVR::ManifestStore
    property files : Hash(String, String) = {} of String => String

    def write(path : String, content : String) : Nil
      @files[path] = content
    end

    def delete(path : String) : Nil
      @files.delete(path)
    end

    def exists?(path : String) : Bool
      @files.has_key?(path)
    end
  end
end

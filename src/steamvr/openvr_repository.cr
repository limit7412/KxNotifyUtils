require "json"
require "log"
require "./ffi"
require "./repository"

module SteamVR
  # openvr_api.dll を実行時に解決して呼ぶ Repository 実装（仕様書 4.6 節）。
  #
  # インターフェースバージョンは openvr_capi.h の記述に合わせて固定する。
  # openvr_api.dll は後方互換に保たれているため、本ツールが要求する版が古い分には問題にならないが、
  # 逆に SteamVR 側が古くて要求する版を持たない場合は FnTable の並びが合わない。
  # そのため起動時に VR_IsInterfaceVersionValid で検証し、通らなければ SteamVR 連携を無効にする。
  class OpenVRRepository < Repository
    Log = ::Log.for("steamvr")

    IVRSYSTEM_VERSION       = "IVRSystem_026"
    IVRAPPLICATIONS_VERSION = "IVRApplications_008"

    def initialize
      @library = Pointer(Void).null
      @shutdown_internal = nil.as(Proc(Nil)?)
      @system = Pointer(LibOpenVR::IVRSystemFnTable).null
      @applications = Pointer(LibOpenVR::IVRApplicationsFnTable).null
      @opened = false
      @reported_init_error = nil.as(Int32?)
      @logged_library_path = nil.as(String?)
    end

    def opened? : Bool
      @opened
    end

    # openvr_api.dll の解決、OpenVR の初期化、FnTable の取得までを行う。
    # どこで失敗しても SteamVR 連携を無効にするだけで、本体の常駐は続けられる。
    #
    # 初期化には Background を渡す。
    # SteamVR が動いていなければ、この種別だけが SteamVR を起こさずに失敗する（issue #12）。
    # 本ツールが OpenVR に求めるのは vrmanifest の登録と自動起動の設定、
    # そして VREvent_Quit の受け取りだけであり、いずれも overlay の描画を伴わない。
    #
    # SteamVR を起動しないことは、初期化の成功ではなく失敗として表れる。
    # 呼び出し側はこの失敗を異常として扱わず、60 秒ごとに開き直す。
    def open : Bool
      return true if @opened

      unless load_library
        Log.debug { "openvr_api.dll を解決できなかった" }
        return false
      end

      init = resolve("VR_InitInternal2").try do |pointer|
        Proc(Int32*, Int32, UInt8*, UInt64).new(pointer, Pointer(Void).null)
      end
      shutdown = resolve("VR_ShutdownInternal").try do |pointer|
        Proc(Nil).new(pointer, Pointer(Void).null)
      end
      get_generic = resolve("VR_GetGenericInterface").try do |pointer|
        Proc(UInt8*, Int32*, Void*).new(pointer, Pointer(Void).null)
      end
      version_valid = resolve("VR_IsInterfaceVersionValid").try do |pointer|
        Proc(UInt8*, Bool).new(pointer, Pointer(Void).null)
      end

      unless init && shutdown && get_generic && version_valid
        Log.error { "openvr_api.dll から必要な関数を解決できなかった" }
        return unload
      end

      error = 0
      init.call(pointerof(error), LibOpenVR::APPLICATION_TYPE_BACKGROUND, Pointer(UInt8).null)
      unless error == LibOpenVR::ERROR_NONE
        report_init_failure(error)
        return unload
      end
      @reported_init_error = nil
      @shutdown_internal = shutdown

      unless version_valid.call(IVRSYSTEM_VERSION.to_unsafe) &&
             version_valid.call(IVRAPPLICATIONS_VERSION.to_unsafe)
        Log.error do
          "SteamVR が #{IVRSYSTEM_VERSION} と #{IVRAPPLICATIONS_VERSION} に対応していないため " \
          "SteamVR 連携を無効にする"
        end
        return close_and_unload
      end

      @system = get_generic
        .call("FnTable:#{IVRSYSTEM_VERSION}".to_unsafe, pointerof(error))
        .as(LibOpenVR::IVRSystemFnTable*)
      @applications = get_generic
        .call("FnTable:#{IVRAPPLICATIONS_VERSION}".to_unsafe, pointerof(error))
        .as(LibOpenVR::IVRApplicationsFnTable*)

      if @system.null? || @applications.null?
        Log.error { "OpenVR の FnTable を取得できなかった" }
        return close_and_unload
      end

      @opened = true
      Log.info { "OpenVR を初期化した" }
      true
    end

    def close : Nil
      return unless @opened
      close_and_unload
    end

    def add_application_manifest(manifest_path : String) : Bool
      return false unless @opened
      call = Proc(UInt8*, Bool, Int32).new(@applications.value.add_application_manifest, Pointer(Void).null)
      check("AddApplicationManifest", call.call(manifest_path.to_unsafe, false))
    end

    def remove_application_manifest(manifest_path : String) : Bool
      return false unless @opened
      call = Proc(UInt8*, Int32).new(@applications.value.remove_application_manifest, Pointer(Void).null)
      check("RemoveApplicationManifest", call.call(manifest_path.to_unsafe))
    end

    def set_auto_launch(app_key : String, enabled : Bool) : Bool
      return false unless @opened
      call = Proc(UInt8*, Bool, Int32).new(@applications.value.set_application_auto_launch, Pointer(Void).null)
      check("SetApplicationAutoLaunch", call.call(app_key.to_unsafe, enabled))
    end

    def auto_launch?(app_key : String) : Bool
      return false unless @opened
      call = Proc(UInt8*, Bool).new(@applications.value.get_application_auto_launch, Pointer(Void).null)
      call.call(app_key.to_unsafe)
    end

    # 溜まっているイベントを読み切り、終了要求が含まれていたかを返す。
    def quit_requested? : Bool
      return false unless @opened

      call = Proc(LibOpenVR::PVREvent, UInt32, Bool).new(@system.value.poll_next_event, Pointer(Void).null)
      event = uninitialized LibOpenVR::VREvent
      requested = false
      while call.call(pointerof(event), sizeof(LibOpenVR::VREvent).to_u32)
        requested = true if event.event_type == LibOpenVR::EVENT_QUIT
      end
      requested
    end

    def acknowledge_quit : Nil
      return unless @opened
      Proc(Nil).new(@system.value.acknowledge_quit_exiting, Pointer(Void).null).call
    end

    # openvrpaths.vrpath の runtime 配列から openvr_api.dll を探す。
    private def load_library : Bool
      return true unless @library.null?

      runtime_directories.each do |directory|
        path = File.join(directory, "bin", "win64", "openvr_api.dll")
        next unless File.exists?(path)

        handle = LibDynamicLoad.load_library_w(path.to_utf16.to_unsafe)
        next if handle.null?

        @library = handle
        report_library_loaded(path)
        return true
      end
      false
    end

    # OpenVR 標準のパス設定ファイルを一次の情報源とし、読めなければ既定のインストール先を試す。
    private def runtime_directories : Array(String)
      directories = [] of String

      if local_app_data = ENV["LOCALAPPDATA"]?
        vrpath = File.join(local_app_data, "openvr", "openvrpaths.vrpath")
        if File.exists?(vrpath)
          begin
            JSON.parse(File.read(vrpath))["runtime"].as_a.each do |entry|
              entry.as_s?.try { |directory| directories << directory }
            end
          rescue ex
            Log.warn(exception: ex) { "openvrpaths.vrpath を読めなかった: #{vrpath}" }
          end
        end
      end

      if program_files = ENV["ProgramFiles(x86)"]?
        directories << File.join(program_files, "Steam", "steamapps", "common", "SteamVR")
      end
      directories.uniq!
    end

    private def resolve(name : String) : Void*?
      pointer = LibDynamicLoad.get_proc_address(@library, name.to_unsafe)
      pointer.null? ? nil : pointer
    end

    # 解決できた場所を出す。ただし場所が変わったときだけ書く。
    #
    # SteamVR を起動していない間、open は毎回失敗し、その後始末で DLL を手放す。
    # Background で初期化するようにしてから、この経路は常に通る（issue #12）。
    # 次の再試行は読み込むところからやり直すため、そのたびに書くと
    # VR を使わない日のログがこの 1 行だけで埋まる（issue #34）。
    #
    # 手放すのをやめて読み込んだままにする手は採らない。
    # openvr_api.dll のファイルが掴まれ、常駐している間 SteamVR の更新や
    # 再インストールを妨げる。それが起きるのは SteamVR を止めている間、
    # つまりまさにこの経路を通っているときである。
    #
    # 場所が変わったら書き直す。移した先を黙られると、
    # 古い場所を見に行ったまま追えなくなる。
    private def report_library_loaded(path : String) : Nil
      if @logged_library_path == path
        Log.debug { "openvr_api.dll をロードした: #{path}" }
        return
      end

      @logged_library_path = path
      Log.info { "openvr_api.dll をロードした: #{path}" }
    end

    # 初期化の失敗を、SteamVR が動いていないだけの場合と切り分けて出す。
    #
    # Background で初期化するため、SteamVR を起動していない間はここを必ず通る。
    # 既定のログレベルは info であり、そちらへ上げると VR を使わない日のログが
    # 60 秒ごとの同じ 1 行で埋まる。異常ではないので debug に留める。
    #
    # それ以外の失敗は目に触れる必要がある。
    # ただし再試行のたびに繰り返されるため、番号が変わったときだけ書く。
    private def report_init_failure(error : Int32) : Nil
      if error == LibOpenVR::ERROR_NO_SERVER_FOR_BACKGROUND_APP
        Log.debug { "SteamVR が動いていないため OpenVR を初期化しなかった" }
        @reported_init_error = nil
        return
      end

      if @reported_init_error == error
        Log.debug { "OpenVR の初期化に失敗した (#{error})" }
        return
      end

      @reported_init_error = error
      Log.warn { "OpenVR の初期化に失敗した (#{error})" }
    end

    private def check(operation : String, error : Int32) : Bool
      return true if error == LibOpenVR::ERROR_NONE
      Log.error { "#{operation} が失敗した (#{error})" }
      false
    end

    private def close_and_unload : Bool
      @shutdown_internal.try(&.call)
      @shutdown_internal = nil
      @system = Pointer(LibOpenVR::IVRSystemFnTable).null
      @applications = Pointer(LibOpenVR::IVRApplicationsFnTable).null
      @opened = false
      unload
    end

    private def unload : Bool
      LibDynamicLoad.free_library(@library) unless @library.null?
      @library = Pointer(Void).null
      false
    end
  end
end

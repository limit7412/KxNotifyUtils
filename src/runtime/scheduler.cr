require "../error/usecase"
require "../notify/usecase"
require "../steamvr/usecase"

module Runtime
  # ポーリングと終了イベントの確認を一定の順序で回す（仕様書 4.1 節）。
  # ロジックは持たず、usecase を呼ぶ順序と間隔だけを決める。
  class Scheduler
    # SteamVR より先に本体を手動起動した場合に備え、OpenVR の初期化を繰り返し試す間隔。
    OPENVR_RETRY_INTERVAL = 60.seconds
    # SteamVR の終了イベントを確認する間隔。
    QUIT_POLL_INTERVAL = 1.second
    # 開始に失敗した通知ソースをやり直す間隔。
    SOURCE_RETRY_INTERVAL = 30.seconds

    getter? quit_requested : Bool = false

    def initialize(@relay : Notify::RelayUsecase, @steamvr : SteamVR::Usecase, @errors : Error::Usecase)
      @next_retry = Time.monotonic + OPENVR_RETRY_INTERVAL
      @next_quit_poll = Time.monotonic
      @next_source_retry = Time.monotonic + SOURCE_RETRY_INTERVAL
    end

    # 主ループから繰り返し呼ぶ 1 拍。
    def step(now : Time::Span = Time.monotonic) : Nil
      @errors.guard("error.relay") { @relay.tick(now) }
      poll_steamvr
    end

    private def poll_steamvr : Nil
      monotonic = Time.monotonic
      return if monotonic < @next_quit_poll
      @next_quit_poll = monotonic + QUIT_POLL_INTERVAL

      @errors.guard("error.steamvr_poll") do
        @quit_requested = true if @steamvr.quit_requested?
      end
    end

    # OpenVR の初期化をやり直すべき時刻になったかを返す。
    # 再試行そのものは composition root が行う。
    def retry_openvr? : Bool
      monotonic = Time.monotonic
      return false if monotonic < @next_retry
      @next_retry = monotonic + OPENVR_RETRY_INTERVAL
      true
    end

    # 通知ソースの開始をやり直すべき時刻になったかを返す。
    # 再試行そのものは composition root が行う。
    def retry_source? : Bool
      monotonic = Time.monotonic
      return false if monotonic < @next_source_retry
      @next_source_retry = monotonic + SOURCE_RETRY_INTERVAL
      true
    end
  end
end

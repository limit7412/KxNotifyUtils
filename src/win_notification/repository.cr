require "log"
require "../notify/models"
require "../notify/repository"
require "./models"

module WinNotification
  # シムの C API を呼ぶ境界。
  # FFI を直接触るのは実装側（ffi_client.cr）だけで、差分検出の試験ではテスト用実装に差し替える。
  abstract class ShimClient
    abstract def open : Nil
    abstract def close : Nil
    abstract def access_status : AccessStatus
    abstract def request_access : AccessStatus
    # 現在の通知一覧を仕様書 3.3 節の JSON 文字列で返す。
    abstract def fetch_json : String
  end

  # Windows 通知ソースの SourceRepository 実装。
  # id 集合の比較という Windows 通知に固有の差分検出をここに閉じる（仕様書 4.2 節）。
  class Repository < Notify::SourceRepository
    Log = ::Log.for("win_notification")

    # 未許可のときに許可状態を問い合わせ直す間隔。
    # 利用者が Windows の設定画面で許可した直後に中継が始まるようにするための再確認である。
    ACCESS_RECHECK_INTERVAL = 5.seconds

    property settings : Settings
    getter access_status : AccessStatus = AccessStatus::Unspecified

    def initialize(
      @client : ShimClient,
      @settings : Settings,
      @access_recheck_interval : Time::Span = ACCESS_RECHECK_INTERVAL,
    )
      @seen = Set(UInt32).new
      @primed = false
      @access_checked_at = Time.monotonic
    end

    def source_id : String
      SOURCE_ID
    end

    def poll_interval : Time::Span
      @settings.polling_interval_ms.milliseconds
    end

    # 開始のたびに差分検出の状態を戻す。
    # 無効にしている間に届いて通知センターに残っている通知を、
    # 再開直後の 1 周期で一斉に中継しないためである。
    def start : Nil
      reset_diff_state
      @client.open
      @access_status = @client.access_status
      @access_status = @client.request_access unless @access_status.allowed?
      @access_checked_at = Time.monotonic
      Log.info { "通知アクセスの許可状態: #{@access_status}" }
    end

    def stop : Nil
      @client.close
    end

    # 許可が下りるまでポーリングを行わない。
    # 常駐は続けたままなので、許可された時点で中継が始まる。
    #
    # 許可されている間も確かめ直す。
    # 起動後に利用者が許可を取り消すこともあり、そのまま呼び続けると
    # 失敗するポーリングを周期ごとに繰り返すことになるためである。
    def ready? : Bool
      if Time.monotonic - @access_checked_at >= @access_recheck_interval
        @access_checked_at = Time.monotonic
        previous = @access_status
        @access_status = @client.access_status

        if previous != @access_status
          Log.info { "通知アクセスの許可状態が変わった: #{previous} -> #{@access_status}" }
          # 許可が戻ったときは、拒否されていた間に届いて通知センターに残っている通知を
          # 再開直後の 1 周期で一斉に中継しないよう、開始時と同じく既読からやり直す。
          reset_diff_state if @access_status.allowed?
        end
      end
      @access_status.allowed?
    end

    # 前回の id 集合に無い通知だけを新規とみなす。
    # 初回の結果は既読として捨て、起動前に溜まっていた通知を一斉送信しない。
    def poll_new : Array(Notify::Incoming)
      list = NotificationList.from_json(@client.fetch_json)
      current = Set(UInt32).new(list.notifications.map(&.id))
      fresh = list.notifications.reject { |n| @seen.includes?(n.id) }
      @seen = current

      unless @primed
        @primed = true
        return [] of Notify::Incoming
      end

      fresh.map { |n| to_incoming(n) }
    end

    # 次のポーリングの結果を既読とみなす状態に戻す。
    private def reset_diff_state : Nil
      @seen = Set(UInt32).new
      @primed = false
    end

    private def to_incoming(notification : Notification) : Notify::Incoming
      icon = notification.icon_png_base64.try { |data| Notify::Icon.base64(data) }
      Notify::Incoming.new(
        source: SOURCE_ID,
        app_id: notification.app_id,
        app_name: notification.app_name,
        title: notification.title,
        body: notification.body,
        icon: icon,
        created_at: notification.created_time,
      )
    end
  end
end

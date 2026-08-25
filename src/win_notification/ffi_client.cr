require "./models"
require "./repository"

{% if flag?(:windows) %}
  require "./ffi"
{% end %}

module WinNotification
  class ShimError < Exception
  end

  # シムの C API を呼ぶ ShimClient 実装。
  # FFI に触れるのはこのクラスだけで、差分検出も整形もここには置かない。
  #
  # nls_init を呼んだスレッドと同じスレッドから全 API を呼ぶ契約のため（仕様書 3.4 節）、
  # 本体はこのクラスの呼び出しをメインスレッドに閉じ込める。
  class FfiClient < ShimClient
    def open : Nil
      {% if flag?(:windows) %}
        code = LibShim.init
        raise ShimError.new("シムの初期化に失敗した (#{code}): #{last_error}") if code < 0
      {% else %}
        raise ShimError.new("Windows 通知ソースは Windows でのみ動作する")
      {% end %}
    end

    def close : Nil
      {% if flag?(:windows) %}
        LibShim.shutdown
      {% end %}
    end

    def access_status : AccessStatus
      {% if flag?(:windows) %}
        AccessStatus.from_code(LibShim.get_access_status)
      {% else %}
        AccessStatus::Unknown
      {% end %}
    end

    def request_access : AccessStatus
      {% if flag?(:windows) %}
        AccessStatus.from_code(LibShim.request_access)
      {% else %}
        AccessStatus::Unknown
      {% end %}
    end

    # 文字列はシムが確保したものを受け取り、対になる解放関数で必ず返す。
    def fetch_json : String
      {% if flag?(:windows) %}
        pointer = LibShim.get_notifications
        raise ShimError.new("通知一覧を取得できなかった: #{last_error}") if pointer.null?

        begin
          String.new(pointer)
        ensure
          LibShim.free_string(pointer)
        end
      {% else %}
        raise ShimError.new("Windows 通知ソースは Windows でのみ動作する")
      {% end %}
    end

    private def last_error : String
      {% if flag?(:windows) %}
        pointer = LibShim.last_error
        pointer.null? ? "(詳細なし)" : String.new(pointer)
      {% else %}
        "(詳細なし)"
      {% end %}
    end
  end
end

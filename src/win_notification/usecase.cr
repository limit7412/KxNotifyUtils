require "../config/models"
require "../notify/models"
require "../notify/repository"
require "./models"

module WinNotification
  # Incoming と解決済みルールから Notify::Message を組み立てる（仕様書 4.3 節 手順 3 から手順 7）。
  # 整形の知識をソース側に集めるための配置であり、notify 側には順序制御だけが残る。
  class MessageBuilder < Notify::MessageBuilder
    # XSOverlay が組み込みアイコンとして解釈する名前。
    # 他のシンクを追加するときは、各アダプタがこの名前を自分の同等物へ対応づける。
    BUILTIN_ICONS = %w[default warning error]

    # 本文が無い通知の高さ。
    HEIGHT_WITHOUT_BODY = 100.0
    # 本文がある通知の高さの下限と上限。
    HEIGHT_MIN = 120.0
    HEIGHT_MAX = 250.0
    # 本文 1 文字あたりに加算する高さ。HEIGHT_MIN から 200 文字で HEIGHT_MAX に達する係数である。
    HEIGHT_PER_CHAR = 0.65

    SOURCE_APP = "KxNotifyUtils"

    def initialize(@icons : Notify::IconRepository)
    end

    def source_id : String
      SOURCE_ID
    end

    def build(incoming : Notify::Incoming, settings : ::Config::Resolved) : Notify::Message
      title = expand(settings.title_template, incoming)
      body = truncate(incoming.body, settings.max_body_length)

      Notify::Message.new(
        title: title,
        body: body,
        icon: resolve_icon(settings.icon, incoming),
        timeout: timeout_for(settings, title, body),
        sound: settings.sound,
        volume: settings.volume,
        source_app: SOURCE_APP,
        hints: Notify::DisplayHints.new(height: height_for(body), opacity: settings.opacity),
      )
    end

    # title テンプレートで置換するプレースホルダ。
    PLACEHOLDER = /\{(?:app_name|app_id|title|body)\}/

    # title テンプレートの展開。
    # 置換を 1 回の走査で済ませるのは、差し込んだ通知本文の中にプレースホルダらしき文字列が
    # 含まれていても再解釈しないためである。連鎖した gsub では、たとえば通知タイトルに
    # "{body}" と書かれていた場合に max_body_length を通さない本文が混ざり込む。
    private def expand(template : String, incoming : Notify::Incoming) : String
      template.gsub(PLACEHOLDER) do |match|
        case match
        when "{app_name}" then incoming.app_name
        when "{app_id}"   then incoming.app_id
        when "{title}"    then incoming.title
        else                   incoming.body
        end
      end
    end

    # max_body_length を超える本文は切り詰め、切り詰めたことがわかるよう末尾に記号を付ける。
    # 0 は「本文を載せない」を意味する。無制限を表す値は設けていない。
    private def truncate(body : String, max_length : Int32) : String
      return "" if max_length <= 0
      return body if body.size <= max_length
      "#{body[0, max_length]}…"
    end

    private def timeout_for(settings : ::Config::Resolved, title : String, body : String) : Float64
      case settings.timeout_mode
      in ::Config::TimeoutMode::Fixed
        settings.timeout
      in ::Config::TimeoutMode::Dynamic
        settings.dynamic_timeout.seconds_for(title.size + body.size)
      end
    end

    private def height_for(body : String) : Float64
      return HEIGHT_WITHOUT_BODY if body.empty?
      (HEIGHT_MIN + body.size * HEIGHT_PER_CHAR).clamp(HEIGHT_MIN, HEIGHT_MAX)
    end

    # ルールの icon 設定を解決する。
    # app 指定でアイコンが取れなかった場合と、ファイルが読めなかった場合は default へ落とす。
    private def resolve_icon(spec : String, incoming : Notify::Incoming) : Notify::Icon
      case spec
      when "app"
        incoming.icon || Notify::Icon.builtin("default")
      when .in?(BUILTIN_ICONS)
        Notify::Icon.builtin(spec)
      else
        if data = @icons.load_png_base64(spec)
          Notify::Icon.base64(data)
        else
          Notify::Icon.builtin("default")
        end
      end
    end
  end
end

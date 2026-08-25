require "base64"
require "log"
require "../notify/repository"

module Runtime
  # ルールがファイルパスで指定したアイコンを読み出す IconRepository 実装。
  #
  # 通知ごとに読み直すとポーリング周期に対して重いため、パスをキーに base64 表現を覚える。
  # 常駐アプリの実用上、ルールで指定されるアイコンは高々数個である。
  class IconRepository < Notify::IconRepository
    Log = ::Log.for("notify")

    def initialize
      @cache = {} of String => String?
    end

    def load_png_base64(path : String) : String?
      @cache.fetch(path) do
        @cache[path] = read(path)
      end
    end

    # 設定を保存したときに呼び、差し替えたアイコンを次の通知から反映させる。
    def clear : Nil
      @cache.clear
    end

    private def read(path : String) : String?
      Base64.strict_encode(File.read(path))
    rescue ex
      Log.warn { "アイコンのファイルを読めなかった: #{path} (#{ex.message})" }
      nil
    end
  end
end

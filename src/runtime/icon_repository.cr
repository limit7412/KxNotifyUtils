require "base64"
require "log"
require "../config/repository"
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

    # 設定の検証を通っていても、保存後にファイルが差し替わることはある。
    # PNG でないものを base64 化して送っても表示できないため、ここでも確かめて既定へ落とす。
    private def read(path : String) : String?
      content = File.read(path)
      unless content.to_slice[0, ::Config::PNG_SIGNATURE.size]? == ::Config::PNG_SIGNATURE
        Log.warn { "アイコンのファイルが PNG ではない: #{path}" }
        return nil
      end
      Base64.strict_encode(content)
    rescue ex
      Log.warn { "アイコンのファイルを読めなかった: #{path} (#{ex.message})" }
      nil
    end
  end
end

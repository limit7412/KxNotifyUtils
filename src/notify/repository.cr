require "./models"

module Notify
  # 監視対象の抽象（仕様書 2.3 節）。
  # 差分検出の方式はソースごとに違うため、poll_new の契約に含めて実装へ閉じる。
  abstract class SourceRepository
    # このソースの識別子。Incoming#source とルールのマッチングに使う。
    abstract def source_id : String

    # 前回の呼び出し以降に発生した新規通知を返す。
    abstract def poll_new : Array(Incoming)

    # このソースを呼び出す間隔。
    abstract def poll_interval : Time::Span

    # ソースの初期化。失敗した場合は例外を投げる。
    def start : Nil
    end

    # ソースの後始末。
    def stop : Nil
    end

    # 中継可能な状態か。false の間、このソースはポーリングの対象から外れる。
    def ready? : Bool
      true
    end
  end

  # 通知先の抽象（仕様書 4.4 節）。
  abstract class PostRepository
    # このシンクの識別子。ログとテスト通知の宛先表示に使う。
    abstract def sink_id : String

    # Message を送信する。
    # 接続断などで送信できなかった場合は false を返し、呼び出し側はその通知を破棄する。
    abstract def send_message(message : Message) : Bool

    # シンクへの接続を開始する。
    def start : Nil
    end

    # シンクへの接続を終了する。
    def stop : Nil
    end
  end

  # ルールが指定したアイコンファイルを読み出す境界。
  # usecase 自身は I/O を行わないため、ファイル読み出しはこの抽象越しに行う。
  abstract class IconRepository
    # PNG ファイルを読んで base64 表現を返す。読めなかった場合は nil を返す。
    abstract def load_png_base64(path : String) : String?
  end

  # Incoming と解決済みルールから Message を組み立てる規約。
  # 整形の知識はソース側に置くため、実装は各ソースのコンテキストが提供する（仕様書 4.3 節）。
  abstract class MessageBuilder
    # 組み立てを担当するソースの識別子。
    abstract def source_id : String

    abstract def build(incoming : Incoming, settings : ::Config::Resolved) : Message
  end
end

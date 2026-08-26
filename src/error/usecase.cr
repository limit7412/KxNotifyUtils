require "log"

# 例外の記録と利用者への通知。
module Error
  # 例外をログへ落とし、利用者が気付けるようトレイ通知にも出す。
  # 通知の出し方は runtime 側から差し込むため、ここは Win32 にもトレイにも依存しない。
  class Usecase
    Log = ::Log.for("error")

    # トレイ通知を出すためのフック。composition root が登録する。
    property notifier : Proc(String, String, Nil) = ->(_title : String, _body : String) {}

    # 例外の文脈は辞書のキーで受け取り、ログ用と表示用を別々に開く（issue #4）。
    # ログは開発者が読むものなので言語を固定し、通知は利用者が選んだ言語で出す。
    # 辞書は runtime 側にあり、ここから参照すると層が逆さになるため、
    # 解決そのものは composition root から差し込む。
    # 既定はキーを素通しする。差し込む前に例外が出ても、何の文脈かは残る。
    property log_text : Proc(String, String) = ->(key : String) { key }
    property display_text : Proc(String, String) = ->(key : String) { key }

    def handle(key : String, exception : Exception) : Nil
      Log.error(exception: exception) { @log_text.call(key) }
      notify(@display_text.call(key), exception.message || exception.class.to_s)
    end

    def notify(title : String, body : String) : Nil
      @notifier.call(title, body)
    rescue ex
      Log.error(exception: ex) { "トレイ通知を出せなかった" }
    end

    # 中断させたくない処理を包む。例外はログとトレイ通知に変えて握りつぶす。
    def guard(key : String, & : -> Nil) : Nil
      yield
    rescue exception
      handle(key, exception)
    end
  end
end

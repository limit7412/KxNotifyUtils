require "log"

# 例外の記録と利用者への通知。
module Error
  # 例外をログへ落とし、利用者が気付けるようトレイ通知にも出す。
  # 通知の出し方は runtime 側から差し込むため、ここは Win32 にもトレイにも依存しない。
  class Usecase
    Log = ::Log.for("error")

    # トレイ通知を出すためのフック。composition root が登録する。
    property notifier : Proc(String, String, Nil) = ->(_title : String, _body : String) {}

    def handle(context : String, exception : Exception) : Nil
      Log.error(exception: exception) { context }
      notify(context, exception.message || exception.class.to_s)
    end

    def notify(title : String, body : String) : Nil
      @notifier.call(title, body)
    rescue ex
      Log.error(exception: ex) { "トレイ通知を出せなかった" }
    end

    # 中断させたくない処理を包む。例外はログとトレイ通知に変えて握りつぶす。
    def guard(context : String, & : -> Nil) : Nil
      yield
    rescue exception
      handle(context, exception)
    end
  end
end

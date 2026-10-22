module Sleep
  # 外部アプリから読んだ睡眠の状態。
  enum SignalState
    # 読めていない。相手が動いていないか、まだ見つけていない。
    Unknown
    # 睡眠中ではない。
    Awake
    # 睡眠中である。
    Asleep
  end

  # 睡眠中かを外部アプリから読む境界（issue #54）。
  #
  # 今の実装は OyasumiVR の睡眠モードを読むものだけである。
  # 読み取りは別のファイバで進め、ここでは直近の結果だけを返す。
  # 主ループから毎周期呼ばれるため、ここで応答を待つとトレイも設定画面も止まる。
  abstract class Signal
    abstract def state : SignalState
  end
end

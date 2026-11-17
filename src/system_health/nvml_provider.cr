require "log"
require "./models"
require "./repository"

module SystemHealth
  # NVML から取れた計測値 1 回ぶん。取れなかった項目は nil である。
  struct NvmlSample
    enum State
      # 取得スレッドが動いていない。
      Stopped
      # 取得スレッドは動いているが、まだ 1 回も取れていない。
      Starting
      # 取れている。
      Sampling
      # NVML を使えない。NVIDIA の GPU が無い環境がこれにあたる。
      Unavailable
    end

    getter state : State
    # 直近に取れてからの経過。取得スレッドが NVML の中で止まると伸び続ける。
    getter age : Time::Span
    getter device_count : Int32
    getter temperature_c : Int32?
    # 温度のしきい値。順に、動作上限、減速を始める温度、停止する温度。
    getter limit_gpu_max_c : Int32?
    getter limit_slowdown_c : Int32?
    getter limit_shutdown_c : Int32?
    getter fan_percent : Int32?
    # クロックを制限している理由のビットマスク。
    getter clock_reasons : UInt64?

    def initialize(
      @state : State,
      @age : Time::Span = Time::Span.zero,
      @device_count : Int32 = 0,
      @temperature_c : Int32? = nil,
      @limit_gpu_max_c : Int32? = nil,
      @limit_slowdown_c : Int32? = nil,
      @limit_shutdown_c : Int32? = nil,
      @fan_percent : Int32? = nil,
      @clock_reasons : UInt64? = nil,
    )
    end

    # 余裕の計算に使う上限。
    #
    # 動作上限を使う。返さない機種では、減速を始める温度で代える。
    # 停止する温度は使わない。そこまでの余裕で判定すると、減速が始まってからの通知になる。
    def limit_c : Int32?
      @limit_gpu_max_c || @limit_slowdown_c
    end
  end

  # NVML の計測値を読む境界。
  #
  # 実装は取得を別のスレッドで行い、read は待たずに最後に取れた値を返す。
  # NVIDIA の GPU が応答を止めると NVML の呼び出しは戻らなくなるため、
  # 主ループから NVML を直に呼ぶ実装は置けない。
  abstract class NvmlReader
    # 取得スレッドを立てる。既に動いていれば間隔だけを差し替える。立てられなければ例外を投げる。
    abstract def start(interval : Time::Span) : Nil
    abstract def stop : Nil
    abstract def read : NvmlSample

    # NVML を使えなかった理由。ログに残すための文字列である。
    def last_error : String
      ""
    end
  end

  # NVIDIA の GPU の計測値を取る。
  class NvmlProvider < MetricProvider
    Log = ::Log.for("system_health")

    PROVIDER_ID = "nvml"

    # ソフトウェアによる温度制限が作動していることを示すビット（nvmlClocksEventReasonSwThermalSlowdown）。
    #
    # ハードウェア側の減速（0x08、0x40、0x80）はここでは見ない。
    # そちらはクロックを半分以下に落とす別の保護であり、別の規則として扱う。
    THERMAL_SLOWDOWN_BIT = 0x20_u64

    # 取れてからこれより古い値は使わない。
    #
    # 取得スレッドが NVML の中で止まると、最後に取れた値がいつまでも残る。
    # その値で判定を続けると、GPU が止まった後も「温度に余裕がある」と見なし続ける。
    MIN_STALE_AFTER = 5.seconds

    def initialize(@reader : NvmlReader)
      @stale_after = MIN_STALE_AFTER
      # 直前に見た状態。切り替わりをログへ残すために持つ。
      @state = NvmlSample::State::Stopped
      @stale = false
    end

    def provider_id : String
      PROVIDER_ID
    end

    def start(interval : Time::Span) : Nil
      @stale_after = {MIN_STALE_AFTER, interval * 3}.max
      @reader.start(interval)
    end

    def stop : Nil
      @reader.stop
      @state = NvmlSample::State::Stopped
      @stale = false
    end

    def sample(samples : Hash(String, Float64)) : Nil
      current = @reader.read
      report_state(current)
      return unless current.state.sampling?

      stale = current.age > @stale_after
      report_stale(stale, current)
      return if stale

      if reasons = current.clock_reasons
        samples[Metric::GPU_THERMAL_THROTTLE] = reasons.bits_set?(THERMAL_SLOWDOWN_BIT) ? 1.0 : 0.0
      end
      if fan = current.fan_percent
        samples[Metric::GPU_FAN] = fan.to_f64
      end

      temperature = current.temperature_c
      return if temperature.nil?
      samples[Metric::GPU_TEMPERATURE] = temperature.to_f64

      limit = current.limit_c
      return if limit.nil?
      samples[Metric::GPU_TEMPERATURE_LIMIT] = limit.to_f64
      samples[Metric::GPU_THERMAL_MARGIN] = (limit - temperature).to_f64
    end

    # 状態の切り替わりをログへ残す。
    #
    # 取れ始めたときは、ドライバが返したしきい値をすべて書く。
    # 余裕の計算にどの温度を使っているかを、利用者が自分の機種で確かめられるようにするためである。
    private def report_state(current : NvmlSample) : Nil
      return if current.state == @state
      @state = current.state

      case current.state
      in .sampling?
        Log.info do
          "NVML から取れ始めた: GPU #{current.device_count} 台、" \
          "動作上限 #{degrees(current.limit_gpu_max_c)}、減速 #{degrees(current.limit_slowdown_c)}、" \
          "停止 #{degrees(current.limit_shutdown_c)}、余裕の計算に使う上限 #{degrees(current.limit_c)}"
        end
      in .unavailable?
        Log.info { "NVML を使えないため GPU の計測値は取らない: #{@reader.last_error}" }
      in .starting?, .stopped?
      end
    end

    private def report_stale(stale : Bool, current : NvmlSample) : Nil
      return if stale == @stale
      @stale = stale
      if stale
        Log.warn { "NVML の値が #{current.age.total_seconds.round(1)} 秒更新されていない。GPU の計測値を使わない" }
      else
        Log.info { "NVML の値が更新されるようになった" }
      end
    end

    private def degrees(value : Int32?) : String
      value ? "#{value}℃" : "不明"
    end
  end
end

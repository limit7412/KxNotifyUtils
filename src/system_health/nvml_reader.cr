require "./nvml_ffi"
require "./nvml_provider"

module SystemHealth
  # シムの取得スレッドから NVML の計測値を読む NvmlReader 実装。
  #
  # Windows の外では取得スレッドを持たず、常に「使えない」を返す。
  class ShimNvmlReader < NvmlReader
    def start(interval : Time::Span) : Nil
      {% if flag?(:windows) %}
        # 構造体の宣言がシムと食い違ったまま読むと、ずれた位置の値を計測値として扱うことになる。
        expected = sizeof(LibNvmlMonitor::Sample)
        actual = LibNvmlMonitor.sample_size
        raise "nvm_sample の大きさがシムと食い違っている（本体 #{expected}、シム #{actual}）" unless actual == expected

        code = LibNvmlMonitor.start(interval.total_milliseconds.to_u32)
        raise "NVML の取得スレッドを立てられなかった（#{code}）: #{last_error}" unless code == 0
      {% end %}
    end

    def stop : Nil
      {% if flag?(:windows) %}
        LibNvmlMonitor.stop
      {% end %}
    end

    def read : NvmlSample
      {% if flag?(:windows) %}
        raw = LibNvmlMonitor::Sample.new
        LibNvmlMonitor.read(pointerof(raw))
        NvmlSample.new(
          state: state_of(raw.state),
          age: raw.age_ms.milliseconds,
          device_count: raw.device_count.to_i32,
          temperature_c: known(raw.temperature_c),
          limit_gpu_max_c: known(raw.limit_gpu_max_c),
          limit_slowdown_c: known(raw.limit_slowdown_c),
          limit_shutdown_c: known(raw.limit_shutdown_c),
          fan_percent: known(raw.fan_percent),
          clock_reasons: raw.clock_reasons_valid != 0 ? raw.clock_reasons : nil,
        )
      {% else %}
        NvmlSample.new(NvmlSample::State::Unavailable)
      {% end %}
    end

    def last_error : String
      {% if flag?(:windows) %}
        String.new(LibNvmlMonitor.last_error)
      {% else %}
        "Windows でのみ使える"
      {% end %}
    end

    private def known(value : Int32) : Int32?
      value == LibNvmlMonitor::UNKNOWN ? nil : value
    end

    private def state_of(value : Int32) : NvmlSample::State
      case value
      when LibNvmlMonitor::STATE_STARTING    then NvmlSample::State::Starting
      when LibNvmlMonitor::STATE_SAMPLING    then NvmlSample::State::Sampling
      when LibNvmlMonitor::STATE_UNAVAILABLE then NvmlSample::State::Unavailable
      else                                        NvmlSample::State::Stopped
      end
    end
  end
end

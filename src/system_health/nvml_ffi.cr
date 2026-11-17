module SystemHealth
  # NVML の取得スレッド（シムの nvml_monitor）の C API 宣言。
  #
  # NVML の呼び出しはシムの中のスレッドが行い、ここから呼ぶ関数はどれも待たない。
  # nvml.dll はシムが実行時に探してロードするため、ここではリンクしない。
  # この lib 宣言を参照するのは同じコンテキストの nvml_reader.cr だけとする。
  @[Link("NotifListenerShim")]
  lib LibNvmlMonitor
    STATE_STOPPED     = 0
    STATE_STARTING    = 1
    STATE_SAMPLING    = 2
    STATE_UNAVAILABLE = 3

    # 値が取れなかった項目に入る値。
    UNKNOWN = -1

    # nvm_sample。並びと大きさはシムの nvml_monitor.h と揃える。
    struct Sample
      state : Int32
      age_ms : UInt32
      device_count : UInt32
      temperature_c : Int32
      limit_gpu_max_c : Int32
      limit_slowdown_c : Int32
      limit_shutdown_c : Int32
      fan_percent : Int32
      clock_reasons : UInt64
      clock_reasons_valid : Int32
      reserved : Int32
    end

    fun sample_size = nvm_sample_size : UInt32
    fun start = nvm_start(interval_ms : UInt32) : Int32
    fun stop = nvm_stop : Void
    fun read = nvm_read(sample : Sample*) : Int32
    fun last_error = nvm_last_error : UInt8*
  end
end

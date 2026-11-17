module SystemHealth
  # 計測値の取得に使う Win32 API の宣言。
  lib LibSysInfo
    # MEMORYSTATUSEX。length には構造体の大きさを入れてから渡す。
    struct MemoryStatusEx
      length : UInt32
      memory_load : UInt32
      total_phys : UInt64
      avail_phys : UInt64
      total_page_file : UInt64
      avail_page_file : UInt64
      total_virtual : UInt64
      avail_virtual : UInt64
      avail_extended_virtual : UInt64
    end

    fun global_memory_status_ex = GlobalMemoryStatusEx(buffer : MemoryStatusEx*) : Int32
  end
end

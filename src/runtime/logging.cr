require "log"
require "./paths"

module Runtime
  # 日次ローテーションでログを書き出すバックエンド（仕様書 6 章）。
  # 世代数を超えた古いファイルは書き出しのタイミングで消す。
  class DailyFileBackend < ::Log::Backend
    GENERATIONS = 7

    def initialize(@directory : String, @generations : Int32 = GENERATIONS)
      super(:direct)
      @date = ""
      @file = nil.as(File?)
    end

    def write(entry : ::Log::Entry) : Nil
      file = rotate(entry.timestamp)
      return unless file

      file << entry.timestamp.to_s("%Y-%m-%dT%H:%M:%S.%3N%:z")
      file << " [" << entry.severity.label << "] " << entry.source << " - " << entry.message << '\n'
      if exception = entry.exception
        file << "  " << exception.class << ": " << exception.message << '\n'
      end
      file.flush
    rescue
      # ログの書き出し失敗で常駐を止めるわけにはいかないため、ここでは握りつぶす。
    end

    def close : Nil
      @file.try(&.close)
      @file = nil
    end

    private def rotate(timestamp : Time) : File?
      date = timestamp.to_s("%Y-%m-%d")
      return @file if date == @date && @file

      @file.try(&.close)
      Dir.mkdir_p(@directory)
      @date = date
      @file = File.open(File.join(@directory, "kxnotifyutils-#{date}.log"), "a")
      prune
      @file
    end

    private def prune : Nil
      logs = Dir.glob(File.join(@directory, "kxnotifyutils-*.log")).sort
      return if logs.size <= @generations
      logs[0...(logs.size - @generations)].each { |path| File.delete(path) rescue nil }
    end
  end

  module Logging
    # ログレベルを差し替える。
    # バックエンドは開いたファイルを抱えるため、composition root が持つ 1 つを使い回す。
    def self.setup(backend : ::Log::Backend, level : String = "info") : Nil
      ::Log.setup(severity(level), backend)
    end

    def self.severity(level : String) : ::Log::Severity
      ::Log::Severity.parse(level)
    rescue
      ::Log::Severity::Info
    end
  end
end

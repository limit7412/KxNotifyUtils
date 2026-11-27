require "json"
require "log"

module Runtime
  # 最終成功時刻のメトリクス（仕様書 9）。
  #
  # CloudWatch の Embedded Metric Format で出す。
  # 決まった形の JSON を一行書けば CloudWatch がメトリクスとして拾うので、
  # PutMetricData を呼ぶ資格情報も、実行ロールへの権限の追加も要らない。
  # 実行ロールが持っているのはログの書き込みだけである（infra/src/roles.ts）。
  #
  # 仕様書 9 の「5 分以上更新がなければ通知する」は、この値が 5 分間 0 で
  # あることをアラームの条件にすれば表せる。
  # アラームは infra の持ちものなので、ここは数えるところまでを持つ。
  class Metrics
    Log = ::Log.for("metrics")

    NAMESPACE = "VRCServiceStatusPanel"

    # 次元。スタックごとに分けて数える。
    DIMENSION = "Env"

    # 一回の実行が配信まで終えたこと。
    SUCCESS = "RefreshSuccess"

    UNIT = "Count"

    # 出力先を受け取るのは、spec から読み取るためである。
    def initialize(@env : String, @io : IO = STDOUT)
    end

    # 配信まで終えた実行を一つ数える。
    def success(now : Time? = nil) : Nil
      emit(SUCCESS, 1, now || Time.utc)
    end

    private def emit(name : String, value : Int32, at : Time) : Nil
      # 一行に収める。CloudWatch は改行で記録を割るので、
      # 途中で折り返した JSON はメトリクスとして読まれない。
      @io.puts(document(name, value, at))
    rescue error
      # 数えられなくても、その実行は配信まで終えている。
      # ここで例外を出すと、成功した実行が失敗として報告される。
      Log.error(exception: error) { "メトリクスを出せなかった" }
    end

    # 仕様書ではなく AWS が形を決めている。
    # https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/CloudWatch_Embedded_Metric_Format_Specification.html
    private def document(name : String, value : Int32, at : Time) : String
      JSON.build do |json|
        json.object do
          json.field("_aws") do
            json.object do
              # ミリ秒で渡す。秒で渡すと 1970 年の値として捨てられる。
              json.field("Timestamp", at.to_unix_ms)
              json.field("CloudWatchMetrics") do
                json.array do
                  json.object do
                    json.field("Namespace", NAMESPACE)
                    json.field("Dimensions") { json.array { json.array { json.string(DIMENSION) } } }
                    json.field("Metrics") do
                      json.array do
                        json.object do
                          json.field("Name", name)
                          json.field("Unit", UNIT)
                        end
                      end
                    end
                  end
                end
              end
            end
          end

          # Dimensions に挙げた名前は、根の直下に値が要る。
          json.field(DIMENSION, @env)
          json.field(name, value)
        end
      end
    end
  end
end

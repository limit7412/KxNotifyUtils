require "./booth/repository"
require "./config"
require "./error/usecase"
require "./r2/repository"
require "./runtime/lambda"
require "./runtime/metrics"
require "./status/models"
require "./status/repository"
require "./status/usecase"
require "./statuspage/repository"
require "./steam/repository"
require "./youtube/repository"

# 構成ルート（仕様書 11.2、11.7）。
# コールドスタート時に一度だけ環境変数を解決し、依存を組み立てる。
#
# 関数は `_HANDLER` で振り分ける。同じバイナリを複数の関数で使い回すための形で、
# 参考リポジトリ（limit7412/github_notifications_slack）と同じである。
# 関数を増やすときは、ここへ handler を足し、HANDLERS と infra/index.ts の
# FUNCTIONS にも同じ名前を足す。

HANDLERS = %w[refresh]

Runtime::Lambda.setup_log
Runtime::Lambda.setup_ssl_cert

config = begin
  Main::Config.from(ENV.to_h)
rescue ex
  Runtime::Lambda.fail_to_start(ex)
end

Log.info { "起動した handler=#{Runtime::Lambda.handler_name} #{config.to_log}" }

# 取得元（仕様書 3.2）。
#
# この並びが、そのまま配信 JSON の services の並びになる（仕様書 4）。
# 取得元を足すときは、表示したい位置へ挟む（仕様書 11.6）。
#
# 来訪者が最初に疑うもの（VRChat と、ワールドで使う三つ）を上に置き、
# 公式ステータスページを持つ周辺サービスを下に置いた。
#
# 取得元のインスタンスはここで一度だけ作り、ウォームスタートのあいだ生かす。
# Statuspage 系は前回の ETag と本文をインスタンスに持ち、条件付き GET に使う
# （仕様書 5.4、11.7）。実行ごとに作り直すと、その控えが毎回捨てられる。
sources = [
  Statuspage::Repository.new(
    service_id: "vrchat",
    display_name: "VRChat",
    page_url: "https://status.vrchat.com",
    # status.vrchat.com の実応答（2026-09-04）にある component をすべて挙げる。
    # 箱（API / Website、Realtime Networking）は中身の写しなので入れない。
    # 応答に無い名前は黙って落ちるので、上流が名称を変えても、
    # そのサービスの level までは巻き添えにならない。
    component_names: [
      "Authentication / Login",
      "Social / Friends List",
      "SDK Asset Uploads",
      "Realtime Player State Changes",
      "USA, West (San José)",
      "USA, East (Washington D.C.)",
      "Europe (Amsterdam)",
      "Japan (Tokyo)",
    ],
  ),
  Youtube::Repository.new(config.youtube_probe_video_id),
  Steam::Repository.new,
  Booth::Repository.new(config.booth_probe_item_id),
  Statuspage::Repository.new(
    service_id: "discord",
    display_name: "Discord",
    page_url: "https://discordstatus.com",
  ),
  Statuspage::Repository.new(
    service_id: "cloudflare",
    display_name: "Cloudflare",
    page_url: "https://www.cloudflarestatus.com",
  ),
  Statuspage::Repository.new(
    service_id: "twitch",
    display_name: "Twitch",
    page_url: "https://status.twitch.com",
  ),
] of Status::SourceRepository

feeds = R2::Repository.new(
  endpoint: config.r2_endpoint,
  access_key_id: config.r2_access_key_id,
  secret_access_key: config.r2_secret_access_key,
  public_bucket: config.r2_public_bucket,
  state_bucket: config.r2_state_bucket,
)

usecase = Status::Usecase.new(sources, feeds)
errors = Error::Usecase.new(config.env, config.alert_webhook_url)
metrics = Runtime::Metrics.new(config.env)

Runtime::Lambda.handler "refresh" do |_event, request_id|
  feed = begin
    usecase.refresh
  rescue ex
    # 失敗の記録と Lambda への報告は runtime が行う（仕様書 11.7）。
    # ここで足すのは、人へ届ける経路だけである。
    errors.alert("refresh", ex, request_id)
    raise ex
  end

  # 配信まで終えた実行を数える（仕様書 9）。
  # 上流の一部が取れなくても、前回値を継いで配り切れていれば成功である。
  # 止まったことを見たいのであって、上流の調子はメトリクスの外にある。
  metrics.success

  Log.info do
    "配信した generated_unix=#{feed.generated_unix} " \
    "stale=#{feed.stale?} services=#{feed.services.size}"
  end

  # Runtime API へ返したものを読む相手はいない。記録に残るだけなので、
  # 配信物そのものではなく、その実行が何をしたかの要約を返す。
  {
    generated_unix: feed.generated_unix,
    stale:          feed.stale?,
    services:       feed.services.size,
  }
end

# ここへ到達するのは `_HANDLER` がどの handler とも一致しなかったときである。
Runtime::Lambda.reject_unknown_handler(HANDLERS)

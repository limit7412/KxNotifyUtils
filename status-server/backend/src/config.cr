# 環境変数の解決（仕様書 11.7）。
#
# 仕様書 11.2 はこれを main.cr の仕事としているが、main.cr は require した時点で
# Runtime API のループに入る。解決の規則だけを spec から確かめられるよう、
# ここへ分けている。組み立ては main.cr のままである。
module Main
  struct Config
    # 欠けている環境変数。起動時に落とすためのもの（仕様書 11.7）。
    #
    # 空文字も欠けているものとして扱う。CI が Secrets から組み立てるとき、
    # 未設定の Secret は空文字で展開されるためである。
    class MissingEnv < Exception
      getter keys : Array(String)

      def initialize(@keys : Array(String))
        super("環境変数が足りない: #{@keys.join(", ")}")
      end
    end

    # 実行環境の名前。ログとアラートの文面に出す
    getter env : String
    # 配信先と内部バケット（仕様書 6）
    getter r2_endpoint : String
    getter r2_public_bucket : String
    getter r2_state_bucket : String
    getter r2_access_key_id : String
    getter r2_secret_access_key : String
    # 合成監視の対象（仕様書 3.3）
    getter youtube_probe_video_id : String
    getter booth_probe_item_id : String
    # 失敗時のアラート送信先（仕様書 11.2 の error/usecase.cr）
    getter alert_webhook_url : String

    REQUIRED = %w[
      ENV
      R2_ENDPOINT
      R2_PUBLIC_BUCKET
      R2_STATE_BUCKET
      R2_ACCESS_KEY_ID
      R2_SECRET_ACCESS_KEY
      YOUTUBE_PROBE_VIDEO_ID
      BOOTH_PROBE_ITEM_ID
      ALERT_WEBHOOK_URL
    ]

    # 足りないものを一度に挙げる。
    # 一つ直しては次で落ちる、を繰り返さずに済む。
    def self.from(source : Hash(String, String)) : Config
      missing = REQUIRED.reject { |key| present?(source[key]?) }
      raise MissingEnv.new(missing) unless missing.empty?

      new(
        env: source["ENV"],
        r2_endpoint: source["R2_ENDPOINT"],
        r2_public_bucket: source["R2_PUBLIC_BUCKET"],
        r2_state_bucket: source["R2_STATE_BUCKET"],
        r2_access_key_id: source["R2_ACCESS_KEY_ID"],
        r2_secret_access_key: source["R2_SECRET_ACCESS_KEY"],
        youtube_probe_video_id: source["YOUTUBE_PROBE_VIDEO_ID"],
        booth_probe_item_id: source["BOOTH_PROBE_ITEM_ID"],
        alert_webhook_url: source["ALERT_WEBHOOK_URL"],
      )
    end

    private def self.present?(value : String?) : Bool
      !value.nil? && !value.empty?
    end

    def initialize(
      @env : String,
      @r2_endpoint : String,
      @r2_public_bucket : String,
      @r2_state_bucket : String,
      @r2_access_key_id : String,
      @r2_secret_access_key : String,
      @youtube_probe_video_id : String,
      @booth_probe_item_id : String,
      @alert_webhook_url : String,
    )
    end

    # ログに出せる範囲だけを返す。鍵は含めない。
    def to_log : String
      "env=#{env} public=#{r2_public_bucket} state=#{r2_state_bucket}"
    end
  end
end

require "http/client"
require "json"
require "log"

# Lambda の Runtime API をそのまま扱う（仕様書 11.2）。
#
# shard を挟まないのは参考リポジトリ（limit7412/github_notifications_slack）と
# 同じ方針である。やり取りは HTTP 三種だけで、依存を増やす利がない。
#
# handler は名前で振り分ける。`_HANDLER` と一致したものだけがループに入るので、
# main.cr に handler を並べれば、ひとつのバイナリで複数の関数を賄える。
# 関数を増やすときは infra 側の handler 文字列と名前を揃えること。
module Runtime
  module Lambda
    extend self

    API_VERSION = "2018-06-01"

    # 静的リンクした OpenSSL は CA バンドルを自力で見つけられない（仕様書 5.1）。
    # provided.al2023 が置いている場所を起動時に教える。
    # これを忘れると、上流への HTTPS がすべて証明書エラーで失敗する。
    CA_BUNDLE = "/etc/pki/tls/cert.pem"

    REQUEST_ID_HEADER = "Lambda-Runtime-Aws-Request-Id"
    ERROR_TYPE_HEADER = "Lambda-Runtime-Function-Error-Type"

    Log = ::Log.for("lambda")

    # 環境変数が無い、つまり Lambda の外で動かされたとき。
    class NotOnLambda < Exception
      def initialize
        super("AWS_LAMBDA_RUNTIME_API が無い。Lambda の上でのみ動く")
      end
    end

    # `_HANDLER` が main.cr のどの handler とも一致しないとき。
    # infra 側の handler 文字列と main.cr の名前がずれている。
    class UnknownHandler < Exception
      def initialize(name : String, known : Array(String))
        super("_HANDLER=#{name.inspect} に対応する handler が無い。ある名前: #{known.join(", ")}")
      end
    end

    @@dispatched = false

    # CloudWatch は改行で記録を割るため、一件を一行に収める。
    def setup_log(level : ::Log::Severity = ::Log::Severity::Info) : Nil
      ::Log.setup(level, ::Log::IOBackend.new(STDOUT, formatter: FORMATTER))
    end

    FORMATTER = ::Log::Formatter.new do |entry, io|
      io << entry.severity.label << ' '
      io << entry.source << ' ' unless entry.source.empty?
      io << entry.message.gsub('\n', ' ')
      if ex = entry.exception
        io << " | " << ex.class << ": " << ex.message.to_s.gsub('\n', ' ')
      end
    end

    def setup_ssl_cert(path : String = CA_BUNDLE) : Nil
      # 呼び出し側が明示していればそちらを尊重する。
      return if ENV["SSL_CERT_FILE"]?
      return unless File.exists?(path)

      ENV["SSL_CERT_FILE"] = path
    end

    def handler_name : String
      ENV["_HANDLER"]? || ""
    end

    def endpoint : String
      value = ENV["AWS_LAMBDA_RUNTIME_API"]?
      raise NotOnLambda.new if value.nil? || value.empty?

      value
    end

    # 名前が `_HANDLER` と一致したときだけ、起動を受けては block へ渡す。
    #
    # block には起動の中身と request id を渡す。
    # 後者はアラートの本文に入る（仕様書 11.7）。使わない block は受けなくてよい。
    #
    # block の例外はその起動の失敗として報告し、ループは続ける。
    # 一回の失敗でプロセスを終わらせると、次の 60 秒まで何も更新されない。
    def handler(name : String, &) : Nil
      return unless name == handler_name

      @@dispatched = true
      client = client_for(endpoint)

      loop do
        begin
          response = client.get("/#{API_VERSION}/runtime/invocation/next")
        rescue ex : IO::Error
          # Runtime API との接続が切れた。実行環境が畳まれるときに起きる。
          # 掴んでも次の起動は来ないので、記録して抜ける。
          # Lambda はプロセスの終了を検知して新しい実行環境を立ち上げる。
          Log.error(exception: ex) { "Runtime API との接続が切れた" }
          return
        end

        request_id = response.headers[REQUEST_ID_HEADER]?
        if request_id.nil?
          Log.error { "#{REQUEST_ID_HEADER} が応答に無い" }
          next
        end

        begin
          body = yield JSON.parse(response.body), request_id
          post(client, "invocation/#{request_id}/response", body.to_json)
        rescue ex
          Log.error(exception: ex) { "起動の処理に失敗した request_id=#{request_id}" }
          post(
            client,
            "invocation/#{request_id}/error",
            error_body(ex),
            HTTP::Headers{ERROR_TYPE_HEADER => "Unhandled"},
          )
        end
      end
    end

    # handler をすべて並べたあとに呼ぶ。
    #
    # ここへ到達するのは、どの handler も `_HANDLER` と一致しなかったときである。
    # 一致していれば handler の中のループから戻らない。
    # 名前のずれは設定の取り違えなので、黙って終わらせずに報告して落とす。
    def reject_unknown_handler(known : Array(String)) : Nil
      return if @@dispatched

      fail_to_start(UnknownHandler.new(handler_name, known))
    end

    # 初期化そのものに失敗したことを伝えて落とす。
    # 起動を受けてから落ちると、失敗が 60 秒ごとに繰り返される。
    def fail_to_start(ex : Exception) : NoReturn
      Log.error(exception: ex) { "初期化に失敗した" }
      report_init_error(ex)
      exit 1
    end

    private def report_init_error(ex : Exception) : Nil
      post(client_for(endpoint), "init/error", error_body(ex))
    rescue error
      # 報告できなくても構わない。伝える手段が無いだけで、終わることに変わりはない。
      Log.error(exception: error) { "初期化の失敗を報告できなかった" }
    end

    private def client_for(endpoint : String) : HTTP::Client
      client = HTTP::Client.new(URI.parse("http://#{endpoint}"))
      # 次の起動を待つ GET は応答が来るまで開いたままになる。
      # 読み取りに制限を掛けると、待っている間に自分から切ってしまう。
      client.read_timeout = nil
      client
    end

    private def post(client : HTTP::Client, path : String, body : String, headers : HTTP::Headers? = nil) : Nil
      client.post("/#{API_VERSION}/runtime/#{path}", headers: headers, body: body)
    end

    private def error_body(ex : Exception) : String
      {errorType: ex.class.name, errorMessage: ex.message.to_s}.to_json
    end
  end
end

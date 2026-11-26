require "http/client"
require "json"
require "log"
require "uri"

# 失敗の通知（仕様書 11.2、11.7）。
#
# handler は refresh の例外をここへ渡してから再送出する。
# 再送出するので、Runtime API へはその起動の失敗として報告される。
# ここが担うのは、人へ届ける経路だけである。
module Error
  class Usecase
    Log = ::Log.for("error")

    # 送信の上限。
    # 上流への GET と揃える理由は無いが、待ち続けても実行の残り時間を
    # 食うだけなので、同じ 5 秒で諦める。
    TIMEOUT = 5.seconds

    # 同じ種類の失敗を送る間隔。
    #
    # 60 秒ごとに同じ原因で落ちると、通知も 60 秒ごとに届く。
    # 一通目で分かることは二通目には無く、届き続けると読まれなくなる。
    #
    # 最後に送った時刻はインスタンスが持つので、コールドスタートで忘れる。
    # そのときは一通余分に届く。
    INTERVAL = 10.minutes

    # Discord の上限。越えると 400 で断られ、届かないことだけが残る。
    # https://discord.com/developers/docs/resources/message#embed-object-embed-limits
    # （2026-09-05 に原文で確かめた。#48）
    #
    # field の name（256）、fields の個数（25）、embeds の個数（10）にも上限があるが、
    # ここで送るのは固定の名前を持つ三つの field と一つの embed なので、越えない。
    CONTENT_LIMIT     = 2000
    TITLE_LIMIT       =  256
    DESCRIPTION_LIMIT = 4096
    FIELD_LIMIT       = 1024

    # embed 全体で数える上限。title、description、field の name と value の
    # 文字数を、すべての embed にわたって足したものがこれを越えてはならない。
    # 項目ごとの上限を守っていても、足すと越えうる（4096 + 1024 × 3 で既に越える）。
    EMBED_TOTAL_LIMIT = 6000

    # 埋め込みの左端の色。赤系にしておく。
    COLOR = 0xE74C3C

    def initialize(@env : String, @webhook_url : String)
      @last_sent = {} of String => Time
    end

    # 失敗を一件送る。
    #
    # 抑えたことは記録しない。失敗そのものは runtime が毎回記録しており、
    # 通知が来ないあいだも、ログを見れば続いていることが分かる。
    def alert(handler : String, error : Exception, request_id : String?, now : Time? = nil) : Nil
      at = now || Time.utc
      kind = error.class.name

      return unless due?(kind, at)

      # 送れたかによらず、試みた時点で数える。
      # 送れないものは 10 分後にもたぶん送れない。
      # 毎分試しても届かず、届かなかったことのログだけが増える。
      @last_sent[kind] = at

      post(body(handler, error, kind, request_id))
    end

    private def due?(kind : String, at : Time) : Bool
      last = @last_sent[kind]?

      last.nil? || at - last >= INTERVAL
    end

    # Discord の webhook が受け取る形。
    # https://discord.com/developers/docs/resources/webhook#execute-webhook
    #
    # 仕様書 11.2 は「JSON を POST する」とだけ定めていて、形は送信先が決める。
    # Discord は content か embeds のどちらかを求め、平らな JSON は 400 で断る。
    # 仕様書 11.7 の五つは、種類を title に、文面を description に、残りを fields に置く。
    #
    # content は通知の一行目になる。押し通知に出るのはここなので、
    # どこの何が落ちたかを、開かずに分かる形にする。
    #
    # 全体の上限（EMBED_TOTAL_LIMIT）は description で吸収する。
    # 他の項目は短いか、上限が小さいかのどちらかで、いちばん長くなりうるのが
    # 例外のメッセージだからである。title と fields を先に決め、残りを description に渡す。
    private def body(handler : String, error : Exception, kind : String, request_id : String?) : String
      title = clip(kind, TITLE_LIMIT)
      fields = [
        {name: "env", value: clip(@env, FIELD_LIMIT), inline: true},
        {name: "handler", value: clip(handler, FIELD_LIMIT), inline: true},
        # 空の value は断られる。request id は runtime が必ず付けるが、型は nil を許す。
        {name: "request_id", value: clip(request_id || "-", FIELD_LIMIT), inline: false},
      ]

      used = title.size + fields.sum { |field| field[:name].size + field[:value].size }
      # 他の項目が上限いっぱいでも 2,000 字あまりは残る。clamp は念のためである。
      description_limit = (EMBED_TOTAL_LIMIT - used).clamp(1, DESCRIPTION_LIMIT)

      {
        content: clip("#{@env} の #{handler} が失敗した", CONTENT_LIMIT),
        embeds:  [{
          title:       title,
          description: clip(error.message.to_s, description_limit),
          color:       COLOR,
          fields:      fields,
        }],
      }.to_json
    end

    # 上限を越えた分を落とす。Discord は超過を切り詰めず、400 で丸ごと断る。
    # 数えるのは文字であってバイトではない。
    private def clip(text : String, limit : Int32) : String
      return text if text.size <= limit

      text[0, limit - 1] + "…"
    end

    private def post(body : String) : Nil
      uri = URI.parse(@webhook_url)

      client = HTTP::Client.new(uri)
      client.connect_timeout = TIMEOUT
      client.read_timeout = TIMEOUT

      response = begin
        client.post(
          request_target(uri),
          headers: HTTP::Headers{"Content-Type" => "application/json"},
          body: body,
        )
      ensure
        client.close
      end

      return if response.success?

      Log.error { "アラートが受け取られなかった HTTP #{response.status_code}" }
    rescue error
      # 送れなくても、失敗そのものは runtime が記録して Lambda へ報告する。
      # 伝える手立てが一つ欠けるだけなので、ここで例外を出さない。
      # 出せば、本体の失敗の報告がアラートの失敗に置き換わる。
      Log.error(exception: error) { "アラートを送れなかった" }
    end

    private def request_target(uri : URI) : String
      target = uri.request_target

      target.empty? ? "/" : target
    end
  end
end

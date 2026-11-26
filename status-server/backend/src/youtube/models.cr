require "json"

# YouTube の応答の写像（仕様書 3.3）。
module Youtube
  # oEmbed の応答。
  #
  # 動画が解決できたことだけを見るので、題だけを読む。
  # 解決できない動画は 401 か 404 を返し、本文はここへ来ない。
  struct OEmbed
    include JSON::Serializable

    getter title : String
  end
end

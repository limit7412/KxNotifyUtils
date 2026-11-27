require "json"

# Steam Web API の応答の写像（仕様書 3.3）。
module Steam
  # ISteamWebAPIUtil/GetServerInfo の応答。
  #
  # 見たいのは「Web API が生きているか」だけなので、時刻の一項目しか読まない。
  # 読めれば生きていると判断する。API キーが要らないのはこの経路だけである。
  struct ServerInfo
    include JSON::Serializable

    getter servertime : Int64
  end
end

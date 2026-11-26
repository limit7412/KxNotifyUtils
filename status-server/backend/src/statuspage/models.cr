require "json"
require "../status/models"

# Atlassian Statuspage の summary.json の写像（仕様書 3.2、11.3）。
# 判定と表示に使う項目だけを持ち、他の項目は読み捨てる。
module Statuspage
  # indicator と level の対応（仕様書 3.2）。
  #
  # maintenance は仕様書の表に無いが、Statuspage は計画された停止でこれを返す。
  # 予告された一部停止であって全断ではないため Degraded に寄せる。
  # 表に無い値は判定できないものとして Unknown にする。上流が新しい indicator を
  # 足したとき、黙って正常と報せるよりは判定不能と出したほうが害が小さい。
  def self.level_of(indicator : String) : Status::Level
    case indicator
    when "none"
      Status::Level::Operational
    when "minor", "maintenance"
      Status::Level::Degraded
    when "major", "critical"
      Status::Level::MajorOutage
    else
      Status::Level::Unknown
    end
  end

  # component の状態と level の対応（仕様書 4 の components）。
  def self.component_level(status : String) : Status::Level
    case status
    when "operational"
      Status::Level::Operational
    when "degraded_performance", "partial_outage", "under_maintenance"
      Status::Level::Degraded
    when "major_outage"
      Status::Level::MajorOutage
    else
      Status::Level::Unknown
    end
  end

  # note に出すときの表記。degraded_performance を「Degraded Performance」にする。
  def self.label_of(status : String) : String
    status.split('_').map(&.capitalize).join(' ')
  end

  # note に出す一件を選ぶための重さ。
  #
  # level では並べられない。level は判定できない状態を最も大きい 3 に置くので、
  # そのまま最大を取ると、知らない状態が major_outage を押しのけてしまう。
  SEVERITY = %w[under_maintenance degraded_performance partial_outage major_outage]

  # 知らない状態は最も軽いものとして扱う。他に出すものが無ければ選ばれる。
  def self.severity_of(status : String) : Int32
    SEVERITY.index(status) || -1
  end

  # ページ全体の指標。JSON の status に対応する。
  # 型名を Status にすると中核の Status モジュールを隠してしまうため、こう呼ぶ。
  struct PageStatus
    include JSON::Serializable

    getter indicator : String = "unknown"
    getter description : String = ""
  end

  struct Component
    include JSON::Serializable

    getter name : String
    getter status : String = "unknown"

    # 他の component をまとめる箱かどうか。
    # 箱の状態は中身の写しなので、note にも components にも出さない。
    getter? group : Bool = false
  end

  struct Incident
    include JSON::Serializable

    getter name : String
    getter status : String = ""
  end

  struct Summary
    include JSON::Serializable

    # 進行中でないインシデントの status（Statuspage の定義）。
    RESOLVED = %w[resolved postmortem]

    @[JSON::Field(key: "status")]
    getter page_status : PageStatus

    getter components : Array(Component) = [] of Component
    getter incidents : Array(Incident) = [] of Incident

    def indicator : String
      page_status.indicator
    end

    # 一行の説明（仕様書 3.2）。
    #
    # 進行中のインシデントがあればその名称を出し、無ければ operational でない
    # component を一件だけ出す。該当が複数あるときは最も重いものを選ぶ。
    # 切り詰めはここでは行わない。整形は ServiceStatus の生成時に一度だけ行う
    # （仕様書 11.5）。
    def note : String
      if incident = ongoing_incident
        return incident.name
      end

      if component = worst_component
        return "#{component.name}: #{Statuspage.label_of(component.status)}"
      end

      ""
    end

    # 表示対象に選んだ component を配信 JSON の形へ写す（仕様書 4）。
    #
    # 並びは渡した名前の順にし、応答での並びは見ない。上流が並べ替えても
    # パネルの行が入れ替わらないためである。
    # 名前が見つからないものは黙って落とす。上流が名称を変えたとき、
    # そのサービスの level まで巻き添えで判定不能にはしない。
    def components_for(names : Array(String)) : Array(Status::Component)?
      picked = names.compact_map do |name|
        component = listed_components.find { |candidate| candidate.name == name }
        next if component.nil?

        Status::Component.new(component.name, Statuspage.component_level(component.status))
      end

      picked.empty? ? nil : picked
    end

    private def ongoing_incident : Incident?
      incidents.find { |incident| !RESOLVED.includes?(incident.status) }
    end

    private def listed_components : Array(Component)
      components.reject(&.group?)
    end

    private def worst_component : Component?
      listed_components
        .reject { |component| component.status == "operational" }
        .max_by? { |component| Statuspage.severity_of(component.status) }
    end
  end
end

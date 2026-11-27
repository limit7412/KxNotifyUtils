require "../spec_helper"

# 障害の出ている VRChat を模した応答（仕様書 3.2）。
# Live Services は個々の component をまとめる箱で、状態は中身の写しである。
private def summary_json : String
  <<-JSON
    {
      "page": { "id": "vrchat", "name": "VRChat", "url": "https://status.vrchat.com" },
      "components": [
        { "id": "1", "name": "Live Services", "status": "partial_outage", "group": true },
        { "id": "2", "name": "API", "status": "operational", "group": false },
        { "id": "3", "name": "Websocket", "status": "partial_outage", "group": false },
        { "id": "4", "name": "Website", "status": "degraded_performance", "group": false }
      ],
      "incidents": [],
      "scheduled_maintenances": [],
      "status": { "indicator": "minor", "description": "Partially Degraded Service" }
    }
    JSON
end

private def operational_json : String
  <<-JSON
    {
      "components": [
        { "id": "2", "name": "API", "status": "operational", "group": false }
      ],
      "incidents": [
        { "id": "9", "name": "過去の障害", "status": "resolved" }
      ],
      "status": { "indicator": "none", "description": "All Systems Operational" }
    }
    JSON
end

private def incident_json : String
  <<-JSON
    {
      "components": [
        { "id": "3", "name": "Websocket", "status": "major_outage", "group": false }
      ],
      "incidents": [
        { "id": "8", "name": "過去の障害", "status": "postmortem" },
        { "id": "9", "name": "Websocket の接続が切れる", "status": "investigating" }
      ],
      "status": { "indicator": "critical", "description": "Major Service Outage" }
    }
    JSON
end

describe Statuspage do
  describe ".level_of" do
    it "maps every indicator listed in the specification" do
      Statuspage.level_of("none").should eq Status::Level::Operational
      Statuspage.level_of("minor").should eq Status::Level::Degraded
      Statuspage.level_of("major").should eq Status::Level::MajorOutage
      Statuspage.level_of("critical").should eq Status::Level::MajorOutage
    end

    it "treats a planned maintenance as a partial degradation" do
      Statuspage.level_of("maintenance").should eq Status::Level::Degraded
    end

    it "refuses to judge an indicator it does not know" do
      Statuspage.level_of("meltdown").should eq Status::Level::Unknown
    end
  end

  describe ".component_level" do
    it "maps the component states of Statuspage" do
      Statuspage.component_level("operational").should eq Status::Level::Operational
      Statuspage.component_level("degraded_performance").should eq Status::Level::Degraded
      Statuspage.component_level("partial_outage").should eq Status::Level::Degraded
      Statuspage.component_level("under_maintenance").should eq Status::Level::Degraded
      Statuspage.component_level("major_outage").should eq Status::Level::MajorOutage
      Statuspage.component_level("meltdown").should eq Status::Level::Unknown
    end
  end

  describe ".label_of" do
    it "spells the component state as words" do
      Statuspage.label_of("partial_outage").should eq "Partial Outage"
      Statuspage.label_of("operational").should eq "Operational"
    end
  end
end

describe Statuspage::Summary do
  it "reads the indicator of the page" do
    Statuspage::Summary.from_json(summary_json).indicator.should eq "minor"
  end

  describe "#note" do
    it "names the heaviest component that is not operational" do
      Statuspage::Summary.from_json(summary_json).note.should eq "Websocket: Partial Outage"
    end

    it "prefers the name of an ongoing incident" do
      Statuspage::Summary.from_json(incident_json).note.should eq "Websocket の接続が切れる"
    end

    it "is empty while every component is operational" do
      Statuspage::Summary.from_json(operational_json).note.should eq ""
    end
  end

  describe "#components_for" do
    it "follows the order it was asked for, not the order of the response" do
      summary = Statuspage::Summary.from_json(summary_json)

      components = summary.components_for(["Websocket", "API"]) || [] of Status::Component

      components.map(&.name).should eq ["Websocket", "API"]
      components.map(&.level).should eq [
        Status::Level::Degraded.value,
        Status::Level::Operational.value,
      ]
    end

    it "drops a name the response does not carry" do
      summary = Statuspage::Summary.from_json(summary_json)

      components = summary.components_for(["API", "Auth"]) || [] of Status::Component

      components.map(&.name).should eq ["API"]
    end

    it "never picks the box that groups the components" do
      summary = Statuspage::Summary.from_json(summary_json)

      summary.components_for(["Live Services"]).should be_nil
    end

    it "is nil when nothing was asked for" do
      Statuspage::Summary.from_json(summary_json).components_for([] of String).should be_nil
    end

    # status.vrchat.com の実応答（2026-09-04、ブラウザから取得）。
    # 名前を見当で書いた最初の四つは一つも一致せず、dev の配信 JSON から
    # components が丸ごと消えていた。main.cr に並べる名前はここから取る。
    it "picks every VRChat component from the real summary" do
      summary = Statuspage::Summary.from_json(File.read(File.join(__DIR__, "fixtures", "vrchat-summary.json")))
      names = [
        "Authentication / Login",
        "Social / Friends List",
        "SDK Asset Uploads",
        "Realtime Player State Changes",
        "USA, West (San José)",
        "USA, East (Washington D.C.)",
        "Europe (Amsterdam)",
        "Japan (Tokyo)",
      ]

      components = summary.components_for(names) || [] of Status::Component

      components.map(&.name).should eq names
      components.map(&.level).should eq [Status::Level::Operational.value] * 8
    end
  end
end

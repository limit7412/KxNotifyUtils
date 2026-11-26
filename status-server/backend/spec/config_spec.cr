require "./spec_helper"

private def full_env : Hash(String, String)
  {
    "ENV"                    => "dev",
    "R2_ENDPOINT"            => "https://example.r2.cloudflarestorage.com",
    "R2_PUBLIC_BUCKET"       => "status-public",
    "R2_STATE_BUCKET"        => "status-state",
    "R2_ACCESS_KEY_ID"       => "key-id",
    "R2_SECRET_ACCESS_KEY"   => "secret",
    "YOUTUBE_PROBE_VIDEO_ID" => "video",
    "BOOTH_PROBE_ITEM_ID"    => "item",
    "ALERT_WEBHOOK_URL"      => "https://example.test/hook",
  }
end

describe Main::Config do
  describe ".from" do
    it "揃っていれば読み取る" do
      config = Main::Config.from(full_env)

      config.env.should eq("dev")
      config.r2_public_bucket.should eq("status-public")
    end

    it "欠けていれば落とす" do
      source = full_env
      source.delete("R2_ENDPOINT")

      expect_raises(Main::Config::MissingEnv) do
        Main::Config.from(source)
      end
    end

    # CI は Secrets から env を組み立てる。未設定の Secret は空文字で展開されるため、
    # 空文字を通してしまうと、鍵が無いまま起動して上流への PUT で初めて気づく。
    it "空文字も欠けているものとして扱う" do
      source = full_env
      source["R2_SECRET_ACCESS_KEY"] = ""

      expect_raises(Main::Config::MissingEnv) do
        Main::Config.from(source)
      end
    end

    it "足りないものを一度に挙げる" do
      source = full_env
      source.delete("ENV")
      source["ALERT_WEBHOOK_URL"] = ""

      error = expect_raises(Main::Config::MissingEnv) do
        Main::Config.from(source)
      end

      error.keys.should eq(["ENV", "ALERT_WEBHOOK_URL"])
    end
  end

  describe "#to_log" do
    it "鍵を含めない" do
      log = Main::Config.from(full_env).to_log

      log.should contain("env=dev")
      log.should_not contain("secret")
      log.should_not contain("key-id")
    end
  end
end

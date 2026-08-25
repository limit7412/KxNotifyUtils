require "../spec_helper"

describe Config::FileRepository do
  describe "#file_exists?" do
    it "通常のファイルだけを受け付け、ディレクトリは受け付けない" do
      directory = File.tempname("kxnotifyutils-spec")
      Dir.mkdir_p(directory)
      file = File.join(directory, "sound.wav")
      File.write(file, "")

      repository = Config::FileRepository.new(File.join(directory, "config.json"))
      repository.file_exists?(file).should be_true
      repository.file_exists?(directory).should be_false
      repository.file_exists?(File.join(directory, "missing.wav")).should be_false
    ensure
      FileUtils.rm_rf(directory) if directory
    end
  end

  describe "#save" do
    it "書き出した設定を読み戻せる" do
      directory = File.tempname("kxnotifyutils-spec")
      path = File.join(directory, "config.json")
      repository = Config::FileRepository.new(path)

      repository.exists?.should be_false
      repository.save(Config::Root.default)

      repository.exists?.should be_true
      repository.load.sinks.keys.should eq ["xsoverlay"]
    ensure
      FileUtils.rm_rf(directory) if directory
    end
  end
end

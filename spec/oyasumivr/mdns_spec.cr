require "../spec_helper"
require "../../src/oyasumivr/mdns"

# 名前をラベルの並びとして書き出す。圧縮はしない。
private def write_name(io : IO, name : String) : Nil
  name.split('.').each do |label|
    io.write_byte(label.bytesize.to_u8)
    io << label
  end
  io.write_byte(0_u8)
end

private def write_u16(io : IO, value : Int) : Nil
  io.write_bytes(value.to_u16, IO::ByteFormat::BigEndian)
end

private def write_record(io : IO, name : String, type : Int, data : Bytes) : Nil
  write_name(io, name)
  write_u16(io, type)
  write_u16(io, 1)
  io.write_bytes(120_u32, IO::ByteFormat::BigEndian)
  write_u16(io, data.size)
  io.write(data)
end

private def srv_data(port : Int, target : String) : Bytes
  io = IO::Memory.new
  write_u16(io, 0)
  write_u16(io, 0)
  write_u16(io, port)
  write_name(io, target)
  io.to_slice
end

private def name_data(name : String) : Bytes
  io = IO::Memory.new
  write_name(io, name)
  io.to_slice
end

# OyasumiVR の応答と同じ並びの応答を作る。
# 回答に種別からインスタンスへの PTR、追加に SRV と A を置く。
# address を偽にすると A を省き、SRV で終わる応答になる。
private def response(instance : String, port : Int, address : Bool = true) : Bytes
  io = IO::Memory.new
  {0, 0x8400, 0, 1, 0, address ? 2 : 1}.each { |value| write_u16(io, value) }
  write_record(io, "_oscjson._tcp.local", 12, name_data(instance))
  write_record(io, instance, 33, srv_data(port, instance))
  write_record(io, instance, 1, Bytes[127, 0, 0, 1]) if address
  io.to_slice
end

describe OyasumiVR::Mdns do
  it "問い合わせは _oscjson._tcp.local の PTR をユニキャストの応答つきで問う" do
    query = OyasumiVR::Mdns.query

    # id、flags、問い合わせ 1 件、残りは 0 件。
    query[0, 12].should eq Bytes[0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0]
    query[12, 21].should eq name_data("_oscjson._tcp.local")
    # type PTR (12)、class IN (1) に最上位ビットを立てたもの。
    query[33, 4].should eq Bytes[0, 12, 0x80, 1]
    query.size.should eq 37
  end

  it "応答から OyasumiVR の SRV のポートを取り出す" do
    OyasumiVR::Mdns.find_port(response("oyasumivr._oscjson._tcp.local", 51234)).should eq 51234
  end

  it "インスタンス名の大文字と小文字は区別しない" do
    OyasumiVR::Mdns.find_port(response("OyasumiVR._oscjson._tcp.local", 51234)).should eq 51234
  end

  it "ほかのインスタンスの応答は無視する" do
    OyasumiVR::Mdns.find_port(response("VRChat-Client-ABCDEF._oscjson._tcp.local", 9001)).should be_nil
  end

  it "圧縮ポインタで書かれた名前も読む" do
    io = IO::Memory.new
    {0, 0x8400, 0, 1, 0, 1}.each { |value| write_u16(io, value) }
    # 12 バイト目から種別の名前が始まる。
    write_record(io, "_oscjson._tcp.local", 12, name_data("oyasumivr._oscjson._tcp.local"))
    # SRV の名前は "oyasumivr" と、12 バイト目へのポインタで書く。
    io.write_byte(9_u8)
    io << "oyasumivr"
    io.write(Bytes[0xC0, 12])
    write_u16(io, 33)
    write_u16(io, 1)
    io.write_bytes(120_u32, IO::ByteFormat::BigEndian)
    write_u16(io, 8)
    io.write(Bytes[0, 0, 0, 0, 0xC8, 0x00, 0xC0, 12])

    OyasumiVR::Mdns.find_port(io.to_slice).should eq 0xC800
  end

  it "問い合わせのパケットは応答として読まない" do
    OyasumiVR::Mdns.find_port(OyasumiVR::Mdns.query).should be_nil
  end

  # SRV で終わる応答を使い、どこで切れても SRV を読み切れないようにする。
  it "途中で切れた応答は見つからなかったものとして扱う" do
    packet = response("oyasumivr._oscjson._tcp.local", 51234, address: false)
    OyasumiVR::Mdns.find_port(packet).should eq 51234

    (0...packet.size).each do |size|
      OyasumiVR::Mdns.find_port(packet[0, size]).should be_nil
    end
  end

  it "輪になった圧縮ポインタで止まらない" do
    io = IO::Memory.new
    {0, 0x8400, 0, 1, 0, 0}.each { |value| write_u16(io, value) }
    io.write(Bytes[0xC0, 12])

    OyasumiVR::Mdns.find_port(io.to_slice).should be_nil
  end
end

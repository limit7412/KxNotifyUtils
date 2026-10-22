module OyasumiVR
  # OSCQuery サーバを mDNS で探すためのパケットの組み立てと解析（issue #54）。
  #
  # ソケットを持たない純粋関数だけを置く。
  # 送受信は repository が行い、ここは固定のバイト列で確かめられるようにしておく。
  #
  # 名前の比較は大文字と小文字を区別しない。DNS の名前はそう比べる決まりであり、
  # OyasumiVR も版によって "OyasumiVR" と、小文字にした "oyasumivr" のどちらでも名乗る。
  module Mdns
    SERVICE  = "_oscjson._tcp.local"
    INSTANCE = "oyasumivr.#{SERVICE}"

    TYPE_PTR = 12_u16
    TYPE_SRV = 33_u16
    CLASS_IN =  1_u16
    # 問い合わせの class の最上位ビット。応答を送信元へユニキャストで返すよう求める（RFC 6762 5.4 節）。
    UNICAST_RESPONSE = 0x8000_u16

    HEADER_SIZE = 12
    # 圧縮ポインタを辿る回数の上限。壊れた応答がポインタで輪を作っても止まるようにする。
    MAX_POINTER_JUMPS = 64

    # 解析の途中で応答の形が崩れていたときに投げる。外へは出さず nil へ畳む。
    class MalformedError < Exception
    end

    # `_oscjson._tcp.local` の PTR を問う 1 問だけのパケット。
    #
    # 一時ポートから送るため、応答はユニキャストで返ってくる。
    # 5353 へ bind せずに済むので、同じ PC の他の mDNS 実装とポートを取り合わない。
    def self.query : Bytes
      io = IO::Memory.new
      # id、flags、問い合わせ数、回答数、権威数、追加数。
      {0_u16, 0_u16, 1_u16, 0_u16, 0_u16, 0_u16}.each { |value| io.write_bytes(value, IO::ByteFormat::BigEndian) }
      SERVICE.split('.').each do |label|
        io.write_byte(label.bytesize.to_u8)
        io << label
      end
      io.write_byte(0_u8)
      io.write_bytes(TYPE_PTR, IO::ByteFormat::BigEndian)
      io.write_bytes(CLASS_IN | UNICAST_RESPONSE, IO::ByteFormat::BigEndian)
      io.to_slice
    end

    # 応答から instance の SRV レコードを探し、そのポートを返す。無ければ nil を返す。
    #
    # 同じ種別には VRChat なども応えるため、ポートはインスタンス名で選ぶ。
    # SRV は回答にも追加にも置かれうるので、問い合わせ以外の全レコードを見る。
    # 応答の形が崩れていても例外は出さず、見つからなかったものとして扱う。
    def self.find_port(packet : Bytes, instance : String = INSTANCE) : Int32?
      return nil if packet.size < HEADER_SIZE
      # 最上位ビットが 0 のものは問い合わせであり、他の機器の問い合わせが届くこともある。
      return nil unless packet[2] & 0x80 != 0

      questions = read_u16(packet, 4)
      records = read_u16(packet, 6).to_i + read_u16(packet, 8) + read_u16(packet, 10)
      offset = HEADER_SIZE
      questions.times do
        _, offset = read_name(packet, offset)
        offset += 4
      end

      records.times do
        name, offset = read_name(packet, offset)
        type = read_u16(packet, offset)
        length = read_u16(packet, offset + 8).to_i
        data = offset + 10
        raise MalformedError.new if data + length > packet.size

        if type == TYPE_SRV && length >= 6 && name.compare(instance, case_insensitive: true) == 0
          port = read_u16(packet, data + 4).to_i
          return port unless port == 0
        end
        offset = data + length
      end
      nil
    rescue MalformedError | IndexError
      nil
    end

    # offset から名前を読み、ラベルを "." で繋いだものと、名前の直後の位置を返す。
    #
    # 圧縮ポインタを辿った場合、直後の位置はポインタの次になる。
    private def self.read_name(packet : Bytes, offset : Int32) : {String, Int32}
      labels = [] of String
      position = offset
      after = nil.as(Int32?)
      jumps = 0
      loop do
        length = packet[position]
        if length == 0
          return {labels.join('.'), after || position + 1}
        elsif length & 0xC0 == 0xC0
          jumps += 1
          raise MalformedError.new if jumps > MAX_POINTER_JUMPS
          after ||= position + 2
          position = ((length.to_i & 0x3F) << 8) | packet[position + 1]
        elsif length & 0xC0 == 0
          start = position + 1
          raise MalformedError.new if start + length > packet.size
          labels << String.new(packet[start, length])
          position = start + length
        else
          # 0x40 と 0x80 は拡張ラベルの予約であり、mDNS の応答には現れない。
          raise MalformedError.new
        end
      end
    end

    private def self.read_u16(packet : Bytes, offset : Int32) : UInt16
      raise MalformedError.new if offset + 2 > packet.size
      (packet[offset].to_u16 << 8) | packet[offset + 1]
    end
  end
end

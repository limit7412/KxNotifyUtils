require "../notify/template_message_builder"
require "./models"

module ServiceStatus
  # 障害検知の Incoming から Notify::Message を組み立てる。
  #
  # 整形は共通の TemplateMessageBuilder のままである。
  # レベルに応じたアイコンは repository が Incoming の icon に組み込み名で載せており、
  # ルールの icon が "app" なら共通の解決がそれをそのまま使う。
  class MessageBuilder < Notify::TemplateMessageBuilder
    def source_id : String
      SOURCE_ID
    end
  end
end

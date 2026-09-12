require "../notify/template_message_builder"
require "./models"

module WinNotification
  # Windows 通知の Incoming から Notify::Message を組み立てる。
  # 整形は共通の TemplateMessageBuilder のままで、このソースに固有の整形は無い。
  # ソースごとに MessageBuilder を持つ配置（仕様書 4.3 節）は保ち、source_id だけを返す。
  class MessageBuilder < Notify::TemplateMessageBuilder
    def source_id : String
      SOURCE_ID
    end
  end
end

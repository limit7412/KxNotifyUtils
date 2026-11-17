require "log"
require "../notify/models"
require "../notify/repository"
require "./evaluator"
require "./ffi"
require "./models"

module SystemHealth
  # 計測値の取得元の境界。
  #
  # 規則の評価は取得元の素性を見ないため、取得元を足しても評価には手を入れない。
  # spec ではテスト用実装に差し替える。
  abstract class MetricProvider
    # providers の鍵になる識別子。
    abstract def provider_id : String

    # 取れた計測値を samples へ書く。取れなかった値は書かない。
    #
    # 主ループの中で呼ばれるため、待ちを伴う取得をここで行うわけにはいかない。
    # 待ちうる取得元は別のスレッドで取り、ここでは最後に取れた値を書く。
    abstract def sample(samples : Hash(String, Float64)) : Nil
  end

  # 物理メモリの使用率を取る。
  #
  # GlobalMemoryStatusEx はカーネルが持つ値を読むだけで待ちが無く、主ループから直に呼べる。
  class MemoryProvider < MetricProvider
    PROVIDER_ID = "memory"

    def provider_id : String
      PROVIDER_ID
    end

    def sample(samples : Hash(String, Float64)) : Nil
      {% if flag?(:windows) %}
        status = LibSysInfo::MemoryStatusEx.new
        status.length = sizeof(LibSysInfo::MemoryStatusEx).to_u32
        return if LibSysInfo.global_memory_status_ex(pointerof(status)) == 0
        return if status.total_phys == 0

        used = status.total_phys - status.avail_phys
        samples[Metric::MEMORY_PHYSICAL_USAGE] = used.to_f64 * 100.0 / status.total_phys.to_f64
      {% end %}
    end
  end

  # 規則 1 件の通知の文言。
  #
  # 本文には {value}（計測値）、{threshold}（しきい値）、{for_s}（継続の秒数）を書ける。
  struct RuleTexts
    getter title : String
    getter body : String
    getter cleared_title : String
    getter cleared_body : String

    def initialize(@title : String, @body : String, @cleared_title : String, @cleared_body : String)
    end
  end

  # 通知に載せる文言。
  #
  # 辞書は runtime 側にあり、ここから参照すると層が逆さになるため、
  # composition root が辞書から引いたものを受け取る。
  struct Texts
    getter app_name : String
    getter rules : Hash(String, RuleTexts)

    def initialize(@app_name : String, @rules : Hash(String, RuleTexts))
    end
  end

  # システムヘルスの SourceRepository 実装。
  #
  # 返すのは状態が変わった規則の通知だけである。
  # 条件が成り立っている間じゅう通知を出し続けることはしない。
  class Repository < Notify::SourceRepository
    Log = ::Log.for("system_health")

    PLACEHOLDER = /\{(?:value|threshold|for_s)\}/

    getter settings : Settings
    # 通知に載せる文言。言語が決まるのは起動の途中なので、後から差し替えられる。
    property texts : Texts

    def initialize(@providers : Array(MetricProvider), @settings : Settings, @texts : Texts)
      @evaluator = Evaluator.new
      @rules = @settings.rules
      # 取得で例外を出した取得元。同じ失敗を周期ごとに警告しないために持つ。
      @failing = Set(String).new
      # 読み飛ばしたことを知らせ済みの鍵。設定は反映のたびに渡されるため、同じ警告を繰り返さない。
      @reported_unknown = [] of String
    end

    def source_id : String
      SOURCE_ID
    end

    def poll_interval : Time::Span
      @settings.polling_interval_s.seconds
    end

    def settings=(settings : Settings) : Nil
      @settings = settings
      @rules = settings.rules
      unknown = settings.unknown_alert_ids.map { |id| "alerts.#{id}" } +
                settings.unknown_provider_ids.map { |id| "providers.#{id}" }
      return if unknown == @reported_unknown
      @reported_unknown = unknown
      Log.warn { "知らない鍵を読み飛ばした: #{unknown.join(", ")}" } unless unknown.empty?
    end

    # 開始のたびに規則の状態を戻す。
    # 無効にする前の継続時間を、有効に戻した後へ引き継がないためである。
    def start : Nil
      @evaluator.reset
      @failing.clear
    end

    def poll_new : Array(Notify::Incoming)
      poll_new(Time.monotonic)
    end

    # 時刻を受け取るのは、継続時間と再発報の間隔を spec から確かめるためである。
    def poll_new(now : Time::Span) : Array(Notify::Incoming)
      fresh = [] of Notify::Incoming
      @evaluator.evaluate(@rules, collect, now).each do |transition|
        rule = transition.rule
        case transition.kind
        in .fired?
          Log.info { "発報した: #{rule.id} 値=#{transition.value.round(1)} しきい値=#{rule.threshold}" }
          fresh << to_incoming(transition)
        in .cleared?
          Log.info { "解除した: #{rule.id} 値=#{transition.value.round(1)}" }
          fresh << to_incoming(transition) if rule.notify_clear?
        end
      end
      fresh
    end

    # 有効な取得元から計測値を集める。
    #
    # ある取得元の失敗は、他の取得元の値を使った評価を妨げない。
    private def collect : Hash(String, Float64)
      samples = {} of String => Float64
      @providers.each do |provider|
        id = provider.provider_id
        next unless @settings.provider_enabled?(id)

        begin
          provider.sample(samples)
          Log.info { "計測値を取れるようになった: #{id}" } if @failing.delete(id)
        rescue ex
          if @failing.add?(id)
            Log.warn(exception: ex) { "計測値を取れなかった: #{id}" }
          end
        end
      end
      samples
    end

    private def to_incoming(transition : Evaluator::Transition) : Notify::Incoming
      rule = transition.rule
      texts = @texts.rules[rule.id]?
      fired = transition.kind.fired?
      title = fired ? texts.try(&.title) : texts.try(&.cleared_title)
      body = fired ? texts.try(&.body) : texts.try(&.cleared_body)
      severity = fired ? rule.definition.severity : Severity::Default

      Notify::Incoming.new(
        source: SOURCE_ID,
        app_id: "#{SOURCE_ID}.#{rule.id}",
        app_name: @texts.app_name,
        # 文言の無い規則は id をそのまま出す。黙って捨てるより、何が起きたかは伝わる。
        title: title || rule.id,
        body: expand(body || "", transition),
        icon: Notify::Icon.builtin(severity.icon_name),
      )
    end

    # 本文のプレースホルダを値で置き換える。
    private def expand(template : String, transition : Evaluator::Transition) : String
      rule = transition.rule
      template.gsub(PLACEHOLDER) do |match|
        case match
        when "{value}"     then transition.value.round.to_i.to_s
        when "{threshold}" then number(rule.threshold)
        else                    rule.for_s.to_s
        end
      end
    end

    # 設定に書かれた数値を、書かれた形に近いまま出す。95.0 は 95 と出す。
    private def number(value : Float64) : String
      value == value.round ? value.to_i.to_s : value.to_s
    end
  end
end

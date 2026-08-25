require "log"
require "json"
require "./models"
require "./repository"

module Config
  # 検証エラー 1 件。
  # section は設定 GUI がどのタブを指し示すかを決めるために使う（仕様書 4.8.2 節）。
  struct ValidationError
    getter section : String
    getter message : String

    def initialize(@section : String, @message : String)
    end

    def to_s(io : IO) : Nil
      io << section << ": " << message
    end
  end

  # 設定の検証、保存、再読み込み、各 usecase への反映を担う（仕様書 4.8.2 節）。
  class Usecase
    Log = ::Log.for("config")

    BUILTIN_ICONS  = %w[default warning error]
    BUILTIN_SOUNDS = %w[default warning error]
    LOG_LEVELS     = %w[trace debug info notice warn error fatal none]

    # 検証を通った設定を各 usecase へ流すためのフック。
    # composition root がスナップショットの差し替えを登録する。
    property on_apply : Proc(Root, Nil) = ->(_root : Root) {}

    getter current : Root
    getter repository : Repository

    # current が設定ファイルの内容かどうか。
    # 読めなかったときは既定値で動くため、その内容でファイルを書き戻してはならない。
    getter? readable : Bool = true

    def initialize(@repository : Repository, @current : Root = Root.default)
      # sources と sinks の各セクションは、そのアダプタが自分で検証する。
      @section_validators = {} of String => Proc(JSON::Any?, Array(String))
    end

    # "sources.windows" のようなセクション名に対する検証をアダプタから登録する。
    def register_validator(section : String, &block : JSON::Any? -> Array(String)) : Nil
      @section_validators[section] = block
    end

    # 起動時の読み込み。
    # 設定ファイルが無ければ初期設定を書き出し、壊れていれば初期設定で起動する。
    def load : Array(ValidationError)
      unless @repository.exists?
        @current = Root.default
        @repository.save(@current)
        Log.info { "初期設定を書き出した: #{@repository.path}" }
        return [] of ValidationError
      end

      root = @repository.load
      errors = validate(root)
      if errors.empty?
        @current = root
        @readable = true
        @on_apply.call(@current)
      else
        @readable = false
        Log.error { "設定の検証に失敗したため初期設定で起動する: #{errors.join(" / ")}" }
      end
      errors
    rescue ex : JSON::Error | File::Error
      @readable = false
      Log.error(exception: ex) { "設定ファイルを読めなかったため初期設定で起動する" }
      [ValidationError.new("全般", "設定ファイルを読めなかった: #{ex.message}")]
    end

    # 手動編集後の取り込み（トレイメニューの「設定を再読み込み」）。
    # 不正な JSON を読んだ場合は直前の有効な設定で動作を続ける（仕様書 5 章）。
    def reload : Array(ValidationError)
      root = @repository.load
      errors = validate(root)
      if errors.empty?
        @current = root
        @readable = true
        @on_apply.call(@current)
        Log.info { "設定を再読み込みした" }
      else
        @readable = false
        Log.error { "再読み込みした設定が不正なため直前の設定を維持する: #{errors.join(" / ")}" }
      end
      errors
    rescue ex : JSON::Error | File::Error
      @readable = false
      Log.error(exception: ex) { "設定ファイルを読めなかったため直前の設定を維持する" }
      [ValidationError.new("全般", "設定ファイルを読めなかった: #{ex.message}")]
    end

    # 保存は全項目が有効なときだけ行う。
    # 保存が通ったときだけスナップショットを差し替えるため、検証エラーは現在の動作に影響しない。
    #
    # 設定ファイルを読めていない間は、書き出さずに反映だけを行う。
    # このとき current は既定値であり、書き戻すと利用者のルールごとファイルを失う。
    # 読めなかったファイルはそのまま残してあり、利用者が直せる状態にしておく必要がある。
    #
    # overwrite_unreadable は、利用者が設定画面で全項目を確かめて保存したときに真にする。
    # 壊れたファイルを画面から直す操作そのものなので、ここは書き出さなければならない。
    def save(root : Root, overwrite_unreadable : Bool = false) : Array(ValidationError)
      errors = validate(root)
      return errors unless errors.empty?

      if @readable || overwrite_unreadable
        @repository.save(root)
        @readable = true
        Log.info { "設定を保存した" }
      else
        Log.warn { "設定ファイルを読めていないため、書き出さずに反映だけを行う: #{@repository.path}" }
      end

      @current = root
      @on_apply.call(@current)
      errors
    end

    def validate(root : Root) : Array(ValidationError)
      errors = [] of ValidationError
      validate_sinks(root, errors)
      validate_sources(root, errors)
      validate_settings("既定の通知設定", root.defaults.to_resolved, errors)
      validate_rules(root, errors)
      validate_general(root, errors)
      errors
    end

    # 有効な通知先を数えるとき、検証を登録していないキーは数に入れない。
    # 検証を登録しているのは composition root が組み立てられるシンクだけであり、
    # 将来用の未知のキーを数に入れると、実際には送信先が無い設定を通してしまうためである。
    private def validate_sinks(root : Root, errors : Array(ValidationError)) : Nil
      buildable = root.sinks.select { |id, _| @section_validators.has_key?("sinks.#{id}") }
      enabled = buildable.count { |_, section| section["enabled"]?.try(&.as_bool?) != false }
      if enabled.zero?
        errors << ValidationError.new("通知先", "有効な通知先が 1 つも無い")
      end

      root.sinks.each_key do |id|
        run_section_validator("sinks.#{id}", "通知先", root.sink(id), errors)
      end
    end

    private def validate_sources(root : Root, errors : Array(ValidationError)) : Nil
      root.sources.each_key do |id|
        run_section_validator("sources.#{id}", "監視対象", root.source(id), errors)
      end
    end

    private def run_section_validator(
      key : String,
      tab : String,
      section : JSON::Any?,
      errors : Array(ValidationError),
    ) : Nil
      validator = @section_validators[key]?
      return unless validator
      validator.call(section).each { |message| errors << ValidationError.new(tab, message) }
    end

    private def validate_rules(root : Root, errors : Array(ValidationError)) : Nil
      root.rules.each_with_index do |rule, index|
        label = "アプリ別ルール[#{index}]"
        if rule.match_app_id.empty?
          errors << ValidationError.new(label, "match_app_id が空である")
        end
        validate_settings(label, rule.resolve(root.defaults), errors)
      end
    end

    private def validate_general(root : Root, errors : Array(ValidationError)) : Nil
      unless LOG_LEVELS.includes?(root.log_level)
        errors << ValidationError.new("全般", "log_level は #{LOG_LEVELS.join(" / ")} のいずれかで指定する")
      end
    end

    # defaults とルール解決後の値に共通する数値範囲とファイル存在の検証。
    private def validate_settings(label : String, settings : Resolved, errors : Array(ValidationError)) : Nil
      unless (0.0..1.0).includes?(settings.opacity)
        errors << ValidationError.new(label, "opacity は 0.0 から 1.0 の範囲で指定する")
      end
      unless (0.0..1.0).includes?(settings.volume)
        errors << ValidationError.new(label, "volume は 0.0 から 1.0 の範囲で指定する")
      end
      unless positive_finite?(settings.timeout)
        errors << ValidationError.new(label, "timeout は 0 より大きい有限の値で指定する")
      end
      unless MAX_BODY_LENGTH_RANGE.includes?(settings.max_body_length)
        errors << ValidationError.new(
          label,
          "max_body_length は #{MAX_BODY_LENGTH_RANGE.begin} から #{MAX_BODY_LENGTH_RANGE.end} の範囲で指定する",
        )
      end

      dynamic = settings.dynamic_timeout
      unless positive_finite?(dynamic.reading_speed)
        errors << ValidationError.new(label, "dynamic_timeout.reading_speed は 0 より大きい有限の値で指定する")
      end
      unless dynamic.base.finite? && dynamic.base >= 0.0
        errors << ValidationError.new(label, "dynamic_timeout.base は 0 以上の有限の値で指定する")
      end
      # 上下限そのものが正でないと、動的表示時間が負の値へクランプされる。
      unless positive_finite?(dynamic.min)
        errors << ValidationError.new(label, "dynamic_timeout.min は 0 より大きい有限の値で指定する")
      end
      unless positive_finite?(dynamic.max)
        errors << ValidationError.new(label, "dynamic_timeout.max は 0 より大きい有限の値で指定する")
      end
      if dynamic.min > dynamic.max
        errors << ValidationError.new(label, "dynamic_timeout.min は max 以下で指定する")
      end

      validate_icon(label, settings.icon, errors)
      validate_sound(label, settings.sound, errors)
    end

    # 大小の比較だけでは NaN を弾けない。
    # NaN はどの比較でも偽になるため、範囲を外れているとみなされずに検証を通ってしまう。
    # NaN や無限大が混ざると、表示時間が解釈できないまま送られるか、
    # 設定の JSON 書き出しで例外になる。
    private def positive_finite?(value : Float64) : Bool
      value.finite? && value > 0.0
    end

    private def validate_icon(label : String, icon : String, errors : Array(ValidationError)) : Nil
      return if icon == "app" || BUILTIN_ICONS.includes?(icon)

      unless @repository.file_exists?(icon)
        errors << ValidationError.new(label, "icon のファイルが見つからない: #{icon}")
        return
      end

      # 内容まで確かめる。PNG 以外を通すと、シンクへは base64 化した中身がそのまま渡り、
      # 表示できないアイコンとして送られる。
      return if @repository.png_file?(icon)
      errors << ValidationError.new(label, "icon のファイルが PNG ではない: #{icon}")
    end

    private def validate_sound(label : String, sound : String, errors : Array(ValidationError)) : Nil
      # 空文字列はミュートを表す（仕様書 4.3 節 手順 7）。
      return if sound.empty? || BUILTIN_SOUNDS.includes?(sound)
      return if @repository.file_exists?(sound)
      errors << ValidationError.new(label, "sound のファイルが見つからない: #{sound}")
    end
  end
end

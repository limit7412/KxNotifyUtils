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

    BUILTIN_ICONS   = %w[default warning error]
    BUILTIN_SOUNDS  = %w[default warning error]
    LOG_LEVELS      = %w[trace debug info notice warn error fatal none]
    LANGUAGES       = %w[auto ja en]
    UPDATE_CHANNELS = %w[stable test]

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
      # 最後に読み込むか書き出した時点の更新時刻。
      # current がディスクの中身と一致しているかの判断に使う（issue #15）。
      @synced_at = nil.as(Time?)
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
        @synced_at = @repository.modified_at
        Log.info { "初期設定を書き出した: #{@repository.path}" }
        return [] of ValidationError
      end

      root = @repository.load
      errors = validate(root)
      if errors.empty?
        @current = root
        @readable = true
        @synced_at = @repository.modified_at
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
        @synced_at = @repository.modified_at
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
        @synced_at = @repository.modified_at
        Log.info { "設定を保存した" }
      else
        Log.warn { "設定ファイルを読めていないため、書き出さずに反映だけを行う: #{@repository.path}" }
      end

      @current = root
      @on_apply.call(@current)
      errors
    end

    # アプリ自身が書き込む記録だけを書き戻す（issue #15）。
    #
    # 利用者が設定画面から保存する save とは分けてある。
    # あちらは全項目を画面で確かめたうえでの明示的な上書きであり、外部変更の警告も出す。
    # こちらは SteamVR の同期や更新の確認から、利用者の操作を伴わずに走る。
    # 読み込みから書き戻しまでの間に手で編集されていると、
    # メモリ上のスナップショットで全体を置き換えて、その編集を警告なしに失う。
    #
    # 渡すブロックは、書き戻す元になる設定を受け取って、記録を載せ替えたものを返す。
    # 記録がディスクへ書けたかを返す。書けなかった場合、呼び出し側は次の機会に呼び直せる。
    #
    # 記録そのものは、書けたかどうかに関わらず動作へ反映する。
    # 反映しないと、たとえば自動起動の登録が決着しないままになり、
    # 再試行の条件が成立し続けて 60 秒ごとに登録し直すことになる。
    def record(& : Root -> Root) : Bool
      # 読めていない設定へは書き出さない。save と同じ理由である。
      # current は既定値であり、書き戻すと利用者のルールごとファイルを失う。
      unless @readable
        Log.warn { "設定ファイルを読めていないため、書き出さずに反映だけを行う: #{@repository.path}" }
        apply_record(yield @current)
        return false
      end

      before, base, reflect = base_for_record
      unless base
        apply_record(yield @current)
        return false
      end

      root = yield base
      errors = validate(root)
      unless errors.empty?
        # 読み直した設定が検証を通らない。記録だけを載せて書き戻すと、
        # 利用者が直している途中のファイルを不正なまま固定してしまう。
        Log.warn { "書き戻す元の設定が検証を通らないため記録の書き戻しを見送る: #{errors.join(" / ")}" }
        apply_record(yield @current)
        return false
      end

      # 読んでから書くまでの間にもう一度編集されていないかを見る。
      # ここで防げるのは読み取りと書き出しの隙間だけであり、
      # 書き出しそのものと同時の編集は防げない。それでも、
      # この record が守ろうとしている手編集の消失を、同じ処理の中で
      # 起こさないだけの意味はある。
      if changed_since?(before)
        Log.warn { "書き出す直前に設定ファイルが変更されたため記録の書き戻しを見送る: #{@repository.path}" }
        apply_record(yield @current)
        return false
      end

      @repository.save(root)

      # 外部の編集を読み直して書いた場合、その内容は動作へ反映しない。
      # 利用者が「設定を再読み込み」を押す前に、編集の途中のものへ勝手に切り替わるのを避ける。
      # 記録はディスクへ残っているので、次の読み込みで揃う。
      #
      # このとき synced_at も進めない。
      # あれは「current がディスクと一致していた時点」を指すものであり、
      # 反映しないまま進めると、次の record が古い current を基準にして、
      # ここで守った手編集を結局は上書きしてしまう。
      unless reflect
        # 読み直した設定は反映しないが、記録だけは current へ載せる。
        # 落とすと登録が決着せず、再試行が止まらない。
        apply_record(yield @current)
        return true
      end

      @synced_at = @repository.modified_at
      apply_record(root)
      true
    end

    # 読み取りの時点から設定ファイルが変わっているか。
    # どちらかの更新時刻を取れない場合は、変わっていないものとして進める。
    # 取れないことを理由に書き戻しを止めると、更新時刻を持たない環境で
    # 記録が一度も残らなくなる。
    private def changed_since?(before : Time?) : Bool
      return false unless before

      now = @repository.modified_at
      return false unless now

      now != before
    end

    private def apply_record(root : Root) : Nil
      errors = validate(root)
      unless errors.empty?
        Log.warn { "記録を載せた設定が検証を通らないため反映しない: #{errors.join(" / ")}" }
        return
      end

      @current = root
      @on_apply.call(@current)
    end

    # 読み取りの時点の更新時刻と、書き戻す元になる設定と、
    # 読み直した設定を動作へ反映してよいかを返す。
    #
    # 更新時刻が変わっていなければ current がディスクと一致しているので、そのまま使う。
    # 変わっていれば読み直す。読み直せない場合は書き込みそのものを見送る。
    private def base_for_record : {Time?, Root?, Bool}
      modified = @repository.modified_at
      return {modified, @current, true} if modified && modified == @synced_at

      Log.info { "設定ファイルが外部で変更されているため読み直してから記録する: #{@repository.path}" }
      {modified, @repository.load, false}
    rescue ex : JSON::Error | File::Error
      # 読み直せないものへ記録を載せることはできない。
      # 全体を上書きすれば書けるが、それでは外部の編集を失う。
      Log.warn(exception: ex) { "設定ファイルを読み直せなかったため記録の書き戻しを見送る" }
      {nil, nil, false}
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
      # オブジェクトでないセクションは有効として数える。
      # 書式そのものの誤りは各アダプタの検証がエラーにするので、
      # ここで「有効な通知先が無い」と重ねて言う必要はない。
      # なお as_h? を挟まず添字を引くと、null や配列を書かれたときに例外で落ちる。
      enabled = buildable.count do |_, section|
        section.as_h?.try(&.["enabled"]?).try(&.as_bool?) != false
      end
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
      unless LANGUAGES.includes?(root.language)
        errors << ValidationError.new("全般", "language は #{LANGUAGES.join(" / ")} のいずれかで指定する")
      end
      unless UPDATE_CHANNELS.includes?(root.update.channel)
        errors << ValidationError.new(
          "全般",
          "update.channel は #{UPDATE_CHANNELS.join(" / ")} のいずれかで指定する",
        )
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

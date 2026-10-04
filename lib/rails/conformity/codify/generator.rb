require "erb"
require "fileutils"

module Rails
  module Conformity
    module Codify
      # Extracts a repeated pattern into a Rails generator.
      #
      # A pattern family is a set of members sharing one skeleton. A member may
      # span several roles (e.g. app/services/route_alert.rb plus
      # spec/services/route_alert_spec.rb). Family members are grouped per
      # directory, so a namespace module wrapper stays constant across the
      # family and is carried into the template verbatim.
      #
      # Optionally, registration in a factory/registry file is codified too:
      # the line each member contributes is extracted as an ERB template and
      # the generated generator appends it after the first registered member.
      class Generator
        attr_reader :app_root, :files, :roles, :role_templates, :role_instances, :registration

        def initialize(app_root, files, register: nil)
          @app_root = app_root
          @files = files
          @register = register
          @roles = {}
          @role_templates = {}
          @role_instances = {}
          @registration = nil
        end

        # Directories scanned for repeated structural families. Grouping itself
        # is per directory, so a family never spans different folders.
        FAMILY_DIRS = %w[app/services app/models app/jobs app/controllers].freeze
        BASE_FILES = %w[application.rb application_job.rb application_record.rb
                        application_controller.rb application_cable.rb connection.rb
                        channel.rb application_helper.rb application_mailer.rb].freeze

        def self.family_files(app_root)
          FAMILY_DIRS.flat_map { |dir| Dir.glob(File.join(app_root, dir, "**", "*.rb")) }
                     .reject { |path| BASE_FILES.include?(File.basename(path)) }
                     .reject { |path| path.include?(File.join("app", "controllers", "concerns")) }
        end

        def self.patterns(app_root, files: nil)
          primary = files || family_files(app_root)
          relative = primary.map { |path| path.delete_prefix("#{app_root}/") }
          relative.group_by { |file| [File.dirname(file), family_digest(File.read(File.join(app_root, file)))] }
                  .values.filter_map do |group|
            next nil if group.size < 2

            generator = nil
            begin
              generator = new(app_root, group.map { |path| path.delete_prefix("#{app_root}/") })
              next nil unless generator.extract && generator.round_trip?
            rescue StandardError, ScriptError
              next nil
            end

            generator.files
          end
        end

        # Loose digest for candidate grouping: normalize identifiers and
        # literals. Exact token-diff extraction plus the round-trip test (the
        # real judge) decides whether a group is actually codifiable.
        KEYWORDS = %w[class module def end require do if unless else elsif when case
                      while until rescue ensure return yield self then and or not in
                      begin lambda proc freeze].freeze

        def self.family_digest(source)
          source.gsub(/^\s*#.*\n?/, "")
                .gsub(/'[^']*'|"[^"]*"/, "STR")
                .gsub(/[A-Z][a-zA-Z0-9]*/, "CAP")
                .gsub(/\d+/, "NUM")
                .gsub(/[a-z_][a-z0-9_]*[?!=]?/) { |word| KEYWORDS.include?(word) ? word : "ID" }
        end

        def self.skeleton(source)
          source.gsub(/[A-Z][a-zA-Z0-9]*/, "CAP").gsub(/"[^"]*"/, "STR").gsub(/\d+/, "NUM")
        end

        # Primary-role template (backwards-compatible single-file view).
        def template_source
          @role_templates["service"]
        end

        # Service-role instances keyed by primary file (backwards-compatible).
        def instances
          @role_instances["service"] || {}
        end

        def extract
          @roles = { "service" => files.dup }
          tests = files.map { |file| related_test(file) }.compact
          role_name = test_role_name(tests)
          if tests.size >= 2 && role_name && skeletons_match(tests)
            @roles[role_name] = tests
          end

          ok = @roles.all? { |role, role_files| extract_role(role, role_files) }
          return false unless ok

          @registration = @register ? Registration.new(app_root, @register, files, common_class_suffix) : nil
          @registration.nil? || (@registration.extract && @registration.round_trip?)
        end

        def round_trip?
          return false if @role_templates.value?(nil)

          @roles.all? do |role, role_files|
            role_files.all? do |file|
              ERB.new(@role_templates[role]).result_with_hash(@role_instances[role][file]) ==
                File.read(File.join(app_root, file))
            end
          end
        end

        def generator_name
          common_class_suffix.underscore
        end

        def write_generator(name:)
          gen_dir = File.join(app_root, "lib", "generators", "team", name.underscore)
          FileUtils.mkdir_p(File.join(gen_dir, "templates"))

          written = []
          @roles.each do |role, _|
            path = File.join(gen_dir, "templates", "#{name.underscore}#{role == "service" ? "" : "_#{role}"}.rb.tt")
            File.write(path, @role_templates[role])
            written << path
          end
          gen_path = File.join(gen_dir, "#{name.underscore}_generator.rb")
          File.write(gen_path, generator_source(name))
          FileUtils.chmod(0o755, gen_path)
          written << gen_path
        end

        private

        def extract_role(role, role_files)
          source = File.read(File.join(app_root, role_files.first))
          base_lines = source.lines
          member_lines = role_files.map { |f| File.read(File.join(app_root, f)).lines }
          slots = (0...base_lines.length).select { |idx| member_lines.any? { |ml| ml[idx] != base_lines[idx] } }
          specs = slots.map { |idx| [idx, line_slot_spec(idx, base_lines, member_lines, role)] }.to_h

          # Pass 1: best-effort template. Pass 2: force any line that still
          # renders wrong to a whole-line slot (round-trip guaranteed).
          2.times do
            template = build_line_template(source, specs)
            bad = (0...base_lines.length).select do |idx|
              member_lines.each_with_index.any? do |ml, i|
                next false if ml[idx].nil? && idx >= ml.length && idx != 0 && false
                rendered = render_lines(template, locals_for(member_lines[i], specs.to_a, i))
                rendered.nil? || rendered[idx] != ml[idx]
              end
            end & slots
            specs = specs.map do |idx, spec|
              if bad.include?(idx) && spec[:kind] != :verbatim
                [idx, { kind: :verbatim, local: next_local!(role), force: true }]
              else
                [idx, spec]
              end
            end.to_h
          end

          template = build_line_template(source, specs)
          ok = role_files.each_with_index.all? do |file, i|
            rendered = render_lines(template, locals_for(member_lines[i], specs.to_a, i))
            rendered && rendered == File.read(File.join(app_root, file)).lines && rendered.join == File.read(File.join(app_root, file))
          end
          @role_templates[role] = template if ok
          @role_instances[role] ||= {}
          role_files.each_with_index do |file, i|
            @role_instances[role][file] = locals_for(member_lines[i], specs.to_a, i)
          end
          ok
        end

        # Per-family test-role files: rspec (spec/**/*_spec.rb) or Minitest
        # (test/**/*_test.rb), whichever the members consistently have. Mixed
        # kinds across members never become a role.
        def related_test(file)
          stem = File.basename(file, ".rb")
          spec = Dir.glob(File.join(app_root, "spec", "**", "#{stem}_spec.rb")).first
          return spec.delete_prefix("#{app_root}/") if spec

          test = Dir.glob(File.join(app_root, "test", "**", "#{stem}_test.rb")).first
          test&.delete_prefix("#{app_root}/")
        end

        def test_role_name(test_files)
          prefixes = test_files.map { |path| File.dirname(path).split("/").first }.uniq
          return nil unless prefixes.size == 1
          return nil unless %w[spec test].include?(prefixes.first)

          prefixes.first
        end

        def skeletons_match(test_files)
          digests = test_files.map { |path| self.class.family_digest(File.read(File.join(app_root, path))) }
          digests.uniq.size == 1
        end

        def tokens(relative)
          File.read(File.join(app_root, relative)).split
        end

        def member_class(i)
          File.basename(files[i], ".rb").camelize
        end

        def common_class_suffix
          @common_class_suffix ||= begin
            names = files.map { |file| File.basename(file, ".rb").camelize }
            first = names.first
            suffix = +""
            (1..first.length).each do |length|
              candidate = first[-length, length]
              break unless names.all? { |name| name.end_with?(candidate) }

              suffix.replace(candidate)
            end
            suffix
          end
        end

        SAFE_CLASS = "\x01"
        SAFE_SNAKE = "\x02"

        def snake_stem_for(i)
          File.basename(files[i], ".rb").delete_suffix("_#{common_class_suffix.underscore}")
        end

        def next_local!(role)
          @local_counter ||= {}
          n = (@local_counter[role] ||= 0) + 1
          @local_counter[role] = n
          role == "service" ? :"v#{n}" : :"#{role}_v#{n}"
        end

        # Classify one differing line:
        # - :class_name / :snake_stem — name differences only, templatable.
        # - :tokens — names plus per-member content; token-level slots.
        # - :verbatim — anything else, whole-line slot (default = member 0).
        def line_slot_spec(idx, base_lines, member_lines, role)
          base = base_lines[idx]
          lines = member_lines.map { |ml| ml[idx] }
          anon = lines.each_with_index.map do |line, i|
            res = line.to_s.gsub(member_class(i), SAFE_CLASS)
            res.gsub(snake_stem_for(i), SAFE_SNAKE)
          end
          return { kind: :class_name } if anon.uniq.size == 1 && anon[0].include?(SAFE_CLASS)
          return { kind: :snake_stem } if anon.uniq.size == 1 && anon[0].include?(SAFE_SNAKE)

          toks = anon.map(&:split)
          if toks.all? { |t| t.size == toks[0].size }
            base_toks = toks[0]
            out = base_toks.dup
            indent = base[/\A\s*/] || ""
            value_map = {}
            differing = false
            (0...base_toks.size).each do |j|
              next unless toks.any? { |t| t[j] != base_toks[j] }

              differing = true
              tok = base_toks[j]
              out[j] = if tok.include?(SAFE_CLASS)
                tok.gsub(SAFE_CLASS, "<%= class_name %>#{common_class_suffix}").gsub(SAFE_SNAKE, "<%= snake_stem %>")
              elsif tok.include?(SAFE_SNAKE)
                tok.gsub(SAFE_SNAKE, "<%= snake_stem %>")
              else
                name = next_local!(role)
                value_map[j] = name
                "<%= #{name} %>"
              end
            end
            if differing
              return { kind: :tokens, template: indent + out.join(" "), value_map: value_map }
            end
          end
          { kind: :verbatim, local: next_local!(role) }
        end

        def build_line_template(source, specs)
          result = source.lines.dup
          specs.each do |idx, spec|
            line = source.lines[idx]
            result[idx] = case spec[:kind]
            when :class_name
              stem = member_class(0).delete_suffix(common_class_suffix)
              line.gsub(member_class(0), "<%= class_name %>#{common_class_suffix}")
                  .gsub(/#{stem}(?![a-z_])/, "<%= class_name %>")
            when :snake_stem
              line.gsub(/#{Regexp.escape(snake_stem_for(0))}(?![a-z_])/, "<%= snake_stem %>")
            when :tokens
              spec[:template]
            else
              "<%= #{spec[:local]} %>"
            end
          end
          result.join
        end

        def render_lines(template_source, instance)
          ERB.new(template_source).result_with_hash(instance).lines
        rescue StandardError, ScriptError
          nil
        end

        def locals_for(lines, specs, i)
          locals = {
            class_name: member_class(i).delete_suffix(common_class_suffix),
            snake_stem: snake_stem_for(i)
          }
          specs.each do |idx, spec|
            line = lines[idx]
            next if line.nil?

            case spec[:kind]
            when :verbatim
              locals[spec[:local]] = line
            when :tokens
              toks = line.split
              spec[:value_map].each { |j, name| locals[name] = toks[j] }
            end
          end
          locals
        end

        def generator_source(name)
          # Quote for emitted Ruby: single-quoted when no interpolation or
          # escapes are needed (RuboCop's default Style/StringLiterals).
          ruby_string = lambda do |value|
            if value.include?('#{') || value.include?('\\') || value.include?("\n")
              value.inspect
            else
              "'#{value.gsub("'", %q(\\'))}'"
            end
          end

          # Multi-line option defaults emit as chunks joined at runtime so the
          # emitted source stays under the 120-char LineLength default.
          ruby_default = lambda do |value|
            if value.include?("\n")
              pieces = value.scan(/.{1,60}/m)
              "[\n" + pieces.map { |piece| "      " + piece.inspect }.join(",\n") + "\n    ].join"
            else
              ruby_string.call(value)
            end
          end

          dest_lines = @roles.keys.map do |role|
            dir, base = File.split(dest_for(role))
            base = base.sub("<<FP>>", '#{file_path}')
            template_name = name.underscore + (role == "service" ? "" : "_#{role}") + ".rb.tt"
            "      template " + ruby_string.call(template_name) +
              ", File.join(" + ruby_string.call(dir) + ", \"" + base + "\")"
          end

          lines = []
          lines << "# frozen_string_literal: true"
          lines << ""
          lines << "require 'erb'" << ""
          lines << "module Team"
          lines << "  # Generates family members from the codified team template."
          lines << "  class #{name.camelize}Generator < Rails::Generators::NamedBase"
          lines << "    source_root File.expand_path('templates', __dir__)" << ""
          all_slot_locals = (@role_instances || {}).sort.map { |_role, instances| (instances&.first&.last || {}) }
          all_slot_locals.each do |locals|
            locals.each do |key, value|
              next if key == :class_name || key == :snake_stem

              lines << "    class_option :#{key}, type: :string, default: #{ruby_default.call(value)}"
            end
          end
          lines << "" << "    def create_#{name.underscore}"
          lines.concat(dest_lines)
          lines << "" << "      register_member" if @registration
          lines << "    end" << ""
          all_slot_locals.each do |locals|
            locals.each_key do |key|
              next if key == :class_name || key == :snake_stem

              lines << "    def #{key} = options[:#{key}]"
            end
          end
          if @registration
            lines << ""
            lines << "    def register_member"
            lines << "      path = #{ruby_string.call(@registration.path)}"
            lines << "      lines = File.readlines(path)"
            lines << "      index = lines.index { |line| line.include?(#{ruby_string.call(@registration.anchor)}) }"
            lines << "      abort 'conformity: registration anchor missing in #{@registration.path}' unless index"
            lines << "      lines.insert(index + 1, ERB.new(#{ruby_string.call(@registration.line_template)}).result(binding))"
            lines << "      File.write(path, lines.join)"
            lines << "    end" << ""
            lines << "    def klass = \"\#{class_name}#{common_class_suffix}\""
            lines << ""
            lines << "    def stem = \"\#{file_name}_#{common_class_suffix.underscore}\""
            lines << ""
            lines << "    def snake_name = file_name"
          end
          lines << "  end" << "end"

          lines.join("\n") + "\n"
        end
        def dest_for(role)
          base_stem = File.basename(files.first, ".rb")
          @roles[role].first.gsub(base_stem, "<<FP>>_#{common_class_suffix.underscore}")
        end

        def indented(text)
          return text if text.empty?

          text.lines.map { |line| line.strip.empty? ? line : "  #{line}" }.join
        end
      end

      # Codifies how a family member registers itself in a factory/registry
      # file. The registration line of each member is extracted into an ERB
      # template; the round-trip test must reproduce every member's line.
      class Registration
        attr_reader :path, :anchor, :line_template

        def initialize(app_root, path, members, suffix)
          @app_root = app_root
          @path = path
          @members = members
          @suffix = suffix
          @lines = []
          @member_lines = []
        end

        def extract
          @lines = File.readlines(absolute)
          @member_lines = (0...@members.size).map { |i| @lines.find { |line| line.include?(member_values(i)[:klass]) } }
          return false if @member_lines.any?(&:nil?)

          @anchor = member_values(0)[:klass]
          @line_template = templatize(@member_lines[0], member_values(0))
          true
        end

        def round_trip?
          return false unless @line_template

          # Trailing commas are structural, not per-member: compare without them.
          (0...@members.size).all? do |i|
            values = member_values(i)
            rendered = ERB.new(@line_template).result_with_hash(values).sub(/,\n\z/, "\n")
            rendered == @member_lines[i].sub(/,\n\z/, "\n")
          end
        end

        def render(klass, stem, snake_name)
          ERB.new(@line_template).result_with_hash({ klass: klass, stem: stem, snake_name: snake_name })
        end

        private

        def absolute
          File.join(@app_root, @path)
        end

        def member_values(i)
          stem = File.basename(@members[i], ".rb")
          {
            klass: stem.camelize,
            stem: stem,
            snake_name: stem.delete_suffix("_#{@suffix.underscore}")
          }
        end

        def templatize(line, values)
          line
            .gsub(values[:klass], "<%= klass %>")
            .gsub(values[:stem], "<%= stem %>")
            .gsub(values[:snake_name], "<%= snake_name %>")
        end
      end
    end
  end
end

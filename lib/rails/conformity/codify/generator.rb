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
                .gsub(/[A-Z][a-zA-Z0-9]*/, "CAP")
                .gsub(/"[^"]*"/, "STR")
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
          specs = files.map { |file| related_spec(file) }
          if specs.compact.size >= 2 && skeletons_match(specs.compact)
            @roles["spec"] = specs.compact
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
          slots = []
          role_files.each do |file|
            File.read(File.join(app_root, file)).lines.each_with_index do |line, idx|
              next unless idx < base_lines.length
              slots << idx if line != base_lines[idx] && !slots.include?(idx)
            end
          end
          slots.sort!

          locals_map = slots_local_map(base_lines, slots)
          @role_templates[role] = build_line_template(source, base_lines, slots, locals_map)
          @role_instances[role] ||= {}
          role_files.each_with_index do |file, i|
            @role_instances[role][file] = locals_for(role_files, i, slots, locals_map)
          end
          true
        end

        def related_spec(file)
          stem = File.basename(file, ".rb")
          hit = Dir.glob(File.join(app_root, "spec", "**", "#{stem}_spec.rb")).first
          hit&.delete_prefix("#{app_root}/")
        end

        def skeletons_match(spec_files)
          skeletons = spec_files.map { |path| self.class.skeleton(File.read(File.join(app_root, path))) }
          skeletons.uniq.size == 1
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

        def slots_local_map(base_lines, slots)
          snake_stem = File.basename(files.first, ".rb").delete_suffix("_#{common_class_suffix.underscore}")
          base_lines.each_with_index.with_object({}) do |(line, idx), map|
            next unless slots.include?(idx)

            map[idx] = if line.include?(member_class(0))
              :class_name
            elsif snake_stem != "" && line.include?(snake_stem)
              :snake_stem
            else
              :"v#{map.values.count { |v| v.to_s.start_with?("v") } + 1}"
            end
          end
        end

        # Line-level slots: a differing line is replaced whole. Name-aware
        # lines keep templatable names (class name, snake stem) so generated
        # members inherit correct naming; every other differing line becomes
        # a verbatim slot (default = first member, overridable via options).
        def build_line_template(source, base_lines, slots, locals_map)
          snake_stem = File.basename(files.first, ".rb").delete_suffix("_#{common_class_suffix.underscore}")
          result = base_lines.dup
          slots.each do |idx|
            line = base_lines[idx]
            result[idx] = case locals_map[idx]
            when :class_name
              line = line.gsub(member_class(0), "<%= class_name %>#{common_class_suffix}")
              stem = member_class(0).delete_suffix(common_class_suffix)
              line.gsub(/#{stem}(?![a-z_])/, "<%= class_name %>")
            when :snake_stem
              line.gsub(/#{snake_stem}(?![a-z_])/, "<%= snake_stem %>")
            else
              # Verbatim slot: the stored line carries its own newline.
              "<%= #{locals_map[idx]} %>"
            end
          end
          result.join
        end

        def locals_for(role_files, i, slots, locals_map)
          lines = File.read(File.join(app_root, role_files[i])).lines
          locals = {
            class_name: member_class(i).delete_suffix(common_class_suffix),
            snake_stem: File.basename(files[i], ".rb").delete_suffix("_#{common_class_suffix.underscore}")
          }
          lines.each_with_index do |line, idx|
            next unless slots.include?(idx) && locals_map[idx].to_s.start_with?("v")

            locals[locals_map[idx]] = line
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
          (@role_instances["service"]&.first&.last || {}).each do |key, value|
            next if key == :class_name || key == :snake_stem

            lines << "    class_option :#{key}, type: :string, default: #{ruby_string.call(value)}"
          end
          lines << "" << "    def create_#{name.underscore}"
          lines.concat(dest_lines)
          lines << "" << "      register_member" if @registration
          lines << "    end" << ""
          (@role_instances["service"]&.first&.last || {}).each_key do |key|
            next if key == :class_name || key == :snake_stem

            lines << "    def #{key} = options[:#{key}]"
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

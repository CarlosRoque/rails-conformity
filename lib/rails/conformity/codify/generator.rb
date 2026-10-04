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

        def self.patterns(app_root, files: nil)
          primary = files || Dir.glob(File.join(app_root, "app", "services", "**", "*.rb"))
          relative = primary.map { |path| path.delete_prefix("#{app_root}/") }
          relative.group_by { |file| [File.dirname(file), skeleton(File.read(File.join(app_root, file)))] }
                  .values.select { |group| group.size >= 2 }
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
          base = File.read(File.join(app_root, role_files.first)).split
          slots = []
          role_files.each do |file|
            File.read(File.join(app_root, file)).split.each_with_index do |token, slot|
              next unless slot < base.length
              slots << slot if token != base[slot] && !slots.include?(slot)
            end
          end
          slots.sort!

          locals_map = slots_to_locals(base, slots)
          @role_templates[role] = build_template(File.read(File.join(app_root, role_files.first)), base, slots, locals_map)
          @role_instances[role] ||= {}
          role_files.each_with_index do |file, i|
            @role_instances[role][file] = locals_for(role_files, i, base, slots, locals_map)
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

        def slots_to_locals(base, slots)
          base.each_with_index.with_object({}) do |(token, slot), map|
            next unless slots.include?(slot)

            bare = token.delete_prefix('"')
            if bare.start_with?(member_class(0)) || bare == member_class(0).delete_suffix(common_class_suffix)
              map[slot] = :class_name
            else
              map[slot] = :"v#{map.values.count { |v| v.to_s.start_with?("v") } + 1}"
            end
          end
        end

        def build_template(source, base, slots, locals_map)
          base.each_with_index do |token, slot|
            next unless slots.include?(slot)

            source = if locals_map[slot] == :class_name
              prefix = token[/\A[^A-Za-z0-9]*/] || ""
              suffix = token[/[^A-Za-z0-9]\z\z/] || ""
              core = token.delete_prefix(prefix).delete_suffix(suffix)
              if core == member_class(0).delete_suffix(common_class_suffix)
                replacement = "#{prefix}<%= class_name %>#{suffix}"
              else
                extra = core.delete_prefix(member_class(0))
                replacement = "#{prefix}<%= class_name %>#{common_class_suffix}#{extra}#{suffix}"
              end
              source.gsub(token, replacement)
            else
              # v-slots carry the whole token verbatim.
              source.gsub(token, "<%= #{locals_map[slot]} %>")
            end
          end
          source
        end

        def locals_for(role_files, i, base, slots, locals_map)
          role_tokens = File.read(File.join(app_root, role_files[i])).split
          locals = { class_name: member_class(i).delete_suffix(common_class_suffix) }
          role_tokens.each_with_index do |token, slot|
            next unless slots.include?(slot) && locals_map[slot] != :class_name

            locals[locals_map[slot]] = token
          end
          locals
        end

        def generator_source(name)
          suffix = common_class_suffix
          suffix_snake = suffix.underscore
          dest_lines = @roles.keys.map do |role|
            dir, base = File.split(dest_for(role))
            base = base.sub("<<FP>>", '#{file_path}')
            "        template \"#{name.underscore}#{role == "service" ? "" : "_#{role}"}.rb.tt\", File.join(#{dir.inspect}, \"#{base}\")"
          end.join("\n")

          call_register = @registration ? "\n        register_member" : ""
          register_def = ""
          helper_defs = ""
          if @registration
            register_def = <<~RUBY
                  def register_member
                    path = #{@registration.path.inspect}
                    lines = File.readlines(path)
                    index = lines.index { |line| line.include?(#{@registration.anchor.inspect}) }
                    abort "conformity: registration anchor missing in #{@registration.path}" unless index
                    lines.insert(index + 1, ERB.new(#{@registration.line_template.inspect}).result(binding))
                    File.write(path, lines.join)
                  end
            RUBY
            helper_defs = <<~RUBY
                  def klass = "\#{class_name}#{suffix}"

                  def stem = "\#{file_name}_#{suffix_snake}"

                  def snake_name = file_name
            RUBY
          end

          # v-slots vary per member; expose each as an overridable class_option
          # (default = first family member's value) so the generated generator
          # runs non-interactively and slots stay correctable per invocation.
          slot_defaults = (@role_instances["service"]&.first&.last || {}).reject { |k, _| k == :class_name }
          option_defs = slot_defaults.map do |key, value|
            "      class_option :#{key}, type: :string, default: #{value.inspect}"
          end.join("\n")
          method_defs = slot_defaults.keys.map do |key|
            "      def #{key} = options[:#{key}]"
          end.join("\n")
          option_defs = indented(option_defs)
          method_defs = indented(method_defs)
          register_def = indented(register_def)
          helper_defs = indented(helper_defs)

          <<~RUBY
            # frozen_string_literal: true

            require "erb"

            module Team
              class #{name.camelize}Generator < Rails::Generators::NamedBase
                source_root File.expand_path("templates", __dir__)
            #{option_defs}#{option_defs.empty? ? "" : "\n"}
                def create_#{name.underscore}
            #{dest_lines}#{call_register}
                end
            #{method_defs}#{method_defs.empty? ? "" : "\n"}#{register_def.chomp}#{register_def.empty? ? "" : "\n"}#{helper_defs.chomp}#{helper_defs.empty? ? "" : "\n"}
              end
            end
          RUBY
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

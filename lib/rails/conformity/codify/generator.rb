require "erb"
require "fileutils"

module Rails
  module Conformity
    module Codify
      class Generator
        attr_reader :app_root, :files, :instances, :template_source

        def initialize(app_root, files)
          @app_root = app_root
          @files = files
          @instances = {}
          @template_source = nil
          @slots = []
          @common_suffix = nil
          @slot_locals = {}
        end

        def self.patterns(app_root, files: nil)
          services = files || Dir.glob(File.join(app_root, "app", "services", "*.rb"))
          relative = services.map { |path| path.delete_prefix("#{app_root}/") }
          groups = relative.group_by { |file| skeleton(File.read(File.join(app_root, file))) }
          groups.values.select { |group| group.size >= 2 }
        end

        def self.skeleton(source)
          source.gsub(/[A-Z][a-zA-Z0-9]*/, "CAP").gsub(/"[^"]*"/, "STR").gsub(/\d+/, "NUM")
        end

        def generator_name
          common_class_suffix.underscore
        end

        def extract
          base = tokens(files.first)
          @common_suffix = common_class_suffix
          @slots = []
          files.each do |file|
            other = tokens(file)
            other.each_with_index do |token, slot|
              @slots << slot if slot < base.length && token != base[slot] && !@slots.include?(slot)
            end
          end
          @slots.sort!
          @slot_locals = slots_to_locals(base)
          @template_source = build_template(base)
          files.each { |file| @instances[file] = locals_for(file) }
          round_trip?
        end

        def round_trip?
          return false unless @template_source

          files.all? do |file|
            ERB.new(@template_source).result_with_hash(@instances[file]) == File.read(File.join(app_root, file))
          end
        end

        def write_generator(name:)
          gen_dir = File.join(app_root, "lib", "generators", "team", name.underscore)
          FileUtils.mkdir_p(File.join(gen_dir, "templates"))
          File.write(File.join(gen_dir, "templates", "#{name.underscore}.rb.tt"), @template_source)
          File.write(File.join(gen_dir, "#{name.underscore}_generator.rb"), generator_source(name))
          [File.join(gen_dir, "#{name.underscore}_generator.rb"), File.join(gen_dir, "templates", "#{name.underscore}.rb.tt")]
        end

        private

        def tokens(file)
          File.read(File.join(app_root, file)).split
        end

        def class_name_of(file)
          File.basename(file, ".rb").camelize
        end

        def common_class_suffix
          names = files.map { |file| class_name_of(file) }
          first = names.first
          suffix = +""
          (1..first.length).each do |length|
            candidate = first[-length, length]
            break unless names.all? { |name| name.end_with?(candidate) }

            suffix.replace(candidate)
          end
          suffix
        end

        def slots_to_locals(base)
          base.each_with_index.with_object({}) do |(token, slot), map|
            next unless @slots.include?(slot)

            bare = token.delete_prefix('"')
            if class_name_of(files.first).start_with?(bare) || bare == class_name_of(files.first).delete_suffix(@common_suffix)
              map[slot] = :class_name
            else
              map[slot] = :"v#{map.values.count { |v| v.to_s.start_with?("v") } + 1}"
            end
          end
        end

        def build_template(base)
          source = File.read(File.join(app_root, files.first))
          base.each_with_index do |token, slot|
            next unless @slots.include?(slot)

            prefix = token[/\A[^A-Za-z0-9]*/] || ""
            suffix = token[/[^A-Za-z0-9]\z\z/] || ""
            core = token.delete_prefix(prefix).delete_suffix(suffix)
            replacement = if @slot_locals[slot] == :class_name
              core_suffix = core == class_name_of(files.first) ? @common_suffix : ""
              "#{prefix}<%= class_name %>#{core_suffix}#{suffix}"
            else
              "#{prefix}<%= #{@slot_locals[slot]} %>#{suffix}"
            end
            source.gsub!(token, replacement) if source.include?(token)
          end
          source
        end

        def locals_for(file)
          class_name = class_name_of(file).delete_suffix(@common_suffix)
          locals = { class_name: class_name }
          tokens(file).each_with_index do |token, slot|
            next unless @slots.include?(slot) && @slot_locals[slot] != :class_name

            locals[@slot_locals[slot]] = token
          end
          locals
        end

        def generator_source(name)
          <<~'RUBY'.gsub("__NAME__", name.underscore).gsub("__KLASS__", name.camelize)
            # frozen_string_literal: true

            module Team
              class __KLASS__Generator < Rails::Generators::NamedBase
                source_root File.expand_path("templates", __dir__)

                def create___NAME__
                  template "__NAME__.rb.tt", File.join("app/services", "#{file_path}___NAME__.rb")
                end
              end
            end
          RUBY
        end
      end
    end
  end
end

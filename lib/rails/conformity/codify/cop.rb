require "json"
require "open3"
require "fileutils"
require "shellwords"

module Rails
  module Conformity
    module Codify
      class Cop
        attr_reader :app_root, :cop_name

        def initialize(app_root, cop_name)
          @app_root = app_root
          @cop_name = cop_name
        end

        def build(message:, restrict_on_send:, node_pattern:, severity: "error")
          dir = File.join(app_root, "lib", "rubocop", "cop", "convention")
          FileUtils.mkdir_p(dir)
          File.write(cop_path, <<~RUBY)
            # frozen_string_literal: true

            module RuboCop
              module Cop
                module Convention
                  class #{cop_name.camelize} < Base
                    MSG = #{message.inspect}

                    RESTRICT_ON_SEND = %i[ #{restrict_on_send.join(" ")} ].freeze

                    def_node_matcher :offending?, <<~PATTERN
                      #{node_pattern}
                    PATTERN

                    def on_send(node)
                      offending?(node) do |arg|
                        add_offense(node, message: format(MSG, sql: arg&.value || arg&.source))
                      end
                    end
                  end
                end
              end
            end
          RUBY
          inject_config(severity)
          cop_path
        end

        def corpus_test(positives:, negatives:)
          dir = Dir.mktmpdir("conformity-corpus")
          positive_files = positives.each_with_index.map { |code, i| write_corpus(dir, "positive_#{i}", code) }
          negative_files = negatives.each_with_index.map { |code, i| write_corpus(dir, "negative_#{i}", code) }

          stdout, _stderr, _status = Open3.capture3(
            "bundle", "exec", "rubocop",
            "--require", cop_path,
            "--only", "Convention/#{cop_name.camelize}",
            "--no-color", "--format", "json",
            *(positive_files + negative_files),
            chdir: app_root
          )
          json = JSON.parse(stdout) rescue {}
          files = json.fetch("files", [])
          by_file = files.to_h { |file| [file.fetch("path"), file.fetch("offenses").size] }

          missed = positive_files.count { |file| by_file[file].to_i.zero? }
          false_hits = negative_files.count { |file| by_file[file].to_i.positive? }
          passed = missed.zero? && false_hits.zero?

          { passed?: passed, missed: missed, false_hits: false_hits,
            detail: { positives: positives.size, negatives: negatives.size } }
        ensure
          FileUtils.remove_entry(dir) if dir
        end

        private

        def cop_path
          File.join(app_root, "lib", "rubocop", "cop", "convention", "#{cop_name.underscore}.rb")
        end

        def write_corpus(dir, name, code)
          path = File.join(dir, "#{name}.rb")
          File.write(path, code)
          path
        end

        def inject_config(severity)
          config_path = File.join(app_root, ".rubocop.yml")
          existing = File.exist?(config_path) ? File.read(config_path) : ""
          return existing if existing.include?("Convention/#{cop_name.camelize}")

          entry = <<~YAML
            require:
              - ./lib/rubocop/cop/convention/#{cop_name.underscore}.rb

            Convention/#{cop_name.camelize}:
              Enabled: true
              Severity: #{severity}
          YAML
          File.write(config_path, "#{existing.rstrip}\n\n#{entry}")
        end
      end
    end
  end
end

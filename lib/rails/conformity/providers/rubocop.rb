require "json"
require "open3"

module Rails
  module Conformity
    module Providers
      class Rubocop < Base
        COP_MAP = {
          "Style/FrozenStringLiteralComment" => "convention/frozen_string_literal",
          "Lint/SuppressedException" => "convention/rescue_nil"
        }.freeze

        def initialize(app_root)
          @app_root = app_root
        end

        def call(files:, full: false)
          ruby_files = files.select { |file| file.end_with?(".rb") }
          return [] if ruby_files.empty?

          catalog = run(ruby_files, "--only", COP_MAP.keys.join(","))
          team = run(ruby_files)
          merge(catalog + team)
        rescue StandardError
          []
        end

        private

        def run(ruby_files, *extra)
          stdout, _stderr, _status = Open3.capture3(
            { "BUNDLE_GEMFILE" => File.join(@app_root, "Gemfile") },
            "bundle", "exec", "rubocop", "--no-color", "--format", "json", "--force-exclusion",
            *extra, *ruby_files.map { |file| File.join(@app_root, file) },
            chdir: @app_root
          )
          parse(stdout)
        end

        def merge(findings)
          findings.uniq { |finding| [finding.rule_id, finding.file, finding.line] }
        end

        def parse(stdout)
          json = begin
            JSON.parse(stdout)
          rescue StandardError
            return []
          end
          json.fetch("files", []).flat_map do |file|
            file.fetch("offenses", []).map do |offense|
              cop = offense.fetch("cop_name")
              rule_id = COP_MAP.fetch(cop, "rubocop/#{cop}")
              relative = relative_path(file.fetch("path"))
              Finding.new(
                rule_id: rule_id,
                severity: Rules.severity_for(rule_id, cop_severity(offense)),
                file: relative,
                line: offense.dig("location", "line"),
                message: offense.fetch("message")
              )
            end
          end
        end

        def cop_severity(offense)
          offense.fetch("severity") == "error" ? "error" : "warning"
        end

        def relative_path(path)
          path.delete_prefix("#{@app_root}/")
        end
      end
    end
  end
end

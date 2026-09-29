require "open3"

module Rails
  module Conformity
    module Providers
      class Verify < Base
        def initialize(app_root)
          @app_root = app_root
        end

        def call(files: [], full: false)
          findings = pending_migration_findings
          if full
            findings.concat(test_findings)
            findings.concat(zeitwerk_findings)
          end
          findings
        end

        private

        def pending_migration_findings
          stdout, _stderr, _status = Open3.capture3("bin/rails", "db:migrate:status", chdir: @app_root)
          stdout.lines.select { |line| line.match?(/\sdown\s|NO FILE/) }.map do |line|
            Finding.new(
              rule_id: "convention/pending_migration",
              severity: Rules.severity_for("convention/pending_migration"),
              file: line.strip.split.last(2).join(":"),
              message: "Pending migration: #{line.strip}"
            )
          end
        end

        def test_findings
          _stdout, _stderr, status = Open3.capture3("bin/rails", "test", chdir: @app_root)
          return [] if status.success?

          [Finding.new(
            rule_id: "convention/failing_tests",
            severity: Rules.severity_for("convention/failing_tests"),
            file: "test/",
            message: "Test suite fails (run bin/rails test for details)"
          )]
        end

        def zeitwerk_findings
          stdout, _stderr, status = Open3.capture3("bin/rails", "zeitwerk:check", chdir: @app_root)
          return [] if status.success?

          [Finding.new(
            rule_id: "convention/zeitwerk_error",
            severity: Rules.severity_for("convention/zeitwerk_error"),
            file: stdout[/(expected file .+? to define constant .+?)/, 1] || "app/",
            message: "Zeitwerk constant mismatch (run bin/rails zeitwerk:check)"
          )]
        end
      end
    end
  end
end

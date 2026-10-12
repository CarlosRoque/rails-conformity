require "open3"

module Rails
  module Conformity
    module Providers
      class Verify < Base
        def initialize(app_root)
          @app_root = app_root
        end

        def call(files: [], full: false, progress: nil)
          findings = pending_migration_findings(progress)
          if full
            findings.concat(test_findings(progress))
            findings.concat(zeitwerk_findings(progress))
          end
          findings
        end

        private

        # Prints "\rconformity: <label> (Ns)" to stderr (updates in place),
        # finalizing to its own line when done. Stdout stays clean.
        def run_with_progress(cmd, label, progress)
          return Open3.capture3(*cmd, chdir: @app_root) unless progress

          stop = false
          started = Time.now
          ticker = Thread.new do
            until stop
              $stderr.write("\rconformity: #{label} (#{(Time.now - started).to_i}s)   ")
              sleep 1
            end
          end
          stdout, stderr, status = Open3.capture3(*cmd, chdir: @app_root)
          stop = true
          ticker.wakeup
          ticker.join
          $stderr.write("\r#{' ' * 72}\rconformity: done #{label}\n")
          [stdout, stderr, status]
        rescue StandardError
          Open3.capture3(*cmd, chdir: @app_root)
        end

        def pending_migration_findings(progress)
          stdout, = run_with_progress(["bin/rails", "db:migrate:status"], "checking migrations", progress)
          stdout.lines.select { |line| line.match?(/\sdown\s|NO FILE/) }.map do |line|
            Finding.new(
              rule_id: "convention/pending_migration",
              severity: Rules.severity_for("convention/pending_migration"),
              file: line.strip.split.last(2).join(":"),
              message: "Pending migration: #{line.strip}"
            )
          end
        end

        def test_findings(progress)
          _stdout, _stderr, status = run_with_progress(["bin/rails", "test"], "running test suite", progress)
          return [] if status.success?

          [Finding.new(
            rule_id: "convention/failing_tests",
            severity: Rules.severity_for("convention/failing_tests"),
            file: "test/",
            message: "Test suite fails (run bin/rails test for details)"
          )]
        end

        def zeitwerk_findings(progress)
          stdout, _stderr, status = run_with_progress(["bin/rails", "zeitwerk:check"], "checking constants", progress)
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

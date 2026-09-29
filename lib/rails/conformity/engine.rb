require "open3"
require "json"

module Rails
  module Conformity
    class Engine
      INTERESTING = /\A(app|config|lib|db|test|spec)\/|\AGemfile\z|\AGemfile\.lock\z/

      attr_reader :app_root, :policy

      def initialize(app_root)
        @app_root = app_root
        @policy = Policy.load(app_root)
      end

      def providers
        available = {
          "conventions" => Providers::Conventions.new(app_root),
          "provenance" => Providers::Provenance.new(app_root),
          "rubocop" => Providers::Rubocop.new(app_root),
          "verify" => Providers::Verify.new(app_root)
        }
        policy.check_ids.filter_map { |id| available[id] }
      end

      def tracked_files
        tracked = git("ls-files").lines.map(&:strip)
        untracked = git("status --porcelain").lines.map do |line|
          line[3..]&.strip
        end.compact.reject { |entry| entry.end_with?("/") }
        (tracked + untracked).uniq.select { |file| file.match?(INTERESTING) && File.exist?(File.join(app_root, file)) }
      end

      def changed_files(base: "HEAD")
        diff = git("diff --name-only #{base}").lines.map(&:strip)
        untracked = git("status --porcelain").lines.map do |line|
          line[3..]&.strip
        end.compact.select { |entry| !entry.end_with?("/") }
        (diff + untracked).uniq.select { |file| file.match?(INTERESTING) && File.exist?(File.join(app_root, file)) }
      end

      def changed_lines(files, base: "HEAD")
        numstat = git("diff --numstat #{base}").lines.map(&:strip).to_h do |line|
          added, _removed, file = line.split("\t")
          [file, added.to_i]
        end
        files.to_h { |file| [file, numstat.fetch(file, 1)] }
      end

      def report(files:, detail: :findings, full_verify: false, base: nil)
        lines = base ? changed_lines(files, base: base) : {}
        report = Report.build(
          app_root: app_root, policy: policy, providers: providers,
          files: files, changed_lines: lines, full_verify: full_verify
        )
        [report, report.to_json(detail: detail)]
      end

      def full_report(full_verify: true)
        report(files: tracked_files, detail: :full, full_verify: full_verify)
      end

      def baseline
        Baseline.load(app_root)
      end

      def registry
        Registry.load(app_root)
      end

      def check(full_verify: true)
        findings = Report.build(
          app_root: app_root, policy: policy, providers: providers,
          files: tracked_files, full_verify: full_verify
        ).findings
        findings.concat(Renderer.new(app_root, policy, registry).drift_findings)
        findings = findings.uniq { |finding| [finding.rule_id, finding.file, finding.line] }

        new_findings = baseline.new_findings(findings).reject { |finding| finding.severity == "info" }
        {
          findings: findings,
          new_findings: new_findings,
          info_findings: findings.select { |finding| finding.severity == "info" },
          passed?: new_findings.empty?
        }
      end

      def record_baseline(full_verify: false)
        report, = report(files: tracked_files, detail: :summary, full_verify: full_verify)
        baseline.record(report.findings, score: report.score)
        [report.findings.size, report.score]
      end

      private

      def git(command)
        _stdout, _stderr, _status = Open3.capture3("git", *command.split, chdir: app_root)
        _stdout
      end
    end
  end
end

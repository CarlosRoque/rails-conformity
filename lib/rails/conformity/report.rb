require_relative "recommendation"

module Rails
  module Conformity
    class Report
      attr_reader :files, :findings, :recommendations, :score, :file_scores, :summary

      def self.build(app_root:, policy:, providers:, files:, changed_lines: {}, full_verify: false)
        findings = providers.flat_map { |provider| provider.call(files: files, full: full_verify) }
        findings = dedupe(findings)
        context = context_for(app_root, files)
        findings.concat(repeated_pattern_findings(app_root, files, context))
        findings = findings.sort_by { |finding| [finding.file, finding.rule_id, finding.line.to_i] }

        engine = Recommendation::Engine.new
        recommendations = findings.map { |finding| engine.recommend(finding, context.fetch(finding.file, {})) }

        scoring = Scoring.new(policy)
        findings_by_file = findings.group_by(&:file)
        file_scores = files.to_h { |file| [file, scoring.file_score(findings_by_file[file] || [])] }
        score = scoring.aggregate(files, findings_by_file, changed_lines)

        new(files: files, findings: findings, recommendations: recommendations, score: score,
            file_scores: file_scores, summary: "#{findings.size} findings across #{files.size} files")
      end

      def self.repeated_pattern_findings(app_root, files, context)
        service_files = files.select { |file| file.start_with?("app/services/") }
        return [] if service_files.size < 2

        Codify::Generator.patterns(app_root, files: service_files.map { |file| File.join(app_root, file) }).flat_map do |group|
          relative = group.map { |path| path.delete_prefix("#{app_root}/") }
          context[relative.first] = { pattern_group: relative }
          [Finding.new(
            rule_id: "convention/repeated_pattern",
            severity: Rules.severity_for("convention/repeated_pattern"),
            file: relative.first,
            message: "#{relative.size} structurally identical services: codify candidate (#{relative.join(", ")})"
          )]
        end
      end

      def self.context_for(app_root, files)
        files.to_h do |file|
          context = {}
          match = file.match(%r{app/controllers/(\w+)_controller\.rb})
          context[:model_name] = match[1].singularize.camelize if match
          [file, context]
        end
      end

      def self.dedupe(findings)
        findings.uniq { |finding| [finding.rule_id, finding.file, finding.line] }
      end

      def initialize(files:, findings:, recommendations:, score:, file_scores:, summary:)
        @files = files
        @findings = findings
        @recommendations = recommendations
        @score = score
        @file_scores = file_scores
        @summary = summary
      end

      def to_json(detail: :findings)
        base = {
          score: score,
          summary: summary,
          files: file_scores
        }
        return base.to_json if detail == :summary

        payload = base.merge(
          findings: findings.map { |finding| finding_h(finding, detail) },
          recommendations: recommendations.map(&:to_h)
        )
        payload.to_json
      end

      private

      def finding_h(finding, detail)
        hash = finding.to_h
        hash.delete(:evidence) unless detail == :full
        hash
      end
    end
  end
end

module Rails
  module Conformity
    class Scoring
      def initialize(policy)
        @policy = policy
      end

      def file_score(findings)
        penalty = findings.sum { |finding| @policy.weight(finding.severity) }
        [100 - penalty, 0].max
      end

      def aggregate(files, findings_by_file, changed_lines_by_file = {})
        total = 0.0
        weight = 0
        files.each do |file|
          score = file_score(findings_by_file[file] || [])
          lines = changed_lines_by_file.fetch(file, 1)
          total += score * lines
          weight += lines
        end
        return 100 if weight.zero?

        (total / weight).round
      end
    end
  end
end

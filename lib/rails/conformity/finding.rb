require "active_support/core_ext/string/inflections"

module Rails
  module Conformity
    class Finding
      SEVERITIES = %w[error warning info].freeze

      attr_reader :rule_id, :severity, :file, :line, :message, :evidence

      def initialize(rule_id:, severity:, file:, line: nil, message: "", evidence: nil)
        @rule_id = rule_id
        @severity = severity
        @file = file
        @line = line
        @message = message
        @evidence = evidence
      end

      def key
        "#{rule_id}:#{file}"
      end

      def to_h
        { rule_id: rule_id, severity: severity, file: file, line: line, message: message, evidence: evidence }.compact
      end

      def terse
        "#{rule_id}: #{file}#{line ? ":#{line}" : ''} #{message}"
      end

      def error?
        severity == "error"
      end
    end
  end
end

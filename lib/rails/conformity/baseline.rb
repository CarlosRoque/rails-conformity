require "yaml"

module Rails
  module Conformity
    class Baseline
      attr_reader :path

      def self.load(app_root)
        new(File.join(app_root, "conformity", "baseline.yml"))
      end

      def initialize(path)
        @path = path
        @data = File.exist?(path) ? YAML.safe_load_file(path) || {} : {}
      end

      def finding_keys
        @data.fetch("findings", [])
      end

      def score
        @data["score"]
      end

      def covers?(finding)
        finding_keys.include?(finding.key)
      end

      def new_findings(findings)
        findings.reject { |finding| covers?(finding) }
      end

      def record(findings, score:)
        keys = findings.map(&:key).uniq.sort
        File.write(path, YAML.dump({ "findings" => keys, "score" => score }))
        @data = { "findings" => keys, "score" => score }
        self
      end
    end
  end
end

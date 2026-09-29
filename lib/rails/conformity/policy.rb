require "yaml"

module Rails
  module Conformity
    class Policy
      DEFAULTS = {
        "weights" => { "error" => 10, "warning" => 3, "info" => 1 },
        "thresholds" => { "new_pr" => 85 },
        "checks" => {
          "conventions" => { "mode" => "strict" },
          "provenance" => { "mode" => "strict" },
          "rubocop" => { "mode" => "strict" },
          "verify" => { "mode" => "strict" }
        },
        "resolutions" => { "conform" => "auto", "codify" => "ask", "exempt" => "ask" }
      }.freeze

      def self.load(app_root)
        path = File.join(app_root, "config", "conformity.yml")
        merged = File.exist?(path) ? deep_merge(DEFAULTS, YAML.safe_load_file(path) || {}) : DEFAULTS.dup
        new(merged)
      end

      def self.deep_merge(base, other)
        base.merge(other) do |_key, a, b|
          a.is_a?(Hash) && b.is_a?(Hash) ? deep_merge(a, b) : b
        end
      end

      attr_reader :config

      def initialize(config = DEFAULTS)
        @config = config
      end

      def weight(severity)
        config.dig("weights", severity).to_i
      end

      def new_pr_threshold
        config.dig("thresholds", "new_pr").to_i
      end

      def strict?(check)
        config.dig("checks", check, "mode") != "advisory"
      end

      def check_ids
        config.fetch("checks", {}).keys
      end

      def resolution_policy(action)
        config.dig("resolutions", action) || "ask"
      end

      def to_h
        config
      end
    end
  end
end

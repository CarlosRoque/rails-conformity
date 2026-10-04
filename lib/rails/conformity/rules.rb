require "yaml"

module Rails
  module Conformity
    module Rules
      CATALOG = {
        "convention/strong_params" => { "severity" => "error", "topic" => "controllers", "tier" => "always" },
        "convention/raw_sql" => { "severity" => "error", "topic" => "queries", "tier" => "always" },
        "convention/frozen_string_literal" => { "severity" => "error", "topic" => "style", "tier" => "always" },
        "convention/no_respond_format" => { "severity" => "error", "topic" => "controllers", "tier" => "always" },
        "convention/ivar_naming" => { "severity" => "warning", "topic" => "controllers", "tier" => "always" },
        "convention/missing_before_action" => { "severity" => "warning", "topic" => "controllers", "tier" => "always" },
        "convention/missing_controller_tests" => { "severity" => "warning", "topic" => "controllers", "tier" => "always" },
        "convention/fat_controller" => { "severity" => "warning", "topic" => "controllers", "tier" => "always" },
        "convention/rescue_nil" => { "severity" => "error", "topic" => "style", "tier" => "always" },
        "convention/unsanitized_find" => { "severity" => "warning", "topic" => "controllers", "tier" => "always" },
        "convention/repeated_pattern" => { "severity" => "info", "topic" => "codify", "tier" => "ask" },
        "convention/rejected_pattern" => { "severity" => "info", "topic" => "codify", "tier" => "ask" },
        "convention/pending_migration" => { "severity" => "error", "topic" => "database", "tier" => "always" },
        "convention/failing_tests" => { "severity" => "error", "topic" => "tests", "tier" => "always" },
        "convention/zeitwerk_error" => { "severity" => "error", "topic" => "tests", "tier" => "always" },
        "conformity/steering_drift" => { "severity" => "error", "topic" => "steering", "tier" => "always" }
      }.freeze

      def self.severity_for(rule_id, fallback = "warning")
        CATALOG.dig(rule_id, "severity") || fallback
      end

      def self.tier_for(rule_id)
        CATALOG.dig(rule_id, "tier") || "always"
      end
    end
  end
end

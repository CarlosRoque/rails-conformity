module Rails
  module Conformity
    class Recommendation
      attr_reader :finding, :strategy, :command, :note

      def initialize(finding, strategy:, command: nil, note: nil)
        @finding = finding
        @strategy = strategy
        @command = command
        @note = note
      end

      def to_h
        {
          finding: finding.rule_id,
          file: finding.file,
          strategy: strategy,
          command: command,
          note: note
        }.compact
      end

      def deterministic?
        %w[autocorrect regenerate].include?(strategy)
      end

      class Engine
        RUBOCOP_AUTOCORRECTABLE = %w[
          convention/frozen_string_literal convention/rescue_nil
        ].freeze

        REGENERATE_RULES = %w[
          convention/strong_params convention/no_respond_format
          convention/ivar_naming convention/missing_before_action
          convention/missing_controller_tests convention/unsanitized_find
        ].freeze

        def recommend(finding, context = {})
          case finding.rule_id
          when *RUBOCOP_AUTOCORRECTABLE, /rubocop\/.+/
            autocorrect(finding)
          when *REGENERATE_RULES
            regenerate(finding, context)
          when "convention/raw_sql"
            manual(finding, note: "Replace string SQL conditions with hash conditions: .where(starts_at: range) instead of .where(\"...\")")
          when "convention/fat_controller"
            manual(finding, note: "Move domain math out of the action into an app/services object; see docs/conventions/controllers.md")
          when "convention/repeated_pattern"
            codify_generator(finding, context)
          when "convention/rejected_pattern"
            manual(finding, note: "Pattern recorded as not acceptable; refactor on touch, do not copy (see docs/conventions/codify.md)")
          when "conformity/steering_drift"
            autocorrect(finding, command: "bin/rails conformity:sync", note: "Steering files are stale relative to the registry")
          else
            manual(finding)
          end
        end

        private

        def autocorrect(finding, command: nil, note: nil)
          catalog_cops = Rails::Conformity::Providers::Rubocop::COP_MAP.keys.join(",")
          Recommendation.new(
            finding,
            strategy: "autocorrect",
            command: command || "bundle exec rubocop -A --only #{catalog_cops} #{finding.file}",
            note: note || "Autocorrectable by RuboCop (catalog cops)"
          )
        end

        def regenerate(finding, context)
          model = context.fetch(:model_name, "FIXME")
          Recommendation.new(
            finding,
            strategy: "regenerate",
            command: "bin/rails g scaffold_controller #{model} --helper=false --orm=false --template-engine=false --force",
            note: "Then transplant any custom actions into the regenerated file (see docs/conventions/controllers.md)"
          )
        end

        def codify_generator(finding, context)
          group = context.fetch(:pattern_group, []).join(", ")
          Recommendation.new(
            finding,
            strategy: "codify_generator",
            command: "bin/rails conformity:codify_generator[#{group}]",
            note: "Extract this repeated pattern into a generator; round-trip test decides acceptance"
          )
        end

        def manual(finding, note: nil)
          Recommendation.new(
            finding,
            strategy: "manual",
            command: nil,
            note: note || "Requires judgment; raise it in triage (conform / codify / exempt)"
          )
        end
      end
    end
  end
end

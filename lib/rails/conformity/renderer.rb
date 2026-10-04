require "erb"
require "fileutils"

module Rails
  module Conformity
    class Renderer
      TOPICS = {
        "controllers" => "Controllers",
        "queries" => "Queries",
        "style" => "Style",
        "database" => "Database",
        "tests" => "Tests",
        "codify" => "Codified conventions",
        "steering" => "Steering"
      }.freeze

      def initialize(app_root, policy, registry)
        @app_root = app_root
        @policy = policy
        @registry = registry
      end

      def files
        index = index_content
        topics = TOPICS.map { |topic, title| [File.join("docs", "conventions", "#{topic}.md"), topic_content(topic, title)] }.to_h
        nested = nested_exemption_files
        { "AGENTS.md" => index }.merge(topics).merge(nested)
      end

      def write
        files.each do |relative, content|
          path = File.join(@app_root, relative)
          FileUtils.mkdir_p(File.dirname(path))
          File.write(path, content)
        end
        files.keys
      end

      def drift_findings
        files.map do |relative, content|
          path = File.join(@app_root, relative)
          next if File.exist?(path) && File.read(path) == content

          Finding.new(
            rule_id: "conformity/steering_drift",
            severity: Rules.severity_for("conformity/steering_drift"),
            file: relative,
            message: "Steering file missing or stale relative to registry; run bin/rails conformity:sync"
          )
        end.compact
      end

      private

      def app_name
        File.basename(@app_root).camelize
      end

      def index_content
        <<~MARKDOWN
          # #{app_name} — agent guide

          Everything below is ENFORCED by `bin/rails conformity:check` (CI gate). Steering and enforcement are rendered from the same registry — this file is generated, never edit it by hand.

          ## Commands

          - Tests: `bin/rails test`
          - Lint: `bundle exec rubocop`
          - Conformity gate: `bin/rails conformity:check`
          - Regenerate this file: `bin/rails conformity:sync`

          ## Always (CI fails on these)

          - Strong parameters: every controller has a private `<singular>_params` method — see docs/conventions/controllers.md
          - No raw SQL strings in app/ code — see docs/conventions/queries.md
          - No fat controller actions; domain math lives in app/services — see docs/conventions/controllers.md
          - Scaffold-shaped controllers are generated, never hand-written: `bin/rails g scaffold_controller <Name> --helper=false --orm=false --template-engine=false`
          - Migrations are applied before merge (`bin/rails db:migrate`)

          ## Ask first

          - Codifying a new pattern as a cop or generator (`bin/rails conformity:codify_generator[...]`)
          - Any exemption — exemptions are tracked in the registry with an expiry date

          ## Never

          - Silence a cop with `# rubocop:disable` without a registry exemption
          - Hand-write any pattern listed in docs/conventions/codified.md

          ## Read when

          | Touching | Read |
          | --- | --- |
          | controllers | docs/conventions/controllers.md |
          | queries / models | docs/conventions/queries.md |
          | style | docs/conventions/style.md |
          | database | docs/conventions/database.md |
          | tests | docs/conventions/tests.md |
          | service patterns | docs/conventions/codify.md |
          #{registry_read_when_rows}

          ## Codified conventions (from registry)

          #{codified_section}
        MARKDOWN
      end

      def registry_read_when_rows
        @registry.exemptions.map do |entry|
          "| #{entry['path']} | #{entry['path']}/AGENTS.md |"
        end.join("\n  ")
      end

      def codified_section
        codified = @registry.codified
        return "(none yet — codify patterns via conformity:codify_generator or conformity:codify_cop)" if codified.empty?

        codified.map do |entry|
          "- #{entry['description']} (`#{entry['command']}`) — round-trip/corpus tested, added from #{entry['created_from']}"
        end.join("\n")
      end

      def topic_content(topic, title)
        case topic
        when "controllers" then controllers_topic
        when "queries" then queries_topic
        when "style" then style_topic
        when "database" then database_topic
        when "tests" then tests_topic
        when "codify" then codify_topic
        when "steering" then steering_topic
        else "# #{title}\n"
        end
      end

      def controllers_topic
        <<~MARKDOWN
          # Controllers

          - Every controller defines a private `<singular>_params` method using `params.expect` / `params.require`.
            - good: `params.expect(sailing: [:starts_at, :ends_at])`
            - bad: `Post.new(params[:post])`
          - Scaffold shape: `before_action :set_<singular>` plus a private setter using `<Model>.find(params[:id])`.
            - bad: `Post.find(params[:id].to_i)` inline in every action
          - CRUD actions redirect or render conventional formats; no inline `render json:`.
          - Instance variables follow scaffold names: `@<plural>` in index, `@<singular>` elsewhere.
          - Domain logic (fares, calculations) lives in app/services. Actions over 15 statements are flagged.
          - Scaffold-shaped controllers are generated, then custom actions are transplanted:
            `bin/rails g scaffold_controller <Name> --helper=false --orm=false --template-engine=false --force`
        MARKDOWN
      end

      def queries_topic
        <<~MARKDOWN
          # Queries

          - No raw SQL strings in app/ code.
            - good: `Post.where(status: :published)`
            - bad: `Post.where("published_at > ?", cutoff)`
        MARKDOWN
      end

      def style_topic
        <<~MARKDOWN
          # Style

          - `# frozen_string_literal: true` in every Ruby file (RuboCop autocorrects).
          - No `rescue nil`; rescue specific errors (RuboCop autocorrects to `rescue StandardError`, prefer explicit classes).
        MARKDOWN
      end

      def database_topic
        <<~MARKDOWN
          # Database

          - No pending migrations at merge time; `bin/rails db:migrate:status` must be clean.
          - Migrations are reversible.
        MARKDOWN
      end

      def tests_topic
        <<~MARKDOWN
          # Tests

          - Every controller has a controller test generated with it.
          - Test suite green: `bin/rails test`.
          - Zeitwerk constants resolve: `bin/rails zeitwerk:check`.
        MARKDOWN
      end

      def codify_topic
        <<~MARKDOWN
          # Codified conventions

          - A repeated pattern (3+ structurally identical files) is a codify candidate, not copy-paste material.
          - Codify as generator: `bin/rails conformity:codify_generator[app/services/a.rb,app/services/b.rb]`
          - Acceptance is deterministic: the round-trip test must reproduce every original file from the template.
          - A proposed custom cop is accepted only when the corpus test fires on every positive example and stays silent on every negative.
          #{reject_notes}
        MARKDOWN
      end

      def reject_notes
        entries = @registry.rejects
        return "" if entries.empty?

        body = entries.map { |entry| "  - #{entry['paths'].join(', ')}: #{entry['note']}" }.join("\n")
        "- Rejected patterns (recorded decisions — not acceptable, do not copy):\n#{body}"
      end

      def steering_topic
        <<~MARKDOWN
          # Steering

          - AGENTS.md and docs/conventions/* are generated from conformity/registry.yml.
          - `bin/rails conformity:sync` regenerates them; a stale file fails the gate like a stale schema.rb.
        MARKDOWN
      end

      def nested_exemption_files
        @registry.exemptions.select { |entry| entry["path"] }.to_h do |entry|
          [File.join(entry["path"], "AGENTS.md"), <<~MARKDOWN]
            # AGENTS.md (#{entry['path']})

            This area is exempt from `#{entry['rules'].join(", ")}` until #{entry['expires_on']}.
            Do not copy this pattern elsewhere; do not extend the exemption without a new triage decision.
          MARKDOWN
        end
      end
    end
  end
end

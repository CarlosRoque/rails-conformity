require "spec_helper"
require "fileutils"
require "tmpdir"

RSpec.describe Rails::Conformity::Finding do
  it "builds a terse one-line message" do
    finding = Rails::Conformity::Finding.new(
      rule_id: "convention/strong_params", severity: "error",
      file: "app/controllers/sailings_controller.rb", line: 12, message: "no strong params"
    )
    expect(finding.terse).to eq("convention/strong_params: app/controllers/sailings_controller.rb:12 no strong params")
    expect(finding.key).to eq("convention/strong_params:app/controllers/sailings_controller.rb")
    expect(finding.to_h[:evidence]).to be_nil
  end
end

RSpec.describe Rails::Conformity::Policy do
  it "defaults weights and thresholds" do
    policy = Rails::Conformity::Policy.new
    expect(policy.weight("error")).to eq(10)
    expect(policy.weight("warning")).to eq(3)
    expect(policy.new_pr_threshold).to eq(85)
    expect(policy.strict?("conventions")).to be true
    expect(policy.resolution_policy("codify")).to eq("ask")
  end

  it "merges app overrides" do
    policy = Rails::Conformity::Policy.new(Rails::Conformity::Policy.deep_merge(
      Rails::Conformity::Policy::DEFAULTS,
      { "checks" => { "rubocop" => { "mode" => "advisory" } } }
    ))
    expect(policy.strict?("rubocop")).to be false
    expect(policy.strict?("conventions")).to be true
  end
end

RSpec.describe Rails::Conformity::Scoring do
  let(:policy) { Rails::Conformity::Policy.new }
  let(:scoring) { Rails::Conformity::Scoring.new(policy) }

  it "starts files at 100 and subtracts weighted findings" do
    error = Rails::Conformity::Finding.new(rule_id: "a", severity: "error", file: "a.rb")
    warning = Rails::Conformity::Finding.new(rule_id: "b", severity: "warning", file: "a.rb")
    expect(scoring.file_score([error, warning])).to eq(100 - 10 - 3)
  end

  it "floors at zero and aggregates weighted by changed lines" do
    errors = Array.new(12) { Rails::Conformity::Finding.new(rule_id: "a", severity: "error", file: "a.rb") }
    expect(scoring.file_score(errors)).to eq(0)
    score = scoring.aggregate(%w[a.rb b.rb], { "a.rb" => errors, "b.rb" => [] }, { "a.rb" => 90, "b.rb" => 10 })
    expect(score).to eq(10)
  end
end

RSpec.describe Rails::Conformity::Recommendation::Engine do
  let(:engine) { described_class.new }

  it "prefers deterministic strategies" do
    autocorrectable = Rails::Conformity::Finding.new(rule_id: "convention/frozen_string_literal", severity: "error", file: "a.rb")
    regenerable = Rails::Conformity::Finding.new(rule_id: "convention/strong_params", severity: "error", file: "app/controllers/sailings_controller.rb")
    manual = Rails::Conformity::Finding.new(rule_id: "convention/raw_sql", severity: "error", file: "a.rb")

    expect(engine.recommend(autocorrectable).deterministic?).to be true
    expect(engine.recommend(regenerable, { model_name: "Sailing" })).to have_attributes(strategy: "regenerate")
    expect(engine.recommend(regenerable, { model_name: "Sailing" }).command).to include("scaffold_controller Sailing")
    expect(engine.recommend(manual).deterministic?).to be false
  end
end

RSpec.describe Rails::Conformity::Codify::Generator do
  ALERT = <<~'RUBY'
    class %sAlert
      def initialize(record)
        @record = record
      end

      def call
        "%s alert: #{@record.name} needs attention"
      end
    end
  RUBY

  it "extracts a template that round-trips every instance" do
    Dir.mktmpdir do |dir|
      %w[route vessel dock weather].each do |name|
        File.write(File.join(dir, "#{name}_alert.rb"), format(ALERT, name.camelize, name.camelize))
      end
      files = %w[route_alert.rb vessel_alert.rb dock_alert.rb weather_alert.rb]
      generator = described_class.new(dir, files)

      expect(generator.extract).to be true
      expect(generator.round_trip?).to be true
      expect(generator.template_source).to include("<%= class_name %>Alert")
      expect(generator.generator_name).to eq("alert")
      expect(generator.instances["route_alert.rb"][:class_name]).to eq("Route")
    end
  end

  it "does not group structurally different files" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "route_alert.rb"), format(ALERT, "Route", "Route"))
      File.write(File.join(dir, "fare_quote.rb"), "class FareQuote\n  def call = 42\nend\n")
      groups = described_class.patterns(dir)
      expect(groups).to be_empty
    end
  end

  it "detects repeated families in models and jobs, not just services" do
    MODEL = <<~'RUBY'
      class %sCalculator < ApplicationRecord
        def self.public_details
          { name: name }
        end
      end
    RUBY

    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "app", "models"))
      FileUtils.mkdir_p(File.join(dir, "app", "jobs"))
      %w[subtotal discount].each do |name|
        File.write(File.join(dir, "app", "models", "#{name}_calculator.rb"), format(MODEL, name.camelize))
      end
      File.write(File.join(dir, "app", "jobs", "one_job.rb"), "class OneJob < ApplicationJob\n  def perform\n  end\nend\n")
      File.write(File.join(dir, "app", "jobs", "two_job.rb"), "class TwoJob < ApplicationJob\n  def perform\n  end\nend\n")
      File.write(File.join(dir, "app", "jobs", "application_job.rb"), "class ApplicationJob\nend\n")

      groups = described_class.patterns(dir)
      group_paths = groups.flatten
      expect(group_paths).to include(*%w[app/models/subtotal_calculator.rb app/models/discount_calculator.rb])
      expect(group_paths).to include(*%w[app/jobs/one_job.rb app/jobs/two_job.rb])
      expect(group_paths).not_to include("app/jobs/application_job.rb")
    end
  end

  it "finds namespaced families and keeps the module wrapper in the template" do
    NS_ALERT = <<~'RUBY'
      module Shipping
        class %sAlert
          def call
            "%s alert: needs attention"
          end
        end
      end
    RUBY

    Dir.mktmpdir do |dir|
      %w[rate fuel].each do |name|
        FileUtils.mkdir_p(File.join(dir, "app", "services", "shipping"))
        File.write(File.join(dir, "app", "services", "shipping", "#{name}_alert.rb"), format(NS_ALERT, name.camelize, name.camelize))
      end
      files = %w[app/services/shipping/rate_alert.rb app/services/shipping/fuel_alert.rb]
      generator = described_class.new(dir, files)

      expect(generator.extract).to be true
      expect(generator.round_trip?).to be true
      expect(generator.template_source).to include("module Shipping")
      expect(generator.template_source).to include("<%= class_name %>Alert")
      expect(generator.generator_name).to eq("alert")
      expect(generator.instances["app/services/shipping/rate_alert.rb"][:class_name]).to eq("Rate")
    end
  end

  it "codifies a service + spec family as one multi-file pattern" do
    SPEC = <<~'RUBY'
      require "test_helper"

      class %sAlertTest < ActiveSupport::TestCase
        test "calls" do
          record = Object.new
          def record.name = "x"
          assert_equal "%s alert: x needs attention", %sAlert.new(record).call
        end
      end
    RUBY

    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "app", "services"))
      FileUtils.mkdir_p(File.join(dir, "spec", "services"))
      %w[route dock].each do |name|
        File.write(File.join(dir, "app", "services", "#{name}_alert.rb"), format(ALERT, name.camelize, name.camelize))
        FileUtils.mkdir_p(File.join(dir, "spec", "services"))
        File.write(File.join(dir, "spec", "services", "#{name}_alert_spec.rb"), format(SPEC, name.camelize, name.camelize, name.camelize))
      end
      generator = described_class.new(dir, %w[app/services/route_alert.rb app/services/dock_alert.rb])

      expect(generator.extract).to be true
      expect(generator.round_trip?).to be true
      expect(generator.roles.keys).to eq(%w[service spec])
      expect(generator.role_templates["spec"]).to include("<%= class_name %>AlertTest")
    end
  end

  it "codifies factory registration with a round-tripped line template" do
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "app", "services"))
      %w[route dock].each do |name|
        File.write(File.join(dir, "app", "services", "#{name}_alert.rb"), format(ALERT, name.camelize, name.camelize))
      end
      File.write(File.join(dir, "app", "services", "alert_factory.rb"), <<~FACTORY)
        class AlertFactory
          REGISTRY = {
            route: RouteAlert,
            dock: DockAlert
          }.freeze
        end
      FACTORY
      generator = described_class.new(
        dir, %w[app/services/route_alert.rb app/services/dock_alert.rb], register: "app/services/alert_factory.rb"
      )

      expect(generator.extract).to be true
      expect(generator.round_trip?).to be true
      registration = generator.registration
      expect(registration.round_trip?).to be true
      expect(registration.render("FogAlert", "fog_alert", "fog")).to eq("    fog: FogAlert,\n")
    end
  end

  it "fails registration extraction when a member is missing from the factory" do
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "app", "services"))
      %w[route dock].each do |name|
        File.write(File.join(dir, "app", "services", "#{name}_alert.rb"), format(ALERT, name.camelize, name.camelize))
      end
      File.write(File.join(dir, "app", "services", "alert_factory.rb"), <<~FACTORY)
        class AlertFactory
          REGISTRY = {
            route: RouteAlert
          }.freeze
        end
      FACTORY
      generator = described_class.new(
        dir, %w[app/services/route_alert.rb app/services/dock_alert.rb], register: "app/services/alert_factory.rb"
      )

      expect(generator.extract).to be false
    end
  end
end

RSpec.describe Rails::Conformity::Registry do
  it "answers whether a rejected pattern covers a file" do
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "conformity"))
      registry = Rails::Conformity::Registry.new(File.join(dir, "conformity", "registry.yml"))
      registry.add(
        "id" => "reject-legacy", "kind" => "reject", "paths" => %w[app/services/legacy_import.rb],
        "note" => "TODO: refactor; do not copy this pattern", "created_from" => "triage"
      )

      expect(registry.covers?("app/services/legacy_import.rb")).to be true
      expect(registry.covers?("app/services/legacy_import.rb/helpers.rb")).to be true
      expect(registry.covers?("app/services/fare_quote.rb")).to be false
    end
  end
end

RSpec.describe Rails::Conformity::Report do
  it "annotates rejected pattern groups instead of suggesting codify" do
    ALERT = <<~'RUBY'
      class %sAlert
        def call
          "%s alert: needs attention"
        end
      end
    RUBY

    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "app", "services"))
      FileUtils.mkdir_p(File.join(dir, "conformity"))
      %w[route dock].each do |name|
        File.write(File.join(dir, "app", "services", "#{name}_alert.rb"), format(ALERT, name.camelize, name.camelize))
      end
      registry = Rails::Conformity::Registry.new(File.join(dir, "conformity", "registry.yml"))
      registry.add(
        "id" => "reject-alerts", "kind" => "reject", "paths" => %w[app/services/route_alert.rb],
        "note" => "TODO: refactor into notifier; do not copy", "created_from" => "triage"
      )

      report = Rails::Conformity::Report.build(
        app_root: dir, policy: Rails::Conformity::Policy.new,
        providers: [], files: %w[app/services/route_alert.rb app/services/dock_alert.rb]
      )
      finding = report.findings.find { |f| f.rule_id == "convention/rejected_pattern" }
      expect(finding).to be_present
      expect(finding.message).to include("TODO: refactor into notifier; do not copy")
      expect(report.findings).not_to include(an_object_having_attributes(rule_id: "convention/repeated_pattern"))
    end
  end
end

RSpec.describe Rails::Conformity::Renderer do
  it "renders deterministic, byte-identical steering files with no timestamps" do
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "conformity"))
      registry = Rails::Conformity::Registry.new(File.join(dir, "conformity", "registry.yml"))
      policy = Rails::Conformity::Policy.new

      first = Rails::Conformity::Renderer.new(dir, policy, registry).files
      second = Rails::Conformity::Renderer.new(dir, policy, registry).files
      expect(first).to eq(second)
      expect(first.keys).to include("AGENTS.md", "docs/conventions/controllers.md")
      expect(first["AGENTS.md"].lines.count).to be < 150
      expect(first["AGENTS.md"]).not_to include(Time.now.year.to_s + "-")

      registry.add({ "id" => "exempt-legacy", "kind" => "exemption", "path" => "app/services/legacy_import",
                     "rules" => %w[convention/raw_sql], "expires_on" => "2026-12-31", "created_from" => "triage" })
      nested = Rails::Conformity::Renderer.new(dir, policy, registry).files
      expect(nested.keys).to include("app/services/legacy_import/AGENTS.md")
      expect(nested["app/services/legacy_import/AGENTS.md"]).to include("until 2026-12-31")
    end
  end
end

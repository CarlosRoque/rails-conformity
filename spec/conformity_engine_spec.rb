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

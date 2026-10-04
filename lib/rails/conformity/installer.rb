require "yaml"
require "fileutils"
require_relative "skill"

module Rails
  module Conformity
    class Installer
      attr_reader :app_root

      def initialize(app_root)
        @app_root = app_root
      end

      def detect
        {
          "test_framework" => File.exist?(File.join(app_root, "test")) ? "minitest" : "rspec",
          "rubocop" => File.exist?(File.join(app_root, ".rubocop.yml")),
          "custom_dirs" => Dir.glob(File.join(app_root, "app", "*")).select { |path| File.directory?(path) }
                             .map { |path| File.basename(path) } - %w[controllers channels helpers jobs mailers models views]
        }
      end

      def install(hooks: [])
        stack = detect
        write_policy(stack)
        ensure_generator_load_path
        registry.write
        Renderer.new(app_root, policy, registry).write
        files = Renderer.new(app_root, policy, registry).files.keys
        files << Skill.new.write(app_root)
        unless hooks.empty?
          files += Hooks.new(app_root).install(hooks)
        end
        files << File.join("config", "conformity.yml")
        files << File.join("conformity", "registry.yml")
        files << File.join("config", "application.rb")
        { stack: stack, files: files.sort }
      end

      def first_run(mode: "ratchet")
        engine = Engine.new(app_root)
        if mode == "triage"
          triage(engine)
        elsif Baseline.load(app_root).finding_keys.any?
          { mode: "ratchet (skipped, baseline exists)", findings: nil }
        else
          count, score = engine.record_baseline
          { mode: "ratchet", findings: count, score: score }
        end
      end

      def triage(engine)
        report, = engine.report(files: engine.tracked_files, detail: :findings)
        decisions = []
        report.findings.each do |finding|
          puts "#{finding.rule_id}: #{finding.file} — #{finding.message}"
          print "[c]odify / [e]xempt / [r]eject / [k]eep in baseline? "
          answer = $stdin.gets.to_s.strip
          case answer
          when "c"
            decisions << { rule_id: finding.rule_id, decision: "codify" }
            registry.add(
              "id" => "codify-#{finding.rule_id.tr("/", "-")}",
              "kind" => "generator",
              "description" => finding.message,
              "command" => "bin/rails conformity:codify_generator[#{finding.file}]",
              "paths" => [finding.file],
              "created_from" => finding.rule_id
            )
          when "e"
            decisions << { rule_id: finding.rule_id, decision: "exempt" }
            registry.add(
              "id" => "exempt-#{finding.rule_id.tr("/", "-")}",
              "kind" => "exemption",
              "path" => File.dirname(finding.file),
              "rules" => [finding.rule_id],
              "expires_on" => (Date.today >> 6).iso8601,
              "created_from" => finding.rule_id
            )
          when "r"
            decisions << { rule_id: finding.rule_id, decision: "reject" }
            print "reject note (blank = TODO: refactor; do not copy this pattern): "
            note = $stdin.gets.to_s.strip
            note = "TODO: refactor; do not copy this pattern" if note.empty?
            registry.add(
              "id" => "reject-#{finding.rule_id.tr("/", "-")}-#{File.basename(finding.file, ".*")}",
              "kind" => "reject",
              "paths" => [finding.file],
              "note" => note,
              "created_from" => finding.rule_id
            )
          else
            decisions << { rule_id: finding.rule_id, decision: "baseline" }
          end
        end
        Renderer.new(app_root, policy, registry).write
        { mode: "triage", decisions: decisions }
      end

      private

      def ensure_generator_load_path
        path = File.join(app_root, "config", "application.rb")
        source = File.read(path) if File.exist?(path)
        return unless source&.include?("config.autoload_lib")

        needed = %w[generators rubocop].reject do |dir|
          source.match?(%r{config\.autoload_lib\(ignore:.*\b#{dir}\b.*\)})
        end
        return if needed.empty?

        updated = source.sub(/config\.autoload_lib\(ignore: %w\[(.*?)\]\)/) do
          current = Regexp.last_match(1).split
          "config.autoload_lib(ignore: %w[#{(current + needed).uniq.join(" ")}])"
        end
        File.write(path, updated) if updated != source
      end

      def policy
        @policy ||= Policy.load(app_root)
      end

      def registry
        @registry ||= Registry.load(app_root)
      end

      def write_policy(stack)
        config = {
          "stack" => stack,
          "weights" => Policy::DEFAULTS["weights"],
          "thresholds" => Policy::DEFAULTS["thresholds"],
          "checks" => Policy::DEFAULTS["checks"],
          "resolutions" => Policy::DEFAULTS["resolutions"]
        }
        path = File.join(app_root, "config", "conformity.yml")
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, YAML.dump(config).gsub(/^---\n/, ""))
        path
      end
    end
  end
end

require "json"

module Rails
  module Conformity
    module TaskHelpers
      def self.engine
        Engine.new(Rails.root)
      end

      def self.parse_args(task_args)
        values = ([task_args[:opts]] + task_args.extras).compact
        raw = values.join(",")
        raw.to_s.split(",").to_h do |pair|
          key, value = pair.split("=", 2)
          [key.delete_prefix("--"), value]
        end
      end
    end
  end
end

namespace :conformity do
  desc "Measure, compare, recommend (--format=json,--detail=summary|findings|full,--base=HEAD)"
  task :report, [:opts] => :environment do |_t, args|
    options = Rails::Conformity::TaskHelpers.parse_args(args)
    engine = Rails::Conformity::TaskHelpers.engine
    base = options["base"]
    files = base ? engine.changed_files(base: base) : engine.changed_files
    full_verify = options["full"] == "true"
    _report, json = engine.report(files: files, detail: options.fetch("detail", "findings").to_sym, full_verify: full_verify, base: base)
    if options["format"] == "json"
      puts json
    else
      parsed = JSON.parse(json)
      puts "score: #{parsed['score']}  #{parsed['summary']}"
      parsed["findings"].to_a.each { |finding| puts "  #{finding['severity']}: #{finding['rule_id']}: #{finding['file']} #{finding['message']}" }
      parsed["recommendations"].to_a.each { |rec| puts "  -> #{rec['strategy']}: #{rec['command'] || rec['note']}" }
    end
  end

  desc "Gate check: exit 0 green, exit 2 with new findings on stderr"
  task check: :environment do
    engine = Rails::Conformity::TaskHelpers.engine
    result = engine.check(full_verify: true)
    if result[:passed?]
      puts "conformity: green (baseline ratchet honored)"
    else
      result[:new_findings].each { |finding| warn finding.terse }
      warn "conformity: #{result[:new_findings].size} new finding(s) — gate failed"
      exit 2
    end
  end

  desc "Record the team baseline (ratchet)"
  task :baseline, [:opts] => :environment do |_t, args|
    options = Rails::Conformity::TaskHelpers.parse_args(args)
    full = options["full"] == "true"
    count, score = Rails::Conformity::TaskHelpers.engine.record_baseline(full_verify: full)
    puts "conformity: baseline recorded — #{count} findings, score #{score}"
  end

  desc "Interactive triage of all findings"
  task triage: :environment do
    engine = Rails::Conformity::TaskHelpers.engine
    result = Rails::Conformity::Installer.new(Rails.root).triage(engine)
    puts "conformity: triage complete — #{result[:decisions].size} decision(s)"
  end

  desc "First run: ratchet baseline (default) or interactive triage (--mode=triage)"
  task :first_run, [:opts] => :environment do |_t, args|
    options = Rails::Conformity::TaskHelpers.parse_args(args)
    mode = options.fetch("mode", "ratchet")
    result = Rails::Conformity::Installer.new(Rails.root).first_run(mode: mode)
    puts "conformity: first_run (#{result[:mode]}) — #{result[:findings] || result[:decisions]&.size} finding(s) recorded"
  end

  desc "Regenerate AGENTS.md and docs/conventions from the registry"
  task sync: :environment do
    engine = Rails::Conformity::TaskHelpers.engine
    files = Rails::Conformity::Renderer.new(Rails.root, engine.policy, engine.registry).write
    puts "conformity: synced #{files.join(', ')}"
  end

  desc "Codify a repeated pattern as a generator (comma-separated files, --register=path for factory registration)"
  task :codify_generator, [:opts] => :environment do |_t, args|
    raw = ([args[:opts]] + args.extras).compact
    register = nil
    files = raw.filter_map do |arg|
      if arg.start_with?("--register=")
        register = arg.delete_prefix("--register=")
        nil
      else
        arg
      end
    end
    abort "conformity: no files given" if files.empty?

    generator = Rails::Conformity::Codify::Generator.new(Rails.root, files, register: register)
    unless generator.extract && generator.round_trip?
      abort "conformity: round-trip test FAILED — pattern not codified (template must reproduce every original)"
    end

    name = generator.generator_name
    written = generator.write_generator(name: name)
    engine = Rails::Conformity::TaskHelpers.engine
    entry = {
      "id" => "generator-#{name}",
      "kind" => "generator",
      "description" => "#{name.camelize} services are generated, never hand-written",
      "command" => "bin/rails g team:#{name} <Name>",
      "created_from" => "convention/repeated_pattern"
    }
    entry["register"] = register if register
    engine.registry.add(entry)
    Rails::Conformity::Renderer.new(Rails.root, engine.policy, engine.registry).write
    puts "conformity: round-trip PASSED — #{written.join(', ')}"
  end

  desc "Codify a proposed cop and verify it with a corpus test (prototype: raw SQL cop)"
  task :codify_cop, [:cop_name] => :environment do |_t, args|
    cop_name = args[:cop_name] || "no_raw_sql_where"
    cop = Rails::Conformity::Codify::Cop.new(Rails.root, cop_name)
    cop.build(
      message: "Prefer hash conditions over raw SQL: %<sql>s",
      restrict_on_send: %i[where],
      node_pattern: "(send _ :where $(str _) ...)"
    )
    result = cop.corpus_test(
      positives: [
        "Sailing.where(\"starts_at > ?\", cutoff)",
        "Sailing.where(\"fare_cents > 100\")"
      ],
      negatives: [
        "Sailing.where(starts_at: cutoff)",
        "Sailing.where.not(starts_at: cutoff)"
      ]
    )
    unless result[:passed?]
      abort "conformity: corpus test FAILED (missed: #{result[:missed]}, false hits: #{result[:false_hits]}) — cop rejected"
    end

    engine = Rails::Conformity::TaskHelpers.engine
    engine.registry.add(
      "id" => "cop-#{cop_name}",
      "kind" => "cop",
      "description" => "Raw SQL string conditions are rejected by the corpus-tested cop Convention/#{cop_name.camelize}",
      "command" => "bundle exec rubocop",
      "created_from" => "convention/raw_sql"
    )
    Rails::Conformity::Renderer.new(Rails.root, engine.policy, engine.registry).write
    puts "conformity: corpus test PASSED — cop registered (missed: 0, false hits: 0)"
  end
end

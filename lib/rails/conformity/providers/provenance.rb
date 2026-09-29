require "rails/generators"

module Rails
  module Conformity
    module Providers
      class Provenance < Base
        def initialize(app_root)
          @app_root = app_root
        end

        def call(files:, full: false)
          findings = []
          files.each do |file|
            match = file.match(%r{app/controllers/(\w+)_controller\.rb})
            next unless match
            next if file.end_with?("application_controller.rb")

            name = match[1]
            klass = name.singularize.camelize
            next unless model_defined?(klass)

            findings.concat(structural_findings(file, name, klass))
            deviation = deviation_finding(file, name, klass)
            findings << deviation if deviation
          end
          findings
        end

        private

        def model_defined?(klass)
          File.exist?(File.join(@app_root, "app", "models", "#{klass.underscore}.rb"))
        end

        def structural_findings(file, name, klass)
          source = File.read(File.join(@app_root, file))
          singular = name.singularize.underscore
          findings = []

          unless source.match?(/before_action :set_#{singular}/)
            findings << Finding.new(
              rule_id: "convention/missing_before_action",
              severity: Rules.severity_for("convention/missing_before_action"),
              file: file,
              message: "Scaffold uses before_action :set_#{singular} with a private setter; controller does not"
            )
          end
          if source.match?(/@data|@item|@result|@payload/)
            findings << Finding.new(
              rule_id: "convention/ivar_naming",
              severity: Rules.severity_for("convention/ivar_naming"),
              file: file,
              message: "Scaffold assigns @#{name}/@#{singular}; controller uses ad-hoc ivars"
            )
          end
          if source.match?(/render json:/) && source.match?(/\bdef (create|update|destroy)\b/) && !source.match?(/respond_to|redirect_to/)
            findings << Finding.new(
              rule_id: "convention/no_respond_format",
              severity: Rules.severity_for("convention/no_respond_format"),
              file: file,
              message: "CRUD actions render json inline; scaffold redirects or renders conventional formats"
            )
          end
          if source.match?(/#{klass}\.find\(params\[:id\]\.to_[if]\)/)
            findings << Finding.new(
              rule_id: "convention/unsanitized_find",
              severity: Rules.severity_for("convention/unsanitized_find"),
              file: file,
              message: "Scaffold calls #{klass}.find(params[:id]); controller coerces manually"
            )
          end
          findings
        end

        def deviation_finding(file, name, klass)
          generated = generate_in_sandbox(name, klass)
          return unless generated

          delta = normalized_delta(generated, File.join(@app_root, file))
          return if delta.empty?

          Finding.new(
            rule_id: "provenance/scaffold_deviation",
            severity: "info",
            file: file,
            message: "#{delta[:lines]} lines differ from generator output (#{delta[:added]} added, #{delta[:removed]} removed)",
            evidence: delta[:first_diff]
          )
        end

        def generate_in_sandbox(name, klass)
          sink = File.new(File::NULL, "w")
          sandbox = Dir.mktmpdir("conformity-sandbox")
          generated = invoke_in_sandbox(sink, sandbox, name, klass)
          return unless generated

          File.read(generated)
          result = generated
          FileUtils.remove_entry(sandbox)
          result
        end

        def invoke_in_sandbox(sink, sandbox, name, klass)
          original_stdout = $stdout
          original_stderr = $stderr
          $stdout = sink
          $stderr = sink
          Rails::Generators.invoke(
            "scaffold_controller",
            [klass, "--skip-collision-check", "--no-helper", "--no-orm", "--no-test-framework", "--no-template-engine"],
            destination_root: sandbox
          )
          File.join(sandbox, "app", "controllers", "#{name}_controller.rb")
        rescue StandardError
          FileUtils.remove_entry(sandbox) if File.exist?(sandbox)
          nil
        ensure
          if original_stdout
            $stdout = original_stdout
            $stderr = original_stderr
          end
          sink.close unless sink.closed?
        end

        def normalized_delta(generated_source, app_path)
          generated = normalize(generated_source)
          actual = normalize(File.read(app_path))
          return { lines: 0, added: 0, removed: 0, first_diff: nil } if generated == actual

          generated_lines = generated.lines
          actual_lines = actual.lines
          added = actual_lines.count { |line| !generated_lines.include?(line) }
          removed = generated_lines.count { |line| !actual_lines.include?(line) }
          first = actual_lines.zip(generated_lines).find { |a, g| a != g }
          { lines: added + removed, added: added, removed: removed, first_diff: first&.first&.strip }
        end

        def normalize(source)
          source.lines.map(&:strip).reject do |line|
            line.empty? || line.start_with?("#")
          end.join("\n")
        end
      end
    end
  end
end

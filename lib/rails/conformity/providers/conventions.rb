require_relative "base"

module Rails
  module Conformity
    module Providers
      class Conventions < Base
        def call(files:, full: false)
          findings = []
          files.each do |file|
            next unless file.end_with?(".rb")

            if controller?(file) && !application_controller?(file)
              findings.concat(controller_findings(file))
            end
            if app_file?(file)
              raw_sql = raw_sql_finding(file)
              findings << raw_sql if raw_sql
            end
          end
          findings
        end

        private

        def controller?(file)
          file.include?("app/controllers/") && file.end_with?("_controller.rb")
        end

        def application_controller?(file)
          file.end_with?("application_controller.rb")
        end

        def app_file?(file)
          file.start_with?("app/") && file.end_with?(".rb")
        end

        def controller_findings(file)
          source = File.read(file)
          name = File.basename(file, "_controller.rb")
          singular = name.underscore.singularize
          [
            strong_params_finding(file, source, singular),
            missing_tests_finding(file, name),
            fat_controller_finding(file, source)
          ].compact
        end

        def strong_params_finding(file, source, singular)
          return unless source.match?(/\bdef (create|update)\b/)
          return if source.match?(/def #{singular}_params\b/) || source.match?(/params\.(expect|require|fetch)\b/)

          raw_line = source.each_line.find_index { |line| line.include?("params[:") }
          Finding.new(
            rule_id: "convention/strong_params",
            severity: Rules.severity_for("convention/strong_params"),
            file: file,
            line: raw_line ? raw_line + 1 : nil,
            message: "create/update use raw params without strong parameters (#{singular}_params)"
          )
        end

        def missing_tests_finding(file, name)
          test_file = "test/controllers/#{name}_controller_test.rb"
          spec_file = "spec/controllers/#{name}_controller_spec.rb"
          return if File.exist?(test_file) || File.exist?(spec_file)

          Finding.new(
            rule_id: "convention/missing_controller_tests",
            severity: Rules.severity_for("convention/missing_controller_tests"),
            file: file,
            message: "No controller test found (#{test_file})"
          )
        end

        def fat_controller_finding(file, source)
          source.scan(/^  def (\w+)(.*?)^  end$/m).each do |_action, body|
            next unless body.lines.count { |line| !line.strip.empty? } > 15

            return Finding.new(
              rule_id: "convention/fat_controller",
              severity: Rules.severity_for("convention/fat_controller"),
              file: file,
              message: "Action has more than 15 statements of domain logic; move it to app/services"
            )
          end
          nil
        end

        def raw_sql_finding(file)
          source = File.read(file)
          line_number = source.each_line.find_index { |line| line.match?(/\.(where|order|select)\("/) }
          return unless line_number

          line = source.lines[line_number].strip
          return if line.match?(/migration|execute/)

          Finding.new(
            rule_id: "convention/raw_sql",
            severity: Rules.severity_for("convention/raw_sql"),
            file: file,
            line: line_number + 1,
            message: "Raw SQL string in #{line.split.first} call; use hash conditions",
            evidence: line
          )
        end
      end
    end
  end
end

require "json"
require "fileutils"

module Rails
  module Conformity
    class Hooks
      HOSTS = %w[git claude codex opencode].freeze

      def initialize(app_root)
        @app_root = app_root
      end

      def install(hosts)
        write_shim
        hosts.each { |host| send("install_#{host}") }
        hosts.map { |host| files_for(host) }.flatten
      end

      def files_for(host)
        case host
        when "git" then [File.join(".git", "hooks", "pre-push")]
        when "claude" then [File.join(".claude", "settings.json")]
        when "codex" then [File.join(".codex", "hooks.json")]
        when "opencode" then ["opencode.json"]
        end
      end

      private

      def write_shim
        catalog_cops = Rails::Conformity::Providers::Rubocop::COP_MAP.keys.join(",")
        path = File.join(@app_root, "bin", "conformity")
        source = <<~'RUBY'
          #!/usr/bin/env ruby
          require "json"

          Dir.chdir(File.expand_path("..", __dir__))

          raw = $stdin.read
          payload = raw.empty? ? {} : begin
            JSON.parse(raw)
          rescue StandardError
            {}
          end
          input = payload.is_a?(Hash) ? payload : {}

          command = ARGV[0] || "changed-check"

          case command
          when "edit-check"
            file = input.dig("tool_input", "file_path") || input.dig("tool_input", "path") || input.dig("tool_input", "file")
            exit 0 unless file && file.end_with?(".rb")

            require "yaml"
            baseline = begin
              YAML.safe_load_file("conformity/baseline.yml")
            rescue StandardError
              {}
            end || {}
            allowed = Array(baseline["findings"]).map(&:to_s)

            catalog = `bundle exec rubocop --no-color --only __CATALOG_COPS__ "#{file}" 2>&1`
            team = `bundle exec rubocop --no-color "#{file}" 2>&1`
            fresh = (catalog + team).lines
              .map(&:strip)
              .select { |line| line.match?(/:\d+:\d+: [CWE]:/) }
              .uniq
              .reject do |line|
                cop = line[/\[Correctable\] ([A-Z][A-Za-z\/]+): /, 1] || line[/: [CWE]: ([A-Z][A-Za-z\/]+): /, 1]
                key = if cop == "Style/FrozenStringLiteralComment"
                  "convention/frozen_string_literal:#{file}"
                elsif cop == "Lint/SuppressedException"
                  "convention/rescue_nil:#{file}"
                else
                  "rubocop/#{cop}:#{file}"
                end
                allowed.include?(key)
              end
            if fresh.empty?
              exit 0
            else
              warn fresh.first(5)
              exit 2
            end
          when "changed-check"
            exit(system("bin/rails conformity:check") ? 0 : 2)
          else
            warn "usage: bin/conformity [edit-check|changed-check]"
            exit 1
          end
        RUBY
        File.write(path, source.sub("__CATALOG_COPS__", catalog_cops))
        FileUtils.chmod(0o755, path)
        path
      end

      def marker
        "bin/conformity"
      end

      def install_git
        path = File.join(@app_root, ".git", "hooks", "pre-push")
        existing = File.exist?(path) ? File.read(path) : ""
        return path if existing.include?(marker)

        File.write(path, existing.empty? ? git_hook : "#{existing.rstrip}\n#{git_hook}\n")
        FileUtils.chmod(0o755, path)
        path
      end

      def git_hook
        <<~SHELL
          # conformity gate
          exec bin/rails conformity:check
        SHELL
      end

      def install_claude
        merge_json(File.join(".claude", "settings.json")) do |config|
          hooks = config["hooks"] ||= {}
          if JSON.dump(hooks).include?(marker)
            config
          else
            hooks["PostToolUse"] = (hooks["PostToolUse"] || []) + [
              { "matcher" => "Edit|Write|MultiEdit",
                "hooks" => [{ "type" => "command", "command" => "bin/conformity edit-check", "timeout" => 30 }] }
            ]
            hooks["Stop"] = (hooks["Stop"] || []) + [
              { "hooks" => [{ "type" => "command", "command" => "bin/conformity changed-check", "timeout" => 300 }] }
            ]
            config
          end
        end
      end

      def install_codex
        merge_json(File.join(".codex", "hooks.json")) do |config|
          hooks = config["hooks"] ||= []
          return config if JSON.dump(hooks).include?(marker)

          config["hooks"] = hooks + [
            { "matcher" => "Edit|Write|apply_patch",
              "hooks" => [{ "type" => "command", "command" => "bin/conformity edit-check", "timeout" => 30 }] },
            { "matcher" => "",
              "hooks" => [{ "type" => "command", "command" => "bin/conformity changed-check", "timeout" => 300 }] }
          ]
          config
        end
      end

      def install_opencode
        merge_json("opencode.json") do |config|
          return config if JSON.dump(config).include?(marker)

          config["hooks"] ||= {}
          config["hooks"]["tool.execute.after"] = [
            { "matcher" => "edit|write", "command" => "bin/conformity edit-check", "timeout" => 30_000 }
          ]
          config
        end
      end

      def merge_json(relative)
        path = File.join(@app_root, relative)
        FileUtils.mkdir_p(File.dirname(path))
        config = File.exist?(path) ? (JSON.parse(File.read(path)) rescue {}) : {}
        config = yield(config.is_a?(Hash) ? config : {})
        File.write(path, JSON.pretty_generate(config) + "\n")
        path
      end
    end
  end
end

require_relative "../../../rails/conformity/engine"
require_relative "../../../rails/conformity/hooks"
require_relative "../../../rails/conformity/installer"

module Rails
  module Conformity
    class InstallGenerator < Rails::Generators::Base
      def self.namespace
        "conformity:install"
      end

      class_option :hooks, type: :string, default: "git,claude,codex,opencode", desc: "Hosts to wire: git,claude,codex,opencode or none"
      class_option :no_interactive, type: :boolean, default: false, desc: "Skip prompts; ratchet baseline"

      def install
        installer = Installer.new(destination_root)
        hooks = options[:hooks].to_s.split(",").map(&:strip).reject(&:empty?)
        hooks -= ["none"]
        hooks &= Hooks::HOSTS

        result = installer.install(hooks: hooks)
        say_status :install, "conformity (#{result[:stack].inspect})", :green
        result[:files].each { |file| say_status :create, file }

        if $stdout.tty? && !options[:no_interactive]
          mode = choose_mode
        else
          mode = "ratchet"
        end
        first_run = installer.first_run(mode: mode)
        say_status :first_run, "#{first_run[:mode]} (#{first_run[:findings] || first_run[:decisions]&.size} findings recorded)", :green
      end

      private

      def choose_mode
        say "Existing violations found. How do you want to handle them?"
        say "  1. Interactive triage — walk each finding now (conform / codify / exempt)"
        say "  2. Ratchet baseline — record everything; only new deviations fail CI"
        loop do
          answer = ask("Choose [1/2]: ").to_s.strip
          return "triage" if answer == "1"
          return "ratchet" if answer == "2" || answer.empty?
        end
      end
    end
  end
end

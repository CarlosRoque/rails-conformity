require "yaml"
require "fileutils"
require "active_support/core_ext/hash/indifferent_access"

module Rails
  module Conformity
    class Registry
      attr_reader :path, :entries

      def self.load(app_root)
        new(File.join(app_root, "conformity", "registry.yml"))
      end

      def initialize(path)
        @path = path
        @entries = File.exist?(path) ? (YAML.safe_load_file(path) || []).map(&:with_indifferent_access) : []
      end

      def find(id)
        entries.find { |entry| entry["id"] == id }
      end

      def add(entry)
        entry = entry.with_indifferent_access
        @entries.reject! { |existing| existing["id"] == entry["id"] }
        @entries << entry
        @entries.sort_by! { |existing| existing["id"].to_s }
        write
        self
      end

      def remove(id)
        @entries.reject! { |entry| entry["id"] == id }
        write
        self
      end

      def exemptions
        entries.select { |entry| entry["kind"] == "exemption" }
      end

      def rejects
        entries.select { |entry| entry["kind"] == "reject" }
      end

      # True when a rejected pattern covers the file (exact path or prefix).
      def covers?(relative_path)
        rejects.any? do |entry|
          Array(entry["paths"]).any? do |covered|
            relative_path == covered || relative_path.start_with?("#{covered}/")
          end
        end
      end

      def codified
        entries.select { |entry| %w[cop generator].include?(entry["kind"]) }
      end

      def codified_paths
        codified.flat_map { |entry| Array(entry["paths"]) }
      end

      # True when a codified generator/cop covers the file (exact or prefix).
      def codified_covers?(relative_path)
        codified_paths.any? { |covered| relative_path == covered || relative_path.start_with?("#{covered}/") }
      end

      def write
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, YAML.dump(sort_entry_keys(entries)))
        self
      end

      private

      def sort_entry_keys(list)
        list.map do |entry|
          entry.keys.sort.to_h { |key| [key, entry[key]] }
        end
      end
    end
  end
end

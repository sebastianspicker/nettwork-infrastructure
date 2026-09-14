# frozen_string_literal: true

require "yaml"
require_relative "constants"

module SwiftQuality
  class SourceInventory
    def initialize(root)
      @root = File.expand_path(root)
    end

    def files
      Dir.glob(File.join(@root, "**", "*.swift")).reject { |path| generated_path?(path) }.sort
    end

    def non_swift_files
      extensions = NON_SWIFT_FILE_LIMITS.keys.map { |extension| extension.delete_prefix(".") }.join(",")
      Dir.glob(File.join(@root, "**", "*.{#{extensions}}"))
         .reject { |path| generated_path?(path) }
         .sort
    end

    def relative_path(path)
      path.delete_prefix("#{@root}/")
    end

    def test_file?(relative)
      relative.split("/").any? { |part| part.match?(/(?:Tests|UITests)\z/) } ||
        File.basename(relative).match?(/Tests?\.swift\z/)
    end

    def non_swift_limit(path)
      NON_SWIFT_FILE_LIMITS.fetch(File.extname(path))
    end

    def targets_for(files)
      mapping = Hash.new { |hash, key| hash[key] = [] }
      add_package_targets(mapping, files)
      add_xcode_targets(mapping, files)
      files.each { |file| finalize_target(mapping, file) }
      mapping
    rescue Psych::Exception => error
      abort "swift-quality: cannot parse project.yml: #{error.message}"
    end

    private

    def generated_path?(path)
      relative_path(path).split("/").any? do |component|
        GENERATED_DIRECTORIES.include?(component.downcase)
      end
    end

    def add_package_targets(mapping, files)
      package = File.join(@root, "Packages", "NettworkCore", "Package.swift")
      return unless File.file?(package)

      files.each do |file|
        match = relative_path(file).match(%r{\APackages/NettworkCore/(?:Sources|Tests)/([^/]+)/})
        mapping[file] << "swiftpm:#{match[1]}" if match
      end
    end

    def add_xcode_targets(mapping, files)
      project_path = File.join(@root, "project.yml")
      return unless File.file?(project_path)

      project = YAML.load_file(project_path)
      (project["targets"] || {}).each do |name, target|
        Array(target["sources"]).each { |source| map_xcode_source(mapping, files, name, source) }
      end
    end

    def map_xcode_source(mapping, files, name, source)
      source_path = source.is_a?(Hash) ? source["path"] : source
      return unless source_path

      prefix = File.expand_path(source_path, @root)
      files.each { |file| mapping[file] << "xcode:#{name}" if file.start_with?("#{prefix}/") }
    end

    def finalize_target(mapping, file)
      mapping[file].uniq!
      mapping[file] << "unassigned:#{relative_path(file).split("/").first}" if mapping[file].empty?
    end
  end
end

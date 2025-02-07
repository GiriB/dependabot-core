# frozen_string_literal: true

require "json"
require "dependabot/file_fetchers"
require "dependabot/file_fetchers/base"
require "dependabot/npm_and_yarn/file_parser"

module Dependabot
  module NpmAndYarn
    # rubocop:disable Metrics/ClassLength
    class FileFetcher < Dependabot::FileFetchers::Base
      require_relative "file_fetcher/path_dependency_builder"

      # Npm always prefixes file paths in the lockfile "version" with "file:"
      # even when a naked path is used (e.g. "../dep")
      NPM_PATH_DEPENDENCY_STARTS = %w(file:).freeze
      # "link:" is only supported by Yarn but is interchangeable with "file:"
      # when it specifies a path. Only include Yarn "link:"'s that start with a
      # path and ignore symlinked package names that have been registered with
      # "yarn link", e.g. "link:react"
      PATH_DEPENDENCY_STARTS =
        %w(file: link:. link:/ link:~/ / ./ ../ ~/).freeze
      PATH_DEPENDENCY_CLEAN_REGEX = /^file:|^link:/.freeze

      def self.required_files_in?(filenames)
        filenames.include?("package.json")
      end

      def self.required_files_message
        "Repo must contain a package.json/rush.json."
      end

      def npmrc_content
        npmrc.content
      end

      private

      def fetch_files
        fetched_files = []
        fetched_files += root_manifest_files
        fetched_files << package_lock if package_lock && !ignore_package_lock?
        fetched_files << yarn_lock if yarn_lock
        fetched_files << shrinkwrap if shrinkwrap
        fetched_files << lerna_json if lerna_json
        fetched_files << npmrc if npmrc
        fetched_files << yarnrc if yarnrc
        fetched_files += rush_files if rush_files
        fetched_files += workspace_package_jsons
        fetched_files += lerna_packages
        fetched_files += path_dependencies(fetched_files)

        fetched_files.uniq
      end

      def root_manifest_files
        @root_manifest_files ||= fetch_root_manifest_files
      end

      def package_json
        @package_json ||= fetch_file_if_present("package.json")
      end

      def package_lock
        @package_lock ||= fetch_file_if_present("package-lock.json")
      end

      def yarn_lock
        @yarn_lock ||= fetch_file_if_present("yarn.lock")
      end

      def shrinkwrap
        @shrinkwrap ||= fetch_file_if_present("npm-shrinkwrap.json")
      end

      def npmrc
        @npmrc ||= fetch_file_if_present(".npmrc")&.
                   tap { |f| f.support_file = true }

        return @npmrc if @npmrc || directory == "/"

        # Loop through parent directories looking for an npmrc
        (1..directory.split("/").count).each do |i|
          @npmrc = fetch_file_from_host("../" * i + ".npmrc")&.
                   tap { |f| f.support_file = true }
          break if @npmrc
        rescue Dependabot::DependencyFileNotFound
          # Ignore errors (.npmrc may not be present)
          nil
        end

        @npmrc
      end

      def yarnrc
        @yarnrc ||= fetch_file_if_present(".yarnrc")&.
                   tap { |f| f.support_file = true }

        return @yarnrc if @yarnrc || directory == "/"

        # Loop through parent directories looking for an yarnrc
        (1..directory.split("/").count).each do |i|
          @yarnrc = fetch_file_from_host("../" * i + ".yarnrc")&.
                   tap { |f| f.support_file = true }
          break if @yarnrc
        rescue Dependabot::DependencyFileNotFound
          # Ignore errors (.yarnrc may not be present)
          nil
        end

        @yarnrc
      end

      def lerna_json
        @lerna_json ||= fetch_file_if_present("lerna.json")&.
                        tap { |f| f.support_file = true }
      end

      def rush_files
        @rush_files ||= [*rush_configs, *rush_packages].compact
      end

      def rush_json
        @rush_json ||= fetch_file_if_present("rush.json")&.
                        tap { |f| f.support_file = true }
      end

      def rush_configs
        @rush_configs ||= fetch_rush_configs
      end

      def fetch_rush_configs
        [
          fetch_file_if_present("common/config/rush/pnpm-lock.yaml"),
          fetch_file_if_present("common/config/rush/shrinkwrap.yaml"),
          fetch_file_if_present("common/config/rush/pnpmfile.js"),
          fetch_file_if_present("common/config/rush/.npmrc"),
          fetch_file_if_present("common/scripts/install-run-rush.js"),
          fetch_file_if_present("common/scripts/install-run.js"),
          fetch_file_if_present("common/config/pnpmfile-dependencies.json"),
          fetch_file_if_present("common/config/rush/common-versions.json"),
          fetch_file_if_present("common/config/rush/version-policies.json")
        ].compact
      end

      def fetch_root_manifest_files
        raise Dependabot::ManifestFileNotFound unless package_json || rush_json

        [package_json, rush_json].compact
      end

      def workspace_package_jsons
        @workspace_package_jsons ||= fetch_workspace_package_jsons
      end

      def lerna_packages
        @lerna_packages ||= fetch_lerna_packages
      end

      def rush_packages
        @rush_packages ||= fetch_rush_packages
      end

      def path_dependencies(fetched_files)
        package_json_files = []
        unfetchable_deps = []

        path_dependency_details(fetched_files).each do |name, path|
          path = path.gsub(PATH_DEPENDENCY_CLEAN_REGEX, "")
          filename = path
          # NPM/Yarn support loading path dependencies from tarballs:
          # https://docs.npmjs.com/cli/pack.html
          filename = File.join(filename, "package.json") unless filename.end_with?(".tgz", ".tar")
          cleaned_name = Pathname.new(filename).cleanpath.to_path
          next if fetched_files.map(&:name).include?(cleaned_name)

          begin
            file = fetch_file_from_host(filename, fetch_submodules: true)
            package_json_files << file
          rescue Dependabot::DependencyFileNotFound
            # Unfetchable tarballs should not be re-fetched as a package
            unfetchable_deps << [name, path] unless path.end_with?(".tgz", ".tar")
          end
        end

        package_json_files += build_unfetchable_deps(unfetchable_deps)

        if package_json_files.any?
          package_json_files +=
            path_dependencies(fetched_files + package_json_files)
        end

        package_json_files.tap { |fs| fs.each { |f| f.support_file = true } }
      end

      def path_dependency_details(fetched_files)
        package_json_path_deps = []

        fetched_files.each do |file|
          package_json_path_deps +=
            path_dependency_details_from_manifest(file)
        end

        package_lock_path_deps = path_dependency_details_from_npm_lockfile(
          parsed_package_lock
        )
        shrinkwrap_path_deps = path_dependency_details_from_npm_lockfile(
          parsed_shrinkwrap
        )

        [
          *package_json_path_deps,
          *package_lock_path_deps,
          *shrinkwrap_path_deps
        ].uniq
      end

      # rubocop:disable Metrics/PerceivedComplexity
      # rubocop:disable Metrics/AbcSize
      def path_dependency_details_from_manifest(file)
        return [] unless file.name.end_with?("package.json")

        current_dir = file.name.rpartition("/").first
        current_dir = nil if current_dir == ""

        dep_types = NpmAndYarn::FileParser::DEPENDENCY_TYPES
        parsed_manifest = JSON.parse(file.content)
        dependency_objects = parsed_manifest.values_at(*dep_types).compact
        # Fetch yarn "file:" path "resolutions" so the lockfile can be resolved
        resolution_objects = parsed_manifest.values_at("resolutions").compact
        manifest_objects = dependency_objects + resolution_objects

        raise Dependabot::DependencyFileNotParseable, file.path unless manifest_objects.all? { |o| o.is_a?(Hash) }

        resolution_deps = resolution_objects.flat_map(&:to_a).
                          map do |path, value|
                            convert_dependency_path_to_name(path, value)
                          end

        path_starts = PATH_DEPENDENCY_STARTS
        (dependency_objects.flat_map(&:to_a) + resolution_deps).
          select { |_, v| v.is_a?(String) && v.start_with?(*path_starts) }.
          map do |name, path|
            path = path.gsub(PATH_DEPENDENCY_CLEAN_REGEX, "")
            path = File.join(current_dir, path) unless current_dir.nil?
            [name, Pathname.new(path).cleanpath.to_path]
          end
      rescue JSON::ParserError
        raise Dependabot::DependencyFileNotParseable, file.path
      end
      # rubocop:enable Metrics/AbcSize
      # rubocop:enable Metrics/PerceivedComplexity

      def path_dependency_details_from_npm_lockfile(parsed_lockfile)
        path_starts = NPM_PATH_DEPENDENCY_STARTS
        parsed_lockfile.fetch("dependencies", []).to_a.
          select { |_, v| v.is_a?(Hash) }.
          select { |_, v| v.fetch("version", "").start_with?(*path_starts) }.
          map { |k, v| [k, v.fetch("version")] }
      end

      # Re-write the glob name to the targeted dependency name (which is used
      # in the lockfile), for example "parent-package/**/sub-dep/target-dep" >
      # "target-dep"
      def convert_dependency_path_to_name(path, value)
        # Picking the last two parts that might include a scope
        parts = path.split("/").last(2)
        parts.shift if parts.count == 2 && !parts.first.start_with?("@")
        [parts.join("/"), value]
      end

      def fetch_workspace_package_jsons
        return [] unless parsed_package_json["workspaces"]

        package_json_files = []

        workspace_paths(parsed_package_json["workspaces"]).each do |workspace|
          file = File.join(workspace, "package.json")

          begin
            package_json_files << fetch_file_from_host(file)
          rescue Dependabot::DependencyFileNotFound
            nil
          end
        end

        package_json_files
      end

      def fetch_lerna_packages
        return [] unless parsed_lerna_json["packages"]

        dependency_files = []

        workspace_paths(parsed_lerna_json["packages"]).each do |workspace|
          dependency_files += fetch_lerna_packages_from_path(workspace)
        end

        dependency_files
      end

      def fetch_rush_packages
        return [] unless parsed_rush_json["projects"]

        dependency_files = []
        workspace_paths(parsed_rush_json["projects"]).each do |workspace|
          dependency_files += fetch_rush_packages_from_path(workspace["projectFolder"])
        end

        dependency_files
      end

      def fetch_lerna_packages_from_path(path, nested = false)
        dependency_files = []

        package_json_path = File.join(path, "package.json")

        begin
          dependency_files << fetch_file_from_host(package_json_path)
          dependency_files += [
            fetch_file_if_present(File.join(path, "package-lock.json")),
            fetch_file_if_present(File.join(path, "yarn.lock")),
            fetch_file_if_present(File.join(path, "npm-shrinkwrap.json"))
          ].compact
        rescue Dependabot::DependencyFileNotFound
          matches_double_glob =
            parsed_lerna_json["packages"].any? do |globbed_path|
              next false unless globbed_path.include?("**")

              File.fnmatch?(globbed_path, path)
            end

          if matches_double_glob && !nested
            dependency_files +=
              expanded_paths(File.join(path, "*")).flat_map do |nested_path|
                fetch_lerna_packages_from_path(nested_path, true)
              end
          end
        end

        dependency_files
      end

      def fetch_rush_packages_from_path(path, _nested = false)
        dependency_files = []
        package_json_path = File.join(path, "package.json")

        # Currently we fetch just the package.json
        # TODO: Do we need nested lookup here? Do we need wildcard matching?
        dependency_files << fetch_file_from_host(package_json_path)

        dependency_files
      end

      # rubocop:disable Metrics/PerceivedComplexity
      def workspace_paths(workspace_object)
        paths_array =
          if workspace_object.is_a?(Hash)
            workspace_object.values_at("packages", "nohoist").flatten.compact
          elsif workspace_object.is_a?(Array) then workspace_object
          else
            [] # Invalid lerna.json, which must not be in use
          end

        # Currently, for complex glob patterns like packages/**/*, */packages/**,
        # it is not possible to fetch workspace packages without local repo clone,
        # (See `expanded_paths` function declaration in this file for more details).
        # Hence, the idea is to fetch all the package.json paths in the repo and then
        # match it with the specified workspace glob patterns.
        complex_glob_pattern_present = paths_array.any? do |globbed_path|
          globbed_path.include?("**") || globbed_path.include?("*/")
        end
        if complex_glob_pattern_present

          workspace_directories = expanded_paths_for_complex_glob_patterns(paths_array)
          return workspace_directories unless workspace_directories.empty?
        end

        paths_array.flat_map do |path|
          # The packages/!(not-this-package) syntax is unique to Yarn
          if path.include?("*") || path.include?("!(")
            expanded_paths(path)
          else
            path
          end
        end
      end
      # rubocop:enable Metrics/PerceivedComplexity

      # Only expands globs one level deep, so path/**/* gets expanded to path/
      def expanded_paths(path)
        ignored_paths = path.scan(/!\((.*?)\)/).flatten

        dir = directory.gsub(%r{(^/|/$)}, "")
        path = path.gsub(%r{^\./}, "").gsub(/!\(.*?\)/, "*")
        unglobbed_path = path.split("*").first&.gsub(%r{(?<=/)[^/]*$}, "") ||
                         "."

        repo_contents(dir: unglobbed_path, raise_errors: false).
          select { |file| file.type == "dir" }.
          map { |f| f.path.gsub(%r{^/?#{Regexp.escape(dir)}/?}, "") }.
          select { |filename| File.fnmatch?(path, filename) }.
          reject { |fn| ignored_paths.any? { |p| fn.include?(p) } }
      end

      def expanded_paths_for_complex_glob_patterns(paths_array)
        workspace_directories = []
        ignored_paths = ignored_workspace_paths(paths_array)
        package_json_paths = fetch_all_workspace_package_jsons_repo_paths

        package_json_paths.each do |package_json_path|
          # Since we want only the directory path, remove package.json from the package_json_path
          workspace_directory_path = package_json_path.chomp("/package.json")

          # If it does not match any of the specified workspaces or is an excluded workspace, skip that workspace path.
          next unless ignored_paths.none? { |path| File.fnmatch?(path, workspace_directory_path, File::FNM_PATHNAME) }
          next unless paths_array.any? do |path|
                        !path.include?("!(") && File.fnmatch?(path, workspace_directory_path, File::FNM_PATHNAME)
                      end

          workspace_directories.append(workspace_directory_path)
        end

        workspace_directories
      end

      def fetch_all_workspace_package_jsons_repo_paths
        dir = directory.gsub(%r{(^/|/$)}, "")

        fetch_repo_paths_for_code_search("package.json", directory).
          # Check if the path is for a package.json file and starts with the source repo directory
          filter { |repo_path| repo_path.end_with?("/package.json") }.
          # Return path relative to repo source directory
          map { |package_json_path| package_json_path.gsub(%r{^/?#{Regexp.escape(dir)}/?}, "") }
      end

      def ignored_workspace_paths(workspace_paths)
        # The packages/!(not-this-package) syntax is used to specify workspace exclusions
        ignored_paths_array = workspace_paths.filter { |path| path.include?("!(") }

        ignored_workspace_paths = []
        ignored_paths_array.each do |ignored_path|
          paths = ignored_path.scan(/!\((.*?)\)/).flatten
          paths.each do |path|
            # Expands regex to add individual directory regexes
            ignored_workspace_paths.append(ignored_path.gsub(/!\(.*?\)/, path))
          end
        end

        ignored_workspace_paths
      end

      def parsed_package_json
        return {} unless package_json

        JSON.parse(package_json.content)
      rescue JSON::ParserError
        raise Dependabot::DependencyFileNotParseable, package_json.path
      end

      def parsed_package_lock
        return {} unless package_lock

        JSON.parse(package_lock.content)
      rescue JSON::ParserError
        {}
      end

      def parsed_shrinkwrap
        return {} unless shrinkwrap

        JSON.parse(shrinkwrap.content)
      rescue JSON::ParserError
        {}
      end

      def ignore_package_lock?
        return false unless npmrc

        npmrc.content.match?(/^package-lock\s*=\s*false/)
      end

      def build_unfetchable_deps(unfetchable_deps)
        return [] unless package_lock || yarn_lock

        unfetchable_deps.map do |name, path|
          PathDependencyBuilder.new(
            dependency_name: name,
            path: path,
            directory: directory,
            package_lock: package_lock,
            yarn_lock: yarn_lock
          ).dependency_file
        end
      end

      def parsed_lerna_json
        return {} unless lerna_json

        JSON.parse(lerna_json.content)
      rescue JSON::ParserError
        raise Dependabot::DependencyFileNotParseable, lerna_json.path
      end

      def parsed_rush_json
        return {} unless rush_json

        JSON.parse(rush_json.content)
      rescue JSON::ParserError
        raise Dependabot::DependencyFileNotParseable, rush_json.path
      end
    end
    # rubocop:enable Metrics/ClassLength
  end
end

Dependabot::FileFetchers.
  register("npm_and_yarn", Dependabot::NpmAndYarn::FileFetcher)

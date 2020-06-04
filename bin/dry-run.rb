#!/usr/bin/env ruby
# frozen_string_literal: true

# This script is does a full update run for a given repo (optionally for a
# specific dependency only), and shows the proposed changes to any dependency
# files without actually creating a pull request.
#
# It's used regularly by the Dependabot team to manually debug issues, so
# should always be up-to-date.
#
# Usage:
#   ruby bin/dry-run.rb [OPTIONS] PACKAGE_MANAGER GITHUB_REPO
#
# ! You'll need to have a GitHub access token (a personal access token is
# ! fine) available as the environment variable LOCAL_GITHUB_ACCESS_TOKEN.
#
# Example:
#   ruby bin/dry-run.rb go_modules zonedb/zonedb
#
# Package managers:
# - bundler
# - pip (includes pipenv)
# - npm_and_yarn
# - maven
# - gradle
# - cargo
# - hex
# - composer
# - nuget
# - go_modules
# - elm
# - submodules
# - docker
# - terraform

# rubocop:disable Style/GlobalVars

require "etc"
unless Etc.getpwuid(Process.uid).name == "dependabot"
  puts <<~INFO
    bin/dry-run.rb is only supported in a developerment container.

    Please use bin/docker-dev-shell first.
  INFO
  exit 1
end

$LOAD_PATH << "./bundler/lib"
$LOAD_PATH << "./cargo/lib"
$LOAD_PATH << "./common/lib"
$LOAD_PATH << "./composer/lib"
$LOAD_PATH << "./docker/lib"
$LOAD_PATH << "./elm/lib"
$LOAD_PATH << "./git_submodules/lib"
$LOAD_PATH << "./github_actions/lib"
$LOAD_PATH << "./go_modules/lib"
$LOAD_PATH << "./gradle/lib"
$LOAD_PATH << "./hex/lib"
$LOAD_PATH << "./maven/lib"
$LOAD_PATH << "./npm_and_yarn/lib"
$LOAD_PATH << "./nuget/lib"
$LOAD_PATH << "./python/lib"
$LOAD_PATH << "./terraform/lib"

require "bundler"
require "json"
ENV["BUNDLE_GEMFILE"] = File.join(__dir__, "../omnibus/Gemfile")
Bundler.setup

require "optparse"
require "json"
require "byebug"
require "logger"
require "dependabot/logger"
require "stackprof"

Dependabot.logger = Logger.new($stdout)

require "dependabot/file_fetchers"
require "dependabot/file_parsers"
require "dependabot/update_checkers"
require "dependabot/file_updaters"
require "dependabot/pull_request_creator"
require "dependabot/config/file_fetcher"

require "dependabot/bundler"
require "dependabot/cargo"
require "dependabot/composer"
require "dependabot/docker"
require "dependabot/elm"
require "dependabot/git_submodules"
require "dependabot/github_actions"
require "dependabot/go_modules"
require "dependabot/gradle"
require "dependabot/hex"
require "dependabot/maven"
require "dependabot/npm_and_yarn"
require "dependabot/nuget"
require "dependabot/python"
require "dependabot/terraform"

# GitHub credentials with write permission to the repo you want to update
# (so that you can create a new branch, commit and pull request).
# If using a private registry it's also possible to add details of that here.

$options = {
  credentials: [],
  provider: "github",
  directory: "/",
  dependency_names: nil,
  branch: nil,
  cache_steps: [],
  write: false,
  clone: false,
  lockfile_only: false,
  reject_external_code: false,
  requirements_update_strategy: nil,
  commit: nil,
  updater_options: {},
  security_advisories: [],
  security_updates_only: false,
  ignore_conditions: [],
  pull_request: false
}

unless ENV["LOCAL_GITHUB_ACCESS_TOKEN"].to_s.strip.empty?
  $options[:credentials] << {
    "type" => "git_source",
    "host" => "github.com",
    "username" => "x-access-token",
    "password" => ENV["LOCAL_GITHUB_ACCESS_TOKEN"]
  }
end

unless ENV["LOCAL_CONFIG_VARIABLES"].to_s.strip.empty?
  # For example:
  # "[{\"type\":\"npm_registry\",\"registry\":\
  #     "registry.npmjs.org\",\"token\":\"123\"}]"
  $options[:credentials].concat(JSON.parse(ENV["LOCAL_CONFIG_VARIABLES"]))
end

unless ENV["SECURITY_ADVISORIES"].to_s.strip.empty?
  # For example:
  # [{"dependency-name":"name",
  #   "patched-versions":[],
  #   "unaffected-versions":[],
  #   "affected-versions":["< 0.10.0"]}]
  $options[:security_advisories].concat(JSON.parse(ENV["SECURITY_ADVISORIES"]))
end

unless ENV["IGNORE_CONDITIONS"].to_s.strip.empty?
  # For example:
  # [{"dependency-name":"ruby","version-requirement":">= 3.a, < 4"}]
  $options[:ignore_conditions] = JSON.parse(ENV["IGNORE_CONDITIONS"])
end

# rubocop:disable Metrics/BlockLength
option_parse = OptionParser.new do |opts|
  opts.banner = "usage: ruby bin/dry-run.rb [OPTIONS] PACKAGE_MANAGER REPO"

  opts.on("--provider PROVIDER", "SCM provider e.g. github, azure, bitbucket") do |value|
    $options[:provider] = value
  end

  opts.on("--dir DIRECTORY", "Dependency file directory") do |value|
    $options[:directory] = value
  end

  opts.on("--branch BRANCH", "Repo branch") do |value|
    $options[:branch] = value
  end

  opts.on("--dep DEPENDENCIES",
          "Comma separated list of dependencies to update") do |value|
    $options[:dependency_names] = value.split(",").map { |o| o.strip.downcase }
  end

  opts.on("--cache STEPS", "Cache e.g. files, dependencies") do |value|
    $options[:cache_steps].concat(value.split(",").map(&:strip))
  end

  opts.on("--write", "Write the update to the cache directory") do |_value|
    $options[:write] = true
  end

  opts.on("--lockfile-only", "Only update the lockfile") do |_value|
    $options[:lockfile_only] = true
  end

  opts.on("--reject-external-code", "Reject external code") do |_value|
    $options[:reject_external_code] = true
  end

  opts_req_desc = "Options: auto, widen_ranges, bump_versions or "\
                         "bump_versions_if_necessary"
  opts.on("--requirements-update-strategy STRATEGY", opts_req_desc) do |value|
    value = nil if value == "auto"
    $options[:requirements_update_strategy] = value
  end

  opts.on("--commit COMMIT", "Commit to fetch dependency files from") do |value|
    $options[:commit] = value
  end

  opts.on("--clone", "clone the repo") do |_value|
    $options[:clone] = true
  end

  opts_opt_desc = "Comma separated list of updater options, "\
                  "available options depend on PACKAGE_MANAGER"
  opts.on("--updater-options OPTIONS", opts_opt_desc) do |value|
    $options[:updater_options] = value.split(",").map do |o|
      [o.strip.downcase.to_sym, true]
    end.to_h
  end

  opts.on("--security-updates-only",
          "Only update vulnerable dependencies") do |_value|
    $options[:security_updates_only] = true
  end

  opts.on("--profile",
          "Profile using Stackprof. Output in `tmp/stackprof-<datetime>.dump`") do
    $options[:profile] = true
  end

  opts.on("--pull-request",
          "Output pull request information: title, description") do
    $options[:pull_request] = true
  end
  opts.on("--registry-token TOKEN", "Azure PAT for accessing private feeds") do |value|
    $options[:reg_token] = value
  end
  opts.on("--github-access-token TOKEN", "Github PAT for accessing github based repos") do |value|
    $options[:github_token] = value
  end
  opts.on("--pr-count COUNT", "Count of the maximum PR's to raise in a single run") do |value|
    if value.to_i <= 0
      raise "Invalid PR count"
    end
    $options[:pr_count] = value.to_i
  end
  opts.on("--exclusions EXCLUSIONS", "List of dependencies to exclude") do |value|
    $options[:exclusions] = Set.new(value.split(",").map(&:strip))
  end
end
# rubocop:enable Metrics/BlockLength

option_parse.parse!

#unless ENV["LOCAL_AZURE_ACCESS_TOKEN"].to_s.strip.empty?
  $options[:credentials] << {
    "type" => "git_source",
    "host" => "dev.azure.com",
    #"username" => "x-access-token",
    "password" => $options[:azure_token]
  }
#end
  
#unless ENV["LOCAL_GITHUB_ACCESS_TOKEN"].to_s.strip.empty?
  $options[:credentials] << {
    "type" => "git_source",
    "host" => "github.com",
    "password" => $options[:github_token]
  }
#end

#unless ENV["LOCAL_CONFIG_VARIABLES"].to_s.strip.empty?
  # For example:
  # "[{\"type\":\"npm_registry\",\"registry\":\"registry.npmjs.org\",\"token\":\"123\"}]"
  #$options[:credentials].concat(JSON.parse(ENV["LOCAL_CONFIG_VARIABLES"]))
  #$options[:credentials] << {
  #}
#end



# Full name of the GitHub repo you want to create pull requests for
if ARGV.length < 2
  puts option_parse.help
  exit 1
end

$package_manager, $repo_name = ARGV


def show_diff(original_file, updated_file)
  return unless original_file

  if original_file.content == updated_file.content
    puts "    no change to #{original_file.name}"
    return
  end

  original_tmp_file = Tempfile.new("original")
  original_tmp_file.write(original_file.content)
  original_tmp_file.close

  updated_tmp_file = Tempfile.new("updated")
  updated_tmp_file.write(updated_file.content)
  updated_tmp_file.close

  diff = `diff #{original_tmp_file.path} #{updated_tmp_file.path}`
  puts
  puts "    ± #{original_file.name}"
  puts "    ~~~"
  puts diff.lines.map { |line| "    " + line }.join
  puts "    ~~~"
end

def cached_read(name)
  puts "cache read #{name}"
  raise "Provide something to cache" unless block_given?
  return yield unless $options[:cache_steps].include?(name)

  cache_path = File.join("tmp", $repo_name.split("/"), "cache", "#{name}.bin")
  cache_dir = File.dirname(cache_path)
  FileUtils.mkdir_p(cache_dir) unless Dir.exist?(cache_dir)
  cached = File.read(cache_path) if File.exist?(cache_path)
  # rubocop:disable Security/MarshalLoad
  return Marshal.load(cached) if cached

  # rubocop:enable Security/MarshalLoad

  data = yield
  File.write(cache_path, Marshal.dump(data))
  data
end

def dependency_files_cache_dir
  branch = $options[:branch] || ""
  dir = $options[:directory]
  File.join("dry-run", $repo_name.split("/"), branch, dir)
end

# rubocop:disable Metrics/AbcSize
# rubocop:disable Metrics/MethodLength
# rubocop:disable Metrics/CyclomaticComplexity
# rubocop:disable Metrics/PerceivedComplexity
def cached_dependency_files_read
  cache_dir = dependency_files_cache_dir
  cache_manifest_path = File.join(
    cache_dir, "cache-manifest-#{$package_manager}.json"
  )
  FileUtils.mkdir_p(cache_dir) unless Dir.exist?(cache_dir)

  cached_manifest = File.read(cache_manifest_path) if File.exist?(cache_manifest_path)
  cached_dependency_files = JSON.parse(cached_manifest) if cached_manifest

  all_files_cached = cached_dependency_files&.all? do |file|
    File.exist?(File.join(cache_dir, file["name"]))
  end

  if all_files_cached && $options[:cache_steps].include?("files")
    puts "=> reading dependency files from cache manifest: "\
         "./#{cache_manifest_path}"
    cached_dependency_files.map do |file|
      file_content = File.read(File.join(cache_dir, file["name"]))
      Dependabot::DependencyFile.new(
        name: file["name"],
        content: file_content,
        directory: file["directory"] || "/",
        support_file: file["support_file"] || false,
        symlink_target: file["symlink_target"] || nil,
        type: file["type"] || "file"
      )
    end
  else
    if $options[:cache_steps].include?("files")
      puts "=> failed to read all dependency files from cache manifest: "\
           "./#{cache_manifest_path}"
    end
    puts "=>Fetching dependency files"
    data = yield
    puts "=> dumping fetched dependency files: ./#{cache_dir}"
    manifest_data = data.map do |file|
      {
        name: file.name,
        directory: file.directory,
        symlink_target: file.symlink_target,
        support_file: file.support_file,
        type: file.type
      }
    end
    File.write(cache_manifest_path, JSON.pretty_generate(manifest_data))
    data.map do |file|
      files_path = File.join(cache_dir, file.name)
      files_dir = File.dirname(files_path)
      FileUtils.mkdir_p(files_dir) unless Dir.exist?(files_dir)
      File.write(files_path, file.content)
    end
    # Initialize a git repo so that changed files can be diffed
    if $options[:write]
      FileUtils.cp(".gitignore", File.join(cache_dir, ".gitignore")) if File.exist?(".gitignore")
      Dir.chdir(cache_dir) do
        system("git init . && git add . && git commit --allow-empty -m 'Init'")
      end
    end
    data
  end
end
# rubocop:enable Metrics/PerceivedComplexity
# rubocop:enable Metrics/CyclomaticComplexity
# rubocop:enable Metrics/MethodLength
# rubocop:enable Metrics/AbcSize

# rubocop:disable Metrics/MethodLength
def handle_dependabot_error(error:, dependency:)
  error_details =
    case error
    when Dependabot::DependencyFileNotResolvable
      {
        "error-type": "dependency_file_not_resolvable",
        "error-detail": { message: error.message }
      }
    when Dependabot::DependencyFileNotEvaluatable
      {
        "error-type": "dependency_file_not_evaluatable",
        "error-detail": { message: error.message }
      }
    when Dependabot::BranchNotFound
      {
        "error-type": "branch_not_found",
        "error-detail": { "branch-name": error.branch_name }
      }
    when Dependabot::DependencyFileNotParseable
      {
        "error-type": "dependency_file_not_parseable",
        "error-detail": {
          message: error.message,
          "file-path": error.file_path
        }
      }
    when Dependabot::DependencyFileNotFound
      {
        "error-type": "dependency_file_not_found",
        "error-detail": { "file-path": error.file_path }
      }
    when Dependabot::PathDependenciesNotReachable
      {
        "error-type": "path_dependencies_not_reachable",
        "error-detail": { dependencies: error.dependencies }
      }
    when Dependabot::GitDependenciesNotReachable
      {
        "error-type": "git_dependencies_not_reachable",
        "error-detail": { "dependency-urls": error.dependency_urls }
      }
    when Dependabot::GitDependencyReferenceNotFound
      {
        "error-type": "git_dependency_reference_not_found",
        "error-detail": { dependency: error.dependency }
      }
    when Dependabot::PrivateSourceAuthenticationFailure
      {
        "error-type": "private_source_authentication_failure",
        "error-detail": { source: error.source }
      }
    when Dependabot::PrivateSourceTimedOut
      {
        "error-type": "private_source_timed_out",
        "error-detail": { source: error.source }
      }
    when Dependabot::PrivateSourceCertificateFailure
      {
        "error-type": "private_source_certificate_failure",
        "error-detail": { source: error.source }
      }
    when Dependabot::MissingEnvironmentVariable
      {
        "error-type": "missing_environment_variable",
        "error-detail": {
          "environment-variable": error.environment_variable
        }
      }
    when Dependabot::GoModulePathMismatch
      {
        "error-type": "go_module_path_mismatch",
        "error-detail": {
          "declared-path": error.declared_path,
          "discovered-path": error.discovered_path,
          "go-mod": error.go_mod
        }
      }
    else
      raise error
    end

  puts " => handled error whilst updating #{dependency.name}: #{error_details.fetch(:"error-type")} "\
       "#{error_details.fetch(:"error-detail")}"
end
# rubocop:enable Metrics/MethodLength

StackProf.start(raw: true) if $options[:profile]

$source = Dependabot::Source.new(
  provider: $options[:provider],
  repo: $repo_name,
  directory: $options[:directory],
  branch: $options[:branch],
  commit: $options[:commit]
)

always_clone = Dependabot::Utils.
               always_clone_for_package_manager?($package_manager)
$repo_contents_path = File.expand_path(File.join("tmp", $repo_name.split("/"))) if $options[:clone] || always_clone

fetcher_args = {
  source: $source,
  credentials: $options[:credentials],
  repo_contents_path: $repo_contents_path
}
$config_file = begin
  cfg_file = Dependabot::Config::FileFetcher.new(**fetcher_args).config_file
  Dependabot::Config::File.parse(cfg_file.content)
rescue Dependabot::DependencyFileNotFound
  Dependabot::Config::File.new(updates: [])
end
$update_config = $config_file.update_config(
  $package_manager,
  directory: $options[:directory],
  target_branch: $options[:branch]
)

fetcher = Dependabot::FileFetchers.for_package_manager($package_manager).new(**fetcher_args)
$files = if $repo_contents_path
           if $options[:cache_steps].include?("files") && Dir.exist?($repo_contents_path)
             puts "=> reading cloned repo from #{$repo_contents_path}"
           else
             puts "=> cloning into #{$repo_contents_path}"
             FileUtils.rm_rf($repo_contents_path)
           end
           fetcher.clone_repo_contents
           if $options[:commit]
             Dir.chdir($repo_contents_path) do
               puts "=> checking out commit #{$options[:commit]}"
               Dependabot::SharedHelpers.run_shell_command("git checkout #{$options[:commit]}")
             end
           end
           fetcher.files
         else
           cached_dependency_files_read do
             fetcher.files
           end
         end

def create_user_npmrc
  puts "reading user .npmrc file"
  home = ENV["HOME"].to_s.strip
  npmrc_path = "#{home}/.npmrc"
  puts "#{npmrc_path}"

  File.delete(npmrc_path) if File.exist?(npmrc_path)

  npmrc = $fetcher.npmrc_content.gsub("\r\n", "\n").gsub("\r", "\n").split("\n")
  registries = []
  npmrc.each do |registry| if !registry.start_with?("#") && registry.include?("registry=")
    registries.push(registry.split('=').at(1).gsub("https:", "").gsub("http:", ""))
  end
  end

  registries = registries.uniq

  registries.each do |reg|
    registry_url = reg
    $options[:credentials] << {
    "type" => "npm_registry",
    "registry" => registry_url[2..-1],
    "token" => Base64.encode64(":" + $options[:reg_token]).gsub("\n", "")
    }
    registry_username = registry_url[2..-1].split('/').at(0).split('.').at(0)
    registry_password = Base64.encode64($options[:reg_token]).gsub("\n", "")
    registry_email = "xyz@abc.com"
    out_file = File.new(npmrc_path, "a")
    registry_npmrc_content = registry_url + ":username=" + registry_username + "\n"
    registry_npmrc_content += registry_url + ":_password=" + registry_password + "\n"
    registry_npmrc_content += registry_url + ":email=" + registry_email + "\n"

    out_file.write(registry_npmrc_content)
    out_file.write(registry_npmrc_content)
    out_file.close
  end
end

create_user_npmrc

# GGB: Print file names

# Parse the dependency files
puts "=> parsing dependency files"
parser = Dependabot::FileParsers.for_package_manager($package_manager).new(
  dependency_files: $files,
  repo_contents_path: $repo_contents_path,
  source: $source,
  credentials: $options[:credentials],
  reject_external_code: $options[:reject_external_code]
)

dependencies = cached_read("dependencies") { parser.parse }

if $options[:dependency_names].nil?
  dependencies.select!(&:top_level?)
else
  dependencies.select! do |d|
    $options[:dependency_names].include?(d.name.downcase)
  end
end

def update_checker_for(dependency)
  Dependabot::UpdateCheckers.for_package_manager($package_manager).new(
    dependency: dependency,
    dependency_files: $files,
    credentials: $options[:credentials],
    repo_contents_path: $repo_contents_path,
    requirements_update_strategy: $options[:requirements_update_strategy],
    ignored_versions: ignored_versions_for(dependency),
    security_advisories: security_advisories
  )
end

def ignored_versions_for(dep)
  if $options[:ignore_conditions].any?
    ignore_conditions = $options[:ignore_conditions].map do |ic|
      Dependabot::Config::IgnoreCondition.new(
        dependency_name: ic["dependency-name"],
        versions: [ic["version-requirement"]].compact,
        update_types: ic["update-types"]
      )
    end
    Dependabot::Config::UpdateConfig.new(ignore_conditions: ignore_conditions).
      ignored_versions_for(dep, security_updates_only: $options[:security_updates_only])
  else
    $update_config.ignored_versions_for(dep)
  end
end

def security_advisories
  $options[:security_advisories].map do |adv|
    vulnerable_versions = adv["affected-versions"] || []
    safe_versions = (adv["patched-versions"] || []) +
                    (adv["unaffected-versions"] || [])

    # Handle case mismatches between advisory name and parsed dependency name
    dependency_name = adv["dependency-name"].downcase
    Dependabot::SecurityAdvisory.new(
      dependency_name: dependency_name,
      package_manager: $package_manager,
      vulnerable_versions: vulnerable_versions,
      safe_versions: safe_versions
    )
  end
end

def peer_dependencies_can_update?(checker, reqs_to_unlock)
  checker.updated_dependencies(requirements_to_unlock: reqs_to_unlock).
    reject { |dep| dep.name == checker.dependency.name }.
    any? do |dep|
      original_peer_dep = ::Dependabot::Dependency.new(
        name: dep.name,
        version: dep.previous_version,
        requirements: dep.previous_requirements,
        package_manager: dep.package_manager
      )
      update_checker_for(original_peer_dep).
        can_update?(requirements_to_unlock: :own)
    end
end

def file_updater_for(dependencies)
  if dependencies.count == 1
    updated_dependency = dependencies.first
    prev_v = updated_dependency.previous_version
    prev_v_msg = prev_v ? "from #{prev_v} " : ""
    puts " => updating #{updated_dependency.name} #{prev_v_msg}to " \
         "#{updated_dependency.version}"
  else
    dependency_names = dependencies.map(&:name)
    puts " => updating #{dependency_names.join(', ')}"
  end

  Dependabot::FileUpdaters.for_package_manager($package_manager).new(
    dependencies: dependencies,
    dependency_files: $files,
    repo_contents_path: $repo_contents_path,
    credentials: $options[:credentials],
    options: $options[:updater_options]
  )
end

def security_fix?(dependency)
  security_advisories.any? do |advisory|
    advisory.fixed_by?(dependency)
  end
end

puts "=> updating #{dependencies.count} dependencies: #{dependencies.map(&:name).join(', ')}"

# rubocop:disable Metrics/BlockLength
checker_count = 0
dependencies.each do |dep|
  checker_count += 1
  checker = update_checker_for(dep)
  name_version = "\n=== #{dep.name} (#{dep.version})"
  vulnerable = checker.vulnerable? ? " (vulnerable 🚨)" : ""
  puts name_version + vulnerable

  puts " => checking for updates #{checker_count}/#{dependencies.count}"
  puts " => latest available version is #{checker.latest_version}"

  if $options[:security_updates_only] && !checker.vulnerable?
    if checker.version_class.correct?(checker.dependency.version)
      puts "    (no security update needed as it's not vulnerable)"
    else
      puts "    (can't update vulnerable dependencies for "\
           "projects without a lockfile as the currently "\
           "installed version isn't known 🚨)"
    end
    next
  end

  if checker.vulnerable?
    if checker.lowest_security_fix_version
      puts " => earliest available non-vulnerable version is "\
           "#{checker.lowest_security_fix_version}"
    else
      puts " => there is no available non-vulnerable version"
    end
  end

  latest_allowed_version = if checker.vulnerable?
                             checker.lowest_resolvable_security_fix_version
                           else
                             checker.latest_resolvable_version
                           end
  puts " => latest allowed version is #{latest_allowed_version || dep.version}"

  conflicting_dependencies = checker.conflicting_dependencies
  if conflicting_dependencies.any?
    puts " => The update is not possible because of the following conflicting "\
      "dependencies:"

    conflicting_dependencies.each do |conflicting_dep|
      puts "   #{conflicting_dep['explanation']}"
    end
  end

  if checker.up_to_date?
    puts "    (no update needed as it's already up-to-date)"
    next
  end

  requirements_to_unlock =
    if $options[:lockfile_only] || !checker.requirements_unlocked_or_can_be?
      if checker.can_update?(requirements_to_unlock: :none) then :none
      else :update_not_possible
      end
    elsif checker.can_update?(requirements_to_unlock: :own) then :own
    elsif checker.can_update?(requirements_to_unlock: :all) then :all
    else :update_not_possible
    end

  puts " => requirements to unlock: #{requirements_to_unlock}"

  if checker.respond_to?(:requirements_update_strategy)
    puts " => requirements update strategy: "\
         "#{checker.requirements_update_strategy}"
  end

  if requirements_to_unlock == :update_not_possible
    if checker.vulnerable? || $options[:security_updates_only]
      puts "    (no security update possible 🙅‍♀️)"
    else
      puts "    (no update possible 🙅‍♀️)"
    end
    next
  end

  updated_deps = checker.updated_dependencies(
    requirements_to_unlock: requirements_to_unlock
  )

  if peer_dependencies_can_update?(checker, requirements_to_unlock)
    puts "    (no update possible, peer dependency can be updated)"
    next
  end

  updater = file_updater_for(updated_deps)
  updated_files = updater.updated_dependency_files

  # Currently unused but used to create pull requests (from the updater)
  updated_deps.reject do |d|
    next false if d.name == checker.dependency.name
    next true if d.requirements == d.previous_requirements

    d.version == d.previous_version
  end

  if $options[:security_updates_only] &&
     updated_deps.none? { |d| security_fix?(d) }
    puts "    (updated version is still vulnerable 🚨)"
  end

  if $options[:write]
    updated_files.each do |updated_file|
      path = File.join(dependency_files_cache_dir, updated_file.name)
      puts " => writing updated file ./#{path}"
      dirname = File.dirname(path)
      FileUtils.mkdir_p(dirname) unless Dir.exist?(dirname)
      if updated_file.operation == Dependabot::DependencyFile::Operation::DELETE
        File.delete(path) if File.exist?(path)
      else
        File.write(path, updated_file.decoded_content)
      end
    end
  end

  updated_files.each do |updated_file|
    if updated_file.operation == Dependabot::DependencyFile::Operation::DELETE
      puts "deleted #{updated_file.name}"
    else
      original_file = $files.find { |f| f.name == updated_file.name }
      if original_file
        show_diff(original_file, updated_file)
      else
        puts "added #{updated_file.name}"
      end
    end
  end

  if $options[:pull_request]
    msg = Dependabot::PullRequestCreator::MessageBuilder.new(
      dependencies: updated_deps,
      files: updated_files,
      credentials: $options[:credentials],
      source: $source,
      commit_message_options: $update_config.commit_message_options.to_h,
      github_redirection_service: Dependabot::PullRequestCreator::DEFAULT_GITHUB_REDIRECTION_SERVICE
    ).message
    puts "Pull Request Title: #{msg.pr_name}"
    puts "--description--\n#{msg.pr_message}\n--/description--"
    puts "--commit--\n#{msg.commit_message}\n--/commit--"
  end
rescue StandardError => e
  handle_dependabot_error(error: e, dependency: dep)
end

StackProf.stop if $options[:profile]
StackProf.results("tmp/stackprof-#{Time.now.strftime('%Y-%m-%d-%H:%M')}.dump") if $options[:profile]

# rubocop:enable Metrics/BlockLength

# rubocop:enable Style/GlobalVars

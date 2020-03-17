# frozen_string_literal: true

require "dependabot/npm_and_yarn/update_checker/registry_finder"
require "dependabot/npm_and_yarn/native_helpers"
require "dependabot/shared_helpers"

module Dependabot
    module NpmAndYarn
        class FileUpdater
            class PnpmLockfileUpdater
                
                def initialize(dependencies:, dependency_files:, credentials:)
                    @dependencies = dependencies
                    @dependency_files = dependency_files
                    @credentials = credentials
                end

                def updated_pnpm_lock_content(pnpm_lock_file)
                    @updated_pnpm_lock_content ||= {}
                    if @updated_pnpm_lock_content[pnpm_lock_file.name]
                        return @updated_pnpm_lock_content[pnpm_lock_file.name]
                    end
            
                    updated_pnpm_lock(pnpm_lock_file)
            
                    # @updated_pnpm_lock_content[pnpm_lock_file.name] =
                    #     post_process_pnpm_lock_file(new_content)
                end


                def updated_pnpm_lock(pnpm_lock)
                        original_path = Dir.pwd
                        Dir.chdir(ENV["NODE_MODULES_ROOT"].to_s.strip)
                        write_temporary_dependency_files
                        lockfile_name = Pathname.new(pnpm_lock.name).basename.to_s
                        path = Pathname.new(pnpm_lock.name).dirname.to_s
                        response = run_current_pnpm_update(
                            path: path,
                            lockfile_name: lockfile_name
                        )
                        Dir.chdir(original_path)
                        return response
                        # updated_files.fetch(lockfile_name)
                rescue SharedHelpers::HelperSubprocessFailed => e
                    puts "#{e}"
                #     handle_pnpm_lock_updater_error(e, pnpm_lock)
                end
                
                # TODO: Currently works only for a single file (pnpms's shrinkwrap.yaml). Update the params to take a list of file paths that need to be reread 
                # after we run rush update.
                def run_pnpm_updater(path:, lockfile_name:)
                    #puts "#{Dir.pwd}"
                    SharedHelpers.run_helper_subprocess(
                        command: NativeHelpers.helper_path,
                        function: "rush:update",
                        args: [
                            Dir.pwd,
                            path+"/"+lockfile_name
                        # top_level_dependency_updates
                        ]
                    )

                end

                def run_current_pnpm_update(path:, lockfile_name:)
                    run_pnpm_updater(
                        path: path,
                        lockfile_name: lockfile_name,
                    )
                end

                def write_temporary_dependency_files(update_package_json: true)
                    # write_lockfiles
        
                    # File.write(".npmrc", npmrc_content)
                    # File.write(".yarnrc", yarnrc_content) if yarnrc_specifies_npm_reg?
                    
                    # TODO: Copy all the dependency files to the temp folder and run yarn update?

                    @dependency_files.each do |file|
                        path = file.name
                        FileUtils.mkdir_p(Pathname.new(path).dirname)

                        # Update package.json files. Copy others as is
                        updated_content =
                            if file.name.end_with?("package.json") && top_level_dependencies.any?
                                updated_package_json_content(file)
                            else
                                file.content
                            end
                    
                        File.write(file.name, updated_content)
                    end
                    
                end
                
                # def package_files
                #     dependency_files.select { |f| f.name.end_with?("package.json") }
                # end

                def top_level_dependencies
                    @dependencies.select(&:top_level?)
                end
                
                def npmrc_content
                    NpmrcBuilder.new(
                        credentials: credentials,
                        dependency_files: dependency_files
                    ).npmrc_content
                end
        
                def updated_package_json_content(file)
                    @updated_package_json_content ||= {}
                    @updated_package_json_content[file.name] ||=
                        PackageJsonUpdater.new(
                        package_json: file,
                        dependencies: @dependencies
                        ).updated_package_json.content
                end
            end
        end
    end
end

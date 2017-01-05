require 'xcodeproj'

module FrameworkGenerate
  class Target
    attr_accessor :name, :info_plist, :bundle_id, :header, :include_files, :exclude_files, :dependencies, :type, :test_target

    def initialize(name = nil, info_plist = nil, bundle_id = nil, header = nil, include_files = nil, exclude_files = nil, dependencies = nil, type = :framework, test_target = nil)
      @name = name
      @info_plist = info_plist
      @bundle_id = bundle_id
      @header = header
      @include_files = include_files
      @exclude_files = exclude_files
      @dependencies = dependencies
      @type = type
      @test_target = test_target

      yield(self) if block_given?
    end

    def to_s
      "Target<#{name}, #{info_plist}, #{bundle_id}, #{header}, #{include_files}, #{exclude_files}, #{dependencies}>"
    end

    def target_build_settings(settings)
      settings.delete('CODE_SIGN_IDENTITY')

      settings['INFOPLIST_FILE'] = @info_plist
      settings['PRODUCT_BUNDLE_IDENTIFIER'] = @bundle_id

      settings
    end

    def find_group(project, path)
      folder_path = File.dirname(path)
      project.main_group.find_subpath(folder_path, true)
    end

    def add_framework_header(project, target)
      return unless @header != nil
      header_path = @header
      header_file_group = find_group(project, header_path)
      header_file = header_file_group.new_reference(header_path)
      header_build_file = target.headers_build_phase.add_file_reference(header_file, true)
      header_build_file.settings ||= {}
      header_build_file.settings['ATTRIBUTES'] = ['Public']
    end

    def add_info_plist(project)
      info_plist_path = @info_plist
      info_plist_group = find_group(project, info_plist_path)
      has_info_plist = info_plist_group.find_file_by_path(info_plist_path)

      info_plist_group.new_reference(@info_plist) unless has_info_plist
    end

    def add_supporting_files(project, target)
      add_info_plist(project)
      return if target.test_target_type?
      add_framework_header(project, target)
    end

    def reject_excluded_files(exclude_files, path)
      exclude_files.each do |files_to_exclude|
        files_to_exclude.each do |file_to_exclude|
          return true if File.fnmatch(file_to_exclude, path)
        end
      end

      false
    end

    def add_source_files(project, target)
      exclude_files = @exclude_files.map do |files|
        Dir[files]
      end

      source_files = @include_files.map do |files|
        Dir[files].reject do |path|
          reject_excluded_files(exclude_files, path)
        end
      end

      source_files.each do |file_directory|
        file_directory.each do |path|
          source_file_group = find_group(project, path)
          has_source_file = source_file_group.find_file_by_path(path)
          unless has_source_file
            source_file = source_file_group.new_reference(path)
            target.source_build_phase.add_file_reference(source_file, true)
          end
        end
      end
    end

    def add_dependencies(project, target)
      return unless @dependencies != nil

      frameworks = @dependencies.reject do |name|
        !project.products.any? { |x| x.path == name }
      end

      frameworks = frameworks.map do |name|
        project.products.find { |x| x.path == name }
      end

      frameworks.each do |path|
        target.frameworks_build_phase.add_file_reference(path, true)
      end
    end

    def copy_carthage_frameworks(project, build_phase)
      script_file_path = File.join(File.dirname(__FILE__), 'copy-carthage-frameworks.sh')

      script_file = File.open(script_file_path)

      build_phase.shell_script = script_file.read

      script_file.close

      add_framework_to_copy_phase(project, build_phase)
    end

    def add_framework_to_copy_phase(project, build_phase)
      return unless @dependencies != nil

      frameworks = @dependencies.reject do |name|
        project.products.any? { |x| x.path == name }
      end

      frameworks.each do |path|
        build_phase.input_paths << path
      end
    end

    def create(project, language)
      name = @name
      type = @type

      # Target
      target = project.new(Xcodeproj::Project::Object::PBXNativeTarget)
      project.targets << target
      target.name = name
      target.product_name = name
      target.product_type = Xcodeproj::Constants::PRODUCT_TYPE_UTI[type]
      target.build_configuration_list = Xcodeproj::Project::ProjectHelper.configuration_list(project, :osx, nil, type, language.type)

      add_supporting_files(project, target)
      add_source_files(project, target)

      target.build_configurations.each do |configuration|
        target_build_settings(configuration.build_settings)
      end

      # Product
      product = project.products_group.new_product_ref_for_target(name, type)
      target.product_reference = product

      # Build phases
      target.build_phases << project.new(Xcodeproj::Project::Object::PBXSourcesBuildPhase)
      target.build_phases << project.new(Xcodeproj::Project::Object::PBXResourcesBuildPhase)
      target.build_phases << project.new(Xcodeproj::Project::Object::PBXFrameworksBuildPhase)

      # Dependencies
      add_dependencies(project, target)

      # Copy frameworks to test target
      if target.test_target_type?
        build_phase = target.new_shell_script_build_phase('Copy Carthage Frameworks')
        copy_carthage_frameworks(project, build_phase)
      end

      target
    end
  end
end

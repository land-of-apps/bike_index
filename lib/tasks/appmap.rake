# frozen_string_literal: true

lambda do
  def relative_path(file)
    file.index(Dir.pwd) == 0 ? file[Dir.pwd.length+1..-1] : file
  end

  namespace :appmap do
    AppMap.configuration.swagger_config.project_version = [ 'v3', `git rev-parse --short HEAD`.strip ].join('_')
    AppMap::Swagger::RakeTasks.define_tasks

    test_runner = lambda do |test_files|
      require "shellwords"
      file_list = test_files.map(&:shellescape).join(" ")
      env = { 'RAILS_ENV' => 'test', 'APPMAP' => 'true', 'DISABLE_SPRING' => '1' }
      system(env, "bundle exec rspec --format documentation -t '~empty' -t '~large' -t '~unstable' #{file_list}")
    end

    AppMap::Depends::RakeTasks.define_tasks test_runner: test_runner

    task :architecture do
      test_files = File.read('ARCHITECTURE.md').scan(/\[[^\(]+\(([^\]]+)\)\]\(.*\.appmap\.json\)/).flatten
      test_files = test_files.map(&method(:relative_path)).uniq.map(&:shellescape)

      env = { 'RAILS_ENV' => 'test', 'APPMAP' => 'true', 'DISABLE_SPRING' => '1' }
      exit 1 unless system(env, "bundle exec rspec --format documentation #{test_files.join(' ')}")
    end

    task :architecture do
    end
  end

  desc 'Bring AppMaps up to date with local file modifications, and updated derived data such as Swagger files'
  task :appmap => :'appmap:depends:update'
end.call if %w[test development].member?(Rails.env)

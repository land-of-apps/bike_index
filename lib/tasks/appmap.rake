# frozen_string_literal: true

lambda do
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
  end

  desc 'Bring AppMaps up to date with local file modifications, and updated derived data such as Swagger files'
  task :appmap => :'appmap:depends:update'
end.call if %w[test development].member?(Rails.env)

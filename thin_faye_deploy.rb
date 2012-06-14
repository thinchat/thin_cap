require "bundler/capistrano"
require 'capistrano/ext/multistage'

set :stages, %w(production development staging)
set :default_stage, "development"

set :application, "thin_faye"
set :user, "deployer"
set :deploy_to, "/home/#{user}/apps/#{application}"
set :deploy_via, :remote_cache
set :use_sudo, false

set :scm, "git"
set :repository, "git@github.com:thinchat/#{application}.git"
set :branch, "master"

default_run_options[:pty] = true
ssh_options[:forward_agent] = true

namespace :deploy do
  desc "Start faye"
  task :start, roles: :app, except: {no_release: true} do
    sudo "service god-service start faye_server"
  end

  desc "Restart faye"
  task :restart, roles: :app, except: {no_release: true} do
    sudo "service god-service restart faye_server"
  end

  desc "Stop faye"
  task :stop, roles: :app, except: {no_release: true} do
    sudo "service god-service stop faye_server"
  end

  task :create_release_dir, :except => {:no_release => true} do
    run "mkdir -p #{fetch :releases_path}"
  end
  before "deploy:update_code", "deploy:create_release_dir"

  desc "Deploy to a server for the first time (assumes you've run 'cap stage-name provision')"
  task :fresh, roles: :app do
    puts "Deploying to fresh server..."
  end
  after "deploy:fresh", "deploy:setup", "deploy", "deploy:start_god"

  desc "Start the God service on the server"
  task :start_god, roles: :app do
    sudo "service god-service start"
  end

  desc "Push secret files"
  task :secret, roles: :app do
    run "mkdir #{release_path}/config/secret"
    transfer(:up, "config/secret/campfire_token.rb", "#{release_path}/config/secret/campfire_token.rb", :scp => true)
    transfer(:up, "config/secret/redis_password.rb", "#{release_path}/config/secret/redis_password.rb", :scp => true)
    require "./config/secret/redis_password.rb"
    sudo "/usr/bin/redis-cli config set requirepass #{REDIS_PASSWORD}"
  end
  after "deploy:update_code", "deploy:secret"

  desc "Install environment-specific god configuration"
  task :god_config, roles: :app do
    run "cp #{release_path}/config/god/faye_server.#{rails_env}.god #{release_path}/config/faye_server.god"
  end
  after "deploy:secret", "deploy:god_config"

  desc "Make sure local git is in sync with remote."
  task :check_revision, roles: :web do
    unless `git rev-parse HEAD` == `git rev-parse origin/master`
      puts "WARNING: HEAD is not the same as origin/master"
      puts "Run `git push` to sync changes."
      exit
    end
  end
  before "deploy", "deploy:check_revision"
end

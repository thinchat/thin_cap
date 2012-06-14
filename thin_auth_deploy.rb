require "bundler/capistrano"
require 'capistrano/ext/multistage'

set :stages, %w(production development staging)
set :default_stage, "development"

set :application, "thin_auth"
set :user, "deployer"
set :deploy_to, "/home/#{user}/apps/#{application}"
set :deploy_via, :remote_cache
set :use_sudo, false
set :scm, "git"
set :repository, "git@github.com:thinchat/#{application}.git"

default_run_options[:pty] = true
ssh_options[:forward_agent] = true

after "deploy", "deploy:cleanup" # keep only the last 5 releases

def current_git_branch
  `git symbolic-ref HEAD`.gsub("refs/heads/", "")
end

def prompt_with_default(message, default)
  response = Capistrano::CLI.ui.ask "#{message} Default is: [#{default}] : "
  response.empty? ? default : response
end

def set_branch
  if current_git_branch != "master"
    set :branch, ENV['BRANCH'] || prompt_with_default("Enter branch to deploy, or ENTER for default.", "#{current_git_branch.chomp}")
  else
    set :branch, ENV['BRANCH'] || "#{current_git_branch.chomp}"
  end
end

set :branch, set_branch

namespace :deploy do
  %w[start stop restart].each do |command|
    desc "#{command} unicorn server"
    task command, roles: :app, except: {no_release: true} do
      run "/etc/init.d/unicorn_#{application} #{command}"
    end
  end

  desc "Deploy to a server for the first time (assumes you've run 'cap stage-name provision')"
  task :fresh, roles: :app do
    puts "Deploying to fresh server..."
  end
  after "deploy:fresh", "deploy:setup", "deploy", "deploy:nginx:restart"

  desc "Create the database"
  task :create_database, roles: :app do
    run "cd #{release_path} && bundle exec rake RAILS_ENV=#{rails_env} db:create"
  end
  after "deploy:symlink_config", "deploy:create_database"
  after "deploy:create_database", "deploy:migrate"

  desc "Setup unicorn configuration"
  task :setup_config, roles: :app do
    sudo "ln -nfs #{current_path}/config/unicorn/unicorn_#{rails_env}_init.sh /etc/init.d/unicorn_#{application}"
  end
  after "deploy:setup", "deploy:create_release_dir", "deploy:setup_config"

  task :create_release_dir, :except => {:no_release => true} do
    run "mkdir -p #{fetch :releases_path}"
  end

  desc "Symlink shared/database.yml to config/database.yml"
  task :symlink_config, roles: :app do
    run "ln -nfs #{shared_path}/config/database.yml #{release_path}/config/database.yml"
  end
  after "deploy:finalize_update", "deploy:symlink_config"

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

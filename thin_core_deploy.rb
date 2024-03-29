require "bundler/capistrano"
require 'capistrano/ext/multistage'

set :stages, %w(production development staging)
set :default_stage, "development"

set :application, "thin_core"
set :user, "deployer"
set :deploy_to, "/home/#{user}/apps/#{application}"
set :deploy_via, :remote_cache
set :use_sudo, false
set :ssh_options, { :forward_agent => true }
set :git_enable_submodules,1
set :scm, "git"
set :repository, "git@github.com:thinchat/#{application}.git"

default_run_options[:pty] = true
ssh_options[:forward_agent] = true

after "deploy", "deploy:nginx:config", "deploy:cleanup", "deploy:workers:start" # keep only the last 5 releases

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
    desc "#{command} #{application}"
    task command, roles: :app, except: {no_release: true} do
      sudo "god load #{current_path}/config/god/#{application}.#{rails_env}.god"
      sudo "god #{command} #{application}"
    end
  end

  namespace :workers do
    %w[start stop restart].each do |command|
      desc "#{command} core_resque_worker"
      task command, roles: :app, except: {no_release: true} do
        sudo "god load #{current_path}/config/god/#{application}.#{rails_env}.god"
        sudo "god #{command} core_resque_worker"
      end
    end
  end

  desc "Deploy to Vagrant (assumes you've run 'rake vagrant:setup')"
  task :vagrant, roles: :app do
    puts "Deploying to Vagrant..."
  end
  after "deploy:vagrant", "deploy:setup", "deploy", "deploy:nginx:restart"

  desc "Deploy to a server for the first time (assumes you've run 'cap stage-name provision')"
  task :fresh, roles: :app do
    puts "Deploying to fresh server..."
  end
  after "deploy:fresh", "deploy:setup", "deploy", "deploy:nginx:restart"

  desc "Push ssh keys to authorized_keys"
  task :keys, roles: :app do
    run "mkdir /home/deployer/.ssh"
    transfer(:up, "config/secret/authorized_keys", "/home/deployer/.ssh/authorized_keys", :scp => true)
    sudo "chmod 700 /home/deployer/.ssh"
    sudo "chmod 644 /home/deployer/.ssh/authorized_keys"
    sudo "chown -R deployer:admin /home/deployer"
  end

  desc "Create god directories"
  task :god_dir, roles: :app do
    sudo "mkdir /etc/god"
    sudo "mkdir /var/log/god"
  end
  after "provision", "deploy:god_dir"

  desc "Set hostname for server"
  task :hostname, roles: :app do
    sudo "echo '#{rails_env}' > /home/deployer/hostname"
    sudo "mv /home/deployer/hostname /etc/hostname"
    sudo "hostname -F /etc/hostname"
    sudo "awk -v \"n=2\" -v \"s=127.0.0.1       #{rails_env}.thinchat.com        #{rails_env}\" '(NR==n) { print s } 1' /etc/hosts > /home/deployer/new_hosts"
    sudo "mv /home/deployer/new_hosts /etc/hosts"
  end

  desc "Push god configuration"
  task :god, roles: :app do
    sudo "chown -R deployer:admin /var/log/god"
    transfer(:up, "config/god/master.conf", "/home/deployer/master.conf", :scp => true)
    transfer(:up, "config/god/god-initd.sh", "/home/deployer/god-initd.sh", :scp => true)
    sudo "mv /home/deployer/master.conf /etc/god/master.conf"
    sudo "mv /home/deployer/god-initd.sh /etc/god/god-initd.sh"
    sudo "chmod +x /etc/god/god-initd.sh"
    sudo "cp /etc/god/god-initd.sh /etc/init.d/god-service"
    sudo "update-rc.d god-service defaults"
    sudo "service god-service start"
  end

  desc "Create the database"
  task :create_database, roles: :app do
    run "cd #{release_path} && bundle exec rake RAILS_ENV=#{rails_env} db:create"
  end
  after "deploy:db_config", "deploy:create_database"
  after "deploy:create_database", "deploy:migrate"

  desc "Setup unicorn configuration"
  task :setup_config, roles: :app do
    sudo "ln -nfs #{current_path}/config/unicorn/unicorn_#{rails_env}_init.sh /etc/init.d/unicorn_#{application}"
  end
  after "deploy:setup", "deploy:create_release_dir", "deploy:setup_config"

  task :create_release_dir, :except => {:no_release => true} do
    run "mkdir -p #{fetch :releases_path}"
  end

  desc "Copy secret/database.yml to config/database.yml"
  task :db_config, roles: :app do
    run "cp #{release_path}/config/secret/database.#{application}.yml #{release_path}/config/database.yml"
  end
  before "deploy:assets:precompile", "deploy:db_config"

  desc "Make sure local git is in sync with remote."
  task :check_revision, roles: :web do
    unless `git rev-parse HEAD` == `git rev-parse origin/#{branch}`
      puts "WARNING: HEAD is not the same as origin/#{branch}"
      puts "Run `git push` to sync changes."
      exit
    end
  end
  before "deploy", "deploy:check_revision"

  namespace :nginx do
    desc "Restart Nginx"
    task :restart, roles: :app do
      sudo "service nginx restart"
    end

    desc "Copy nginx.conf to thinchat/config and symlink to /etc/nginx/sites-enabled/default "
    task :config, roles: :app do
      sudo "ln -nfs #{current_path}/config/nginx.conf /etc/nginx/sites-enabled/default"
    end
  end

  namespace :mysql do
    desc "Copy my.conf to /etc/mysql/my.cnf"
    task :config, roles: :app do
      transfer(:up, "config/my.cnf", "/home/deployer/my.cnf", :scp => true)
      sudo "cp /home/deployer/my.cnf /etc/mysql/my.cnf"
      sudo "service mysql restart"
    end
  end
end

desc "Provision server"
task :provision do
  response = Capistrano::CLI.ui.ask "Are you sure you want to provision this server? [y/n]"
  if response == 'y' || response == 'yes'
    set :user, "root"
    transfer(:up, "config/vagrant/setup.sh", "setup.sh", :scp => true)
    sudo "chmod +x setup.sh"
    sudo "./setup.sh"
  else
    puts "Phew. That was a close one eh?"
  end
end
after "provision", "deploy:keys", "deploy:hostname", "deploy:mysql:config", "deploy:god"

namespace :god do
  desc "Status of god tasks"
  task :status, roles: :app do
    sudo "god status"
  end

  desc "Load god file"
  task :load_config, roles: :app do
    sudo "god load #{current_path}/config/god/#{application}.#{rails_env}.god"
  end
end

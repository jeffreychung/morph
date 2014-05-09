require 'capistrano/ext/multistage'
require 'rvm/capistrano'
require 'rvm/capistrano/gem_install_uninstall'
require 'bundler/capistrano'

set :application, "morph"
set :stages, %w(production)

set :repository, 'git@github.com:sebbacon/morph.git'

set :rvm_bin, '/home/openc/.rvm/bin/rvm'
set :rvm_ruby_string, '2.0.0-p353'
set :rvm_ruby_version, '2.0.0-p353'

set :user, 'openc'
set :deploy_to, "/home/openc/sites/#{application}"
set :use_sudo, false

set :scm, :git

ssh_options[:forward_agent] = true

default_run_options[:pty] = true

def disable_rvm_shell(&block)
  old_shell = self[:default_shell]
  self[:default_shell] = nil
  yield
  self[:default_shell] = old_shell
end

namespace :deploy do
  task :install_apt_dependencies do
    disable_rvm_shell do
      sudo "echo deb http://ftp.us.debian.org/debian wheezy-backports main | sudo tee  /etc/apt/sources.list.d/backports.list"
      sudo "echo deb http://get.docker.io/ubuntu docker main | sudo tee /etc/apt/sources.list.d/docker.list"
      sudo "apt-key adv --keyserver keyserver.ubuntu.com --recv-keys 36A1D7869245C8950F966E92D8576A8BA88D21E9"
      sudo "apt-get update"
      # For rvm
      sudo "apt-get install bzip2 gawk g++ gcc make libc6-dev libreadline6-dev  zlib1g-dev libssl-dev libyaml-dev libsqlite3-dev sqlite3 autoconf libgdbm-dev libncurses5-dev automake libtool bison pkg-config libffi-dev -y"
      # For ?
      sudo "apt-get install curl git-core libcurl3 libcurl3-gnutls libcurl4-openssl-dev -y"
      # For morph
      sudo "apt-get install mysql-server redis-server mitmproxy sqlite3 lxc-docker curl libmysqlclient-dev nodejs"
    end
  end

  desc "Install bundler"
  task :install_bundler do
    ENV['GEM'] = 'bundler'
    find_and_execute_task("rvm:install_gem")
  end

  desc "Uploads a new Nginx configuration file and reloads the config"
  task :update_nginx_config, :roles => :web do
    generate_nginx_config
    reload_nginx_config
  end

  desc "Creates the Nginx config from a template and puts it in the proper location and then tests it"
  task :generate_nginx_config, :roles => :web do
    conf_file = File.read(File.join(File.dirname(__FILE__), "nginx_#{stage}.conf"))
    put(conf_file, "#{shared_path}/tmp/new_nginx.conf") # upload new conf file
    sudo "mv /etc/nginx/nginx.conf /etc/nginx/nginx_BACKUP.conf" # backup old file
    sudo "mv #{shared_path}/tmp/new_nginx.conf /etc/nginx/nginx.conf" # move new one in it's place
    sudo "/usr/sbin/nginx -t -c /etc/nginx/nginx.conf" # check new conf file is OK
  end

  desc "Tell Nginx to reload already loaded configuration file"
  task :reload_nginx_config, :roles => :web do
    sudo "kill -HUP `cat /var/run/nginx.pid`"
  end

  desc "create folders necessary to run site"
  task :create_folder_structure do
    run "mkdir -p #{shared_path}/tmp"
  end

  desc "Create symlinks to shared folder"
  task :update_symlinks do
    run "ln -sf #{shared_path}/config/database.yml #{release_path}/config/database.yml"
    run "ln -sf #{shared_path}/config/sync.yml #{release_path}/config/sync.yml"
    run "ln -sf #{shared_path}/config/morph-dotenv #{release_path}/.env"
  end

  desc "Updates secret_token.rb from SAN"
  task :update_config_files do
    run "mkdir -p #{shared_path}/config"
    run "cp /oc/openc/secure_config/morph-database.yml #{shared_path}/config/database.yml"
    run "cp /oc/openc/secure_config/morph-sync.yml #{shared_path}/config/sync.yml"
    run "cp /oc/openc/secure_config/morph-dotenv #{shared_path}/config/morph-dotenv"
  end
end

#before 'deploy:setup', 'deploy:install_apt_dependencies'
before 'deploy:setup', 'rvm:install_rvm'
before 'deploy:setup', 'rvm:install_ruby'
before 'deploy:setup', 'deploy:install_bundler'
after 'deploy:update_code', 'deploy:create_folder_structure'
after 'deploy:update_code', 'deploy:update_symlinks'

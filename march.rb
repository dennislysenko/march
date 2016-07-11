require 'yaml'
require 'set'
require 'net/scp'
require 'net/ssh'
require 'tempfile'

current_stage_name = ARGV[0]
if current_stage_name.nil?
  raise 'No stage specified: please run `march STAGE COMMAND`, where stage is something like production/staging'
end

VALID_COMMANDS = %w[deploy logs]

command = ARGV[1]
if command.nil?
  raise "No command specified: please run `march STAGE #{VALID_COMMANDS.join('|')}"
end

YAML_PATH='march/config.yml'

raise 'No march/config.yml found' unless File.exists? YAML_PATH
march_config = YAML::load_file(YAML_PATH)

deploy_path = march_config['deploy_path']
raise 'Please specify deploy_path in march/config.yml' if deploy_path.nil?

go_binary_name = march_config['go_binary_name']
raise 'Please specify go_binary_name in march/config.yml' if go_binary_name.nil?

env = march_config['env']
env = {} if env.nil?

# time for stages yeaaaah
server_defaults = march_config['server_defaults']
# p server_defaults
stages = march_config['stages']
raise 'No stages specified in march/config.yml' if stages.nil? || stages.empty?

REQUIRED_SERVER_CONFIG_KEYS = Set.new(%w[host go_os user port])
current_stage_servers = nil
stages.each do |stage_name, stage_config|
  raise "No servers on stage #{stage_name}" if stage_config['servers'].nil?
  servers = stage_config['servers']

  if stage_name == current_stage_name
    current_stage_servers = servers
  end

  servers.each.with_index do |server_config, index|
    server_config = server_defaults.merge(server_config) # have stage_config overwrite defaults

    specified_keys = server_config.keys

    # puts "#{stage_name}.servers[#{index}] => #{server_config}"

    missing_keys = REQUIRED_SERVER_CONFIG_KEYS - specified_keys
    unless missing_keys.empty?
      raise "Server \##{index} #{stage_name} was missing #{missing_keys.to_a.join(', ')}"
    end

    servers[index] = server_config
  end
end

puts current_stage_servers

class ServerConfig < Struct.new(:host, :user, :port, :go_os, :deploy_path)
  def registered_deploy_timestamps
    tempfile = Tempfile.new('deploy_name')
    Net::SCP.download!(host, user, "#{deploy_path}/.march/deploy_timestamps", tempfile.path, ssh: { port: port })
    contents = tempfile.read
    # coalesce empty string to nil
    if contents == '' || contents.nil?
      []
    else
      contents.split("\n")
    end
  rescue Net::SCP::Error
    nil
  end

  def add_latest_deploy_timestamp(timestamp)
    timestamps = registered_deploy_timestamps
    timestamps.insert(0, timestamp)
    tempfile = Tempfile.new('timestamps')
    tempfile.write(timestamps.join("\n"))
    tempfile.rewind

    Net::SSH.start(server.host, server.user, port: server.port) do |ssh|
      ssh.exec! "mkdir -p #{deploy_path}/.march/"
    end

    Net::SCP.upload!(host, user, tempfile.path, "#{deploy_path}/.march/deploy_timestaps", ssh: { port: port })
  end

  def delete_stale_deploys(deploys_to_keep: 5)
    deletes = registered_deploy_timestamps.slice(deploys_to_keep)
    Net::SSH.start(server.host, server.user, port: server.port) do |ssh|
      deletes.each do |timestamp|
        # let's be really careful
        raise if deploy_path.nil?
        raise if timestamp.nil?
        full_path = "#{deploy_path}/#{timestamp}"
        raise if full_path == '/'

        ssh.exec! "rm -rf #{full_path}"
      end
    end
  end
end

server_configs = current_stage_servers.map do |server|
  ServerConfig.new(server['host'], server['user'], server['port'], server['go_os'], deploy_path)
end

p server_configs

case command.to_sym
when :deploy
  puts 'deploying...'

  puts 'building...'
  # Build the binary
  required_oses = server_configs.map(&:go_os).uniq
  Dir.mkdir 'march/build' unless Dir.exist? 'march/build'
  required_oses.each do |os|
    system("/bin/bash -c \"GOOS=#{os} go build -o march/build/#{os}\"")
  end

  new_deploy_timestamp = Time.now.to_i.to_s
  remote_assets_path = "#{deploy_path}/#{new_deploy_timestamp}/assets"

  puts 'writing launch script...'
  # Write the launch script
  env_string = env.to_a.map { |pair| pair.join('=') }.join(' ')
  script = <<-eos
  #!/bin/bash
  while true; do
    echo "Starting #{go_binary_name} process..." >> #{deploy_path}/#{new_deploy_timestamp}/#{go_binary_name}.log
    MARCH_ASSETS_PATH=#{remote_assets_path} #{env_string} #{deploy_path}/#{new_deploy_timestamp}/#{go_binary_name} 2>&1 >> #{deploy_path}/#{new_deploy_timestamp}/#{go_binary_name}.log
  done
  eos
  local_launch_script_path = "march/build/#{go_binary_name}.sh"
  File.open(local_launch_script_path, 'w') { |f| f.write(script) }

  puts 'uploading...'
  server_configs.each do |server|
    existing_deploy_timestamp = server.registered_deploy_timestamps.first

    Net::SSH.start(server.host, server.user, port: server.port) do |ssh|
      ssh.exec! "mkdir -p #{deploy_path}/#{new_deploy_timestamp}"
    end

    puts 'uploading binary...'
    local_binary_path = "march/build/#{server.go_os}"
    remote_binary_path = "#{deploy_path}/#{new_deploy_timestamp}/#{go_binary_name}"
    puts "#{local_binary_path} => #{remote_binary_path}"
    Net::SCP.upload!(server.host, server.user, local_binary_path, remote_binary_path, ssh: { port: server.port })

    puts 'uploading launch script...'
    Net::SCP.upload!(server.host, server.user, local_launch_script_path,
                     "#{deploy_path}/#{new_deploy_timestamp}/#{go_binary_name}.sh",
                     ssh: { port: server.port })

    if Dir.exists? 'assets'
      puts 'copying assets...'
      Net::SCP.upload!(server.host, server.user, 'assets', remote_assets_path,
                       ssh: { port: server.port }, recursive: true)
    end

    puts 'starting ssh session...'
    Net::SSH.start(server.host, server.user, port: server.port) do |ssh|
      def signal_first_match_for(matcher, ssh, signal)
        output = find_matches_for(matcher, ssh)
        pid_matches = output.match(/[1-9]\d+/)
        unless pid_matches.nil?
          puts "killing existing instance of #{matcher}..."
          pid = pid_matches.to_a.first
          ssh.exec!("kill #{signal} #{pid}")
        end
      end

      def find_matches_for(matcher, ssh)
        ssh.exec!("ps aux | grep \"#{matcher}\" | grep -v \"grep #{matcher}\"")
      end

      def signal_all_processes_matching(matcher, ssh, signal)
        signal_first_match_for(matcher, ssh, signal) until find_matches_for(matcher, ssh).empty?
      end

      def sigkill_all_processes_matching(matcher, ssh)
        signal_all_processes_matching matcher, ssh, '-9'
      end

      def sigint_all_processes_matching(matcher, ssh)
        signal_all_processes_matching matcher, ssh, '-2'
      end

      unless existing_deploy_timestamp.nil?
        sigkill_all_processes_matching "#{deploy_path}/#{go_binary_name}.sh$", ssh # kill the parent script to prevent the child restarting when we interrupt it
        sigint_all_processes_matching "#{deploy_path}/#{go_binary_name}$", ssh # interrupt the child script
        sigkill_all_processes_matching "#{deploy_path}/#{go_binary_name}.log$", ssh # kill all log processes started by march

        sigkill_all_processes_matching "#{deploy_path}/#{existing_deploy_timestamp}/#{go_binary_name}.sh$", ssh # kill the parent script to prevent the child restarting when we interrupt it
        sigint_all_processes_matching "#{deploy_path}/#{existing_deploy_timestamp}/#{go_binary_name}$", ssh # interrupt the child script
        sigkill_all_processes_matching "#{deploy_path}/#{existing_deploy_timestamp}/#{go_binary_name}.log$", ssh # kill all log processes started by march
      end

      puts 'launching binary...'

      ssh.exec!("chmod +x #{deploy_path}/#{new_deploy_timestamp}/#{go_binary_name}.sh")
      launch_command = "/usr/bin/nohup #{deploy_path}/#{new_deploy_timestamp}/#{go_binary_name}.sh > nohup.out &"
      # puts launch_command
      ssh.exec!(launch_command) do |_, stream, data|
        stdout << data if stream == :stdout
        STDERR << data if stream == :stderr
      end
    end
  end

  puts 'successfully deployed, check logs for more details'
when :logs
  server = server_configs.first
  begin
    session = nil
    channel = nil

    trap 'INT' do
      session.shutdown!
      exit!
    end

    existing_deploy_timestamp = server.registered_deploy_timestamps.first
    raise "No deployed version, please call `march #{current_stage_name} deploy` first!" if existing_deploy_timestamp.nil?

    Net::SSH.start(server['host'], server['user'], port: server['port']) do |ssh|
      session = ssh

      channel = ssh.exec("tail -f -n 50 #{deploy_path}/#{existing_deploy_timestamp}/#{go_binary_name}.log") do |ch, stream, data|
        puts data if stream == :stdout
      end
      channel.wait
    end
  rescue SystemExit, Interrupt
    puts 'Received sigint. Aborting.'
    session.shutdown!
    exit!
  end
else
  raise 'Invalid command; this should never execute as the validation should have stopped this above'
end
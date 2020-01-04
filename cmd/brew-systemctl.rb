# frozen_string_literal: true

#:  * `systemctl` <subcommand>:
#:
#:  Manage background services with Linux' `systemctl`(1) daemon manager
#:      --all                           run <subcommand> on all services.
#:
#:  `brew systemctl list`
#:      List all running services (from all users).
#:
#:  `brew systemctl run` (<formulae>|`--all`)
#:      Run the services of <formulae> without registering them to launch at login.
#:
#:  `brew systemctl start` (<formulae>|`--all`)
#:      Start the services of <formulae> immediately and register them to launch at login.
#:
#:  `brew systemctl stop` (<formulae>|`--all`)
#:      Stop the services of <formulae> immediately and unregister them from launching at login.
#:
#:  `brew systemctl restart` (<formulae>|`--all`)
#:      Stop (if necessary) and start the services of <formulae> immediately and register them to launch at login.
#:
#:  `brew systemctl cleanup`
#:      Remove all unused services.
#:
#:  `brew systemctl purge`
#:      Remove all services.
#:
#:  Operate on `~/.config/systemd/user` (started at login).

module Kernel

  def passthru(cmd, env = {})
    if ARGV.verbose?
      puts "Executing `#{cmd}`"
    end

    result = nil
    IO.popen(env, cmd, :err => '/dev/null') do |io|
      result = io.read
    end
    return result if $?.exitstatus.zero?

    raise(ErrorDuringExecution.new([cmd], status: $?))
  end
  
  def bin
    'brew systemctl'
  end

end

class SystemCtlPlistToServiceFileConverter

  def convert(definition)
    service = {
      :Unit => {},
      :Service => {},
      :Install => {},
    }
    
    unsupported_keys = []
    definition.plist.each do |key, value|
      case key
      when 'KeepAlive'
        service[:Service][:Restart] = 'always'
      when 'Label'
        service[:Unit][:Description] = value
      when 'ProgramArguments'
        service[:Service][:ExecStart] = value.map { |arg| "'#{arg}'" }.join(' ')
      when 'RunAtLoad'
        # AFAIK, there is neither and equivalent nor a real need for this.
      when 'StandardErrorPath'
        service[:Service][:StandardError] = "file:#{value}"
      when 'WorkingDirectory'
        service[:Service][:WorkingDirectory] = value
      else
        unsupported_keys.push(key)
      end
    end

    unless unsupported_keys.empty?
      opoo("The following plist keys are not yet supported, and were ignored: '#{unsupported_keys.join("', '")}'.")
    end
    
    service[:Service][:Type] = 'simple'
    service[:Install][:WantedBy] = 'default.target'
    
    service_lines = []
    service.each do |section, values|
      service_lines.push("[#{section}]")
      values.each do |key, value|
        service_lines.push("#{key}=#{value}")
      end
      service_lines.push('')
    end

    service_lines.join("\n")
  end  

end

class SystemCtlCommandline

  def initialize(systemctl)
    @systemctl = systemctl
  end

  def invoke(*args)
    cmd = args.unshift(@systemctl).join(' ')
    passthru(cmd, {
      'XDG_RUNTIME_DIR' => "/run/user/#{Process.uid}"
    })
  end

end

class SystemCtlStandardRunInfoGenerator

  def initialize(commandline)
    @commandline = commandline
  end

  def run_info(service_id)
    snapshot = run_snapshot
    {
      user: snapshot.key?(service_id) ? snapshot[service_id][:user] : nil,
      status: snapshot.key?(service_id) ? snapshot[service_id][:status] : :unknown
    }
  end
  
  def reset
    @run_snapshot = nil
  end
  
  private
  
  def run_snapshot
    @run_snapshot ||= {}
      .merge(snapshot_for_bus('user'))
      .merge(snapshot_for_bus('system'))
  end
  
  def snapshot_for_bus(bus)
    hash = {}
    uid  = ('system' == bus) ? 0 : Process.uid
    args = "--#{bus} --all --type=service --no-pager --no-legend list-units"
    lines = @commandline.invoke(args).lines

    lines.each do |line|
      items = line.split
      service_id = items[0].sub('.service', '')
      hash[service_id] ||= {
        user: uid,
        status: convert_status(items[1], items[2], items[3])
      }
    end
    hash
  end
  
  def convert_status(load, active, sub)
    return :unknown if ('not-found' == load)
    case sub
      when 'running'
        return :started
      when 'failed'
        return :error
      when 'exited'
        return :stopped
      else
        return :unknown
    end
  end

end

class SystemCtlExperimentalRunInfoGenerator

  def initialize(commandline)
    @commandline = commandline
  end
 
  def run_info(service_id)
    snapshot = run_snapshot
    {
      user: snapshot.key?(service_id) ? snapshot[service_id] : nil,
      status: snapshot.key?(service_id) ? :started : :stopped,
    }
  end
  
  def reset
    @run_snapshot = nil
  end
  
  private
  
  def run_snapshot
    @run_snapshot ||= begin
      snapshot = {}
      uid = nil
      lines = @commandline.invoke("status --no-pager --no-legend").lines
      lines.each do |line|
        line.match(/system\.slice/) { |match| uid = 0 }
        line.match(/user-([\d]+)\.slice/) { |match| uid = match[1].to_i }
        line.match(/([\w+-.@]+)\.service/) do |match|
          raise("This should not happen. `#{@systemctl} status` output might differ from what is expected.") unless uid
          service_id = match[1]
          snapshot[service_id] = uid
        end
      end
      snapshot
    end
  end

end
  
class SystemCtlDriver

  def self.create
    commandline = SystemCtlCommandline.new(which('systemctl'))
    new(
      SystemCtlPlistToServiceFileConverter.new,
      # SystemCtlStandardRunInfoGenerator.new(commandline),
      SystemCtlExperimentalRunInfoGenerator.new(commandline),
      commandline
    )
  end
  
  def initialize(converter, generator, commandline)
    @converter = converter
    @generator = generator
    @commandline = commandline
  end
  
  def run(definition)
    start(definition)
  end

  def stop(definition)
    invoke('stop', get_real_service_id(definition.id))
    @generator.reset
  end
  
  def start(definition)
    install(definition)
    invoke('start', get_real_service_id(definition.id))
    @generator.reset
  end
  
  def restart(definition)
    install(definition)
    invoke('restart', get_real_service_id(definition.id))
    @generator.reset
  end
  
  def register(definition)
    install(definition)
    invoke('enable', get_real_service_id(definition.id))
  end
  
  def unregister(definition)
    was_installed = installed?(definition)
    install(definition)
    invoke('disable', get_real_service_id(definition.id))
    uninstall(definition) unless was_installed
  end
  
  def install(definition)
    get_service_file_path(definition).write(@converter.convert(definition)) unless installed?(definition)
    invoke('daemon-reload')
  end
  
  def installed?(definition)
    get_service_file_path(definition).exist?
  end

  def uninstall(definition)
    get_service_file_path(definition).delete if installed?(definition)
    invoke('daemon-reload')
  end

  def running?(definition)
    run_info(definition).running?
  end
  
  def run_info(definition)
    service_id = get_real_service_id(definition.id)
    ServiceRunInfo.new(definition, -> do
      info = @generator.run_info(service_id)
      info[:user] = Etc.getpwuid(info[:user].nil? ? Process.uid : info[:user].to_i)
      file = get_service_file_path(definition, info[:user])
      info[:file] = file.exist? ? file.to_s : nil
      return info
    end.call)
  end

  private
  
  def invoke(*args)
    args.unshift('--user') unless Process.uid.zero?
    @commandline.invoke(args)
  end
  
  def get_service_file_path(definition, user = nil)
    user ||= Etc.getpwuid(Process.uid)
    service_id = get_real_service_id(definition.id)
    Pathname.new(format("%<dir>s/#{service_id}.service", {
      dir: user.uid.zero? ? '/lib/systemd/system' : "#{user.dir}/.config/systemd/user",
    }))
  end
  
  def get_real_service_id(definition_id)
    definition_id.sub('@', '-at-')
  end

end

class DriverFactory

  def self.create
    if OS.linux? && which('systemctl')
      return SystemCtlDriver.create
    end

    raise('No suitable driver was found.')
  end

end

class ServiceRunInfo
  attr_reader :file, :status, :definition

  def initialize(definition, values)
    @definition = definition
    @user = values[:user]
    @file = values[:file]
    @status = values[:status]
  end
  
  def name
    @definition.name
  end
  
  def user
    @user.nil? ? nil : @user.name
  end
 
  def running?
    :started == @status
  end
  
  def to_h
    { name: name, user: user, file: file, status: status }
  end

end

class ServiceDefinition

  def initialize(formula)
    @formula = formula
  end
  
  def id
    @formula.plist_name
  end
  
  def name
    @formula.name
  end
  
  def plist
    @plist ||= begin
      # Replace "template" variables.
      plist_xml = @formula.plist.to_s.gsub(/\{\{([a-z][a-z0-9_]*)\}\}/i) do |_|
        @formula.send(Regexp.last_match(1)).to_s if @formula.respond_to?(Regexp.last_match(1))
      end
      Plist.parse_xml(plist_xml)
    end
  end

end

class RunInfoListOutput

  def self.create(run_info)
    run_info_hashes = run_info.map do |info|
      info.to_h
    end

    longest_name = [run_info_hashes.max_by { |info| info[:name].length }[:name].length, 4].max
    longest_user = [run_info_hashes.map { |info| info[:user].nil? ? 4 : info[:user].length }.max, 4].max
  
    lines = []
    lines.push(format(
      "#{Tty.bold}%-#{longest_name}.#{longest_name}<name>s %-7.7<status>s " \
      "%-#{longest_user}.#{longest_user}<user>s %<file>s#{Tty.reset}",
      {
        name: 'Name',
        status: 'Status',
        user: 'User',
        file: 'File'
      }
    ))
    run_info_hashes.each do |info|
      info[:status] = case info[:status]
        when :started then "#{Tty.green}started#{Tty.reset}"
        when :stopped then "stopped"
        when :error   then "#{Tty.red}error  #{Tty.reset}"
        when :unknown then "#{Tty.yellow}unknown#{Tty.reset}"
      end

      lines.push(format(
        "%-#{longest_name}.#{longest_name}<name>s %<status>s " \
        "%-#{longest_user}.#{longest_user}<user>s %<file>s", 
        info
      ))
    end
    return lines.join("\n")
  end

end

module OutputMessages

  def self.already_running(info)
    "Service '#{info.name}' is already running, use `#{bin} restart #{info.name}` to restart."
  end
  
  def self.not_running(info)
    "Service '#{info.name}' is not running."
  end
  
  def self.begin_action(action, info)
    "#{action} `#{info.name}`... (might take a while)".capitalize
  end
  
  def self.successful_action(action, info)
    "Successfully #{action} `#{info.name}`."
  end
  
  def self.cannot_manage(info)
    "Cannot manage '#{info.name}', the service was started by '#{info.user}'."
  end

end

class Command

  def initialize(driver, installed_formulae)
    @driver = driver
    @installed_formulae = installed_formulae.map do |formula|
      [formula.name, formula]
    end.to_h
    @service_definitions = installed_formulae.select(&:plist).sort_by(&:name).map do |formula|
      [formula.name, ServiceDefinition.new(formula)]
    end.to_h
  end

  def execute(input)
    service_names = @service_definitions.keys
    return puts("No services available to control with `#{bin}`.") if service_names.empty?

    args = input.arguments
    command = args.shift
    names = input.flag?('all') ? service_names : args
    case command
    when 'cleanup', 'clean', 'cl', 'rm'
      cleanup(service_names)
    when 'list', 'ls'
      list(service_names)
    when 'purge'
      purge(service_names)
    when 'restart', 'relaunch', 'reload', 'r'
      restart(names)
    when 'run'
      run(names)
    when 'start', 'launch', 'load', 's', 'l'
      start(names)
    when 'stop', 'unload', 'terminate', 'term', 't', 'u'
      stop(names)
    else
      usage = passthru("#{bin} --help")
      raise("Unknown command `#{command}`!\n#{usage}") unless command.nil?
      puts usage
    end
  end
  
  private
  
  def run(names)
    run_info_by_name(names, true).each do |info|
      next puts(OutputMessages.already_running(info)) if info.running?
      puts(OutputMessages.begin_action('running', info))
      @driver.run(info.definition)
      ohai(OutputMessages.successful_action('started', info))
    end
  end
  
  def start(names)
    run_info_by_name(names, true).each do |info|
      next puts(OutputMessages.already_running(info)) if info.running?
      @driver.register(info.definition)
      puts(OutputMessages.begin_action('starting', info))
      @driver.start(info.definition)
      ohai(OutputMessages.successful_action('started', info))
    end
  end
  
  def stop(names)
    run_info_by_name(names, true).each do |info|
      next puts(OutputMessages.not_running(info)) unless info.running?
      next puts(OutputMessages.cannot_manage(info)) unless current_user_can_manage?(info)
      @driver.unregister(info.definition)
      puts(OutputMessages.begin_action('stopping', info))
      @driver.stop(info.definition)
      ohai(OutputMessages.successful_action('stopped', info))
    end
  end
  
  def restart(names)
    run_info_by_name(names, true).each do |info|
      next puts(OutputMessages.cannot_manage(info)) unless current_user_can_manage?(info)
      @driver.register(info.definition)
      puts(OutputMessages.begin_action('restarting', info))
      @driver.restart(info.definition)
      ohai(OutputMessages.successful_action('restarted', info))
    end
  end
  
  def cleanup(names)
    run_info_by_name(names).each do |info|
      # Remove unused service files (for current user).
      if @driver.installed?(info.definition) && (!info.running? || !current_user_owns?(info))
        @driver.unregister(info.definition)
        @driver.uninstall(info.definition)
        ohai("Successfully removed service file for '#{info.name}' for user '#{current_user}'.")
      end
      
      # Stop running services not having service files (for current user).
      if info.running? && info.file.nil?
        next puts(OutputMessages.cannot_manage(info)) unless current_user_can_manage?(info)
        puts(OutputMessages.begin_action('stopping', info))
        @driver.stop(info.definition)
        ohai(OutputMessages.successful_action('stopped', info))
      end
    end
  end
  
  def list(names)
    run_info = run_info_by_name(names)
    puts(RunInfoListOutput.create(run_info))
  end
  
  def purge(names)
    stop(names)
    cleanup(names)
  end
  
  def run_info_by_name(names, exception_if_empty = false)
    raise("Please provide formula(e) name(s) or use --all.") if (names.empty? && exception_if_empty)

    non_service_formulae = []
    missing_formulae = []

    service_names = names.select do |name|
      next true if @service_definitions.key?(name)
      next missing_formulae.push(name) && false unless @installed_formulae.key?(name)
      next non_service_formulae.push(name) && false unless @service_definitions.key?(name)
      false
    end

    if non_service_formulae.any?
      puts("Skipped non-service formulae: #{non_service_formulae.join(', ')}.")
    end
    if missing_formulae.any?
      puts("Skipped missing formulae: #{missing_formulae.join(', ')}.")
    end

    service_names.map do |name|
      @driver.run_info(@service_definitions[name])
    end
  end

  def current_user_can_manage?(info)
    !info.running? || current_user_owns?(info)
  end
  
  def current_user_owns?(info)
    current_user == info.user
  end
  
  def current_user
    @current_user ||= Etc.getpwuid(Process.uid).name
  end

end

class ArgvInput

  def initialize(argv)
    @argv = argv
  end
  
  def arguments
    @argv.named.dclone
  end
  
  def flag?(name)
    @argv.flags_only.include?("--#{name}")
  end

end

unless defined?(HOMEBREW_LIBRARY_PATH)
  abort("Runtime error: Homebrew is required. Please start via `#{bin}`.")
end

# pbpaste's exit status is a proxy for detecting the use of reattach-to-user-namespace
if ENV['TMUX'] && !quiet_system('/usr/bin/pbpaste')
  abort("#{bin} cannot run under tmux!")
end

begin
  command = Command.new(DriverFactory.create, Formula.installed)
  command.execute(ArgvInput.new(ARGV))
rescue RuntimeError => e
  odebug(e.backtrace)
  onoe(e.message)
end

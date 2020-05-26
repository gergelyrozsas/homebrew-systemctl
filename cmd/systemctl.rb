# frozen_string_literal: true

require "cli/parser"

module Kernel
  def passthru(cmd, env = {})
    if Homebrew.args.verbose?
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

module Homebrew
  def self.user
    @user ||= Etc.getpwuid(HOMEBREW_PREFIX.stat.uid)
  end
end

class Array
  def resize(length, fill = '')
    return fill(fill, size, length - size) if (size < length)
    slice(0, length)
  end
end

class DriverFactory
  def self.create
    if OS.linux? && which('systemctl')
      require_relative '../lib/systemctl'
      return SystemCtl::Driver.create
    end

    raise('No suitable driver was found.')
  end
end

class Service
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

class Table
  def initialize
    @header = []
    @rows = []
    yield self if block_given?
  end
  
  def header=(array)
    @header = [array]
  end

  def rows=(array_of_rows)
    @rows = []
    add_rows(array_of_rows)
  end

  def add_rows(array_of_rows)
    array_of_rows.each { |row| add_row(row) }
  end

  def add_row(array)
    array = array.map { |item| item.is_a?(Array) ? item : [item] }
    actual_row_count = array.max_by { |item| item.size }.size
    (0 .. (actual_row_count - 1)).each do |index|
      @rows.push(array.map { |item| item[index] || '' })
    end
  end
  
  def to_s
    column_lengths = get_column_lengths
    format_string = column_lengths.map { |length| "%-#{length}.#{length}s" }.join(' ')
    lines = @header.map do |header|
      format("#{Tty.bold}#{format_string}#{Tty.reset}", *header.resize(column_lengths.size))
    end + @rows.map do |row|
      format(format_string, *row.resize(column_lengths.size))
    end
    lines.join("\n")
  end
  
  private

  def get_column_lengths
    max_item_count = (header_and_rows.max_by { |array| array.size } || []).size
    (0 .. (max_item_count - 1)).map do |index|
      header_and_rows
        .map { |row| (row[index] || '').to_s }
        .max_by { |item| item.length }
        .length
    end
  end

  def header_and_rows
    @header + @rows
  end
end

module OutputMessages
  def self.already_running(service)
    "Service '#{service.name}' is already running, use `#{bin} restart #{service.name}` to restart."
  end
  
  def self.not_running(service)
    "Service '#{service.name}' is not running."
  end
  
  def self.begin_action(action, service)
    "#{action} `#{service.name}`... (might take a while)".capitalize
  end
  
  def self.successful_action(action, service)
    "Successfully #{action} `#{service.name}`."
  end
  
  def self.cannot_manage(service)
    "Cannot manage '#{service.name}', the service was started by '#{service.user}'."
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
      foreach(service_names, :cleanup)
    when 'list', 'ls'
      list(service_names)
    when 'purge'
      foreach(service_names, :purge)
    when 'restart', 'relaunch', 'reload', 'r'
      foreach(names, :restart, true)
    when 'run'
      foreach(names, :run, true)
    when 'start', 'launch', 'load', 's', 'l'
      foreach(names, :start, true)
    when 'stop', 'unload', 'terminate', 'term', 't', 'u'
      foreach(names, :stop, true)
    else
      usage = passthru("#{bin} --help")
      raise("Unknown command `#{command}`!\n#{usage}") unless command.nil?
      puts usage
    end
  end
  
  private
  
  def run(service)
    return puts(OutputMessages.already_running(service)) if service.running?
    puts(OutputMessages.begin_action('running', service))
    @driver.run(service.definition)
    ohai(OutputMessages.successful_action('started', service))
  end
  
  def start(service)
    return puts(OutputMessages.already_running(service)) if service.running?
    @driver.register(service.definition)
    puts(OutputMessages.begin_action('starting', service))
    @driver.start(service.definition)
    ohai(OutputMessages.successful_action('started', service))
  end
  
  def stop(service)
    return puts(OutputMessages.not_running(service)) unless service.running?
    return puts(OutputMessages.cannot_manage(service)) unless current_user_can_manage?(service)
    @driver.unregister(service.definition)
    puts(OutputMessages.begin_action('stopping', service))
    @driver.stop(service.definition)
    ohai(OutputMessages.successful_action('stopped', service))
  end
  
  def restart(service)
    return puts(OutputMessages.cannot_manage(service)) unless current_user_can_manage?(service)
    @driver.register(service.definition)
    puts(OutputMessages.begin_action('restarting', service))
    @driver.restart(service.definition)
    ohai(OutputMessages.successful_action('restarted', service))
  end
  
  def cleanup(service)
    # Remove unused service files (for current user).
    if @driver.installed?(service.definition) && (!service.running? || !current_user_owns?(service))
      @driver.unregister(service.definition)
      @driver.uninstall(service.definition)
      ohai("Successfully removed service file for '#{service.name}' for user '#{current_user}'.")
    end
    
    # Stop running services not having service files (for current user).
    if service.running? && service.file.nil?
      return puts(OutputMessages.cannot_manage(service)) unless current_user_can_manage?(service)
      puts(OutputMessages.begin_action('stopping', service))
      @driver.stop(service.definition)
      ohai(OutputMessages.successful_action('stopped', service))
    end
  end
  
  def list(names)
    table = Table.new do |t|
      t.header = %w(Name Status User File)
      t.rows = service_list_by_name(names).map { |service| [service.name, service.status, service.user, service.file] }
    end
    puts(table)
  end
  
  def purge(service)
    stop(service)
    service = @driver.status(service.definition)
    cleanup(service)
  end
  
  def foreach(names, method, is_input = false)
    raise("Please provide formula(e) name(s) or use --all.") if (names.empty? && is_input)
    service_list_by_name(names).each { |service| send(method, service) }
  end
  
  def service_list_by_name(names)
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
      @driver.status(@service_definitions[name])
    end
  end

  def current_user_can_manage?(service)
    !service.running? || current_user_owns?(service)
  end
  
  def current_user_owns?(service)
    current_user == service.user
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
    @argv.named.dup
  end
  
  def flag?(name)
    @argv.flags_only.include?("--#{name}")
  end
end

module Homebrew
  module_function

  def systemctl_args
    Homebrew::CLI::Parser.new do
      usage_banner <<~EOS
        `systemctl` <subcommand>

        Manage background services with Linux' `systemctl`(1) daemon manager.

        `brew systemctl list`
          List all running services (from all users).

        `brew systemctl run` (<formulae>|`--all`)
          Run the services of <formulae> without registering them to launch at login.

        `brew systemctl start` (<formulae>|`--all`)
          Start the services of <formulae> immediately and register them to launch at login.

        `brew systemctl stop` (<formulae>|`--all`)
          Stop the services of <formulae> immediately and unregister them from launching at login.

        `brew systemctl restart` (<formulae>|`--all`)
          Stop (if necessary) and start the services of <formulae> immediately and register them to launch at login.

        `brew systemctl cleanup`
          Remove all unused services.

        `brew systemctl purge`
          Remove all services.

        Operate on `~/.config/systemd/user` (started at login).
      EOS
      switch_option("-a", "--all", description: "Run <subcommand> on all services.")
      switch_option(:verbose)
      switch_option(:debug)
    end
  end

  def systemctl
    systemctl_args.parse

    # pbpaste's exit status is a proxy for detecting the use of reattach-to-user-namespace
    raise UsageError.new("#{bin} cannot run under tmux!") if ENV['TMUX'] && !quiet_system('/usr/bin/pbpaste')
    # The command can only be run with the user owning the Homebrew installation directory
    raise UsageError.new("The `#{bin}` command can only be run with `#{Homebrew.user.name}` user - as `#{Homebrew.user.name}` is the owner of the Homebrew installation.") unless [Homebrew.user.uid].include?(Process.uid)

    begin
      command = Command.new(DriverFactory.create, Formula.installed)
      command.execute(ArgvInput.new(Homebrew.args))
    rescue RuntimeError => e
      odebug(e.backtrace)
      onoe(e.message)
    end
  end
end

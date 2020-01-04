# frozen_string_literal: true

module SystemCtl
  class Driver
    def self.create
      commandline = SystemCtl::Commandline.new(which('systemctl'))
      new(
          SystemCtl::PlistToServiceFileConverter.new,
          # SystemCtl::StandardRunInfoGenerator.new(commandline),
          SystemCtl::ExperimentalRunInfoGenerator.new(commandline),
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
end
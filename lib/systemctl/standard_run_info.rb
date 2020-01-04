# frozen_string_literal: true

module SystemCtl
  class StandardRunInfoGenerator
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
end

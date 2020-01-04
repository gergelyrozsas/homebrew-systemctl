# frozen_string_literal: true

module SystemCtl
  class ExperimentalRunInfoGenerator
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
end

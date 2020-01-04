# frozen_string_literal: true

module SystemCtl
  class Commandline
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
end

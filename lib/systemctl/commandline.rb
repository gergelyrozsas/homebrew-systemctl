# frozen_string_literal: true

module SystemCtl
  class Commandline
    def initialize(systemctl)
      @systemctl = systemctl
    end

    def invoke(*args, **opts)
      opts = {
        :bus => 'user',
        :uid => Process.uid,
      }.merge(opts)
      env = {}
      if 'user' === opts[:bus]
        env['XDG_RUNTIME_DIR'] = "/run/user/#{opts[:uid]}"
      end
      cmd = args
        .unshift("--#{opts[:bus]}")
        .unshift(@systemctl)
        .join(' ')
      passthru(cmd, env)
    end
  end
end

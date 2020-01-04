# frozen_string_literal: true

module SystemCtl
  class PlistToServiceFileConverter
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
end

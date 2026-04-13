# frozen_string_literal: true

require 'open3'
require 'timeout'

class OpenclawService
  DEFAULT_TRADING_FLOOR_CHANNEL =
    ENV['TRADING_FLOOR_CHANNEL_ID'].presence ||
    ENV['DISCORD_TRADING_FLOOR_CHANNEL_ID'].presence ||
    '1464509330731696213'
  DEFAULT_BIN_PATHS = [
    ENV['OPENCLAW_BIN'],
    File.join(Dir.home, '.npm-global', 'bin', 'openclaw'),
    'openclaw'
  ].compact.freeze

  class << self
    def send_agent_message(agent:, message:, timeout: 60)
      return simulate_agent_message(agent, message) if simulate?

      cmd = [openclaw_bin, 'agent', '--agent', agent, '--message', message]
      run_command(cmd, timeout: timeout).fetch(:stdout)
    end

    def send_trading_floor_message(message:, timeout: 30)
      send_discord_message(channel_id: DEFAULT_TRADING_FLOOR_CHANNEL, message: message, timeout: timeout)
    end

    def send_discord_message(channel_id:, message:, timeout: 30)
      return "SIMULATED" if simulate?

      cmd = [
        openclaw_bin, 'message', 'send',
        '--channel', 'discord',
        '--target', normalize_discord_target(channel_id),
        '--message', message
      ]
      run_command(cmd, timeout: timeout).fetch(:stdout)
    end

    private

    def simulate?
      ENV.fetch('OPENCLAW_SIMULATE', 'false').downcase == 'true'
    end

    def simulate_agent_message(agent, message)
      return "SIMULATED" unless agent.to_s == 'dundas'

      token = message.to_s[/Confirm news batch\s+(\d+)/i, 1]
      token ? "Confirm news batch #{token} [ROUTED]" : "SIMULATED"
    end

    def openclaw_bin
      DEFAULT_BIN_PATHS.each do |candidate|
        return candidate if candidate && (candidate == 'openclaw' || File.exist?(candidate))
      end
      'openclaw'
    end

    def run_command(cmd, timeout:)
      stdout = ''
      stderr = ''
      status = nil

      Timeout.timeout(timeout) do
        stdout, stderr, status = Open3.capture3(*cmd)
      end

      unless status&.success?
        raise "Openclaw command failed: #{stderr.presence || stdout.presence || 'unknown error'}"
      end

      # Strip OpenClaw doctor warnings from stdout
      clean_stdout = strip_doctor_warnings(stdout.to_s)

      { stdout: clean_stdout.strip, stderr: stderr.to_s.strip, status: status.exitstatus }
    rescue Timeout::Error
      raise "Openclaw command timed out after #{timeout}s"
    end

    def strip_doctor_warnings(text)
      # Remove the doctor warnings box that appears before agent responses
      # Pattern: │\n◇ Doctor warnings...\n├───...\n
      text.gsub(/^[│◇├─\s]*Doctor warnings[│◇├─\s\n]*(?:- .*\n)*[│◇├─\s]*\n/m, '')
    end

    def normalize_discord_target(target)
      target_str = target.to_s
      return target_str if target_str.start_with?('channel:')

      "channel:#{target_str}"
    end
  end
end

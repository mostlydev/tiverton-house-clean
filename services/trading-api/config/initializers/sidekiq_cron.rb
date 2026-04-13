# frozen_string_literal: true

# Schedule recurring jobs with sidekiq-cron
# See: https://github.com/sidekiq-cron/sidekiq-cron

if Sidekiq.server?
  schedule_file = File.join(Rails.root, 'config', 'schedule.yml')

  if File.exist?(schedule_file)
    Sidekiq::Cron::Job.load_from_hash(YAML.load_file(schedule_file))
  end
end

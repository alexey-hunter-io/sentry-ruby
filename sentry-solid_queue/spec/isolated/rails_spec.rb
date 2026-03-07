# frozen_string_literal: true

begin
  require "simplecov"
  SimpleCov.command_name "SolidQueueRails"
rescue LoadError
end

require "bundler/setup"
require "logger"

# SolidQueue depends on ActiveModel and ActiveJob railties
require "rails"
require "active_model/railtie"
require "active_job/railtie"

# Must require sentry-rails before sentry-solid_queue so that
# defined?(::Sentry::Rails) is true when the Railtie fires
require "sentry-rails"
require "sentry-solid_queue"
require "sentry/test_helper"

DUMMY_DSN = "http://12345:67890@sentry.localdomain/sentry/42"

class TestApp < Rails::Application
end

def make_basic_app
  app = Class.new(TestApp) do
    def self.name
      "RailsTestApp"
    end
  end

  app.config.hosts = nil
  app.config.secret_key_base = "test"
  app.config.eager_load = false
  app.config.active_job.queue_adapter = :solid_queue

  app.initializer :configure_sentry do
    Sentry.init do |config|
      config.dsn = DUMMY_DSN
      config.sdk_logger = ::Logger.new(nil)
      config.background_worker_threads = 0
      config.transport.transport_class = Sentry::DummyTransport
    end
  end

  app.initialize!
  Rails.application = app
  app
end

RSpec.describe Sentry::SolidQueue, "Railtie integration" do
  before(:all) { make_basic_app }

  after(:all) { Sentry::SolidQueue.detach_event_handlers }

  it "adds SolidQueue adapter to config.rails.skippable_job_adapters" do
    expect(Sentry.configuration.rails.skippable_job_adapters)
      .to include("ActiveJob::QueueAdapters::SolidQueueAdapter")
  end

  it "prepends ActiveJobExtensions onto ActiveJob::Base" do
    expect(ActiveJob::Base.ancestors).to include(Sentry::SolidQueue::ActiveJobExtensions)
  end

  it "registers event handler subscribers" do
    expect(Sentry::SolidQueue.subscribers).not_to be_empty
  end
end

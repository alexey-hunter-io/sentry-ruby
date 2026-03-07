# frozen_string_literal: true

require "solid_queue"
require "sentry-ruby"
require "sentry/integrable"
require "sentry/solid_queue/version"
require "sentry/solid_queue/configuration"
require "sentry/solid_queue/active_job_extensions"
require "sentry/solid_queue/event_handler"
require "sentry/solid_queue/recurring_tasks"

module Sentry
  module SolidQueue
    extend Sentry::Integrable
    register_integration name: "solid_queue", version: Sentry::SolidQueue::VERSION

    class << self
      def subscribers
        @subscribers ||= []
      end

      def subscribe(event_name, &block)
        subscriber = ActiveSupport::Notifications.subscribe(event_name, &block)
        subscribers << subscriber
        subscriber
      end

      def detach_event_handlers
        subscribers.each { |s| ActiveSupport::Notifications.unsubscribe(s) }
        subscribers.clear
        @thread_error_handler_installed = false
        Sentry::SolidQueue::RecurringTasks.reset!
      end

      def setup_thread_error_handler
        return unless ::SolidQueue.respond_to?(:on_thread_error)
        return if @thread_error_handler_installed

        original_handler = ::SolidQueue.on_thread_error
        @thread_error_handler_installed = true

        ::SolidQueue.on_thread_error = ->(exception) do
          begin
            Sentry::SolidQueue.capture_thread_error(exception)
          ensure
            original_handler&.call(exception)
          end
        end
      end

      def capture_thread_error(exception)
        return unless Sentry.initialized?

        Sentry.clone_hub_to_current_thread
        scope = Sentry.get_current_scope
        scope.set_transaction_name("SolidQueue::ThreadError", source: :task)
        scope.set_contexts(solid_queue: { source: "thread_error" })
        Sentry::SolidQueue.capture_exception(exception, hint: { background: false })
        scope.clear
      end
    end

    if defined?(::Rails::Railtie)
      class Railtie < ::Rails::Railtie
        initializer "sentry.solid_queue.extend_active_job", before: :eager_load! do
          ActiveSupport.on_load(:active_job) do
            prepend Sentry::SolidQueue::ActiveJobExtensions
          end
        end

        config.after_initialize do
          next unless Sentry.initialized?

          if defined?(::Sentry::Rails)
            Sentry.configuration.rails.skippable_job_adapters << "ActiveJob::QueueAdapters::SolidQueueAdapter"
          end

          if Sentry.configuration.solid_queue.capture_thread_errors
            Sentry::SolidQueue.setup_thread_error_handler
          end

          # ActiveJob lifecycle event subscriptions
          Sentry::SolidQueue::EventHandler.register_event_handlers

          # Recurring task monitoring
          Sentry::SolidQueue::RecurringTasks.setup if defined?(::SolidQueue::Scheduler)
        end
      end
    end
  end
end

# frozen_string_literal: true

module Sentry
  module SolidQueue
    module EventHandler
      SOLID_QUEUE_ADAPTER = "solid_queue"

      def self.register_event_handlers
        # Retry events: report each retry error unless report_after_job_retries is enabled
        unless Sentry.configuration.solid_queue.report_after_job_retries
          Sentry::SolidQueue.subscribe("enqueue_retry.active_job") do |event|
            job = event.payload[:job]
            next unless job.class.queue_adapter_name == SOLID_QUEUE_ADAPTER

            Sentry::SolidQueue.capture_exception(
              event.payload[:error],
              contexts: { solid_queue: { active_job: job.class.name, job_id: job.job_id, executions: job.executions } },
              hint: { background: false }
            )
          end
        end

        # Discard events: capture discarded job errors.
        # Note: retry_stopped is intentionally NOT subscribed here — the inline
        # capture in perform_with_sentry handles final-retry exceptions to avoid
        # double-reporting (retry_stopped re-raises, which our rescue catches).
        Sentry::SolidQueue.subscribe("discard.active_job") do |event|
          job = event.payload[:job]
          next unless job.class.queue_adapter_name == SOLID_QUEUE_ADAPTER

          error = event.payload[:error] || event.payload[:exception_object]
          next unless error

          Sentry::SolidQueue.capture_exception(
            error,
            contexts: { solid_queue: { active_job: job.class.name, job_id: job.job_id, event: "discard" } },
            hint: { background: false }
          )
        end
      end
    end
  end
end

# frozen_string_literal: true

module Sentry
  class Configuration
    attr_reader :solid_queue

    add_post_initialization_callback do
      @solid_queue = Sentry::SolidQueue::Configuration.new
    end
  end

  module SolidQueue
    class Configuration
      # Only report errors after all ActiveJob retries are exhausted.
      attr_accessor :report_after_job_retries

      # Inject trace headers during enqueue for connected traces.
      attr_accessor :propagate_traces

      # Capture SolidQueue infrastructure errors via on_thread_error.
      attr_accessor :capture_thread_errors

      def initialize
        @report_after_job_retries = false
        @propagate_traces = true
        @capture_thread_errors = true
      end
    end
  end
end

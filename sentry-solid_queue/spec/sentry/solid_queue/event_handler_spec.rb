# frozen_string_literal: true

require "spec_helper"

RSpec.describe Sentry::SolidQueue::EventHandler do
  let(:transport) { Sentry.get_current_client.transport }

  describe ".register_event_handlers" do
    context "with report_after_job_retries = false (default)" do
      before do
        perform_basic_setup do |config|
          config.traces_sample_rate = 0
          config.solid_queue.report_after_job_retries = false
        end
        Sentry::SolidQueue::EventHandler.register_event_handlers
      end

      it "captures enqueue_retry events" do
        job = HappyJob.new
        error = RuntimeError.new("retry error")

        ActiveSupport::Notifications.instrument("enqueue_retry.active_job", job: job, error: error)

        expect(transport.events.count).to eq(1)
        event = transport.events.first
        expect(event.exception.values.first.type).to eq("RuntimeError")
      end

      it "does not subscribe to retry_stopped events" do
        job = HappyJob.new
        error = RuntimeError.new("stopped error")

        ActiveSupport::Notifications.instrument("retry_stopped.active_job", job: job, error: error)

        expect(transport.events.count).to eq(0)
      end

      it "captures discard events" do
        job = HappyJob.new
        error = RuntimeError.new("discard error")

        ActiveSupport::Notifications.instrument("discard.active_job", job: job, error: error)

        expect(transport.events.count).to eq(1)
        event = transport.events.first
        expect(event.exception.values.first.type).to eq("RuntimeError")
      end

      it "skips non-SolidQueue adapter jobs" do
        job = NonSolidQueueJob.new
        error = RuntimeError.new("wrong adapter")

        ActiveSupport::Notifications.instrument("enqueue_retry.active_job", job: job, error: error)

        expect(transport.events.count).to eq(0)
      end

      it "sets solid_queue context on events" do
        job = HappyJob.new
        error = RuntimeError.new("retry error")

        ActiveSupport::Notifications.instrument("enqueue_retry.active_job", job: job, error: error)

        event = transport.events.first
        expect(event.contexts[:solid_queue][:active_job]).to eq("HappyJob")
        expect(event.contexts[:solid_queue][:job_id]).to be_a(String)
      end

      it "handles discard events with exception_object key" do
        job = HappyJob.new
        error = RuntimeError.new("exception object error")

        ActiveSupport::Notifications.instrument("discard.active_job", job: job, exception_object: error)

        expect(transport.events.count).to eq(1)
      end

      it "skips discard events with no error" do
        job = HappyJob.new

        ActiveSupport::Notifications.instrument("discard.active_job", job: job)

        expect(transport.events.count).to eq(0)
      end
    end

    context "with report_after_job_retries = true" do
      before do
        perform_basic_setup do |config|
          config.traces_sample_rate = 0
          config.solid_queue.report_after_job_retries = true
        end
        Sentry::SolidQueue::EventHandler.register_event_handlers
      end

      it "does not subscribe to enqueue_retry events" do
        job = HappyJob.new
        error = RuntimeError.new("retry error")

        ActiveSupport::Notifications.instrument("enqueue_retry.active_job", job: job, error: error)

        expect(transport.events.count).to eq(0)
      end

      it "does not subscribe to retry_stopped events" do
        job = HappyJob.new
        error = RuntimeError.new("stopped error")

        ActiveSupport::Notifications.instrument("retry_stopped.active_job", job: job, error: error)

        expect(transport.events.count).to eq(0)
      end

      it "still captures discard events" do
        job = HappyJob.new
        error = RuntimeError.new("discard error")

        ActiveSupport::Notifications.instrument("discard.active_job", job: job, error: error)

        expect(transport.events.count).to eq(1)
      end
    end

    context "no double-reporting on final retry" do
      it "produces exactly 1 error event when retry is exhausted" do
        perform_basic_setup { |config| config.traces_sample_rate = 0 }
        Sentry::SolidQueue::EventHandler.register_event_handlers

        job = RetryableJob.new
        job_data = job.serialize
        # Simulate being on the final attempt (attempts: 3, already executed 2 times)
        job_data["exception_executions"] = { "[RuntimeError]" => 2 }
        job.deserialize(job_data)

        expect { job.perform_now }.to raise_error(RuntimeError)

        error_events = transport.events.reject { |e| e.is_a?(Sentry::TransactionEvent) }
        expect(error_events.count).to eq(1)
      end

      it "produces exactly 1 error event with report_after_job_retries=true" do
        perform_basic_setup do |config|
          config.traces_sample_rate = 0
          config.solid_queue.report_after_job_retries = true
        end
        Sentry::SolidQueue::EventHandler.register_event_handlers

        job = RetryableJob.new
        job_data = job.serialize
        job_data["exception_executions"] = { "[RuntimeError]" => 2 }
        job.deserialize(job_data)

        expect { job.perform_now }.to raise_error(RuntimeError)

        error_events = transport.events.reject { |e| e.is_a?(Sentry::TransactionEvent) }
        expect(error_events.count).to eq(1)
      end
    end
  end

  describe "subscriber tracking" do
    it "tracks subscribers in Sentry::SolidQueue.subscribers" do
      perform_basic_setup
      expect(Sentry::SolidQueue.subscribers).to be_empty

      Sentry::SolidQueue::EventHandler.register_event_handlers

      expect(Sentry::SolidQueue.subscribers).not_to be_empty
    end

    it "cleans up subscribers via detach_event_handlers" do
      perform_basic_setup
      Sentry::SolidQueue::EventHandler.register_event_handlers

      expect(Sentry::SolidQueue.subscribers).not_to be_empty
      Sentry::SolidQueue.detach_event_handlers
      expect(Sentry::SolidQueue.subscribers).to be_empty
    end
  end
end

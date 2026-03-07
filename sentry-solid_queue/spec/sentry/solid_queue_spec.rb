# frozen_string_literal: true

require "spec_helper"

RSpec.describe Sentry::SolidQueue do
  let(:transport) { Sentry.get_current_client.transport }

  describe "integration registration" do
    it "registers as a Sentry integration" do
      perform_basic_setup
      integration = Sentry.integrations["solid_queue"]
      expect(integration).not_to be_nil
      expect(integration[:version]).to eq(Sentry::SolidQueue::VERSION)
    end
  end

  describe "end-to-end job execution" do
    before { perform_basic_setup { |config| config.traces_sample_rate = 1.0 } }

    it "captures error with full context" do
      expect { SadJob.perform_now }.to raise_error(RuntimeError)

      # Should have transaction + error event
      expect(transport.events.count).to eq(2)

      transaction = transport.events.find { |e| e.is_a?(Sentry::TransactionEvent) }
      error_event = transport.events.find { |e| !e.is_a?(Sentry::TransactionEvent) }

      expect(transaction).not_to be_nil
      expect(transaction.transaction).to eq("SadJob")
      expect(transaction.contexts.dig(:trace, :op)).to eq("queue.process")
      expect(transaction.contexts.dig(:trace, :status)).to eq("internal_error")

      expect(error_event).not_to be_nil
      expect(error_event.exception.values.first.type).to eq("RuntimeError")
      expect(error_event.contexts[:solid_queue][:active_job]).to eq("SadJob")
    end

    it "captures messages from within jobs" do
      ReportingJob.perform_now

      message_event = transport.events.find { |e| !e.is_a?(Sentry::TransactionEvent) }
      expect(message_event).not_to be_nil
      expect(message_event.message).to eq("I have something to say!")
    end

    it "cleans up context between worker-thread jobs" do
      # First: run SadJob (sets tags and breadcrumbs before raising)
      expect { simulate_worker_perform(SadJob) }.to raise_error(RuntimeError)
      transport.events.clear

      # Second: run HappyJob — should not see SadJob's tags
      simulate_worker_perform(HappyJob)

      transaction = transport.events.find { |e| e.is_a?(Sentry::TransactionEvent) }
      expect(transaction.tags[:mood]).to eq("happy")

      # Ensure no "sad" breadcrumb leaked
      breadcrumb_messages = transaction.breadcrumbs.to_h[:values].map { |b| b[:message] }
      expect(breadcrumb_messages).to include("I'm happy!")
      expect(breadcrumb_messages).not_to include("I'm sad!")
    end
  end

  describe "error handling options" do
    it "captures on each retry when report_after_job_retries is false" do
      perform_basic_setup do |config|
        config.traces_sample_rate = 0
        config.solid_queue.report_after_job_retries = false
      end
      Sentry::SolidQueue::EventHandler.register_event_handlers

      job = RetryableJob.new
      error = RuntimeError.new("retry me!")

      ActiveSupport::Notifications.instrument("enqueue_retry.active_job", job: job, error: error)

      expect(transport.events.count).to eq(1)
    end

    it "suppresses retry events when report_after_job_retries is true" do
      perform_basic_setup do |config|
        config.traces_sample_rate = 0
        config.solid_queue.report_after_job_retries = true
      end
      Sentry::SolidQueue::EventHandler.register_event_handlers

      job = RetryableJob.new
      error = RuntimeError.new("retry me!")

      ActiveSupport::Notifications.instrument("enqueue_retry.active_job", job: job, error: error)

      expect(transport.events.count).to eq(0)
    end
  end

  describe ".capture_thread_error" do
    before { perform_basic_setup { |config| config.traces_sample_rate = 0 } }

    it "captures infrastructure errors to Sentry" do
      error = RuntimeError.new("thread pool error")
      Sentry::SolidQueue.capture_thread_error(error)

      expect(transport.events.count).to eq(1)
      event = transport.events.first
      expect(event.exception.values.first.type).to eq("RuntimeError")
      expect(event.contexts[:solid_queue][:source]).to eq("thread_error")
    end

    it "sets transaction name to SolidQueue::ThreadError" do
      Sentry::SolidQueue.capture_thread_error(RuntimeError.new("test"))

      event = transport.events.first
      expect(event.transaction).to eq("SolidQueue::ThreadError")
    end
  end

  describe ".setup_thread_error_handler" do
    before { perform_basic_setup { |config| config.traces_sample_rate = 0 } }

    it "wraps SolidQueue.on_thread_error and captures to Sentry" do
      original_called = false
      ::SolidQueue.on_thread_error = ->(_ex) { original_called = true }

      Sentry::SolidQueue.setup_thread_error_handler

      ::SolidQueue.on_thread_error.call(RuntimeError.new("test"))

      expect(transport.events.count).to eq(1)
      expect(original_called).to eq(true)
    end

    it "handles nil original handler safely" do
      ::SolidQueue.on_thread_error = nil

      Sentry::SolidQueue.setup_thread_error_handler

      expect { ::SolidQueue.on_thread_error.call(RuntimeError.new("test")) }.not_to raise_error
      expect(transport.events.count).to eq(1)
    end

    it "calls original handler even when Sentry capture raises" do
      original_called = false
      ::SolidQueue.on_thread_error = ->(_ex) { original_called = true }

      Sentry::SolidQueue.setup_thread_error_handler

      allow(Sentry::SolidQueue).to receive(:capture_thread_error).and_raise(StandardError, "sentry broke")

      expect { ::SolidQueue.on_thread_error.call(RuntimeError.new("test")) }.to raise_error(StandardError, "sentry broke")
      expect(original_called).to eq(true)
    end
  end

  describe "cron check-in events" do
    before do
      perform_basic_setup { |config| config.traces_sample_rate = 1.0 }
    end

    it "emits in_progress and ok check-in events for successful cron jobs" do
      # Simulate what RecurringTasks.patch_task does.
      # Always reconfigure to ensure correct slug/config regardless of test order.
      CronJob.include(Sentry::Cron::MonitorCheckIns) unless CronJob.ancestors.include?(Sentry::Cron::MonitorCheckIns)
      CronJob.sentry_monitor_check_ins(
        slug: "my_cron_task",
        monitor_config: Sentry::Cron::MonitorConfig.from_crontab("*/5 * * * *")
      )

      CronJob.perform_now

      check_ins = transport.events.select { |e| e.is_a?(Sentry::CheckInEvent) }
      expect(check_ins.size).to eq(2)

      first = check_ins[0]
      expect(first.status).to eq(:in_progress)
      expect(first.monitor_slug).to eq("my_cron_task")

      second = check_ins[1]
      expect(second.status).to eq(:ok)
      expect(second.monitor_slug).to eq("my_cron_task")
      expect(second.check_in_id).to eq(first.check_in_id)
      expect(second.duration).to be_a(Float)
    end

    it "emits in_progress and error check-in events for failing cron jobs" do
      FailingCronJob.include(Sentry::Cron::MonitorCheckIns) unless FailingCronJob.ancestors.include?(Sentry::Cron::MonitorCheckIns)
      FailingCronJob.sentry_monitor_check_ins(
        slug: "failing_cron",
        monitor_config: Sentry::Cron::MonitorConfig.from_crontab("0 * * * *")
      )

      expect { FailingCronJob.perform_now }.to raise_error(RuntimeError, "cron failed!")

      check_ins = transport.events.select { |e| e.is_a?(Sentry::CheckInEvent) }
      expect(check_ins.size).to eq(2)

      first = check_ins[0]
      expect(first.status).to eq(:in_progress)
      expect(first.monitor_slug).to eq("failing_cron")

      second = check_ins[1]
      expect(second.status).to eq(:error)
      expect(second.check_in_id).to eq(first.check_in_id)
    end

    it "includes monitor_config in check-in events" do
      CronJob.include(Sentry::Cron::MonitorCheckIns) unless CronJob.ancestors.include?(Sentry::Cron::MonitorCheckIns)
      CronJob.sentry_monitor_check_ins(
        slug: "config_check",
        monitor_config: Sentry::Cron::MonitorConfig.from_crontab("*/5 * * * *")
      )

      CronJob.perform_now

      check_in = transport.events.find { |e| e.is_a?(Sentry::CheckInEvent) && e.status == :in_progress }
      config_hash = check_in.to_h[:monitor_config]
      expect(config_hash[:schedule]).to eq({ type: :crontab, value: "*/5 * * * *" })
    end
  end

  describe "Railtie config.after_initialize logic" do
    before do
      perform_basic_setup { |config| config.traces_sample_rate = 1.0 }
    end

    describe "EventHandler registration" do
      it "registers event handlers" do
        expect(described_class.subscribers).to be_empty
        Sentry::SolidQueue::EventHandler.register_event_handlers
        expect(described_class.subscribers).not_to be_empty
      end
    end

    describe "RecurringTasks.setup via Railtie" do
      it "subscribes to enqueue_recurring_task.solid_queue and patches tasks" do
        Sentry::SolidQueue::RecurringTasks.setup

        # Now fire the notification like SolidQueue would
        task = ::SolidQueue::RecurringTask.new(
          class_name: "CronJob",
          schedule: "*/10 * * * *",
          key: "railtie_cron"
        )
        Sentry::SolidQueue::RecurringTasks.reset!

        ActiveSupport::Notifications.instrument("enqueue_recurring_task.solid_queue", task: task)

        expect(Sentry::SolidQueue::RecurringTasks.instance_variable_get(:@patched_classes)).to include("CronJob")
      end
    end

    describe "initialization without sentry-rails" do
      it "registers EventHandler subscribers without Sentry::Rails" do
        # No Sentry::Rails stub — verify features work independently
        Sentry::SolidQueue::EventHandler.register_event_handlers
        expect(described_class.subscribers).not_to be_empty
      end

      it "sets up RecurringTasks without Sentry::Rails" do
        Sentry::SolidQueue::RecurringTasks.setup
        expect(described_class.subscribers).not_to be_empty
      end
    end
  end

  describe "subscriber management" do
    it "starts with empty subscribers" do
      expect(described_class.subscribers).to be_empty
    end

    it "tracks subscribers via .subscribe" do
      perform_basic_setup
      subscriber = described_class.subscribe("test_event.solid_queue") { |_| }

      expect(described_class.subscribers).to include(subscriber)
    end

    it "cleans up via .detach_event_handlers" do
      perform_basic_setup
      described_class.subscribe("test_event.solid_queue") { |_| }
      expect(described_class.subscribers).not_to be_empty

      described_class.detach_event_handlers
      expect(described_class.subscribers).to be_empty
    end
  end

  describe "dual-adapter coexistence" do
    before { perform_basic_setup { |config| config.traces_sample_rate = 1.0 } }

    it "only instruments SolidQueue jobs, not other adapters" do
      # SolidQueue job — should be instrumented
      HappyJob.perform_now

      # Non-SolidQueue job — should NOT be instrumented
      NonSolidQueueJob.perform_now

      transactions = transport.events.select { |e| e.is_a?(Sentry::TransactionEvent) }
      expect(transactions.size).to eq(1)
      expect(transactions.first.transaction).to eq("HappyJob")
    end

    it "does not pollute non-SolidQueue jobs during deserialize" do
      job = NonSolidQueueJob.new
      job_data = job.serialize
      job_data["_sentry"] = { "trace_propagation_headers" => { "sentry-trace" => "abc-123-1" } }
      job.deserialize(job_data)

      # Should not have worker thread flag set
      expect(job.instance_variable_get(:@_solid_queue_worker_thread)).to be_nil
      expect(job.instance_variable_get(:@_sentry_trace_data)).to be_nil

      # Should still execute normally
      result = job.perform_now
      expect(result).to eq("not solid_queue")
    end
  end
end

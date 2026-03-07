# frozen_string_literal: true

require "spec_helper"

RSpec.describe Sentry::SolidQueue::Configuration do
  it "adds #solid_queue option to Sentry::Configuration" do
    config = Sentry::Configuration.new

    expect(config.solid_queue).to be_a(described_class)
  end

  describe "#report_after_job_retries" do
    it "has correct default value" do
      expect(subject.report_after_job_retries).to eq(false)
    end
  end

  describe "#propagate_traces" do
    it "has correct default value" do
      expect(subject.propagate_traces).to eq(true)
    end
  end

  describe "#capture_thread_errors" do
    it "has correct default value" do
      expect(subject.capture_thread_errors).to eq(true)
    end
  end
end

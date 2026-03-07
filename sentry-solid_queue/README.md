<p align="center">
  <a href="https://sentry.io" target="_blank" align="center">
    <img src="https://sentry-brand.storage.googleapis.com/sentry-logo-black.png" width="280">
  </a>
  <br>
</p>

# sentry-solid_queue, the SolidQueue integration for Sentry's Ruby client

---

[![Gem Version](https://img.shields.io/gem/v/sentry-solid_queue.svg)](https://rubygems.org/gems/sentry-solid_queue)
![Build Status](https://github.com/getsentry/sentry-ruby/actions/workflows/sentry_solid_queue_test.yml/badge.svg)
[![Coverage Status](https://img.shields.io/codecov/c/github/getsentry/sentry-ruby/master?logo=codecov)](https://codecov.io/gh/getsentry/sentry-ruby/branch/master)
[![Gem](https://img.shields.io/gem/dt/sentry-solid_queue.svg)](https://rubygems.org/gems/sentry-solid_queue/)

[Documentation](https://docs.sentry.io/platforms/ruby/guides/solid_queue/) | [Bug Tracker](https://github.com/getsentry/sentry-ruby/issues) | [Forum](https://forum.sentry.io/) | IRC: irc.freenode.net, #sentry

The official Ruby-language client and integration layer for the [Sentry](https://github.com/getsentry/sentry) error reporting API.


## Getting Started

### Install

```ruby
gem "sentry-ruby"
gem "sentry-rails"
gem "sentry-solid_queue"
```

### Configuration

Add `sentry-solid_queue` to your `Gemfile` and it will automatically integrate with SolidQueue when the Rails application initializes.

```ruby
Sentry.init do |config|
  config.dsn = "YOUR_SENTRY_DSN"
  config.traces_sample_rate = 1.0

  # SolidQueue-specific options
  config.solid_queue.report_after_job_retries = false  # default: report on each retry
  config.solid_queue.propagate_traces = true           # default: propagate distributed traces
  config.solid_queue.capture_thread_errors = true      # default: capture SolidQueue thread errors
end
```

### Features

- **Error Capture**: Automatically captures exceptions from SolidQueue jobs with full context (job class, queue, arguments, etc.)
- **Performance Tracing**: Creates transactions for job execution with `queue.process` operation and `queue.publish` spans for enqueue
- **Distributed Tracing**: Propagates trace context from the enqueue side to the worker side through SolidQueue's job serialization
- **Cron Monitoring**: Automatically patches recurring tasks with Sentry Crons check-ins
- **Thread Error Handling**: Captures SolidQueue infrastructure errors (thread pool failures, etc.)
- **User Context Propagation**: Optionally propagates user context from web requests to background jobs (gated by `send_default_pii`)
- **Retry Awareness**: Configurable error reporting — capture on each retry or only after retries are exhausted

### Options

| Option | Default | Description |
|--------|---------|-------------|
| `report_after_job_retries` | `false` | When `false`, reports errors on each retry attempt. When `true`, only reports after all retries are exhausted. |
| `propagate_traces` | `true` | When `true`, propagates distributed trace headers through job serialization for end-to-end tracing. |
| `capture_thread_errors` | `true` | When `true`, wraps `SolidQueue.on_thread_error` to capture infrastructure errors to Sentry. |

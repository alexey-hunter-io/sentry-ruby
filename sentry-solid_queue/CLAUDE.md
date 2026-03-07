# sentry-solid_queue

## Testing

Always run the **default rake task**, not `rspec` directly:

```bash
cd sentry-solid_queue
bundle exec rake
```

This runs both `spec` (main specs) and `spec:isolated` (Rails Railtie integration tests that boot a full Rails app). Running `bundle exec rspec` alone will miss the isolated specs.

## Architecture

- **ActiveJobExtensions** is prepended to `ActiveJob::Base` and guards every method with `using_solid_queue_adapter?` so it only instruments SolidQueue jobs.
- When `sentry-rails` is also loaded, the adapter is registered in `skippable_job_adapters` to prevent double-instrumentation.
- Worker-thread jobs use `clone_hub_to_current_thread` for scope isolation; inline `perform_now` uses `with_scope` to preserve request context.
- `detach_event_handlers` is the full teardown method (subscribers + recurring tasks + thread error handler flag). Always use it in test cleanup.

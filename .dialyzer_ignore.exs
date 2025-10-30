[
  # Mix functions are only available during Mix compilation context
  {"lib/mix/tasks/phoenix_kit.install.ex", :unknown_function},
  {"lib/mix/tasks/phoenix_kit.update.ex", :unknown_function},
  {"lib/mix/tasks/phoenix_kit.modernize_layouts.ex", :unknown_function},
  {"lib/phoenix_kit/install/migration_strategy.ex", :unknown_function},
  {"lib/phoenix_kit/install/repo_detection.ex", :unknown_function},
  {"lib/mix/tasks/phoenix_kit.status.ex", :unknown_function},
  {"lib/phoenix_kit/migrations/postgres.ex", :unknown_function},
  {"lib/phoenix_kit/install/mailer_config.ex", :unknown_function},
  {"lib/mix/tasks/phoenix_kit/email_cleanup.ex", :unknown_function},
  {"lib/mix/tasks/phoenix_kit/email_export.ex", :unknown_function},
  {"lib/mix/tasks/phoenix_kit/email_stats.ex", :unknown_function},
  {"lib/mix/tasks/phoenix_kit/email_test_webhook.ex", :unknown_function},
  {"lib/mix/tasks/phoenix_kit/email_verify_config.ex", :unknown_function},
  {"lib/mix/tasks/phoenix_kit.email.debug_sqs.ex", :unknown_function},
  {"lib/mix/tasks/phoenix_kit.email.process_dlq.ex", :unknown_function},
  {"lib/mix/tasks/phoenix_kit.email.send_test.ex", :unknown_function},
  {"lib/mix/tasks/phoenix_kit.configure_aws_ses.ex", :unknown_function},
  {"lib/mix/tasks/phoenix_kit.process_dlq.ex", :unknown_function},
  {"lib/mix/tasks/phoenix_kit.process_sqs_queue.ex", :unknown_function},
  {"lib/mix/tasks/phoenix_kit.sync_email_status.ex", :unknown_function},
  {"lib/mix/tasks/phoenix_kit.seed_templates.ex", :unknown_function},

  # Mix.Task behaviour callbacks (expected in Mix tasks)
  # Note: Mix.Task behaviour info is not available to Dialyzer (compile-time only)
  # Adding @impl Mix.Task does not fix this warning
  {"lib/mix/tasks/phoenix_kit.gen.migration.ex", :callback_info_missing, 1},
  {"lib/mix/tasks/phoenix_kit.seed_templates.ex", :callback_info_missing, 1},
  {"lib/mix/tasks/phoenix_kit.install.ex", :callback_info_missing, 2},
  {"lib/mix/tasks/phoenix_kit.update.ex", :callback_info_missing, 3},
  {"lib/mix/tasks/phoenix_kit.modernize_layouts.ex", :callback_info_missing, 1},
  {"lib/mix/tasks/phoenix_kit.assets.rebuild.ex", :callback_info_missing, 1},
  {"lib/mix/tasks/phoenix_kit.status.ex", :callback_info_missing, 1},
  {"lib/mix/tasks/phoenix_kit/email_cleanup.ex", :callback_info_missing, 1},
  {"lib/mix/tasks/phoenix_kit/email_export.ex", :callback_info_missing, 1},
  {"lib/mix/tasks/phoenix_kit/email_stats.ex", :callback_info_missing, 1},
  {"lib/mix/tasks/phoenix_kit/email_test_webhook.ex", :callback_info_missing, 1},
  {"lib/mix/tasks/phoenix_kit/email_verify_config.ex", :callback_info_missing, 1},
  {"lib/mix/tasks/phoenix_kit.email.debug_sqs.ex", :callback_info_missing, 1},
  {"lib/mix/tasks/phoenix_kit.email.process_dlq.ex", :callback_info_missing, 1},
  {"lib/mix/tasks/phoenix_kit.email.send_test.ex", :callback_info_missing, 1},
  {"lib/mix/tasks/phoenix_kit.configure_aws_ses.ex", :callback_info_missing, 1},
  {"lib/mix/tasks/phoenix_kit.process_dlq.ex", :callback_info_missing, 1},
  {"lib/mix/tasks/phoenix_kit.process_sqs_queue.ex", :callback_info_missing, 1},
  {"lib/mix/tasks/phoenix_kit.sync_email_status.ex", :callback_info_missing, 1},

  # False positive pattern match warnings (runtime behavior differs from static analysis)
  {"lib/mix/tasks/phoenix_kit/email_cleanup.ex", :pattern_match, 1},
  # Dialyzer incorrectly thinks 'false' pattern is unreachable after 'true' in boolean case
  ~r/lib\/mix\/tasks\/phoenix_kit\.configure_aws_ses\.ex:193:.*pattern_match/,

  # ExAws library type definition issues (false positives from incomplete type specs)
  ~r/lib\/phoenix_kit\/emails\/archiver\.ex:.*pattern_match/,
  ~r/lib\/phoenix_kit\/emails\/archiver\.ex:.*unused_fun/,

  # Ecto.Multi opaque type false positives (Dialyzer limitation with opaque types in pipelines)
  # Note: Code uses proper pipe syntax, but Dialyzer loses opaque type info
  ~r/lib\/phoenix_kit\/users\/auth\.ex:.*call_without_opaque/
]

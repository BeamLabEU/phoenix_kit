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
  {"lib/phoenix_kit/install/finch_setup.ex", :unknown_function},
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
  {"lib/mix/tasks/phoenix_kit.gen.migration.ex", :callback_info_missing, 1},
  {"lib/mix/tasks/phoenix_kit.seed_templates.ex", :callback_info_missing, 1},
  {"lib/mix/tasks/phoenix_kit.install.ex", :callback_info_missing, 2},
  {"lib/mix/tasks/phoenix_kit.update.ex", :callback_info_missing, 1},
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

  # False positive guard clause warnings (function returns boolean correctly)
  {"lib/mix/tasks/phoenix_kit.assets.rebuild.ex", :guard_fail, 209},
  {"lib/mix/tasks/phoenix_kit.configure_aws_ses.ex", :guard_fail, 183},
  {"lib/mix/tasks/phoenix_kit.configure_aws_ses.ex", :guard_fail, 186},
  {"lib/mix/tasks/phoenix_kit.configure_aws_ses.ex", :guard_fail, 189},

  # False positive pattern match warnings (runtime behavior differs from static analysis)
  {"lib/mix/tasks/phoenix_kit/email_cleanup.ex", :pattern_match, 1},
  {"lib/phoenix_kit/email_system/email_interceptor.ex", :pattern_match_cov, 524},
  {"lib/phoenix_kit/email_system/email_interceptor.ex", :pattern_match_cov, 706},
  {"lib/phoenix_kit/email_system/sqs_worker.ex", :pattern_match, 1},
  ~r/lib\/phoenix_kit\/email_system\/email_interceptor\.ex:558:.*pattern_match_cov/,
  ~r/lib\/phoenix_kit\/email_system\/email_interceptor\.ex:742:.*pattern_match_cov/,
  ~r/lib\/phoenix_kit\/email_system\/email_interceptor\.ex:746:.*pattern_match_cov/,
  ~r/lib\/phoenix_kit\/email_system\/email_interceptor\.ex:778:.*pattern_match_cov/,

  # Unused functions that are actually used in recursive patterns or by calling code
  {"lib/mix/tasks/phoenix_kit.email.process_dlq.ex", :unused_fun, 176},
  {"lib/mix/tasks/phoenix_kit.email.process_dlq.ex", :unused_fun, 212},
  {"lib/mix/tasks/phoenix_kit.email.process_dlq.ex", :unused_fun, 225},
  {"lib/mix/tasks/phoenix_kit.email.process_dlq.ex", :unused_fun, 248},
  {"lib/phoenix_kit/email_system/email_system.ex", :unused_fun, 481},
  {"lib/phoenix_kit/email_system/email_system.ex", :unused_fun, 590},
  {"lib/phoenix_kit/email_system/email_system.ex", :unused_fun, 615},
  {"lib/phoenix_kit/email_system/email_system.ex", :unused_fun, 704},

  # ExAws function call warnings (library type definitions)
  {"lib/phoenix_kit/email_system/email_system.ex", :no_return, 495},
  {"lib/phoenix_kit/email_system/email_system.ex", :call, 520},
  {"lib/phoenix_kit/email_system/email_system.ex", :no_return, 643},
  {"lib/phoenix_kit/email_system/email_system.ex", :call, 657},

  # Ecto.Multi opaque type false positives (code works correctly)
  ~r/lib\/phoenix_kit\/users\/auth\.ex:.*call_without_opaque/

  # Exact comparison warnings for nil checks (legacy warning format - Dialyzer bug)
  # (No current warnings - exact_compare issue in configure_aws_ses.ex was fixed by using pattern matching)

  # Ignore all test files - library tests are meant for integration testing
  ~r/^test\/.*/
]

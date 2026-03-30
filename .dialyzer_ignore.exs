[
  # Mix functions are only available during Mix compilation context
  {"lib/mix/tasks/phoenix_kit.gen.migration.ex", :unknown_function},
  {"lib/mix/tasks/phoenix_kit.doctor.ex", :unknown_function},
  {"lib/mix/tasks/phoenix_kit.install.ex", :unknown_function},
  {"lib/mix/tasks/phoenix_kit.update.ex", :unknown_function},
  {"lib/mix/tasks/phoenix_kit.gen.admin.page.ex", :unknown_function},
  {"lib/mix/tasks/phoenix_kit.gen.user.dashboard.ex", :unknown_function},
  # Conditional compilation pattern match in update.ex (Code.ensure_loaded?)
  {"lib/mix/tasks/phoenix_kit.update.ex", :pattern_match, 1},
  {"lib/mix/tasks/phoenix_kit.modernize_layouts.ex", :unknown_function},
  {"lib/phoenix_kit/install/migration_strategy.ex", :unknown_function},
  {"lib/mix/tasks/phoenix_kit.status.ex", :unknown_function},
  {"lib/phoenix_kit/migrations/postgres.ex", :unknown_function},
  {"lib/mix/tasks/phoenix_kit.cleanup_orphaned_files.ex", :unknown_function},

  # Mix.Task behaviour callbacks (expected in Mix tasks)
  # Note: Mix.Task behaviour info is not available to Dialyzer (compile-time only)
  # Adding @impl Mix.Task does not fix this warning
  {"lib/mix/tasks/phoenix_kit.doctor.ex", :callback_info_missing, 1},
  {"lib/mix/tasks/phoenix_kit.gen.migration.ex", :callback_info_missing, 1},
  {"lib/mix/tasks/phoenix_kit.install.ex", :callback_info_missing, 2},
  {"lib/mix/tasks/phoenix_kit.update.ex", :callback_info_missing, 3},
  {"lib/mix/tasks/phoenix_kit.gen.admin.page.ex", :callback_info_missing},
  {"lib/mix/tasks/phoenix_kit.gen.user.dashboard.ex", :callback_info_missing},
  {"lib/mix/tasks/phoenix_kit.modernize_layouts.ex", :callback_info_missing, 1},
  {"lib/mix/tasks/phoenix_kit.assets.rebuild.ex", :callback_info_missing, 1},
  {"lib/mix/tasks/phoenix_kit.status.ex", :callback_info_missing, 1},
  {"lib/mix/tasks/phoenix_kit.cleanup_orphaned_files.ex", :callback_info_missing, 1},

  # Publishing module (extracted) — dynamic dispatch through publishing_module() helper
  # Ecto.Multi opaque type false positives (code works correctly)
  ~r/lib\/phoenix_kit\/users\/auth\.ex:.*call_without_opaque/,

  # Connections module (extracted to phoenix_kit_user_connections) — conditional calls via Code.ensure_loaded?
  {"lib/phoenix_kit_web/live/users/user_details.ex", :unknown_function},

  # Legal module (extracted to phoenix_kit_legal) — conditional component calls
  {"lib/phoenix_kit_web/components/layout_wrapper.ex", :unknown_function},
  {"lib/phoenix_kit_web/components/layouts/root.html.heex", :unknown_function},
  {"lib/phoenix_kit_web/components/layouts/dashboard.html.heex", :unknown_function},

  # Pages module - type inference false positives
  ~r/lib\/modules\/pages\/listing_cache\.ex:.*pattern_match/,
  ~r/lib\/modules\/pages\/storage\/.*\.ex:.*pattern_match/,
  ~r/lib\/modules\/pages\/storage\/.*\.ex:.*call/,

  # Dashboard tab system - keyword list spec inference false positives
  # Functions accept keyword() but Dialyzer infers broader types from pattern matching
  ~r/lib\/phoenix_kit\/dashboard\/tab\.ex:.*invalid_contract/,
  ~r/lib\/phoenix_kit\/dashboard\/dashboard\.ex:.*invalid_contract/,

  # Dashboard context selector - user-provided display_name callback might return nil
  # Dialyzer infers binary() type from usage but callback contract allows nil
  ~r/lib\/phoenix_kit\/dashboard\/context_selector\.ex:.*pattern_match/,

  # Dashboard context selector - MapSet opaque type false positives
  # Dialyzer can't properly track MapSet opaque types through recursive functions
  ~r/lib\/phoenix_kit\/dashboard\/context_selector\.ex:.*call_without_opaque/,

  # Scope struct contains MapSet.t() which is opaque - Dialyzer can't reconcile
  # opaque types inside struct type definitions with their constructed values
  {"lib/phoenix_kit/users/auth/scope.ex", :contract_with_opaque},
  # Callers of Scope.admin?/1 inherit the opaque mismatch from Scope.for_user/1
  {"lib/modules/maintenance/web/plugs/maintenance_mode.ex", :call_without_opaque},

  # doctor.ex display_check - `if detail` on binary() type: Dialyzer sees binary is always
  # truthy so the nil/false branch of `if` can never succeed; this is intentional nil-guard
  {"lib/mix/tasks/phoenix_kit.doctor.ex", :guard_fail},
  # doctor.ex MapSet.member? - Dialyzer infers old MapSet internal structure from SQL rows
  # This is a false positive: MapSet.new/1 correctly produces an opaque MapSet at runtime
  {"lib/mix/tasks/phoenix_kit.doctor.ex", :call_without_opaque},

  # Shop catalog_product - false positive guard_fail warning
  # Case statement already handles nil in earlier branch, Dialyzer incorrectly warns
  # that remaining branch comparing binary() to nil can never succeed
  {"lib/modules/shop/web/catalog_product.ex", :guard_fail},

  # Entity form - defensive catch-all clauses for mb_to_bytes and parse_accept_list
  # Dialyzer proves previous clauses cover all actual call-site types but
  # catch-alls are kept intentionally for safety with dynamic form params

  # tab_callback_context/1 has a :user_dashboard_tabs clause for future use
  # but compile_module_admin_routes only passes :admin_tabs and :settings_tabs currently
  {"lib/phoenix_kit_web/integration.ex", :pattern_match},

  # External optional modules guarded by Code.ensure_loaded? at runtime
  {"lib/modules/sitemap/sources/posts.ex", :unknown_function},
  {"lib/modules/sitemap/sources/publishing.ex", :unknown_function},
  {"lib/phoenix_kit/dashboard/registry.ex", :unknown_function},
  {"lib/phoenix_kit/install/css_integration.ex", :unknown_function},
  {"lib/phoenix_kit/scheduled_jobs/workers/process_scheduled_jobs_worker.ex", :unknown_function},

  # ExUnit internal functions — false positives when test/support is compiled in MIX_ENV=test
  # Dialyzer cannot resolve ExUnit private macros expanded at compile time
  {"test/support/conn_case.ex", :unknown_function},
  {"test/support/data_case.ex", :unknown_function},

  # Extracted module references — conditionally loaded via Code.ensure_loaded?
  # These modules live in separate packages (phoenix_kit_ecommerce, phoenix_kit_billing)
  {"lib/phoenix_kit_web/integration.ex", :unknown_function},
  {"lib/phoenix_kit/utils/country_data.ex", :unknown_function},
  {"lib/phoenix_kit_web/users/auth.ex", :unknown_function},
  {"lib/modules/sitemap/sources/shop.ex", :unknown_function},
  {"lib/phoenix_kit/users/auth.ex", :unknown_function}
]

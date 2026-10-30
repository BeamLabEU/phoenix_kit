defmodule PhoenixKit.Migrations.ModuleOwnedTables do
  @moduledoc """
  Which of the tables core's migration chain creates belong to core, and which
  belong to a module.

  Core's chain (the V135 baseline and the versions after it) still creates
  tables for 25 modules, from the years those modules lived inside core. This
  module is the one place that says whose each of those tables is. Every table
  the chain creates is listed exactly once: in `core_tables/0` or under its
  owner in `owners/0` (`test/phoenix_kit/migrations/module_owned_tables_test.exs`
  holds that against the `ExpectedSchema` manifest).

  An owner is the module's OTP application. Ownership follows the code that
  uses a table: the package holding its Ecto schema, or, for the few without
  one, the module whose migrations adopt it. That is not always the `owner:`
  label in `ExpectedSchema` — 57 tables there say `:core` and 6 say
  `:comments` although posts, billing, ecommerce and others use them. This
  list is the authority; the manifest labels predate it.

  ## The rule

  **Core's migrations never create, change or drop a module's table again.**
  Since core 3.0 no core version does (`last_core_version_touching_module_tables/0` is 0):
  V135..V224 had that DDL removed. A change to a module's table goes into that
  module's own migration chain, and a core version that names one fails the test above. A new core
  table goes into `core_tables/0`, and the same test fails until it does.

  Moving the remaining tables fully into their modules is planned step by
  step in `dev_docs/plans/2026-10-25-module-table-ownership.md`, which also
  records where that work stands.
  """

  @last_core_version_touching_module_tables 0

  @owners [
    phoenix_kit_ai: ~w(
      phoenix_kit_ai_endpoints
      phoenix_kit_ai_prompts
      phoenix_kit_ai_requests
    ),
    phoenix_kit_billing: ~w(
      phoenix_kit_billing_profiles
      phoenix_kit_currencies
      phoenix_kit_invoices
      phoenix_kit_orders
      phoenix_kit_payment_methods
      phoenix_kit_payment_options
      phoenix_kit_payment_provider_configs
      phoenix_kit_subscription_types
      phoenix_kit_subscriptions
      phoenix_kit_transactions
      phoenix_kit_webhook_events
    ),
    phoenix_kit_calendar: ~w(
      phoenix_kit_calendar_event_participants
      phoenix_kit_calendar_events
    ),
    phoenix_kit_catalogue: ~w(
      phoenix_kit_cat_attribute_groups
      phoenix_kit_cat_attribute_values
      phoenix_kit_cat_attributes
      phoenix_kit_cat_catalogues
      phoenix_kit_cat_categories
      phoenix_kit_cat_folders
      phoenix_kit_cat_item_attribute_groups
      phoenix_kit_cat_item_attribute_sets
      phoenix_kit_cat_item_catalogue_rules
      phoenix_kit_cat_item_supplier_info
      phoenix_kit_cat_items
      phoenix_kit_cat_manufacturer_suppliers
      phoenix_kit_cat_manufacturers
      phoenix_kit_cat_pdf_extractions
      phoenix_kit_cat_pdf_page_contents
      phoenix_kit_cat_pdf_pages
      phoenix_kit_cat_pdfs
      phoenix_kit_cat_suppliers
    ),
    phoenix_kit_comments: ~w(
      phoenix_kit_comment_media
      phoenix_kit_comments
      phoenix_kit_comments_dislikes
      phoenix_kit_comments_likes
    ),
    phoenix_kit_crm: ~w(
      phoenix_kit_crm_companies
      phoenix_kit_crm_company_memberships
      phoenix_kit_crm_contacts
      phoenix_kit_crm_interaction_parties
      phoenix_kit_crm_interactions
      phoenix_kit_crm_list_members
      phoenix_kit_crm_lists
      phoenix_kit_crm_party_roles
      phoenix_kit_crm_role_settings
      phoenix_kit_crm_user_role_view
    ),
    phoenix_kit_customer_support: ~w(
      phoenix_kit_ticket_attachments
      phoenix_kit_ticket_comments
      phoenix_kit_ticket_status_history
      phoenix_kit_tickets
    ),
    phoenix_kit_dashboards: ~w(
      phoenix_kit_dashboards
    ),
    phoenix_kit_document_creator: ~w(
      phoenix_kit_doc_categories
      phoenix_kit_doc_document_sections
      phoenix_kit_doc_documents
      phoenix_kit_doc_headers_footers
      phoenix_kit_doc_template_presets
      phoenix_kit_doc_templates
      phoenix_kit_doc_types
    ),
    phoenix_kit_ecommerce: ~w(
      phoenix_kit_shop_cart_items
      phoenix_kit_shop_carts
      phoenix_kit_shop_categories
      phoenix_kit_shop_category_slugs
      phoenix_kit_shop_config
      phoenix_kit_shop_import_configs
      phoenix_kit_shop_import_logs
      phoenix_kit_shop_product_slugs
      phoenix_kit_shop_products
      phoenix_kit_shop_shipping_methods
    ),
    phoenix_kit_emails: ~w(
      phoenix_kit_email_blocklist
      phoenix_kit_email_events
      phoenix_kit_email_logs
      phoenix_kit_email_metrics
      phoenix_kit_email_orphaned_events
    ),
    phoenix_kit_entities: ~w(
      phoenix_kit_entities
      phoenix_kit_entity_data
    ),
    phoenix_kit_legal: ~w(
      phoenix_kit_consent_logs
    ),
    phoenix_kit_locations: ~w(
      phoenix_kit_location_spaces
      phoenix_kit_location_type_assignments
      phoenix_kit_location_types
      phoenix_kit_locations
    ),
    phoenix_kit_manufacturing: ~w(
      phoenix_kit_machine_operations
      phoenix_kit_machine_type_assignments
      phoenix_kit_machines
    ),
    phoenix_kit_newsletters: ~w(
      phoenix_kit_newsletters_broadcasts
      phoenix_kit_newsletters_deliveries
    ),
    phoenix_kit_og: ~w(
      phoenix_kit_og_assignments
      phoenix_kit_og_templates
    ),
    phoenix_kit_posts: ~w(
      phoenix_kit_comment_dislikes
      phoenix_kit_comment_likes
      phoenix_kit_post_comments
      phoenix_kit_post_dislikes
      phoenix_kit_post_group_assignments
      phoenix_kit_post_groups
      phoenix_kit_post_likes
      phoenix_kit_post_media
      phoenix_kit_post_mentions
      phoenix_kit_post_tag_assignments
      phoenix_kit_post_tags
      phoenix_kit_post_views
      phoenix_kit_posts
    ),
    phoenix_kit_projects: ~w(
      phoenix_kit_project_assignments
      phoenix_kit_project_dependencies
      phoenix_kit_project_statuses
      phoenix_kit_project_task_dependencies
      phoenix_kit_project_tasks
      phoenix_kit_projects
    ),
    phoenix_kit_publishing: ~w(
      phoenix_kit_publishing_categories
      phoenix_kit_publishing_contents
      phoenix_kit_publishing_groups
      phoenix_kit_publishing_post_categories
      phoenix_kit_publishing_post_views
      phoenix_kit_publishing_posts
      phoenix_kit_publishing_versions
    ),
    phoenix_kit_referrals: ~w(
      phoenix_kit_referral_code_usage
      phoenix_kit_referral_codes
    ),
    phoenix_kit_staff: ~w(
      phoenix_kit_staff_departments
      phoenix_kit_staff_employments
      phoenix_kit_staff_people
      phoenix_kit_staff_person_skills
      phoenix_kit_staff_skills
      phoenix_kit_staff_team_memberships
      phoenix_kit_staff_teams
    ),
    phoenix_kit_sync: ~w(
      phoenix_kit_sync_connections
      phoenix_kit_sync_transfers
    ),
    phoenix_kit_user_connections: ~w(
      phoenix_kit_user_blocks
      phoenix_kit_user_blocks_history
      phoenix_kit_user_connections
      phoenix_kit_user_connections_history
      phoenix_kit_user_follows
      phoenix_kit_user_follows_history
    ),
    phoenix_kit_warehouse: ~w(
      phoenix_kit_warehouse_goods_issues
      phoenix_kit_warehouse_goods_receipts
      phoenix_kit_warehouse_internal_orders
      phoenix_kit_warehouse_inventory_documents
      phoenix_kit_warehouse_min_stock
      phoenix_kit_warehouse_stock
      phoenix_kit_warehouse_supplier_orders
      phoenix_kit_warehouse_transfers
    )
  ]

  @core_tables ~w(
    phoenix_kit
    phoenix_kit_access_attempts
    phoenix_kit_access_requests
    phoenix_kit_activities
    phoenix_kit_admin_notes
    phoenix_kit_annotations
    phoenix_kit_api_confirmations
    phoenix_kit_api_idempotency
    phoenix_kit_api_keys
    phoenix_kit_audit_logs
    phoenix_kit_bucket_log
    phoenix_kit_buckets
    phoenix_kit_email_send_profiles
    phoenix_kit_file_instances
    phoenix_kit_file_location_checks
    phoenix_kit_file_locations
    phoenix_kit_files
    phoenix_kit_job_runs
    phoenix_kit_login_attempts
    phoenix_kit_media_folder_links
    phoenix_kit_media_folders
    phoenix_kit_mentions
    phoenix_kit_notifications
    phoenix_kit_organization_invitations
    phoenix_kit_organization_managers
    phoenix_kit_role_permissions
    phoenix_kit_scheduled_jobs
    phoenix_kit_settings
    phoenix_kit_storage_dimensions
    phoenix_kit_storage_libraries
    phoenix_kit_storage_library_members
    phoenix_kit_storage_profile_buckets
    phoenix_kit_storage_profiles
    phoenix_kit_user_known_devices
    phoenix_kit_user_oauth_providers
    phoenix_kit_user_role_assignments
    phoenix_kit_user_roles
    phoenix_kit_user_view_prefs
    phoenix_kit_users
    phoenix_kit_users_tokens
    phoenix_kit_variant_sets
  )

  @owner_by_table for {owner, tables} <- @owners, table <- tables, into: %{}, do: {table, owner}

  @doc "Every module-owned table core's chain creates, grouped by owning OTP application."
  @spec owners() :: [{atom(), [String.t()]}]
  def owners, do: @owners

  @doc "The tables core's chain creates that are core's own."
  @spec core_tables() :: [String.t()]
  def core_tables, do: @core_tables

  @doc "Every module-owned table core's chain creates."
  @spec module_tables() :: [String.t()]
  def module_tables, do: Map.keys(@owner_by_table)

  @doc """
  The OTP application owning `table`, `:core` for one of core's own tables, or
  `nil` for a table core's chain does not create.
  """
  @spec owner(String.t()) :: atom() | nil
  def owner(table) when is_binary(table) do
    cond do
      Map.has_key?(@owner_by_table, table) -> Map.fetch!(@owner_by_table, table)
      table in @core_tables -> :core
      true -> nil
    end
  end

  @doc "The tables core's chain creates on behalf of the module `app`."
  @spec tables_for(atom()) :: [String.t()]
  def tables_for(app) when is_atom(app), do: Keyword.get(@owners, app, [])

  @doc "The last core migration version allowed to create or change a module's table."
  @spec last_core_version_touching_module_tables() :: non_neg_integer()
  def last_core_version_touching_module_tables, do: @last_core_version_touching_module_tables
end

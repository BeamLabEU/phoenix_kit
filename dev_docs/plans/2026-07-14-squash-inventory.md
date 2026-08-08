# Migration-chain inventory V01..V150 — appendix to the squash spec

Generated 2026-07-14 by 4 parallel classification agents reading every migration file
(v1.7.193, V01..V148), extended 2026-07-16 with V149-V150 (v1.7.196). Companion to
`2026-07-14-squash-migrations-spec.md`. Purpose: the baseline/manifest author's checklist —
what a fresh install must be seeded with, which operations are upgrade-only (excluded from the
baseline, D7), which objects were dropped/renamed along the chain (must NOT appear in the
baseline), and per-version hazards for anyone reproducing chain semantics.

Kind counts across V01..V148: ddl 141, backfill 28→31 (incl. sub-entries), destructive 21,
infra 20, seed 17. V149 = ddl (catalogue sourcing junction + soft CRM xref). V150 = ddl
(tokens browser/os columns via add_if_not_exists).

## Seeds (fresh install must have)
- V1: phoenix_kit_user_roles: Owner/Admin/User with is_system_role=true, ON CONFLICT (name) DO NOTHING (v01.ex:138-145)
- V3: phoenix_kit_settings: time_zone='0', date_format='Y-m-d', time_format='H:i', ON CONFLICT (key) DO NOTHING (v03.ex:34-42) — note module column doesn't exist yet; V04's UPDATE gives these module='system', so a baseline should seed them WITH module='system' directly
- V15: System email templates via Mix.Tasks.PhoenixKit.SeedTemplates run with apply/rescue; SKIPPED when Mix tasks unavailable (production releases) and errors swallowed (v15.ex:130-151) — template rows are NOT guaranteed present; verify-and-repair should treat them as optional/re-seedable
- V17: phoenix_kit_settings: entities_enabled='false', entities_max_per_user='100', entities_allow_relations='true', entities_file_upload='false', module='entities', ON CONFLICT (key) DO NOTHING (v17.ex:123-131)
- V20: phoenix_kit_storage_dimensions: 8 rows (thumbnail/small/medium/large/360p/720p/1080p/video_thumbnail) with Elixir UUIDv7.generate() ids and interpolated timestamps, ON CONFLICT (name) DO NOTHING (v20.ex:253-351); phoenix_kit_buckets: 'Local Storage' provider='local' endpoint='priv/media' priority=0 — INSERT with NO ON CONFLICT and no unique constraint (v20.ex:354-363): NON-IDEMPOTENT, re-run duplicates the bucket; phoenix_kit_settings: storage_redundancy_copies='1', storage_auto_generate_variants='true', storage_default_bucket_id=NULL, ON CONFLICT DO NOTHING (v20.ex:220-222,365-375; NULL value legal only because V12 dropped NOT NULL)
- V29: phoenix_kit_settings: 18 posts_* keys (posts_max_media='10' … posts_comment_moderation='false'), ON CONFLICT (key) DO NOTHING, but insert_setting OMITS the module column → module=NULL (v29.ex:486-529) — inconsistent with V17/V31 style
- V31: phoenix_kit_currencies: EUR (is_default=true), USD, GBP, ON CONFLICT (code) DO NOTHING (v31.ex:73-81); phoenix_kit_settings: 9 billing_* keys module='billing' (billing_enabled='false', billing_default_currency='EUR', billing_tax_enabled='false', billing_default_tax_rate='0', prefixes INV/ORD/RCP/TXN, billing_invoice_due_days='14'), ON CONFLICT DO NOTHING (v31.ex:442-455); billing_invoice/billing_receipt email templates via PhoenixKit.Modules.Emails.Templates.seed_system_templates with apply + rescue-all — best-effort, not guaranteed (v31.ex:523-525,768-795)
- V32: phoenix_kit_settings: ai_enabled='false' module='ai' ON CONFLICT DO NOTHING (v32.ex:182-187); phoenix_kit_settings: ai_text_processing_slots as value_json (JSON.encode! interpolated ::jsonb) ON CONFLICT DO NOTHING (v32.ex:190-228) — DELETED by V34; baseline must NOT seed it
- V33: phoenix_kit_settings: billing_stripe_enabled/billing_paypal_enabled/billing_razorpay_enabled='false', billing_subscription_grace_days='3', billing_dunning_max_attempts='3', billing_dunning_retry_days='3', module='billing', ON CONFLICT DO NOTHING (v33.ex:304-321)
- V35: phoenix_kit_user_roles: SupportAgent is_system_role=true — ON CONFLICT (name) DO UPDATE SET is_system_role=true (v35.ex:305-315): an UPSERT, not DO NOTHING; overwrites the flag on any pre-existing same-name role; down() deliberately never removes it (v35.ex:83); phoenix_kit_settings: tickets_enabled='false', tickets_per_page='20', tickets_comments_enabled/internal_notes_enabled/attachments_enabled='true', tickets_allow_reopen='true', ON CONFLICT DO NOTHING, module=NULL (v35.ex:317-346)
- V36: phoenix_kit_settings: connections_enabled='false', ON CONFLICT DO NOTHING, module=NULL (v36.ex:214-227)
- V43: phoenix_kit_settings: legal_enabled='false', legal_consent_widget_enabled='false', legal_cookie_banner_position='bottom' (module='legal') ON CONFLICT (key) DO NOTHING (v43.ex:104-111); phoenix_kit_settings value_json: legal_frameworks='{"items":[]}', legal_company_info='{}', legal_dpo_contact='{}' (module='legal') ON CONFLICT (key) DO NOTHING (v43.ex:114-121)
- V45: phoenix_kit_settings (module='shop'): shop_enabled='false', shop_currency='USD', shop_tax_enabled='true', shop_tax_rate='20', shop_inventory_tracking='true' ON CONFLICT (key) DO NOTHING (v45.ex:495-504); phoenix_kit_payment_options: 4 rows keyed by code — cod (active=true, pos 1), bank_transfer (inactive, pos 2), stripe (inactive, provider='stripe', pos 3), paypal (inactive, provider='paypal', pos 4) — ON CONFLICT (code) DO UPDATE on display fields (v45.ex:509-568)
- V53: phoenix_kit_role_permissions: 24 module_key rows for the Admin role (dashboard users media settings modules billing shop emails entities tickets posts ai sync publishing referrals sitemap seo maintenance storage languages connections legal db jobs), ON CONFLICT DO NOTHING, conditional on Admin role existing (v53.ex:32-37,90-113)
- V55: phoenix_kit_settings: comments_enabled='false', comments_moderation='false', comments_max_depth='10', comments_max_length='10000' ON CONFLICT (key) DO NOTHING (no module value) (v55.ex:117-125); phoenix_kit_role_permissions: module_key='comments' for Admin role, ON CONFLICT DO NOTHING (v55.ex:156-173)
- V59: phoenix_kit_settings: publishing_storage='filesystem' ON CONFLICT (key) DO NOTHING (v59.ex:247-251)

## Backfills (upgrade-only)
- V2: DELETE FROM phoenix_kit_user_role_assignments WHERE is_active=false — permanent upgrade-only cleanup (v02.ex:38-41)
- V4: UPDATE phoenix_kit_settings SET module='system' WHERE key IN ('time_zone','date_format','time_format','project_title') (v04.ex:85-89) — also shapes FRESH installs since it retro-tags V03's seeds; fold into baseline seed rows
- V8: Generates username for every existing user from email (downcase, dots→underscores, must start with letter, min length 3) with in-memory dedupe suffixes, executed IMMEDIATELY via SQL.query(RepoHelper.repo()) per-row UPDATEs (v08.ex:59-88) — upgrade-only, no-op on fresh installs
- V24: DELETE FROM phoenix_kit_files keeping DISTINCT ON (checksum) ORDER BY inserted_at ASC (v24.ex:51-64) — upgrade-only, destroys newer duplicate rows
- V26: UPDATE phoenix_kit_files SET user_file_checksum = encode(<pgcrypto_schema>.digest(user_id||file_checksum,'sha256'),'hex') WHERE NULL (v26.ex:50-54)
- V30: UPDATE users SET custom_fields = custom_fields || jsonb_build_object('preferred_locale', preferred_locale) WHERE preferred_locale IS NOT NULL (v30.ex:40-44)
- V40: UPDATE <table> SET uuid = <prefix>.uuid_generate_v7() WHERE uuid IS NULL — plain for small tables (v40.ex:239-244), batched 10k-row DO$$ loop with pg_sleep(0.01) for users/tokens/email_logs/email_events/audit_logs/entity_data/ai_requests (v40.ex:158-169,267-296) — upgrade-only; fresh tables are empty
- V44: UPDATE phoenix_kit_settings SET key='sync_*' WHERE key='db_sync_*' for 3 keys (upgrade-only; fresh installs seed sync_* names elsewhere)
- V47: string→JSONB wrap of 9 shop columns under default_language key (v47.ex:54-134); merge of V46 translations JSONB into the new per-field maps via jsonb_object_agg (v47.ex:138-227)
- V54: featured_product_id derived per category from first active product having featured_image_id, only WHERE image_id IS NULL (v54.ex:48-58) — upgrade-only
- V56: UPDATE ... SET uuid = uuid_generate_v7() WHERE uuid IS NULL on ~16 tables (v56.ex:329-333,354-359); UUIDFKColumns.up backfills every *_uuid FK from its integer FK via JOIN on source-table uuid (delegated, v56.ex:241); varchar→uuid USING uuid::uuid type rewrite on any phoenix_kit_% table found (v56.ex:521-525)
- V61: SET uuid = uuid_generate_v7() WHERE uuid IS NULL on the 6 tables (v61.ex:109-113); scheduled_jobs.created_by_uuid ← users.uuid JOIN on created_by_id (v61.ex:157-164)
- V63: ai_requests.account_uuid ← ai_accounts.uuid via account_id JOIN (v63.ex:132-139); email_orphaned_events.matched_email_log_uuid ← email_logs.uuid::uuid via matched_email_log_id JOIN, exception-tolerant (v63.ex:164-177); invoices.subscription_uuid ← subscriptions.uuid via subscription_id JOIN (v63.ex:198-205)
- V70: reset-then-rederive email_events.email_log_uuid from email_logs via email_log_id JOIN (v70.ex:121-159); reset-then-rederive email_orphaned_events.matched_email_log_uuid (v70.ex:180-203)
- V76: JSONB key rewrite in users.custom_fields: avatar_file_id → avatar_file_uuid WHERE key present (v76.ex:31-36)
- V77: UPDATE-based key renames on settings and role_permissions (upgrade-only)
- V78: ai_prompts uuid backfill WHERE uuid IS NULL inside ensure_uuid_column (v78.ex:131) — only fires on late-enabled-module installs
- V80: string→JSONB {'en': value} wrap of 5 email_templates columns; description NULL preserved as NULL (v80.ex:28-43)
- V81: phoenix_kit_entity_data.position = ROW_NUMBER() PARTITION BY entity_uuid ORDER BY date_created ASC WHERE position IS NULL (v81.ex:24-38)
- V88: posts.trashed_at = updated_at WHERE status='trashed' (v88.ex:362-378); versions.published_at copied from posts.published_at for published versions (v88.ex:380-400); posts.active_version_uuid = latest published version per post (DISTINCT ON, version_number DESC) (v88.ex:402-426); versions.data merged from post.data (allow_version_access/tags/seo) and best-language content.data (featured_image_uuid/description/seo_title/excerpt), primary_language-aware with 'en' fallback branch (v88.ex:428-516)
- V96: items.catalogue_uuid = category.catalogue_uuid WHERE category set AND catalogue_uuid IS NULL (v96.ex:45-51); orphan items (no category) pinned to oldest catalogue WHERE status <> 'deleted' ORDER BY inserted_at ASC LIMIT 1 (v96.ex:64-73)
- V107: endpoints with provider LIKE '%:%' matched exactly to settings key 'integration:' || provider (v107.ex:63-70); bare-provider endpoints matched to the most-recently-validated 'integration:<provider>:*' settings row via ROW_NUMBER ORDER BY value_json->>'last_validated_at' DESC NULLS LAST, uuid ASC (v107.ex:77-97)
- V109: UPDATE phoenix_kit_settings SET key='customer_support_*' WHERE key='customer_service_*' for 7 keys; collision -> DELETE source (v109.ex:60-71); UPDATE phoenix_kit_role_permissions SET module_key='customer_support' WHERE module_key='customer_service'; per-role collision -> DELETE source rows (v109.ex:75-91)
- V112: projects.archived_at = COALESCE(updated_at, NOW()) WHERE status='archived' AND archived_at IS NULL (v112.ex:195-202); scheduled_start_date DATE values preserved at midnight via ::timestamp(0) USING cast (v112.ex:251-268)
- V114: settings.key rewritten from 'integration:<provider>[:<name>]' to the row's uuid text; value_json backfilled with provider (from key position 13+, split on ':') and name (defaulting 'default'); module set to 'integrations' (v114.ex:93-112)
- V120: PL/pgSQL loop: each distinct lower(category) on phoenix_kit_doc_templates becomes an INSERT into phoenix_kit_doc_categories (uuid via #{prefix}.uuid_generate_v7(), display-name mapping 'financial'->'Financial', 'technical'->'Technical', else capitalize; positions 0..n), then UPDATE templates SET category_uuid, then documents inherit template's category_uuid (v120.ex:121-168). Entire block gated on the legacy column still existing — upgrade-only; fresh installs no-op (V117 created the column empty).
- V134: Pre-FK cleanup UPDATE: SET cover_file_uuid/logo_file_uuid = NULL WHERE value NOT IN (SELECT uuid FROM phoenix_kit_files) (v134.ex:84-88) — upgrade-only hygiene; a fresh baseline adds the FK with the column and never needs it.
- V135: INSERT INTO staff_skills: DISTINCT ON lower(LEFT(trim(token),255)) from regexp_split_to_table(people.skills, ','), ON CONFLICT (lower(name)) DO NOTHING (v135.ex:103-109); INSERT INTO staff_person_skills joining on the 255-capped token, ON CONFLICT DO NOTHING (v135.ex:114-120); UPDATE people.translations stripping 'skills' subkeys via jsonb_object_agg(lang, submap - 'skills') (v135.ex:125-130). Whole block gated on the skills COLUMN still existing (v135.ex:92-97) — upgrade-only.
- V136: INSERT..SELECT one employment span per person having any employment data, lifting per-locale job_title overrides from people.translations into the span's translations (jsonb_object_agg over jsonb_each WHERE submap ? 'job_title'), guarded by NOT EXISTS on the span table per person (v136.ex:83-114). Upgrade-only: fresh installs have zero people so it no-ops; the denormalized columns are NOT dropped (v136.ex:29 moduledoc).
- V137: aws_message_id backfill: UPDATE email_logs from DISTINCT ON (aws_id) over COALESCE(headers->>'aws_message_id', headers->>'X-AWS-Message-Id', headers->>'MessageId') WHERE aws_message_id IS NULL, guarded by NOT EXISTS against the existing partial unique index on aws_message_id (v137.ex:86-107). Upgrade-only; not reversed on down (v137.ex:152-153).
- V141: UPDATE calendar_events SET status='active' WHERE status='confirmed' (v141.ex:98-100) — legacy-rows rename that runs on EVERY up/1 (drop CHECK, update, reset default, re-add CHECK, v141.ex:94-109); no-op on fresh installs.

## Drops/renames
- V2: column phoenix_kit_user_role_assignments.is_active (v02.ex:55-57); index idx_user_role_assignments_user_active (v02.ex:44-47); index idx_user_role_assignments_role_active (v02.ex:49-52)
- V12: NOT NULL constraint on phoenix_kit_settings.value (v12.ex:57-60) — baseline must create value as nullable
- V16: NOT NULL on phoenix_kit_users_tokens.user_id (v16.ex:140-152)
- V26: unique_index(:phoenix_kit_files,[:checksum]) from V24 (v26.ex:36); column rename phoenix_kit_files.checksum → file_checksum (v26.ex:39)
- V30: users.preferred_locale column + its index (from V28) (v30.ex:47-53) — conditional
- V33: DEFAULT 'bank' and NOT NULL on phoenix_kit_orders.payment_method (v33.ex:283-287) — baseline creates the column nullable with no default
- V34: settings rows: ai_text_processing_slots (seeded by V32), ai_vision_processing_slots, ai_image_gen_slots, ai_embeddings_slots (v34.ex:158-166)
- V44: tables phoenix_kit_db_sync_connections / phoenix_kit_db_sync_transfers (renamed away); 10 phoenix_kit_db_sync_* index names (renamed to phoenix_kit_sync_*); settings keys db_sync_enabled, db_sync_incoming_mode, db_sync_incoming_password (renamed)
- V47: columns phoenix_kit_shop_products: title, slug, description, body_html, seo_title, seo_description, translations (string/old forms); columns phoenix_kit_shop_categories: name, slug, description, translations (string/old forms); constraints phoenix_kit_shop_products_slug_key, phoenix_kit_shop_categories_slug_key (IF EXISTS)
- V51: index idx_shop_cart_items_unique (V45 definition) — replaced by MD5-hash variant; constraints phoenix_kit_orders_user_id_fkey / phoenix_kit_billing_profiles_user_id_fkey / phoenix_kit_tickets_user_id_fkey (dropped and recreated with SET NULL)
- V52: indexes phoenix_kit_shop_products_slug_unique_idx, phoenix_kit_shop_categories_slug_unique_idx (IF EXISTS); constraints phoenix_kit_shop_products_slug_unique/_slug_key, phoenix_kit_shop_categories_slug_unique/_slug_key (IF EXISTS)
- V54: column phoenix_kit_shop_categories.image_url
- V62: 36 old *_id column names (renamed to *_uuid): full list at v62.ex:21-64
- V64: constraint user_id_required_for_non_registration_tokens (from V16)
- V65: table name phoenix_kit_subscription_plans (renamed); index name phoenix_kit_subscription_plans_slug_uidx (renamed to _types_); columns subscriptions.plan_id / plan_uuid (renamed)
- V68: index idx_publishing_posts_group_slug (V59 unconditional definition; recreated as partial with same name)
- V71: column phoenix_kit_shop_import_logs.product_ids (integer[])
- V72: 30 Category A tables' column name id (renamed to uuid): list at v72.ex:29-42; orphaned rows in phoenix_kit_comments/_likes/_dislikes and dangling scheduled_jobs.created_by_uuid values (cleanup)
- V73: index names phoenix_kit_post_tag_assignments_post_id_tag_id_index, phoenix_kit_post_group_assignments_post_id_group_id_index, phoenix_kit_post_media_post_id_position_index, phoenix_kit_file_instances_file_id_variant_name_index (renamed to *_uuid_* forms, v73.ex:35-45)
- V74: all FK constraints on phoenix_kit_% tables whose referenced column is id (dynamic); ~100 integer FK columns (user_id, role_id, cart_id, endpoint_id, account_id, created_by, author_id, etc. — full list v74.ex:25-133); bigint id column (+sequence, + PK constraint) on 47 Category B tables (v74.ex:140-188)
- V75: sequence phoenix_kit_id_seq (CASCADE; removes DEFAULT on phoenix_kit.id)
- V76: column name phoenix_kit_shop_products.image_ids (renamed image_uuids); settings keys publishing_translation_endpoint_id, storage_default_bucket_id (renamed)
- V77: settings keys tickets_enabled, tickets_per_page, tickets_comments_enabled, tickets_internal_notes_enabled, tickets_attachments_enabled, tickets_allow_reopen, auto_granted_perm:tickets (renamed); role_permissions rows with module_key='tickets' (renamed/deduped)
- V84: renames phoenix_kit_mailing_lists -> phoenix_kit_newsletters_lists; renames phoenix_kit_mailing_list_members -> phoenix_kit_newsletters_list_members; renames phoenix_kit_mailing_broadcasts -> phoenix_kit_newsletters_broadcasts; renames phoenix_kit_mailing_deliveries -> phoenix_kit_newsletters_deliveries
- V88: posts columns: scheduled_at, status, published_at, primary_language, data (v88.ex:301-358); indexes: idx_publishing_posts_scheduled, idx_publishing_posts_group_status, idx_publishing_posts_group_published_at (v88.ex:141-143)
- V89: renames column phoenix_kit_cat_items.price -> base_price (v89.ex:21-29)
- V91: column phoenix_kit_locations.location_type_uuid (heal, v91.ex:117-124); index phoenix_kit_location_types_name_index (heal; never created in current chain) (v91.ex:200-207); renames phoenix_kit_locations.address -> address_line_1 (heal, v91.ex:126-133)
- V106: index phoenix_kit_projects_name_index (v106.ex:54)
- V109: DELETEs colliding customer_service_* settings rows and duplicate role-permission rows (v109.ex:64-66,80-85)
- V111: DROP TABLE IF EXISTS ... CASCADE on phoenix_kit_cat_pdf_pages, phoenix_kit_cat_pdfs, phoenix_kit_cat_pdf_extractions, phoenix_kit_cat_pdf_page_contents BEFORE recreation (v111.ex:55-58)
- V112: index phoenix_kit_projects_name_template_index (from V106); index phoenix_kit_projects_name_project_index (from V106); index phoenix_kit_project_tasks_title_index (from V101) (v112.ex:101-105,242)
- V114: composite 'integration:*' keys cease to exist (irreversible identity rewrite; down is best-effort with -<8-char-uuid-tail> suffix on collisions, v114.ex:125-148)
- V118: phoenix_kit_annotations_kind_check (V115 4-kind version) — replaced by 6-kind version
- V119: phoenix_kit_annotations_kind_check (V118 6-kind version) — replaced by 7-kind version
- V120: phoenix_kit_doc_templates.category column (v120.ex:171) — implicitly drops V117's phoenix_kit_doc_templates_category_index; phoenix_kit_doc_template_presets.category column (v120.ex:173-184) — implicitly drops V117's 3-col phoenix_kit_doc_template_presets_scope_index; recreates phoenix_kit_doc_template_presets_scope_index as (scope_type, scope_id) 2-col, gated on presets table existence (v120.ex:191-202)
- V121: phoenix_kit_annotations_kind_check (V119 7-kind version) — replaced by 8-kind version
- V123: V87's unique index phoenix_kit_cat_items_sku_index (partial, WHERE sku IS NOT NULL) — drop_if_exists(index(:phoenix_kit_cat_items, [:sku])) at v123.ex:93; baseline must NOT create any unique index on cat_items.sku
- V124: prior non-partial phoenix_kit_media_folders_name_parent_idx (DROP INDEX IF EXISTS with schema-qualified name, v124.ex:37) — baseline creates only the partial form (v124.ex:39-43)
- V130: phoenix_kit_annotations_kind_check (V121 8-kind version) — replaced by final 9-kind version (v130.ex:33-37)
- V135: phoenix_kit_staff_people.skills TEXT column (v135.ex:136) — baseline must NOT create it; per-locale translations['*']['skills'] keys rewritten away (irreversible value rewrite, documented lossy v135.ex:31-36)
- V137: duplicate email_events rows DELETEd (two self-join DELETEs keeping smallest UUIDv7, v137.ex:53-71) — irreversible row deletion on upgrade; no-op on fresh/empty tables
- V141: calendar_event_status CHECK (the CREATE TABLE's own version) is dropped and re-added identically each run (v141.ex:94-109)
- V144: conditional: phoenix_kit_machine_types, phoenix_kit_operations, phoenix_kit_defect_reasons DROPped CASCADE only when EXISTS and empty (maybe_drop_if_empty, v144.ex:256-272); these legacy module tables must NEVER appear in a baseline; any discovered FK constraint on machine_type_assignments.machine_type_uuid and machine_operations.operation_uuid (drop_fk_constraint, v144.ex:413-418) — baseline creates these columns FK-less

## Hazards flagged
- V1: CREATE SCHEMA only when prefix != 'public' AND schema missing (immediate repo().query schema_exists? check, v01.ex:16-31,162-169); raises if missing + create_schema: false; Helpers.ensure_extension!("citext") executes IMMEDIATELY via repo().query! so the citext type exists before the queued CREATE TABLE using :citext email (v01.ex:35; helpers.ex:148-156); Creates role_assignments.is_active + indexes idx_user_role_assignments_user_active/_role_active (v01.ex:108,122-130) which V02 drops — baseline must NOT include them; idx_users_active (v01.ex:132-135) survives; Version comment stamp `COMMENT ON TABLE ... IS '1'` (v01.ex:152); INSERT uses inspect(prefix) quoted-identifier idiom (v01.ex:139)
- V2: Module carries unused ceremony API (version/0, destructive?/0, validate_prerequisites/2, v02.ex:99-164) found nowhere else in the chain
- V3: INSERT target uses #{inspect(prefix)} double-quoted identifier (v03.ex:35)
- V4: Bare `alter table ... add :module` — non-idempotent (v04.ex:33-35); FK added via `modify :code_id, references(...)` (v04.ex:79-82) — re-run duplicates the constraint
- V5: Bare `add` — non-idempotent
- V7: FK via `modify` non-idempotent; all indexes explicitly named phoenix_kit_email_logs_* / phoenix_kit_email_events_* — baseline must reproduce exact names
- V8: flush() at v08.ex:42 is load-bearing: DDL must exist before the immediate SQL backfill; unique index phoenix_kit_users_username_uidx WHERE username IS NOT NULL created only after backfill (v08.ex:48-52); Uses PhoenixKit.RepoHelper.repo() + Ecto.Adapters.SQL directly, outside the migration command queue
- V10: Bare `add`s inside alter — non-idempotent
- V13: NON-IDEMPOTENT bare `create unique_index` (not create_if_not_exists) named phoenix_kit_email_logs_aws_message_id_index WHERE aws_message_id IS NOT NULL (v13.ex:61-65); V22 later creates a SECOND partial unique index on the same column with a different name (_uidx) — a fresh full chain ends with BOTH; baseline author must pick one deliberately
- V15: Version comment '15' stamped at v15.ex:97 BEFORE flush() (v15.ex:100) and seeding — stamp does not imply seeds ran; flush() is one of only four in v01–v40 (V08, V15, V31, V40); uuid columns here mean V40 later SKIPS this table via its column_exists? guard
- V16: Bare ADD CONSTRAINT with no existence guard — non-idempotent (v16.ex:185-195); Upstream V64 later DROPS this constraint and replaces it with a user_uuid-based one (postgres.ex moduledoc V64 entry) — a baseline with floor ≥ 64 must not create the V16 constraint at all
- V17: FK guard uses `conrelid = '<prefixed table>'::regclass` inside a QUEUED execute (v17.ex:106-121) — safe only because the table CREATE is queued earlier in the same version; the regclass idiom raises if used in an immediate check before flush (see CLAUDE.md prefix rules)
- V20: Seed ids/timestamps generated at migration runtime in Elixir (v20.ex:384-387) — not reproducible SQL; the phoenix_kit_files.checksum column created here is renamed by V26; files.checksum column created here is renamed to file_checksum in V26 — baseline creates file_checksum directly
- V21: V22 re-issues create_if_not_exists with the identical name (v22.ex:65-70) — second is a no-op
- V22: add_if_not_exists columns (v22.ex:44-52) exist to tolerate installs that skipped V13 — pure no-op on the normal chain; Creates phoenix_kit_email_logs_aws_message_id_uidx (v22.ex:56-62) DUPLICATING V13's phoenix_kit_email_logs_aws_message_id_index — both survive a fresh chain; baseline should keep exactly one and verify-and-repair must not flag the other as drift blindly
- V23: Indexes use Ecto default naming (no :name option) — baseline must reproduce default-derived names
- V24: The unique index created here (v24.ex:32) is dropped again by V26 — baseline must NOT include it
- V26: Helpers.ensure_extension!("pgcrypto") runs IMMEDIATELY (v26.ex:33; helpers.ex:148-156); Index name interpolates prefix: "#{prefix}_phoenix_kit_files_user_file_checksum_index" (v26.ex:62-65) → 'public_phoenix_kit_files_user_file_checksum_index' on default installs — baseline must reproduce this odd name or migrate it deliberately; bare `create` non-idempotent; Backfill uses Helpers.pgcrypto_call/1 which resolves pgcrypto's REAL installation schema at migration time (helpers.ex:105-107,224-235)
- V27: create_schema: false is load-bearing — without it Oban defaults to true for non-public prefixes and executes CREATE SCHEMA, which fails for low-privilege roles (v27.ex:50-56); Oban schema version floats with the installed Oban dep — a baseline must keep the delegation, never inline Oban DDL; Oban tables land in the SAME prefix as PhoenixKit tables; host Oban config must carry the prefix
- V28: Bare `create index` non-idempotent (v28.ex:60)
- V29: post_tag_assignments and post_group_assignments have NO primary key column (v29.ex:343-357,411-431)
- V30: CONFIRMED fresh-chain flaw: the guard uses an immediate query via Application.get_env(:phoenix_kit,:repo) (v30.ex:91-109) while V28's `add` is still BUFFERED (last flush was V15's, next is V31's; cf. the identical V40 bug documented at v40.ex:177-183 and postgres.ex:471-477). On a fresh one-migration chain the check sees no column, skips the drop, then V31's flush executes V28's add — the column and index SURVIVE on fresh installs, and no later version (grep v01–v148) removes preferred_locale. Baseline must exclude it; verify-and-repair should expect this column as known drift on fresh-chain installs; Uses Application.get_env repo directly instead of repo() (v30.ex:107-109)
- V31: Version comment '31' written BEFORE flush() + template seeding (v31.ex:521-525); This flush() was the LAST flush before V40 historically — the root cause window of the V61 safety-net bug (postgres.ex:471-477); paid_amount conditional add: information_schema check anchored by table_schema ONLY when prefix truthy (v31.ex:424-437) — unanchored for nil prefix
- V32: JSONB seed built by string-interpolating JSON.encode! output into SQL
- V33: prefix_table_name here special-cases "public" to a BARE name (v33.ex:401), unlike most versions which emit public. or rely on nil; phoenix_kit_subscription_plans created here is RENAMED to phoenix_kit_subscription_types by upstream V65 (postgres.ex moduledoc) — floor ≥ 65 baselines must create the new name
- V34: Net effect for baseline: never create the slot settings; ai_accounts table is intentionally KEPT for historical request references (v34.ex:38-40)
- V35: CHECK constraint phoenix_kit_ticket_attachments_parent_check added via queued DO$$ + regclass (v35.ex:234-250)
- V37: FK guards use conrelid regclass in QUEUED executes — order-safe within the version, but the idiom is the one CLAUDE.md flags as fatal in IMMEDIATE checks
- V38: prefix_table_name special-cases "public" to bare (v38.ex:140-141), same family as V33
- V40: flush() FIRST (v40.ex:183) is load-bearing: the immediate repo().query table_exists?/column_exists? checks (v40.ex:324-359) see only flushed state; before this fix V32-V39 tables were skipped, patched later by upstream V61/V63 safety nets (postgres.ex:471-495); Helpers.ensure_uuid_v7_function(prefix) creates the function schema-qualified with pg_proc existence guard and pgcrypto-schema-qualified gen_random_bytes (v40.ex:191; helpers.ex:47-70,191-217); Postgres.up/1 re-ensures it for upgrade chains starting ≥ V40 (CLAUDE.md) — the baseline must own function creation via the same helpers; DEFAULT <prefix>.uuid_generate_v7() is deliberately KEPT after backfill (v40.ex:258-261) — baseline columns need the default too; `#{prefix}.uuid_generate_v7()` interpolation (v40.ex:230,241,278) assumes non-nil prefix (with_defaults normalizes to 'public', postgres.ex:1680-1688); Index names are bare {table}_uuid_idx via CREATE UNIQUE INDEX IF NOT EXISTS (v40.ex:247-250); phoenix_kit_email_templates is skipped because V15 already created its uuid columns
- V41: table_exists? uses IMMEDIATE PhoenixKit.RepoHelper.repo().query! (v41.ex:160-171) with NO flush() first — on a fresh chain the AI tables (V32/V34/V38) may still be queued, so V41 silently skips; V78 exists solely to repair this; FK add guarded by pg_constraint conname + conrelid regclass cast (v41.ex:52-56) — regclass idiom, but safe here because inside queued DO block after the table-exists gate; integer prompt_id column is later superseded by prompt_uuid (V78) and dropped by V74 — baseline must NOT create it; version comment '41' (v41.ex:110); prefix_table_name qualifies public as public.* (v41.ex:173-174)
- V42: FK DO block catches undefined_table so it works even if users table missing (v42.ex:110-114); created_by_id bigint FK later dropped by V74; created_by_uuid companion added by V61 — baseline should create created_by_uuid only; resource_id (binary_id) renamed to resource_uuid by V62; id PK later renamed to uuid by V72 and default fixed by V75 — baseline: uuid PK DEFAULT <prefix>.uuid_generate_v7(); prefix_table_name(nil) yields bare name here (v42.ex:214) — inconsistent with V41's public-qualifying variant
- V43: consent_logs created WITHOUT uuid column though the Ecto schema expects one — repaired by V56; baseline must include uuid UUID NOT NULL DEFAULT uuid_generate_v7() + unique index from the start; timestamps utc_datetime_usec later converted to timestamptz by V58 (already tz-aware here); version comment '43' (v43.ex:147)
- V44: Pure rename migration — a fresh baseline creates the sync_* names directly and must never emit db_sync_* objects; settings-key rename UPDATE guarded by NOT EXISTS on target key (v44.ex:292-303) — collision-safe; all table/index existence checks correctly anchored to schema via COALESCE('#{prefix}','public') / schemaname
- V45: Everything here is later reworked: gen_random_uuid→uuid_generate_v7 (V56), timestamp→timestamptz (V58), string title/slug→JSONB (V47), image/file _id cols renamed _uuid (V62), bigint id PK dropped + uuid promoted (V74) — baseline must emit the FINAL shape, not this one; payment-options seed uses ON CONFLICT (code) DO UPDATE overwriting name/description/instructions/icon/position/requires_billing_profile (v45.ex:561-567) — NOT a pure DO NOTHING seed; re-running clobbers admin edits to those fields (active is preserved); idx_shop_cart_items_unique (cart_id, product_id) WHERE variant_id IS NULL (v45.ex:368-371) is dropped and redefined by V51 — baseline should create only the V51 form; prefix_str treats "public" as "public." here (v45.ex:32) unlike V46+ which use bare names for public
- V46: translations JSONB columns added here are DROPPED by V47 — baseline must not create them; image_id→image_uuid, featured_image_id→featured_image_uuid renamed by V62; image_ids→image_uuids by V76; required_columns default ARRAY['Handle','Title','Variant Price'] on import_configs (v46.ex:176); nullable uuid columns repaired by V56 (NOT NULL + v7 default)
- V47: NOT re-runnable: after the rename, `title` is JSONB; a second pass re-adds title_new then the step-2 UPDATE compares JSONB `title != ''` against text — SQL error. Only the version gate prevents this; backfill reads (SELECT value FROM settings WHERE key='default_language') inline in every CASE arm (v47.ex:60 etc.); dropped constraints are named *_slug_key here but V45 created them as *_slug_unique — V52 cleans up both spellings; baseline: create title/slug/description/body_html/seo_title/seo_description (products) and name/slug/description (categories) as JSONB DEFAULT '{}' directly, plus the two GIN slug indexes (phoenix_kit_shop_products_slug_gin_idx, phoenix_kit_shop_categories_slug_gin_idx)
- V48: user_id bigint FKs later made nullable (V66/V67) then dropped (V74); post_id/comment_id renamed *_uuid (V62); id renamed uuid (V72) with DEFAULT restored by V75 — baseline shape: uuid PK DEFAULT uuid_generate_v7(), post_uuid/comment_uuid/user_uuid columns only; naive_datetime timestamps converted to timestamptz by V58; prefix_table_name("public") → bare name (v48.ex:189)
- V49: product_ids is DROPPED by V71 and replaced with product_uuids uuid[] — baseline creates product_uuids only, never product_ids
- V50: SET LOCAL lock_timeout pattern (v50.ex:28,46) is unique to this version — a baseline folding this in just adds the column at CREATE TABLE time; the DO-block checks information_schema.columns with explicit table_schema anchor — the model idiom for conditional adds
- V51: CREATE UNIQUE INDEX idx_shop_cart_items_unique has NO IF NOT EXISTS (v51.ex:41) — non-idempotent; re-run fails with duplicate_object; pg_constraint checks use conrelid='...'::regclass INSIDE the table-EXISTS guard (v51.ex:60-62) — safe only because the outer IF gates it; the naked regclass idiom is the CLAUDE.md-documented 25P02 trap; these FK semantics (SET NULL + nullable user_id) are moot post-V74 (integer user_id dropped entirely) — baseline needs none of this; version comment '51' (v51.ex:130)
- V52: Function is a permanent runtime dependency (backs unique indexes) — baseline MUST create <prefix>.extract_primary_slug and the two functional indexes; CREATE UNIQUE INDEX inside the DO blocks lacks IF NOT EXISTS (v52.ex:65,90) — re-run with index present raises (guarded only by table-exists, not index-exists); function name is prefix-qualified at creation AND at both call sites in the index expression (v52.ex:67,92) — reproduce exactly for prefixed installs
- V53: Seed resolves Admin role by name='Admin' at runtime inside a DO block; skips silently if roles table or Admin row absent (v53.ex:94-111) — a baseline must reproduce this Admin full-grant or admins lose the whole admin UI; permission key list is compile-frozen here (24 keys incl. 'tickets' which V77 renames to 'customer_service' and V109 further renames to 'customer_support' at the ROW level — at any candidate floor ≥ 110 the baseline seeds customer_support, not tickets/customer_service); role_id/granted_by integer FKs later nullable (V67/V69) then dropped (V74); role_uuid/granted_by_uuid companions come from UUIDFKColumns in V56/V57; uuid column repaired by V56/V73/V75 — final shape: uuid PK, role_uuid+module_key unique; ON CONFLICT (role_id, module_key) DO NOTHING (v53.ex:108)
- V54: featured_product_id (integer) is dropped by V74 — the UUID companion comes via UUIDFKColumns; baseline should carry featured_product_uuid only; the auto-populate backfill (v54.ex:48-58) references featured_image_id which V62 renames — order-sensitive on replays
- V55: gen_random_uuid PK defaults fixed to uuid_generate_v7 by V56/V75; resource_id/parent_id/comment_id renamed *_uuid by V62; user_id FKs go nullable (V67) then dropped (V74); missing user_uuid FK constraints added by V72 — final shape differs substantially; settings seed omits the module column (unlike V43/V45) (v55.ex:117-124); Admin 'comments' permission seeded via same conditional-DO-block pattern as V53 (v55.ex:156-173)
- V56: Pure repair/convergence layer — on a correct fresh baseline every operation is a no-op; the baseline replaces this by creating final columns directly, but MUST still ensure uuid_generate_v7() exists first (Helpers.ensure_uuid_v7_function); leans on IMMEDIATE repo().query existence checks (v56.ex:534-568) with an explicit leading flush() (v56.ex:203) — the flush-before-introspection pattern the baseline author must preserve anywhere introspection meets queued DDL; delegates to shared module PhoenixKit.Migrations.UUIDFKColumns (v56.ex:241-244) — companion columns, NOT NULL+FK constraints, and backfills live OUTSIDE the versioned file; the moduledoc admits V56 behaves differently depending on when it ran (V57 re-runs it); dynamic type-conversion loop uses set-returning repo().query then queued executes (v56.ex:516-529); prefix interpolation #{prefix}.uuid_generate_v7() assumes non-nil prefix (v56.ex:325); index names get prefix_-prepended on non-public prefixes (v56.ex:574-576) — naming quirk to reproduce or consciously drop
- V57: No-op on a correct baseline — exists only because a shared helper module changed under an already-applied version; cautionary tale for the baseline spec: never let external modules drift under stamped versions
- V58: Baseline should declare every timestamp column TIMESTAMPTZ from creation, making this whole version vanish; the @timestamp_columns list is the closest thing to a full-schema census at V58 — useful as a verify-and-repair checklist input; up-cast needs no USING (implicit UTC), down requires USING col AT TIME ZONE 'UTC' (v58.ex:276-277)
- V59: First module written in the FINAL conventions (v7 UUID PK, timestamptz) — good template for baseline table shapes; group_id/post_id/version_id renamed *_uuid by V62; created_by_id/updatedated_by_id bigints dropped by V74; idx_publishing_posts_group_slug replaced by V68 partial index — baseline uses the V68 form and _uuid names; #{prefix}.uuid_generate_v7() interpolation requires non-nil prefix (v59.ex:42)
- V60: escape_prefix/1 calls String.replace on the prefix (v60.ex:73) — crashes on nil prefix (up-chain normalization saves it); upgrade-gap filler: baseline includes these columns in the email_templates CREATE
- V61: Documents the root flush() pathology: repo().query() is immediate while execute is buffered, so V40 skipped every table created after V31's flush (v61.ex:3-33) — THE core hazard the baseline/verify tool must design around; double flush(): before and after ensure_uuid_v7_function (v61.ex:65-72); known bug fixed later: listed ai_requests where ai_accounts was intended (per V63 moduledoc) — ai_accounts got its uuid only at V63; non-public index names in remove path get prefix_-prepended (v61.ex:234-236) but the CREATE at v61.ex:116 uses the bare #{table}_uuid_idx — asymmetric
- V62: Pure rename — baseline creates *_uuid names directly; every earlier CREATE in v29-v59 that used the _id spelling must be emitted with the _uuid spelling; guard checks old column existence only (not new-absent) — a table with BOTH would fail the ALTER; acceptable because V62 assumes V56 shape
- V63: Three deliberate flush() calls — before introspection, after function ensure, and after the ai_accounts.uuid add so the JOIN backfill can see it (v63.ex:46-58) — the ordering is load-bearing; the email-log backfill anticipates varchar uuid type mismatch and swallows it with RAISE WARNING, explicitly deferring to V70 (v63.ex:164-177) — an early instance of the verify-and-repair pattern the new requirement asks for
- V64: ADD CONSTRAINT has no existence guard (v64.ex:27-36) — re-run raises duplicate_object; only the version gate protects it; baseline: emit only the user_uuid variant on users_tokens
- V65: Baseline creates phoenix_kit_subscription_types + subscription_type_uuid directly; subscription_plans name must never appear; ALTER INDEX IF EXISTS ... RENAME is unqualified (no schema prefix, v65.ex:60-63) — on prefixed installs resolves via search_path; potential prefix blind spot
- V66: Interim fix only — those user_id columns are deleted by V74; irrelevant to the baseline
- V67: Handles the V65 rename ambiguity by listing both column names (v67.ex:125-128) — a version-skew accommodation the baseline doesn't need; all columns in this list are dropped by V74 — zero baseline impact
- V68: DROP INDEX IF EXISTS idx_publishing_posts_group_slug is schema-UNQUALIFIED (v68.ex:32) — on a prefixed install it targets whatever search_path resolves, potentially missing the prefixed index (prefix blind-spot family from CLAUDE.md); down-direction backfills NULL slugs to 'migrated-'||uuid before restoring NOT NULL (v68.ex:61) — up has no backfill; baseline: publishing_posts.slug nullable + the two partial unique indexes; never the V59 unconditional one
- V69: All three columns dropped by V74 — no baseline impact
- V70: Model for the requested verify-and-repair capability: detect-bogus → NULL-reset → batched idempotent re-derive, all EXCEPTION-guarded so a live prod run can't abort the transaction; documents the 25P02 aborted-transaction failure mode of rescue-around-execute (v70.ex:16-27); batched UPDATE uses ctid IN (SELECT ... LIMIT 10000) + pg_sleep(0.01) (v70.ex:137-153) — live-DB-safe batching idiom
- V71: Data in product_ids is discarded, not converted — acceptable because the column was mistyped, but it is a silent data drop on upgrade; baseline: shop_import_logs carries product_uuids uuid[] only
- V72: Orphan cleanup DELETEs rows (CASCADE-mode) from comments tables before adding FKs (v72.ex:131-139) — destructive on live data, logged only via RAISE NOTICE; the rename silently drops any sequence-based DEFAULT the id column carried — V75 exists to restore defaults; a baseline names the PK uuid with the v7 default from the start; FK existence check uses conrelid regclass but inside table-exists guard (v72.ex:113-117); fk constraint naming: fk_<table-minus-prefix>_<col> (v72.ex:188-191)
- V73: down's DROP NOT NULL correctly refuses to touch PK columns via a PRIMARY KEY constraint check (v73.ex:130-139) — because V74 may already have promoted uuid to PK; index existence checks properly anchored on schemaname (v73.ex:160-163,192-195); baseline: these NOT NULLs/unique indexes/index names are simply the final CREATE forms
- V74: DROP COLUMN id CASCADE (v74.ex:267) also destroys the PK constraint, its sequence, and any dependent FK indexes — the single most destructive statement in the chain; after V74 no integer id/_id columns exist anywhere: the baseline emits pure-UUID tables and must NOT create any of the ~100 dropped columns; dynamic constraint-drop is schema-anchored (tc.table_schema = escaped_prefix, v74.ex:229) — the verify-and-repair tool can reuse this census query; ADD PRIMARY KEY guarded on absence of any PK (v74.ex:270-282)
- V75: #{prefix}.uuid_generate_v7() interpolation (v75.ex:74) assumes non-nil prefix; DROP SEQUENCE ... CASCADE (v75.ex:91) touches the phoenix_kit version-tracking meta table's id default — baseline must decide the final meta-table shape deliberately; down is comment-only
- V76: settings-key UPDATEs have no target-exists guard (unlike V44/V77) — if both keys existed a unique violation would abort; practically safe because only one spelling was ever seeded; flush() at start; column_exists? treats nil prefix as public (v76.ex:87-105)
- V77: rename_setting deletes the OLD key when the new one already exists (v77.ex:45-56) — collision-safe but silently discards the old value; permission rename dedupes per role_uuid before UPDATE (v77.ex:60-76); baseline: NB the V77 names are NOT final — V109 renames customer_service_* → customer_support_* (see v81-v115 notes), so at any candidate floor ≥ 110 the baseline seeds customer_support_* keys and the customer_support permission (the tickets_* seeds live in V35, outside this range); the V53 seed list's 'tickets' entry must become customer_support in the baseline
- V78: table_exists? is IMMEDIATE repo().query! with NO flush() first (v78.ex:107-118) — same V41 pathology; works upgrade-only because prior versions flushed, but a squashed replay must not inherit this ordering blindly; pg_constraint check uses '...'::regclass cast in a QUEUED DO block (v78.ex:50) — safe only because the outer table_exists? gate ran; the naked-regclass 25P02 trap documented in CLAUDE.md; prefix_str/1 has NO nil clause (v78.ex:140-141) — relies on Map.get(opts,:prefix,"public") at v78.ex:15; baseline: ai_endpoints carries reasoning columns and ai_requests carries prompt_uuid/prompt_name + FK from creation
- V79: Fully final-convention module — direct copy into the baseline; #{prefix}.uuid_generate_v7() in DEFAULT (v79.ex:25) breaks if prefix nil while prefix_str(nil) → "" (v79.ex:194) — inconsistent nil handling, moot because entry points normalize; FK to phoenix_kit_email_templates(uuid) means baseline table-creation ORDER matters: email_templates (V15-lineage) before newsletters
- V80: Moduledoc records the historical missed-version-marker bug: this version once failed to write COMMENT '80', so an interrupted multi-version run (disable_ddl_transaction, per-step autocommit) resumed at V80 and double-wrapped JSONB (v80.ex:19-25) — direct evidence the single-comment version stamp is the chain's only resume cursor and each baseline step must stamp it; the type-check guard is the canonical idempotency-retrofit idiom for irreversible USING conversions; baseline: email_templates content columns are JSONB from creation; seeded default templates (V15-lineage, outside range) must be seeded in {"en": ...} shape
- V81: IMMEDIATE Elixir-side existence check: table_exists?/2 runs PhoenixKit.RepoHelper.repo().query!(information_schema.tables) at migration-build time, not queued (v81.ex:66-77); whole body is conditional on phoenix_kit_entity_data existing (v81.ex:18); version comment stamped as trailing single execute: COMMENT ON TABLE {p}phoenix_kit IS '81' (v81.ex:46); prefix_str('public') -> 'public.' (v81.ex:79)
- V82: IMMEDIATE repo().query! table-existence check (v82.ex:36-47), same idiom as V81; version comment '82' at v82.ex:21
- V83: IMMEDIATE repo().query check via non-bang variant returning false on any error (v83.ex:55-58); prefix_str idiom differs: public -> EMPTY string, not 'public.' (v83.ex:13) — comment write is `COMMENT ON TABLE phoenix_kit IS '83'` unqualified on public installs (v83.ex:27); index name bare on CREATE (correct per prefix rules), qualified on DROP in down (v83.ex:35)
- V84: baseline must create newsletters_* names only; mailing_* must never appear; all conditionals are SQL-side (queued DO $$), safe ordering (v84.ex:78-91)
- V85: pure SQL-side guards; no immediate queries
- V86: uuid PK default via fragment("#{prefix}.uuid_generate_v7()") — schema-qualified function call (v86.ex:22,42,90); templates.variables jsonb default fragment('[]'::jsonb) — array-shaped default, easy to get wrong in a baseline (v86.ex:52); config map defaults %{paper_size: 'a4', orientation: 'portrait'} on templates and documents (v86.ex:74,117)
- V87: items are created WITH `price` column (v87.ex:159) which V89 renames to base_price — baseline must emit base_price directly; partial unique index on sku with where: clause (v87.ex:188-193)
- V88: asymmetric guarding: the column-adds DO block RETURNs early if phoenix_kit_publishing_posts is missing (v88.ex:30-36), but the 3 CREATE INDEX IF NOT EXISTS statements at v88.ex:103-119 are NOT table-guarded — they would raise if publishing tables were absent; safe only because the full chain always creates them earlier; new indexes: idx_publishing_posts_active_version (partial NOT NULL), idx_publishing_posts_trashed_at (partial IS NULL), idx_publishing_versions_published_at (DESC, partial NOT NULL); baseline: posts get active_version_uuid/trashed_at, versions get published_at, groups get *_i18n; legacy columns never exist
- V89: baseline emits base_price (never price) and markup_percentage on catalogues
- V90: prefix_str('public') -> '' (empty) in THIS file (v90.ex:56) — comment stamp unqualified on public installs; table has inserted_at only, default fragment('now()') (v90.ex:28)
- V91: heal block is upgrade-only (targets an 'early V90' prototype shape); on fresh installs the CREATEs above already produce the final shape — baseline reproduces only the final table shape; features JSONB NOT NULL DEFAULT '{}' when heal-added (v91.ex:196) vs :map default %{} in create (v91.ex:62) — nullable difference between fresh and healed installs
- V92: CHECK constraints are NAMED and created inline with the column ADD — a repair tool must check pg_constraint by name, not just column existence (v92.ex:42,100-101); partial unique index created via pg_indexes-guarded DO block, schemaname-anchored (v92.ex:123-137)
- V93: index uses operator class `text_pattern_ops` — must be reproduced exactly in a baseline (v93.ex:32)
- V94: all 8 column adds are individually DO-block-guarded; the two unique indexes are pg_indexes-guarded (v94.ex:151-181); doc_documents.status DEFAULT 'published' but NULLABLE (no NOT NULL) (v94.ex:64-65)
- V95: uses opts[:escaped_prefix] (Map.get(opts, :escaped_prefix, prefix)) for the information_schema check — the ONLY version in this range that reads escaped_prefix (v95.ex:14,110); prefix_str('public') -> '' in this file (v95.ex:141); COALESCE-functional unique index cannot be expressed via Ecto index/3 — raw SQL required in baseline (v95.ex:60-63); redundant heal: add_if_not_exists :color for pre-release installs (v95.ex:51-53)
- V96: the two backfill UPDATEs run unguarded (no table-exists check) — safe only because V87 guarantees the tables in-chain (v96.ex:45-73)
- V97: NULL-vs-0 semantics are load-bearing; baseline must keep the column nullable with NO default (v97.ex:37-38)
- V98: Postgres array-typed column with typed default — verify exact type text[] in repair checks (v98.ex:30)
- V99: index created via Ecto create_if_not_exists with where: + explicit name: (v99.ex:34-40)
- V100: functional unique indexes on lower(name)/lower(title) family — raw SQL only; all-raw-SQL style: table + index names must be byte-exact in a baseline
- V101: creates UNIQUE indexes phoenix_kit_projects_name_index (lower(name)) (v101.ex:70-73) and phoenix_kit_project_tasks_title_index (lower(title)) (v101.ex:48-51) — projects_name_index is DROPPED by V106, tasks_title_index and V106's replacements are DROPPED by V112: NONE of these unique-name indexes may appear in the baseline; named CHECK constraints phoenix_kit_project_tasks_single_default_assignee (v101.ex:43-44) and phoenix_kit_project_assignments_single_assignee (v101.ex:100-101); projects.scheduled_start_date created as DATE (v101.ex:62) but retyped to TIMESTAMP(0) by V112 — baseline emits TIMESTAMP(0)
- V102: pg_constraint guards use the `conrelid = '...'::regclass` idiom inside a QUEUED DO block (v102.ex:169,179,189,200,210) — safe here because the tables predate V102 in-chain, but this is exactly the idiom that aborts the transaction if the relation is missing (see V146 incident); a baseline/repair tool must use name-based JOINs instead; CHECKs: cat_catalogues_kind_check, cat_catalogues_discount_pct_check, cat_items_discount_pct_check, cat_items_default_value_check, cat_item_catalogue_rules_value_check — repair must verify by conname
- V103: FK deliberately has no ON DELETE clause (defaults to NO ACTION) — do not 'fix' to CASCADE in a baseline (v103.ex:37-38)
- V104: no updated_at column; partial DESC composite index (v104.ex:54-58)
- V105: uniqueness here is a table CONSTRAINT (not an index) — verify via pg_constraint (v105.ex:57)
- V106: BOTH replacement indexes are dropped again by V112 — the baseline has NO name-uniqueness indexes on phoenix_kit_projects at all; down/0 (only) performs an IMMEDIATE repo().query! duplicate-name pre-check before restoring the global index (v106.ex:96-115)
- V107: ORDER-COUPLING with V114: the backfill parses the pre-V114 composite key shape 'integration:provider:name' from settings.key — it only works because V107 runs before V114 rewrites keys to uuids; a repair tool re-running this logic on a post-V114 DB finds zero matching rows; CREATE UNIQUE INDEX on lower(name) is IF NOT EXISTS but can FAIL on upgrade if an existing install has duplicate endpoint names (data-dependent, no dedupe step) (v107.ex:104-107)
- V108: ALTERs assume all three tables exist (no table guard) — chain-order dependent; columns are NULLABLE with DEFAULT 0 (unlike V112's NOT NULL positions) — reproduce nullability exactly
- V109: SIGNATURE differs: up/down pattern-match `%{prefix: prefix}` — raises FunctionClauseError if opts lacks :prefix (every other version in range uses Map.get with 'public' default) (v109.ex:20,93); prefix_str has a nil clause -> '' (v109.ex:131); upgrade-only: fresh installs never have customer_service_* keys; baseline seeds (if any) must use customer_support_* naming
- V111: NOT idempotent in a data-preserving sense: re-running V111 unconditionally DROPs and recreates the 4 tables, wiping all PDF-library data — a verify-and-repair tool must NEVER replay V111's drop-first pattern on a live DB; Helpers.ensure_extension!("pg_trgm") runs IMMEDIATELY via repo().query! (helpers.ex:148-156), raising an operator-facing error if the extension is missing and the role lacks CREATE — baseline must call the same helper, never bare CREATE EXTENSION; uses plain `create table` (no if_not_exists) — safe only because of the preceding drops; GIN index with gin_trgm_ops opclass — raw SQL required (v111.ex:125-128)
- V112: baseline consequences: projects table keeps the now-unused `status` column (kept deliberately, v112 moduledoc), scheduled_start_date is TIMESTAMP(0) from day one, and NO unique-name indexes exist on projects/tasks; moduledoc misattributes the split indexes to V105 — they were created by V106; the DROPped names in code are correct (v112.ex:60-62); type-retype guard keys off information_schema data_type = 'date' — a repair pass must use the same data_type check for idempotence (v112.ex:255-261); note V112's position columns are NOT NULL DEFAULT 0 while V108's are nullable DEFAULT 0
- V113: ALTER COLUMN user_uuid DROP NOT NULL (v113.ex:104) — a baseline creating phoenix_kit_files must make user_uuid NULLABLE and include the compensating CHECK constraint; a naive repair that re-adds NOT NULL breaks tile rows; pg_constraint guards again use the '::regclass' idiom in queued DO blocks (v113.ex:87,147) — table exists in-chain, but repair code must not copy this into immediate checks; NOT VALID + VALIDATE CONSTRAINT two-step (v113.ex:149-154) — cheap on live DBs; the pattern to keep for the additive repair capability; down/0 DELETEs all system_managed=true file rows (destructive on rollback only, v113.ex:231)
- V114: upgrade-only; fresh installs never have integration rows during migration — but a VERIFY tool must assert the post-V114 invariant (no settings.key LIKE 'integration:%' with module='integrations' rows keyed composite) rather than replaying the rewrite; ordering-coupled with V107 (which consumes the pre-V114 key shape); prefix_str('public') -> '' in this file (v114.ex:151)
- V115: CHECK guard uses '::regclass' inside a queued DO block that executes after the queued CREATE TABLE — order-safe within the version but the idiom is repair-hostile (v115.ex:100)
- V116: IMMEDIATE check: table_exists?/2 uses PhoenixKit.RepoHelper.repo().query! against information_schema.tables (v116.ex:85-96) — sees only FLUSHED state. Works on a fresh chain only because phoenix_kit_entity_data is created at V17 (v17.ex:68) and the last flush() before this point is V76; a baseline author reordering versions could break this silently (skip = column never added, version comment still stamped).; If the gate returns false, up/1 still stamps COMMENT ON TABLE phoenix_kit IS '116' (v116.ex:63) — version advances without the DDL.; Column add uses DO $$ information_schema.columns guard anchored on table_schema (v116.ex:41-55); index via CREATE INDEX IF NOT EXISTS with bare name (v116.ex:57-60). FK on parent_uuid has deliberately NO ON DELETE action (context-layer managed).; Baseline must include: entity_data.parent_uuid UUID REFERENCES self(uuid), index (parent_uuid).
- V117: The category column, its index, and the 3-column preset scope index are all REMOVED/REPLACED by V120 — a squashed baseline must NOT carry doc_templates.category, phoenix_kit_doc_templates_category_index, presets.category, or the 3-col scope index (v117.ex:40-45,101-119 vs v120.ex:171-202).; Presets table created via raw SQL because Ecto :map can't express JSONB '[]' default (v117.ex:99-114); uuid default is #{prefix}.uuid_generate_v7() — schema-qualified call site.; document_sections uses Ecto create_if_not_exists with fragment("#{prefix}.uuid_generate_v7()") (v117.ex:52-56); FKs: document_uuid on_delete: :delete_all, template_uuid on_delete: :nilify_all (v117.ex:58-77).; ALTER on doc_templates is unguarded by table existence — relies on doc tables existing from earlier chain versions.
- V118: CHECK re-add is guarded by pg_constraint conname + conrelid '#{p}...'::regclass inside a queued DO $$ block (v118.ex:42-54) — evaluated SQL-side at flush, so the regclass trap doesn't bite, BUT V121/V130 comments (v121.ex:17-22) explain this conname guard is wrong on multi-prefix installs (conname unique per namespace, not global); the guard here is anchored by regclass so it is actually prefix-correct — the difference from V121's concern is the regclass anchor.; This CHECK is superseded again by V119, V121, V130 — baseline should emit only the FINAL 9-kind set (see V130).
- V119: trashed_at column added via DO $$ information_schema.columns guard with schema variable (v119.ex:33-46); partial index via Ecto create_if_not_exists index with where: + explicit name :phoenix_kit_media_folders_trashed_at_index (v119.ex:48-54).; trashed_at is a prerequisite for V124's partial unique name index — ordering matters in a baseline.; kind CHECK superseded by V121/V130; baseline emits only final set.
- V120: Baseline shape: doc_templates/doc_documents have category_uuid + type_uuid FK columns (ON DELETE SET NULL), NO category string; presets have NO category; scope index is 2-col. Baseline never needs the string->row backfill.; doc_types.category_uuid FK is ON DELETE :delete_all and NOT NULL (v120.ex:63-72); templates/documents FKs are ON DELETE SET NULL added via DO $$ information_schema guards (v120.ex:87-108).; Composite index (category_uuid, position) on doc_types deliberately replaces a standalone category_uuid index (v120.ex:77-81).
- V121: Establishes the DROP-then-unconditional-ADD idiom with an explicit comment (v121.ex:17-22): a bare pg_constraint conname guard (without table anchor) would be wrong on multi-prefix installs — a baseline author reproducing constraint guards must keep either the unconditional re-add or a table-anchored check.; Superseded by V130; baseline emits only final set.
- V122: HEAL/PRIOR-ART: the create_if_not_exists of phoenix_kit_locations (v122.ex:71-100) exists solely because v91.ex was mutated after release — a canonical example of why the project needs verify-and-repair; a baseline creates locations exactly once and this heal disappears.; kind CHECK is generated from module attribute @kinds ~w(floor room hall suite section zone aisle shelf corner) via Enum.map_join (v122.ex:56,154-162) — baseline must reproduce the exact 9-value list; status CHECK ('active','inactive') same DROP-then-ADD pattern (v122.ex:164-172).; location_spaces FKs: location_uuid on_delete: :delete_all NOT NULL, parent_uuid self-FK on_delete: :delete_all (v122.ex:108-127); composite index (location_uuid, parent_uuid, position).; down/1 also drops first_name/middle_name/last_name columns from an earlier unreleased V123 sketch (v122.ex:207-209) — evidence that released migrations were edited in place; irrelevant to a fresh baseline.; Staff ALTERs use ADD COLUMN IF NOT EXISTS with NOT NULL DEFAULT '{}'::jsonb (v122.ex:179-192) — assumes staff tables exist from earlier chain versions, unguarded on table existence.
- V123: folder_uuid added via DO $$ information_schema.columns guard with inline REFERENCES ... ON DELETE SET NULL (v123.ex:72-86).; cat_folders.parent_uuid is on_delete: :nilify_all (orphan-promote, not cascade) (v123.ex:44-52); composite (parent_uuid, position) index serves the self-FK (v123.ex:63-65).
- V124: Documents the prefix rule in-code: index name must be BARE on CREATE (lands in table's schema) but schema-qualified on DROP (v124.ex:27-32) — the load-bearing idiom for any baseline execute-built index SQL.; Depends on trashed_at existing (V119) — ordering constraint if versions are merged.
- V125: First version in range using the `#{p}uuid_generate_v7()` form (prefix-dot interpolation, v125.ex:122) instead of `#{prefix}.uuid_generate_v7()` — both resolve identically because prefix_str appends the dot; baseline should standardize on Helpers.uuid_v7_call/1.; FK to phoenix_kit_entities guarded via information_schema.table_constraints on constraint_name (v125.ex:166-183); index guards via pg_indexes with schemaname anchor (v125.ex:246-283) — the schema-anchored idioms a baseline keeps for its repair mode.; cross-module FK: projects -> entities table (both core-chain-owned, so a hard FK was acceptable here, unlike V138/V145 loose-uuid choices).
- V126: Baseline must create notifications with activity_uuid NULLABLE + metadata column from the start.; down/1 DELETEs rows WHERE activity_uuid IS NULL before restoring NOT NULL (v126.ex:46) — destructive only on rollback.; DROP NOT NULL is naturally idempotent (v126.ex:29).
- V127: Baseline must create project_assignments with task_uuid NULLABLE + the XOR check phoenix_kit_project_assignments_task_xor_child + FK ON DELETE RESTRICT + partial unique phoenix_kit_project_assignments_child_project_unique — reversing V127's relaxation would break the schema contract.; All guards are SQL-side DO $$ blocks anchored on table_schema (information_schema.table_constraints v127.ex:117-134,148-163; pg_indexes v127.ex:168-183).; down/1 DELETEs sub-project linking rows and cascades dependency edges (v127.ex:79-81) — rollback is feature-removal.
- V128: Fully parameterized helper pattern (add_assignee_column/create_assignee_index, v128.ex:62-131) with information_schema + pg_indexes schema-anchored guards; index names phoenix_kit_projects_assigned_{team|department|person}_idx.; Cross-module FK core-chain-owned (staff tables) — hard FKs deliberately, contrast V138/V140 soft refs.
- V129: Second canonical drift-repair in the range (moduledoc v129.ex:5-14 documents the V33/V65 chain bug): fresh ensure_current builds lacked the column entirely. A baseline creates subscriptions with subscription_type_uuid from the start and this version vanishes; the verify-and-repair capability should still check for its absence on legacy DBs.; Guards: information_schema.columns + table_constraints + pg_indexes, all schema-anchored (v129.ex:33-74).
- V130: This is the FINAL kind set as of V148 — baseline emits exactly this CHECK once; the V115→V118→V119→V121→V130 churn collapses.; Same multi-prefix guard warning comment as V121 (v130.ex:19-24).
- V131: Single ADD COLUMN IF NOT EXISTS (v131.ex:26-28); folds trivially into the baseline staff_people definition.
- V132: Single ADD COLUMN IF NOT EXISTS (v132.ex:19); folds into baseline media_folders definition.
- V133: Unique (owner_user_uuid, slug) relies on default NULLS DISTINCT so system dashboards (NULL owner) are unconstrained (v133.ex:52-55) — baseline must preserve exact index semantics.; role_uuid is deliberately NOT an FK. down/1 uses DROP TABLE ... CASCADE (v133.ex:64).; V139 later adds config JSONB — baseline folds it in.
- V134: FK guard uses the pg_constraint conname + conrelid '#{table}'::regclass idiom inside a QUEUED DO block (v134.ex:91-102) — safe at flush time because the table pre-exists, but it is the regclass idiom CLAUDE.md warns against for IMMEDIATE checks; a repair tool re-running this must keep it SQL-side.; The dangling-ref UPDATE runs unconditionally on every re-run (idempotent by predicate).
- V135: The PL/pgSQL column-existence gate exploits lazy planning so re-runs after the DROP are no-ops (v135.ex:86-88 comment) — a baseline creates the two tables + never creates skills column; the verify-and-repair path only needs the tables/indexes, not the parse.; 255-char token capping in BOTH insert and join is load-bearing against 'value too long' aborts (v135.ex:98-104 comment).
- V136: The backfill guard is per-person NOT EXISTS, not a global flag — re-runs after partial application only fill missing people (idempotent, good repair-mode prior art).; primary_team_uuid deliberately left NULL on backfill (no single primary derivable from team_memberships).
- V137: GIN gin_trgm_ops indexes require pg_trgm, enabled since V111 (v137.ex:39-40 moduledoc) — baseline must ensure the extension via Helpers.ensure_extension! before these indexes.; Dedup DELETEs rely on uuid being time-ordered UUIDv7 with no bigint id (dropped V74) — MIN(uuid) = earliest (v137.ex:22-25).; "to" column is a reserved word and stays double-quoted in the trgm index (v137.ex:112-115).
- V138: Establishes the loose-UUID soft-ref precedent for cross-module references (staff_person_uuid no FK, v138.ex:146-159) that V140/V145/V148 cite — baseline must keep these as bare UUID columns, NOT 'fix' them into FKs.; All raw SQL with `#{prefix}.uuid_generate_v7()` defaults and inline named CHECK/UNIQUE constraints (phoenix_kit_crm_party_exclusive_arc, phoenix_kit_crm_company_memberships_uniq).
- V139: Single ADD COLUMN IF NOT EXISTS (v139.ex:18-21); folds into V133's baseline dashboards definition.
- V140: Four CREATE SEQUENCE IF NOT EXISTS objects (…inventory_documents/internal_orders/supplier_orders/goods_receipts/goods_issues_number_seq) with nextval() column defaults (e.g. v140.ex:89-95) — baseline must create sequences BEFORE the tables referencing them, and down/1 shows the per-table sequence pairing (v140.ex:207-222).; quantity>=0 CHECK guarded by pg_constraint conname + regclass in a QUEUED DO block (v140.ex:73-85) — safe SQL-side; document for repair-mode reuse.; performed_by_uuid FK to phoenix_kit_users ON DELETE SET NULL on every document table; item/location/supplier/storage_folder integrity is app-layer only (v140.ex:24-33 moduledoc).
- V141: Moduledoc admits the migration was EXTENDED IN PLACE while unreleased (v141.ex:43-46) — same released-file-mutation pattern that caused the V91/V122 and V129 heals; baseline emits the final shape (status CHECK ('active','cancelled'), location_uuid present) directly and the drop/update/re-add ritual disappears.; Participants visibility joins physical staff/CRM tables at query time — the calendar tables have no cross-module FKs (loose target_uuid + display_name snapshot).; Timestamps here are TIMESTAMP(0) (no tz), unlike TIMESTAMPTZ elsewhere in the range.
- V142: Baseline must create role_permissions.module_key as VARCHAR(120) directly (not V53's 50).; down/1 DELETEs rows WHERE LENGTH(module_key) > 50 before narrowing (v142.ex:34-37) — destructive on rollback only.; The ALTER COLUMN TYPE is unguarded but naturally idempotent.
- V143: Uses the canonical Helpers.uuid_v7_call(prefix) fragment (v143.ex:30) — the pattern a baseline should standardize on.; Unique index has a NON-DEFAULT explicit name (v143.ex:53-60) — baseline must reproduce it exactly or the repair check will mismatch.; This is the exact version involved in the fork-renumber drift incident (memory: DB comment said 143 but held V144 content) — a strong argument for content-based verification, not comment-trusting.
- V144: IMMEDIATE repo().query in fk_constraint_name/3 (v144.ex:393-411, parameterized $1..$3, raises on error) — safe only because the FK sought pre-exists from external module 0.2.0 installs, never from queued DDL in this run (explicit comment v144.ex:388-391); a baseline author must not blindly copy this idiom next to same-run CREATEs.; maybe_drop_if_empty runs COUNT(*) + dynamic EXECUTE DDL inside a queued DO block — evaluated at flush; DROP ... CASCADE is a resilience net for partially-applied prior runs (v144.ex:246-255 comment).; down/1 drops machine_type_assignments unconditionally even on hosts where it pre-dates V144 (provenance indistinguishable, v144.ex:79-92).; machines table shape: CREATE with V1 columns then 10x ALTER ADD COLUMN IF NOT EXISTS for V2 columns (v144.ex:110-186) — baseline emits the merged final column list in one CREATE.
- V145: integration_uuid and send_profile_uuid are deliberately FK-less (loose-UUID pattern citing v138/v140, moduledoc v145.ex:7-12) — do not harden in a baseline.; At-most-one-default enforced by partial unique index on the boolean (v145.ex:53-56).; ALTER on newsletters_broadcasts assumes the table exists from earlier chain versions, unguarded.
- V146: The ONLY flush() in the v77..v148 span (v146.ex:33): required so the immediate constraint_exists? query sees phoenix_kit_cat_items whose CREATE (V87) is still queued on a fresh chain — without it the check either misses or, with a regclass idiom, would 25P02-poison the transaction. Baseline collapsing removes the need, but the verify-and-repair mode MUST inherit the name-based JOIN idiom (pg_constraint JOIN pg_class JOIN pg_namespace WHERE nspname = $1, v146.ex:82-98) instead of regclass for immediate checks.; up/1 pattern-matches %{prefix: prefix} (v146.ex:25) — unlike every other version's Map.get(opts, :prefix, "public") — so it REQUIRES the prefix key in opts (always present via with_defaults, but a divergence to note); also consumes opts.escaped_prefix with fallback (v146.ex:26).; constraint check runs with log: false via repo().query (v146.ex:94).
- V147: Uses Ecto DSL alter/add_if_not_exists rather than raw SQL (v147.ex:18-20) — folds into V143's baseline table definition.
- V148: CHECK guard uses pg_constraint conname + conrelid regclass in a QUEUED DO block (v148.ex:54-67) — safe because the CREATE TABLE precedes it in the same queue and both execute at the same flush; the same code as an immediate check would raise on fresh chains (the V146 lesson).; Polymorphic pair carries no FK by design (v148.ex:13-17) — keep loose in baseline.

## Chunk notes
CROSS-CUTTING (v01–v40, all claims from current code):
(1) Version stamping: every version's up ends with a single `COMMENT ON TABLE <prefix>.phoenix_kit IS '<n>'`; additionally the chain runner re-stamps the FINAL version once for multi-step runs (postgres.ex:1628-1641, record_version at 1674-1677). A baseline module must stamp its floor version identically (obj_description on the phoenix_kit table is the sole version store; the table's `version` column is never inserted into in this range).
(2) Buffering model: all version modules run inside ONE Ecto migration; execute/create calls queue until flush() or migration end. Explicit flush() sites in this range: v08.ex:42, v15.ex:100, v31.ex:524, v40.ex:183. Any IMMEDIATE repo().query check only sees flushed state. Two real consequences: (a) V40's pre-fix skip bug (fixed by leading flush; upstream V61/V63 are the safety nets, postgres.ex:471-495); (b) STILL-LIVE: V30's immediate column_exists? guard (v30.ex:38,91-109) runs while V28's buffered `add :preferred_locale` has not flushed (window V15→V31), so on a fresh full chain the drop is skipped and V28's add executes at V31's flush — fresh installs retain users.preferred_locale + index; no later version (v41–v148, grep) removes it. Baseline must EXCLUDE the column; verify-and-repair must classify a present preferred_locale as known, harmless drift (and could adopt dropping it).
(3) Net-state deltas (created-then-removed inside this range — baseline must OMIT): role_assignments.is_active + 2 indexes (V01→V02); files.checksum unique index and the column name checksum (V24→V26 rename to file_checksum); users.preferred_locale (V28→V30, with the caveat in note 2); settings ai_*_slots rows (V32→V34). Also removed later than this range but relevant to floor choice: V16's user_id CHECK constraint (replaced by V64) and phoenix_kit_subscription_plans (renamed by V65).
(4) Known duplicate: email_logs carries TWO partial unique indexes on aws_message_id after a fresh chain — V13's phoenix_kit_email_logs_aws_message_id_index (bare create, v13.ex:61-65) and V22's phoenix_kit_email_logs_aws_message_id_uidx (v22.ex:56-62). V21 and V22 both create phoenix_kit_email_logs_message_ids_idx (second is if-not-exists no-op).
(5) Non-idempotent spots a repair tool must special-case: V04 bare add + FK-via-modify; V07 FK-via-modify; V08 bare add; V13 bare create unique_index; V16 bare ADD CONSTRAINT; V20 default-bucket INSERT without ON CONFLICT (no unique key on buckets — re-run duplicates rows); V26 bare create unique_index; V28 bare create index. Everything else uses create_if_not_exists/add_if_not_exists/ON CONFLICT or DO$$ pg_constraint guards.
(6) Seed inventory a fresh install accumulates by V40: roles Owner/Admin/User (V01) + SupportAgent (V35, UPSERT semantics); settings — time_zone/date_format/time_format (V03, module retro-tagged 'system' by V04's UPDATE), 4 entities_* (V17, module='entities'), 3 storage_* (V20, module NULL, one NULL value), 18 posts_* (V29, module NULL), 9+6 billing_* (V31/V33, module='billing'), ai_enabled (V32, module='ai'), 6 tickets_* (V35, module NULL), connections_enabled (V36, module NULL); currencies EUR/USD/GBP (V31); storage_dimensions 8 rows + 1 'Local Storage' bucket (V20). Email templates (V15 via Mix task, V31 via Templates module) are best-effort Elixir seeding with rescue-all — NOT guaranteed present in production releases; verify-and-repair should treat them as re-seedable, not as schema drift.
(7) Oban: V27 is pure delegation (Oban.Migration.up, create_schema: false load-bearing, v27.ex:50-56); Oban's own internal versioning floats with the dep — baseline must keep the delegation call verbatim.
(8) Prefix idioms vary per version and matter for byte-identical SQL reproduction: most use local prefix_table_name (nil→bare, else prefix.); V33/V38 additionally map \"public\"→bare (v33.ex:401, v38.ex:140); V40 maps \"public\"→public. (v40.ex:363); V01/V03 use inspect(prefix) quoted identifiers in INSERTs; V26 embeds the prefix in an index NAME (v26.ex:64). with_defaults normalizes prefix (default 'public'), validates it, and supplies quoted_prefix/escaped_prefix/create_schema (postgres.ex:1680-1688). Extension/function infra is centralized in helpers.ex: ensure_extension! runs IMMEDIATELY (helpers.ex:148-156), ensure_uuid_v7_function queues guarded by pg_proc (helpers.ex:191-217), pgcrypto calls resolve the extension's real schema (helpers.ex:105-107,224-235).
(9) Elixir-runtime dependencies inside migrations (hazard for deterministic baselines): V08 (RepoHelper + Ecto.Adapters.SQL per-row updates), V15/V31 (apply on optional modules), V20 (UUIDv7.generate() + NaiveDateTime interpolation), V32/V34 (JSON.encode! interpolation), V30 (Application.get_env repo).
---
RANGE CHARACTER: v41–v55 build feature modules in OLD conventions (BIGSERIAL id PK, uuid gen_random_uuid() nullable, timestamp(0), _id FK names, string content columns); v56–v78 is a long convergence campaign (UUID identity → v7 defaults → _uuid renames → NOT NULL flips → V74 destruction of every integer id/FK) ending in the final all-UUID shape; v79–v80 are the first modules born in final conventions. A baseline for this range should emit ONLY the post-V78 shapes: uuid PK named `uuid` DEFAULT <prefix>.uuid_generate_v7(), TIMESTAMPTZ everywhere, *_uuid FK columns with real FK constraints, JSONB localized fields (shop title/slug/etc per V47, email_templates per V80), table names phoenix_kit_sync_* (never db_sync_*), phoenix_kit_subscription_types (never _plans), columns image_uuids/product_uuids/subscription_type_uuid, settings keys sync_*/customer_support_* (V109 form — this range's customer_service_* names are themselves renamed by V109)/publishing_translation_endpoint_uuid/storage_default_bucket_uuid, publishing partial slug indexes (V68 form), cart-items unique index in the V51 MD5(selected_specs) form, and V52's <prefix>.extract_primary_slug() function + functional indexes (a REQUIRED runtime dependency, not a repair artifact). SEEDS a fresh install needs from this range: V43 legal (6 settings), V45 shop (5 settings + 4 payment_options — note its ON CONFLICT DO UPDATE upsert semantics), V53 Admin all-permissions grant (with 'tickets' → 'customer_service' per V77 → 'customer_support' per V109; seed the V109 form), V55 comments (4 settings + Admin 'comments' permission), V59 publishing_storage. REPAIR/NO-OP VERSIONS that vanish in a baseline: V56, V57, V58, V60, V61, V63, V66, V67, V69, V70, V73, V75, V78 — but their MECHANISMS are the prior art for the new verify-and-repair requirement: V70 is the best template (detect-bogus → NULL-reset → ctid-batched re-derive → EXCEPTION-guarded, live-safe), V58's @timestamp_columns and V74's dynamic FK census are ready-made verification checklists, V63/V70's RAISE WARNING + defer-to-later-version pattern shows how to degrade gracefully. HAZARD FAMILIES: (1) immediate repo().query existence checks vs queued execute — V41 and V78 do introspection WITHOUT flush() (bug-in-waiting on replay; V61 moduledoc documents the pathology), V56/V61/V62/V63/V65/V66/V67/V68/V69/V70/V71/V72/V73/V74/V75/V76 all flush() first; (2) non-idempotent statements surviving only behind the version gate — V51:41 and V52:65,90 bare CREATE UNIQUE INDEX, V64:29 bare ADD CONSTRAINT, V47's whole string→JSONB conversion (re-run = SQL type error), V80 fixed the same class with a column_type guard; (3) prefix blind spots — V68:32 unqualified DROP INDEX and V65:60 unqualified ALTER INDEX, plus three different prefix_table_name conventions for 'public' (qualifies: V41/V43/V48-era helpers; bare: V42/V45/V46+); (4) every version ends with the single-statement COMMENT ON TABLE phoenix_kit IS '<n>' stamp — V80's moduledoc proves this comment is the chain's only resume cursor under disable_ddl_transaction, so the baseline must stamp the floor version exactly once at the end and the Oban-style skip logic must treat the comment as authoritative-but-corruptible (cf. memory note on renumber drift); (5) shared mutable helper modules (UUIDFKColumns used by V56/V57, Helpers.ensure_uuid_v7_function used by V56/V61/V63) mean stamped versions changed behavior after the fact — the baseline must inline or version-freeze such helpers. DESTRUCTIVE inventory for skip-semantics safety: V74 is irreversible (dynamic FK-constraint drops + ~100 column drops + id PK removals, down is comment-only), V72 deletes orphaned comment rows, V71 discards product_ids data, V47/V54 drop columns; an existing install being 'skipped past' the baseline must already be ≥ the floor version or these destructive semantics can never be re-derived from the baseline alone.
---
Range v81-v115 (/www/phoenix_kit/lib/phoenix_kit/migrations/postgres/). (1) ZERO seed versions in this range — no reference rows inserted anywhere; fresh-install data effects are limited to DDL defaults. (2) Every version stamps the version marker as a single trailing `execute("COMMENT ON TABLE {p}phoenix_kit IS 'NN'")` — one write, queued last; no version reads its own comment. (3) prefix_str is INCONSISTENT across files: 'public' maps to 'public.' in most (v81:79, v86:141, etc.) but to '' (empty) in v83:13 (inline), v90:56, v95:141, v114:151, and v109 additionally accepts nil->'' — semantically identical SQL on public installs, but a byte-comparison-based verifier must normalize. (4) Immediate (non-queued) DB access appears in exactly four places: V81/V82 repo().query! and V83 repo().query Elixir-side table_exists? checks (conditional skip of the whole version body when the module tables are absent — but in the current full chain those tables always exist), V106.down's duplicate pre-check, and V111's Helpers.ensure_extension!('pg_trgm') (helpers.ex:148-156, immediate repo().query!). No flush() calls and no Oban delegation anywhere in the range. (5) Baseline net-state deltas this range imposes on everything earlier: newsletters_* not mailing_* (V84); cat_items.base_price not price (V89); publishing posts WITHOUT scheduled_at/status/published_at/primary_language/data and without the 3 old indexes (V88); phoenix_kit_projects/tasks with NO unique-name indexes (V101->V106->V112 create-then-drop chains — baseline must emit none of phoenix_kit_projects_name_index, *_name_template_index, *_name_project_index, phoenix_kit_project_tasks_title_index); projects.scheduled_start_date TIMESTAMP(0) not DATE (V112); files.user_uuid NULLABLE + user_or_parent CHECK (V113); settings integration rows uuid-keyed with module='integrations' (V114); customer_support_* naming not customer_service_* (V109). (6) Upgrade-only transforms a squash can drop for fresh installs but the verify-and-repair spec must encode as INVARIANT ASSERTIONS (not replays): V81 position backfill, V88 publishing data merge, V96 catalogue_uuid backfill + orphan pinning, V107 integration_uuid backfill (reads PRE-V114 key shape — order-coupled, unreplayable post-V114), V109 key renames, V112 archived_at backfill + date->timestamp retype, V114 key rewrite. (7) Repair-tool hazards: V111 is drop-first (re-running wipes phoenix_kit_cat_pdf* data — must never be replayed); V107's unique lower(name) index can fail on dirty data (needs dedupe-or-report step); V102/V113/V115 use the pg_constraint `conrelid='...'::regclass` idiom (queued-safe in-chain, but per repo CLAUDE.md this idiom aborts transactions in immediate checks — repair code must use name-based pg_class/pg_namespace JOINs); V113's NOT VALID + VALIDATE CONSTRAINT two-step is the model for adding CHECKs additively on live DBs. (8) Functional/partial/opclass indexes that Ecto DSL cannot express (raw SQL required in baseline): lower(name)/lower(title) uniques (V100), COALESCE folder-name unique (V95), text_pattern_ops (V93), gin_trgm_ops (V111), plus ~15 partial (WHERE-clause) indexes across V88/92/94/99/101/104/112/113/115.
---
RANGE-WIDE FACTS (v116-v148), all verified against current code: (1) ZERO seed rows — no version in this range INSERTs reference/default rows a fresh install needs (all INSERT..SELECT/UPDATE statements are upgrade-only backfills gated on legacy columns/rows existing: V120 category strings, V134 dangling refs, V135 skills parse, V136 employment spans, V137 dedup+aws_message_id, V141 status rename). A baseline covering this range is pure DDL. (2) Version-comment protocol: every up/1 ends with COMMENT ON TABLE #{p}phoenix_kit IS 'NNN' and every down/1 stamps NNN-1; additionally the chain runner postgres.ex:1629-1633 re-records the final version after multi-step runs. The runner (postgres.ex:1603-1617) invokes each VNN.up(opts) inside ONE Ecto migration with NO per-version flush — commands queue, so immediate repo().query checks (V116 v116.ex:94, V144 v144.ex:406, V146 v146.ex:94) see only flushed state; the last flush() before this range is V76 and the only flush() inside it is V146's (v146.ex:33). V116's immediate table gate works only because phoenix_kit_entity_data dates to V17; V144's is safe only because the FK it hunts pre-exists from external module installs. (3) Net baseline deltas vs what earlier versions created: annotations kind CHECK ends at the 9-kind V130 set (V115/118/119/121 versions are dead churn); phoenix_kit_media_folders_name_parent_idx ends PARTIAL (V124); V87's cat_items sku unique index must NOT exist (V123); doc_templates/presets 'category' string columns + templates_category_index must NOT exist and the presets scope index is 2-col (V120); staff_people.skills column must NOT exist (V135); role_permissions.module_key is VARCHAR(120) (V142); notifications.activity_uuid nullable + metadata (V126); project_assignments.task_uuid nullable + XOR check (V127); legacy phoenix_kit_machine_types/operations/defect_reasons tables and FKs on machine_type_uuid/operation_uuid must NOT exist (V144); calendar status CHECK is ('active','cancelled') (V141). (4) Two in-range versions are pure DRIFT HEALS caused by editing released migrations in place — V122's locations re-create (issue #598, v122.ex:62-70) and V129's subscription_type_uuid add (v129.ex:5-14); V141 admits in-place extension too (v141.ex:43-46). These are the strongest in-repo precedents for the new verify-and-repair requirement: the repair tool should express each as an object-level assertion (table/column/constraint exists with expected shape) rather than a version replay. (5) Idiom inventory a baseline+repair author must preserve: bare index names on CREATE / schema-qualified on DROP (documented in-code v124.ex:27-32); schema-anchored existence guards (information_schema.columns/table_constraints with table_schema, pg_indexes with schemaname); DROP-CONSTRAINT-IF-EXISTS-then-unconditional-ADD for CHECKs where a conname-only guard is cross-prefix-unsafe (v121.ex:17-22, v130.ex:19-24); regclass-anchored pg_constraint guards are used ONLY inside queued DO blocks (V118/119/134/140/144/148) — for immediate checks the name-based JOIN with nspname=$1 (v146.ex:82-98) is the mandated form; uuid function call sites use three spellings that must be unified via Helpers.uuid_v7_call/1 (`#{prefix}.uuid_generate_v7()` in v117/v120/v133/v135/v136/v138/v141, `#{p}uuid_generate_v7()` in v125/v140/v144/v148, Helpers.uuid_v7_call in v143/v145). (6) Cross-module reference policy is deliberate and non-uniform: hard FKs when both ends are core-chain tables (V125 projects→entities, V128 projects→staff, V134 folders→files), loose FK-less UUIDs for optional-module targets (V138 staff_person_uuid, V140 item/location/supplier/storage_folder, V141 target_uuid/location_uuid, V144 machine_type/operation, V145 integration/send_profile, V148 roleable) — a repair tool asserting FK presence must encode this exact split or it will 'fix' intentional soft refs. (7) V146 uniquely pattern-matches %{prefix:} and reads opts.escaped_prefix — evidence the opts map contract (prefix, escaped_prefix, quoted_prefix, create_schema via with_defaults, postgres.ex:1315-1329) is part of the baseline's API surface. Current chain head: @current_version 148 (postgres.ex:1299).

## Post-V148 additions (2026-07-16 refresh)
- V149 (ddl): `phoenix_kit_cat_item_supplier_info` junction (soft supplier_uuid, per-supplier
  SKU/cost/lead-time/MOQ; FK to cat_items CASCADE) + 2 indexes + `cat_suppliers.crm_company_uuid`
  soft xref column. All `IF NOT EXISTS`; raw `#{p}uuid_generate_v7()` default; self-stamps '149'.
  Down drops table CASCADE + column (lossy, documented).
- V150 (ddl): `phoenix_kit_users_tokens.browser`/`os` VARCHAR(100) via Ecto DSL
  `add_if_not_exists`; no backfill possible (raw UA never stored). Self-stamps '150'.
  NB: renumbered V149→V150 on 2026-07-15 because upstream took V149 — the 5th renumber event.
- V151 (ddl, 2026-07-17 refresh): source/primary columns on
  `phoenix_kit_cat_item_supplier_info` (extends V149's junction) + citext email columns on
  CRM tables (citext enabled since V01). Additive, `IF NOT EXISTS`-guarded, self-stamps '151'.

## Post-V151 additions (2026-08-04 refresh, V152..V160)

RANGE-WIDE: zero reference-data seed rows (seed lists in the tooling unaffected); no new SQL
functions; mechanics unchanged (postgres.ex: only moduledoc + @current_version 160; helpers.ex /
migration.ex byte-identical vs 1.7.198). 6th renumber event at the range boundary: V151->V152
(da87ced8, 2026-07-15 — upstream PR #640 took V151 for supplier-info, the restructuring
accumulator stepped aside; its down/1 stamps '151').

- V152 (ddl, backfill, destructive): email send profiles moved to core — creates
  phoenix_kit_email_send_profiles (V145 newsletters shape) + idx_email_send_profiles_* ; backfill
  INSERT..SELECT ON CONFLICT (uuid) DO NOTHING guarded by IMMEDIATE table_exists? (safe: nothing
  queued yet, v152.ex:181,414-431); DROPS phoenix_kit_newsletters_send_profiles CASCADE +
  idx_nl_send_profiles_integration + idx_nl_send_profiles_default (must NOT appear in a
  baseline). CRM contact lists: phoenix_kit_crm_lists + phoenix_kit_crm_list_members (+3 columns
  on crm_contacts: locale/opted_out_at/consent). Broadcasts: list_uuid DROP NOT NULL,
  source_type (Ecto-only enum, no CHECK), crm_list_uuid soft ref + partial index;
  deliveries.user_uuid DROP NOT NULL + recipient_email CITEXT +
  phoenix_kit_newsletters_deliveries_recipient_check (conname-guarded DO block; REDEFINED under
  the same name by V155 — a native shape revision, no guard curation needed). down/1 deliberately
  does not restore the two NOT NULLs. "One open migration" accumulator rule documented
  (v152.ex:12-30).
- V153 (ddl, backfill): media_folders.header_size DEFAULT 'medium'->'small' + lossy UPDATE of
  existing 'medium' rows (deliberate; down restores default only).
- V154 (ddl): phoenix_kit_og_templates + phoenix_kit_og_assignments (+ self-heal ADD COLUMN IF
  NOT EXISTS slot_mapping for pre-release hosts — V91/V122/V129/V141 heal family); partial-index
  uniqueness pair on (module_key,scope_type[,scope_uuid]). @disable_ddl_transaction true with no
  in-file reason and no CONCURRENTLY — flagged. down drops both CASCADE.
- V155 (ddl): deliveries.crm_contact_uuid (bare uuid, PLAIN index — deliberate deviation from the
  partial-index soft-ref convention, v155.ex:10-16); recipient_check REPLACED under the same name
  via unconditional DROP+ADD (deliberate overwrite semantics) with widened not-both rule
  (explicitly not strict XOR, v155.ex:18-45); 3 partial unique per-broadcast dedup indexes;
  broadcasts.source_params JSONB DEFAULT '{}'. Cross-package rollback coupling documented.
- V156 (ddl, backfill, destructive): newsletters lists -> CRM migration (heaviest in range;
  coordinated-release warning v156.ex:6-15). 5-step guarded backfill (lists, contacts with the
  same-email-different-user carve-out v156.ex:249-259, user linking via ORDER BY
  inserted_at,uuid LIMIT 1, memberships with fail-closed status mapping, recount); re-points
  source_type='newsletters_list' broadcasts to crm_list. DROPS (must NOT appear in a baseline):
  FK fk_newsletters_broadcasts_list, index idx_newsletters_broadcasts_list, column
  phoenix_kit_newsletters_broadcasts.list_uuid, tables phoenix_kit_newsletters_list_members and
  phoenix_kit_newsletters_lists (CASCADE, members first). down/1 structure-only (V79 shape),
  data never returns.
- V157 (ddl): annotations kind CHECK widened to add 'image' via unconditional DROP-then-ADD
  (V121/V130 precedent); NEW down/1 shape for the chain — data-conditional rollback guard
  raises with row count + remediation if kind='image' rows exist (v157.ex:78-101).
- V158 (ddl): broadcasts.attachments JSONB DEFAULT '[]' (ordered Storage-file uuid array, soft
  refs) + jsonb_typeof CHECK via DROP-then-ADD; accumulator CLOSED at 1.7.211.
- V159 (ddl): publishing categories (self-FK parent SET NULL, per-group unique slug), M:N
  post_categories (composite PK), post_views per-day rollup (composite PK, no PII).
  @disable_ddl_transaction true again unexplained — flagged. down drops all three CASCADE.
- V160 (ddl): settings.value VARCHAR(255)->TEXT (validation allowed 1000, column capped 255 —
  real crash class); catalog-only change; down/1 hard-fails if any value exceeds 255 chars.

## Post-V160 additions (2026-08-04, V164 after renumber — shape-bimodality repair)

> ✅ **RENUMBERED to V164 (done 2026-08-07).** The 161 slot went to upstream PR #681 (our own
> citext `users.username`) and 162 to #682 (payment-option linkage, itself renumbered off 161) —
> this repair migration moved to V164 in the merge that brought upstream 1.7.233 in: file+module
> renamed, self-stamp `'164'`, `down/1` restamp `'163'`, `@current_version 164`, moduledoc
> `⚡ LATEST`, and the guard test `v164_relaxed_columns_test.exs`. That restamp target (`'163'`)
> was correct on the day it was written and stays correct today for an unrelated reason: the very
> next day upstream landed its own real V163 (see "Post-V161 additions" below), so 163 is once
> again the version directly below 164 — just a different migration's content than whatever sat
> there when this line was drafted.
>
> **What the renumber left stale, confirmed live 2026-08-08 and NOT fixed by this docs-only
> pass:** `v164.ex`'s own moduledoc and source still say `163` in three places that mean *this*
> migration, not upstream's — a doc-comment citing `test/phoenix_kit/migrations/v163_relaxed_columns_test.exs`
> (the real file is `v164_relaxed_columns_test.exs`), a comment naming `V163RelaxedColumnsTest`
> (the real module is `V164RelaxedColumnsTest`), and, more seriously, the `IO.warn` text a
> production run actually prints when a constraint is left `NOT VALID` — it says "the version
> comment now reads 163", but `up/1` self-stamps `'164'` two lines away from where that string is
> built, so the message is simply wrong. `test/phoenix_kit/migrations/v164_relaxed_columns_test.exs`
> carries the matching artifact: `@exempt_version 163`, set by a version comment that says "V164
> itself is exempt" — the constant should read `164`. None of this is a schema-correctness bug
> (self-stamping and the actual restamp value are right; only prose and one log message are
> wrong), but it will confuse the first person who reads the log or greps for the test file. Flag
> for a follow-up lib/test change; out of scope for this pass (docs only, no `lib/`/`test/`
> edits).

- V161 (repair, no-op on any chain run from here on): fixes the fallout of V56/V57's missing
  flush() between UUIDFKColumns.up/1 (queues ~80 ADD COLUMNs) and add_constraints/1 (immediate
  column_exists?/NOT NULL guards) — harmless on an incremental chain run (Ecto flushes between
  migration modules regardless), but on a SINGLE-SHOT run (fresh install; also this repo's own
  squash generator's single-shot probe) the guards ran before Postgres had seen the
  just-queued columns, silently leaving 46 *_uuid FK columns across 33 tables nullable instead
  of NOT NULL (full list: UUIDFKColumns.not_null_uuid_fks/0) and
  phoenix_kit_comments.fk_comments_user_uuid never created at all — V72, finding that FK
  missing, guessed ON DELETE CASCADE instead of matching V56/V57's own already-declared SET
  NULL intent (UUIDFKColumns.@fk_constraints). V56/V57 now carry the missing flush() and V72's
  guess is now SET NULL, so this class of bug cannot recur going forward; V161 exists only to
  repair installs whose single-shot run already happened before those fixes landed. Mechanics:
  flush() first; per not_null_uuid_fks() pair, SET NOT NULL only if the column currently has
  zero NULL rows (else IO.warn naming table/column/row-count and skip — never backfills live
  data with an invented value, unlike UUIDFKColumns' own conversion-era backfill which only ever
  ran against columns it had just created); fk_comments_user_uuid: DROP+re-ADD SET NULL if
  currently CASCADE (no orphan cleanup needed — a row cannot be orphaned under an
  already-enforced CASCADE constraint), ADD SET NULL with V72-style orphan cleanup if the
  constraint is absent entirely (defensive), no-op if already SET NULL. down/1 restamps the
  comment only (V57 precedent — a repair migration never undoes its own fix on rollback).
  Discovered via generate_baseline.exs's stepwise-vs-single-shot bimodality guard
  (Bimodality.diff/2): the first real full-chain single-shot run ever executed end-to-end
  against a scratch DB flagged 47 objects (46 columns + 1 constraint) with genuinely different
  SHAPES between the two install modes — not just presence, which the existing
  `:legacy_optional` model cannot express — and the generator correctly aborted rather than
  silently emit a manifest wrong for one of the two install paths
  (dev_docs/squash/output/mode_shape_mismatch.txt has the full 47-object list from that run).

### Hazard: stepwise-vs-single-shot shape bimodality (root cause fixed 2026-08-04, class remains)

The squash generator's Step 4 (`Bimodality.diff/2`) compares a stepwise (one-version-at-a-time,
mirrors `mix phoenix_kit.update` against an existing install) chain run against a single-shot
(all-N-versions-in-one-call, mirrors a fresh `mix phoenix_kit.install`) chain run and expects
only PRESENCE differences between the two — the existing `:legacy_optional` model. A SHAPE
difference on an object present in BOTH modes (the same column existing both ways but with a
different `not_null`/`default`/`type`, or a constraint with a different `on_delete`) is a
structurally different class of bug the generator refuses to guess at — it aborts loudly
(`mode_shape_mismatch.txt`) rather than silently emit a manifest that is wrong for one of the
two install paths. Root cause class, generalized: a `flush()` gap between two operations inside
the SAME migration, where the second operation's IMMEDIATE `information_schema` (or
`pg_constraint`/`pg_class`) guard depends on the first operation's QUEUED DDL already having
landed. This is invisible on an incremental chain (Ecto flushes between migration *modules*
regardless of what happens inside each one) and surfaces only on a genuine single-shot run —
which is why V56/V57's gap (introduced early in the chain) survived undetected all the way to
the first real single-shot generator run against the full V1..V160 chain. Any future migration
that calls a helper module's `up/1` (queues DDL) immediately followed by another operation with
an immediate existence/state guard needs a `flush()` between them, or this exact bug class
recurs under a fresh-install-only code path most contributors never manually exercise (stepwise,
incremental upgrades are the much more commonly tested path).

### Hazard: install-PATH bimodality from prefix-unsafe DDL (found 2026-08-08 by Mode A, normalized by V164)

A second bimodality axis, independent of the stepwise-vs-single-shot one above and invisible to
every scenario that runs in a named scratch schema: two pre-squash migrations produce a
**different schema in `public` than in a named schema**, because their DDL is prefix-unsafe.

- `V68` replaces `idx_publishing_posts_group_slug` with the partial index its moduledoc says is
  the correct design (`(group_uuid, slug) WHERE slug IS NOT NULL`). Its
  `DROP INDEX IF EXISTS idx_publishing_posts_group_slug` is **not schema-qualified**: in `public`
  it resolves and the replacement lands; in a named schema `IF EXISTS` silently finds nothing and
  the following `CREATE UNIQUE INDEX IF NOT EXISTS` then silently does nothing either, because
  V59 already took that name. The named path therefore keeps V59's NON-partial index forever.
- The same accident class left the unique index on `phoenix_kit_subscription_types.slug` named
  `phoenix_kit_subscription_types_slug_uidx` on the public path but
  `phoenix_kit_subscription_plans_slug_uidx` on the named path (the table was renamed from
  `subscription_plans` between V33 and V65).

Why this mattered for the squash: the baseline is generated by replaying the chain into a
**named** scratch schema (the generator refuses `public` outright — schema-name substitution is
what makes its snapshots portable), so it baked in the named-path shapes. Every real install is a
`public` install, so a fresh 2.0 install diverged from every upgraded one on exactly these two
objects — confirmed against a live pre-production database, and reported by
`mix phoenix_kit.repair` there as a permanent `wrong_shape` finding on the index predicate.

`--mode b` cannot see this by construction: both sides of its comparison are named schemas. It
took the `--mode a` (public-path) oracle to surface it, which is the concrete argument for
keeping that mode runnable. `V164` normalizes both objects onto the public/intended shape on
every install, so the axis is closed rather than tolerated; it is a complete no-op on a real
public install, and the two names plus the index are listed in `verify.exs`'s committed
`:legacy_optional` whitelist so the OLD chain's named-schema output may legitimately differ from
ours.

**Rule for new migrations:** an unqualified `DROP INDEX`/`ALTER INDEX` is not a style nit — it is
a silent schema fork between install paths. `CLAUDE.md`'s prefix-safety rules already say index
names stay bare on `CREATE` and are qualified on `DROP`; this is what happens when they are not.

## Post-V161 additions (2026-08-08 — V162, upstream's real V163, and this delta's second renumber)

- V162 (ddl): `phoenix_kit_orders.payment_option_uuid` — a nullable FK (+ default-named index) to
  `phoenix_kit_payment_options`, `ON DELETE SET NULL`. Distinct from `payment_method` (the small
  closed vocabulary — `bank`/`stripe`/`paypal`/…): this is the specific operator-configured option
  row the customer picked, previously discarded at checkout. Idempotent by construction — a raw
  guarded `DO $$` block rather than `add_if_not_exists` + `references`, because Ecto emits the
  column and its constraint as separate statements and only the column carries `IF NOT EXISTS`
  (v162.ex:33-79); the FK-existence check matches on presence of *any* FK on the column, not on a
  specific constraint name, so a differently-named one from an earlier build of this same
  migration is recognized and left alone rather than duplicated. Self-stamps `'162'`; `down/1`
  drops the column and constraint, restamps `'161'`.

- V163 (repair, upstream PR #688, catalog-driven, no-op on a correct install): fixes any
  `phoenix_kit_*` table whose `uuid` column is the wrong type, nullable, or not the primary key —
  the state `V40`/`V56`/`V74` each assumed impossible and a production install reached anyway. The
  reported instance: `phoenix_kit_email_events.uuid` was `character varying(255)`, nullable, no
  default, and the table had no primary key at all — invisible to `V40` (whose guard tests column
  *existence*, not type, and an older release had already created the column as Ecto `:string`)
  and to `V56` (whose native-type conversion pass was added seventeen days after V56 itself
  shipped, so any host that crossed V56 in that window kept the broken column permanently). Rather
  than enumerate tables by hand — every earlier attempt did, and this table was missing from every
  list — V163 asks the catalog which tables are actually broken. Above two million rows the
  `ALTER COLUMN ... TYPE uuid` rewrite and the `ADD PRIMARY KEY` are DEFERRED and logged with the
  exact remediation command rather than taking an `ACCESS EXCLUSIVE` lock mid-deploy;
  `mix phoenix_kit.doctor` is the loud channel for what was deferred. Never raises on the happy
  path — a latent, one-table problem turned into a fleet-wide failed deploy would be worse than
  the problem itself. Self-stamps `'163'`; this is upstream's own version, not this branch's.

  **Order matters, and it is not incidental.** `V163` runs immediately before `V164` in the merged
  chain, and `V164`'s own moduledoc states the dependency explicitly: "a foreign key cannot
  reference a column with no unique/primary key, so promoting `uuid` to PK here is what lets
  `V164`'s FK repair validate." Concretely — of `V164`'s ~70 declared foreign keys, every one whose
  referenced column is a table's `uuid` primary key needs that PK to already exist before
  `ADD CONSTRAINT ... FOREIGN KEY` can even attempt validation; on the one table `V163` names as
  its worked example, `phoenix_kit_email_events`, that PK did not exist before `V163` ran. Running
  the two in the opposite order is not merely untested, it is a chain that cannot validate.

  **Correction owed to upstream.** Upstream's own moduledoc entry for `V163` did not survive their
  merge into this branch intact — `postgres.ex`'s moduledoc section for `V163` landed positioned
  above `V162`'s body, and `V162`'s own heading was lost in the process (mechanical fallout of two
  moduledoc-collapsing edits landing on the same lines from different directions — this branch's
  own V01..V134 collapse, and upstream's ordinary per-release entry, colliding at the merge base).
  This branch's merge resolution restored both headings in the correct order and correct content
  (`postgres.ex`, the `V164`/`V163`/`V162`/`V161` moduledoc block) — carry that fix back upstream;
  it is not specific to this branch and their own `main` likely still has the defect.

- V164 (this branch's own delta, finalized 2026-08-07, one migration by explicit decision — see
  the "Post-V160 additions" section above for the full flush-order defect it repairs): the version
  ultimately ships three repairs the branch carried as drafts at various points, folded into one
  migration rather than split across several — re-imposing `NOT NULL` and the ~70 declared FK
  constraints `V56`/`V57` silently skipped on any single-shot chain run, correcting
  `fk_comments_user_uuid` from a guessed `CASCADE` to the originally-declared `SET NULL`, and
  normalizing the two objects the "Hazard: install-PATH bimodality" section above documents
  (`idx_publishing_posts_group_slug`'s missing partial predicate, and the
  `phoenix_kit_subscription_plans_slug_uidx` → `..._types_slug_uidx` rename) onto the shape every
  real `public` install already has. All three are additive/corrective and no-ops on a healthy
  install; `S21` (see `dev_docs/squash/COVERAGE.md`) is the scenario that proves the repair half by
  damaging a healthy install the same way the flush defect did and asserting full restoration.

  **This delta's own renumbering is the seventh AND eighth events in the chain-wide ledger this
  document and `dev_docs/squash/README.md` track.** The ledger through `V151`→`V152` (2026-07-15)
  already stands at six (this document's own "Post-V148"/"Post-V151" addenda name the `V149`→`V150`
  move the fifth and `V151`→`V152` the sixth). This delta's first move, `V161`→`V163` — made room for
  upstream PRs #681 (citext `username`, landed as their real `V161`) and #682 (payment-option
  linkage, landed as `V162`) — is the seventh. Its second move, `V163`→`V164`, made the day before
  upstream's *own*, unrelated `V163` (UUID primary-key integrity, PR #688) landed and reclaimed the
  slot this delta had just vacated, is the eighth. Two renumbers for the same delta inside a single
  branch, on top of six earlier chain-wide ones, is exactly the argument for why nothing in the
  harness or the tooling hardcodes a version number: floor and head are always read from the
  compiled registry (`Postgres.initial_version/0` / `current_version/0`), never written as a
  literal anywhere generation or verification runs.

- **Manifest gap, confirmed live 2026-08-08, not closed by this docs-only pass.** The upstream
  merge that brought `V163` in (`10b36a7d`) did not touch
  `lib/phoenix_kit/migrations/expected_schema.ex` — `git show 10b36a7d --stat -- lib/phoenix_kit/migrations/expected_schema.ex`
  returns nothing. The generated manifest therefore has zero knowledge of `V163`'s objects (the
  `uuid`-column type/nullability/PK-promotion repairs on however many tables the catalog scan finds
  broken on a given install). Per the policy this same document and `dev_docs/squash/README.md`
  state ("regenerate after any rebase that touches `v*.ex`, and after every renumber event"), the
  manifest needs regeneration before it can be trusted for any table `V163` touches — until then,
  `mix phoenix_kit.repair`/verify's view of those objects reflects the pre-`V163` shape. The
  manifest's own header comment (`expected_schema.ex:11-19`) independently confirms it predates
  even the `V164` renumber's completion: it still describes the chain as "initial=1 current=163
  files=163" / "initial=135 current=163 files=29", one version behind the code it ships next to
  (`postgres.ex`'s `@current_version` is `164`; the file count is otherwise correct at 29 deltas).
  The `@chain_hash` constant itself WAS updated in the `V164` renumber commit (`6adf55b6`) — only
  the free-text header prose was left stale, and neither was touched again for `V163`. This is the
  single largest open item this pass surfaced: the "21 PASS, 0 FAIL" full-matrix result
  `dev_docs/squash/README.md` reports for 2026-08-08 predates both the final renumber commit and
  the upstream merge, by commit-graph position (`6adf55b6` and `10b36a7d` are the two most recent
  commits on this branch). Whether that run's PASS result still holds against the current HEAD is
  unverified — regenerating the manifest and re-running the full scenario matrix against HEAD is a
  prerequisite this document is not in a position to close (no `lib/` edits, no database scenarios
  in this pass).

## What the squash changed (P3, floor 135)

Executed 2026-08-07 against v1.7.233/V164 with **floor = 135** (operator-decided; not the 121
candidate this document's earlier floor table anticipated). Mechanical outcome:

- `lib/phoenix_kit/migrations/postgres/v01.ex`..`v134.ex` (134 files) deleted; `v135.ex`
  replaced wholesale by the tool-generated baseline slice (`dev_docs/squash/output/v135.ex`,
  11,156 lines / 1,199 `execute` statements — final post-V134 shape only, class-ordered
  extensions < functions < sequences < tables < indexes < constraints < Oban delegation <
  seeds < version stamp). `lib/phoenix_kit/migrations/postgres/` now holds 28 delta modules
  (V136..V164) + `helpers.ex` + the new `v135.ex`, down from 163 version files.
- `lib/phoenix_kit/migrations/expected_schema.ex` promoted from
  `dev_docs/squash/output/expected_schema.ex` (the generated `PhoenixKit.Migrations.ExpectedSchema`
  manifest — `PhoenixKit.Migrations.ExpectedSchema.Resolver`'s default module, confirmed
  resolving via `objects/1`/`data_invariants/1`/`chain_hash/0`).
- `postgres.ex`: `@initial_version` 1 → 135. `plan_up/3`/`plan_down/3` (already implementing
  spec §5.2 pre-squash, dormant) are now live for real installs — below-floor raise, fresh-DB
  clamp to V135, and the down/1 teardown split at the floor boundary all activated without code
  changes to those functions themselves. The moduledoc's V01..V134 narrative (~1,125 lines)
  collapsed into one baseline entry; V135..V164 entries and the ⚡ LATEST discipline kept as-is.
  The dormant `{83, …}` `version_checks/0` heal entry (V83's comment-prefix bug — V83 is now
  inside the baseline, below the floor) pruned to `[]`; the heal mechanism itself stays for a
  future version's bug of the same class.
- **`PhoenixKit.Migrations.UUIDFKColumns` was NOT retired**, despite this document's and the
  spec's §5.4 note that its callers (v56/v57/v70) are "all below any candidate floor". That was
  true when written but went stale: `V164` (added 2026-08-07, after the note) also calls
  `UUIDFKColumns.not_null_uuid_fks/0` and `UUIDFKColumns.@fk_constraints`, and V164 is *above*
  the floor — it survives the squash. Deleting `UUIDFKColumns` would have broken V164's compile.
  Left in place, undocumented-as-dead (it is very much alive).
- `PhoenixKit.Migrations.UUIDRepair` (the `< 40`-gated pre-1.7.0 upgrade repairer) and its
  `mix phoenix_kit.update` pre-migration call site WERE retired — genuinely dead at floor 135
  (every reachable `migrated_version` is either 0, handled as `:fresh_install`, or ≥ 135 ≥ 40,
  both `check_needs_repair/3` clauses that return `false`). Removed: the module, its alias +
  call site + `run_uuid_repair/1` in `phoenix_kit.update.ex`, its dedicated assertion in
  `prefix_validation_test.exs`, and its name-drops in `helpers.ex`'s moduledoc.
- Test disposition (spec §5.3): `v106_test.exs` deleted with nothing ported (it pinned
  `V106.down/1`'s pre-check SQL, a rollback mechanism that no longer exists as a distinct step;
  the schema fact it protected — no unique-name index survives on `phoenix_kit_projects` — is
  already correct-by-omission in the generated manifest, confirmed via
  `dev_docs/squash/output/generation_report.md`'s "Dropped along the chain" list). `v114_test.exs`
  deleted with nothing ported (100% upgrade-only composite-key-rewrite logic, unreachable at
  floor 135; the end-state invariant it protected is already a generator-emitted `data_invariant`
  in the manifest, `since: 114`). `v107_test.exs`/`v112_test.exs`/`v113_test.exs`/`v125_test.exs`
  had their genuinely load-bearing final-shape assertions (column types/nullability/defaults,
  index predicates, FK delete actions, CHECK-constraint enforcement — NOT the migration
  mechanism, none of these files could invoke `up/1`/`down/1` directly in the first place) ported
  verbatim into the new `v135_baseline_schema_test.exs`; V107's upgrade-only backfill-correctness
  tests were dropped (same reasoning as V114). `v145_test.exs` survives untouched, per spec.
- Docs: `dev_docs/guides/2026-07-27-prefix-safe-migrations.md`'s V01/V27/V40/V51 idiom
  name-drops rewritten to name the `V135` baseline module + `Helpers`, with the historical
  version numbers kept parenthetically where they add provenance value. `AGENTS.md`/`CLAUDE.md`
  itself (the `Prefix-safe migrations` section proper) already named no bare version numbers —
  nothing to change there.
- Manifest regenerated post-deletion (`PK_SQUASH_FLOOR=135 mix run dev_docs/squash/generate_baseline.exs`)
  so `chain_hash()` pins the POST-deletion `v*.ex` file set, not the pre-squash one — see the P3
  execution report for the regenerated hash and confirmation that below-floor `since` tags
  collapsed to 135 as expected (the minimum supported comment IS the floor).

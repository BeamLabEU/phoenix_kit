-- Generated V235 reference: browser push installations, bindings and pending pushes.
ALTER TABLE ONLY __SCHEMA__.phoenix_kit_push_bindings
    ADD CONSTRAINT phoenix_kit_push_bindings_installation_uuid_fkey FOREIGN KEY (installation_uuid) REFERENCES __SCHEMA__.phoenix_kit_push_installations(uuid) ON DELETE CASCADE;

ALTER TABLE ONLY __SCHEMA__.phoenix_kit_push_bindings
    ADD CONSTRAINT phoenix_kit_push_bindings_pkey PRIMARY KEY (uuid);

ALTER TABLE ONLY __SCHEMA__.phoenix_kit_push_bindings
    ADD CONSTRAINT phoenix_kit_push_bindings_user_uuid_fkey FOREIGN KEY (user_uuid) REFERENCES __SCHEMA__.phoenix_kit_users(uuid) ON DELETE CASCADE;

ALTER TABLE ONLY __SCHEMA__.phoenix_kit_push_installations
    ADD CONSTRAINT phoenix_kit_push_installations_pkey PRIMARY KEY (uuid);

ALTER TABLE ONLY __SCHEMA__.phoenix_kit_push_pending
    ADD CONSTRAINT phoenix_kit_push_pending_pkey PRIMARY KEY (uuid);

ALTER TABLE ONLY __SCHEMA__.phoenix_kit_push_pending
    ADD CONSTRAINT phoenix_kit_push_pending_user_uuid_fkey FOREIGN KEY (user_uuid) REFERENCES __SCHEMA__.phoenix_kit_users(uuid) ON DELETE CASCADE;

CREATE INDEX phoenix_kit_push_bindings_user_uuid_index ON __SCHEMA__.phoenix_kit_push_bindings USING btree (user_uuid);

CREATE INDEX phoenix_kit_push_installations_browser_id_index ON __SCHEMA__.phoenix_kit_push_installations USING btree (browser_id);

CREATE INDEX phoenix_kit_push_pending_user_uuid_index ON __SCHEMA__.phoenix_kit_push_pending USING btree (user_uuid, inserted_at);

CREATE TABLE __SCHEMA__.phoenix_kit_push_bindings (
    uuid uuid DEFAULT __SCHEMA__.uuid_generate_v7() NOT NULL,
    installation_uuid uuid NOT NULL,
    user_uuid uuid NOT NULL,
    inserted_at timestamp(0) without time zone DEFAULT now() NOT NULL
);

CREATE TABLE __SCHEMA__.phoenix_kit_push_installations (
    uuid uuid DEFAULT __SCHEMA__.uuid_generate_v7() NOT NULL,
    endpoint text NOT NULL,
    endpoint_hash bytea NOT NULL,
    p256dh character varying(255) NOT NULL,
    auth character varying(255) NOT NULL,
    label character varying(160),
    browser_id character varying(64),
    vapid_key_id character varying(64) NOT NULL,
    last_success_at timestamp(0) without time zone,
    inserted_at timestamp(0) without time zone DEFAULT now() NOT NULL,
    updated_at timestamp(0) without time zone DEFAULT now() NOT NULL
);

CREATE TABLE __SCHEMA__.phoenix_kit_push_pending (
    uuid uuid DEFAULT __SCHEMA__.uuid_generate_v7() NOT NULL,
    user_uuid uuid NOT NULL,
    notification_uuid uuid,
    type_key character varying(160),
    title text,
    line text,
    link text,
    inserted_at timestamp(0) without time zone DEFAULT now() NOT NULL
);

CREATE UNIQUE INDEX phoenix_kit_push_bindings_installation_user_index ON __SCHEMA__.phoenix_kit_push_bindings USING btree (installation_uuid, user_uuid);

CREATE UNIQUE INDEX phoenix_kit_push_installations_endpoint_hash_index ON __SCHEMA__.phoenix_kit_push_installations USING btree (endpoint_hash);
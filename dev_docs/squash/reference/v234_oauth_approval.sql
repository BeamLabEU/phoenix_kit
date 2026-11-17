-- Generated V234 reference: approval of an OAuth connection.
ALTER TABLE ONLY __SCHEMA__.phoenix_kit_api_oauth_grants
    ADD CONSTRAINT phoenix_kit_api_oauth_grants_client_uuid_fkey FOREIGN KEY (client_uuid) REFERENCES __SCHEMA__.phoenix_kit_api_oauth_clients(uuid) ON DELETE CASCADE;

ALTER TABLE ONLY __SCHEMA__.phoenix_kit_api_oauth_grants
    ADD CONSTRAINT phoenix_kit_api_oauth_grants_key_uuid_fkey FOREIGN KEY (key_uuid) REFERENCES __SCHEMA__.phoenix_kit_api_keys(uuid) ON DELETE CASCADE;

ALTER TABLE ONLY __SCHEMA__.phoenix_kit_api_oauth_grants
    ADD CONSTRAINT phoenix_kit_api_oauth_grants_pkey PRIMARY KEY (uuid);

ALTER TABLE ONLY __SCHEMA__.phoenix_kit_api_oauth_grants
    ADD CONSTRAINT phoenix_kit_api_oauth_grants_user_uuid_fkey FOREIGN KEY (user_uuid) REFERENCES __SCHEMA__.phoenix_kit_users(uuid) ON DELETE CASCADE;

CREATE INDEX phoenix_kit_api_oauth_grants_client_uuid_index ON __SCHEMA__.phoenix_kit_api_oauth_grants USING btree (client_uuid);

CREATE INDEX phoenix_kit_api_oauth_grants_user_uuid_index ON __SCHEMA__.phoenix_kit_api_oauth_grants USING btree (user_uuid);

CREATE TABLE __SCHEMA__.phoenix_kit_api_oauth_grants (
    uuid uuid DEFAULT __SCHEMA__.uuid_generate_v7() NOT NULL,
    user_uuid uuid NOT NULL,
    client_uuid uuid NOT NULL,
    key_uuid uuid NOT NULL,
    resource character varying(2048) NOT NULL,
    scopes text[] DEFAULT '{}'::text[] NOT NULL,
    expires_at timestamp(0) without time zone NOT NULL,
    activated_at timestamp(0) without time zone,
    revoked_at timestamp(0) without time zone,
    last_used_at timestamp(0) without time zone,
    created_ip character varying(45),
    inserted_at timestamp(0) without time zone DEFAULT now() NOT NULL,
    updated_at timestamp(0) without time zone DEFAULT now() NOT NULL,
    approved_at timestamp(0) without time zone
);

CREATE UNIQUE INDEX phoenix_kit_api_oauth_grants_key_uuid_index ON __SCHEMA__.phoenix_kit_api_oauth_grants USING btree (key_uuid);
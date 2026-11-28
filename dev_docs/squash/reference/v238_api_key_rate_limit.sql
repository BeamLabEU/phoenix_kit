-- Generated V238 reference: the API keys with their own rate limit column.
ALTER TABLE ONLY __SCHEMA__.phoenix_kit_api_keys
    ADD CONSTRAINT phoenix_kit_api_keys_created_by_uuid_fkey FOREIGN KEY (created_by_uuid) REFERENCES __SCHEMA__.phoenix_kit_users(uuid) ON DELETE SET NULL;

ALTER TABLE ONLY __SCHEMA__.phoenix_kit_api_keys
    ADD CONSTRAINT phoenix_kit_api_keys_pkey PRIMARY KEY (uuid);

ALTER TABLE ONLY __SCHEMA__.phoenix_kit_api_keys
    ADD CONSTRAINT phoenix_kit_api_keys_user_uuid_fkey FOREIGN KEY (user_uuid) REFERENCES __SCHEMA__.phoenix_kit_users(uuid) ON DELETE CASCADE;

CREATE INDEX phoenix_kit_api_keys_created_by_uuid_index ON __SCHEMA__.phoenix_kit_api_keys USING btree (created_by_uuid);

CREATE INDEX phoenix_kit_api_keys_user_uuid_index ON __SCHEMA__.phoenix_kit_api_keys USING btree (user_uuid);

CREATE TABLE __SCHEMA__.phoenix_kit_api_keys (
    uuid uuid DEFAULT __SCHEMA__.uuid_generate_v7() NOT NULL,
    user_uuid uuid NOT NULL,
    created_by_uuid uuid,
    name character varying(160) NOT NULL,
    prefix character varying(8) NOT NULL,
    secret_hash bytea NOT NULL,
    scopes text[] DEFAULT '{}'::text[] NOT NULL,
    requires_approval boolean DEFAULT false NOT NULL,
    allowed_ips text[] DEFAULT '{}'::text[] NOT NULL,
    expires_at timestamp(0) without time zone,
    revoked_at timestamp(0) without time zone,
    last_used_at timestamp(0) without time zone,
    last_used_ip character varying(45),
    inserted_at timestamp(0) without time zone DEFAULT now() NOT NULL,
    updated_at timestamp(0) without time zone DEFAULT now() NOT NULL,
    personal boolean DEFAULT false NOT NULL,
    oauth_grant_uuid uuid,
    rate_limit_per_minute integer,
    CONSTRAINT phoenix_kit_api_keys_prefix_check CHECK (((prefix)::text ~ '^[0-9a-f]{8}$'::text)),
    CONSTRAINT phoenix_kit_api_keys_rate_limit_per_minute_check CHECK (((rate_limit_per_minute IS NULL) OR (rate_limit_per_minute > 0)))
);

CREATE UNIQUE INDEX phoenix_kit_api_keys_oauth_grant_uuid_index ON __SCHEMA__.phoenix_kit_api_keys USING btree (oauth_grant_uuid) WHERE (oauth_grant_uuid IS NOT NULL);

CREATE UNIQUE INDEX phoenix_kit_api_keys_prefix_index ON __SCHEMA__.phoenix_kit_api_keys USING btree (prefix);
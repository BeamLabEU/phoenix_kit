-- Generated V233 reference: OAuth for the MCP endpoint.
ALTER TABLE ONLY __SCHEMA__.phoenix_kit_api_keys
    ADD CONSTRAINT phoenix_kit_api_keys_created_by_uuid_fkey FOREIGN KEY (created_by_uuid) REFERENCES __SCHEMA__.phoenix_kit_users(uuid) ON DELETE SET NULL;

ALTER TABLE ONLY __SCHEMA__.phoenix_kit_api_keys
    ADD CONSTRAINT phoenix_kit_api_keys_pkey PRIMARY KEY (uuid);

ALTER TABLE ONLY __SCHEMA__.phoenix_kit_api_keys
    ADD CONSTRAINT phoenix_kit_api_keys_user_uuid_fkey FOREIGN KEY (user_uuid) REFERENCES __SCHEMA__.phoenix_kit_users(uuid) ON DELETE CASCADE;

ALTER TABLE ONLY __SCHEMA__.phoenix_kit_api_oauth_clients
    ADD CONSTRAINT phoenix_kit_api_oauth_clients_pkey PRIMARY KEY (uuid);

ALTER TABLE ONLY __SCHEMA__.phoenix_kit_api_oauth_codes
    ADD CONSTRAINT phoenix_kit_api_oauth_codes_grant_uuid_fkey FOREIGN KEY (grant_uuid) REFERENCES __SCHEMA__.phoenix_kit_api_oauth_grants(uuid) ON DELETE CASCADE;

ALTER TABLE ONLY __SCHEMA__.phoenix_kit_api_oauth_codes
    ADD CONSTRAINT phoenix_kit_api_oauth_codes_pkey PRIMARY KEY (uuid);

ALTER TABLE ONLY __SCHEMA__.phoenix_kit_api_oauth_grants
    ADD CONSTRAINT phoenix_kit_api_oauth_grants_client_uuid_fkey FOREIGN KEY (client_uuid) REFERENCES __SCHEMA__.phoenix_kit_api_oauth_clients(uuid) ON DELETE CASCADE;

ALTER TABLE ONLY __SCHEMA__.phoenix_kit_api_oauth_grants
    ADD CONSTRAINT phoenix_kit_api_oauth_grants_key_uuid_fkey FOREIGN KEY (key_uuid) REFERENCES __SCHEMA__.phoenix_kit_api_keys(uuid) ON DELETE CASCADE;

ALTER TABLE ONLY __SCHEMA__.phoenix_kit_api_oauth_grants
    ADD CONSTRAINT phoenix_kit_api_oauth_grants_pkey PRIMARY KEY (uuid);

ALTER TABLE ONLY __SCHEMA__.phoenix_kit_api_oauth_grants
    ADD CONSTRAINT phoenix_kit_api_oauth_grants_user_uuid_fkey FOREIGN KEY (user_uuid) REFERENCES __SCHEMA__.phoenix_kit_users(uuid) ON DELETE CASCADE;

ALTER TABLE ONLY __SCHEMA__.phoenix_kit_api_oauth_requests
    ADD CONSTRAINT phoenix_kit_api_oauth_requests_client_uuid_fkey FOREIGN KEY (client_uuid) REFERENCES __SCHEMA__.phoenix_kit_api_oauth_clients(uuid) ON DELETE CASCADE;

ALTER TABLE ONLY __SCHEMA__.phoenix_kit_api_oauth_requests
    ADD CONSTRAINT phoenix_kit_api_oauth_requests_pkey PRIMARY KEY (uuid);

ALTER TABLE ONLY __SCHEMA__.phoenix_kit_api_oauth_tokens
    ADD CONSTRAINT phoenix_kit_api_oauth_tokens_grant_uuid_fkey FOREIGN KEY (grant_uuid) REFERENCES __SCHEMA__.phoenix_kit_api_oauth_grants(uuid) ON DELETE CASCADE;

ALTER TABLE ONLY __SCHEMA__.phoenix_kit_api_oauth_tokens
    ADD CONSTRAINT phoenix_kit_api_oauth_tokens_pkey PRIMARY KEY (uuid);

CREATE INDEX phoenix_kit_api_keys_created_by_uuid_index ON __SCHEMA__.phoenix_kit_api_keys USING btree (created_by_uuid);

CREATE INDEX phoenix_kit_api_keys_user_uuid_index ON __SCHEMA__.phoenix_kit_api_keys USING btree (user_uuid);

CREATE INDEX phoenix_kit_api_oauth_codes_grant_uuid_index ON __SCHEMA__.phoenix_kit_api_oauth_codes USING btree (grant_uuid);

CREATE INDEX phoenix_kit_api_oauth_grants_client_uuid_index ON __SCHEMA__.phoenix_kit_api_oauth_grants USING btree (client_uuid);

CREATE INDEX phoenix_kit_api_oauth_grants_user_uuid_index ON __SCHEMA__.phoenix_kit_api_oauth_grants USING btree (user_uuid);

CREATE INDEX phoenix_kit_api_oauth_requests_client_uuid_index ON __SCHEMA__.phoenix_kit_api_oauth_requests USING btree (client_uuid);

CREATE INDEX phoenix_kit_api_oauth_requests_expires_at_index ON __SCHEMA__.phoenix_kit_api_oauth_requests USING btree (expires_at);

CREATE INDEX phoenix_kit_api_oauth_tokens_grant_uuid_index ON __SCHEMA__.phoenix_kit_api_oauth_tokens USING btree (grant_uuid);

CREATE INDEX phoenix_kit_api_oauth_tokens_parent_uuid_index ON __SCHEMA__.phoenix_kit_api_oauth_tokens USING btree (parent_uuid) WHERE (parent_uuid IS NOT NULL);

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
    CONSTRAINT phoenix_kit_api_keys_prefix_check CHECK (((prefix)::text ~ '^[0-9a-f]{8}$'::text))
);

CREATE TABLE __SCHEMA__.phoenix_kit_api_oauth_clients (
    uuid uuid DEFAULT __SCHEMA__.uuid_generate_v7() NOT NULL,
    client_id character varying(2048) NOT NULL,
    kind character varying(16) NOT NULL,
    client_name character varying(160),
    client_uri character varying(2048),
    redirect_uris text[] DEFAULT '{}'::text[] NOT NULL,
    metadata_fetched_at timestamp(0) without time zone,
    metadata_expires_at timestamp(0) without time zone,
    last_seen_at timestamp(0) without time zone,
    inserted_at timestamp(0) without time zone DEFAULT now() NOT NULL,
    updated_at timestamp(0) without time zone DEFAULT now() NOT NULL,
    CONSTRAINT phoenix_kit_api_oauth_clients_kind_check CHECK (((kind)::text = ANY ((ARRAY['cimd'::character varying, 'dcr'::character varying, 'preregistered'::character varying])::text[])))
);

CREATE TABLE __SCHEMA__.phoenix_kit_api_oauth_codes (
    uuid uuid DEFAULT __SCHEMA__.uuid_generate_v7() NOT NULL,
    code_hash bytea NOT NULL,
    grant_uuid uuid NOT NULL,
    redirect_uri text NOT NULL,
    code_challenge character varying(128) NOT NULL,
    expires_at timestamp(0) without time zone NOT NULL,
    used_at timestamp(0) without time zone,
    inserted_at timestamp(0) without time zone DEFAULT now() NOT NULL
);

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
    updated_at timestamp(0) without time zone DEFAULT now() NOT NULL
);

CREATE TABLE __SCHEMA__.phoenix_kit_api_oauth_requests (
    uuid uuid DEFAULT __SCHEMA__.uuid_generate_v7() NOT NULL,
    request_token_hash bytea NOT NULL,
    client_uuid uuid NOT NULL,
    redirect_uri text NOT NULL,
    code_challenge character varying(128) NOT NULL,
    resource character varying(2048) NOT NULL,
    state character varying(512),
    requested_scopes text[] DEFAULT '{}'::text[] NOT NULL,
    client_snapshot jsonb DEFAULT '{}'::jsonb NOT NULL,
    expires_at timestamp(0) without time zone NOT NULL,
    consumed_at timestamp(0) without time zone,
    inserted_at timestamp(0) without time zone DEFAULT now() NOT NULL
);

CREATE TABLE __SCHEMA__.phoenix_kit_api_oauth_tokens (
    uuid uuid DEFAULT __SCHEMA__.uuid_generate_v7() NOT NULL,
    token_hash bytea NOT NULL,
    kind character varying(8) NOT NULL,
    grant_uuid uuid NOT NULL,
    family uuid NOT NULL,
    parent_uuid uuid,
    expires_at timestamp(0) without time zone NOT NULL,
    used_at timestamp(0) without time zone,
    revoked_at timestamp(0) without time zone,
    revoke_reason character varying(32),
    inserted_at timestamp(0) without time zone DEFAULT now() NOT NULL,
    CONSTRAINT phoenix_kit_api_oauth_tokens_kind_check CHECK (((kind)::text = ANY ((ARRAY['access'::character varying, 'refresh'::character varying])::text[])))
);

CREATE UNIQUE INDEX phoenix_kit_api_keys_oauth_grant_uuid_index ON __SCHEMA__.phoenix_kit_api_keys USING btree (oauth_grant_uuid) WHERE (oauth_grant_uuid IS NOT NULL);

CREATE UNIQUE INDEX phoenix_kit_api_keys_prefix_index ON __SCHEMA__.phoenix_kit_api_keys USING btree (prefix);

CREATE UNIQUE INDEX phoenix_kit_api_oauth_clients_client_id_index ON __SCHEMA__.phoenix_kit_api_oauth_clients USING btree (client_id);

CREATE UNIQUE INDEX phoenix_kit_api_oauth_codes_code_hash_index ON __SCHEMA__.phoenix_kit_api_oauth_codes USING btree (code_hash);

CREATE UNIQUE INDEX phoenix_kit_api_oauth_grants_key_uuid_index ON __SCHEMA__.phoenix_kit_api_oauth_grants USING btree (key_uuid);

CREATE UNIQUE INDEX phoenix_kit_api_oauth_requests_request_token_hash_index ON __SCHEMA__.phoenix_kit_api_oauth_requests USING btree (request_token_hash);

CREATE UNIQUE INDEX phoenix_kit_api_oauth_tokens_token_hash_index ON __SCHEMA__.phoenix_kit_api_oauth_tokens USING btree (token_hash);
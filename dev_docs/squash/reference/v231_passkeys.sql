-- Generated V231 reference: passkeys.
ALTER TABLE ONLY __SCHEMA__.phoenix_kit_user_passkeys
    ADD CONSTRAINT phoenix_kit_user_passkeys_pkey PRIMARY KEY (uuid);

ALTER TABLE ONLY __SCHEMA__.phoenix_kit_user_passkeys
    ADD CONSTRAINT phoenix_kit_user_passkeys_user_uuid_fkey FOREIGN KEY (user_uuid) REFERENCES __SCHEMA__.phoenix_kit_users(uuid) ON DELETE CASCADE;

CREATE INDEX phoenix_kit_user_passkeys_user_uuid_index ON __SCHEMA__.phoenix_kit_user_passkeys USING btree (user_uuid);

CREATE TABLE __SCHEMA__.phoenix_kit_user_passkeys (
    uuid uuid DEFAULT __SCHEMA__.uuid_generate_v7() NOT NULL,
    user_uuid uuid NOT NULL,
    credential_id bytea NOT NULL,
    public_key bytea NOT NULL,
    sign_count bigint DEFAULT 0 NOT NULL,
    rp_id character varying(255) NOT NULL,
    transports character varying(32)[] DEFAULT '{}'::character varying[] NOT NULL,
    backup_eligible boolean DEFAULT false NOT NULL,
    name character varying(100) NOT NULL,
    last_used_at timestamp(0) without time zone,
    inserted_at timestamp(0) without time zone DEFAULT now() NOT NULL,
    updated_at timestamp(0) without time zone DEFAULT now() NOT NULL
);

CREATE UNIQUE INDEX phoenix_kit_user_passkeys_credential_id_index ON __SCHEMA__.phoenix_kit_user_passkeys USING btree (credential_id);
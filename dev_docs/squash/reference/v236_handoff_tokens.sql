-- Generated V236 reference: the cross-domain handoff tokens.
ALTER TABLE ONLY __SCHEMA__.phoenix_kit_handoff_tokens
    ADD CONSTRAINT phoenix_kit_handoff_tokens_pkey PRIMARY KEY (uuid);

ALTER TABLE ONLY __SCHEMA__.phoenix_kit_handoff_tokens
    ADD CONSTRAINT phoenix_kit_handoff_tokens_user_uuid_fkey FOREIGN KEY (user_uuid) REFERENCES __SCHEMA__.phoenix_kit_users(uuid) ON DELETE CASCADE;

CREATE INDEX phoenix_kit_handoff_tokens_expires_at_index ON __SCHEMA__.phoenix_kit_handoff_tokens USING btree (expires_at);

CREATE INDEX phoenix_kit_handoff_tokens_user_uuid_index ON __SCHEMA__.phoenix_kit_handoff_tokens USING btree (user_uuid);

CREATE TABLE __SCHEMA__.phoenix_kit_handoff_tokens (
    uuid uuid DEFAULT __SCHEMA__.uuid_generate_v7() NOT NULL,
    token_hash bytea NOT NULL,
    target_host text NOT NULL,
    redirect_path text NOT NULL,
    user_uuid uuid,
    payload jsonb DEFAULT '{}'::jsonb NOT NULL,
    browser_nonce_hash bytea NOT NULL,
    user_agent_hash bytea,
    expires_at timestamp(0) without time zone NOT NULL,
    used_at timestamp(0) without time zone,
    inserted_at timestamp(0) without time zone DEFAULT now() NOT NULL
);

CREATE UNIQUE INDEX phoenix_kit_handoff_tokens_token_hash_index ON __SCHEMA__.phoenix_kit_handoff_tokens USING btree (token_hash);
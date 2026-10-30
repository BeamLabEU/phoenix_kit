-- Generated V227 reference: users, tokens, managers and invitations.
ALTER TABLE ONLY __SCHEMA__.phoenix_kit_organization_invitations
    ADD CONSTRAINT phoenix_kit_organization_invitations_invited_by_uuid_fkey FOREIGN KEY (invited_by_uuid) REFERENCES __SCHEMA__.phoenix_kit_users(uuid) ON DELETE SET NULL;

ALTER TABLE ONLY __SCHEMA__.phoenix_kit_organization_invitations
    ADD CONSTRAINT phoenix_kit_organization_invitations_organization_uuid_fkey FOREIGN KEY (organization_uuid) REFERENCES __SCHEMA__.phoenix_kit_users(uuid) ON DELETE CASCADE;

ALTER TABLE ONLY __SCHEMA__.phoenix_kit_organization_invitations
    ADD CONSTRAINT phoenix_kit_organization_invitations_pkey PRIMARY KEY (uuid);

ALTER TABLE ONLY __SCHEMA__.phoenix_kit_organization_managers
    ADD CONSTRAINT phoenix_kit_organization_managers_granted_by_uuid_fkey FOREIGN KEY (granted_by_uuid) REFERENCES __SCHEMA__.phoenix_kit_users(uuid) ON DELETE SET NULL;

ALTER TABLE ONLY __SCHEMA__.phoenix_kit_organization_managers
    ADD CONSTRAINT phoenix_kit_organization_managers_organization_uuid_fkey FOREIGN KEY (organization_uuid) REFERENCES __SCHEMA__.phoenix_kit_users(uuid) ON DELETE CASCADE;

ALTER TABLE ONLY __SCHEMA__.phoenix_kit_organization_managers
    ADD CONSTRAINT phoenix_kit_organization_managers_pkey PRIMARY KEY (uuid);

ALTER TABLE ONLY __SCHEMA__.phoenix_kit_organization_managers
    ADD CONSTRAINT phoenix_kit_organization_managers_user_uuid_fkey FOREIGN KEY (user_uuid) REFERENCES __SCHEMA__.phoenix_kit_users(uuid) ON DELETE CASCADE;

ALTER TABLE ONLY __SCHEMA__.phoenix_kit_users
    ADD CONSTRAINT phoenix_kit_users_created_by_uuid_fkey FOREIGN KEY (created_by_uuid) REFERENCES __SCHEMA__.phoenix_kit_users(uuid) ON DELETE SET NULL;

ALTER TABLE ONLY __SCHEMA__.phoenix_kit_users
    ADD CONSTRAINT phoenix_kit_users_organization_uuid_fkey FOREIGN KEY (organization_uuid) REFERENCES __SCHEMA__.phoenix_kit_users(uuid) ON DELETE SET NULL;

ALTER TABLE ONLY __SCHEMA__.phoenix_kit_users
    ADD CONSTRAINT phoenix_kit_users_pkey PRIMARY KEY (uuid);

ALTER TABLE ONLY __SCHEMA__.phoenix_kit_users_tokens
    ADD CONSTRAINT fk_users_tokens_user_uuid FOREIGN KEY (user_uuid) REFERENCES __SCHEMA__.phoenix_kit_users(uuid) ON DELETE CASCADE;

ALTER TABLE ONLY __SCHEMA__.phoenix_kit_users_tokens
    ADD CONSTRAINT phoenix_kit_users_tokens_pkey PRIMARY KEY (uuid);

ALTER TABLE ONLY __SCHEMA__.phoenix_kit_users_tokens
    ADD CONSTRAINT pk_tokens_acting_session_fkey FOREIGN KEY (acting_session_uuid) REFERENCES __SCHEMA__.phoenix_kit_users_tokens(uuid) ON DELETE CASCADE;

ALTER TABLE ONLY __SCHEMA__.phoenix_kit_users_tokens
    ADD CONSTRAINT pk_tokens_organization_manager_fkey FOREIGN KEY (organization_manager_uuid) REFERENCES __SCHEMA__.phoenix_kit_organization_managers(uuid) ON DELETE CASCADE;

CREATE INDEX idx_users_active ON __SCHEMA__.phoenix_kit_users USING btree (is_active);

CREATE INDEX phoenix_kit_organization_invitations_email_index ON __SCHEMA__.phoenix_kit_organization_invitations USING btree (email);

CREATE INDEX phoenix_kit_organization_invitations_organization_uuid_index ON __SCHEMA__.phoenix_kit_organization_invitations USING btree (organization_uuid);

CREATE INDEX phoenix_kit_organization_invitations_status_index ON __SCHEMA__.phoenix_kit_organization_invitations USING btree (status);

CREATE INDEX phoenix_kit_organization_managers_user_uuid_index ON __SCHEMA__.phoenix_kit_organization_managers USING btree (user_uuid);

CREATE INDEX phoenix_kit_users_account_type_index ON __SCHEMA__.phoenix_kit_users USING btree (account_type);

CREATE INDEX phoenix_kit_users_created_by_uuid_index ON __SCHEMA__.phoenix_kit_users USING btree (created_by_uuid);

CREATE INDEX phoenix_kit_users_organization_uuid_index ON __SCHEMA__.phoenix_kit_users USING btree (organization_uuid);

CREATE INDEX phoenix_kit_users_reg_city_date_idx ON __SCHEMA__.phoenix_kit_users USING btree (registration_city, inserted_at);

CREATE INDEX phoenix_kit_users_reg_country_date_idx ON __SCHEMA__.phoenix_kit_users USING btree (registration_country, inserted_at);

CREATE INDEX phoenix_kit_users_reg_geo_idx ON __SCHEMA__.phoenix_kit_users USING btree (registration_country, registration_region, registration_city);

CREATE INDEX phoenix_kit_users_reg_ip_date_idx ON __SCHEMA__.phoenix_kit_users USING btree (registration_ip, inserted_at);

CREATE INDEX phoenix_kit_users_reg_region_date_idx ON __SCHEMA__.phoenix_kit_users USING btree (registration_region, inserted_at);

CREATE INDEX phoenix_kit_users_tokens_acting_session_uuid_index ON __SCHEMA__.phoenix_kit_users_tokens USING btree (acting_session_uuid);

CREATE INDEX phoenix_kit_users_tokens_ip_address_index ON __SCHEMA__.phoenix_kit_users_tokens USING btree (ip_address);

CREATE INDEX phoenix_kit_users_tokens_organization_manager_index ON __SCHEMA__.phoenix_kit_users_tokens USING btree (organization_manager_uuid);

CREATE INDEX phoenix_kit_users_tokens_token_ip_address_user_agent_hash_index ON __SCHEMA__.phoenix_kit_users_tokens USING btree (token, ip_address, user_agent_hash);

CREATE INDEX phoenix_kit_users_tokens_user_agent_hash_index ON __SCHEMA__.phoenix_kit_users_tokens USING btree (user_agent_hash);

CREATE INDEX phoenix_kit_users_tokens_user_uuid_idx ON __SCHEMA__.phoenix_kit_users_tokens USING btree (user_uuid);

CREATE TABLE __SCHEMA__.phoenix_kit_organization_invitations (
    uuid uuid DEFAULT __SCHEMA__.uuid_generate_v7() NOT NULL,
    organization_uuid uuid NOT NULL,
    email character varying(160) NOT NULL,
    invited_by_uuid uuid,
    token bytea NOT NULL,
    status character varying(20) DEFAULT 'pending'::character varying NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    accepted_at timestamp with time zone,
    inserted_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    kind character varying(20) DEFAULT 'member'::character varying NOT NULL,
    CONSTRAINT phoenix_kit_org_invitations_kind_check CHECK (((kind)::text = ANY ((ARRAY['member'::character varying, 'manager'::character varying])::text[]))),
    CONSTRAINT phoenix_kit_org_invitations_status_check CHECK (((status)::text = ANY ((ARRAY['pending'::character varying, 'accepted'::character varying, 'declined'::character varying, 'cancelled'::character varying])::text[])))
);

CREATE TABLE __SCHEMA__.phoenix_kit_organization_managers (
    uuid uuid DEFAULT __SCHEMA__.uuid_generate_v7() NOT NULL,
    organization_uuid uuid NOT NULL,
    user_uuid uuid NOT NULL,
    granted_by_uuid uuid,
    inserted_at timestamp(0) without time zone DEFAULT now() NOT NULL,
    updated_at timestamp(0) without time zone DEFAULT now() NOT NULL,
    CONSTRAINT phoenix_kit_organization_managers_not_self_check CHECK ((organization_uuid <> user_uuid))
);

CREATE TABLE __SCHEMA__.phoenix_kit_users (
    email public.citext NOT NULL,
    hashed_password character varying(255) NOT NULL,
    first_name character varying(100),
    last_name character varying(100),
    is_active boolean DEFAULT true NOT NULL,
    confirmed_at timestamp with time zone,
    inserted_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL,
    username public.citext,
    registration_ip character varying(45),
    registration_country character varying(2),
    registration_region character varying(100),
    registration_city character varying(100),
    user_timezone character varying(64),
    custom_fields jsonb DEFAULT '{}'::jsonb,
    uuid uuid DEFAULT __SCHEMA__.uuid_generate_v7() NOT NULL,
    account_type character varying(20) DEFAULT 'person'::character varying NOT NULL,
    organization_name character varying(255),
    organization_uuid uuid,
    created_by_uuid uuid,
    google_email character varying(160),
    api_only boolean DEFAULT false NOT NULL,
    country character varying(2),
    managed_by_members boolean DEFAULT false NOT NULL,
    contact_email public.citext,
    CONSTRAINT phoenix_kit_users_account_type_check CHECK (((account_type)::text = ANY ((ARRAY['person'::character varying, 'organization'::character varying])::text[]))),
    CONSTRAINT phoenix_kit_users_managed_organization_check CHECK (((NOT managed_by_members) OR (((account_type)::text = 'organization'::text) AND (NOT api_only))))
);

CREATE TABLE __SCHEMA__.phoenix_kit_users_tokens (
    token bytea NOT NULL,
    context character varying(255) NOT NULL,
    sent_to character varying(255),
    inserted_at timestamp with time zone NOT NULL,
    ip_address character varying(255),
    user_agent_hash character varying(255),
    uuid uuid DEFAULT __SCHEMA__.uuid_generate_v7() NOT NULL,
    user_uuid uuid,
    browser character varying(100),
    os character varying(100),
    active_role_uuid uuid,
    acting_session_uuid uuid,
    organization_manager_uuid uuid,
    CONSTRAINT phoenix_kit_users_tokens_acting_pair_check CHECK ((((acting_session_uuid IS NULL) AND (organization_manager_uuid IS NULL)) OR ((acting_session_uuid IS NOT NULL) AND (organization_manager_uuid IS NOT NULL) AND ((context)::text = 'session'::text)))),
    CONSTRAINT user_uuid_required_for_non_registration_tokens CHECK (
CASE
    WHEN ((context)::text = 'magic_link_registration'::text) THEN true
    ELSE (user_uuid IS NOT NULL)
END)
);

CREATE UNIQUE INDEX phoenix_kit_org_invitations_pending_unique_idx ON __SCHEMA__.phoenix_kit_organization_invitations USING btree (organization_uuid, email, kind) WHERE ((status)::text = 'pending'::text);

CREATE UNIQUE INDEX phoenix_kit_organization_invitations_token_index ON __SCHEMA__.phoenix_kit_organization_invitations USING btree (token);

CREATE UNIQUE INDEX phoenix_kit_organization_managers_org_user_index ON __SCHEMA__.phoenix_kit_organization_managers USING btree (organization_uuid, user_uuid);

CREATE UNIQUE INDEX phoenix_kit_users_email_index ON __SCHEMA__.phoenix_kit_users USING btree (email);

CREATE UNIQUE INDEX phoenix_kit_users_tokens_context_token_index ON __SCHEMA__.phoenix_kit_users_tokens USING btree (context, token);

CREATE UNIQUE INDEX phoenix_kit_users_tokens_uuid_idx ON __SCHEMA__.phoenix_kit_users_tokens USING btree (uuid);

CREATE UNIQUE INDEX phoenix_kit_users_username_uidx ON __SCHEMA__.phoenix_kit_users USING btree (username) WHERE (username IS NOT NULL);

CREATE UNIQUE INDEX phoenix_kit_users_uuid_idx ON __SCHEMA__.phoenix_kit_users USING btree (uuid);
-- Generated V229 reference: types, links, link roles, invitations and roles.
ALTER TABLE ONLY __SCHEMA__.phoenix_kit_organization_invitations
    ADD CONSTRAINT phoenix_kit_organization_invitations_invited_by_uuid_fkey FOREIGN KEY (invited_by_uuid) REFERENCES __SCHEMA__.phoenix_kit_users(uuid) ON DELETE SET NULL;

ALTER TABLE ONLY __SCHEMA__.phoenix_kit_organization_invitations
    ADD CONSTRAINT phoenix_kit_organization_invitations_organization_uuid_fkey FOREIGN KEY (organization_uuid) REFERENCES __SCHEMA__.phoenix_kit_users(uuid) ON DELETE CASCADE;

ALTER TABLE ONLY __SCHEMA__.phoenix_kit_organization_invitations
    ADD CONSTRAINT phoenix_kit_organization_invitations_pkey PRIMARY KEY (uuid);

ALTER TABLE ONLY __SCHEMA__.phoenix_kit_organization_invitations
    ADD CONSTRAINT pk_org_invitations_relationship_type_fkey FOREIGN KEY (relationship_type_uuid) REFERENCES __SCHEMA__.phoenix_kit_relationship_types(uuid) ON DELETE RESTRICT;

ALTER TABLE ONLY __SCHEMA__.phoenix_kit_organization_manager_roles
    ADD CONSTRAINT phoenix_kit_organization_manager_organization_manager_uuid_fkey FOREIGN KEY (organization_manager_uuid) REFERENCES __SCHEMA__.phoenix_kit_organization_managers(uuid) ON DELETE CASCADE;

ALTER TABLE ONLY __SCHEMA__.phoenix_kit_organization_manager_roles
    ADD CONSTRAINT phoenix_kit_organization_manager_roles_assigned_by_uuid_fkey FOREIGN KEY (assigned_by_uuid) REFERENCES __SCHEMA__.phoenix_kit_users(uuid) ON DELETE SET NULL;

ALTER TABLE ONLY __SCHEMA__.phoenix_kit_organization_manager_roles
    ADD CONSTRAINT phoenix_kit_organization_manager_roles_pkey PRIMARY KEY (uuid);

ALTER TABLE ONLY __SCHEMA__.phoenix_kit_organization_manager_roles
    ADD CONSTRAINT phoenix_kit_organization_manager_roles_role_uuid_fkey FOREIGN KEY (role_uuid) REFERENCES __SCHEMA__.phoenix_kit_user_roles(uuid) ON DELETE RESTRICT;

ALTER TABLE ONLY __SCHEMA__.phoenix_kit_organization_managers
    ADD CONSTRAINT phoenix_kit_organization_managers_granted_by_uuid_fkey FOREIGN KEY (granted_by_uuid) REFERENCES __SCHEMA__.phoenix_kit_users(uuid) ON DELETE SET NULL;

ALTER TABLE ONLY __SCHEMA__.phoenix_kit_organization_managers
    ADD CONSTRAINT phoenix_kit_organization_managers_organization_uuid_fkey FOREIGN KEY (organization_uuid) REFERENCES __SCHEMA__.phoenix_kit_users(uuid) ON DELETE CASCADE;

ALTER TABLE ONLY __SCHEMA__.phoenix_kit_organization_managers
    ADD CONSTRAINT phoenix_kit_organization_managers_pkey PRIMARY KEY (uuid);

ALTER TABLE ONLY __SCHEMA__.phoenix_kit_organization_managers
    ADD CONSTRAINT phoenix_kit_organization_managers_user_uuid_fkey FOREIGN KEY (user_uuid) REFERENCES __SCHEMA__.phoenix_kit_users(uuid) ON DELETE CASCADE;

ALTER TABLE ONLY __SCHEMA__.phoenix_kit_organization_managers
    ADD CONSTRAINT pk_org_managers_relationship_type_fkey FOREIGN KEY (relationship_type_uuid) REFERENCES __SCHEMA__.phoenix_kit_relationship_types(uuid) ON DELETE RESTRICT;

ALTER TABLE ONLY __SCHEMA__.phoenix_kit_relationship_types
    ADD CONSTRAINT phoenix_kit_relationship_types_pkey PRIMARY KEY (uuid);

ALTER TABLE ONLY __SCHEMA__.phoenix_kit_user_roles
    ADD CONSTRAINT phoenix_kit_user_roles_pkey PRIMARY KEY (uuid);

CREATE INDEX phoenix_kit_organization_invitations_email_index ON __SCHEMA__.phoenix_kit_organization_invitations USING btree (email);

CREATE INDEX phoenix_kit_organization_invitations_organization_uuid_index ON __SCHEMA__.phoenix_kit_organization_invitations USING btree (organization_uuid);

CREATE INDEX phoenix_kit_organization_invitations_status_index ON __SCHEMA__.phoenix_kit_organization_invitations USING btree (status);

CREATE INDEX phoenix_kit_organization_manager_roles_role_index ON __SCHEMA__.phoenix_kit_organization_manager_roles USING btree (role_uuid);

CREATE INDEX phoenix_kit_organization_managers_type_index ON __SCHEMA__.phoenix_kit_organization_managers USING btree (relationship_type_uuid);

CREATE INDEX phoenix_kit_organization_managers_user_uuid_index ON __SCHEMA__.phoenix_kit_organization_managers USING btree (user_uuid);

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
    relationship_type_uuid uuid,
    all_roles boolean DEFAULT true NOT NULL,
    role_uuids uuid[] DEFAULT '{}'::uuid[] NOT NULL,
    CONSTRAINT phoenix_kit_org_invitations_kind_check CHECK (((kind)::text = ANY ((ARRAY['member'::character varying, 'manager'::character varying])::text[]))),
    CONSTRAINT phoenix_kit_org_invitations_status_check CHECK (((status)::text = ANY ((ARRAY['pending'::character varying, 'accepted'::character varying, 'declined'::character varying, 'cancelled'::character varying])::text[]))),
    CONSTRAINT phoenix_kit_org_invitations_type_check CHECK ((((kind)::text = 'manager'::text) = (relationship_type_uuid IS NOT NULL)))
);

CREATE TABLE __SCHEMA__.phoenix_kit_organization_manager_roles (
    uuid uuid DEFAULT __SCHEMA__.uuid_generate_v7() NOT NULL,
    organization_manager_uuid uuid CONSTRAINT phoenix_kit_organization_man_organization_manager_uuid_not_null NOT NULL,
    role_uuid uuid NOT NULL,
    assigned_by_uuid uuid,
    inserted_at timestamp(0) without time zone DEFAULT now() NOT NULL
);

CREATE TABLE __SCHEMA__.phoenix_kit_organization_managers (
    uuid uuid DEFAULT __SCHEMA__.uuid_generate_v7() NOT NULL,
    organization_uuid uuid NOT NULL,
    user_uuid uuid NOT NULL,
    granted_by_uuid uuid,
    inserted_at timestamp(0) without time zone DEFAULT now() NOT NULL,
    updated_at timestamp(0) without time zone DEFAULT now() NOT NULL,
    relationship_type_uuid uuid DEFAULT '019a0000-0000-7000-8000-000000000229'::uuid CONSTRAINT phoenix_kit_organization_manage_relationship_type_uuid_not_null NOT NULL,
    all_roles boolean DEFAULT true NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    CONSTRAINT phoenix_kit_organization_managers_not_self_check CHECK ((organization_uuid <> user_uuid))
);

CREATE TABLE __SCHEMA__.phoenix_kit_relationship_types (
    uuid uuid DEFAULT __SCHEMA__.uuid_generate_v7() NOT NULL,
    key character varying(64) NOT NULL,
    data jsonb DEFAULT '{}'::jsonb NOT NULL,
    from_kind character varying(20) NOT NULL,
    to_kind character varying(20) NOT NULL,
    can_act boolean DEFAULT false NOT NULL,
    can_manage boolean DEFAULT false NOT NULL,
    status character varying(20) DEFAULT 'active'::character varying NOT NULL,
    "position" integer DEFAULT 0 NOT NULL,
    builtin boolean DEFAULT false NOT NULL,
    inserted_at timestamp(0) without time zone DEFAULT now() NOT NULL,
    updated_at timestamp(0) without time zone DEFAULT now() NOT NULL,
    CONSTRAINT phoenix_kit_relationship_types_act_check CHECK (((NOT can_act) OR (((from_kind)::text = 'person'::text) AND ((to_kind)::text = 'organization'::text)))),
    CONSTRAINT phoenix_kit_relationship_types_kinds_check CHECK ((((from_kind)::text = ANY ((ARRAY['person'::character varying, 'organization'::character varying])::text[])) AND ((to_kind)::text = ANY ((ARRAY['person'::character varying, 'organization'::character varying])::text[])))),
    CONSTRAINT phoenix_kit_relationship_types_manage_check CHECK (((NOT can_manage) OR can_act)),
    CONSTRAINT phoenix_kit_relationship_types_status_check CHECK (((status)::text = ANY ((ARRAY['active'::character varying, 'archived'::character varying])::text[])))
);

CREATE TABLE __SCHEMA__.phoenix_kit_user_roles (
    name character varying(50) NOT NULL,
    description text,
    is_system_role boolean DEFAULT false NOT NULL,
    inserted_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL,
    uuid uuid DEFAULT __SCHEMA__.uuid_generate_v7() NOT NULL,
    "position" integer DEFAULT 0 NOT NULL,
    data jsonb DEFAULT '{}'::jsonb NOT NULL
);

CREATE UNIQUE INDEX phoenix_kit_org_invitations_pending_unique_idx ON __SCHEMA__.phoenix_kit_organization_invitations USING btree (organization_uuid, email, kind) WHERE ((status)::text = 'pending'::text);

CREATE UNIQUE INDEX phoenix_kit_organization_invitations_token_index ON __SCHEMA__.phoenix_kit_organization_invitations USING btree (token);

CREATE UNIQUE INDEX phoenix_kit_organization_manager_roles_link_role_index ON __SCHEMA__.phoenix_kit_organization_manager_roles USING btree (organization_manager_uuid, role_uuid);

CREATE UNIQUE INDEX phoenix_kit_organization_managers_org_user_index ON __SCHEMA__.phoenix_kit_organization_managers USING btree (organization_uuid, user_uuid);

CREATE UNIQUE INDEX phoenix_kit_relationship_types_key_index ON __SCHEMA__.phoenix_kit_relationship_types USING btree (key);

CREATE UNIQUE INDEX phoenix_kit_user_roles_name_index ON __SCHEMA__.phoenix_kit_user_roles USING btree (name);

CREATE UNIQUE INDEX phoenix_kit_user_roles_uuid_idx ON __SCHEMA__.phoenix_kit_user_roles USING btree (uuid);
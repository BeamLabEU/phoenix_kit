-- Generated V232 reference: file stacks.
ALTER TABLE ONLY __SCHEMA__.phoenix_kit_file_stacks
    ADD CONSTRAINT phoenix_kit_file_stacks_created_by_uuid_fkey FOREIGN KEY (created_by_uuid) REFERENCES __SCHEMA__.phoenix_kit_users(uuid) ON DELETE SET NULL;

ALTER TABLE ONLY __SCHEMA__.phoenix_kit_file_stacks
    ADD CONSTRAINT phoenix_kit_file_stacks_library_uuid_fkey FOREIGN KEY (library_uuid) REFERENCES __SCHEMA__.phoenix_kit_storage_libraries(uuid) ON DELETE CASCADE;

ALTER TABLE ONLY __SCHEMA__.phoenix_kit_file_stacks
    ADD CONSTRAINT phoenix_kit_file_stacks_pkey PRIMARY KEY (uuid);

ALTER TABLE ONLY __SCHEMA__.phoenix_kit_files
    ADD CONSTRAINT fk_files_user_uuid FOREIGN KEY (user_uuid) REFERENCES __SCHEMA__.phoenix_kit_users(uuid) ON DELETE SET NULL;

ALTER TABLE ONLY __SCHEMA__.phoenix_kit_files
    ADD CONSTRAINT phoenix_kit_files_edited_from_uuid_fkey FOREIGN KEY (edited_from_uuid) REFERENCES __SCHEMA__.phoenix_kit_files(uuid) ON DELETE SET NULL;

ALTER TABLE ONLY __SCHEMA__.phoenix_kit_files
    ADD CONSTRAINT phoenix_kit_files_folder_uuid_fkey FOREIGN KEY (folder_uuid) REFERENCES __SCHEMA__.phoenix_kit_media_folders(uuid) ON DELETE SET NULL;

ALTER TABLE ONLY __SCHEMA__.phoenix_kit_files
    ADD CONSTRAINT phoenix_kit_files_library_uuid_fkey FOREIGN KEY (library_uuid) REFERENCES __SCHEMA__.phoenix_kit_storage_libraries(uuid) ON DELETE RESTRICT;

ALTER TABLE ONLY __SCHEMA__.phoenix_kit_files
    ADD CONSTRAINT phoenix_kit_files_original_file_uuid_fkey FOREIGN KEY (original_file_uuid) REFERENCES __SCHEMA__.phoenix_kit_files(uuid) ON DELETE SET NULL;

ALTER TABLE ONLY __SCHEMA__.phoenix_kit_files
    ADD CONSTRAINT phoenix_kit_files_parent_file_uuid_fkey FOREIGN KEY (parent_file_uuid) REFERENCES __SCHEMA__.phoenix_kit_files(uuid) ON DELETE CASCADE;

ALTER TABLE ONLY __SCHEMA__.phoenix_kit_files
    ADD CONSTRAINT phoenix_kit_files_pkey PRIMARY KEY (uuid);

ALTER TABLE ONLY __SCHEMA__.phoenix_kit_files
    ADD CONSTRAINT phoenix_kit_files_stack_uuid_fkey FOREIGN KEY (stack_uuid) REFERENCES __SCHEMA__.phoenix_kit_file_stacks(uuid) ON DELETE SET NULL;

CREATE INDEX phoenix_kit_file_stacks_library_uuid_index ON __SCHEMA__.phoenix_kit_file_stacks USING btree (library_uuid);

CREATE INDEX phoenix_kit_files_capture_date_index ON __SCHEMA__.phoenix_kit_files USING btree (user_uuid, taken_on DESC, taken_at DESC) WHERE ((system_managed = false) AND (trashed_at IS NULL) AND (parent_file_uuid IS NULL) AND ((status)::text = 'active'::text) AND ((file_type)::text = ANY ((ARRAY['image'::character varying, 'video'::character varying])::text[])));

CREATE INDEX phoenix_kit_files_edited_from_uuid_index ON __SCHEMA__.phoenix_kit_files USING btree (edited_from_uuid);

CREATE INDEX phoenix_kit_files_file_path_index ON __SCHEMA__.phoenix_kit_files USING btree (file_path);

CREATE INDEX phoenix_kit_files_file_type_index ON __SCHEMA__.phoenix_kit_files USING btree (file_type);

CREATE INDEX phoenix_kit_files_folder_uuid_index ON __SCHEMA__.phoenix_kit_files USING btree (folder_uuid);

CREATE INDEX phoenix_kit_files_geo_index ON __SCHEMA__.phoenix_kit_files USING gist (point(longitude, latitude)) WHERE ((latitude IS NOT NULL) AND (longitude IS NOT NULL));

CREATE INDEX phoenix_kit_files_inserted_at_index ON __SCHEMA__.phoenix_kit_files USING btree (inserted_at);

CREATE INDEX phoenix_kit_files_library_aspect_ratio_index ON __SCHEMA__.phoenix_kit_files USING btree (library_uuid, aspect_ratio) WHERE (aspect_ratio IS NOT NULL);

CREATE INDEX phoenix_kit_files_library_capture_date_index ON __SCHEMA__.phoenix_kit_files USING btree (library_uuid, taken_on DESC, taken_at DESC) WHERE ((system_managed = false) AND (trashed_at IS NULL) AND (parent_file_uuid IS NULL) AND ((status)::text = 'active'::text) AND ((file_type)::text = ANY ((ARRAY['image'::character varying, 'video'::character varying])::text[])));

CREATE INDEX phoenix_kit_files_library_uuid_index ON __SCHEMA__.phoenix_kit_files USING btree (library_uuid);

CREATE INDEX phoenix_kit_files_original_file_uuid_index ON __SCHEMA__.phoenix_kit_files USING btree (original_file_uuid);

CREATE INDEX phoenix_kit_files_parent_uuid_index ON __SCHEMA__.phoenix_kit_files USING btree (parent_file_uuid) WHERE (parent_file_uuid IS NOT NULL);

CREATE INDEX phoenix_kit_files_stack_index ON __SCHEMA__.phoenix_kit_files USING btree (stack_uuid, stack_position) WHERE (stack_uuid IS NOT NULL);

CREATE INDEX phoenix_kit_files_status_index ON __SCHEMA__.phoenix_kit_files USING btree (status);

CREATE INDEX phoenix_kit_files_system_managed_index ON __SCHEMA__.phoenix_kit_files USING btree (inserted_at DESC) WHERE (system_managed = false);

CREATE INDEX phoenix_kit_files_trashed_at_index ON __SCHEMA__.phoenix_kit_files USING btree (trashed_at) WHERE (trashed_at IS NOT NULL);

CREATE INDEX phoenix_kit_files_user_uuid_idx ON __SCHEMA__.phoenix_kit_files USING btree (user_uuid);

CREATE TABLE __SCHEMA__.phoenix_kit_file_stacks (
    uuid uuid DEFAULT __SCHEMA__.uuid_generate_v7() NOT NULL,
    library_uuid uuid NOT NULL,
    title character varying(200),
    description text,
    created_by_uuid uuid,
    inserted_at timestamp(0) without time zone DEFAULT now() NOT NULL,
    updated_at timestamp(0) without time zone DEFAULT now() NOT NULL
);

CREATE TABLE __SCHEMA__.phoenix_kit_files (
    uuid uuid DEFAULT __SCHEMA__.uuid_generate_v7() NOT NULL,
    original_file_name character varying(255) NOT NULL,
    file_name character varying(255) NOT NULL,
    file_path character varying(255),
    mime_type character varying(255) NOT NULL,
    file_type character varying(255) NOT NULL,
    ext character varying(255) NOT NULL,
    file_checksum character varying(255) NOT NULL,
    size bigint NOT NULL,
    width integer,
    height integer,
    duration integer,
    status character varying(255) DEFAULT 'processing'::character varying NOT NULL,
    metadata jsonb,
    inserted_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL,
    user_file_checksum character varying(255) NOT NULL,
    user_uuid uuid,
    folder_uuid uuid,
    trashed_at timestamp with time zone,
    system_managed boolean DEFAULT false NOT NULL,
    parent_file_uuid uuid,
    edits jsonb,
    edit_revision integer DEFAULT 0 NOT NULL,
    edit_state character varying(16),
    original_file_uuid uuid,
    edited_from_uuid uuid,
    data jsonb DEFAULT '{}'::jsonb NOT NULL,
    taken_at timestamp with time zone,
    taken_on date,
    taken_at_offset integer,
    taken_at_source character varying(255),
    library_uuid uuid DEFAULT '00000000-0000-7000-8000-000000000001'::uuid CONSTRAINT phoenix_kit_files_library_uuid_not_null1 NOT NULL,
    placed_profile_uuid uuid,
    placed_revision integer,
    placed_variant_set_uuid uuid,
    placed_variant_revision integer,
    reconcile_attempted_at timestamp(0) without time zone,
    aspect_ratio double precision GENERATED ALWAYS AS (
CASE
    WHEN ((width > 0) AND (height > 0)) THEN ((width)::double precision / (height)::double precision)
    ELSE NULL::double precision
END) STORED,
    latitude double precision,
    longitude double precision,
    short_code character varying(12),
    reconcile_lock_token uuid,
    reconcile_locked_until timestamp(0) without time zone,
    stack_uuid uuid,
    stack_position integer,
    CONSTRAINT phoenix_kit_files_user_or_parent_check CHECK (((user_uuid IS NOT NULL) OR (parent_file_uuid IS NOT NULL) OR (library_uuid IS NOT NULL)))
);

CREATE UNIQUE INDEX phoenix_kit_files_short_code_index ON __SCHEMA__.phoenix_kit_files USING btree (short_code) WHERE (short_code IS NOT NULL);

CREATE UNIQUE INDEX phoenix_kit_files_system_dedup_index ON __SCHEMA__.phoenix_kit_files USING btree (parent_file_uuid, file_name) WHERE (system_managed = true);

CREATE UNIQUE INDEX phoenix_kit_files_user_file_checksum_index ON __SCHEMA__.phoenix_kit_files USING btree (user_file_checksum);

CREATE UNIQUE INDEX phoenix_kit_files_uuid_library_uuid_index ON __SCHEMA__.phoenix_kit_files USING btree (uuid, library_uuid);
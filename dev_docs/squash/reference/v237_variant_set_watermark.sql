-- Generated V237 reference: the variant sets with their watermark column.
ALTER TABLE ONLY __SCHEMA__.phoenix_kit_variant_sets
    ADD CONSTRAINT phoenix_kit_variant_sets_pkey PRIMARY KEY (uuid);

CREATE TABLE __SCHEMA__.phoenix_kit_variant_sets (
    uuid uuid DEFAULT __SCHEMA__.uuid_generate_v7() NOT NULL,
    name character varying(255) NOT NULL,
    is_default boolean DEFAULT false NOT NULL,
    selectable boolean DEFAULT false NOT NULL,
    generate_variants boolean DEFAULT true NOT NULL,
    generate_tiles boolean DEFAULT false NOT NULL,
    revision integer DEFAULT 1 NOT NULL,
    inserted_at timestamp(0) without time zone DEFAULT now() NOT NULL,
    updated_at timestamp(0) without time zone DEFAULT now() NOT NULL,
    watermark jsonb
);

CREATE UNIQUE INDEX phoenix_kit_variant_sets_default_index ON __SCHEMA__.phoenix_kit_variant_sets USING btree (is_default) WHERE is_default;

CREATE UNIQUE INDEX phoenix_kit_variant_sets_name_index ON __SCHEMA__.phoenix_kit_variant_sets USING btree (lower((name)::text));
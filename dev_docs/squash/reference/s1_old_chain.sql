-- pk-squash-ref kind=s1 schema=pk_sqv_s1a chain_version=164
--
-- PostgreSQL database dump
--

\restrict 7FQvLeKrNICKnYbtiHA6y8JANc8dLn8m5TdWklf1oqSfCM0JlydL5LGHKTSM78V

-- Dumped from database version 17.4 (Debian 17.4-1.pgdg120+2)
-- Dumped by pg_dump version 17.10 (Debian 17.10-1.pgdg13+1)

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: pk_sqv_s1a; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA pk_sqv_s1a;


--
-- Name: oban_job_state; Type: TYPE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TYPE pk_sqv_s1a.oban_job_state AS ENUM (
    'available',
    'suspended',
    'scheduled',
    'executing',
    'retryable',
    'completed',
    'discarded',
    'cancelled'
);


--
-- Name: extract_primary_slug(jsonb); Type: FUNCTION; Schema: pk_sqv_s1a; Owner: -
--

CREATE FUNCTION pk_sqv_s1a.extract_primary_slug(slug_jsonb jsonb) RETURNS text
    LANGUAGE plpgsql IMMUTABLE STRICT
    AS $$
BEGIN
  RETURN (SELECT value FROM jsonb_each_text(slug_jsonb) ORDER BY key LIMIT 1);
END;
$$;


--
-- Name: uuid_generate_v7(); Type: FUNCTION; Schema: pk_sqv_s1a; Owner: -
--

CREATE FUNCTION pk_sqv_s1a.uuid_generate_v7() RETURNS uuid
    LANGUAGE plpgsql
    AS $$
DECLARE
  unix_ts_ms bytea;
  uuid_bytes bytea;
BEGIN
  -- Get current timestamp in milliseconds
  unix_ts_ms := substring(int8send(floor(extract(epoch FROM clock_timestamp()) * 1000)::bigint) FROM 3);

  -- Build UUIDv7: 6 bytes timestamp + 2 bytes random (with version) + 8 bytes random (with variant)
  uuid_bytes := unix_ts_ms || public.gen_random_bytes(10);

  -- Set version 7 (0111xxxx in byte 7)
  uuid_bytes := set_byte(uuid_bytes, 6, (get_byte(uuid_bytes, 6) & 15) | 112);

  -- Set variant (10xxxxxx in byte 9)
  uuid_bytes := set_byte(uuid_bytes, 8, (get_byte(uuid_bytes, 8) & 63) | 128);

  RETURN encode(uuid_bytes, 'hex')::uuid;
END
$$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: oban_jobs; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.oban_jobs (
    id bigint NOT NULL,
    state pk_sqv_s1a.oban_job_state DEFAULT 'available'::pk_sqv_s1a.oban_job_state NOT NULL,
    queue text DEFAULT 'default'::text NOT NULL,
    worker text NOT NULL,
    args jsonb DEFAULT '{}'::jsonb NOT NULL,
    errors jsonb[] DEFAULT ARRAY[]::jsonb[] NOT NULL,
    attempt integer DEFAULT 0 NOT NULL,
    max_attempts integer DEFAULT 20 NOT NULL,
    inserted_at timestamp without time zone DEFAULT timezone('UTC'::text, now()) NOT NULL,
    scheduled_at timestamp without time zone DEFAULT timezone('UTC'::text, now()) NOT NULL,
    attempted_at timestamp without time zone,
    completed_at timestamp without time zone,
    attempted_by text[],
    discarded_at timestamp without time zone,
    priority integer DEFAULT 0 NOT NULL,
    tags text[] DEFAULT ARRAY[]::text[],
    meta jsonb DEFAULT '{}'::jsonb,
    cancelled_at timestamp without time zone,
    CONSTRAINT attempt_range CHECK (((attempt >= 0) AND (attempt <= max_attempts))),
    CONSTRAINT positive_max_attempts CHECK ((max_attempts > 0)),
    CONSTRAINT queue_length CHECK (((char_length(queue) > 0) AND (char_length(queue) < 128))),
    CONSTRAINT worker_length CHECK (((char_length(worker) > 0) AND (char_length(worker) < 128)))
);


--
-- Name: oban_jobs_id_seq; Type: SEQUENCE; Schema: pk_sqv_s1a; Owner: -
--

CREATE SEQUENCE pk_sqv_s1a.oban_jobs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: oban_jobs_id_seq; Type: SEQUENCE OWNED BY; Schema: pk_sqv_s1a; Owner: -
--

ALTER SEQUENCE pk_sqv_s1a.oban_jobs_id_seq OWNED BY pk_sqv_s1a.oban_jobs.id;


--
-- Name: oban_peers; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNLOGGED TABLE pk_sqv_s1a.oban_peers (
    name text NOT NULL,
    node text NOT NULL,
    started_at timestamp without time zone NOT NULL,
    expires_at timestamp without time zone NOT NULL
);


--
-- Name: phoenix_kit; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit (
    id integer NOT NULL,
    version integer NOT NULL,
    migrated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: phoenix_kit_activities; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_activities (
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    action character varying(100) NOT NULL,
    module character varying(50),
    mode character varying(20),
    actor_uuid uuid,
    resource_type character varying(50),
    resource_uuid uuid,
    target_uuid uuid,
    metadata jsonb DEFAULT '{}'::jsonb,
    inserted_at timestamp(0) without time zone DEFAULT now() NOT NULL
);


--
-- Name: phoenix_kit_admin_notes; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_admin_notes (
    content text NOT NULL,
    inserted_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL,
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    user_uuid uuid NOT NULL,
    author_uuid uuid NOT NULL
);


--
-- Name: phoenix_kit_ai_accounts; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_ai_accounts (
    name character varying(100) NOT NULL,
    provider character varying(50) DEFAULT 'openrouter'::character varying NOT NULL,
    api_key text NOT NULL,
    base_url character varying(255),
    settings jsonb DEFAULT '{}'::jsonb,
    enabled boolean DEFAULT true NOT NULL,
    last_validated_at timestamp with time zone,
    inserted_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL,
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL
);


--
-- Name: phoenix_kit_ai_endpoints; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_ai_endpoints (
    name character varying(100) NOT NULL,
    description character varying(500),
    provider character varying(50) DEFAULT 'openrouter'::character varying NOT NULL,
    api_key text NOT NULL,
    base_url character varying(255),
    provider_settings jsonb DEFAULT '{}'::jsonb,
    model character varying(150) NOT NULL,
    temperature double precision DEFAULT 0.7,
    max_tokens integer,
    top_p double precision,
    top_k integer,
    frequency_penalty double precision,
    presence_penalty double precision,
    repetition_penalty double precision,
    stop character varying(255)[],
    seed integer,
    image_size character varying(20),
    image_quality character varying(20),
    dimensions integer,
    enabled boolean DEFAULT true NOT NULL,
    sort_order integer DEFAULT 0 NOT NULL,
    last_validated_at timestamp with time zone,
    inserted_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL,
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    reasoning_enabled boolean,
    reasoning_effort character varying(20),
    reasoning_max_tokens integer,
    reasoning_exclude boolean,
    integration_uuid uuid
);


--
-- Name: phoenix_kit_ai_prompts; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_ai_prompts (
    name character varying(255) NOT NULL,
    slug character varying(255) NOT NULL,
    description text,
    content text NOT NULL,
    variables character varying(255)[] DEFAULT ARRAY[]::character varying[] NOT NULL,
    enabled boolean DEFAULT true NOT NULL,
    sort_order integer DEFAULT 0 NOT NULL,
    usage_count integer DEFAULT 0 NOT NULL,
    last_used_at timestamp with time zone,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    inserted_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL,
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    system_prompt text
);


--
-- Name: phoenix_kit_ai_requests; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_ai_requests (
    slot_index integer,
    model character varying(100),
    request_type character varying(50) DEFAULT 'text_completion'::character varying NOT NULL,
    input_tokens integer DEFAULT 0 NOT NULL,
    output_tokens integer DEFAULT 0 NOT NULL,
    total_tokens integer DEFAULT 0 NOT NULL,
    cost_cents integer,
    latency_ms integer,
    status character varying(20) DEFAULT 'success'::character varying NOT NULL,
    error_message text,
    metadata jsonb DEFAULT '{}'::jsonb,
    inserted_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL,
    endpoint_name character varying(100),
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    prompt_name character varying(255),
    user_uuid uuid,
    endpoint_uuid uuid,
    prompt_uuid uuid,
    account_uuid uuid
);


--
-- Name: phoenix_kit_annotations; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_annotations (
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    file_uuid uuid NOT NULL,
    creator_uuid uuid,
    kind character varying(32) NOT NULL,
    geometry jsonb NOT NULL,
    style jsonb,
    metadata jsonb,
    "position" integer DEFAULT 0 NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    title character varying(200),
    CONSTRAINT phoenix_kit_annotations_kind_check CHECK (((kind)::text = ANY ((ARRAY['rectangle'::character varying, 'circle'::character varying, 'polygon'::character varying, 'freehand'::character varying, 'callout'::character varying, 'text'::character varying, 'dimension'::character varying, 'line'::character varying, 'marker'::character varying, 'image'::character varying])::text[])))
);


--
-- Name: phoenix_kit_audit_logs; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_audit_logs (
    action character varying(255) NOT NULL,
    ip_address character varying(255),
    user_agent text,
    metadata jsonb DEFAULT '{}'::jsonb,
    inserted_at timestamp with time zone NOT NULL,
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    target_user_uuid uuid NOT NULL,
    admin_user_uuid uuid NOT NULL
);


--
-- Name: phoenix_kit_billing_profiles; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_billing_profiles (
    type character varying(20) DEFAULT 'individual'::character varying NOT NULL,
    is_default boolean DEFAULT false NOT NULL,
    name character varying(255),
    first_name character varying(255),
    last_name character varying(255),
    middle_name character varying(255),
    phone character varying(255),
    email character varying(255),
    company_name character varying(255),
    company_vat_number character varying(20),
    company_registration_number character varying(30),
    company_legal_address text,
    address_line1 character varying(255),
    address_line2 character varying(255),
    city character varying(255),
    state character varying(255),
    postal_code character varying(20),
    country character varying(2) DEFAULT 'EE'::character varying,
    metadata jsonb DEFAULT '{}'::jsonb,
    inserted_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL,
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    user_uuid uuid
);


--
-- Name: phoenix_kit_buckets; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_buckets (
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    name character varying(255) NOT NULL,
    provider character varying(255) NOT NULL,
    region character varying(255),
    endpoint character varying(255),
    bucket_name character varying(255),
    access_key_id character varying(255),
    secret_access_key character varying(255),
    cdn_url character varying(255),
    path_prefix character varying(255),
    enabled boolean DEFAULT true NOT NULL,
    priority integer DEFAULT 0 NOT NULL,
    max_size_mb bigint,
    inserted_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL,
    access_type character varying(20) DEFAULT 'public'::character varying
);


--
-- Name: phoenix_kit_calendar_event_participants; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_calendar_event_participants (
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    event_uuid uuid NOT NULL,
    kind character varying(20) NOT NULL,
    target_uuid uuid,
    display_name character varying(255) NOT NULL,
    added_by_uuid uuid,
    inserted_at timestamp(0) without time zone DEFAULT now() NOT NULL,
    updated_at timestamp(0) without time zone DEFAULT now() NOT NULL,
    CONSTRAINT calendar_participant_kind CHECK (((kind)::text = ANY ((ARRAY['user'::character varying, 'staff_person'::character varying, 'crm_contact'::character varying, 'crm_company'::character varying, 'free_text'::character varying])::text[]))),
    CONSTRAINT calendar_participant_shape CHECK (((((kind)::text = 'free_text'::text) AND (target_uuid IS NULL)) OR (((kind)::text <> 'free_text'::text) AND (target_uuid IS NOT NULL))))
);


--
-- Name: phoenix_kit_calendar_events; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_calendar_events (
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    owner_uuid uuid NOT NULL,
    title character varying(255) NOT NULL,
    description text,
    location character varying(255),
    all_day boolean DEFAULT false NOT NULL,
    starts_at timestamp(0) without time zone,
    ends_at timestamp(0) without time zone,
    starts_on date,
    ends_on date,
    color character varying(50),
    status character varying(20) DEFAULT 'active'::character varying NOT NULL,
    inserted_at timestamp(0) without time zone DEFAULT now() NOT NULL,
    updated_at timestamp(0) without time zone DEFAULT now() NOT NULL,
    location_uuid uuid,
    CONSTRAINT calendar_event_status CHECK (((status)::text = ANY ((ARRAY['active'::character varying, 'cancelled'::character varying])::text[]))),
    CONSTRAINT calendar_event_time_shape CHECK ((((all_day = false) AND (starts_at IS NOT NULL) AND (ends_at IS NOT NULL) AND (starts_on IS NULL) AND (ends_on IS NULL) AND (ends_at > starts_at)) OR ((all_day = true) AND (starts_on IS NOT NULL) AND (ends_on IS NOT NULL) AND (starts_at IS NULL) AND (ends_at IS NULL) AND (ends_on > starts_on))))
);


--
-- Name: phoenix_kit_cat_catalogues; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_cat_catalogues (
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    name character varying(255) NOT NULL,
    description text,
    status character varying(20) DEFAULT 'active'::character varying,
    data jsonb DEFAULT '{}'::jsonb,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    markup_percentage numeric(7,2) DEFAULT 0 NOT NULL,
    discount_percentage numeric(7,2) DEFAULT 0 NOT NULL,
    kind character varying(20) DEFAULT 'standard'::character varying NOT NULL,
    "position" integer DEFAULT 0,
    folder_uuid uuid,
    CONSTRAINT phoenix_kit_cat_catalogues_discount_pct_check CHECK (((discount_percentage >= (0)::numeric) AND (discount_percentage <= (100)::numeric))),
    CONSTRAINT phoenix_kit_cat_catalogues_kind_check CHECK (((kind)::text = ANY ((ARRAY['standard'::character varying, 'smart'::character varying])::text[])))
);


--
-- Name: phoenix_kit_cat_categories; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_cat_categories (
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    name character varying(255) NOT NULL,
    description text,
    "position" integer DEFAULT 0,
    status character varying(20) DEFAULT 'active'::character varying,
    catalogue_uuid uuid NOT NULL,
    data jsonb DEFAULT '{}'::jsonb,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    parent_uuid uuid
);


--
-- Name: phoenix_kit_cat_folders; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_cat_folders (
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    name character varying(255) NOT NULL,
    parent_uuid uuid,
    "position" integer DEFAULT 0 NOT NULL,
    status character varying(255) DEFAULT 'active'::character varying NOT NULL,
    data jsonb DEFAULT '{}'::jsonb NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: phoenix_kit_cat_item_catalogue_rules; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_cat_item_catalogue_rules (
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    item_uuid uuid NOT NULL,
    referenced_catalogue_uuid uuid NOT NULL,
    value numeric(12,4),
    unit character varying(20),
    "position" integer DEFAULT 0 NOT NULL,
    inserted_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT phoenix_kit_cat_item_catalogue_rules_value_check CHECK (((value IS NULL) OR (value >= (0)::numeric)))
);


--
-- Name: phoenix_kit_cat_item_supplier_info; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_cat_item_supplier_info (
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    item_uuid uuid NOT NULL,
    supplier_uuid uuid NOT NULL,
    supplier_sku character varying(100),
    supplier_name_snapshot character varying(255),
    unit_cost numeric(14,4),
    currency character varying(3),
    lead_time_days integer,
    min_order_qty numeric(14,4),
    valid_from date,
    valid_to date,
    "position" integer DEFAULT 0 NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    inserted_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    supplier_source character varying(20) DEFAULT 'local'::character varying NOT NULL,
    is_primary boolean DEFAULT false NOT NULL,
    CONSTRAINT phoenix_kit_cat_item_supplier_info_supplier_source_check CHECK (((supplier_source)::text = ANY ((ARRAY['crm_company'::character varying, 'crm_contact'::character varying, 'local'::character varying])::text[])))
);


--
-- Name: phoenix_kit_cat_items; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_cat_items (
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    name character varying(255) NOT NULL,
    description text,
    sku character varying(100),
    base_price numeric(12,2),
    unit character varying(20) DEFAULT 'piece'::character varying,
    status character varying(20) DEFAULT 'active'::character varying,
    category_uuid uuid,
    manufacturer_uuid uuid,
    data jsonb DEFAULT '{}'::jsonb,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    catalogue_uuid uuid,
    markup_percentage numeric(7,2),
    discount_percentage numeric(7,2),
    default_value numeric(12,4),
    default_unit character varying(20),
    "position" integer DEFAULT 0,
    primary_supplier_uuid uuid,
    CONSTRAINT phoenix_kit_cat_items_default_value_check CHECK (((default_value IS NULL) OR (default_value >= (0)::numeric))),
    CONSTRAINT phoenix_kit_cat_items_discount_pct_check CHECK (((discount_percentage IS NULL) OR ((discount_percentage >= (0)::numeric) AND (discount_percentage <= (100)::numeric))))
);


--
-- Name: phoenix_kit_cat_manufacturer_suppliers; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_cat_manufacturer_suppliers (
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    manufacturer_uuid uuid NOT NULL,
    supplier_uuid uuid NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: phoenix_kit_cat_manufacturers; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_cat_manufacturers (
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    name character varying(255) NOT NULL,
    description text,
    website character varying(500),
    contact_info character varying(500),
    logo_url character varying(500),
    notes text,
    status character varying(20) DEFAULT 'active'::character varying,
    data jsonb DEFAULT '{}'::jsonb,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: phoenix_kit_cat_pdf_extractions; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_cat_pdf_extractions (
    file_uuid uuid NOT NULL,
    extraction_status character varying(20) DEFAULT 'pending'::character varying NOT NULL,
    page_count integer,
    extracted_at timestamp(0) without time zone,
    error_message text,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: phoenix_kit_cat_pdf_page_contents; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_cat_pdf_page_contents (
    content_hash character varying(64) NOT NULL,
    text text NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL
);


--
-- Name: phoenix_kit_cat_pdf_pages; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_cat_pdf_pages (
    file_uuid uuid NOT NULL,
    page_number integer NOT NULL,
    content_hash character varying(64) NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL
);


--
-- Name: phoenix_kit_cat_pdfs; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_cat_pdfs (
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    file_uuid uuid NOT NULL,
    original_filename character varying(500) NOT NULL,
    byte_size bigint,
    status character varying(20) DEFAULT 'active'::character varying NOT NULL,
    trashed_at timestamp(0) without time zone,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: phoenix_kit_cat_suppliers; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_cat_suppliers (
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    name character varying(255) NOT NULL,
    description text,
    website character varying(500),
    contact_info character varying(500),
    notes text,
    status character varying(20) DEFAULT 'active'::character varying,
    data jsonb DEFAULT '{}'::jsonb,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    crm_company_uuid uuid
);


--
-- Name: phoenix_kit_comment_dislikes; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_comment_dislikes (
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    comment_uuid uuid NOT NULL,
    inserted_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL,
    user_uuid uuid NOT NULL
);


--
-- Name: phoenix_kit_comment_likes; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_comment_likes (
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    comment_uuid uuid NOT NULL,
    inserted_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL,
    user_uuid uuid NOT NULL
);


--
-- Name: phoenix_kit_comment_media; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_comment_media (
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    comment_uuid uuid NOT NULL,
    file_uuid uuid NOT NULL,
    "position" integer NOT NULL,
    caption text,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: phoenix_kit_comments; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_comments (
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    resource_type character varying(50) NOT NULL,
    resource_uuid uuid NOT NULL,
    parent_uuid uuid,
    content text NOT NULL,
    status character varying(20) DEFAULT 'published'::character varying NOT NULL,
    depth integer DEFAULT 0 NOT NULL,
    like_count integer DEFAULT 0 NOT NULL,
    dislike_count integer DEFAULT 0 NOT NULL,
    inserted_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    user_uuid uuid,
    metadata jsonb DEFAULT '{}'::jsonb
);


--
-- Name: phoenix_kit_comments_dislikes; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_comments_dislikes (
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    comment_uuid uuid NOT NULL,
    inserted_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    user_uuid uuid NOT NULL
);


--
-- Name: phoenix_kit_comments_likes; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_comments_likes (
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    comment_uuid uuid NOT NULL,
    inserted_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    user_uuid uuid NOT NULL
);


--
-- Name: phoenix_kit_consent_logs; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_consent_logs (
    session_id character varying(64),
    consent_type character varying(30) NOT NULL,
    consent_given boolean DEFAULT false NOT NULL,
    consent_version character varying(20),
    ip_address character varying(45),
    user_agent_hash character varying(64),
    metadata jsonb DEFAULT '{}'::jsonb,
    inserted_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL,
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    user_uuid uuid
);


--
-- Name: phoenix_kit_crm_companies; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_crm_companies (
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    name character varying(255),
    status character varying(50) DEFAULT 'active'::character varying NOT NULL,
    website character varying(255),
    email public.citext,
    phone character varying(50),
    address text,
    industry character varying(255),
    notes text,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    inserted_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: phoenix_kit_crm_company_memberships; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_crm_company_memberships (
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    contact_uuid uuid NOT NULL,
    company_uuid uuid NOT NULL,
    role_in_company character varying(255),
    department character varying(255),
    is_primary boolean DEFAULT false NOT NULL,
    "position" integer DEFAULT 0 NOT NULL,
    inserted_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: phoenix_kit_crm_contacts; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_crm_contacts (
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    name character varying(255),
    status character varying(50) DEFAULT 'active'::character varying NOT NULL,
    email public.citext,
    phone character varying(50),
    notes text,
    user_uuid uuid,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    inserted_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    locale character varying(10),
    opted_out_at timestamp with time zone,
    consent jsonb DEFAULT '{}'::jsonb NOT NULL
);


--
-- Name: phoenix_kit_crm_interaction_parties; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_crm_interaction_parties (
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    interaction_uuid uuid NOT NULL,
    raw_name character varying(255) NOT NULL,
    contact_uuid uuid,
    staff_person_uuid uuid,
    party_snapshot jsonb DEFAULT '{}'::jsonb NOT NULL,
    "position" integer DEFAULT 0 NOT NULL,
    inserted_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT phoenix_kit_crm_party_exclusive_arc CHECK ((NOT ((contact_uuid IS NOT NULL) AND (staff_person_uuid IS NOT NULL))))
);


--
-- Name: phoenix_kit_crm_interactions; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_crm_interactions (
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    contact_uuid uuid NOT NULL,
    interaction_type character varying(50) DEFAULT 'note'::character varying NOT NULL,
    occurred_at timestamp with time zone DEFAULT now() NOT NULL,
    subject character varying(255),
    body text,
    owner_user_uuid uuid,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    inserted_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: phoenix_kit_crm_list_members; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_crm_list_members (
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    list_uuid uuid NOT NULL,
    contact_uuid uuid NOT NULL,
    email public.citext,
    status character varying(20) DEFAULT 'subscribed'::character varying NOT NULL,
    subscribed_at timestamp with time zone,
    unsubscribed_at timestamp with time zone,
    source character varying(20) DEFAULT 'manual'::character varying NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    inserted_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT phoenix_kit_crm_list_members_source_check CHECK (((source)::text = ANY ((ARRAY['manual'::character varying, 'import'::character varying, 'form'::character varying, 'api'::character varying])::text[]))),
    CONSTRAINT phoenix_kit_crm_list_members_status_check CHECK (((status)::text = ANY ((ARRAY['subscribed'::character varying, 'pending'::character varying, 'removed'::character varying])::text[])))
);


--
-- Name: phoenix_kit_crm_lists; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_crm_lists (
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    name character varying(255) NOT NULL,
    slug character varying(255) NOT NULL,
    description text,
    status character varying(20) DEFAULT 'active'::character varying NOT NULL,
    subscribable boolean DEFAULT false NOT NULL,
    subscriber_count integer DEFAULT 0 NOT NULL,
    locale character varying(10),
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    inserted_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT phoenix_kit_crm_lists_status_check CHECK (((status)::text = ANY ((ARRAY['active'::character varying, 'archived'::character varying])::text[])))
);


--
-- Name: phoenix_kit_crm_party_roles; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_crm_party_roles (
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    roleable_type character varying(20) NOT NULL,
    roleable_uuid uuid NOT NULL,
    role character varying(30) NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    valid_from date,
    valid_to date,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    inserted_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT phoenix_kit_crm_party_roles_roleable_type_check CHECK (((roleable_type)::text = ANY ((ARRAY['company'::character varying, 'contact'::character varying])::text[])))
);


--
-- Name: phoenix_kit_crm_role_settings; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_crm_role_settings (
    role_uuid uuid NOT NULL,
    enabled boolean DEFAULT false NOT NULL,
    inserted_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: phoenix_kit_crm_user_role_view; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_crm_user_role_view (
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    user_uuid uuid NOT NULL,
    scope character varying(100) NOT NULL,
    view_config jsonb DEFAULT '{}'::jsonb NOT NULL,
    inserted_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: phoenix_kit_currencies; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_currencies (
    code character varying(3) NOT NULL,
    name character varying(255) NOT NULL,
    symbol character varying(5) NOT NULL,
    decimal_places integer DEFAULT 2 NOT NULL,
    is_default boolean DEFAULT false NOT NULL,
    enabled boolean DEFAULT true NOT NULL,
    exchange_rate numeric(15,6) DEFAULT 1 NOT NULL,
    sort_order integer DEFAULT 0 NOT NULL,
    inserted_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL,
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL
);


--
-- Name: phoenix_kit_dashboards; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_dashboards (
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    title character varying(255) NOT NULL,
    slug character varying(255) NOT NULL,
    owner_user_uuid uuid,
    role_uuid uuid,
    scope character varying(20) DEFAULT 'personal'::character varying NOT NULL,
    layout jsonb DEFAULT '[]'::jsonb NOT NULL,
    is_default boolean DEFAULT false NOT NULL,
    "position" integer DEFAULT 0 NOT NULL,
    inserted_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    config jsonb DEFAULT '{}'::jsonb NOT NULL
);


--
-- Name: phoenix_kit_doc_categories; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_doc_categories (
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    name character varying(255) NOT NULL,
    description text,
    "position" integer DEFAULT 0 NOT NULL,
    status character varying(255) DEFAULT 'active'::character varying NOT NULL,
    data jsonb DEFAULT '{}'::jsonb NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: phoenix_kit_doc_document_sections; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_doc_document_sections (
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    document_uuid uuid NOT NULL,
    template_uuid uuid,
    "position" integer NOT NULL,
    variable_values jsonb DEFAULT '{}'::jsonb NOT NULL,
    image_params jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_by_uuid uuid NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: phoenix_kit_doc_documents; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_doc_documents (
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    name character varying(255) NOT NULL,
    template_uuid uuid,
    content_html text DEFAULT ''::text,
    content_css text DEFAULT ''::text,
    content_native jsonb,
    variable_values jsonb DEFAULT '{}'::jsonb,
    header_html text DEFAULT ''::text,
    header_css text DEFAULT ''::text,
    header_height character varying(20) DEFAULT '25mm'::character varying,
    footer_html text DEFAULT ''::text,
    footer_css text DEFAULT ''::text,
    footer_height character varying(20) DEFAULT '20mm'::character varying,
    config jsonb DEFAULT '{"paper_size": "a4", "orientation": "portrait"}'::jsonb,
    data jsonb DEFAULT '{}'::jsonb,
    thumbnail text,
    created_by_uuid uuid,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    google_doc_id character varying(255),
    status character varying(20) DEFAULT 'published'::character varying,
    path character varying(500),
    folder_id character varying(255),
    category_uuid uuid,
    type_uuid uuid
);


--
-- Name: phoenix_kit_doc_headers_footers; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_doc_headers_footers (
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    name character varying(255) NOT NULL,
    type character varying(20) DEFAULT 'header'::character varying NOT NULL,
    html text DEFAULT ''::text,
    css text DEFAULT ''::text,
    native jsonb,
    height character varying(20) DEFAULT '25mm'::character varying,
    data jsonb DEFAULT '{}'::jsonb,
    created_by_uuid uuid,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    google_doc_id character varying(255)
);


--
-- Name: phoenix_kit_doc_template_presets; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_doc_template_presets (
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    name character varying NOT NULL,
    description text,
    scope_type character varying,
    scope_id character varying,
    sections jsonb DEFAULT '[]'::jsonb NOT NULL,
    created_by_uuid uuid NOT NULL,
    inserted_at timestamp(0) without time zone DEFAULT now() NOT NULL,
    updated_at timestamp(0) without time zone DEFAULT now() NOT NULL
);


--
-- Name: phoenix_kit_doc_templates; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_doc_templates (
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    name character varying(255) NOT NULL,
    slug character varying(255),
    description text,
    status character varying(20) DEFAULT 'published'::character varying,
    content_html text DEFAULT ''::text,
    content_css text DEFAULT ''::text,
    content_native jsonb,
    variables jsonb DEFAULT '[]'::jsonb,
    header_uuid uuid,
    footer_uuid uuid,
    config jsonb DEFAULT '{"paper_size": "a4", "orientation": "portrait"}'::jsonb,
    data jsonb DEFAULT '{}'::jsonb,
    thumbnail text,
    created_by_uuid uuid,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    google_doc_id character varying(255),
    path character varying(500),
    folder_id character varying(255),
    language character varying(10),
    category_uuid uuid,
    type_uuid uuid
);


--
-- Name: phoenix_kit_doc_types; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_doc_types (
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    name character varying(255) NOT NULL,
    description text,
    "position" integer DEFAULT 0 NOT NULL,
    status character varying(255) DEFAULT 'active'::character varying NOT NULL,
    data jsonb DEFAULT '{}'::jsonb NOT NULL,
    category_uuid uuid NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: phoenix_kit_email_blocklist; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_email_blocklist (
    email character varying(255) NOT NULL,
    reason character varying(255) NOT NULL,
    expires_at timestamp with time zone,
    inserted_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    user_uuid uuid
);


--
-- Name: phoenix_kit_email_events; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_email_events (
    event_type character varying(255) NOT NULL,
    event_data jsonb DEFAULT '{}'::jsonb,
    occurred_at timestamp with time zone DEFAULT now() NOT NULL,
    ip_address character varying(255),
    user_agent character varying(255),
    geo_location jsonb DEFAULT '{}'::jsonb,
    link_url character varying(255),
    bounce_type character varying(255),
    complaint_type character varying(255),
    inserted_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL,
    reject_reason character varying(255),
    delay_type character varying(255),
    subscription_type character varying(255),
    failure_reason character varying(255),
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    email_log_uuid uuid NOT NULL
);


--
-- Name: phoenix_kit_email_logs; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_email_logs (
    message_id character varying(255) NOT NULL,
    "to" character varying(255) NOT NULL,
    "from" character varying(255) NOT NULL,
    subject character varying(255),
    headers jsonb DEFAULT '{}'::jsonb,
    body_preview text,
    body_full text,
    template_name character varying(255),
    campaign_id character varying(255),
    attachments_count integer DEFAULT 0 NOT NULL,
    size_bytes integer,
    retry_count integer DEFAULT 0 NOT NULL,
    error_message text,
    status character varying(255) DEFAULT 'sent'::character varying NOT NULL,
    sent_at timestamp with time zone DEFAULT now() NOT NULL,
    delivered_at timestamp with time zone,
    configuration_set character varying(255),
    message_tags jsonb DEFAULT '{}'::jsonb,
    provider character varying(255) DEFAULT 'unknown'::character varying NOT NULL,
    inserted_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL,
    aws_message_id character varying(255),
    bounced_at timestamp with time zone,
    complained_at timestamp with time zone,
    opened_at timestamp with time zone,
    clicked_at timestamp with time zone,
    body_compressed boolean DEFAULT false NOT NULL,
    queued_at timestamp with time zone,
    rejected_at timestamp with time zone,
    failed_at timestamp with time zone,
    delayed_at timestamp with time zone,
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    user_uuid uuid,
    locale character varying(10) DEFAULT 'en'::character varying NOT NULL
);


--
-- Name: phoenix_kit_email_metrics; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_email_metrics (
    metric_key character varying(255) NOT NULL,
    value bigint DEFAULT 0 NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb,
    metric_date date DEFAULT CURRENT_DATE NOT NULL,
    inserted_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL,
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL
);


--
-- Name: phoenix_kit_email_orphaned_events; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_email_orphaned_events (
    aws_message_id character varying(255) NOT NULL,
    event_type character varying(255) NOT NULL,
    event_data jsonb DEFAULT '{}'::jsonb NOT NULL,
    received_at timestamp with time zone DEFAULT now() NOT NULL,
    matched boolean DEFAULT false NOT NULL,
    matched_at timestamp with time zone,
    error_message text,
    inserted_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL,
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    matched_email_log_uuid uuid
);


--
-- Name: phoenix_kit_email_send_profiles; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_email_send_profiles (
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    name character varying(255) NOT NULL,
    integration_uuid uuid NOT NULL,
    provider_kind character varying(40) NOT NULL,
    from_name character varying(255),
    from_email character varying(255),
    reply_to character varying(255),
    signature_html text,
    signature_text text,
    rate_per_hour integer,
    rate_per_day integer,
    pause_seconds integer DEFAULT 0,
    advanced jsonb DEFAULT '{}'::jsonb NOT NULL,
    enabled boolean DEFAULT true NOT NULL,
    is_default boolean DEFAULT false NOT NULL,
    inserted_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: phoenix_kit_email_templates; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_email_templates (
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    name character varying(255) NOT NULL,
    slug character varying(255) NOT NULL,
    display_name jsonb NOT NULL,
    description jsonb,
    subject jsonb NOT NULL,
    html_body jsonb NOT NULL,
    text_body jsonb NOT NULL,
    category character varying(255) DEFAULT 'transactional'::character varying NOT NULL,
    status character varying(255) DEFAULT 'draft'::character varying NOT NULL,
    variables jsonb DEFAULT '{}'::jsonb,
    metadata jsonb DEFAULT '{}'::jsonb,
    usage_count integer DEFAULT 0 NOT NULL,
    last_used_at timestamp with time zone,
    version integer DEFAULT 1 NOT NULL,
    is_system boolean DEFAULT false NOT NULL,
    created_by_user_uuid uuid,
    updated_by_user_uuid uuid,
    inserted_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL
);


--
-- Name: phoenix_kit_entities; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_entities (
    name character varying(255) NOT NULL,
    display_name character varying(255) NOT NULL,
    display_name_plural character varying(255),
    description text,
    icon character varying(255),
    status character varying(255) DEFAULT 'draft'::character varying NOT NULL,
    fields_definition jsonb DEFAULT '[]'::jsonb NOT NULL,
    settings jsonb,
    date_created timestamp with time zone DEFAULT now() NOT NULL,
    date_updated timestamp with time zone DEFAULT now() NOT NULL,
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    created_by_uuid uuid NOT NULL,
    "position" integer DEFAULT 0
);


--
-- Name: phoenix_kit_entity_data; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_entity_data (
    title character varying(255) NOT NULL,
    slug character varying(255),
    status character varying(255) DEFAULT 'draft'::character varying NOT NULL,
    data jsonb DEFAULT '{}'::jsonb NOT NULL,
    metadata jsonb,
    date_created timestamp with time zone DEFAULT now() NOT NULL,
    date_updated timestamp with time zone DEFAULT now() NOT NULL,
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    created_by_uuid uuid NOT NULL,
    entity_uuid uuid NOT NULL,
    "position" integer,
    parent_uuid uuid
);


--
-- Name: phoenix_kit_file_instances; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_file_instances (
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    variant_name character varying(255) NOT NULL,
    file_name character varying(255) NOT NULL,
    mime_type character varying(255) NOT NULL,
    ext character varying(255) NOT NULL,
    checksum character varying(255) NOT NULL,
    size bigint NOT NULL,
    width integer,
    height integer,
    processing_status character varying(255) DEFAULT 'pending'::character varying NOT NULL,
    file_uuid uuid NOT NULL,
    inserted_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL
);


--
-- Name: phoenix_kit_file_locations; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_file_locations (
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    path character varying(255) NOT NULL,
    status character varying(255) DEFAULT 'active'::character varying NOT NULL,
    priority integer DEFAULT 0 NOT NULL,
    last_verified_at timestamp with time zone,
    file_instance_uuid uuid NOT NULL,
    bucket_uuid uuid NOT NULL,
    inserted_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL
);


--
-- Name: phoenix_kit_files; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_files (
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
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
    CONSTRAINT phoenix_kit_files_user_or_parent_check CHECK (((user_uuid IS NOT NULL) OR (parent_file_uuid IS NOT NULL)))
);


--
-- Name: phoenix_kit_invoices; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_invoices (
    invoice_number character varying(30) NOT NULL,
    status character varying(20) DEFAULT 'draft'::character varying NOT NULL,
    subtotal numeric(15,2) DEFAULT 0 NOT NULL,
    tax_amount numeric(15,2) DEFAULT 0 NOT NULL,
    tax_rate numeric(5,4) DEFAULT 0 NOT NULL,
    total numeric(15,2) NOT NULL,
    currency character varying(3) DEFAULT 'EUR'::character varying NOT NULL,
    due_date date,
    billing_details jsonb DEFAULT '{}'::jsonb,
    line_items jsonb DEFAULT '[]'::jsonb NOT NULL,
    payment_terms character varying(255),
    bank_details jsonb DEFAULT '{}'::jsonb,
    notes text,
    metadata jsonb DEFAULT '{}'::jsonb,
    receipt_number character varying(30),
    receipt_generated_at timestamp with time zone,
    receipt_data jsonb DEFAULT '{}'::jsonb,
    sent_at timestamp with time zone,
    paid_at timestamp with time zone,
    voided_at timestamp with time zone,
    inserted_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL,
    paid_amount numeric(15,2) DEFAULT 0 NOT NULL,
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    user_uuid uuid NOT NULL,
    order_uuid uuid,
    subscription_uuid uuid
);


--
-- Name: phoenix_kit_location_spaces; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_location_spaces (
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    location_uuid uuid NOT NULL,
    parent_uuid uuid,
    kind character varying(32) NOT NULL,
    name character varying(255) NOT NULL,
    description text,
    notes text,
    status character varying(20) DEFAULT 'active'::character varying NOT NULL,
    "position" integer DEFAULT 0 NOT NULL,
    data jsonb DEFAULT '{}'::jsonb NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    CONSTRAINT phoenix_kit_location_spaces_kind_check CHECK (((kind)::text = ANY ((ARRAY['floor'::character varying, 'room'::character varying, 'hall'::character varying, 'suite'::character varying, 'section'::character varying, 'zone'::character varying, 'aisle'::character varying, 'shelf'::character varying, 'corner'::character varying])::text[]))),
    CONSTRAINT phoenix_kit_location_spaces_status_check CHECK (((status)::text = ANY ((ARRAY['active'::character varying, 'inactive'::character varying])::text[])))
);


--
-- Name: phoenix_kit_location_type_assignments; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_location_type_assignments (
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    location_uuid uuid NOT NULL,
    location_type_uuid uuid NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: phoenix_kit_location_types; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_location_types (
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    name character varying(255) NOT NULL,
    description text,
    status character varying(20) DEFAULT 'active'::character varying,
    data jsonb DEFAULT '{}'::jsonb,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: phoenix_kit_locations; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_locations (
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    name character varying(255) NOT NULL,
    description text,
    public_notes text,
    address_line_1 character varying(500),
    address_line_2 character varying(500),
    city character varying(255),
    state character varying(255),
    postal_code character varying(20),
    country character varying(255),
    phone character varying(50),
    email character varying(255),
    website character varying(500),
    notes text,
    status character varying(20) DEFAULT 'active'::character varying,
    features jsonb DEFAULT '{}'::jsonb,
    data jsonb DEFAULT '{}'::jsonb,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: phoenix_kit_machine_operations; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_machine_operations (
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    machine_uuid uuid NOT NULL,
    operation_uuid uuid NOT NULL,
    time_norm_seconds integer,
    inserted_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: phoenix_kit_machine_type_assignments; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_machine_type_assignments (
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    machine_uuid uuid NOT NULL,
    machine_type_uuid uuid NOT NULL,
    inserted_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: phoenix_kit_machines; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_machines (
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    name character varying(255) NOT NULL,
    code character varying(100),
    manufacturer character varying(255),
    serial_number character varying(255),
    description text,
    location_note character varying(500),
    status character varying(20) DEFAULT 'active'::character varying NOT NULL,
    data jsonb DEFAULT '{}'::jsonb NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    inserted_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    model character varying(255),
    manufacture_year integer,
    commissioned_on date,
    warranty_until date,
    to_last_on date,
    to_interval_days integer,
    to_next_on date,
    notes text,
    location_uuid uuid,
    space_uuid uuid
);


--
-- Name: phoenix_kit_media_folder_links; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_media_folder_links (
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    folder_uuid uuid NOT NULL,
    file_uuid uuid NOT NULL,
    inserted_at timestamp(0) without time zone DEFAULT now() NOT NULL
);


--
-- Name: phoenix_kit_media_folders; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_media_folders (
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    name character varying(255) NOT NULL,
    color character varying(20),
    parent_uuid uuid,
    user_uuid uuid,
    inserted_at timestamp(0) without time zone DEFAULT now() NOT NULL,
    updated_at timestamp(0) without time zone DEFAULT now() NOT NULL,
    trashed_at timestamp with time zone,
    description text,
    cover_file_uuid uuid,
    logo_file_uuid uuid,
    header_size text DEFAULT 'small'::text NOT NULL,
    header_show_title boolean DEFAULT true NOT NULL,
    header_show_icon boolean DEFAULT true NOT NULL,
    header_show_creator boolean DEFAULT true NOT NULL,
    header_show_date boolean DEFAULT true NOT NULL,
    header_show_file_count boolean DEFAULT true NOT NULL,
    header_show_description boolean DEFAULT true NOT NULL,
    header_show_background boolean DEFAULT true NOT NULL
);


--
-- Name: phoenix_kit_newsletters_broadcasts; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_newsletters_broadcasts (
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    subject character varying(998) NOT NULL,
    markdown_body text,
    html_body text,
    text_body text,
    template_uuid uuid,
    status character varying(20) DEFAULT 'draft'::character varying NOT NULL,
    scheduled_at timestamp with time zone,
    sent_at timestamp with time zone,
    total_recipients integer DEFAULT 0 NOT NULL,
    sent_count integer DEFAULT 0 NOT NULL,
    delivered_count integer DEFAULT 0 NOT NULL,
    opened_count integer DEFAULT 0 NOT NULL,
    bounced_count integer DEFAULT 0 NOT NULL,
    created_by_user_uuid uuid,
    inserted_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    send_profile_uuid uuid,
    source_type character varying(20) DEFAULT 'newsletters_list'::character varying NOT NULL,
    crm_list_uuid uuid,
    source_params jsonb DEFAULT '{}'::jsonb NOT NULL,
    attachments jsonb DEFAULT '[]'::jsonb NOT NULL,
    CONSTRAINT phoenix_kit_newsletters_broadcasts_attachments_is_array CHECK ((jsonb_typeof(attachments) = 'array'::text))
);


--
-- Name: phoenix_kit_newsletters_deliveries; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_newsletters_deliveries (
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    broadcast_uuid uuid NOT NULL,
    user_uuid uuid,
    status character varying(20) DEFAULT 'pending'::character varying NOT NULL,
    sent_at timestamp with time zone,
    delivered_at timestamp with time zone,
    opened_at timestamp with time zone,
    error text,
    message_id character varying(255),
    inserted_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    recipient_email public.citext,
    crm_contact_uuid uuid,
    CONSTRAINT phoenix_kit_newsletters_deliveries_recipient_check CHECK ((((user_uuid IS NOT NULL) OR (recipient_email IS NOT NULL)) AND (NOT ((user_uuid IS NOT NULL) AND (crm_contact_uuid IS NOT NULL)))))
);


--
-- Name: phoenix_kit_notifications; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_notifications (
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    activity_uuid uuid,
    recipient_uuid uuid NOT NULL,
    seen_at timestamp with time zone,
    dismissed_at timestamp with time zone,
    inserted_at timestamp with time zone DEFAULT now() NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL
);


--
-- Name: phoenix_kit_og_assignments; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_og_assignments (
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    module_key character varying(64) NOT NULL,
    scope_type character varying(32) NOT NULL,
    scope_uuid uuid,
    template_uuid uuid NOT NULL,
    slot_mapping jsonb DEFAULT '{}'::jsonb NOT NULL,
    inserted_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: phoenix_kit_og_templates; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_og_templates (
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    name character varying(255) NOT NULL,
    description character varying(1024),
    canvas jsonb DEFAULT '{}'::jsonb NOT NULL,
    preview_image_uuid uuid,
    inserted_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: phoenix_kit_orders; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_orders (
    order_number character varying(30) NOT NULL,
    status character varying(20) DEFAULT 'draft'::character varying NOT NULL,
    payment_method character varying(20),
    line_items jsonb DEFAULT '[]'::jsonb NOT NULL,
    subtotal numeric(15,2) DEFAULT 0 NOT NULL,
    tax_amount numeric(15,2) DEFAULT 0 NOT NULL,
    tax_rate numeric(5,4) DEFAULT 0 NOT NULL,
    discount_amount numeric(15,2) DEFAULT 0 NOT NULL,
    discount_code character varying(50),
    total numeric(15,2) NOT NULL,
    currency character varying(3) DEFAULT 'EUR'::character varying NOT NULL,
    billing_snapshot jsonb DEFAULT '{}'::jsonb,
    notes text,
    internal_notes text,
    metadata jsonb DEFAULT '{}'::jsonb,
    confirmed_at timestamp with time zone,
    paid_at timestamp with time zone,
    cancelled_at timestamp with time zone,
    inserted_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL,
    checkout_session_id character varying(255),
    checkout_url text,
    checkout_expires_at timestamp with time zone,
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    user_uuid uuid,
    billing_profile_uuid uuid,
    payment_option_uuid uuid
);


--
-- Name: phoenix_kit_organization_invitations; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_organization_invitations (
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    organization_uuid uuid NOT NULL,
    email character varying(160) NOT NULL,
    invited_by_uuid uuid,
    token bytea NOT NULL,
    status character varying(20) DEFAULT 'pending'::character varying NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    accepted_at timestamp with time zone,
    inserted_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT phoenix_kit_org_invitations_status_check CHECK (((status)::text = ANY ((ARRAY['pending'::character varying, 'accepted'::character varying, 'declined'::character varying, 'cancelled'::character varying])::text[])))
);


--
-- Name: phoenix_kit_payment_methods; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_payment_methods (
    provider character varying(20) NOT NULL,
    provider_payment_method_id character varying(255) NOT NULL,
    provider_customer_id character varying(255),
    type character varying(20) DEFAULT 'card'::character varying NOT NULL,
    brand character varying(20),
    last4 character varying(4),
    exp_month integer,
    exp_year integer,
    display_name character varying(255),
    is_default boolean DEFAULT false NOT NULL,
    status character varying(20) DEFAULT 'active'::character varying NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    inserted_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL,
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    user_uuid uuid NOT NULL
);


--
-- Name: phoenix_kit_payment_options; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_payment_options (
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    name character varying(255) NOT NULL,
    code character varying(50) NOT NULL,
    type character varying(20) DEFAULT 'offline'::character varying NOT NULL,
    provider character varying(50),
    description text,
    instructions text,
    icon character varying(100) DEFAULT 'hero-banknotes'::character varying,
    active boolean DEFAULT false,
    "position" integer DEFAULT 0,
    requires_billing_profile boolean DEFAULT true,
    settings jsonb DEFAULT '{}'::jsonb,
    inserted_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: phoenix_kit_payment_provider_configs; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_payment_provider_configs (
    provider character varying(20) NOT NULL,
    enabled boolean DEFAULT false NOT NULL,
    mode character varying(10) DEFAULT 'test'::character varying NOT NULL,
    api_key text,
    api_secret text,
    webhook_secret text,
    webhook_url character varying(255),
    last_verified_at timestamp with time zone,
    verification_status character varying(20) DEFAULT 'pending'::character varying,
    verification_error text,
    config jsonb DEFAULT '{}'::jsonb NOT NULL,
    inserted_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL,
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL
);


--
-- Name: phoenix_kit_post_comments; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_post_comments (
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    post_uuid uuid NOT NULL,
    parent_uuid uuid,
    content text NOT NULL,
    status character varying(255) DEFAULT 'published'::character varying NOT NULL,
    depth integer DEFAULT 0 NOT NULL,
    like_count integer DEFAULT 0 NOT NULL,
    inserted_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL,
    dislike_count integer DEFAULT 0 NOT NULL,
    user_uuid uuid NOT NULL
);


--
-- Name: phoenix_kit_post_dislikes; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_post_dislikes (
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    post_uuid uuid NOT NULL,
    inserted_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL,
    user_uuid uuid NOT NULL
);


--
-- Name: phoenix_kit_post_group_assignments; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_post_group_assignments (
    post_uuid uuid NOT NULL,
    group_uuid uuid NOT NULL,
    "position" integer DEFAULT 0 NOT NULL,
    inserted_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL
);


--
-- Name: phoenix_kit_post_groups; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_post_groups (
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    name character varying(255) NOT NULL,
    slug character varying(255) NOT NULL,
    description text,
    cover_image_uuid uuid,
    post_count integer DEFAULT 0 NOT NULL,
    is_public boolean DEFAULT false NOT NULL,
    "position" integer DEFAULT 0 NOT NULL,
    inserted_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL,
    user_uuid uuid NOT NULL
);


--
-- Name: phoenix_kit_post_likes; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_post_likes (
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    post_uuid uuid NOT NULL,
    inserted_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL,
    user_uuid uuid NOT NULL
);


--
-- Name: phoenix_kit_post_media; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_post_media (
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    post_uuid uuid NOT NULL,
    file_uuid uuid NOT NULL,
    "position" integer NOT NULL,
    caption text,
    inserted_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL
);


--
-- Name: phoenix_kit_post_mentions; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_post_mentions (
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    post_uuid uuid NOT NULL,
    mention_type character varying(255) DEFAULT 'mention'::character varying NOT NULL,
    inserted_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL,
    user_uuid uuid NOT NULL
);


--
-- Name: phoenix_kit_post_tag_assignments; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_post_tag_assignments (
    post_uuid uuid NOT NULL,
    tag_uuid uuid NOT NULL,
    inserted_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL
);


--
-- Name: phoenix_kit_post_tags; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_post_tags (
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    name character varying(255) NOT NULL,
    slug character varying(255) NOT NULL,
    usage_count integer DEFAULT 0 NOT NULL,
    inserted_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL
);


--
-- Name: phoenix_kit_post_views; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_post_views (
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    post_uuid uuid NOT NULL,
    ip_address character varying(255),
    user_agent_hash character varying(255),
    session_id character varying(255),
    viewed_at timestamp with time zone NOT NULL,
    inserted_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL,
    user_uuid uuid
);


--
-- Name: phoenix_kit_posts; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_posts (
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    title character varying(255) NOT NULL,
    sub_title character varying(255),
    content text NOT NULL,
    type character varying(255) DEFAULT 'post'::character varying NOT NULL,
    status character varying(255) DEFAULT 'draft'::character varying NOT NULL,
    scheduled_at timestamp with time zone,
    published_at timestamp with time zone,
    repost_url character varying(255),
    slug character varying(255) NOT NULL,
    like_count integer DEFAULT 0 NOT NULL,
    comment_count integer DEFAULT 0 NOT NULL,
    view_count integer DEFAULT 0 NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb,
    inserted_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL,
    dislike_count integer DEFAULT 0 NOT NULL,
    user_uuid uuid NOT NULL
);


--
-- Name: phoenix_kit_project_assignments; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_project_assignments (
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    project_uuid uuid NOT NULL,
    task_uuid uuid,
    status character varying(20) DEFAULT 'todo'::character varying NOT NULL,
    "position" integer DEFAULT 0 NOT NULL,
    description text,
    estimated_duration integer,
    estimated_duration_unit character varying(20),
    assigned_team_uuid uuid,
    assigned_department_uuid uuid,
    assigned_person_uuid uuid,
    counts_weekends boolean,
    progress_pct integer DEFAULT 0 NOT NULL,
    track_progress boolean DEFAULT false NOT NULL,
    completed_by_uuid uuid,
    completed_at timestamp with time zone,
    inserted_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    translations jsonb DEFAULT '{}'::jsonb NOT NULL,
    child_project_uuid uuid,
    CONSTRAINT phoenix_kit_project_assignments_single_assignee CHECK ((num_nonnulls(assigned_team_uuid, assigned_department_uuid, assigned_person_uuid) <= 1)),
    CONSTRAINT phoenix_kit_project_assignments_task_xor_child CHECK (((task_uuid IS NOT NULL) <> (child_project_uuid IS NOT NULL)))
);


--
-- Name: phoenix_kit_project_dependencies; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_project_dependencies (
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    assignment_uuid uuid NOT NULL,
    depends_on_uuid uuid NOT NULL,
    inserted_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: phoenix_kit_project_statuses; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_project_statuses (
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    project_uuid uuid NOT NULL,
    label character varying(255) NOT NULL,
    slug character varying(255) NOT NULL,
    "position" integer DEFAULT 0 NOT NULL,
    data jsonb DEFAULT '{}'::jsonb NOT NULL,
    translations jsonb DEFAULT '{}'::jsonb NOT NULL,
    source_entity_data_uuid uuid,
    inserted_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: phoenix_kit_project_task_dependencies; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_project_task_dependencies (
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    task_uuid uuid NOT NULL,
    depends_on_task_uuid uuid NOT NULL,
    inserted_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: phoenix_kit_project_tasks; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_project_tasks (
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    title character varying(255) NOT NULL,
    description text,
    estimated_duration integer,
    estimated_duration_unit character varying(20) DEFAULT 'hours'::character varying,
    default_assigned_team_uuid uuid,
    default_assigned_department_uuid uuid,
    default_assigned_person_uuid uuid,
    inserted_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    translations jsonb DEFAULT '{}'::jsonb NOT NULL,
    "position" integer DEFAULT 0 NOT NULL,
    CONSTRAINT phoenix_kit_project_tasks_single_default_assignee CHECK ((num_nonnulls(default_assigned_team_uuid, default_assigned_department_uuid, default_assigned_person_uuid) <= 1))
);


--
-- Name: phoenix_kit_projects; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_projects (
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    name character varying(255) NOT NULL,
    description text,
    status character varying(20) DEFAULT 'active'::character varying NOT NULL,
    is_template boolean DEFAULT false NOT NULL,
    counts_weekends boolean DEFAULT false NOT NULL,
    start_mode character varying(20) DEFAULT 'immediate'::character varying NOT NULL,
    scheduled_start_date timestamp(0) without time zone,
    started_at timestamp with time zone,
    completed_at timestamp with time zone,
    inserted_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    archived_at timestamp(0) without time zone,
    translations jsonb DEFAULT '{}'::jsonb NOT NULL,
    "position" integer DEFAULT 0 NOT NULL,
    status_entity_uuid uuid,
    current_status_slug character varying(255),
    settings jsonb DEFAULT '{}'::jsonb NOT NULL,
    external_id character varying(255),
    assigned_team_uuid uuid,
    assigned_department_uuid uuid,
    assigned_person_uuid uuid,
    CONSTRAINT phoenix_kit_projects_single_assignee CHECK ((num_nonnulls(assigned_team_uuid, assigned_department_uuid, assigned_person_uuid) <= 1))
);


--
-- Name: phoenix_kit_publishing_categories; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_publishing_categories (
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    group_uuid uuid NOT NULL,
    parent_uuid uuid,
    name character varying(255) NOT NULL,
    slug character varying(255) NOT NULL,
    name_i18n jsonb DEFAULT '{}'::jsonb NOT NULL,
    description character varying(1024),
    "position" integer DEFAULT 0 NOT NULL,
    inserted_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: phoenix_kit_publishing_contents; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_publishing_contents (
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    version_uuid uuid NOT NULL,
    language character varying(10) NOT NULL,
    title character varying(500) NOT NULL,
    content text,
    status character varying(20) DEFAULT 'draft'::character varying NOT NULL,
    url_slug character varying(500),
    data jsonb DEFAULT '{}'::jsonb NOT NULL,
    inserted_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: phoenix_kit_publishing_groups; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_publishing_groups (
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    name character varying(255) NOT NULL,
    slug character varying(255) NOT NULL,
    mode character varying(20) DEFAULT 'timestamp'::character varying NOT NULL,
    "position" integer DEFAULT 0 NOT NULL,
    data jsonb DEFAULT '{}'::jsonb NOT NULL,
    inserted_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    status character varying(20) DEFAULT 'active'::character varying NOT NULL,
    title_i18n jsonb DEFAULT '{}'::jsonb NOT NULL,
    description_i18n jsonb DEFAULT '{}'::jsonb NOT NULL
);


--
-- Name: phoenix_kit_publishing_post_categories; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_publishing_post_categories (
    post_uuid uuid NOT NULL,
    category_uuid uuid NOT NULL,
    inserted_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: phoenix_kit_publishing_post_views; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_publishing_post_views (
    post_uuid uuid NOT NULL,
    view_date date NOT NULL,
    count integer DEFAULT 0 NOT NULL
);


--
-- Name: phoenix_kit_publishing_posts; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_publishing_posts (
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    group_uuid uuid NOT NULL,
    slug character varying(500),
    mode character varying(20) DEFAULT 'timestamp'::character varying NOT NULL,
    post_date date,
    post_time time without time zone,
    created_by_uuid uuid,
    updated_by_uuid uuid,
    inserted_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    active_version_uuid uuid,
    trashed_at timestamp with time zone
);


--
-- Name: phoenix_kit_publishing_versions; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_publishing_versions (
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    post_uuid uuid NOT NULL,
    version_number integer NOT NULL,
    status character varying(20) DEFAULT 'draft'::character varying NOT NULL,
    created_by_uuid uuid,
    data jsonb DEFAULT '{}'::jsonb NOT NULL,
    inserted_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    published_at timestamp with time zone
);


--
-- Name: phoenix_kit_referral_code_usage; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_referral_code_usage (
    date_used timestamp with time zone DEFAULT now() NOT NULL,
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    used_by_uuid uuid NOT NULL,
    code_uuid uuid NOT NULL
);


--
-- Name: phoenix_kit_referral_codes; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_referral_codes (
    code character varying(255) NOT NULL,
    description character varying(255) NOT NULL,
    status boolean DEFAULT true NOT NULL,
    number_of_uses integer DEFAULT 0 NOT NULL,
    max_uses integer NOT NULL,
    date_created timestamp with time zone DEFAULT now() NOT NULL,
    expiration_date timestamp with time zone,
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    created_by_uuid uuid NOT NULL,
    beneficiary_uuid uuid
);


--
-- Name: phoenix_kit_role_permissions; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_role_permissions (
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    module_key character varying(120) NOT NULL,
    inserted_at timestamp with time zone DEFAULT now() NOT NULL,
    granted_by_uuid uuid,
    role_uuid uuid NOT NULL
);


--
-- Name: phoenix_kit_scheduled_jobs; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_scheduled_jobs (
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    job_type character varying(255) NOT NULL,
    handler_module character varying(255) NOT NULL,
    resource_type character varying(255) NOT NULL,
    resource_uuid uuid NOT NULL,
    scheduled_at timestamp with time zone NOT NULL,
    executed_at timestamp with time zone,
    status character varying(255) DEFAULT 'pending'::character varying NOT NULL,
    attempts integer DEFAULT 0 NOT NULL,
    max_attempts integer DEFAULT 3 NOT NULL,
    last_error text,
    args jsonb DEFAULT '{}'::jsonb NOT NULL,
    priority integer DEFAULT 0 NOT NULL,
    inserted_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL,
    created_by_uuid uuid
);


--
-- Name: phoenix_kit_settings; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_settings (
    key character varying(255) NOT NULL,
    value text,
    date_added timestamp with time zone DEFAULT now() NOT NULL,
    date_updated timestamp with time zone DEFAULT now() NOT NULL,
    module character varying(255),
    value_json jsonb,
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL
);


--
-- Name: phoenix_kit_shop_cart_items; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_shop_cart_items (
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    product_title character varying(255) NOT NULL,
    product_slug character varying(255),
    product_sku character varying(100),
    product_image character varying(500),
    unit_price numeric(12,2) NOT NULL,
    compare_at_price numeric(12,2),
    currency character varying(3) DEFAULT 'USD'::character varying,
    quantity integer DEFAULT 1 NOT NULL,
    line_total numeric(12,2) NOT NULL,
    weight_grams integer DEFAULT 0,
    taxable boolean DEFAULT true,
    variant_options jsonb DEFAULT '{}'::jsonb,
    metadata jsonb DEFAULT '{}'::jsonb,
    inserted_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    selected_specs jsonb DEFAULT '{}'::jsonb,
    cart_uuid uuid NOT NULL,
    product_uuid uuid,
    variant_uuid uuid,
    CONSTRAINT phoenix_kit_shop_cart_items_quantity_positive CHECK ((quantity > 0))
);


--
-- Name: phoenix_kit_shop_carts; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_shop_carts (
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    session_id character varying(64),
    status character varying(20) DEFAULT 'active'::character varying,
    shipping_country character varying(2),
    subtotal numeric(12,2) DEFAULT 0,
    shipping_amount numeric(12,2) DEFAULT 0,
    tax_amount numeric(12,2) DEFAULT 0,
    discount_amount numeric(12,2) DEFAULT 0,
    total numeric(12,2) DEFAULT 0,
    currency character varying(3) DEFAULT 'USD'::character varying,
    discount_code character varying(100),
    total_weight_grams integer DEFAULT 0,
    items_count integer DEFAULT 0,
    metadata jsonb DEFAULT '{}'::jsonb,
    expires_at timestamp with time zone,
    converted_at timestamp with time zone,
    inserted_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    user_uuid uuid,
    shipping_method_uuid uuid,
    merged_into_cart_uuid uuid,
    payment_option_uuid uuid
);


--
-- Name: phoenix_kit_shop_categories; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_shop_categories (
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    "position" integer DEFAULT 0,
    metadata jsonb DEFAULT '{}'::jsonb,
    inserted_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    option_schema jsonb DEFAULT '[]'::jsonb,
    image_uuid uuid,
    status character varying(20) DEFAULT 'active'::character varying,
    name jsonb DEFAULT '{}'::jsonb,
    slug jsonb DEFAULT '{}'::jsonb,
    description jsonb DEFAULT '{}'::jsonb,
    parent_uuid uuid,
    featured_product_uuid uuid
);


--
-- Name: phoenix_kit_shop_config; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_shop_config (
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    key character varying(255) NOT NULL,
    value jsonb DEFAULT '{}'::jsonb,
    inserted_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: phoenix_kit_shop_import_configs; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_shop_import_configs (
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    name character varying(255) NOT NULL,
    include_keywords text[] DEFAULT '{}'::text[],
    exclude_keywords text[] DEFAULT '{}'::text[],
    exclude_phrases text[] DEFAULT '{}'::text[],
    skip_filter boolean DEFAULT false,
    category_rules jsonb DEFAULT '[]'::jsonb,
    default_category_slug character varying(255),
    required_columns text[] DEFAULT ARRAY['Handle'::text, 'Title'::text, 'Variant Price'::text],
    is_default boolean DEFAULT false,
    active boolean DEFAULT true,
    inserted_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    option_mappings jsonb DEFAULT '[]'::jsonb,
    download_images boolean DEFAULT false
);


--
-- Name: phoenix_kit_shop_import_logs; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_shop_import_logs (
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    filename character varying(255) NOT NULL,
    file_path character varying(1024),
    status character varying(50) DEFAULT 'pending'::character varying,
    total_rows integer DEFAULT 0,
    processed_rows integer DEFAULT 0,
    imported_count integer DEFAULT 0,
    updated_count integer DEFAULT 0,
    skipped_count integer DEFAULT 0,
    error_count integer DEFAULT 0,
    options jsonb DEFAULT '{}'::jsonb,
    error_details jsonb DEFAULT '[]'::jsonb,
    started_at timestamp with time zone,
    completed_at timestamp with time zone,
    inserted_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    user_uuid uuid,
    product_uuids uuid[] DEFAULT '{}'::uuid[]
);


--
-- Name: phoenix_kit_shop_products; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_shop_products (
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    status character varying(20) DEFAULT 'draft'::character varying,
    product_type character varying(20) DEFAULT 'physical'::character varying,
    vendor character varying(255),
    tags jsonb DEFAULT '[]'::jsonb,
    price numeric(12,2) NOT NULL,
    compare_at_price numeric(12,2),
    cost_per_item numeric(12,2),
    currency character varying(3) DEFAULT 'USD'::character varying,
    taxable boolean DEFAULT true,
    weight_grams integer DEFAULT 0,
    requires_shipping boolean DEFAULT true,
    has_variants boolean DEFAULT false,
    option_names jsonb DEFAULT '[]'::jsonb,
    images jsonb DEFAULT '[]'::jsonb,
    featured_image text,
    file_uuid uuid,
    download_limit integer,
    download_expiry_days integer,
    metadata jsonb DEFAULT '{}'::jsonb,
    inserted_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    made_to_order boolean DEFAULT false,
    featured_image_uuid uuid,
    image_uuids uuid[] DEFAULT '{}'::uuid[],
    title jsonb DEFAULT '{}'::jsonb,
    slug jsonb DEFAULT '{}'::jsonb,
    description jsonb DEFAULT '{}'::jsonb,
    body_html jsonb DEFAULT '{}'::jsonb,
    seo_title jsonb DEFAULT '{}'::jsonb,
    seo_description jsonb DEFAULT '{}'::jsonb,
    created_by_uuid uuid,
    category_uuid uuid
);


--
-- Name: phoenix_kit_shop_shipping_methods; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_shop_shipping_methods (
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    name character varying(255) NOT NULL,
    slug character varying(100) NOT NULL,
    description text,
    price numeric(12,2) DEFAULT 0 NOT NULL,
    currency character varying(3) DEFAULT 'USD'::character varying,
    free_above_amount numeric(12,2),
    min_weight_grams integer DEFAULT 0,
    max_weight_grams integer,
    min_order_amount numeric(12,2),
    max_order_amount numeric(12,2),
    countries jsonb DEFAULT '[]'::jsonb,
    excluded_countries jsonb DEFAULT '[]'::jsonb,
    active boolean DEFAULT true,
    "position" integer DEFAULT 0,
    estimated_days_min integer,
    estimated_days_max integer,
    tracking_supported boolean DEFAULT false,
    metadata jsonb DEFAULT '{}'::jsonb,
    inserted_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: phoenix_kit_staff_departments; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_staff_departments (
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    name character varying(255) NOT NULL,
    description text,
    inserted_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    translations jsonb DEFAULT '{}'::jsonb NOT NULL
);


--
-- Name: phoenix_kit_staff_employments; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_staff_employments (
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    staff_person_uuid uuid NOT NULL,
    employment_type character varying(50),
    job_title character varying(255),
    translations jsonb DEFAULT '{}'::jsonb NOT NULL,
    primary_department_uuid uuid,
    primary_team_uuid uuid,
    employment_start_date date,
    employment_end_date date,
    work_location character varying(255),
    notes text,
    inserted_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: phoenix_kit_staff_people; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_staff_people (
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    user_uuid uuid NOT NULL,
    primary_department_uuid uuid,
    status character varying(20) DEFAULT 'active'::character varying NOT NULL,
    job_title character varying(255),
    employment_type character varying(20),
    employment_start_date date,
    employment_end_date date,
    work_location character varying(255),
    work_phone character varying(50),
    personal_phone character varying(50),
    bio text,
    notes text,
    date_of_birth date,
    personal_email character varying(255),
    emergency_contact_name character varying(255),
    emergency_contact_phone character varying(50),
    emergency_contact_relationship character varying(100),
    inserted_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    translations jsonb DEFAULT '{}'::jsonb NOT NULL,
    name character varying,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL
);


--
-- Name: phoenix_kit_staff_person_skills; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_staff_person_skills (
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    staff_person_uuid uuid NOT NULL,
    skill_uuid uuid NOT NULL,
    proficiency_levels jsonb DEFAULT '[]'::jsonb NOT NULL,
    inserted_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: phoenix_kit_staff_skills; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_staff_skills (
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    name character varying(255) NOT NULL,
    description text,
    translations jsonb DEFAULT '{}'::jsonb NOT NULL,
    levels jsonb DEFAULT '[]'::jsonb NOT NULL,
    allow_multiple_levels boolean DEFAULT false NOT NULL,
    inserted_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: phoenix_kit_staff_team_memberships; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_staff_team_memberships (
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    team_uuid uuid NOT NULL,
    staff_person_uuid uuid NOT NULL,
    inserted_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: phoenix_kit_staff_teams; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_staff_teams (
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    department_uuid uuid NOT NULL,
    name character varying(255) NOT NULL,
    description text,
    inserted_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    translations jsonb DEFAULT '{}'::jsonb NOT NULL
);


--
-- Name: phoenix_kit_storage_dimensions; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_storage_dimensions (
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    name character varying(255) NOT NULL,
    width integer,
    height integer,
    quality integer DEFAULT 85 NOT NULL,
    format character varying(255),
    applies_to character varying(255) NOT NULL,
    enabled boolean DEFAULT true NOT NULL,
    "order" integer DEFAULT 0 NOT NULL,
    inserted_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL,
    maintain_aspect_ratio boolean DEFAULT true NOT NULL,
    alternative_formats text[] DEFAULT '{}'::text[] NOT NULL
);


--
-- Name: phoenix_kit_subscription_types; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_subscription_types (
    name character varying(255) NOT NULL,
    slug character varying(255) NOT NULL,
    description text,
    price numeric(15,2) NOT NULL,
    currency character varying(3) DEFAULT 'EUR'::character varying NOT NULL,
    "interval" character varying(10) DEFAULT 'month'::character varying NOT NULL,
    interval_count integer DEFAULT 1 NOT NULL,
    trial_days integer DEFAULT 0 NOT NULL,
    features jsonb[] DEFAULT ARRAY[]::jsonb[] NOT NULL,
    active boolean DEFAULT true NOT NULL,
    sort_order integer DEFAULT 0 NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    inserted_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL,
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL
);


--
-- Name: phoenix_kit_subscriptions; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_subscriptions (
    plan_name character varying(255) NOT NULL,
    provider character varying(20),
    provider_subscription_id character varying(255),
    status character varying(20) DEFAULT 'active'::character varying NOT NULL,
    current_period_start timestamp with time zone NOT NULL,
    current_period_end timestamp with time zone NOT NULL,
    cancel_at_period_end boolean DEFAULT false NOT NULL,
    cancelled_at timestamp with time zone,
    trial_start timestamp with time zone,
    trial_end timestamp with time zone,
    grace_period_end timestamp with time zone,
    renewal_attempts integer DEFAULT 0 NOT NULL,
    last_renewal_attempt_at timestamp with time zone,
    last_renewal_error character varying(255),
    price numeric(15,2) NOT NULL,
    currency character varying(3) DEFAULT 'EUR'::character varying NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    inserted_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL,
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    user_uuid uuid NOT NULL,
    billing_profile_uuid uuid,
    payment_method_uuid uuid,
    subscription_type_uuid uuid
);


--
-- Name: phoenix_kit_sync_connections; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_sync_connections (
    name character varying(255) NOT NULL,
    direction character varying(10) NOT NULL,
    site_url character varying(255) NOT NULL,
    auth_token character varying(255),
    auth_token_hash character varying(255),
    status character varying(20) DEFAULT 'pending'::character varying NOT NULL,
    approval_mode character varying(20) DEFAULT 'require_approval'::character varying,
    allowed_tables character varying(255)[] DEFAULT ARRAY[]::character varying[] NOT NULL,
    excluded_tables character varying(255)[] DEFAULT ARRAY[]::character varying[] NOT NULL,
    auto_approve_tables character varying(255)[] DEFAULT ARRAY[]::character varying[] NOT NULL,
    expires_at timestamp with time zone,
    max_downloads integer,
    downloads_used integer DEFAULT 0 NOT NULL,
    max_records_total bigint,
    records_downloaded bigint DEFAULT 0 NOT NULL,
    max_records_per_request integer DEFAULT 10000 NOT NULL,
    rate_limit_requests_per_minute integer DEFAULT 60 NOT NULL,
    download_password_hash character varying(255),
    ip_whitelist character varying(255)[] DEFAULT ARRAY[]::character varying[] NOT NULL,
    allowed_hours_start integer,
    allowed_hours_end integer,
    default_conflict_strategy character varying(20) DEFAULT 'skip'::character varying,
    auto_sync_enabled boolean DEFAULT false NOT NULL,
    auto_sync_tables character varying(255)[] DEFAULT ARRAY[]::character varying[] NOT NULL,
    auto_sync_interval_minutes integer DEFAULT 60 NOT NULL,
    approved_at timestamp with time zone,
    suspended_at timestamp with time zone,
    suspended_reason character varying(255),
    revoked_at timestamp with time zone,
    revoked_reason character varying(255),
    last_connected_at timestamp with time zone,
    last_transfer_at timestamp with time zone,
    total_transfers integer DEFAULT 0 NOT NULL,
    total_records_transferred bigint DEFAULT 0 NOT NULL,
    total_bytes_transferred bigint DEFAULT 0 NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    inserted_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL,
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    approved_by_uuid uuid,
    suspended_by_uuid uuid,
    revoked_by_uuid uuid,
    created_by_uuid uuid
);


--
-- Name: phoenix_kit_sync_transfers; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_sync_transfers (
    direction character varying(10) NOT NULL,
    session_code character varying(20),
    remote_site_url character varying(255),
    table_name character varying(255) NOT NULL,
    records_requested integer DEFAULT 0 NOT NULL,
    records_transferred integer DEFAULT 0 NOT NULL,
    records_created integer DEFAULT 0 NOT NULL,
    records_updated integer DEFAULT 0 NOT NULL,
    records_skipped integer DEFAULT 0 NOT NULL,
    records_failed integer DEFAULT 0 NOT NULL,
    bytes_transferred bigint DEFAULT 0 NOT NULL,
    conflict_strategy character varying(20),
    status character varying(20) DEFAULT 'pending'::character varying NOT NULL,
    requires_approval boolean DEFAULT false NOT NULL,
    approved_at timestamp with time zone,
    denied_at timestamp with time zone,
    denial_reason character varying(255),
    approval_expires_at timestamp with time zone,
    requester_ip character varying(255),
    requester_user_agent character varying(255),
    error_message text,
    started_at timestamp with time zone,
    completed_at timestamp with time zone,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    inserted_at timestamp with time zone NOT NULL,
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    approved_by_uuid uuid,
    denied_by_uuid uuid,
    initiated_by_uuid uuid,
    connection_uuid uuid
);


--
-- Name: phoenix_kit_ticket_attachments; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_ticket_attachments (
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    ticket_uuid uuid,
    comment_uuid uuid,
    file_uuid uuid NOT NULL,
    "position" integer NOT NULL,
    caption text,
    inserted_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL,
    CONSTRAINT phoenix_kit_ticket_attachments_parent_check CHECK ((((ticket_uuid IS NOT NULL) AND (comment_uuid IS NULL)) OR ((ticket_uuid IS NULL) AND (comment_uuid IS NOT NULL))))
);


--
-- Name: phoenix_kit_ticket_comments; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_ticket_comments (
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    ticket_uuid uuid NOT NULL,
    parent_uuid uuid,
    content text NOT NULL,
    is_internal boolean DEFAULT false NOT NULL,
    depth integer DEFAULT 0 NOT NULL,
    inserted_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL,
    user_uuid uuid NOT NULL
);


--
-- Name: phoenix_kit_ticket_status_history; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_ticket_status_history (
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    ticket_uuid uuid NOT NULL,
    from_status character varying(255),
    to_status character varying(255) NOT NULL,
    reason text,
    inserted_at timestamp with time zone NOT NULL,
    changed_by_uuid uuid NOT NULL
);


--
-- Name: phoenix_kit_tickets; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_tickets (
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    title character varying(255) NOT NULL,
    description text NOT NULL,
    status character varying(255) DEFAULT 'open'::character varying NOT NULL,
    slug character varying(255) NOT NULL,
    comment_count integer DEFAULT 0 NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb,
    resolved_at timestamp with time zone,
    closed_at timestamp with time zone,
    inserted_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL,
    user_uuid uuid,
    assigned_to_uuid uuid
);


--
-- Name: phoenix_kit_transactions; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_transactions (
    transaction_number character varying(30) NOT NULL,
    amount numeric(15,2) NOT NULL,
    currency character varying(3) DEFAULT 'EUR'::character varying NOT NULL,
    payment_method character varying(20) DEFAULT 'bank'::character varying NOT NULL,
    description character varying(255),
    metadata jsonb DEFAULT '{}'::jsonb,
    provider_transaction_id character varying(255),
    provider_data jsonb DEFAULT '{}'::jsonb,
    inserted_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL,
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    user_uuid uuid NOT NULL,
    invoice_uuid uuid
);


--
-- Name: phoenix_kit_user_blocks; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_user_blocks (
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    reason character varying(255),
    inserted_at timestamp with time zone NOT NULL,
    blocker_uuid uuid NOT NULL,
    blocked_uuid uuid NOT NULL
);


--
-- Name: phoenix_kit_user_blocks_history; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_user_blocks_history (
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    action character varying(255) NOT NULL,
    reason character varying(255),
    inserted_at timestamp with time zone NOT NULL,
    blocker_uuid uuid NOT NULL,
    blocked_uuid uuid NOT NULL
);


--
-- Name: phoenix_kit_user_connections; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_user_connections (
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    status character varying(255) DEFAULT 'pending'::character varying NOT NULL,
    requested_at timestamp with time zone NOT NULL,
    responded_at timestamp with time zone,
    inserted_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL,
    requester_uuid uuid NOT NULL,
    recipient_uuid uuid NOT NULL
);


--
-- Name: phoenix_kit_user_connections_history; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_user_connections_history (
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    action character varying(255) NOT NULL,
    inserted_at timestamp with time zone NOT NULL,
    user_a_uuid uuid NOT NULL,
    user_b_uuid uuid NOT NULL,
    actor_uuid uuid NOT NULL
);


--
-- Name: phoenix_kit_user_follows; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_user_follows (
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    inserted_at timestamp with time zone NOT NULL,
    follower_uuid uuid NOT NULL,
    followed_uuid uuid NOT NULL
);


--
-- Name: phoenix_kit_user_follows_history; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_user_follows_history (
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    action character varying(255) NOT NULL,
    inserted_at timestamp with time zone NOT NULL,
    follower_uuid uuid NOT NULL,
    followed_uuid uuid NOT NULL
);


--
-- Name: phoenix_kit_user_known_devices; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_user_known_devices (
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    user_uuid uuid NOT NULL,
    ip_address character varying(45) NOT NULL,
    user_agent_hash character varying(64) NOT NULL,
    browser character varying(100),
    os character varying(100),
    first_seen_at timestamp(0) without time zone DEFAULT now() NOT NULL,
    last_seen_at timestamp(0) without time zone DEFAULT now() NOT NULL,
    location character varying(255)
);


--
-- Name: phoenix_kit_user_oauth_providers; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_user_oauth_providers (
    provider character varying(255) NOT NULL,
    provider_uid character varying(255) NOT NULL,
    provider_email character varying(255),
    access_token text,
    refresh_token text,
    token_expires_at timestamp with time zone,
    raw_data jsonb DEFAULT '{}'::jsonb,
    inserted_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL,
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    user_uuid uuid NOT NULL
);


--
-- Name: phoenix_kit_user_role_assignments; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_user_role_assignments (
    assigned_at timestamp with time zone DEFAULT now() NOT NULL,
    inserted_at timestamp with time zone NOT NULL,
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    user_uuid uuid NOT NULL,
    assigned_by_uuid uuid,
    role_uuid uuid NOT NULL
);


--
-- Name: phoenix_kit_user_roles; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_user_roles (
    name character varying(50) NOT NULL,
    description text,
    is_system_role boolean DEFAULT false NOT NULL,
    inserted_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL,
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL
);


--
-- Name: phoenix_kit_users; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_users (
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
    user_timezone character varying(3),
    custom_fields jsonb DEFAULT '{}'::jsonb,
    preferred_locale character varying(10),
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    account_type character varying(20) DEFAULT 'person'::character varying NOT NULL,
    organization_name character varying(255),
    organization_uuid uuid,
    CONSTRAINT phoenix_kit_users_account_type_check CHECK (((account_type)::text = ANY ((ARRAY['person'::character varying, 'organization'::character varying])::text[])))
);


--
-- Name: phoenix_kit_users_tokens; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_users_tokens (
    token bytea NOT NULL,
    context character varying(255) NOT NULL,
    sent_to character varying(255),
    inserted_at timestamp with time zone NOT NULL,
    ip_address character varying(255),
    user_agent_hash character varying(255),
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    user_uuid uuid,
    browser character varying(100),
    os character varying(100),
    CONSTRAINT user_uuid_required_for_non_registration_tokens CHECK (
CASE
    WHEN ((context)::text = 'magic_link_registration'::text) THEN true
    ELSE (user_uuid IS NOT NULL)
END)
);


--
-- Name: phoenix_kit_warehouse_goods_issues_number_seq; Type: SEQUENCE; Schema: pk_sqv_s1a; Owner: -
--

CREATE SEQUENCE pk_sqv_s1a.phoenix_kit_warehouse_goods_issues_number_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: phoenix_kit_warehouse_goods_issues; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_warehouse_goods_issues (
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    number bigint DEFAULT nextval('pk_sqv_s1a.phoenix_kit_warehouse_goods_issues_number_seq'::regclass) NOT NULL,
    status character varying(20) DEFAULT 'draft'::character varying NOT NULL,
    internal_order_uuid uuid,
    location_uuid uuid NOT NULL,
    note text,
    storage_folder_uuid uuid,
    lines jsonb DEFAULT '[]'::jsonb NOT NULL,
    source_refs jsonb DEFAULT '[]'::jsonb NOT NULL,
    created_by_uuid uuid,
    performed_by_uuid uuid,
    posted_at timestamp with time zone,
    deleted_at timestamp with time zone,
    deleted_by_uuid uuid,
    inserted_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: phoenix_kit_warehouse_goods_receipts_number_seq; Type: SEQUENCE; Schema: pk_sqv_s1a; Owner: -
--

CREATE SEQUENCE pk_sqv_s1a.phoenix_kit_warehouse_goods_receipts_number_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: phoenix_kit_warehouse_goods_receipts; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_warehouse_goods_receipts (
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    number bigint DEFAULT nextval('pk_sqv_s1a.phoenix_kit_warehouse_goods_receipts_number_seq'::regclass) NOT NULL,
    status character varying(20) DEFAULT 'draft'::character varying NOT NULL,
    supplier_order_uuid uuid,
    supplier_uuid uuid,
    location_uuid uuid NOT NULL,
    note text,
    storage_folder_uuid uuid,
    lines jsonb DEFAULT '[]'::jsonb NOT NULL,
    source_refs jsonb DEFAULT '[]'::jsonb NOT NULL,
    created_by_uuid uuid,
    performed_by_uuid uuid,
    posted_at timestamp with time zone,
    deleted_at timestamp with time zone,
    deleted_by_uuid uuid,
    inserted_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: phoenix_kit_warehouse_internal_orders_number_seq; Type: SEQUENCE; Schema: pk_sqv_s1a; Owner: -
--

CREATE SEQUENCE pk_sqv_s1a.phoenix_kit_warehouse_internal_orders_number_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: phoenix_kit_warehouse_internal_orders; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_warehouse_internal_orders (
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    number bigint DEFAULT nextval('pk_sqv_s1a.phoenix_kit_warehouse_internal_orders_number_seq'::regclass) NOT NULL,
    status character varying(20) DEFAULT 'draft'::character varying NOT NULL,
    location_uuid uuid NOT NULL,
    note text,
    lines jsonb DEFAULT '[]'::jsonb NOT NULL,
    source_refs jsonb DEFAULT '[]'::jsonb NOT NULL,
    created_by_uuid uuid,
    performed_by_uuid uuid,
    posted_at timestamp with time zone,
    deleted_at timestamp with time zone,
    deleted_by_uuid uuid,
    inserted_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: phoenix_kit_warehouse_inventory_documents_number_seq; Type: SEQUENCE; Schema: pk_sqv_s1a; Owner: -
--

CREATE SEQUENCE pk_sqv_s1a.phoenix_kit_warehouse_inventory_documents_number_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: phoenix_kit_warehouse_inventory_documents; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_warehouse_inventory_documents (
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    number bigint DEFAULT nextval('pk_sqv_s1a.phoenix_kit_warehouse_inventory_documents_number_seq'::regclass) NOT NULL,
    status character varying(20) DEFAULT 'draft'::character varying NOT NULL,
    track_value boolean DEFAULT false NOT NULL,
    location_uuid uuid NOT NULL,
    storage_folder_uuid uuid,
    note text,
    lines jsonb DEFAULT '[]'::jsonb NOT NULL,
    created_by_uuid uuid,
    performed_by_uuid uuid,
    posted_at timestamp with time zone,
    deleted_at timestamp with time zone,
    deleted_by_uuid uuid,
    inserted_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: phoenix_kit_warehouse_min_stock; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_warehouse_min_stock (
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    item_uuid uuid NOT NULL,
    min_quantity numeric DEFAULT 0 NOT NULL,
    inserted_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT phoenix_kit_warehouse_min_stock_min_quantity_non_negative CHECK ((min_quantity >= (0)::numeric))
);


--
-- Name: phoenix_kit_warehouse_stock; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_warehouse_stock (
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    item_uuid uuid NOT NULL,
    location_uuid uuid NOT NULL,
    quantity numeric DEFAULT 0 NOT NULL,
    unit_value numeric,
    inserted_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT phoenix_kit_warehouse_stock_quantity_non_negative CHECK ((quantity >= (0)::numeric))
);


--
-- Name: phoenix_kit_warehouse_supplier_orders_number_seq; Type: SEQUENCE; Schema: pk_sqv_s1a; Owner: -
--

CREATE SEQUENCE pk_sqv_s1a.phoenix_kit_warehouse_supplier_orders_number_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: phoenix_kit_warehouse_supplier_orders; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_warehouse_supplier_orders (
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    number bigint DEFAULT nextval('pk_sqv_s1a.phoenix_kit_warehouse_supplier_orders_number_seq'::regclass) NOT NULL,
    status character varying(20) DEFAULT 'draft'::character varying NOT NULL,
    supplier_uuid uuid,
    internal_order_uuid uuid,
    location_uuid uuid NOT NULL,
    note text,
    storage_folder_uuid uuid,
    lines jsonb DEFAULT '[]'::jsonb NOT NULL,
    source_refs jsonb DEFAULT '[]'::jsonb NOT NULL,
    created_by_uuid uuid,
    performed_by_uuid uuid,
    posted_at timestamp with time zone,
    deleted_at timestamp with time zone,
    deleted_by_uuid uuid,
    inserted_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: phoenix_kit_warehouse_transfers_number_seq; Type: SEQUENCE; Schema: pk_sqv_s1a; Owner: -
--

CREATE SEQUENCE pk_sqv_s1a.phoenix_kit_warehouse_transfers_number_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: phoenix_kit_warehouse_transfers; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_warehouse_transfers (
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL,
    number bigint DEFAULT nextval('pk_sqv_s1a.phoenix_kit_warehouse_transfers_number_seq'::regclass) NOT NULL,
    status character varying(20) DEFAULT 'draft'::character varying NOT NULL,
    source_location_uuid uuid,
    destination_location_uuid uuid,
    note text,
    storage_folder_uuid uuid,
    lines jsonb DEFAULT '[]'::jsonb NOT NULL,
    source_refs jsonb DEFAULT '[]'::jsonb NOT NULL,
    created_by_uuid uuid,
    performed_by_uuid uuid,
    shipped_at timestamp with time zone,
    received_at timestamp with time zone,
    cancelled_at timestamp with time zone,
    deleted_at timestamp with time zone,
    deleted_by_uuid uuid,
    inserted_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: phoenix_kit_webhook_events; Type: TABLE; Schema: pk_sqv_s1a; Owner: -
--

CREATE TABLE pk_sqv_s1a.phoenix_kit_webhook_events (
    provider character varying(20) NOT NULL,
    event_id character varying(255) NOT NULL,
    event_type character varying(255) NOT NULL,
    payload jsonb DEFAULT '{}'::jsonb NOT NULL,
    processed boolean DEFAULT false NOT NULL,
    processed_at timestamp with time zone,
    error_message text,
    retry_count integer DEFAULT 0 NOT NULL,
    inserted_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL,
    uuid uuid DEFAULT pk_sqv_s1a.uuid_generate_v7() NOT NULL
);


--
-- Name: oban_jobs id; Type: DEFAULT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.oban_jobs ALTER COLUMN id SET DEFAULT nextval('pk_sqv_s1a.oban_jobs_id_seq'::regclass);


--
-- Name: oban_jobs non_negative_priority; Type: CHECK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE pk_sqv_s1a.oban_jobs
    ADD CONSTRAINT non_negative_priority CHECK ((priority >= 0)) NOT VALID;


--
-- Name: oban_jobs oban_jobs_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.oban_jobs
    ADD CONSTRAINT oban_jobs_pkey PRIMARY KEY (id);


--
-- Name: oban_peers oban_peers_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.oban_peers
    ADD CONSTRAINT oban_peers_pkey PRIMARY KEY (name);


--
-- Name: phoenix_kit_activities phoenix_kit_activities_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_activities
    ADD CONSTRAINT phoenix_kit_activities_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_admin_notes phoenix_kit_admin_notes_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_admin_notes
    ADD CONSTRAINT phoenix_kit_admin_notes_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_ai_accounts phoenix_kit_ai_accounts_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_ai_accounts
    ADD CONSTRAINT phoenix_kit_ai_accounts_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_ai_endpoints phoenix_kit_ai_endpoints_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_ai_endpoints
    ADD CONSTRAINT phoenix_kit_ai_endpoints_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_ai_prompts phoenix_kit_ai_prompts_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_ai_prompts
    ADD CONSTRAINT phoenix_kit_ai_prompts_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_ai_requests phoenix_kit_ai_requests_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_ai_requests
    ADD CONSTRAINT phoenix_kit_ai_requests_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_annotations phoenix_kit_annotations_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_annotations
    ADD CONSTRAINT phoenix_kit_annotations_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_audit_logs phoenix_kit_audit_logs_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_audit_logs
    ADD CONSTRAINT phoenix_kit_audit_logs_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_billing_profiles phoenix_kit_billing_profiles_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_billing_profiles
    ADD CONSTRAINT phoenix_kit_billing_profiles_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_buckets phoenix_kit_buckets_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_buckets
    ADD CONSTRAINT phoenix_kit_buckets_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_calendar_event_participants phoenix_kit_calendar_event_participants_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_calendar_event_participants
    ADD CONSTRAINT phoenix_kit_calendar_event_participants_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_calendar_events phoenix_kit_calendar_events_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_calendar_events
    ADD CONSTRAINT phoenix_kit_calendar_events_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_cat_catalogues phoenix_kit_cat_catalogues_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_cat_catalogues
    ADD CONSTRAINT phoenix_kit_cat_catalogues_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_cat_categories phoenix_kit_cat_categories_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_cat_categories
    ADD CONSTRAINT phoenix_kit_cat_categories_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_cat_folders phoenix_kit_cat_folders_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_cat_folders
    ADD CONSTRAINT phoenix_kit_cat_folders_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_cat_item_catalogue_rules phoenix_kit_cat_item_catalogue_rules_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_cat_item_catalogue_rules
    ADD CONSTRAINT phoenix_kit_cat_item_catalogue_rules_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_cat_item_supplier_info phoenix_kit_cat_item_supplier_info_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_cat_item_supplier_info
    ADD CONSTRAINT phoenix_kit_cat_item_supplier_info_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_cat_items phoenix_kit_cat_items_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_cat_items
    ADD CONSTRAINT phoenix_kit_cat_items_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_cat_manufacturer_suppliers phoenix_kit_cat_manufacturer_suppliers_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_cat_manufacturer_suppliers
    ADD CONSTRAINT phoenix_kit_cat_manufacturer_suppliers_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_cat_manufacturers phoenix_kit_cat_manufacturers_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_cat_manufacturers
    ADD CONSTRAINT phoenix_kit_cat_manufacturers_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_cat_pdf_extractions phoenix_kit_cat_pdf_extractions_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_cat_pdf_extractions
    ADD CONSTRAINT phoenix_kit_cat_pdf_extractions_pkey PRIMARY KEY (file_uuid);


--
-- Name: phoenix_kit_cat_pdf_page_contents phoenix_kit_cat_pdf_page_contents_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_cat_pdf_page_contents
    ADD CONSTRAINT phoenix_kit_cat_pdf_page_contents_pkey PRIMARY KEY (content_hash);


--
-- Name: phoenix_kit_cat_pdf_pages phoenix_kit_cat_pdf_pages_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_cat_pdf_pages
    ADD CONSTRAINT phoenix_kit_cat_pdf_pages_pkey PRIMARY KEY (file_uuid, page_number);


--
-- Name: phoenix_kit_cat_pdfs phoenix_kit_cat_pdfs_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_cat_pdfs
    ADD CONSTRAINT phoenix_kit_cat_pdfs_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_cat_suppliers phoenix_kit_cat_suppliers_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_cat_suppliers
    ADD CONSTRAINT phoenix_kit_cat_suppliers_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_comment_dislikes phoenix_kit_comment_dislikes_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_comment_dislikes
    ADD CONSTRAINT phoenix_kit_comment_dislikes_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_comment_likes phoenix_kit_comment_likes_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_comment_likes
    ADD CONSTRAINT phoenix_kit_comment_likes_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_comment_media phoenix_kit_comment_media_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_comment_media
    ADD CONSTRAINT phoenix_kit_comment_media_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_comments_dislikes phoenix_kit_comments_dislikes_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_comments_dislikes
    ADD CONSTRAINT phoenix_kit_comments_dislikes_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_comments_likes phoenix_kit_comments_likes_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_comments_likes
    ADD CONSTRAINT phoenix_kit_comments_likes_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_comments phoenix_kit_comments_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_comments
    ADD CONSTRAINT phoenix_kit_comments_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_consent_logs phoenix_kit_consent_logs_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_consent_logs
    ADD CONSTRAINT phoenix_kit_consent_logs_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_crm_companies phoenix_kit_crm_companies_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_crm_companies
    ADD CONSTRAINT phoenix_kit_crm_companies_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_crm_company_memberships phoenix_kit_crm_company_memberships_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_crm_company_memberships
    ADD CONSTRAINT phoenix_kit_crm_company_memberships_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_crm_company_memberships phoenix_kit_crm_company_memberships_uniq; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_crm_company_memberships
    ADD CONSTRAINT phoenix_kit_crm_company_memberships_uniq UNIQUE (contact_uuid, company_uuid);


--
-- Name: phoenix_kit_crm_contacts phoenix_kit_crm_contacts_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_crm_contacts
    ADD CONSTRAINT phoenix_kit_crm_contacts_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_crm_interaction_parties phoenix_kit_crm_interaction_parties_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_crm_interaction_parties
    ADD CONSTRAINT phoenix_kit_crm_interaction_parties_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_crm_interactions phoenix_kit_crm_interactions_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_crm_interactions
    ADD CONSTRAINT phoenix_kit_crm_interactions_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_crm_list_members phoenix_kit_crm_list_members_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_crm_list_members
    ADD CONSTRAINT phoenix_kit_crm_list_members_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_crm_lists phoenix_kit_crm_lists_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_crm_lists
    ADD CONSTRAINT phoenix_kit_crm_lists_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_crm_party_roles phoenix_kit_crm_party_roles_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_crm_party_roles
    ADD CONSTRAINT phoenix_kit_crm_party_roles_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_crm_role_settings phoenix_kit_crm_role_settings_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_crm_role_settings
    ADD CONSTRAINT phoenix_kit_crm_role_settings_pkey PRIMARY KEY (role_uuid);


--
-- Name: phoenix_kit_crm_user_role_view phoenix_kit_crm_user_role_view_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_crm_user_role_view
    ADD CONSTRAINT phoenix_kit_crm_user_role_view_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_crm_user_role_view phoenix_kit_crm_user_role_view_user_scope_uniq; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_crm_user_role_view
    ADD CONSTRAINT phoenix_kit_crm_user_role_view_user_scope_uniq UNIQUE (user_uuid, scope);


--
-- Name: phoenix_kit_currencies phoenix_kit_currencies_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_currencies
    ADD CONSTRAINT phoenix_kit_currencies_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_dashboards phoenix_kit_dashboards_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_dashboards
    ADD CONSTRAINT phoenix_kit_dashboards_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_doc_categories phoenix_kit_doc_categories_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_doc_categories
    ADD CONSTRAINT phoenix_kit_doc_categories_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_doc_document_sections phoenix_kit_doc_document_sections_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_doc_document_sections
    ADD CONSTRAINT phoenix_kit_doc_document_sections_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_doc_documents phoenix_kit_doc_documents_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_doc_documents
    ADD CONSTRAINT phoenix_kit_doc_documents_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_doc_headers_footers phoenix_kit_doc_headers_footers_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_doc_headers_footers
    ADD CONSTRAINT phoenix_kit_doc_headers_footers_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_doc_template_presets phoenix_kit_doc_template_presets_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_doc_template_presets
    ADD CONSTRAINT phoenix_kit_doc_template_presets_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_doc_templates phoenix_kit_doc_templates_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_doc_templates
    ADD CONSTRAINT phoenix_kit_doc_templates_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_doc_types phoenix_kit_doc_types_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_doc_types
    ADD CONSTRAINT phoenix_kit_doc_types_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_email_blocklist phoenix_kit_email_blocklist_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_email_blocklist
    ADD CONSTRAINT phoenix_kit_email_blocklist_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_email_events phoenix_kit_email_events_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_email_events
    ADD CONSTRAINT phoenix_kit_email_events_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_email_logs phoenix_kit_email_logs_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_email_logs
    ADD CONSTRAINT phoenix_kit_email_logs_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_email_metrics phoenix_kit_email_metrics_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_email_metrics
    ADD CONSTRAINT phoenix_kit_email_metrics_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_email_orphaned_events phoenix_kit_email_orphaned_events_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_email_orphaned_events
    ADD CONSTRAINT phoenix_kit_email_orphaned_events_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_email_send_profiles phoenix_kit_email_send_profiles_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_email_send_profiles
    ADD CONSTRAINT phoenix_kit_email_send_profiles_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_email_templates phoenix_kit_email_templates_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_email_templates
    ADD CONSTRAINT phoenix_kit_email_templates_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_entities phoenix_kit_entities_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_entities
    ADD CONSTRAINT phoenix_kit_entities_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_entity_data phoenix_kit_entity_data_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_entity_data
    ADD CONSTRAINT phoenix_kit_entity_data_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_file_instances phoenix_kit_file_instances_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_file_instances
    ADD CONSTRAINT phoenix_kit_file_instances_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_file_locations phoenix_kit_file_locations_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_file_locations
    ADD CONSTRAINT phoenix_kit_file_locations_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_files phoenix_kit_files_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_files
    ADD CONSTRAINT phoenix_kit_files_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_invoices phoenix_kit_invoices_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_invoices
    ADD CONSTRAINT phoenix_kit_invoices_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_location_spaces phoenix_kit_location_spaces_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_location_spaces
    ADD CONSTRAINT phoenix_kit_location_spaces_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_location_type_assignments phoenix_kit_location_type_assignments_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_location_type_assignments
    ADD CONSTRAINT phoenix_kit_location_type_assignments_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_location_types phoenix_kit_location_types_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_location_types
    ADD CONSTRAINT phoenix_kit_location_types_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_locations phoenix_kit_locations_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_locations
    ADD CONSTRAINT phoenix_kit_locations_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_machine_operations phoenix_kit_machine_operations_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_machine_operations
    ADD CONSTRAINT phoenix_kit_machine_operations_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_machine_type_assignments phoenix_kit_machine_type_assignments_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_machine_type_assignments
    ADD CONSTRAINT phoenix_kit_machine_type_assignments_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_machines phoenix_kit_machines_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_machines
    ADD CONSTRAINT phoenix_kit_machines_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_media_folder_links phoenix_kit_media_folder_links_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_media_folder_links
    ADD CONSTRAINT phoenix_kit_media_folder_links_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_media_folders phoenix_kit_media_folders_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_media_folders
    ADD CONSTRAINT phoenix_kit_media_folders_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_newsletters_broadcasts phoenix_kit_newsletters_broadcasts_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_newsletters_broadcasts
    ADD CONSTRAINT phoenix_kit_newsletters_broadcasts_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_newsletters_deliveries phoenix_kit_newsletters_deliveries_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_newsletters_deliveries
    ADD CONSTRAINT phoenix_kit_newsletters_deliveries_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_notifications phoenix_kit_notifications_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_notifications
    ADD CONSTRAINT phoenix_kit_notifications_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_og_assignments phoenix_kit_og_assignments_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_og_assignments
    ADD CONSTRAINT phoenix_kit_og_assignments_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_og_templates phoenix_kit_og_templates_name_uniq; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_og_templates
    ADD CONSTRAINT phoenix_kit_og_templates_name_uniq UNIQUE (name);


--
-- Name: phoenix_kit_og_templates phoenix_kit_og_templates_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_og_templates
    ADD CONSTRAINT phoenix_kit_og_templates_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_orders phoenix_kit_orders_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_orders
    ADD CONSTRAINT phoenix_kit_orders_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_organization_invitations phoenix_kit_organization_invitations_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_organization_invitations
    ADD CONSTRAINT phoenix_kit_organization_invitations_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_payment_methods phoenix_kit_payment_methods_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_payment_methods
    ADD CONSTRAINT phoenix_kit_payment_methods_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_payment_options phoenix_kit_payment_options_code_unique; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_payment_options
    ADD CONSTRAINT phoenix_kit_payment_options_code_unique UNIQUE (code);


--
-- Name: phoenix_kit_payment_options phoenix_kit_payment_options_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_payment_options
    ADD CONSTRAINT phoenix_kit_payment_options_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_payment_provider_configs phoenix_kit_payment_provider_configs_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_payment_provider_configs
    ADD CONSTRAINT phoenix_kit_payment_provider_configs_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit phoenix_kit_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit
    ADD CONSTRAINT phoenix_kit_pkey PRIMARY KEY (id);


--
-- Name: phoenix_kit_post_comments phoenix_kit_post_comments_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_post_comments
    ADD CONSTRAINT phoenix_kit_post_comments_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_post_dislikes phoenix_kit_post_dislikes_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_post_dislikes
    ADD CONSTRAINT phoenix_kit_post_dislikes_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_post_groups phoenix_kit_post_groups_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_post_groups
    ADD CONSTRAINT phoenix_kit_post_groups_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_post_likes phoenix_kit_post_likes_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_post_likes
    ADD CONSTRAINT phoenix_kit_post_likes_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_post_media phoenix_kit_post_media_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_post_media
    ADD CONSTRAINT phoenix_kit_post_media_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_post_mentions phoenix_kit_post_mentions_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_post_mentions
    ADD CONSTRAINT phoenix_kit_post_mentions_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_post_tags phoenix_kit_post_tags_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_post_tags
    ADD CONSTRAINT phoenix_kit_post_tags_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_post_views phoenix_kit_post_views_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_post_views
    ADD CONSTRAINT phoenix_kit_post_views_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_posts phoenix_kit_posts_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_posts
    ADD CONSTRAINT phoenix_kit_posts_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_project_assignments phoenix_kit_project_assignments_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_project_assignments
    ADD CONSTRAINT phoenix_kit_project_assignments_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_project_dependencies phoenix_kit_project_dependencies_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_project_dependencies
    ADD CONSTRAINT phoenix_kit_project_dependencies_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_project_statuses phoenix_kit_project_statuses_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_project_statuses
    ADD CONSTRAINT phoenix_kit_project_statuses_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_project_task_dependencies phoenix_kit_project_task_dependencies_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_project_task_dependencies
    ADD CONSTRAINT phoenix_kit_project_task_dependencies_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_project_tasks phoenix_kit_project_tasks_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_project_tasks
    ADD CONSTRAINT phoenix_kit_project_tasks_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_projects phoenix_kit_projects_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_projects
    ADD CONSTRAINT phoenix_kit_projects_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_publishing_categories phoenix_kit_publishing_categories_group_slug_uniq; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_publishing_categories
    ADD CONSTRAINT phoenix_kit_publishing_categories_group_slug_uniq UNIQUE (group_uuid, slug);


--
-- Name: phoenix_kit_publishing_categories phoenix_kit_publishing_categories_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_publishing_categories
    ADD CONSTRAINT phoenix_kit_publishing_categories_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_publishing_contents phoenix_kit_publishing_contents_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_publishing_contents
    ADD CONSTRAINT phoenix_kit_publishing_contents_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_publishing_groups phoenix_kit_publishing_groups_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_publishing_groups
    ADD CONSTRAINT phoenix_kit_publishing_groups_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_publishing_post_categories phoenix_kit_publishing_post_categories_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_publishing_post_categories
    ADD CONSTRAINT phoenix_kit_publishing_post_categories_pkey PRIMARY KEY (post_uuid, category_uuid);


--
-- Name: phoenix_kit_publishing_post_views phoenix_kit_publishing_post_views_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_publishing_post_views
    ADD CONSTRAINT phoenix_kit_publishing_post_views_pkey PRIMARY KEY (post_uuid, view_date);


--
-- Name: phoenix_kit_publishing_posts phoenix_kit_publishing_posts_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_publishing_posts
    ADD CONSTRAINT phoenix_kit_publishing_posts_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_publishing_versions phoenix_kit_publishing_versions_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_publishing_versions
    ADD CONSTRAINT phoenix_kit_publishing_versions_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_referral_code_usage phoenix_kit_referral_code_usage_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_referral_code_usage
    ADD CONSTRAINT phoenix_kit_referral_code_usage_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_referral_codes phoenix_kit_referral_codes_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_referral_codes
    ADD CONSTRAINT phoenix_kit_referral_codes_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_role_permissions phoenix_kit_role_permissions_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_role_permissions
    ADD CONSTRAINT phoenix_kit_role_permissions_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_scheduled_jobs phoenix_kit_scheduled_jobs_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_scheduled_jobs
    ADD CONSTRAINT phoenix_kit_scheduled_jobs_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_settings phoenix_kit_settings_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_settings
    ADD CONSTRAINT phoenix_kit_settings_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_shop_cart_items phoenix_kit_shop_cart_items_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_shop_cart_items
    ADD CONSTRAINT phoenix_kit_shop_cart_items_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_shop_carts phoenix_kit_shop_carts_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_shop_carts
    ADD CONSTRAINT phoenix_kit_shop_carts_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_shop_categories phoenix_kit_shop_categories_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_shop_categories
    ADD CONSTRAINT phoenix_kit_shop_categories_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_shop_config phoenix_kit_shop_config_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_shop_config
    ADD CONSTRAINT phoenix_kit_shop_config_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_shop_import_configs phoenix_kit_shop_import_configs_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_shop_import_configs
    ADD CONSTRAINT phoenix_kit_shop_import_configs_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_shop_import_logs phoenix_kit_shop_import_logs_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_shop_import_logs
    ADD CONSTRAINT phoenix_kit_shop_import_logs_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_shop_products phoenix_kit_shop_products_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_shop_products
    ADD CONSTRAINT phoenix_kit_shop_products_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_shop_shipping_methods phoenix_kit_shop_shipping_methods_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_shop_shipping_methods
    ADD CONSTRAINT phoenix_kit_shop_shipping_methods_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_shop_shipping_methods phoenix_kit_shop_shipping_methods_slug_unique; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_shop_shipping_methods
    ADD CONSTRAINT phoenix_kit_shop_shipping_methods_slug_unique UNIQUE (slug);


--
-- Name: phoenix_kit_staff_departments phoenix_kit_staff_departments_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_staff_departments
    ADD CONSTRAINT phoenix_kit_staff_departments_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_staff_employments phoenix_kit_staff_employments_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_staff_employments
    ADD CONSTRAINT phoenix_kit_staff_employments_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_staff_people phoenix_kit_staff_people_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_staff_people
    ADD CONSTRAINT phoenix_kit_staff_people_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_staff_person_skills phoenix_kit_staff_person_skills_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_staff_person_skills
    ADD CONSTRAINT phoenix_kit_staff_person_skills_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_staff_skills phoenix_kit_staff_skills_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_staff_skills
    ADD CONSTRAINT phoenix_kit_staff_skills_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_staff_team_memberships phoenix_kit_staff_team_memberships_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_staff_team_memberships
    ADD CONSTRAINT phoenix_kit_staff_team_memberships_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_staff_teams phoenix_kit_staff_teams_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_staff_teams
    ADD CONSTRAINT phoenix_kit_staff_teams_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_storage_dimensions phoenix_kit_storage_dimensions_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_storage_dimensions
    ADD CONSTRAINT phoenix_kit_storage_dimensions_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_subscription_types phoenix_kit_subscription_types_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_subscription_types
    ADD CONSTRAINT phoenix_kit_subscription_types_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_subscriptions phoenix_kit_subscriptions_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_subscriptions
    ADD CONSTRAINT phoenix_kit_subscriptions_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_sync_connections phoenix_kit_sync_connections_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_sync_connections
    ADD CONSTRAINT phoenix_kit_sync_connections_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_sync_transfers phoenix_kit_sync_transfers_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_sync_transfers
    ADD CONSTRAINT phoenix_kit_sync_transfers_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_ticket_attachments phoenix_kit_ticket_attachments_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_ticket_attachments
    ADD CONSTRAINT phoenix_kit_ticket_attachments_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_ticket_comments phoenix_kit_ticket_comments_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_ticket_comments
    ADD CONSTRAINT phoenix_kit_ticket_comments_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_ticket_status_history phoenix_kit_ticket_status_history_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_ticket_status_history
    ADD CONSTRAINT phoenix_kit_ticket_status_history_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_tickets phoenix_kit_tickets_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_tickets
    ADD CONSTRAINT phoenix_kit_tickets_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_transactions phoenix_kit_transactions_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_transactions
    ADD CONSTRAINT phoenix_kit_transactions_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_user_blocks_history phoenix_kit_user_blocks_history_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_user_blocks_history
    ADD CONSTRAINT phoenix_kit_user_blocks_history_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_user_blocks phoenix_kit_user_blocks_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_user_blocks
    ADD CONSTRAINT phoenix_kit_user_blocks_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_user_connections_history phoenix_kit_user_connections_history_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_user_connections_history
    ADD CONSTRAINT phoenix_kit_user_connections_history_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_user_connections phoenix_kit_user_connections_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_user_connections
    ADD CONSTRAINT phoenix_kit_user_connections_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_user_follows_history phoenix_kit_user_follows_history_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_user_follows_history
    ADD CONSTRAINT phoenix_kit_user_follows_history_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_user_follows phoenix_kit_user_follows_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_user_follows
    ADD CONSTRAINT phoenix_kit_user_follows_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_user_known_devices phoenix_kit_user_known_devices_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_user_known_devices
    ADD CONSTRAINT phoenix_kit_user_known_devices_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_user_oauth_providers phoenix_kit_user_oauth_providers_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_user_oauth_providers
    ADD CONSTRAINT phoenix_kit_user_oauth_providers_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_user_role_assignments phoenix_kit_user_role_assignments_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_user_role_assignments
    ADD CONSTRAINT phoenix_kit_user_role_assignments_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_user_roles phoenix_kit_user_roles_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_user_roles
    ADD CONSTRAINT phoenix_kit_user_roles_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_users phoenix_kit_users_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_users
    ADD CONSTRAINT phoenix_kit_users_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_users_tokens phoenix_kit_users_tokens_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_users_tokens
    ADD CONSTRAINT phoenix_kit_users_tokens_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_warehouse_goods_issues phoenix_kit_warehouse_goods_issues_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_warehouse_goods_issues
    ADD CONSTRAINT phoenix_kit_warehouse_goods_issues_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_warehouse_goods_receipts phoenix_kit_warehouse_goods_receipts_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_warehouse_goods_receipts
    ADD CONSTRAINT phoenix_kit_warehouse_goods_receipts_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_warehouse_internal_orders phoenix_kit_warehouse_internal_orders_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_warehouse_internal_orders
    ADD CONSTRAINT phoenix_kit_warehouse_internal_orders_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_warehouse_inventory_documents phoenix_kit_warehouse_inventory_documents_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_warehouse_inventory_documents
    ADD CONSTRAINT phoenix_kit_warehouse_inventory_documents_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_warehouse_min_stock phoenix_kit_warehouse_min_stock_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_warehouse_min_stock
    ADD CONSTRAINT phoenix_kit_warehouse_min_stock_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_warehouse_stock phoenix_kit_warehouse_stock_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_warehouse_stock
    ADD CONSTRAINT phoenix_kit_warehouse_stock_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_warehouse_supplier_orders phoenix_kit_warehouse_supplier_orders_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_warehouse_supplier_orders
    ADD CONSTRAINT phoenix_kit_warehouse_supplier_orders_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_warehouse_transfers phoenix_kit_warehouse_transfers_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_warehouse_transfers
    ADD CONSTRAINT phoenix_kit_warehouse_transfers_pkey PRIMARY KEY (uuid);


--
-- Name: phoenix_kit_webhook_events phoenix_kit_webhook_events_pkey; Type: CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_webhook_events
    ADD CONSTRAINT phoenix_kit_webhook_events_pkey PRIMARY KEY (uuid);


--
-- Name: idx_calendar_events_owner_starts_at; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX idx_calendar_events_owner_starts_at ON pk_sqv_s1a.phoenix_kit_calendar_events USING btree (owner_uuid, starts_at);


--
-- Name: idx_calendar_events_owner_starts_on; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX idx_calendar_events_owner_starts_on ON pk_sqv_s1a.phoenix_kit_calendar_events USING btree (owner_uuid, starts_on);


--
-- Name: idx_calendar_participants_event; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX idx_calendar_participants_event ON pk_sqv_s1a.phoenix_kit_calendar_event_participants USING btree (event_uuid);


--
-- Name: idx_calendar_participants_free_text; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX idx_calendar_participants_free_text ON pk_sqv_s1a.phoenix_kit_calendar_event_participants USING btree (event_uuid, lower((display_name)::text)) WHERE ((kind)::text = 'free_text'::text);


--
-- Name: idx_calendar_participants_kind_target; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX idx_calendar_participants_kind_target ON pk_sqv_s1a.phoenix_kit_calendar_event_participants USING btree (kind, target_uuid) WHERE (target_uuid IS NOT NULL);


--
-- Name: idx_calendar_participants_target; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX idx_calendar_participants_target ON pk_sqv_s1a.phoenix_kit_calendar_event_participants USING btree (event_uuid, kind, target_uuid) WHERE (target_uuid IS NOT NULL);


--
-- Name: idx_comments_inserted_at; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX idx_comments_inserted_at ON pk_sqv_s1a.phoenix_kit_comments USING btree (inserted_at);


--
-- Name: idx_comments_parent_id; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX idx_comments_parent_id ON pk_sqv_s1a.phoenix_kit_comments USING btree (parent_uuid);


--
-- Name: idx_comments_resource; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX idx_comments_resource ON pk_sqv_s1a.phoenix_kit_comments USING btree (resource_type, resource_uuid);


--
-- Name: idx_comments_resource_status; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX idx_comments_resource_status ON pk_sqv_s1a.phoenix_kit_comments USING btree (resource_type, resource_uuid, status);


--
-- Name: idx_comments_status; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX idx_comments_status ON pk_sqv_s1a.phoenix_kit_comments USING btree (status);


--
-- Name: idx_crm_companies_status; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX idx_crm_companies_status ON pk_sqv_s1a.phoenix_kit_crm_companies USING btree (status);


--
-- Name: idx_crm_contacts_status; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX idx_crm_contacts_status ON pk_sqv_s1a.phoenix_kit_crm_contacts USING btree (status);


--
-- Name: idx_crm_contacts_user_uuid; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX idx_crm_contacts_user_uuid ON pk_sqv_s1a.phoenix_kit_crm_contacts USING btree (user_uuid) WHERE (user_uuid IS NOT NULL);


--
-- Name: idx_crm_interactions_contact; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX idx_crm_interactions_contact ON pk_sqv_s1a.phoenix_kit_crm_interactions USING btree (contact_uuid, occurred_at DESC);


--
-- Name: idx_crm_list_members_contact; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX idx_crm_list_members_contact ON pk_sqv_s1a.phoenix_kit_crm_list_members USING btree (contact_uuid);


--
-- Name: idx_crm_list_members_list_contact; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX idx_crm_list_members_list_contact ON pk_sqv_s1a.phoenix_kit_crm_list_members USING btree (list_uuid, contact_uuid);


--
-- Name: idx_crm_list_members_list_email; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX idx_crm_list_members_list_email ON pk_sqv_s1a.phoenix_kit_crm_list_members USING btree (list_uuid, email) WHERE (email IS NOT NULL);


--
-- Name: idx_crm_lists_slug; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX idx_crm_lists_slug ON pk_sqv_s1a.phoenix_kit_crm_lists USING btree (slug);


--
-- Name: idx_crm_memberships_company; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX idx_crm_memberships_company ON pk_sqv_s1a.phoenix_kit_crm_company_memberships USING btree (company_uuid);


--
-- Name: idx_crm_memberships_contact; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX idx_crm_memberships_contact ON pk_sqv_s1a.phoenix_kit_crm_company_memberships USING btree (contact_uuid);


--
-- Name: idx_crm_parties_contact; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX idx_crm_parties_contact ON pk_sqv_s1a.phoenix_kit_crm_interaction_parties USING btree (contact_uuid) WHERE (contact_uuid IS NOT NULL);


--
-- Name: idx_crm_parties_interaction; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX idx_crm_parties_interaction ON pk_sqv_s1a.phoenix_kit_crm_interaction_parties USING btree (interaction_uuid);


--
-- Name: idx_crm_parties_staff_person; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX idx_crm_parties_staff_person ON pk_sqv_s1a.phoenix_kit_crm_interaction_parties USING btree (staff_person_uuid) WHERE (staff_person_uuid IS NOT NULL);


--
-- Name: idx_crm_user_role_view_user; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX idx_crm_user_role_view_user ON pk_sqv_s1a.phoenix_kit_crm_user_role_view USING btree (user_uuid);


--
-- Name: idx_email_logs_locale; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX idx_email_logs_locale ON pk_sqv_s1a.phoenix_kit_email_logs USING btree (locale);


--
-- Name: idx_email_send_profiles_default; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX idx_email_send_profiles_default ON pk_sqv_s1a.phoenix_kit_email_send_profiles USING btree (is_default) WHERE (is_default = true);


--
-- Name: idx_email_send_profiles_integration; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX idx_email_send_profiles_integration ON pk_sqv_s1a.phoenix_kit_email_send_profiles USING btree (integration_uuid);


--
-- Name: idx_machine_operations_operation; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX idx_machine_operations_operation ON pk_sqv_s1a.phoenix_kit_machine_operations USING btree (operation_uuid);


--
-- Name: idx_machine_operations_unique; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX idx_machine_operations_unique ON pk_sqv_s1a.phoenix_kit_machine_operations USING btree (machine_uuid, operation_uuid);


--
-- Name: idx_machine_type_assignments_type; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX idx_machine_type_assignments_type ON pk_sqv_s1a.phoenix_kit_machine_type_assignments USING btree (machine_type_uuid);


--
-- Name: idx_machine_type_assignments_unique; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX idx_machine_type_assignments_unique ON pk_sqv_s1a.phoenix_kit_machine_type_assignments USING btree (machine_uuid, machine_type_uuid);


--
-- Name: idx_machines_location; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX idx_machines_location ON pk_sqv_s1a.phoenix_kit_machines USING btree (location_uuid);


--
-- Name: idx_machines_status; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX idx_machines_status ON pk_sqv_s1a.phoenix_kit_machines USING btree (status);


--
-- Name: idx_newsletters_broadcasts_crm_list; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX idx_newsletters_broadcasts_crm_list ON pk_sqv_s1a.phoenix_kit_newsletters_broadcasts USING btree (crm_list_uuid) WHERE (crm_list_uuid IS NOT NULL);


--
-- Name: idx_newsletters_broadcasts_scheduled_at; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX idx_newsletters_broadcasts_scheduled_at ON pk_sqv_s1a.phoenix_kit_newsletters_broadcasts USING btree (scheduled_at) WHERE (scheduled_at IS NOT NULL);


--
-- Name: idx_newsletters_broadcasts_status; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX idx_newsletters_broadcasts_status ON pk_sqv_s1a.phoenix_kit_newsletters_broadcasts USING btree (status);


--
-- Name: idx_newsletters_deliveries_broadcast; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX idx_newsletters_deliveries_broadcast ON pk_sqv_s1a.phoenix_kit_newsletters_deliveries USING btree (broadcast_uuid);


--
-- Name: idx_newsletters_deliveries_crm_contact; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX idx_newsletters_deliveries_crm_contact ON pk_sqv_s1a.phoenix_kit_newsletters_deliveries USING btree (crm_contact_uuid);


--
-- Name: idx_newsletters_deliveries_message_id; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX idx_newsletters_deliveries_message_id ON pk_sqv_s1a.phoenix_kit_newsletters_deliveries USING btree (message_id) WHERE (message_id IS NOT NULL);


--
-- Name: idx_newsletters_deliveries_status; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX idx_newsletters_deliveries_status ON pk_sqv_s1a.phoenix_kit_newsletters_deliveries USING btree (status);


--
-- Name: idx_newsletters_deliveries_uniq_broadcast_contact; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX idx_newsletters_deliveries_uniq_broadcast_contact ON pk_sqv_s1a.phoenix_kit_newsletters_deliveries USING btree (broadcast_uuid, crm_contact_uuid) WHERE (crm_contact_uuid IS NOT NULL);


--
-- Name: idx_newsletters_deliveries_uniq_broadcast_email; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX idx_newsletters_deliveries_uniq_broadcast_email ON pk_sqv_s1a.phoenix_kit_newsletters_deliveries USING btree (broadcast_uuid, recipient_email) WHERE (recipient_email IS NOT NULL);


--
-- Name: idx_newsletters_deliveries_uniq_broadcast_user; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX idx_newsletters_deliveries_uniq_broadcast_user ON pk_sqv_s1a.phoenix_kit_newsletters_deliveries USING btree (broadcast_uuid, user_uuid) WHERE (user_uuid IS NOT NULL);


--
-- Name: idx_newsletters_deliveries_user; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX idx_newsletters_deliveries_user ON pk_sqv_s1a.phoenix_kit_newsletters_deliveries USING btree (user_uuid);


--
-- Name: idx_og_assignments_template; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX idx_og_assignments_template ON pk_sqv_s1a.phoenix_kit_og_assignments USING btree (template_uuid);


--
-- Name: idx_og_assignments_unique_default; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX idx_og_assignments_unique_default ON pk_sqv_s1a.phoenix_kit_og_assignments USING btree (module_key, scope_type) WHERE (scope_uuid IS NULL);


--
-- Name: idx_og_assignments_unique_scoped; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX idx_og_assignments_unique_scoped ON pk_sqv_s1a.phoenix_kit_og_assignments USING btree (module_key, scope_type, scope_uuid) WHERE (scope_uuid IS NOT NULL);


--
-- Name: idx_payment_options_active; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX idx_payment_options_active ON pk_sqv_s1a.phoenix_kit_payment_options USING btree (active);


--
-- Name: idx_payment_options_position; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX idx_payment_options_position ON pk_sqv_s1a.phoenix_kit_payment_options USING btree ("position");


--
-- Name: idx_phoenix_kit_dashboards_owner; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX idx_phoenix_kit_dashboards_owner ON pk_sqv_s1a.phoenix_kit_dashboards USING btree (owner_user_uuid) WHERE (owner_user_uuid IS NOT NULL);


--
-- Name: idx_phoenix_kit_dashboards_scope; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX idx_phoenix_kit_dashboards_scope ON pk_sqv_s1a.phoenix_kit_dashboards USING btree (scope);


--
-- Name: idx_publishing_categories_group; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX idx_publishing_categories_group ON pk_sqv_s1a.phoenix_kit_publishing_categories USING btree (group_uuid);


--
-- Name: idx_publishing_categories_parent; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX idx_publishing_categories_parent ON pk_sqv_s1a.phoenix_kit_publishing_categories USING btree (parent_uuid);


--
-- Name: idx_publishing_contents_data_gin; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX idx_publishing_contents_data_gin ON pk_sqv_s1a.phoenix_kit_publishing_contents USING gin (data);


--
-- Name: idx_publishing_contents_url_slug; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX idx_publishing_contents_url_slug ON pk_sqv_s1a.phoenix_kit_publishing_contents USING btree (url_slug) WHERE (url_slug IS NOT NULL);


--
-- Name: idx_publishing_contents_version_id; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX idx_publishing_contents_version_id ON pk_sqv_s1a.phoenix_kit_publishing_contents USING btree (version_uuid);


--
-- Name: idx_publishing_contents_version_language; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX idx_publishing_contents_version_language ON pk_sqv_s1a.phoenix_kit_publishing_contents USING btree (version_uuid, language);


--
-- Name: idx_publishing_groups_slug; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX idx_publishing_groups_slug ON pk_sqv_s1a.phoenix_kit_publishing_groups USING btree (slug);


--
-- Name: idx_publishing_groups_status; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX idx_publishing_groups_status ON pk_sqv_s1a.phoenix_kit_publishing_groups USING btree (status);


--
-- Name: idx_publishing_post_categories_category; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX idx_publishing_post_categories_category ON pk_sqv_s1a.phoenix_kit_publishing_post_categories USING btree (category_uuid);


--
-- Name: idx_publishing_posts_active_version; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX idx_publishing_posts_active_version ON pk_sqv_s1a.phoenix_kit_publishing_posts USING btree (active_version_uuid) WHERE (active_version_uuid IS NOT NULL);


--
-- Name: idx_publishing_posts_created_by; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX idx_publishing_posts_created_by ON pk_sqv_s1a.phoenix_kit_publishing_posts USING btree (created_by_uuid);


--
-- Name: idx_publishing_posts_group_date_time; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX idx_publishing_posts_group_date_time ON pk_sqv_s1a.phoenix_kit_publishing_posts USING btree (group_uuid, post_date DESC, post_time DESC) WHERE (post_date IS NOT NULL);


--
-- Name: idx_publishing_posts_group_date_time_unique; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX idx_publishing_posts_group_date_time_unique ON pk_sqv_s1a.phoenix_kit_publishing_posts USING btree (group_uuid, post_date, post_time) WHERE ((post_date IS NOT NULL) AND (post_time IS NOT NULL));


--
-- Name: idx_publishing_posts_group_id; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX idx_publishing_posts_group_id ON pk_sqv_s1a.phoenix_kit_publishing_posts USING btree (group_uuid);


--
-- Name: idx_publishing_posts_group_slug; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX idx_publishing_posts_group_slug ON pk_sqv_s1a.phoenix_kit_publishing_posts USING btree (group_uuid, slug) WHERE (slug IS NOT NULL);


--
-- Name: idx_publishing_posts_trashed_at; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX idx_publishing_posts_trashed_at ON pk_sqv_s1a.phoenix_kit_publishing_posts USING btree (trashed_at) WHERE (trashed_at IS NULL);


--
-- Name: idx_publishing_posts_updated_by; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX idx_publishing_posts_updated_by ON pk_sqv_s1a.phoenix_kit_publishing_posts USING btree (updated_by_uuid);


--
-- Name: idx_publishing_versions_created_by; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX idx_publishing_versions_created_by ON pk_sqv_s1a.phoenix_kit_publishing_versions USING btree (created_by_uuid);


--
-- Name: idx_publishing_versions_post_id; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX idx_publishing_versions_post_id ON pk_sqv_s1a.phoenix_kit_publishing_versions USING btree (post_uuid);


--
-- Name: idx_publishing_versions_post_number; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX idx_publishing_versions_post_number ON pk_sqv_s1a.phoenix_kit_publishing_versions USING btree (post_uuid, version_number);


--
-- Name: idx_publishing_versions_post_status; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX idx_publishing_versions_post_status ON pk_sqv_s1a.phoenix_kit_publishing_versions USING btree (post_uuid, status);


--
-- Name: idx_publishing_versions_published_at; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX idx_publishing_versions_published_at ON pk_sqv_s1a.phoenix_kit_publishing_versions USING btree (published_at DESC) WHERE (published_at IS NOT NULL);


--
-- Name: idx_role_permissions_module_key; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX idx_role_permissions_module_key ON pk_sqv_s1a.phoenix_kit_role_permissions USING btree (module_key);


--
-- Name: idx_role_permissions_uuid; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX idx_role_permissions_uuid ON pk_sqv_s1a.phoenix_kit_role_permissions USING btree (uuid);


--
-- Name: idx_shop_cart_items_selected_specs; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX idx_shop_cart_items_selected_specs ON pk_sqv_s1a.phoenix_kit_shop_cart_items USING gin (selected_specs);


--
-- Name: idx_shop_carts_session; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX idx_shop_carts_session ON pk_sqv_s1a.phoenix_kit_shop_carts USING btree (session_id) WHERE (session_id IS NOT NULL);


--
-- Name: idx_shop_carts_status; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX idx_shop_carts_status ON pk_sqv_s1a.phoenix_kit_shop_carts USING btree (status);


--
-- Name: idx_shop_categories_position; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX idx_shop_categories_position ON pk_sqv_s1a.phoenix_kit_shop_categories USING btree ("position");


--
-- Name: idx_shop_categories_slug_primary; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX idx_shop_categories_slug_primary ON pk_sqv_s1a.phoenix_kit_shop_categories USING btree (pk_sqv_s1a.extract_primary_slug(slug)) WHERE (pk_sqv_s1a.extract_primary_slug(slug) IS NOT NULL);


--
-- Name: idx_shop_categories_status; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX idx_shop_categories_status ON pk_sqv_s1a.phoenix_kit_shop_categories USING btree (status);


--
-- Name: idx_shop_config_key; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX idx_shop_config_key ON pk_sqv_s1a.phoenix_kit_shop_config USING btree (key);


--
-- Name: idx_shop_config_uuid; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX idx_shop_config_uuid ON pk_sqv_s1a.phoenix_kit_shop_config USING btree (uuid);


--
-- Name: idx_shop_import_configs_is_default; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX idx_shop_import_configs_is_default ON pk_sqv_s1a.phoenix_kit_shop_import_configs USING btree (is_default) WHERE (is_default = true);


--
-- Name: idx_shop_import_configs_name; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX idx_shop_import_configs_name ON pk_sqv_s1a.phoenix_kit_shop_import_configs USING btree (name);


--
-- Name: idx_shop_import_configs_uuid; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX idx_shop_import_configs_uuid ON pk_sqv_s1a.phoenix_kit_shop_import_configs USING btree (uuid);


--
-- Name: idx_shop_import_logs_inserted_at; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX idx_shop_import_logs_inserted_at ON pk_sqv_s1a.phoenix_kit_shop_import_logs USING btree (inserted_at DESC);


--
-- Name: idx_shop_import_logs_status; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX idx_shop_import_logs_status ON pk_sqv_s1a.phoenix_kit_shop_import_logs USING btree (status);


--
-- Name: idx_shop_import_logs_uuid; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX idx_shop_import_logs_uuid ON pk_sqv_s1a.phoenix_kit_shop_import_logs USING btree (uuid);


--
-- Name: idx_shop_products_slug_primary; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX idx_shop_products_slug_primary ON pk_sqv_s1a.phoenix_kit_shop_products USING btree (pk_sqv_s1a.extract_primary_slug(slug)) WHERE (pk_sqv_s1a.extract_primary_slug(slug) IS NOT NULL);


--
-- Name: idx_shop_products_status; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX idx_shop_products_status ON pk_sqv_s1a.phoenix_kit_shop_products USING btree (status);


--
-- Name: idx_shop_products_tags; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX idx_shop_products_tags ON pk_sqv_s1a.phoenix_kit_shop_products USING gin (tags);


--
-- Name: idx_shop_products_type; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX idx_shop_products_type ON pk_sqv_s1a.phoenix_kit_shop_products USING btree (product_type);


--
-- Name: idx_shop_shipping_active; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX idx_shop_shipping_active ON pk_sqv_s1a.phoenix_kit_shop_shipping_methods USING btree (active);


--
-- Name: idx_shop_shipping_position; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX idx_shop_shipping_position ON pk_sqv_s1a.phoenix_kit_shop_shipping_methods USING btree ("position");


--
-- Name: idx_users_active; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX idx_users_active ON pk_sqv_s1a.phoenix_kit_users USING btree (is_active);


--
-- Name: oban_jobs_args_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX oban_jobs_args_index ON pk_sqv_s1a.oban_jobs USING gin (args);


--
-- Name: oban_jobs_meta_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX oban_jobs_meta_index ON pk_sqv_s1a.oban_jobs USING gin (meta);


--
-- Name: oban_jobs_state_cancelled_at_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX oban_jobs_state_cancelled_at_index ON pk_sqv_s1a.oban_jobs USING btree (state, cancelled_at);


--
-- Name: oban_jobs_state_discarded_at_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX oban_jobs_state_discarded_at_index ON pk_sqv_s1a.oban_jobs USING btree (state, discarded_at);


--
-- Name: oban_jobs_state_queue_priority_scheduled_at_id_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX oban_jobs_state_queue_priority_scheduled_at_id_index ON pk_sqv_s1a.oban_jobs USING btree (state, queue, priority, scheduled_at, id);


--
-- Name: phoenix_kit_activities_action_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_activities_action_index ON pk_sqv_s1a.phoenix_kit_activities USING btree (action);


--
-- Name: phoenix_kit_activities_action_inserted_at_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_activities_action_inserted_at_index ON pk_sqv_s1a.phoenix_kit_activities USING btree (action, inserted_at);


--
-- Name: phoenix_kit_activities_actor_uuid_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_activities_actor_uuid_index ON pk_sqv_s1a.phoenix_kit_activities USING btree (actor_uuid);


--
-- Name: phoenix_kit_activities_actor_uuid_inserted_at_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_activities_actor_uuid_inserted_at_index ON pk_sqv_s1a.phoenix_kit_activities USING btree (actor_uuid, inserted_at);


--
-- Name: phoenix_kit_activities_inserted_at_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_activities_inserted_at_index ON pk_sqv_s1a.phoenix_kit_activities USING btree (inserted_at);


--
-- Name: phoenix_kit_activities_mode_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_activities_mode_index ON pk_sqv_s1a.phoenix_kit_activities USING btree (mode);


--
-- Name: phoenix_kit_activities_module_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_activities_module_index ON pk_sqv_s1a.phoenix_kit_activities USING btree (module);


--
-- Name: phoenix_kit_activities_resource_type_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_activities_resource_type_index ON pk_sqv_s1a.phoenix_kit_activities USING btree (resource_type);


--
-- Name: phoenix_kit_activities_target_uuid_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_activities_target_uuid_index ON pk_sqv_s1a.phoenix_kit_activities USING btree (target_uuid);


--
-- Name: phoenix_kit_admin_notes_author_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_admin_notes_author_uuid_idx ON pk_sqv_s1a.phoenix_kit_admin_notes USING btree (author_uuid);


--
-- Name: phoenix_kit_admin_notes_inserted_at_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_admin_notes_inserted_at_index ON pk_sqv_s1a.phoenix_kit_admin_notes USING btree (inserted_at);


--
-- Name: phoenix_kit_admin_notes_user_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_admin_notes_user_uuid_idx ON pk_sqv_s1a.phoenix_kit_admin_notes USING btree (user_uuid);


--
-- Name: phoenix_kit_admin_notes_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX phoenix_kit_admin_notes_uuid_idx ON pk_sqv_s1a.phoenix_kit_admin_notes USING btree (uuid);


--
-- Name: phoenix_kit_ai_accounts_enabled_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_ai_accounts_enabled_idx ON pk_sqv_s1a.phoenix_kit_ai_accounts USING btree (enabled);


--
-- Name: phoenix_kit_ai_accounts_provider_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_ai_accounts_provider_idx ON pk_sqv_s1a.phoenix_kit_ai_accounts USING btree (provider);


--
-- Name: phoenix_kit_ai_accounts_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX phoenix_kit_ai_accounts_uuid_idx ON pk_sqv_s1a.phoenix_kit_ai_accounts USING btree (uuid);


--
-- Name: phoenix_kit_ai_endpoints_enabled_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_ai_endpoints_enabled_idx ON pk_sqv_s1a.phoenix_kit_ai_endpoints USING btree (enabled);


--
-- Name: phoenix_kit_ai_endpoints_integration_uuid_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_ai_endpoints_integration_uuid_index ON pk_sqv_s1a.phoenix_kit_ai_endpoints USING btree (integration_uuid);


--
-- Name: phoenix_kit_ai_endpoints_name_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX phoenix_kit_ai_endpoints_name_index ON pk_sqv_s1a.phoenix_kit_ai_endpoints USING btree (lower((name)::text));


--
-- Name: phoenix_kit_ai_endpoints_sort_order_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_ai_endpoints_sort_order_idx ON pk_sqv_s1a.phoenix_kit_ai_endpoints USING btree (sort_order);


--
-- Name: phoenix_kit_ai_endpoints_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX phoenix_kit_ai_endpoints_uuid_idx ON pk_sqv_s1a.phoenix_kit_ai_endpoints USING btree (uuid);


--
-- Name: phoenix_kit_ai_prompts_enabled_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_ai_prompts_enabled_idx ON pk_sqv_s1a.phoenix_kit_ai_prompts USING btree (enabled);


--
-- Name: phoenix_kit_ai_prompts_name_uidx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX phoenix_kit_ai_prompts_name_uidx ON pk_sqv_s1a.phoenix_kit_ai_prompts USING btree (name);


--
-- Name: phoenix_kit_ai_prompts_slug_uidx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX phoenix_kit_ai_prompts_slug_uidx ON pk_sqv_s1a.phoenix_kit_ai_prompts USING btree (slug);


--
-- Name: phoenix_kit_ai_prompts_sort_order_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_ai_prompts_sort_order_idx ON pk_sqv_s1a.phoenix_kit_ai_prompts USING btree (sort_order);


--
-- Name: phoenix_kit_ai_prompts_usage_count_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_ai_prompts_usage_count_idx ON pk_sqv_s1a.phoenix_kit_ai_prompts USING btree (usage_count);


--
-- Name: phoenix_kit_ai_prompts_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX phoenix_kit_ai_prompts_uuid_idx ON pk_sqv_s1a.phoenix_kit_ai_prompts USING btree (uuid);


--
-- Name: phoenix_kit_ai_prompts_uuid_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX phoenix_kit_ai_prompts_uuid_index ON pk_sqv_s1a.phoenix_kit_ai_prompts USING btree (uuid);


--
-- Name: phoenix_kit_ai_requests_account_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_ai_requests_account_uuid_idx ON pk_sqv_s1a.phoenix_kit_ai_requests USING btree (account_uuid);


--
-- Name: phoenix_kit_ai_requests_endpoint_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_ai_requests_endpoint_uuid_idx ON pk_sqv_s1a.phoenix_kit_ai_requests USING btree (endpoint_uuid);


--
-- Name: phoenix_kit_ai_requests_inserted_at_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_ai_requests_inserted_at_idx ON pk_sqv_s1a.phoenix_kit_ai_requests USING btree (inserted_at);


--
-- Name: phoenix_kit_ai_requests_model_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_ai_requests_model_idx ON pk_sqv_s1a.phoenix_kit_ai_requests USING btree (model);


--
-- Name: phoenix_kit_ai_requests_prompt_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_ai_requests_prompt_uuid_idx ON pk_sqv_s1a.phoenix_kit_ai_requests USING btree (prompt_uuid);


--
-- Name: phoenix_kit_ai_requests_status_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_ai_requests_status_idx ON pk_sqv_s1a.phoenix_kit_ai_requests USING btree (status);


--
-- Name: phoenix_kit_ai_requests_user_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_ai_requests_user_uuid_idx ON pk_sqv_s1a.phoenix_kit_ai_requests USING btree (user_uuid);


--
-- Name: phoenix_kit_ai_requests_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX phoenix_kit_ai_requests_uuid_idx ON pk_sqv_s1a.phoenix_kit_ai_requests USING btree (uuid);


--
-- Name: phoenix_kit_annotations_creator_uuid_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_annotations_creator_uuid_index ON pk_sqv_s1a.phoenix_kit_annotations USING btree (creator_uuid) WHERE (creator_uuid IS NOT NULL);


--
-- Name: phoenix_kit_annotations_file_uuid_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_annotations_file_uuid_index ON pk_sqv_s1a.phoenix_kit_annotations USING btree (file_uuid);


--
-- Name: phoenix_kit_audit_logs_action_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_audit_logs_action_index ON pk_sqv_s1a.phoenix_kit_audit_logs USING btree (action);


--
-- Name: phoenix_kit_audit_logs_action_inserted_at_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_audit_logs_action_inserted_at_index ON pk_sqv_s1a.phoenix_kit_audit_logs USING btree (action, inserted_at);


--
-- Name: phoenix_kit_audit_logs_admin_user_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_audit_logs_admin_user_uuid_idx ON pk_sqv_s1a.phoenix_kit_audit_logs USING btree (admin_user_uuid);


--
-- Name: phoenix_kit_audit_logs_inserted_at_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_audit_logs_inserted_at_index ON pk_sqv_s1a.phoenix_kit_audit_logs USING btree (inserted_at);


--
-- Name: phoenix_kit_audit_logs_target_user_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_audit_logs_target_user_uuid_idx ON pk_sqv_s1a.phoenix_kit_audit_logs USING btree (target_user_uuid);


--
-- Name: phoenix_kit_audit_logs_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX phoenix_kit_audit_logs_uuid_idx ON pk_sqv_s1a.phoenix_kit_audit_logs USING btree (uuid);


--
-- Name: phoenix_kit_billing_profiles_user_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_billing_profiles_user_uuid_idx ON pk_sqv_s1a.phoenix_kit_billing_profiles USING btree (user_uuid);


--
-- Name: phoenix_kit_billing_profiles_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX phoenix_kit_billing_profiles_uuid_idx ON pk_sqv_s1a.phoenix_kit_billing_profiles USING btree (uuid);


--
-- Name: phoenix_kit_buckets_enabled_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_buckets_enabled_index ON pk_sqv_s1a.phoenix_kit_buckets USING btree (enabled);


--
-- Name: phoenix_kit_buckets_provider_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_buckets_provider_index ON pk_sqv_s1a.phoenix_kit_buckets USING btree (provider);


--
-- Name: phoenix_kit_cat_catalogues_folder_uuid_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_cat_catalogues_folder_uuid_index ON pk_sqv_s1a.phoenix_kit_cat_catalogues USING btree (folder_uuid);


--
-- Name: phoenix_kit_cat_catalogues_kind_smart_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_cat_catalogues_kind_smart_index ON pk_sqv_s1a.phoenix_kit_cat_catalogues USING btree (uuid) WHERE ((kind)::text = 'smart'::text);


--
-- Name: phoenix_kit_cat_catalogues_status_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_cat_catalogues_status_index ON pk_sqv_s1a.phoenix_kit_cat_catalogues USING btree (status);


--
-- Name: phoenix_kit_cat_categories_catalogue_uuid_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_cat_categories_catalogue_uuid_index ON pk_sqv_s1a.phoenix_kit_cat_categories USING btree (catalogue_uuid);


--
-- Name: phoenix_kit_cat_categories_catalogue_uuid_position_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_cat_categories_catalogue_uuid_position_index ON pk_sqv_s1a.phoenix_kit_cat_categories USING btree (catalogue_uuid, "position");


--
-- Name: phoenix_kit_cat_categories_parent_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_cat_categories_parent_index ON pk_sqv_s1a.phoenix_kit_cat_categories USING btree (parent_uuid);


--
-- Name: phoenix_kit_cat_categories_status_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_cat_categories_status_index ON pk_sqv_s1a.phoenix_kit_cat_categories USING btree (status);


--
-- Name: phoenix_kit_cat_folders_parent_uuid_position_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_cat_folders_parent_uuid_position_index ON pk_sqv_s1a.phoenix_kit_cat_folders USING btree (parent_uuid, "position");


--
-- Name: phoenix_kit_cat_folders_status_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_cat_folders_status_index ON pk_sqv_s1a.phoenix_kit_cat_folders USING btree (status);


--
-- Name: phoenix_kit_cat_item_catalogue_rules_item_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_cat_item_catalogue_rules_item_index ON pk_sqv_s1a.phoenix_kit_cat_item_catalogue_rules USING btree (item_uuid);


--
-- Name: phoenix_kit_cat_item_catalogue_rules_pair_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX phoenix_kit_cat_item_catalogue_rules_pair_index ON pk_sqv_s1a.phoenix_kit_cat_item_catalogue_rules USING btree (item_uuid, referenced_catalogue_uuid);


--
-- Name: phoenix_kit_cat_item_catalogue_rules_referenced_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_cat_item_catalogue_rules_referenced_index ON pk_sqv_s1a.phoenix_kit_cat_item_catalogue_rules USING btree (referenced_catalogue_uuid);


--
-- Name: phoenix_kit_cat_item_supplier_info_item_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_cat_item_supplier_info_item_index ON pk_sqv_s1a.phoenix_kit_cat_item_supplier_info USING btree (item_uuid);


--
-- Name: phoenix_kit_cat_item_supplier_info_primary_uniq; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX phoenix_kit_cat_item_supplier_info_primary_uniq ON pk_sqv_s1a.phoenix_kit_cat_item_supplier_info USING btree (item_uuid) WHERE is_primary;


--
-- Name: phoenix_kit_cat_item_supplier_info_supplier_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_cat_item_supplier_info_supplier_index ON pk_sqv_s1a.phoenix_kit_cat_item_supplier_info USING btree (supplier_uuid);


--
-- Name: phoenix_kit_cat_items_catalogue_uuid_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_cat_items_catalogue_uuid_index ON pk_sqv_s1a.phoenix_kit_cat_items USING btree (catalogue_uuid);


--
-- Name: phoenix_kit_cat_items_catalogue_uuid_status_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_cat_items_catalogue_uuid_status_index ON pk_sqv_s1a.phoenix_kit_cat_items USING btree (catalogue_uuid, status);


--
-- Name: phoenix_kit_cat_items_category_uuid_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_cat_items_category_uuid_index ON pk_sqv_s1a.phoenix_kit_cat_items USING btree (category_uuid);


--
-- Name: phoenix_kit_cat_items_manufacturer_uuid_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_cat_items_manufacturer_uuid_index ON pk_sqv_s1a.phoenix_kit_cat_items USING btree (manufacturer_uuid);


--
-- Name: phoenix_kit_cat_items_primary_supplier_uuid_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_cat_items_primary_supplier_uuid_index ON pk_sqv_s1a.phoenix_kit_cat_items USING btree (primary_supplier_uuid) WHERE (primary_supplier_uuid IS NOT NULL);


--
-- Name: phoenix_kit_cat_items_status_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_cat_items_status_index ON pk_sqv_s1a.phoenix_kit_cat_items USING btree (status);


--
-- Name: phoenix_kit_cat_manufacturer_suppliers_manufacturer_uuid_suppli; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX phoenix_kit_cat_manufacturer_suppliers_manufacturer_uuid_suppli ON pk_sqv_s1a.phoenix_kit_cat_manufacturer_suppliers USING btree (manufacturer_uuid, supplier_uuid);


--
-- Name: phoenix_kit_cat_manufacturers_status_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_cat_manufacturers_status_index ON pk_sqv_s1a.phoenix_kit_cat_manufacturers USING btree (status);


--
-- Name: phoenix_kit_cat_pdf_extractions_extraction_status_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_cat_pdf_extractions_extraction_status_index ON pk_sqv_s1a.phoenix_kit_cat_pdf_extractions USING btree (extraction_status);


--
-- Name: phoenix_kit_cat_pdf_page_contents_text_trgm_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_cat_pdf_page_contents_text_trgm_index ON pk_sqv_s1a.phoenix_kit_cat_pdf_page_contents USING gin (text public.gin_trgm_ops);


--
-- Name: phoenix_kit_cat_pdf_pages_content_hash_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_cat_pdf_pages_content_hash_index ON pk_sqv_s1a.phoenix_kit_cat_pdf_pages USING btree (content_hash);


--
-- Name: phoenix_kit_cat_pdfs_file_uuid_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_cat_pdfs_file_uuid_index ON pk_sqv_s1a.phoenix_kit_cat_pdfs USING btree (file_uuid);


--
-- Name: phoenix_kit_cat_pdfs_status_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_cat_pdfs_status_index ON pk_sqv_s1a.phoenix_kit_cat_pdfs USING btree (status);


--
-- Name: phoenix_kit_cat_suppliers_status_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_cat_suppliers_status_index ON pk_sqv_s1a.phoenix_kit_cat_suppliers USING btree (status);


--
-- Name: phoenix_kit_comment_dislikes_comment_id_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_comment_dislikes_comment_id_index ON pk_sqv_s1a.phoenix_kit_comment_dislikes USING btree (comment_uuid);


--
-- Name: phoenix_kit_comment_dislikes_user_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_comment_dislikes_user_uuid_idx ON pk_sqv_s1a.phoenix_kit_comment_dislikes USING btree (user_uuid);


--
-- Name: phoenix_kit_comment_likes_comment_id_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_comment_likes_comment_id_index ON pk_sqv_s1a.phoenix_kit_comment_likes USING btree (comment_uuid);


--
-- Name: phoenix_kit_comment_likes_user_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_comment_likes_user_uuid_idx ON pk_sqv_s1a.phoenix_kit_comment_likes USING btree (user_uuid);


--
-- Name: phoenix_kit_comment_media_comment_position_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX phoenix_kit_comment_media_comment_position_index ON pk_sqv_s1a.phoenix_kit_comment_media USING btree (comment_uuid, "position");


--
-- Name: phoenix_kit_comment_media_file_uuid_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_comment_media_file_uuid_index ON pk_sqv_s1a.phoenix_kit_comment_media USING btree (file_uuid);


--
-- Name: phoenix_kit_comments_dislikes_user_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_comments_dislikes_user_uuid_idx ON pk_sqv_s1a.phoenix_kit_comments_dislikes USING btree (user_uuid);


--
-- Name: phoenix_kit_comments_likes_user_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_comments_likes_user_uuid_idx ON pk_sqv_s1a.phoenix_kit_comments_likes USING btree (user_uuid);


--
-- Name: phoenix_kit_comments_user_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_comments_user_uuid_idx ON pk_sqv_s1a.phoenix_kit_comments USING btree (user_uuid);


--
-- Name: phoenix_kit_consent_logs_inserted_at_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_consent_logs_inserted_at_idx ON pk_sqv_s1a.phoenix_kit_consent_logs USING btree (inserted_at);


--
-- Name: phoenix_kit_consent_logs_session_id_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_consent_logs_session_id_idx ON pk_sqv_s1a.phoenix_kit_consent_logs USING btree (session_id);


--
-- Name: phoenix_kit_consent_logs_session_type_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_consent_logs_session_type_idx ON pk_sqv_s1a.phoenix_kit_consent_logs USING btree (session_id, consent_type);


--
-- Name: phoenix_kit_consent_logs_type_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_consent_logs_type_idx ON pk_sqv_s1a.phoenix_kit_consent_logs USING btree (consent_type);


--
-- Name: phoenix_kit_consent_logs_user_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_consent_logs_user_uuid_idx ON pk_sqv_s1a.phoenix_kit_consent_logs USING btree (user_uuid);


--
-- Name: phoenix_kit_consent_logs_uuid_unique_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX phoenix_kit_consent_logs_uuid_unique_index ON pk_sqv_s1a.phoenix_kit_consent_logs USING btree (uuid);


--
-- Name: phoenix_kit_crm_party_roles_role_active_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_crm_party_roles_role_active_idx ON pk_sqv_s1a.phoenix_kit_crm_party_roles USING btree (role, is_active);


--
-- Name: phoenix_kit_crm_party_roles_roleable_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_crm_party_roles_roleable_idx ON pk_sqv_s1a.phoenix_kit_crm_party_roles USING btree (roleable_type, roleable_uuid);


--
-- Name: phoenix_kit_crm_party_roles_uniq; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX phoenix_kit_crm_party_roles_uniq ON pk_sqv_s1a.phoenix_kit_crm_party_roles USING btree (roleable_type, roleable_uuid, role);


--
-- Name: phoenix_kit_currencies_code_uidx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX phoenix_kit_currencies_code_uidx ON pk_sqv_s1a.phoenix_kit_currencies USING btree (code);


--
-- Name: phoenix_kit_currencies_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX phoenix_kit_currencies_uuid_idx ON pk_sqv_s1a.phoenix_kit_currencies USING btree (uuid);


--
-- Name: phoenix_kit_dashboards_owner_slug_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX phoenix_kit_dashboards_owner_slug_index ON pk_sqv_s1a.phoenix_kit_dashboards USING btree (owner_user_uuid, slug);


--
-- Name: phoenix_kit_db_sync_connections_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX phoenix_kit_db_sync_connections_uuid_idx ON pk_sqv_s1a.phoenix_kit_sync_connections USING btree (uuid);


--
-- Name: phoenix_kit_db_sync_transfers_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX phoenix_kit_db_sync_transfers_uuid_idx ON pk_sqv_s1a.phoenix_kit_sync_transfers USING btree (uuid);


--
-- Name: phoenix_kit_doc_categories_position_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_doc_categories_position_index ON pk_sqv_s1a.phoenix_kit_doc_categories USING btree ("position");


--
-- Name: phoenix_kit_doc_categories_status_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_doc_categories_status_index ON pk_sqv_s1a.phoenix_kit_doc_categories USING btree (status);


--
-- Name: phoenix_kit_doc_document_sections_doc_position_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX phoenix_kit_doc_document_sections_doc_position_index ON pk_sqv_s1a.phoenix_kit_doc_document_sections USING btree (document_uuid, "position");


--
-- Name: phoenix_kit_doc_document_sections_document_uuid_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_doc_document_sections_document_uuid_index ON pk_sqv_s1a.phoenix_kit_doc_document_sections USING btree (document_uuid);


--
-- Name: phoenix_kit_doc_documents_category_uuid_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_doc_documents_category_uuid_index ON pk_sqv_s1a.phoenix_kit_doc_documents USING btree (category_uuid);


--
-- Name: phoenix_kit_doc_documents_google_doc_id_unique_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX phoenix_kit_doc_documents_google_doc_id_unique_idx ON pk_sqv_s1a.phoenix_kit_doc_documents USING btree (google_doc_id) WHERE (google_doc_id IS NOT NULL);


--
-- Name: phoenix_kit_doc_documents_status_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_doc_documents_status_index ON pk_sqv_s1a.phoenix_kit_doc_documents USING btree (status);


--
-- Name: phoenix_kit_doc_documents_template_uuid_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_doc_documents_template_uuid_index ON pk_sqv_s1a.phoenix_kit_doc_documents USING btree (template_uuid);


--
-- Name: phoenix_kit_doc_documents_type_uuid_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_doc_documents_type_uuid_index ON pk_sqv_s1a.phoenix_kit_doc_documents USING btree (type_uuid);


--
-- Name: phoenix_kit_doc_headers_footers_type_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_doc_headers_footers_type_index ON pk_sqv_s1a.phoenix_kit_doc_headers_footers USING btree (type);


--
-- Name: phoenix_kit_doc_template_presets_scope_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_doc_template_presets_scope_index ON pk_sqv_s1a.phoenix_kit_doc_template_presets USING btree (scope_type, scope_id);


--
-- Name: phoenix_kit_doc_templates_category_uuid_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_doc_templates_category_uuid_index ON pk_sqv_s1a.phoenix_kit_doc_templates USING btree (category_uuid);


--
-- Name: phoenix_kit_doc_templates_google_doc_id_unique_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX phoenix_kit_doc_templates_google_doc_id_unique_idx ON pk_sqv_s1a.phoenix_kit_doc_templates USING btree (google_doc_id) WHERE (google_doc_id IS NOT NULL);


--
-- Name: phoenix_kit_doc_templates_slug_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX phoenix_kit_doc_templates_slug_index ON pk_sqv_s1a.phoenix_kit_doc_templates USING btree (slug);


--
-- Name: phoenix_kit_doc_templates_status_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_doc_templates_status_index ON pk_sqv_s1a.phoenix_kit_doc_templates USING btree (status);


--
-- Name: phoenix_kit_doc_templates_type_uuid_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_doc_templates_type_uuid_index ON pk_sqv_s1a.phoenix_kit_doc_templates USING btree (type_uuid);


--
-- Name: phoenix_kit_doc_types_category_uuid_position_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_doc_types_category_uuid_position_index ON pk_sqv_s1a.phoenix_kit_doc_types USING btree (category_uuid, "position");


--
-- Name: phoenix_kit_doc_types_status_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_doc_types_status_index ON pk_sqv_s1a.phoenix_kit_doc_types USING btree (status);


--
-- Name: phoenix_kit_email_blocklist_email_expires_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_email_blocklist_email_expires_idx ON pk_sqv_s1a.phoenix_kit_email_blocklist USING btree (email, expires_at);


--
-- Name: phoenix_kit_email_blocklist_email_uidx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX phoenix_kit_email_blocklist_email_uidx ON pk_sqv_s1a.phoenix_kit_email_blocklist USING btree (email);


--
-- Name: phoenix_kit_email_blocklist_expires_at_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_email_blocklist_expires_at_idx ON pk_sqv_s1a.phoenix_kit_email_blocklist USING btree (expires_at);


--
-- Name: phoenix_kit_email_blocklist_reason_inserted_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_email_blocklist_reason_inserted_idx ON pk_sqv_s1a.phoenix_kit_email_blocklist USING btree (reason, inserted_at);


--
-- Name: phoenix_kit_email_blocklist_user_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_email_blocklist_user_uuid_idx ON pk_sqv_s1a.phoenix_kit_email_blocklist USING btree (user_uuid);


--
-- Name: phoenix_kit_email_blocklist_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX phoenix_kit_email_blocklist_uuid_idx ON pk_sqv_s1a.phoenix_kit_email_blocklist USING btree (uuid);


--
-- Name: phoenix_kit_email_events_email_log_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_email_events_email_log_uuid_idx ON pk_sqv_s1a.phoenix_kit_email_events USING btree (email_log_uuid);


--
-- Name: phoenix_kit_email_events_log_uuid_event_type_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX phoenix_kit_email_events_log_uuid_event_type_index ON pk_sqv_s1a.phoenix_kit_email_events USING btree (email_log_uuid, event_type) WHERE ((event_type)::text <> ALL ((ARRAY['open'::character varying, 'click'::character varying])::text[]));


--
-- Name: phoenix_kit_email_events_log_uuid_type_occurred_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX phoenix_kit_email_events_log_uuid_type_occurred_index ON pk_sqv_s1a.phoenix_kit_email_events USING btree (email_log_uuid, event_type, occurred_at) WHERE ((event_type)::text = ANY ((ARRAY['open'::character varying, 'click'::character varying])::text[]));


--
-- Name: phoenix_kit_email_events_occurred_at_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_email_events_occurred_at_idx ON pk_sqv_s1a.phoenix_kit_email_events USING btree (occurred_at);


--
-- Name: phoenix_kit_email_events_type_occurred_at_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_email_events_type_occurred_at_idx ON pk_sqv_s1a.phoenix_kit_email_events USING btree (event_type, occurred_at);


--
-- Name: phoenix_kit_email_events_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX phoenix_kit_email_events_uuid_idx ON pk_sqv_s1a.phoenix_kit_email_events USING btree (uuid);


--
-- Name: phoenix_kit_email_logs_aws_message_id_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX phoenix_kit_email_logs_aws_message_id_index ON pk_sqv_s1a.phoenix_kit_email_logs USING btree (aws_message_id) WHERE (aws_message_id IS NOT NULL);


--
-- Name: phoenix_kit_email_logs_aws_message_id_uidx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX phoenix_kit_email_logs_aws_message_id_uidx ON pk_sqv_s1a.phoenix_kit_email_logs USING btree (aws_message_id) WHERE (aws_message_id IS NOT NULL);


--
-- Name: phoenix_kit_email_logs_campaign_id_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_email_logs_campaign_id_idx ON pk_sqv_s1a.phoenix_kit_email_logs USING btree (campaign_id);


--
-- Name: phoenix_kit_email_logs_campaign_id_trgm_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_email_logs_campaign_id_trgm_index ON pk_sqv_s1a.phoenix_kit_email_logs USING gin (campaign_id public.gin_trgm_ops);


--
-- Name: phoenix_kit_email_logs_compress_scan_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_email_logs_compress_scan_index ON pk_sqv_s1a.phoenix_kit_email_logs USING btree (sent_at) WHERE (body_full IS NOT NULL);


--
-- Name: phoenix_kit_email_logs_message_id_uidx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX phoenix_kit_email_logs_message_id_uidx ON pk_sqv_s1a.phoenix_kit_email_logs USING btree (message_id);


--
-- Name: phoenix_kit_email_logs_message_ids_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_email_logs_message_ids_idx ON pk_sqv_s1a.phoenix_kit_email_logs USING btree (message_id, aws_message_id);


--
-- Name: phoenix_kit_email_logs_provider_sent_at_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_email_logs_provider_sent_at_idx ON pk_sqv_s1a.phoenix_kit_email_logs USING btree (provider, sent_at);


--
-- Name: phoenix_kit_email_logs_sent_at_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_email_logs_sent_at_idx ON pk_sqv_s1a.phoenix_kit_email_logs USING btree (sent_at);


--
-- Name: phoenix_kit_email_logs_status_sent_at_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_email_logs_status_sent_at_idx ON pk_sqv_s1a.phoenix_kit_email_logs USING btree (status, sent_at);


--
-- Name: phoenix_kit_email_logs_subject_trgm_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_email_logs_subject_trgm_index ON pk_sqv_s1a.phoenix_kit_email_logs USING gin (subject public.gin_trgm_ops);


--
-- Name: phoenix_kit_email_logs_template_clicked_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_email_logs_template_clicked_index ON pk_sqv_s1a.phoenix_kit_email_logs USING btree (template_name, clicked_at) WHERE (clicked_at IS NOT NULL);


--
-- Name: phoenix_kit_email_logs_template_name_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_email_logs_template_name_idx ON pk_sqv_s1a.phoenix_kit_email_logs USING btree (template_name);


--
-- Name: phoenix_kit_email_logs_template_opened_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_email_logs_template_opened_index ON pk_sqv_s1a.phoenix_kit_email_logs USING btree (template_name, opened_at) WHERE (opened_at IS NOT NULL);


--
-- Name: phoenix_kit_email_logs_to_sent_at_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_email_logs_to_sent_at_idx ON pk_sqv_s1a.phoenix_kit_email_logs USING btree ("to", sent_at);


--
-- Name: phoenix_kit_email_logs_to_trgm_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_email_logs_to_trgm_index ON pk_sqv_s1a.phoenix_kit_email_logs USING gin ("to" public.gin_trgm_ops);


--
-- Name: phoenix_kit_email_logs_user_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_email_logs_user_uuid_idx ON pk_sqv_s1a.phoenix_kit_email_logs USING btree (user_uuid);


--
-- Name: phoenix_kit_email_logs_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX phoenix_kit_email_logs_uuid_idx ON pk_sqv_s1a.phoenix_kit_email_logs USING btree (uuid);


--
-- Name: phoenix_kit_email_metrics_date_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_email_metrics_date_idx ON pk_sqv_s1a.phoenix_kit_email_metrics USING btree (metric_date);


--
-- Name: phoenix_kit_email_metrics_key_date_uidx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX phoenix_kit_email_metrics_key_date_uidx ON pk_sqv_s1a.phoenix_kit_email_metrics USING btree (metric_key, metric_date);


--
-- Name: phoenix_kit_email_metrics_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX phoenix_kit_email_metrics_uuid_idx ON pk_sqv_s1a.phoenix_kit_email_metrics USING btree (uuid);


--
-- Name: phoenix_kit_email_orphaned_events_matched_log_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_email_orphaned_events_matched_log_uuid_idx ON pk_sqv_s1a.phoenix_kit_email_orphaned_events USING btree (matched_email_log_uuid);


--
-- Name: phoenix_kit_email_orphaned_events_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX phoenix_kit_email_orphaned_events_uuid_idx ON pk_sqv_s1a.phoenix_kit_email_orphaned_events USING btree (uuid);


--
-- Name: phoenix_kit_email_templates_category_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_email_templates_category_index ON pk_sqv_s1a.phoenix_kit_email_templates USING btree (category);


--
-- Name: phoenix_kit_email_templates_category_status_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_email_templates_category_status_index ON pk_sqv_s1a.phoenix_kit_email_templates USING btree (category, status);


--
-- Name: phoenix_kit_email_templates_created_by_user_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_email_templates_created_by_user_uuid_idx ON pk_sqv_s1a.phoenix_kit_email_templates USING btree (created_by_user_uuid);


--
-- Name: phoenix_kit_email_templates_inserted_at_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_email_templates_inserted_at_index ON pk_sqv_s1a.phoenix_kit_email_templates USING btree (inserted_at);


--
-- Name: phoenix_kit_email_templates_is_system_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_email_templates_is_system_index ON pk_sqv_s1a.phoenix_kit_email_templates USING btree (is_system);


--
-- Name: phoenix_kit_email_templates_last_used_at_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_email_templates_last_used_at_index ON pk_sqv_s1a.phoenix_kit_email_templates USING btree (last_used_at);


--
-- Name: phoenix_kit_email_templates_name_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX phoenix_kit_email_templates_name_index ON pk_sqv_s1a.phoenix_kit_email_templates USING btree (name);


--
-- Name: phoenix_kit_email_templates_slug_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX phoenix_kit_email_templates_slug_index ON pk_sqv_s1a.phoenix_kit_email_templates USING btree (slug);


--
-- Name: phoenix_kit_email_templates_status_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_email_templates_status_index ON pk_sqv_s1a.phoenix_kit_email_templates USING btree (status);


--
-- Name: phoenix_kit_email_templates_status_is_system_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_email_templates_status_is_system_index ON pk_sqv_s1a.phoenix_kit_email_templates USING btree (status, is_system);


--
-- Name: phoenix_kit_email_templates_updated_by_user_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_email_templates_updated_by_user_uuid_idx ON pk_sqv_s1a.phoenix_kit_email_templates USING btree (updated_by_user_uuid);


--
-- Name: phoenix_kit_email_templates_usage_count_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_email_templates_usage_count_index ON pk_sqv_s1a.phoenix_kit_email_templates USING btree (usage_count);


--
-- Name: phoenix_kit_entities_created_by_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_entities_created_by_uuid_idx ON pk_sqv_s1a.phoenix_kit_entities USING btree (created_by_uuid);


--
-- Name: phoenix_kit_entities_name_uidx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX phoenix_kit_entities_name_uidx ON pk_sqv_s1a.phoenix_kit_entities USING btree (name);


--
-- Name: phoenix_kit_entities_status_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_entities_status_idx ON pk_sqv_s1a.phoenix_kit_entities USING btree (status);


--
-- Name: phoenix_kit_entities_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX phoenix_kit_entities_uuid_idx ON pk_sqv_s1a.phoenix_kit_entities USING btree (uuid);


--
-- Name: phoenix_kit_entity_data_created_by_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_entity_data_created_by_uuid_idx ON pk_sqv_s1a.phoenix_kit_entity_data USING btree (created_by_uuid);


--
-- Name: phoenix_kit_entity_data_entity_position_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_entity_data_entity_position_idx ON pk_sqv_s1a.phoenix_kit_entity_data USING btree (entity_uuid, "position");


--
-- Name: phoenix_kit_entity_data_entity_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_entity_data_entity_uuid_idx ON pk_sqv_s1a.phoenix_kit_entity_data USING btree (entity_uuid);


--
-- Name: phoenix_kit_entity_data_parent_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_entity_data_parent_index ON pk_sqv_s1a.phoenix_kit_entity_data USING btree (parent_uuid);


--
-- Name: phoenix_kit_entity_data_slug_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_entity_data_slug_idx ON pk_sqv_s1a.phoenix_kit_entity_data USING btree (slug);


--
-- Name: phoenix_kit_entity_data_status_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_entity_data_status_idx ON pk_sqv_s1a.phoenix_kit_entity_data USING btree (status);


--
-- Name: phoenix_kit_entity_data_title_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_entity_data_title_idx ON pk_sqv_s1a.phoenix_kit_entity_data USING btree (title);


--
-- Name: phoenix_kit_entity_data_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX phoenix_kit_entity_data_uuid_idx ON pk_sqv_s1a.phoenix_kit_entity_data USING btree (uuid);


--
-- Name: phoenix_kit_file_instances_file_id_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_file_instances_file_id_index ON pk_sqv_s1a.phoenix_kit_file_instances USING btree (file_uuid);


--
-- Name: phoenix_kit_file_instances_file_uuid_variant_name_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX phoenix_kit_file_instances_file_uuid_variant_name_index ON pk_sqv_s1a.phoenix_kit_file_instances USING btree (file_uuid, variant_name);


--
-- Name: phoenix_kit_file_instances_processing_status_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_file_instances_processing_status_index ON pk_sqv_s1a.phoenix_kit_file_instances USING btree (processing_status);


--
-- Name: phoenix_kit_file_instances_variant_name_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_file_instances_variant_name_index ON pk_sqv_s1a.phoenix_kit_file_instances USING btree (variant_name);


--
-- Name: phoenix_kit_file_locations_bucket_id_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_file_locations_bucket_id_index ON pk_sqv_s1a.phoenix_kit_file_locations USING btree (bucket_uuid);


--
-- Name: phoenix_kit_file_locations_file_instance_id_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_file_locations_file_instance_id_index ON pk_sqv_s1a.phoenix_kit_file_locations USING btree (file_instance_uuid);


--
-- Name: phoenix_kit_file_locations_status_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_file_locations_status_index ON pk_sqv_s1a.phoenix_kit_file_locations USING btree (status);


--
-- Name: phoenix_kit_files_file_path_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_files_file_path_index ON pk_sqv_s1a.phoenix_kit_files USING btree (file_path);


--
-- Name: phoenix_kit_files_file_type_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_files_file_type_index ON pk_sqv_s1a.phoenix_kit_files USING btree (file_type);


--
-- Name: phoenix_kit_files_folder_uuid_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_files_folder_uuid_index ON pk_sqv_s1a.phoenix_kit_files USING btree (folder_uuid);


--
-- Name: phoenix_kit_files_inserted_at_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_files_inserted_at_index ON pk_sqv_s1a.phoenix_kit_files USING btree (inserted_at);


--
-- Name: phoenix_kit_files_parent_uuid_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_files_parent_uuid_index ON pk_sqv_s1a.phoenix_kit_files USING btree (parent_file_uuid) WHERE (parent_file_uuid IS NOT NULL);


--
-- Name: phoenix_kit_files_status_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_files_status_index ON pk_sqv_s1a.phoenix_kit_files USING btree (status);


--
-- Name: phoenix_kit_files_system_dedup_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX phoenix_kit_files_system_dedup_index ON pk_sqv_s1a.phoenix_kit_files USING btree (parent_file_uuid, file_name) WHERE (system_managed = true);


--
-- Name: phoenix_kit_files_system_managed_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_files_system_managed_index ON pk_sqv_s1a.phoenix_kit_files USING btree (inserted_at DESC) WHERE (system_managed = false);


--
-- Name: phoenix_kit_files_trashed_at_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_files_trashed_at_index ON pk_sqv_s1a.phoenix_kit_files USING btree (trashed_at) WHERE (trashed_at IS NOT NULL);


--
-- Name: phoenix_kit_files_user_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_files_user_uuid_idx ON pk_sqv_s1a.phoenix_kit_files USING btree (user_uuid);


--
-- Name: phoenix_kit_invoices_due_date_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_invoices_due_date_idx ON pk_sqv_s1a.phoenix_kit_invoices USING btree (due_date);


--
-- Name: phoenix_kit_invoices_invoice_number_uidx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX phoenix_kit_invoices_invoice_number_uidx ON pk_sqv_s1a.phoenix_kit_invoices USING btree (invoice_number);


--
-- Name: phoenix_kit_invoices_order_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_invoices_order_uuid_idx ON pk_sqv_s1a.phoenix_kit_invoices USING btree (order_uuid);


--
-- Name: phoenix_kit_invoices_status_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_invoices_status_idx ON pk_sqv_s1a.phoenix_kit_invoices USING btree (status);


--
-- Name: phoenix_kit_invoices_subscription_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_invoices_subscription_uuid_idx ON pk_sqv_s1a.phoenix_kit_invoices USING btree (subscription_uuid);


--
-- Name: phoenix_kit_invoices_user_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_invoices_user_uuid_idx ON pk_sqv_s1a.phoenix_kit_invoices USING btree (user_uuid);


--
-- Name: phoenix_kit_invoices_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX phoenix_kit_invoices_uuid_idx ON pk_sqv_s1a.phoenix_kit_invoices USING btree (uuid);


--
-- Name: phoenix_kit_known_devices_user_ip_ua_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX phoenix_kit_known_devices_user_ip_ua_index ON pk_sqv_s1a.phoenix_kit_user_known_devices USING btree (user_uuid, ip_address, user_agent_hash);


--
-- Name: phoenix_kit_location_spaces_location_uuid_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_location_spaces_location_uuid_index ON pk_sqv_s1a.phoenix_kit_location_spaces USING btree (location_uuid);


--
-- Name: phoenix_kit_location_spaces_location_uuid_parent_uuid_position_; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_location_spaces_location_uuid_parent_uuid_position_ ON pk_sqv_s1a.phoenix_kit_location_spaces USING btree (location_uuid, parent_uuid, "position");


--
-- Name: phoenix_kit_location_spaces_parent_uuid_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_location_spaces_parent_uuid_index ON pk_sqv_s1a.phoenix_kit_location_spaces USING btree (parent_uuid);


--
-- Name: phoenix_kit_location_type_assignments_location_uuid_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_location_type_assignments_location_uuid_index ON pk_sqv_s1a.phoenix_kit_location_type_assignments USING btree (location_uuid);


--
-- Name: phoenix_kit_location_type_assignments_location_uuid_location_ty; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX phoenix_kit_location_type_assignments_location_uuid_location_ty ON pk_sqv_s1a.phoenix_kit_location_type_assignments USING btree (location_uuid, location_type_uuid);


--
-- Name: phoenix_kit_location_types_status_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_location_types_status_index ON pk_sqv_s1a.phoenix_kit_location_types USING btree (status);


--
-- Name: phoenix_kit_locations_status_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_locations_status_index ON pk_sqv_s1a.phoenix_kit_locations USING btree (status);


--
-- Name: phoenix_kit_media_folder_links_file_uuid_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_media_folder_links_file_uuid_index ON pk_sqv_s1a.phoenix_kit_media_folder_links USING btree (file_uuid);


--
-- Name: phoenix_kit_media_folder_links_folder_uuid_file_uuid_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX phoenix_kit_media_folder_links_folder_uuid_file_uuid_index ON pk_sqv_s1a.phoenix_kit_media_folder_links USING btree (folder_uuid, file_uuid);


--
-- Name: phoenix_kit_media_folder_links_folder_uuid_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_media_folder_links_folder_uuid_index ON pk_sqv_s1a.phoenix_kit_media_folder_links USING btree (folder_uuid);


--
-- Name: phoenix_kit_media_folders_name_parent_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX phoenix_kit_media_folders_name_parent_idx ON pk_sqv_s1a.phoenix_kit_media_folders USING btree (name, COALESCE(parent_uuid, '00000000-0000-0000-0000-000000000000'::uuid)) WHERE (trashed_at IS NULL);


--
-- Name: phoenix_kit_media_folders_parent_uuid_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_media_folders_parent_uuid_index ON pk_sqv_s1a.phoenix_kit_media_folders USING btree (parent_uuid);


--
-- Name: phoenix_kit_media_folders_trashed_at_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_media_folders_trashed_at_index ON pk_sqv_s1a.phoenix_kit_media_folders USING btree (trashed_at) WHERE (trashed_at IS NOT NULL);


--
-- Name: phoenix_kit_media_folders_user_uuid_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_media_folders_user_uuid_index ON pk_sqv_s1a.phoenix_kit_media_folders USING btree (user_uuid);


--
-- Name: phoenix_kit_notifications_activity_recipient_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX phoenix_kit_notifications_activity_recipient_index ON pk_sqv_s1a.phoenix_kit_notifications USING btree (activity_uuid, recipient_uuid);


--
-- Name: phoenix_kit_notifications_recipient_inbox_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_notifications_recipient_inbox_index ON pk_sqv_s1a.phoenix_kit_notifications USING btree (recipient_uuid, inserted_at DESC) WHERE (dismissed_at IS NULL);


--
-- Name: phoenix_kit_oauth_providers_provider_uid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX phoenix_kit_oauth_providers_provider_uid_idx ON pk_sqv_s1a.phoenix_kit_user_oauth_providers USING btree (provider, provider_uid);


--
-- Name: phoenix_kit_oauth_providers_user_uuid_provider_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX phoenix_kit_oauth_providers_user_uuid_provider_idx ON pk_sqv_s1a.phoenix_kit_user_oauth_providers USING btree (user_uuid, provider);


--
-- Name: phoenix_kit_orders_billing_profile_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_orders_billing_profile_uuid_idx ON pk_sqv_s1a.phoenix_kit_orders USING btree (billing_profile_uuid);


--
-- Name: phoenix_kit_orders_inserted_at_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_orders_inserted_at_idx ON pk_sqv_s1a.phoenix_kit_orders USING btree (inserted_at);


--
-- Name: phoenix_kit_orders_order_number_uidx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX phoenix_kit_orders_order_number_uidx ON pk_sqv_s1a.phoenix_kit_orders USING btree (order_number);


--
-- Name: phoenix_kit_orders_payment_option_uuid_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_orders_payment_option_uuid_index ON pk_sqv_s1a.phoenix_kit_orders USING btree (payment_option_uuid);


--
-- Name: phoenix_kit_orders_status_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_orders_status_idx ON pk_sqv_s1a.phoenix_kit_orders USING btree (status);


--
-- Name: phoenix_kit_orders_user_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_orders_user_uuid_idx ON pk_sqv_s1a.phoenix_kit_orders USING btree (user_uuid);


--
-- Name: phoenix_kit_orders_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX phoenix_kit_orders_uuid_idx ON pk_sqv_s1a.phoenix_kit_orders USING btree (uuid);


--
-- Name: phoenix_kit_org_invitations_pending_unique_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX phoenix_kit_org_invitations_pending_unique_idx ON pk_sqv_s1a.phoenix_kit_organization_invitations USING btree (organization_uuid, email) WHERE ((status)::text = 'pending'::text);


--
-- Name: phoenix_kit_organization_invitations_email_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_organization_invitations_email_index ON pk_sqv_s1a.phoenix_kit_organization_invitations USING btree (email);


--
-- Name: phoenix_kit_organization_invitations_organization_uuid_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_organization_invitations_organization_uuid_index ON pk_sqv_s1a.phoenix_kit_organization_invitations USING btree (organization_uuid);


--
-- Name: phoenix_kit_organization_invitations_status_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_organization_invitations_status_index ON pk_sqv_s1a.phoenix_kit_organization_invitations USING btree (status);


--
-- Name: phoenix_kit_organization_invitations_token_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX phoenix_kit_organization_invitations_token_index ON pk_sqv_s1a.phoenix_kit_organization_invitations USING btree (token);


--
-- Name: phoenix_kit_orphaned_events_aws_id_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_orphaned_events_aws_id_idx ON pk_sqv_s1a.phoenix_kit_email_orphaned_events USING btree (aws_message_id);


--
-- Name: phoenix_kit_orphaned_events_matched_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_orphaned_events_matched_idx ON pk_sqv_s1a.phoenix_kit_email_orphaned_events USING btree (matched);


--
-- Name: phoenix_kit_orphaned_events_type_received_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_orphaned_events_type_received_idx ON pk_sqv_s1a.phoenix_kit_email_orphaned_events USING btree (event_type, received_at);


--
-- Name: phoenix_kit_payment_methods_provider_id_uidx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX phoenix_kit_payment_methods_provider_id_uidx ON pk_sqv_s1a.phoenix_kit_payment_methods USING btree (provider, provider_payment_method_id);


--
-- Name: phoenix_kit_payment_methods_user_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_payment_methods_user_uuid_idx ON pk_sqv_s1a.phoenix_kit_payment_methods USING btree (user_uuid);


--
-- Name: phoenix_kit_payment_methods_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX phoenix_kit_payment_methods_uuid_idx ON pk_sqv_s1a.phoenix_kit_payment_methods USING btree (uuid);


--
-- Name: phoenix_kit_payment_methods_uuid_unique_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX phoenix_kit_payment_methods_uuid_unique_index ON pk_sqv_s1a.phoenix_kit_payment_methods USING btree (uuid);


--
-- Name: phoenix_kit_payment_provider_configs_provider_uidx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX phoenix_kit_payment_provider_configs_provider_uidx ON pk_sqv_s1a.phoenix_kit_payment_provider_configs USING btree (provider);


--
-- Name: phoenix_kit_payment_provider_configs_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX phoenix_kit_payment_provider_configs_uuid_idx ON pk_sqv_s1a.phoenix_kit_payment_provider_configs USING btree (uuid);


--
-- Name: phoenix_kit_post_comments_depth_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_post_comments_depth_index ON pk_sqv_s1a.phoenix_kit_post_comments USING btree (depth);


--
-- Name: phoenix_kit_post_comments_parent_id_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_post_comments_parent_id_index ON pk_sqv_s1a.phoenix_kit_post_comments USING btree (parent_uuid);


--
-- Name: phoenix_kit_post_comments_post_id_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_post_comments_post_id_index ON pk_sqv_s1a.phoenix_kit_post_comments USING btree (post_uuid);


--
-- Name: phoenix_kit_post_comments_post_id_parent_id_depth_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_post_comments_post_id_parent_id_depth_index ON pk_sqv_s1a.phoenix_kit_post_comments USING btree (post_uuid, parent_uuid, depth);


--
-- Name: phoenix_kit_post_comments_status_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_post_comments_status_index ON pk_sqv_s1a.phoenix_kit_post_comments USING btree (status);


--
-- Name: phoenix_kit_post_comments_user_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_post_comments_user_uuid_idx ON pk_sqv_s1a.phoenix_kit_post_comments USING btree (user_uuid);


--
-- Name: phoenix_kit_post_dislikes_post_id_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_post_dislikes_post_id_index ON pk_sqv_s1a.phoenix_kit_post_dislikes USING btree (post_uuid);


--
-- Name: phoenix_kit_post_dislikes_user_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_post_dislikes_user_uuid_idx ON pk_sqv_s1a.phoenix_kit_post_dislikes USING btree (user_uuid);


--
-- Name: phoenix_kit_post_group_assignments_group_id_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_post_group_assignments_group_id_index ON pk_sqv_s1a.phoenix_kit_post_group_assignments USING btree (group_uuid);


--
-- Name: phoenix_kit_post_group_assignments_group_id_position_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_post_group_assignments_group_id_position_index ON pk_sqv_s1a.phoenix_kit_post_group_assignments USING btree (group_uuid, "position");


--
-- Name: phoenix_kit_post_group_assignments_position_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_post_group_assignments_position_index ON pk_sqv_s1a.phoenix_kit_post_group_assignments USING btree ("position");


--
-- Name: phoenix_kit_post_group_assignments_post_id_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_post_group_assignments_post_id_index ON pk_sqv_s1a.phoenix_kit_post_group_assignments USING btree (post_uuid);


--
-- Name: phoenix_kit_post_group_assignments_post_uuid_group_uuid_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX phoenix_kit_post_group_assignments_post_uuid_group_uuid_index ON pk_sqv_s1a.phoenix_kit_post_group_assignments USING btree (post_uuid, group_uuid);


--
-- Name: phoenix_kit_post_groups_is_public_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_post_groups_is_public_index ON pk_sqv_s1a.phoenix_kit_post_groups USING btree (is_public);


--
-- Name: phoenix_kit_post_groups_position_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_post_groups_position_index ON pk_sqv_s1a.phoenix_kit_post_groups USING btree ("position");


--
-- Name: phoenix_kit_post_groups_user_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_post_groups_user_uuid_idx ON pk_sqv_s1a.phoenix_kit_post_groups USING btree (user_uuid);


--
-- Name: phoenix_kit_post_likes_post_id_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_post_likes_post_id_index ON pk_sqv_s1a.phoenix_kit_post_likes USING btree (post_uuid);


--
-- Name: phoenix_kit_post_likes_user_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_post_likes_user_uuid_idx ON pk_sqv_s1a.phoenix_kit_post_likes USING btree (user_uuid);


--
-- Name: phoenix_kit_post_media_file_id_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_post_media_file_id_index ON pk_sqv_s1a.phoenix_kit_post_media USING btree (file_uuid);


--
-- Name: phoenix_kit_post_media_position_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_post_media_position_index ON pk_sqv_s1a.phoenix_kit_post_media USING btree ("position");


--
-- Name: phoenix_kit_post_media_post_id_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_post_media_post_id_index ON pk_sqv_s1a.phoenix_kit_post_media USING btree (post_uuid);


--
-- Name: phoenix_kit_post_media_post_uuid_position_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX phoenix_kit_post_media_post_uuid_position_index ON pk_sqv_s1a.phoenix_kit_post_media USING btree (post_uuid, "position");


--
-- Name: phoenix_kit_post_mentions_mention_type_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_post_mentions_mention_type_index ON pk_sqv_s1a.phoenix_kit_post_mentions USING btree (mention_type);


--
-- Name: phoenix_kit_post_mentions_post_id_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_post_mentions_post_id_index ON pk_sqv_s1a.phoenix_kit_post_mentions USING btree (post_uuid);


--
-- Name: phoenix_kit_post_mentions_user_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_post_mentions_user_uuid_idx ON pk_sqv_s1a.phoenix_kit_post_mentions USING btree (user_uuid);


--
-- Name: phoenix_kit_post_tag_assignments_post_id_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_post_tag_assignments_post_id_index ON pk_sqv_s1a.phoenix_kit_post_tag_assignments USING btree (post_uuid);


--
-- Name: phoenix_kit_post_tag_assignments_post_uuid_tag_uuid_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX phoenix_kit_post_tag_assignments_post_uuid_tag_uuid_index ON pk_sqv_s1a.phoenix_kit_post_tag_assignments USING btree (post_uuid, tag_uuid);


--
-- Name: phoenix_kit_post_tag_assignments_tag_id_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_post_tag_assignments_tag_id_index ON pk_sqv_s1a.phoenix_kit_post_tag_assignments USING btree (tag_uuid);


--
-- Name: phoenix_kit_post_tags_slug_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX phoenix_kit_post_tags_slug_index ON pk_sqv_s1a.phoenix_kit_post_tags USING btree (slug);


--
-- Name: phoenix_kit_post_tags_usage_count_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_post_tags_usage_count_index ON pk_sqv_s1a.phoenix_kit_post_tags USING btree (usage_count);


--
-- Name: phoenix_kit_post_views_post_id_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_post_views_post_id_index ON pk_sqv_s1a.phoenix_kit_post_views USING btree (post_uuid);


--
-- Name: phoenix_kit_post_views_post_id_viewed_at_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_post_views_post_id_viewed_at_index ON pk_sqv_s1a.phoenix_kit_post_views USING btree (post_uuid, viewed_at);


--
-- Name: phoenix_kit_post_views_session_id_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_post_views_session_id_index ON pk_sqv_s1a.phoenix_kit_post_views USING btree (session_id);


--
-- Name: phoenix_kit_post_views_user_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_post_views_user_uuid_idx ON pk_sqv_s1a.phoenix_kit_post_views USING btree (user_uuid);


--
-- Name: phoenix_kit_post_views_viewed_at_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_post_views_viewed_at_index ON pk_sqv_s1a.phoenix_kit_post_views USING btree (viewed_at);


--
-- Name: phoenix_kit_posts_published_at_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_posts_published_at_index ON pk_sqv_s1a.phoenix_kit_posts USING btree (published_at);


--
-- Name: phoenix_kit_posts_scheduled_at_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_posts_scheduled_at_index ON pk_sqv_s1a.phoenix_kit_posts USING btree (scheduled_at);


--
-- Name: phoenix_kit_posts_slug_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_posts_slug_index ON pk_sqv_s1a.phoenix_kit_posts USING btree (slug);


--
-- Name: phoenix_kit_posts_status_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_posts_status_index ON pk_sqv_s1a.phoenix_kit_posts USING btree (status);


--
-- Name: phoenix_kit_posts_status_published_at_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_posts_status_published_at_index ON pk_sqv_s1a.phoenix_kit_posts USING btree (status, published_at);


--
-- Name: phoenix_kit_posts_type_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_posts_type_index ON pk_sqv_s1a.phoenix_kit_posts USING btree (type);


--
-- Name: phoenix_kit_posts_type_status_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_posts_type_status_index ON pk_sqv_s1a.phoenix_kit_posts USING btree (type, status);


--
-- Name: phoenix_kit_posts_user_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_posts_user_uuid_idx ON pk_sqv_s1a.phoenix_kit_posts USING btree (user_uuid);


--
-- Name: phoenix_kit_project_assignments_child_project_unique; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX phoenix_kit_project_assignments_child_project_unique ON pk_sqv_s1a.phoenix_kit_project_assignments USING btree (child_project_uuid) WHERE (child_project_uuid IS NOT NULL);


--
-- Name: phoenix_kit_project_assignments_completed_by_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_project_assignments_completed_by_index ON pk_sqv_s1a.phoenix_kit_project_assignments USING btree (completed_by_uuid) WHERE (completed_by_uuid IS NOT NULL);


--
-- Name: phoenix_kit_project_assignments_department_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_project_assignments_department_index ON pk_sqv_s1a.phoenix_kit_project_assignments USING btree (assigned_department_uuid) WHERE (assigned_department_uuid IS NOT NULL);


--
-- Name: phoenix_kit_project_assignments_person_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_project_assignments_person_index ON pk_sqv_s1a.phoenix_kit_project_assignments USING btree (assigned_person_uuid) WHERE (assigned_person_uuid IS NOT NULL);


--
-- Name: phoenix_kit_project_assignments_project_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_project_assignments_project_index ON pk_sqv_s1a.phoenix_kit_project_assignments USING btree (project_uuid);


--
-- Name: phoenix_kit_project_assignments_status_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_project_assignments_status_index ON pk_sqv_s1a.phoenix_kit_project_assignments USING btree (status);


--
-- Name: phoenix_kit_project_assignments_task_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_project_assignments_task_index ON pk_sqv_s1a.phoenix_kit_project_assignments USING btree (task_uuid);


--
-- Name: phoenix_kit_project_assignments_team_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_project_assignments_team_index ON pk_sqv_s1a.phoenix_kit_project_assignments USING btree (assigned_team_uuid) WHERE (assigned_team_uuid IS NOT NULL);


--
-- Name: phoenix_kit_project_dependencies_depends_on_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_project_dependencies_depends_on_index ON pk_sqv_s1a.phoenix_kit_project_dependencies USING btree (depends_on_uuid);


--
-- Name: phoenix_kit_project_dependencies_pair_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX phoenix_kit_project_dependencies_pair_index ON pk_sqv_s1a.phoenix_kit_project_dependencies USING btree (assignment_uuid, depends_on_uuid);


--
-- Name: phoenix_kit_project_statuses_project_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_project_statuses_project_index ON pk_sqv_s1a.phoenix_kit_project_statuses USING btree (project_uuid);


--
-- Name: phoenix_kit_project_statuses_project_slug_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX phoenix_kit_project_statuses_project_slug_index ON pk_sqv_s1a.phoenix_kit_project_statuses USING btree (project_uuid, slug);


--
-- Name: phoenix_kit_project_task_deps_pair_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX phoenix_kit_project_task_deps_pair_index ON pk_sqv_s1a.phoenix_kit_project_task_dependencies USING btree (task_uuid, depends_on_task_uuid);


--
-- Name: phoenix_kit_projects_assigned_department_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_projects_assigned_department_idx ON pk_sqv_s1a.phoenix_kit_projects USING btree (assigned_department_uuid) WHERE (assigned_department_uuid IS NOT NULL);


--
-- Name: phoenix_kit_projects_assigned_person_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_projects_assigned_person_idx ON pk_sqv_s1a.phoenix_kit_projects USING btree (assigned_person_uuid) WHERE (assigned_person_uuid IS NOT NULL);


--
-- Name: phoenix_kit_projects_assigned_team_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_projects_assigned_team_idx ON pk_sqv_s1a.phoenix_kit_projects USING btree (assigned_team_uuid) WHERE (assigned_team_uuid IS NOT NULL);


--
-- Name: phoenix_kit_projects_external_id_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_projects_external_id_idx ON pk_sqv_s1a.phoenix_kit_projects USING btree (external_id) WHERE (external_id IS NOT NULL);


--
-- Name: phoenix_kit_projects_status_entity_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_projects_status_entity_idx ON pk_sqv_s1a.phoenix_kit_projects USING btree (status_entity_uuid) WHERE (status_entity_uuid IS NOT NULL);


--
-- Name: phoenix_kit_projects_status_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_projects_status_index ON pk_sqv_s1a.phoenix_kit_projects USING btree (status);


--
-- Name: phoenix_kit_projects_visible_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_projects_visible_idx ON pk_sqv_s1a.phoenix_kit_projects USING btree (inserted_at DESC) WHERE (archived_at IS NULL);


--
-- Name: phoenix_kit_referral_code_usage_code_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_referral_code_usage_code_uuid_idx ON pk_sqv_s1a.phoenix_kit_referral_code_usage USING btree (code_uuid);


--
-- Name: phoenix_kit_referral_code_usage_date_used_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_referral_code_usage_date_used_idx ON pk_sqv_s1a.phoenix_kit_referral_code_usage USING btree (date_used);


--
-- Name: phoenix_kit_referral_code_usage_used_by_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_referral_code_usage_used_by_uuid_idx ON pk_sqv_s1a.phoenix_kit_referral_code_usage USING btree (used_by_uuid);


--
-- Name: phoenix_kit_referral_code_usage_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX phoenix_kit_referral_code_usage_uuid_idx ON pk_sqv_s1a.phoenix_kit_referral_code_usage USING btree (uuid);


--
-- Name: phoenix_kit_referral_codes_beneficiary_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_referral_codes_beneficiary_uuid_idx ON pk_sqv_s1a.phoenix_kit_referral_codes USING btree (beneficiary_uuid);


--
-- Name: phoenix_kit_referral_codes_code_uidx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX phoenix_kit_referral_codes_code_uidx ON pk_sqv_s1a.phoenix_kit_referral_codes USING btree (code);


--
-- Name: phoenix_kit_referral_codes_created_by_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_referral_codes_created_by_uuid_idx ON pk_sqv_s1a.phoenix_kit_referral_codes USING btree (created_by_uuid);


--
-- Name: phoenix_kit_referral_codes_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX phoenix_kit_referral_codes_uuid_idx ON pk_sqv_s1a.phoenix_kit_referral_codes USING btree (uuid);


--
-- Name: phoenix_kit_role_assignments_user_uuid_role_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX phoenix_kit_role_assignments_user_uuid_role_uuid_idx ON pk_sqv_s1a.phoenix_kit_user_role_assignments USING btree (user_uuid, role_uuid);


--
-- Name: phoenix_kit_role_permissions_granted_by_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_role_permissions_granted_by_uuid_idx ON pk_sqv_s1a.phoenix_kit_role_permissions USING btree (granted_by_uuid);


--
-- Name: phoenix_kit_role_permissions_role_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_role_permissions_role_uuid_idx ON pk_sqv_s1a.phoenix_kit_role_permissions USING btree (role_uuid);


--
-- Name: phoenix_kit_role_permissions_role_uuid_module_key_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX phoenix_kit_role_permissions_role_uuid_module_key_idx ON pk_sqv_s1a.phoenix_kit_role_permissions USING btree (role_uuid, module_key);


--
-- Name: phoenix_kit_scheduled_jobs_created_by_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_scheduled_jobs_created_by_uuid_idx ON pk_sqv_s1a.phoenix_kit_scheduled_jobs USING btree (created_by_uuid);


--
-- Name: phoenix_kit_scheduled_jobs_job_type_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_scheduled_jobs_job_type_idx ON pk_sqv_s1a.phoenix_kit_scheduled_jobs USING btree (job_type);


--
-- Name: phoenix_kit_scheduled_jobs_priority_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_scheduled_jobs_priority_idx ON pk_sqv_s1a.phoenix_kit_scheduled_jobs USING btree (status, priority, scheduled_at);


--
-- Name: phoenix_kit_scheduled_jobs_resource_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_scheduled_jobs_resource_idx ON pk_sqv_s1a.phoenix_kit_scheduled_jobs USING btree (resource_type, resource_uuid);


--
-- Name: phoenix_kit_scheduled_jobs_status_scheduled_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_scheduled_jobs_status_scheduled_idx ON pk_sqv_s1a.phoenix_kit_scheduled_jobs USING btree (status, scheduled_at);


--
-- Name: phoenix_kit_settings_key_prefix_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_settings_key_prefix_idx ON pk_sqv_s1a.phoenix_kit_settings USING btree (key text_pattern_ops);


--
-- Name: phoenix_kit_settings_key_uidx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX phoenix_kit_settings_key_uidx ON pk_sqv_s1a.phoenix_kit_settings USING btree (key);


--
-- Name: phoenix_kit_settings_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX phoenix_kit_settings_uuid_idx ON pk_sqv_s1a.phoenix_kit_settings USING btree (uuid);


--
-- Name: phoenix_kit_shop_cart_items_cart_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_shop_cart_items_cart_uuid_idx ON pk_sqv_s1a.phoenix_kit_shop_cart_items USING btree (cart_uuid);


--
-- Name: phoenix_kit_shop_cart_items_product_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_shop_cart_items_product_uuid_idx ON pk_sqv_s1a.phoenix_kit_shop_cart_items USING btree (product_uuid);


--
-- Name: phoenix_kit_shop_cart_items_variant_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_shop_cart_items_variant_uuid_idx ON pk_sqv_s1a.phoenix_kit_shop_cart_items USING btree (variant_uuid);


--
-- Name: phoenix_kit_shop_carts_merged_into_cart_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_shop_carts_merged_into_cart_uuid_idx ON pk_sqv_s1a.phoenix_kit_shop_carts USING btree (merged_into_cart_uuid);


--
-- Name: phoenix_kit_shop_carts_payment_option_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_shop_carts_payment_option_uuid_idx ON pk_sqv_s1a.phoenix_kit_shop_carts USING btree (payment_option_uuid);


--
-- Name: phoenix_kit_shop_carts_shipping_method_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_shop_carts_shipping_method_uuid_idx ON pk_sqv_s1a.phoenix_kit_shop_carts USING btree (shipping_method_uuid);


--
-- Name: phoenix_kit_shop_carts_user_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_shop_carts_user_uuid_idx ON pk_sqv_s1a.phoenix_kit_shop_carts USING btree (user_uuid);


--
-- Name: phoenix_kit_shop_categories_featured_product_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_shop_categories_featured_product_uuid_idx ON pk_sqv_s1a.phoenix_kit_shop_categories USING btree (featured_product_uuid);


--
-- Name: phoenix_kit_shop_categories_parent_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_shop_categories_parent_uuid_idx ON pk_sqv_s1a.phoenix_kit_shop_categories USING btree (parent_uuid);


--
-- Name: phoenix_kit_shop_categories_slug_gin_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_shop_categories_slug_gin_idx ON pk_sqv_s1a.phoenix_kit_shop_categories USING gin (slug);


--
-- Name: phoenix_kit_shop_import_logs_user_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_shop_import_logs_user_uuid_idx ON pk_sqv_s1a.phoenix_kit_shop_import_logs USING btree (user_uuid);


--
-- Name: phoenix_kit_shop_products_category_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_shop_products_category_uuid_idx ON pk_sqv_s1a.phoenix_kit_shop_products USING btree (category_uuid);


--
-- Name: phoenix_kit_shop_products_created_by_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_shop_products_created_by_uuid_idx ON pk_sqv_s1a.phoenix_kit_shop_products USING btree (created_by_uuid);


--
-- Name: phoenix_kit_shop_products_slug_gin_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_shop_products_slug_gin_idx ON pk_sqv_s1a.phoenix_kit_shop_products USING gin (slug);


--
-- Name: phoenix_kit_staff_departments_name_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX phoenix_kit_staff_departments_name_index ON pk_sqv_s1a.phoenix_kit_staff_departments USING btree (lower((name)::text));


--
-- Name: phoenix_kit_staff_employments_one_open_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX phoenix_kit_staff_employments_one_open_index ON pk_sqv_s1a.phoenix_kit_staff_employments USING btree (staff_person_uuid) WHERE (employment_end_date IS NULL);


--
-- Name: phoenix_kit_staff_employments_person_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_staff_employments_person_index ON pk_sqv_s1a.phoenix_kit_staff_employments USING btree (staff_person_uuid);


--
-- Name: phoenix_kit_staff_people_active_dob_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_staff_people_active_dob_index ON pk_sqv_s1a.phoenix_kit_staff_people USING btree (date_of_birth) WHERE (((status)::text = 'active'::text) AND (date_of_birth IS NOT NULL));


--
-- Name: phoenix_kit_staff_people_primary_department_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_staff_people_primary_department_index ON pk_sqv_s1a.phoenix_kit_staff_people USING btree (primary_department_uuid);


--
-- Name: phoenix_kit_staff_people_status_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_staff_people_status_index ON pk_sqv_s1a.phoenix_kit_staff_people USING btree (status);


--
-- Name: phoenix_kit_staff_people_user_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX phoenix_kit_staff_people_user_index ON pk_sqv_s1a.phoenix_kit_staff_people USING btree (user_uuid);


--
-- Name: phoenix_kit_staff_person_skills_person_skill_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX phoenix_kit_staff_person_skills_person_skill_index ON pk_sqv_s1a.phoenix_kit_staff_person_skills USING btree (staff_person_uuid, skill_uuid);


--
-- Name: phoenix_kit_staff_person_skills_skill_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_staff_person_skills_skill_index ON pk_sqv_s1a.phoenix_kit_staff_person_skills USING btree (skill_uuid);


--
-- Name: phoenix_kit_staff_skills_lower_name_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX phoenix_kit_staff_skills_lower_name_index ON pk_sqv_s1a.phoenix_kit_staff_skills USING btree (lower((name)::text));


--
-- Name: phoenix_kit_staff_team_memberships_person_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_staff_team_memberships_person_index ON pk_sqv_s1a.phoenix_kit_staff_team_memberships USING btree (staff_person_uuid);


--
-- Name: phoenix_kit_staff_team_memberships_team_person_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX phoenix_kit_staff_team_memberships_team_person_index ON pk_sqv_s1a.phoenix_kit_staff_team_memberships USING btree (team_uuid, staff_person_uuid);


--
-- Name: phoenix_kit_staff_teams_department_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_staff_teams_department_index ON pk_sqv_s1a.phoenix_kit_staff_teams USING btree (department_uuid);


--
-- Name: phoenix_kit_staff_teams_department_name_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX phoenix_kit_staff_teams_department_name_index ON pk_sqv_s1a.phoenix_kit_staff_teams USING btree (department_uuid, lower((name)::text));


--
-- Name: phoenix_kit_storage_dimensions_enabled_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_storage_dimensions_enabled_index ON pk_sqv_s1a.phoenix_kit_storage_dimensions USING btree (enabled);


--
-- Name: phoenix_kit_storage_dimensions_name_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX phoenix_kit_storage_dimensions_name_index ON pk_sqv_s1a.phoenix_kit_storage_dimensions USING btree (name);


--
-- Name: phoenix_kit_storage_dimensions_order_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_storage_dimensions_order_index ON pk_sqv_s1a.phoenix_kit_storage_dimensions USING btree ("order");


--
-- Name: phoenix_kit_subscription_plans_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX phoenix_kit_subscription_plans_uuid_idx ON pk_sqv_s1a.phoenix_kit_subscription_types USING btree (uuid);


--
-- Name: phoenix_kit_subscription_types_slug_uidx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX phoenix_kit_subscription_types_slug_uidx ON pk_sqv_s1a.phoenix_kit_subscription_types USING btree (slug);


--
-- Name: phoenix_kit_subscription_types_uuid_unique_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX phoenix_kit_subscription_types_uuid_unique_index ON pk_sqv_s1a.phoenix_kit_subscription_types USING btree (uuid);


--
-- Name: phoenix_kit_subscriptions_billing_profile_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_subscriptions_billing_profile_uuid_idx ON pk_sqv_s1a.phoenix_kit_subscriptions USING btree (billing_profile_uuid);


--
-- Name: phoenix_kit_subscriptions_payment_method_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_subscriptions_payment_method_uuid_idx ON pk_sqv_s1a.phoenix_kit_subscriptions USING btree (payment_method_uuid);


--
-- Name: phoenix_kit_subscriptions_period_end_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_subscriptions_period_end_idx ON pk_sqv_s1a.phoenix_kit_subscriptions USING btree (current_period_end);


--
-- Name: phoenix_kit_subscriptions_provider_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_subscriptions_provider_idx ON pk_sqv_s1a.phoenix_kit_subscriptions USING btree (provider, provider_subscription_id);


--
-- Name: phoenix_kit_subscriptions_status_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_subscriptions_status_idx ON pk_sqv_s1a.phoenix_kit_subscriptions USING btree (status);


--
-- Name: phoenix_kit_subscriptions_subscription_type_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_subscriptions_subscription_type_uuid_idx ON pk_sqv_s1a.phoenix_kit_subscriptions USING btree (subscription_type_uuid) WHERE (subscription_type_uuid IS NOT NULL);


--
-- Name: phoenix_kit_subscriptions_user_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_subscriptions_user_uuid_idx ON pk_sqv_s1a.phoenix_kit_subscriptions USING btree (user_uuid);


--
-- Name: phoenix_kit_subscriptions_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX phoenix_kit_subscriptions_uuid_idx ON pk_sqv_s1a.phoenix_kit_subscriptions USING btree (uuid);


--
-- Name: phoenix_kit_sync_connections_approved_by_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_sync_connections_approved_by_uuid_idx ON pk_sqv_s1a.phoenix_kit_sync_connections USING btree (approved_by_uuid);


--
-- Name: phoenix_kit_sync_connections_created_by_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_sync_connections_created_by_uuid_idx ON pk_sqv_s1a.phoenix_kit_sync_connections USING btree (created_by_uuid);


--
-- Name: phoenix_kit_sync_connections_direction_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_sync_connections_direction_idx ON pk_sqv_s1a.phoenix_kit_sync_connections USING btree (direction);


--
-- Name: phoenix_kit_sync_connections_expires_at_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_sync_connections_expires_at_idx ON pk_sqv_s1a.phoenix_kit_sync_connections USING btree (expires_at);


--
-- Name: phoenix_kit_sync_connections_revoked_by_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_sync_connections_revoked_by_uuid_idx ON pk_sqv_s1a.phoenix_kit_sync_connections USING btree (revoked_by_uuid);


--
-- Name: phoenix_kit_sync_connections_site_direction_uidx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX phoenix_kit_sync_connections_site_direction_uidx ON pk_sqv_s1a.phoenix_kit_sync_connections USING btree (site_url, direction);


--
-- Name: phoenix_kit_sync_connections_status_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_sync_connections_status_idx ON pk_sqv_s1a.phoenix_kit_sync_connections USING btree (status);


--
-- Name: phoenix_kit_sync_connections_suspended_by_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_sync_connections_suspended_by_uuid_idx ON pk_sqv_s1a.phoenix_kit_sync_connections USING btree (suspended_by_uuid);


--
-- Name: phoenix_kit_sync_transfers_approval_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_sync_transfers_approval_idx ON pk_sqv_s1a.phoenix_kit_sync_transfers USING btree (requires_approval, status);


--
-- Name: phoenix_kit_sync_transfers_approved_by_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_sync_transfers_approved_by_uuid_idx ON pk_sqv_s1a.phoenix_kit_sync_transfers USING btree (approved_by_uuid);


--
-- Name: phoenix_kit_sync_transfers_connection_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_sync_transfers_connection_uuid_idx ON pk_sqv_s1a.phoenix_kit_sync_transfers USING btree (connection_uuid);


--
-- Name: phoenix_kit_sync_transfers_denied_by_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_sync_transfers_denied_by_uuid_idx ON pk_sqv_s1a.phoenix_kit_sync_transfers USING btree (denied_by_uuid);


--
-- Name: phoenix_kit_sync_transfers_direction_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_sync_transfers_direction_idx ON pk_sqv_s1a.phoenix_kit_sync_transfers USING btree (direction);


--
-- Name: phoenix_kit_sync_transfers_initiated_by_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_sync_transfers_initiated_by_uuid_idx ON pk_sqv_s1a.phoenix_kit_sync_transfers USING btree (initiated_by_uuid);


--
-- Name: phoenix_kit_sync_transfers_inserted_at_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_sync_transfers_inserted_at_idx ON pk_sqv_s1a.phoenix_kit_sync_transfers USING btree (inserted_at);


--
-- Name: phoenix_kit_sync_transfers_status_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_sync_transfers_status_idx ON pk_sqv_s1a.phoenix_kit_sync_transfers USING btree (status);


--
-- Name: phoenix_kit_ticket_attachments_comment_id_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_ticket_attachments_comment_id_index ON pk_sqv_s1a.phoenix_kit_ticket_attachments USING btree (comment_uuid);


--
-- Name: phoenix_kit_ticket_attachments_file_id_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_ticket_attachments_file_id_index ON pk_sqv_s1a.phoenix_kit_ticket_attachments USING btree (file_uuid);


--
-- Name: phoenix_kit_ticket_attachments_position_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_ticket_attachments_position_index ON pk_sqv_s1a.phoenix_kit_ticket_attachments USING btree ("position");


--
-- Name: phoenix_kit_ticket_attachments_ticket_id_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_ticket_attachments_ticket_id_index ON pk_sqv_s1a.phoenix_kit_ticket_attachments USING btree (ticket_uuid);


--
-- Name: phoenix_kit_ticket_comments_is_internal_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_ticket_comments_is_internal_index ON pk_sqv_s1a.phoenix_kit_ticket_comments USING btree (is_internal);


--
-- Name: phoenix_kit_ticket_comments_parent_id_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_ticket_comments_parent_id_index ON pk_sqv_s1a.phoenix_kit_ticket_comments USING btree (parent_uuid);


--
-- Name: phoenix_kit_ticket_comments_ticket_id_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_ticket_comments_ticket_id_index ON pk_sqv_s1a.phoenix_kit_ticket_comments USING btree (ticket_uuid);


--
-- Name: phoenix_kit_ticket_comments_ticket_id_inserted_at_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_ticket_comments_ticket_id_inserted_at_index ON pk_sqv_s1a.phoenix_kit_ticket_comments USING btree (ticket_uuid, inserted_at);


--
-- Name: phoenix_kit_ticket_comments_ticket_id_is_internal_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_ticket_comments_ticket_id_is_internal_index ON pk_sqv_s1a.phoenix_kit_ticket_comments USING btree (ticket_uuid, is_internal);


--
-- Name: phoenix_kit_ticket_comments_ticket_id_parent_id_depth_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_ticket_comments_ticket_id_parent_id_depth_index ON pk_sqv_s1a.phoenix_kit_ticket_comments USING btree (ticket_uuid, parent_uuid, depth);


--
-- Name: phoenix_kit_ticket_comments_user_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_ticket_comments_user_uuid_idx ON pk_sqv_s1a.phoenix_kit_ticket_comments USING btree (user_uuid);


--
-- Name: phoenix_kit_ticket_status_history_changed_by_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_ticket_status_history_changed_by_uuid_idx ON pk_sqv_s1a.phoenix_kit_ticket_status_history USING btree (changed_by_uuid);


--
-- Name: phoenix_kit_ticket_status_history_inserted_at_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_ticket_status_history_inserted_at_index ON pk_sqv_s1a.phoenix_kit_ticket_status_history USING btree (inserted_at);


--
-- Name: phoenix_kit_ticket_status_history_ticket_id_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_ticket_status_history_ticket_id_index ON pk_sqv_s1a.phoenix_kit_ticket_status_history USING btree (ticket_uuid);


--
-- Name: phoenix_kit_ticket_status_history_ticket_id_inserted_at_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_ticket_status_history_ticket_id_inserted_at_index ON pk_sqv_s1a.phoenix_kit_ticket_status_history USING btree (ticket_uuid, inserted_at);


--
-- Name: phoenix_kit_tickets_assigned_to_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_tickets_assigned_to_uuid_idx ON pk_sqv_s1a.phoenix_kit_tickets USING btree (assigned_to_uuid);


--
-- Name: phoenix_kit_tickets_inserted_at_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_tickets_inserted_at_index ON pk_sqv_s1a.phoenix_kit_tickets USING btree (inserted_at);


--
-- Name: phoenix_kit_tickets_slug_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_tickets_slug_index ON pk_sqv_s1a.phoenix_kit_tickets USING btree (slug);


--
-- Name: phoenix_kit_tickets_status_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_tickets_status_index ON pk_sqv_s1a.phoenix_kit_tickets USING btree (status);


--
-- Name: phoenix_kit_tickets_status_inserted_at_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_tickets_status_inserted_at_index ON pk_sqv_s1a.phoenix_kit_tickets USING btree (status, inserted_at);


--
-- Name: phoenix_kit_tickets_user_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_tickets_user_uuid_idx ON pk_sqv_s1a.phoenix_kit_tickets USING btree (user_uuid);


--
-- Name: phoenix_kit_transactions_invoice_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_transactions_invoice_uuid_idx ON pk_sqv_s1a.phoenix_kit_transactions USING btree (invoice_uuid);


--
-- Name: phoenix_kit_transactions_payment_method_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_transactions_payment_method_idx ON pk_sqv_s1a.phoenix_kit_transactions USING btree (payment_method);


--
-- Name: phoenix_kit_transactions_transaction_number_uidx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX phoenix_kit_transactions_transaction_number_uidx ON pk_sqv_s1a.phoenix_kit_transactions USING btree (transaction_number);


--
-- Name: phoenix_kit_transactions_user_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_transactions_user_uuid_idx ON pk_sqv_s1a.phoenix_kit_transactions USING btree (user_uuid);


--
-- Name: phoenix_kit_transactions_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX phoenix_kit_transactions_uuid_idx ON pk_sqv_s1a.phoenix_kit_transactions USING btree (uuid);


--
-- Name: phoenix_kit_user_blocks_blocked_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_user_blocks_blocked_uuid_idx ON pk_sqv_s1a.phoenix_kit_user_blocks USING btree (blocked_uuid);


--
-- Name: phoenix_kit_user_blocks_blocker_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_user_blocks_blocker_uuid_idx ON pk_sqv_s1a.phoenix_kit_user_blocks USING btree (blocker_uuid);


--
-- Name: phoenix_kit_user_blocks_history_blocked_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_user_blocks_history_blocked_uuid_idx ON pk_sqv_s1a.phoenix_kit_user_blocks_history USING btree (blocked_uuid);


--
-- Name: phoenix_kit_user_blocks_history_blocker_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_user_blocks_history_blocker_uuid_idx ON pk_sqv_s1a.phoenix_kit_user_blocks_history USING btree (blocker_uuid);


--
-- Name: phoenix_kit_user_blocks_history_inserted_at_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_user_blocks_history_inserted_at_index ON pk_sqv_s1a.phoenix_kit_user_blocks_history USING btree (inserted_at);


--
-- Name: phoenix_kit_user_connections_history_actor_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_user_connections_history_actor_uuid_idx ON pk_sqv_s1a.phoenix_kit_user_connections_history USING btree (actor_uuid);


--
-- Name: phoenix_kit_user_connections_history_inserted_at_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_user_connections_history_inserted_at_index ON pk_sqv_s1a.phoenix_kit_user_connections_history USING btree (inserted_at);


--
-- Name: phoenix_kit_user_connections_history_user_a_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_user_connections_history_user_a_uuid_idx ON pk_sqv_s1a.phoenix_kit_user_connections_history USING btree (user_a_uuid);


--
-- Name: phoenix_kit_user_connections_history_user_b_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_user_connections_history_user_b_uuid_idx ON pk_sqv_s1a.phoenix_kit_user_connections_history USING btree (user_b_uuid);


--
-- Name: phoenix_kit_user_connections_recipient_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_user_connections_recipient_uuid_idx ON pk_sqv_s1a.phoenix_kit_user_connections USING btree (recipient_uuid);


--
-- Name: phoenix_kit_user_connections_requester_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_user_connections_requester_uuid_idx ON pk_sqv_s1a.phoenix_kit_user_connections USING btree (requester_uuid);


--
-- Name: phoenix_kit_user_connections_status_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_user_connections_status_index ON pk_sqv_s1a.phoenix_kit_user_connections USING btree (status);


--
-- Name: phoenix_kit_user_follows_followed_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_user_follows_followed_uuid_idx ON pk_sqv_s1a.phoenix_kit_user_follows USING btree (followed_uuid);


--
-- Name: phoenix_kit_user_follows_follower_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_user_follows_follower_uuid_idx ON pk_sqv_s1a.phoenix_kit_user_follows USING btree (follower_uuid);


--
-- Name: phoenix_kit_user_follows_history_followed_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_user_follows_history_followed_uuid_idx ON pk_sqv_s1a.phoenix_kit_user_follows_history USING btree (followed_uuid);


--
-- Name: phoenix_kit_user_follows_history_follower_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_user_follows_history_follower_uuid_idx ON pk_sqv_s1a.phoenix_kit_user_follows_history USING btree (follower_uuid);


--
-- Name: phoenix_kit_user_follows_history_inserted_at_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_user_follows_history_inserted_at_index ON pk_sqv_s1a.phoenix_kit_user_follows_history USING btree (inserted_at);


--
-- Name: phoenix_kit_user_known_devices_user_uuid_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_user_known_devices_user_uuid_index ON pk_sqv_s1a.phoenix_kit_user_known_devices USING btree (user_uuid);


--
-- Name: phoenix_kit_user_oauth_providers_provider_email_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_user_oauth_providers_provider_email_index ON pk_sqv_s1a.phoenix_kit_user_oauth_providers USING btree (provider_email);


--
-- Name: phoenix_kit_user_oauth_providers_provider_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_user_oauth_providers_provider_index ON pk_sqv_s1a.phoenix_kit_user_oauth_providers USING btree (provider);


--
-- Name: phoenix_kit_user_oauth_providers_user_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_user_oauth_providers_user_uuid_idx ON pk_sqv_s1a.phoenix_kit_user_oauth_providers USING btree (user_uuid);


--
-- Name: phoenix_kit_user_oauth_providers_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX phoenix_kit_user_oauth_providers_uuid_idx ON pk_sqv_s1a.phoenix_kit_user_oauth_providers USING btree (uuid);


--
-- Name: phoenix_kit_user_role_assignments_assigned_by_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_user_role_assignments_assigned_by_uuid_idx ON pk_sqv_s1a.phoenix_kit_user_role_assignments USING btree (assigned_by_uuid);


--
-- Name: phoenix_kit_user_role_assignments_role_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_user_role_assignments_role_uuid_idx ON pk_sqv_s1a.phoenix_kit_user_role_assignments USING btree (role_uuid);


--
-- Name: phoenix_kit_user_role_assignments_user_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_user_role_assignments_user_uuid_idx ON pk_sqv_s1a.phoenix_kit_user_role_assignments USING btree (user_uuid);


--
-- Name: phoenix_kit_user_role_assignments_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX phoenix_kit_user_role_assignments_uuid_idx ON pk_sqv_s1a.phoenix_kit_user_role_assignments USING btree (uuid);


--
-- Name: phoenix_kit_user_roles_name_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX phoenix_kit_user_roles_name_index ON pk_sqv_s1a.phoenix_kit_user_roles USING btree (name);


--
-- Name: phoenix_kit_user_roles_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX phoenix_kit_user_roles_uuid_idx ON pk_sqv_s1a.phoenix_kit_user_roles USING btree (uuid);


--
-- Name: phoenix_kit_users_account_type_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_users_account_type_index ON pk_sqv_s1a.phoenix_kit_users USING btree (account_type);


--
-- Name: phoenix_kit_users_email_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX phoenix_kit_users_email_index ON pk_sqv_s1a.phoenix_kit_users USING btree (email);


--
-- Name: phoenix_kit_users_organization_uuid_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_users_organization_uuid_index ON pk_sqv_s1a.phoenix_kit_users USING btree (organization_uuid);


--
-- Name: phoenix_kit_users_preferred_locale_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_users_preferred_locale_index ON pk_sqv_s1a.phoenix_kit_users USING btree (preferred_locale);


--
-- Name: phoenix_kit_users_reg_city_date_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_users_reg_city_date_idx ON pk_sqv_s1a.phoenix_kit_users USING btree (registration_city, inserted_at);


--
-- Name: phoenix_kit_users_reg_country_date_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_users_reg_country_date_idx ON pk_sqv_s1a.phoenix_kit_users USING btree (registration_country, inserted_at);


--
-- Name: phoenix_kit_users_reg_geo_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_users_reg_geo_idx ON pk_sqv_s1a.phoenix_kit_users USING btree (registration_country, registration_region, registration_city);


--
-- Name: phoenix_kit_users_reg_ip_date_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_users_reg_ip_date_idx ON pk_sqv_s1a.phoenix_kit_users USING btree (registration_ip, inserted_at);


--
-- Name: phoenix_kit_users_reg_region_date_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_users_reg_region_date_idx ON pk_sqv_s1a.phoenix_kit_users USING btree (registration_region, inserted_at);


--
-- Name: phoenix_kit_users_tokens_context_token_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX phoenix_kit_users_tokens_context_token_index ON pk_sqv_s1a.phoenix_kit_users_tokens USING btree (context, token);


--
-- Name: phoenix_kit_users_tokens_ip_address_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_users_tokens_ip_address_index ON pk_sqv_s1a.phoenix_kit_users_tokens USING btree (ip_address);


--
-- Name: phoenix_kit_users_tokens_token_ip_address_user_agent_hash_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_users_tokens_token_ip_address_user_agent_hash_index ON pk_sqv_s1a.phoenix_kit_users_tokens USING btree (token, ip_address, user_agent_hash);


--
-- Name: phoenix_kit_users_tokens_user_agent_hash_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_users_tokens_user_agent_hash_index ON pk_sqv_s1a.phoenix_kit_users_tokens USING btree (user_agent_hash);


--
-- Name: phoenix_kit_users_tokens_user_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_users_tokens_user_uuid_idx ON pk_sqv_s1a.phoenix_kit_users_tokens USING btree (user_uuid);


--
-- Name: phoenix_kit_users_tokens_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX phoenix_kit_users_tokens_uuid_idx ON pk_sqv_s1a.phoenix_kit_users_tokens USING btree (uuid);


--
-- Name: phoenix_kit_users_username_uidx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX phoenix_kit_users_username_uidx ON pk_sqv_s1a.phoenix_kit_users USING btree (username) WHERE (username IS NOT NULL);


--
-- Name: phoenix_kit_users_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX phoenix_kit_users_uuid_idx ON pk_sqv_s1a.phoenix_kit_users USING btree (uuid);


--
-- Name: phoenix_kit_version_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX phoenix_kit_version_index ON pk_sqv_s1a.phoenix_kit USING btree (version);


--
-- Name: phoenix_kit_warehouse_goods_issues_deleted_at_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_warehouse_goods_issues_deleted_at_index ON pk_sqv_s1a.phoenix_kit_warehouse_goods_issues USING btree (deleted_at);


--
-- Name: phoenix_kit_warehouse_goods_issues_inserted_at_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_warehouse_goods_issues_inserted_at_index ON pk_sqv_s1a.phoenix_kit_warehouse_goods_issues USING btree (inserted_at);


--
-- Name: phoenix_kit_warehouse_goods_issues_internal_order_uuid_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_warehouse_goods_issues_internal_order_uuid_index ON pk_sqv_s1a.phoenix_kit_warehouse_goods_issues USING btree (internal_order_uuid);


--
-- Name: phoenix_kit_warehouse_goods_issues_location_uuid_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_warehouse_goods_issues_location_uuid_index ON pk_sqv_s1a.phoenix_kit_warehouse_goods_issues USING btree (location_uuid);


--
-- Name: phoenix_kit_warehouse_goods_issues_number_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX phoenix_kit_warehouse_goods_issues_number_index ON pk_sqv_s1a.phoenix_kit_warehouse_goods_issues USING btree (number);


--
-- Name: phoenix_kit_warehouse_goods_issues_source_refs_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_warehouse_goods_issues_source_refs_index ON pk_sqv_s1a.phoenix_kit_warehouse_goods_issues USING gin (source_refs);


--
-- Name: phoenix_kit_warehouse_goods_issues_status_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_warehouse_goods_issues_status_index ON pk_sqv_s1a.phoenix_kit_warehouse_goods_issues USING btree (status);


--
-- Name: phoenix_kit_warehouse_goods_receipts_deleted_at_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_warehouse_goods_receipts_deleted_at_index ON pk_sqv_s1a.phoenix_kit_warehouse_goods_receipts USING btree (deleted_at);


--
-- Name: phoenix_kit_warehouse_goods_receipts_inserted_at_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_warehouse_goods_receipts_inserted_at_index ON pk_sqv_s1a.phoenix_kit_warehouse_goods_receipts USING btree (inserted_at);


--
-- Name: phoenix_kit_warehouse_goods_receipts_location_uuid_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_warehouse_goods_receipts_location_uuid_index ON pk_sqv_s1a.phoenix_kit_warehouse_goods_receipts USING btree (location_uuid);


--
-- Name: phoenix_kit_warehouse_goods_receipts_number_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX phoenix_kit_warehouse_goods_receipts_number_index ON pk_sqv_s1a.phoenix_kit_warehouse_goods_receipts USING btree (number);


--
-- Name: phoenix_kit_warehouse_goods_receipts_source_refs_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_warehouse_goods_receipts_source_refs_index ON pk_sqv_s1a.phoenix_kit_warehouse_goods_receipts USING gin (source_refs);


--
-- Name: phoenix_kit_warehouse_goods_receipts_status_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_warehouse_goods_receipts_status_index ON pk_sqv_s1a.phoenix_kit_warehouse_goods_receipts USING btree (status);


--
-- Name: phoenix_kit_warehouse_goods_receipts_supplier_order_uuid_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_warehouse_goods_receipts_supplier_order_uuid_index ON pk_sqv_s1a.phoenix_kit_warehouse_goods_receipts USING btree (supplier_order_uuid);


--
-- Name: phoenix_kit_warehouse_internal_orders_deleted_at_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_warehouse_internal_orders_deleted_at_index ON pk_sqv_s1a.phoenix_kit_warehouse_internal_orders USING btree (deleted_at);


--
-- Name: phoenix_kit_warehouse_internal_orders_inserted_at_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_warehouse_internal_orders_inserted_at_index ON pk_sqv_s1a.phoenix_kit_warehouse_internal_orders USING btree (inserted_at);


--
-- Name: phoenix_kit_warehouse_internal_orders_location_uuid_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_warehouse_internal_orders_location_uuid_index ON pk_sqv_s1a.phoenix_kit_warehouse_internal_orders USING btree (location_uuid);


--
-- Name: phoenix_kit_warehouse_internal_orders_number_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX phoenix_kit_warehouse_internal_orders_number_index ON pk_sqv_s1a.phoenix_kit_warehouse_internal_orders USING btree (number);


--
-- Name: phoenix_kit_warehouse_internal_orders_source_refs_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_warehouse_internal_orders_source_refs_index ON pk_sqv_s1a.phoenix_kit_warehouse_internal_orders USING gin (source_refs);


--
-- Name: phoenix_kit_warehouse_internal_orders_status_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_warehouse_internal_orders_status_index ON pk_sqv_s1a.phoenix_kit_warehouse_internal_orders USING btree (status);


--
-- Name: phoenix_kit_warehouse_inventory_documents_deleted_at_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_warehouse_inventory_documents_deleted_at_index ON pk_sqv_s1a.phoenix_kit_warehouse_inventory_documents USING btree (deleted_at);


--
-- Name: phoenix_kit_warehouse_inventory_documents_inserted_at_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_warehouse_inventory_documents_inserted_at_index ON pk_sqv_s1a.phoenix_kit_warehouse_inventory_documents USING btree (inserted_at);


--
-- Name: phoenix_kit_warehouse_inventory_documents_location_uuid_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_warehouse_inventory_documents_location_uuid_index ON pk_sqv_s1a.phoenix_kit_warehouse_inventory_documents USING btree (location_uuid);


--
-- Name: phoenix_kit_warehouse_inventory_documents_number_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX phoenix_kit_warehouse_inventory_documents_number_index ON pk_sqv_s1a.phoenix_kit_warehouse_inventory_documents USING btree (number);


--
-- Name: phoenix_kit_warehouse_inventory_documents_status_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_warehouse_inventory_documents_status_index ON pk_sqv_s1a.phoenix_kit_warehouse_inventory_documents USING btree (status);


--
-- Name: phoenix_kit_warehouse_min_stock_item_uuid_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX phoenix_kit_warehouse_min_stock_item_uuid_index ON pk_sqv_s1a.phoenix_kit_warehouse_min_stock USING btree (item_uuid);


--
-- Name: phoenix_kit_warehouse_stock_item_location_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX phoenix_kit_warehouse_stock_item_location_index ON pk_sqv_s1a.phoenix_kit_warehouse_stock USING btree (item_uuid, location_uuid);


--
-- Name: phoenix_kit_warehouse_stock_location_uuid_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_warehouse_stock_location_uuid_index ON pk_sqv_s1a.phoenix_kit_warehouse_stock USING btree (location_uuid);


--
-- Name: phoenix_kit_warehouse_supplier_orders_deleted_at_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_warehouse_supplier_orders_deleted_at_index ON pk_sqv_s1a.phoenix_kit_warehouse_supplier_orders USING btree (deleted_at);


--
-- Name: phoenix_kit_warehouse_supplier_orders_inserted_at_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_warehouse_supplier_orders_inserted_at_index ON pk_sqv_s1a.phoenix_kit_warehouse_supplier_orders USING btree (inserted_at);


--
-- Name: phoenix_kit_warehouse_supplier_orders_internal_order_uuid_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_warehouse_supplier_orders_internal_order_uuid_index ON pk_sqv_s1a.phoenix_kit_warehouse_supplier_orders USING btree (internal_order_uuid);


--
-- Name: phoenix_kit_warehouse_supplier_orders_location_uuid_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_warehouse_supplier_orders_location_uuid_index ON pk_sqv_s1a.phoenix_kit_warehouse_supplier_orders USING btree (location_uuid);


--
-- Name: phoenix_kit_warehouse_supplier_orders_number_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX phoenix_kit_warehouse_supplier_orders_number_index ON pk_sqv_s1a.phoenix_kit_warehouse_supplier_orders USING btree (number);


--
-- Name: phoenix_kit_warehouse_supplier_orders_source_refs_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_warehouse_supplier_orders_source_refs_index ON pk_sqv_s1a.phoenix_kit_warehouse_supplier_orders USING gin (source_refs);


--
-- Name: phoenix_kit_warehouse_supplier_orders_status_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_warehouse_supplier_orders_status_index ON pk_sqv_s1a.phoenix_kit_warehouse_supplier_orders USING btree (status);


--
-- Name: phoenix_kit_warehouse_supplier_orders_supplier_uuid_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_warehouse_supplier_orders_supplier_uuid_index ON pk_sqv_s1a.phoenix_kit_warehouse_supplier_orders USING btree (supplier_uuid);


--
-- Name: phoenix_kit_warehouse_transfers_deleted_at_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_warehouse_transfers_deleted_at_index ON pk_sqv_s1a.phoenix_kit_warehouse_transfers USING btree (deleted_at);


--
-- Name: phoenix_kit_warehouse_transfers_destination_location_uuid_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_warehouse_transfers_destination_location_uuid_index ON pk_sqv_s1a.phoenix_kit_warehouse_transfers USING btree (destination_location_uuid);


--
-- Name: phoenix_kit_warehouse_transfers_inserted_at_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_warehouse_transfers_inserted_at_index ON pk_sqv_s1a.phoenix_kit_warehouse_transfers USING btree (inserted_at);


--
-- Name: phoenix_kit_warehouse_transfers_number_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX phoenix_kit_warehouse_transfers_number_index ON pk_sqv_s1a.phoenix_kit_warehouse_transfers USING btree (number);


--
-- Name: phoenix_kit_warehouse_transfers_received_at_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_warehouse_transfers_received_at_index ON pk_sqv_s1a.phoenix_kit_warehouse_transfers USING btree (received_at);


--
-- Name: phoenix_kit_warehouse_transfers_shipped_at_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_warehouse_transfers_shipped_at_index ON pk_sqv_s1a.phoenix_kit_warehouse_transfers USING btree (shipped_at);


--
-- Name: phoenix_kit_warehouse_transfers_source_location_uuid_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_warehouse_transfers_source_location_uuid_index ON pk_sqv_s1a.phoenix_kit_warehouse_transfers USING btree (source_location_uuid);


--
-- Name: phoenix_kit_warehouse_transfers_source_refs_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_warehouse_transfers_source_refs_index ON pk_sqv_s1a.phoenix_kit_warehouse_transfers USING gin (source_refs);


--
-- Name: phoenix_kit_warehouse_transfers_status_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_warehouse_transfers_status_index ON pk_sqv_s1a.phoenix_kit_warehouse_transfers USING btree (status);


--
-- Name: phoenix_kit_webhook_events_processed_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE INDEX phoenix_kit_webhook_events_processed_idx ON pk_sqv_s1a.phoenix_kit_webhook_events USING btree (processed);


--
-- Name: phoenix_kit_webhook_events_provider_event_uidx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX phoenix_kit_webhook_events_provider_event_uidx ON pk_sqv_s1a.phoenix_kit_webhook_events USING btree (provider, event_id);


--
-- Name: phoenix_kit_webhook_events_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX phoenix_kit_webhook_events_uuid_idx ON pk_sqv_s1a.phoenix_kit_webhook_events USING btree (uuid);


--
-- Name: pk_sqv_s1a_phoenix_kit_ai_endpoints_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX pk_sqv_s1a_phoenix_kit_ai_endpoints_uuid_idx ON pk_sqv_s1a.phoenix_kit_ai_endpoints USING btree (uuid);


--
-- Name: pk_sqv_s1a_phoenix_kit_ai_prompts_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX pk_sqv_s1a_phoenix_kit_ai_prompts_uuid_idx ON pk_sqv_s1a.phoenix_kit_ai_prompts USING btree (uuid);


--
-- Name: pk_sqv_s1a_phoenix_kit_email_templates_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX pk_sqv_s1a_phoenix_kit_email_templates_uuid_idx ON pk_sqv_s1a.phoenix_kit_email_templates USING btree (uuid);


--
-- Name: pk_sqv_s1a_phoenix_kit_files_user_file_checksum_index; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX pk_sqv_s1a_phoenix_kit_files_user_file_checksum_index ON pk_sqv_s1a.phoenix_kit_files USING btree (user_file_checksum);


--
-- Name: pk_sqv_s1a_phoenix_kit_payment_methods_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX pk_sqv_s1a_phoenix_kit_payment_methods_uuid_idx ON pk_sqv_s1a.phoenix_kit_payment_methods USING btree (uuid);


--
-- Name: pk_sqv_s1a_phoenix_kit_payment_options_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX pk_sqv_s1a_phoenix_kit_payment_options_uuid_idx ON pk_sqv_s1a.phoenix_kit_payment_options USING btree (uuid);


--
-- Name: pk_sqv_s1a_phoenix_kit_settings_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX pk_sqv_s1a_phoenix_kit_settings_uuid_idx ON pk_sqv_s1a.phoenix_kit_settings USING btree (uuid);


--
-- Name: pk_sqv_s1a_phoenix_kit_shop_cart_items_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX pk_sqv_s1a_phoenix_kit_shop_cart_items_uuid_idx ON pk_sqv_s1a.phoenix_kit_shop_cart_items USING btree (uuid);


--
-- Name: pk_sqv_s1a_phoenix_kit_shop_carts_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX pk_sqv_s1a_phoenix_kit_shop_carts_uuid_idx ON pk_sqv_s1a.phoenix_kit_shop_carts USING btree (uuid);


--
-- Name: pk_sqv_s1a_phoenix_kit_shop_categories_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX pk_sqv_s1a_phoenix_kit_shop_categories_uuid_idx ON pk_sqv_s1a.phoenix_kit_shop_categories USING btree (uuid);


--
-- Name: pk_sqv_s1a_phoenix_kit_shop_products_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX pk_sqv_s1a_phoenix_kit_shop_products_uuid_idx ON pk_sqv_s1a.phoenix_kit_shop_products USING btree (uuid);


--
-- Name: pk_sqv_s1a_phoenix_kit_shop_shipping_methods_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX pk_sqv_s1a_phoenix_kit_shop_shipping_methods_uuid_idx ON pk_sqv_s1a.phoenix_kit_shop_shipping_methods USING btree (uuid);


--
-- Name: pk_sqv_s1a_phoenix_kit_subscription_plans_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX pk_sqv_s1a_phoenix_kit_subscription_plans_uuid_idx ON pk_sqv_s1a.phoenix_kit_subscription_types USING btree (uuid);


--
-- Name: pk_sqv_s1a_phoenix_kit_sync_connections_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX pk_sqv_s1a_phoenix_kit_sync_connections_uuid_idx ON pk_sqv_s1a.phoenix_kit_sync_connections USING btree (uuid);


--
-- Name: pk_sqv_s1a_phoenix_kit_user_role_assignments_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX pk_sqv_s1a_phoenix_kit_user_role_assignments_uuid_idx ON pk_sqv_s1a.phoenix_kit_user_role_assignments USING btree (uuid);


--
-- Name: pk_sqv_s1a_phoenix_kit_user_roles_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX pk_sqv_s1a_phoenix_kit_user_roles_uuid_idx ON pk_sqv_s1a.phoenix_kit_user_roles USING btree (uuid);


--
-- Name: pk_sqv_s1a_phoenix_kit_users_tokens_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX pk_sqv_s1a_phoenix_kit_users_tokens_uuid_idx ON pk_sqv_s1a.phoenix_kit_users_tokens USING btree (uuid);


--
-- Name: pk_sqv_s1a_phoenix_kit_users_uuid_idx; Type: INDEX; Schema: pk_sqv_s1a; Owner: -
--

CREATE UNIQUE INDEX pk_sqv_s1a_phoenix_kit_users_uuid_idx ON pk_sqv_s1a.phoenix_kit_users USING btree (uuid);


--
-- Name: phoenix_kit_admin_notes fk_admin_notes_author_uuid; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_admin_notes
    ADD CONSTRAINT fk_admin_notes_author_uuid FOREIGN KEY (author_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_users(uuid) ON DELETE CASCADE;


--
-- Name: phoenix_kit_admin_notes fk_admin_notes_user_uuid; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_admin_notes
    ADD CONSTRAINT fk_admin_notes_user_uuid FOREIGN KEY (user_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_users(uuid) ON DELETE CASCADE;


--
-- Name: phoenix_kit_ai_requests fk_ai_requests_endpoint_uuid; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_ai_requests
    ADD CONSTRAINT fk_ai_requests_endpoint_uuid FOREIGN KEY (endpoint_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_ai_endpoints(uuid) ON DELETE SET NULL;


--
-- Name: phoenix_kit_ai_requests fk_ai_requests_prompt_uuid; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_ai_requests
    ADD CONSTRAINT fk_ai_requests_prompt_uuid FOREIGN KEY (prompt_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_ai_prompts(uuid) ON DELETE SET NULL;


--
-- Name: phoenix_kit_ai_requests fk_ai_requests_user_uuid; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_ai_requests
    ADD CONSTRAINT fk_ai_requests_user_uuid FOREIGN KEY (user_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_users(uuid) ON DELETE SET NULL;


--
-- Name: phoenix_kit_billing_profiles fk_billing_profiles_user_uuid; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_billing_profiles
    ADD CONSTRAINT fk_billing_profiles_user_uuid FOREIGN KEY (user_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_users(uuid) ON DELETE SET NULL;


--
-- Name: phoenix_kit_comment_dislikes fk_comment_dislikes_user_uuid; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_comment_dislikes
    ADD CONSTRAINT fk_comment_dislikes_user_uuid FOREIGN KEY (user_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_users(uuid) ON DELETE CASCADE;


--
-- Name: phoenix_kit_comment_likes fk_comment_likes_user_uuid; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_comment_likes
    ADD CONSTRAINT fk_comment_likes_user_uuid FOREIGN KEY (user_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_users(uuid) ON DELETE CASCADE;


--
-- Name: phoenix_kit_comments_dislikes fk_comments_dislikes_comment; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_comments_dislikes
    ADD CONSTRAINT fk_comments_dislikes_comment FOREIGN KEY (comment_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_comments(uuid) ON DELETE CASCADE;


--
-- Name: phoenix_kit_comments_dislikes fk_comments_dislikes_user_uuid; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_comments_dislikes
    ADD CONSTRAINT fk_comments_dislikes_user_uuid FOREIGN KEY (user_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_users(uuid) ON DELETE CASCADE;


--
-- Name: phoenix_kit_comments_likes fk_comments_likes_comment; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_comments_likes
    ADD CONSTRAINT fk_comments_likes_comment FOREIGN KEY (comment_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_comments(uuid) ON DELETE CASCADE;


--
-- Name: phoenix_kit_comments_likes fk_comments_likes_user_uuid; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_comments_likes
    ADD CONSTRAINT fk_comments_likes_user_uuid FOREIGN KEY (user_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_users(uuid) ON DELETE CASCADE;


--
-- Name: phoenix_kit_comments fk_comments_parent; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_comments
    ADD CONSTRAINT fk_comments_parent FOREIGN KEY (parent_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_comments(uuid) ON DELETE CASCADE;


--
-- Name: phoenix_kit_comments fk_comments_user_uuid; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_comments
    ADD CONSTRAINT fk_comments_user_uuid FOREIGN KEY (user_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_users(uuid) ON DELETE SET NULL;


--
-- Name: phoenix_kit_email_events fk_email_events_email_log_uuid; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_email_events
    ADD CONSTRAINT fk_email_events_email_log_uuid FOREIGN KEY (email_log_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_email_logs(uuid) ON DELETE CASCADE;


--
-- Name: phoenix_kit_entity_data fk_entity_data_entity_uuid; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_entity_data
    ADD CONSTRAINT fk_entity_data_entity_uuid FOREIGN KEY (entity_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_entities(uuid) ON DELETE CASCADE;


--
-- Name: phoenix_kit_files fk_files_user_uuid; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_files
    ADD CONSTRAINT fk_files_user_uuid FOREIGN KEY (user_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_users(uuid) ON DELETE CASCADE;


--
-- Name: phoenix_kit_invoices fk_invoices_order_uuid; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_invoices
    ADD CONSTRAINT fk_invoices_order_uuid FOREIGN KEY (order_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_orders(uuid) ON DELETE SET NULL;


--
-- Name: phoenix_kit_invoices fk_invoices_user_uuid; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_invoices
    ADD CONSTRAINT fk_invoices_user_uuid FOREIGN KEY (user_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_users(uuid) ON DELETE RESTRICT;


--
-- Name: phoenix_kit_newsletters_broadcasts fk_newsletters_broadcasts_created_by; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_newsletters_broadcasts
    ADD CONSTRAINT fk_newsletters_broadcasts_created_by FOREIGN KEY (created_by_user_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_users(uuid) ON DELETE SET NULL;


--
-- Name: phoenix_kit_newsletters_broadcasts fk_newsletters_broadcasts_template; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_newsletters_broadcasts
    ADD CONSTRAINT fk_newsletters_broadcasts_template FOREIGN KEY (template_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_email_templates(uuid) ON DELETE SET NULL;


--
-- Name: phoenix_kit_newsletters_deliveries fk_newsletters_deliveries_broadcast; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_newsletters_deliveries
    ADD CONSTRAINT fk_newsletters_deliveries_broadcast FOREIGN KEY (broadcast_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_newsletters_broadcasts(uuid) ON DELETE CASCADE;


--
-- Name: phoenix_kit_newsletters_deliveries fk_newsletters_deliveries_user; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_newsletters_deliveries
    ADD CONSTRAINT fk_newsletters_deliveries_user FOREIGN KEY (user_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_users(uuid) ON DELETE CASCADE;


--
-- Name: phoenix_kit_orders fk_orders_billing_profile_uuid; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_orders
    ADD CONSTRAINT fk_orders_billing_profile_uuid FOREIGN KEY (billing_profile_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_billing_profiles(uuid) ON DELETE SET NULL;


--
-- Name: phoenix_kit_orders fk_orders_payment_option; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_orders
    ADD CONSTRAINT fk_orders_payment_option FOREIGN KEY (payment_option_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_payment_options(uuid) ON DELETE SET NULL;


--
-- Name: phoenix_kit_orders fk_orders_user_uuid; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_orders
    ADD CONSTRAINT fk_orders_user_uuid FOREIGN KEY (user_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_users(uuid) ON DELETE SET NULL;


--
-- Name: phoenix_kit_post_comments fk_post_comments_user_uuid; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_post_comments
    ADD CONSTRAINT fk_post_comments_user_uuid FOREIGN KEY (user_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_users(uuid) ON DELETE CASCADE;


--
-- Name: phoenix_kit_post_dislikes fk_post_dislikes_user_uuid; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_post_dislikes
    ADD CONSTRAINT fk_post_dislikes_user_uuid FOREIGN KEY (user_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_users(uuid) ON DELETE CASCADE;


--
-- Name: phoenix_kit_post_groups fk_post_groups_user_uuid; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_post_groups
    ADD CONSTRAINT fk_post_groups_user_uuid FOREIGN KEY (user_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_users(uuid) ON DELETE CASCADE;


--
-- Name: phoenix_kit_post_likes fk_post_likes_user_uuid; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_post_likes
    ADD CONSTRAINT fk_post_likes_user_uuid FOREIGN KEY (user_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_users(uuid) ON DELETE CASCADE;


--
-- Name: phoenix_kit_post_mentions fk_post_mentions_user_uuid; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_post_mentions
    ADD CONSTRAINT fk_post_mentions_user_uuid FOREIGN KEY (user_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_users(uuid) ON DELETE CASCADE;


--
-- Name: phoenix_kit_post_views fk_post_views_user_uuid; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_post_views
    ADD CONSTRAINT fk_post_views_user_uuid FOREIGN KEY (user_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_users(uuid) ON DELETE CASCADE;


--
-- Name: phoenix_kit_posts fk_posts_user_uuid; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_posts
    ADD CONSTRAINT fk_posts_user_uuid FOREIGN KEY (user_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_users(uuid) ON DELETE CASCADE;


--
-- Name: phoenix_kit_publishing_contents fk_publishing_contents_version; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_publishing_contents
    ADD CONSTRAINT fk_publishing_contents_version FOREIGN KEY (version_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_publishing_versions(uuid) ON DELETE CASCADE;


--
-- Name: phoenix_kit_publishing_posts fk_publishing_posts_active_version; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_publishing_posts
    ADD CONSTRAINT fk_publishing_posts_active_version FOREIGN KEY (active_version_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_publishing_versions(uuid) ON DELETE SET NULL;


--
-- Name: phoenix_kit_publishing_posts fk_publishing_posts_created_by; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_publishing_posts
    ADD CONSTRAINT fk_publishing_posts_created_by FOREIGN KEY (created_by_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_users(uuid) ON DELETE SET NULL;


--
-- Name: phoenix_kit_publishing_posts fk_publishing_posts_group; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_publishing_posts
    ADD CONSTRAINT fk_publishing_posts_group FOREIGN KEY (group_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_publishing_groups(uuid) ON DELETE CASCADE;


--
-- Name: phoenix_kit_publishing_posts fk_publishing_posts_updated_by; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_publishing_posts
    ADD CONSTRAINT fk_publishing_posts_updated_by FOREIGN KEY (updated_by_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_users(uuid) ON DELETE SET NULL;


--
-- Name: phoenix_kit_publishing_versions fk_publishing_versions_created_by; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_publishing_versions
    ADD CONSTRAINT fk_publishing_versions_created_by FOREIGN KEY (created_by_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_users(uuid) ON DELETE SET NULL;


--
-- Name: phoenix_kit_publishing_versions fk_publishing_versions_post; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_publishing_versions
    ADD CONSTRAINT fk_publishing_versions_post FOREIGN KEY (post_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_publishing_posts(uuid) ON DELETE CASCADE;


--
-- Name: phoenix_kit_referral_code_usage fk_referral_code_usage_code_uuid; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_referral_code_usage
    ADD CONSTRAINT fk_referral_code_usage_code_uuid FOREIGN KEY (code_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_referral_codes(uuid) ON DELETE CASCADE;


--
-- Name: phoenix_kit_role_permissions fk_role_permissions_granted_by_uuid; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_role_permissions
    ADD CONSTRAINT fk_role_permissions_granted_by_uuid FOREIGN KEY (granted_by_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_users(uuid) ON DELETE SET NULL;


--
-- Name: phoenix_kit_role_permissions fk_role_permissions_role_uuid; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_role_permissions
    ADD CONSTRAINT fk_role_permissions_role_uuid FOREIGN KEY (role_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_user_roles(uuid) ON DELETE CASCADE;


--
-- Name: phoenix_kit_scheduled_jobs fk_scheduled_jobs_created_by_uuid; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_scheduled_jobs
    ADD CONSTRAINT fk_scheduled_jobs_created_by_uuid FOREIGN KEY (created_by_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_users(uuid) ON DELETE SET NULL;


--
-- Name: phoenix_kit_shop_cart_items fk_shop_cart_items_cart_uuid; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_shop_cart_items
    ADD CONSTRAINT fk_shop_cart_items_cart_uuid FOREIGN KEY (cart_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_shop_carts(uuid) ON DELETE CASCADE;


--
-- Name: phoenix_kit_shop_cart_items fk_shop_cart_items_product_uuid; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_shop_cart_items
    ADD CONSTRAINT fk_shop_cart_items_product_uuid FOREIGN KEY (product_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_shop_products(uuid) ON DELETE SET NULL;


--
-- Name: phoenix_kit_shop_carts fk_shop_carts_payment_option_uuid; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_shop_carts
    ADD CONSTRAINT fk_shop_carts_payment_option_uuid FOREIGN KEY (payment_option_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_payment_options(uuid) ON DELETE SET NULL;


--
-- Name: phoenix_kit_shop_carts fk_shop_carts_shipping_method_uuid; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_shop_carts
    ADD CONSTRAINT fk_shop_carts_shipping_method_uuid FOREIGN KEY (shipping_method_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_shop_shipping_methods(uuid) ON DELETE SET NULL;


--
-- Name: phoenix_kit_shop_carts fk_shop_carts_user_uuid; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_shop_carts
    ADD CONSTRAINT fk_shop_carts_user_uuid FOREIGN KEY (user_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_users(uuid) ON DELETE SET NULL;


--
-- Name: phoenix_kit_shop_categories fk_shop_categories_featured_product_uuid; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_shop_categories
    ADD CONSTRAINT fk_shop_categories_featured_product_uuid FOREIGN KEY (featured_product_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_shop_products(uuid) ON DELETE SET NULL;


--
-- Name: phoenix_kit_shop_categories fk_shop_categories_parent_uuid; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_shop_categories
    ADD CONSTRAINT fk_shop_categories_parent_uuid FOREIGN KEY (parent_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_shop_categories(uuid) ON DELETE SET NULL;


--
-- Name: phoenix_kit_shop_import_logs fk_shop_import_logs_user_uuid; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_shop_import_logs
    ADD CONSTRAINT fk_shop_import_logs_user_uuid FOREIGN KEY (user_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_users(uuid) ON DELETE SET NULL;


--
-- Name: phoenix_kit_shop_products fk_shop_products_category_uuid; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_shop_products
    ADD CONSTRAINT fk_shop_products_category_uuid FOREIGN KEY (category_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_shop_categories(uuid) ON DELETE SET NULL;


--
-- Name: phoenix_kit_shop_products fk_shop_products_created_by_uuid; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_shop_products
    ADD CONSTRAINT fk_shop_products_created_by_uuid FOREIGN KEY (created_by_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_users(uuid) ON DELETE SET NULL;


--
-- Name: phoenix_kit_sync_connections fk_sync_connections_approved_by_uuid; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_sync_connections
    ADD CONSTRAINT fk_sync_connections_approved_by_uuid FOREIGN KEY (approved_by_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_users(uuid) ON DELETE SET NULL;


--
-- Name: phoenix_kit_sync_connections fk_sync_connections_created_by_uuid; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_sync_connections
    ADD CONSTRAINT fk_sync_connections_created_by_uuid FOREIGN KEY (created_by_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_users(uuid) ON DELETE SET NULL;


--
-- Name: phoenix_kit_sync_connections fk_sync_connections_revoked_by_uuid; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_sync_connections
    ADD CONSTRAINT fk_sync_connections_revoked_by_uuid FOREIGN KEY (revoked_by_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_users(uuid) ON DELETE SET NULL;


--
-- Name: phoenix_kit_sync_connections fk_sync_connections_suspended_by_uuid; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_sync_connections
    ADD CONSTRAINT fk_sync_connections_suspended_by_uuid FOREIGN KEY (suspended_by_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_users(uuid) ON DELETE SET NULL;


--
-- Name: phoenix_kit_sync_transfers fk_sync_transfers_approved_by_uuid; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_sync_transfers
    ADD CONSTRAINT fk_sync_transfers_approved_by_uuid FOREIGN KEY (approved_by_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_users(uuid) ON DELETE SET NULL;


--
-- Name: phoenix_kit_sync_transfers fk_sync_transfers_connection_uuid; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_sync_transfers
    ADD CONSTRAINT fk_sync_transfers_connection_uuid FOREIGN KEY (connection_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_sync_connections(uuid) ON DELETE SET NULL;


--
-- Name: phoenix_kit_sync_transfers fk_sync_transfers_denied_by_uuid; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_sync_transfers
    ADD CONSTRAINT fk_sync_transfers_denied_by_uuid FOREIGN KEY (denied_by_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_users(uuid) ON DELETE SET NULL;


--
-- Name: phoenix_kit_sync_transfers fk_sync_transfers_initiated_by_uuid; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_sync_transfers
    ADD CONSTRAINT fk_sync_transfers_initiated_by_uuid FOREIGN KEY (initiated_by_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_users(uuid) ON DELETE SET NULL;


--
-- Name: phoenix_kit_ticket_comments fk_ticket_comments_user_uuid; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_ticket_comments
    ADD CONSTRAINT fk_ticket_comments_user_uuid FOREIGN KEY (user_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_users(uuid) ON DELETE CASCADE;


--
-- Name: phoenix_kit_ticket_status_history fk_ticket_status_history_changed_by_uuid; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_ticket_status_history
    ADD CONSTRAINT fk_ticket_status_history_changed_by_uuid FOREIGN KEY (changed_by_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_users(uuid) ON DELETE SET NULL;


--
-- Name: phoenix_kit_tickets fk_tickets_assigned_to_uuid; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_tickets
    ADD CONSTRAINT fk_tickets_assigned_to_uuid FOREIGN KEY (assigned_to_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_users(uuid) ON DELETE SET NULL;


--
-- Name: phoenix_kit_tickets fk_tickets_user_uuid; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_tickets
    ADD CONSTRAINT fk_tickets_user_uuid FOREIGN KEY (user_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_users(uuid) ON DELETE SET NULL;


--
-- Name: phoenix_kit_transactions fk_transactions_invoice_uuid; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_transactions
    ADD CONSTRAINT fk_transactions_invoice_uuid FOREIGN KEY (invoice_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_invoices(uuid) ON DELETE RESTRICT;


--
-- Name: phoenix_kit_transactions fk_transactions_user_uuid; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_transactions
    ADD CONSTRAINT fk_transactions_user_uuid FOREIGN KEY (user_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_users(uuid) ON DELETE RESTRICT;


--
-- Name: phoenix_kit_user_blocks fk_user_blocks_blocked_uuid; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_user_blocks
    ADD CONSTRAINT fk_user_blocks_blocked_uuid FOREIGN KEY (blocked_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_users(uuid) ON DELETE CASCADE;


--
-- Name: phoenix_kit_user_blocks fk_user_blocks_blocker_uuid; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_user_blocks
    ADD CONSTRAINT fk_user_blocks_blocker_uuid FOREIGN KEY (blocker_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_users(uuid) ON DELETE CASCADE;


--
-- Name: phoenix_kit_user_blocks_history fk_user_blocks_history_blocked_uuid; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_user_blocks_history
    ADD CONSTRAINT fk_user_blocks_history_blocked_uuid FOREIGN KEY (blocked_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_users(uuid) ON DELETE CASCADE;


--
-- Name: phoenix_kit_user_blocks_history fk_user_blocks_history_blocker_uuid; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_user_blocks_history
    ADD CONSTRAINT fk_user_blocks_history_blocker_uuid FOREIGN KEY (blocker_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_users(uuid) ON DELETE CASCADE;


--
-- Name: phoenix_kit_user_connections_history fk_user_connections_history_actor_uuid; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_user_connections_history
    ADD CONSTRAINT fk_user_connections_history_actor_uuid FOREIGN KEY (actor_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_users(uuid) ON DELETE CASCADE;


--
-- Name: phoenix_kit_user_connections_history fk_user_connections_history_user_a_uuid; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_user_connections_history
    ADD CONSTRAINT fk_user_connections_history_user_a_uuid FOREIGN KEY (user_a_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_users(uuid) ON DELETE CASCADE;


--
-- Name: phoenix_kit_user_connections_history fk_user_connections_history_user_b_uuid; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_user_connections_history
    ADD CONSTRAINT fk_user_connections_history_user_b_uuid FOREIGN KEY (user_b_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_users(uuid) ON DELETE CASCADE;


--
-- Name: phoenix_kit_user_connections fk_user_connections_recipient_uuid; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_user_connections
    ADD CONSTRAINT fk_user_connections_recipient_uuid FOREIGN KEY (recipient_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_users(uuid) ON DELETE CASCADE;


--
-- Name: phoenix_kit_user_connections fk_user_connections_requester_uuid; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_user_connections
    ADD CONSTRAINT fk_user_connections_requester_uuid FOREIGN KEY (requester_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_users(uuid) ON DELETE CASCADE;


--
-- Name: phoenix_kit_user_follows fk_user_follows_followed_uuid; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_user_follows
    ADD CONSTRAINT fk_user_follows_followed_uuid FOREIGN KEY (followed_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_users(uuid) ON DELETE CASCADE;


--
-- Name: phoenix_kit_user_follows fk_user_follows_follower_uuid; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_user_follows
    ADD CONSTRAINT fk_user_follows_follower_uuid FOREIGN KEY (follower_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_users(uuid) ON DELETE CASCADE;


--
-- Name: phoenix_kit_user_follows_history fk_user_follows_history_followed_uuid; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_user_follows_history
    ADD CONSTRAINT fk_user_follows_history_followed_uuid FOREIGN KEY (followed_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_users(uuid) ON DELETE CASCADE;


--
-- Name: phoenix_kit_user_follows_history fk_user_follows_history_follower_uuid; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_user_follows_history
    ADD CONSTRAINT fk_user_follows_history_follower_uuid FOREIGN KEY (follower_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_users(uuid) ON DELETE CASCADE;


--
-- Name: phoenix_kit_user_oauth_providers fk_user_oauth_providers_user_uuid; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_user_oauth_providers
    ADD CONSTRAINT fk_user_oauth_providers_user_uuid FOREIGN KEY (user_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_users(uuid) ON DELETE CASCADE;


--
-- Name: phoenix_kit_user_role_assignments fk_user_role_assignments_assigned_by_uuid; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_user_role_assignments
    ADD CONSTRAINT fk_user_role_assignments_assigned_by_uuid FOREIGN KEY (assigned_by_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_users(uuid) ON DELETE SET NULL;


--
-- Name: phoenix_kit_user_role_assignments fk_user_role_assignments_role_uuid; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_user_role_assignments
    ADD CONSTRAINT fk_user_role_assignments_role_uuid FOREIGN KEY (role_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_user_roles(uuid) ON DELETE CASCADE;


--
-- Name: phoenix_kit_user_role_assignments fk_user_role_assignments_user_uuid; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_user_role_assignments
    ADD CONSTRAINT fk_user_role_assignments_user_uuid FOREIGN KEY (user_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_users(uuid) ON DELETE CASCADE;


--
-- Name: phoenix_kit_users_tokens fk_users_tokens_user_uuid; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_users_tokens
    ADD CONSTRAINT fk_users_tokens_user_uuid FOREIGN KEY (user_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_users(uuid) ON DELETE CASCADE;


--
-- Name: phoenix_kit_ai_requests phoenix_kit_ai_requests_prompt_uuid_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_ai_requests
    ADD CONSTRAINT phoenix_kit_ai_requests_prompt_uuid_fkey FOREIGN KEY (prompt_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_ai_prompts(uuid) ON DELETE SET NULL;


--
-- Name: phoenix_kit_annotations phoenix_kit_annotations_creator_uuid_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_annotations
    ADD CONSTRAINT phoenix_kit_annotations_creator_uuid_fkey FOREIGN KEY (creator_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_users(uuid) ON DELETE SET NULL;


--
-- Name: phoenix_kit_annotations phoenix_kit_annotations_file_uuid_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_annotations
    ADD CONSTRAINT phoenix_kit_annotations_file_uuid_fkey FOREIGN KEY (file_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_files(uuid) ON DELETE CASCADE;


--
-- Name: phoenix_kit_calendar_event_participants phoenix_kit_calendar_event_participants_added_by_uuid_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_calendar_event_participants
    ADD CONSTRAINT phoenix_kit_calendar_event_participants_added_by_uuid_fkey FOREIGN KEY (added_by_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_users(uuid) ON DELETE SET NULL;


--
-- Name: phoenix_kit_calendar_event_participants phoenix_kit_calendar_event_participants_event_uuid_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_calendar_event_participants
    ADD CONSTRAINT phoenix_kit_calendar_event_participants_event_uuid_fkey FOREIGN KEY (event_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_calendar_events(uuid) ON DELETE CASCADE;


--
-- Name: phoenix_kit_calendar_events phoenix_kit_calendar_events_owner_uuid_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_calendar_events
    ADD CONSTRAINT phoenix_kit_calendar_events_owner_uuid_fkey FOREIGN KEY (owner_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_users(uuid) ON DELETE CASCADE;


--
-- Name: phoenix_kit_cat_catalogues phoenix_kit_cat_catalogues_folder_uuid_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_cat_catalogues
    ADD CONSTRAINT phoenix_kit_cat_catalogues_folder_uuid_fkey FOREIGN KEY (folder_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_cat_folders(uuid) ON DELETE SET NULL;


--
-- Name: phoenix_kit_cat_categories phoenix_kit_cat_categories_catalogue_uuid_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_cat_categories
    ADD CONSTRAINT phoenix_kit_cat_categories_catalogue_uuid_fkey FOREIGN KEY (catalogue_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_cat_catalogues(uuid) ON DELETE CASCADE;


--
-- Name: phoenix_kit_cat_categories phoenix_kit_cat_categories_parent_uuid_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_cat_categories
    ADD CONSTRAINT phoenix_kit_cat_categories_parent_uuid_fkey FOREIGN KEY (parent_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_cat_categories(uuid);


--
-- Name: phoenix_kit_cat_folders phoenix_kit_cat_folders_parent_uuid_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_cat_folders
    ADD CONSTRAINT phoenix_kit_cat_folders_parent_uuid_fkey FOREIGN KEY (parent_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_cat_folders(uuid) ON DELETE SET NULL;


--
-- Name: phoenix_kit_cat_item_catalogue_rules phoenix_kit_cat_item_catalogue_r_referenced_catalogue_uuid_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_cat_item_catalogue_rules
    ADD CONSTRAINT phoenix_kit_cat_item_catalogue_r_referenced_catalogue_uuid_fkey FOREIGN KEY (referenced_catalogue_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_cat_catalogues(uuid) ON DELETE CASCADE;


--
-- Name: phoenix_kit_cat_item_catalogue_rules phoenix_kit_cat_item_catalogue_rules_item_uuid_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_cat_item_catalogue_rules
    ADD CONSTRAINT phoenix_kit_cat_item_catalogue_rules_item_uuid_fkey FOREIGN KEY (item_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_cat_items(uuid) ON DELETE CASCADE;


--
-- Name: phoenix_kit_cat_item_supplier_info phoenix_kit_cat_item_supplier_info_item_uuid_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_cat_item_supplier_info
    ADD CONSTRAINT phoenix_kit_cat_item_supplier_info_item_uuid_fkey FOREIGN KEY (item_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_cat_items(uuid) ON DELETE CASCADE;


--
-- Name: phoenix_kit_cat_items phoenix_kit_cat_items_catalogue_uuid_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_cat_items
    ADD CONSTRAINT phoenix_kit_cat_items_catalogue_uuid_fkey FOREIGN KEY (catalogue_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_cat_catalogues(uuid) ON DELETE SET NULL;


--
-- Name: phoenix_kit_cat_items phoenix_kit_cat_items_category_uuid_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_cat_items
    ADD CONSTRAINT phoenix_kit_cat_items_category_uuid_fkey FOREIGN KEY (category_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_cat_categories(uuid) ON DELETE SET NULL;


--
-- Name: phoenix_kit_cat_items phoenix_kit_cat_items_manufacturer_uuid_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_cat_items
    ADD CONSTRAINT phoenix_kit_cat_items_manufacturer_uuid_fkey FOREIGN KEY (manufacturer_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_cat_manufacturers(uuid) ON DELETE SET NULL;


--
-- Name: phoenix_kit_cat_items phoenix_kit_cat_items_primary_supplier_uuid_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_cat_items
    ADD CONSTRAINT phoenix_kit_cat_items_primary_supplier_uuid_fkey FOREIGN KEY (primary_supplier_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_cat_suppliers(uuid) ON DELETE SET NULL;


--
-- Name: phoenix_kit_cat_manufacturer_suppliers phoenix_kit_cat_manufacturer_suppliers_manufacturer_uuid_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_cat_manufacturer_suppliers
    ADD CONSTRAINT phoenix_kit_cat_manufacturer_suppliers_manufacturer_uuid_fkey FOREIGN KEY (manufacturer_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_cat_manufacturers(uuid) ON DELETE CASCADE;


--
-- Name: phoenix_kit_cat_manufacturer_suppliers phoenix_kit_cat_manufacturer_suppliers_supplier_uuid_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_cat_manufacturer_suppliers
    ADD CONSTRAINT phoenix_kit_cat_manufacturer_suppliers_supplier_uuid_fkey FOREIGN KEY (supplier_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_cat_suppliers(uuid) ON DELETE CASCADE;


--
-- Name: phoenix_kit_cat_pdf_extractions phoenix_kit_cat_pdf_extractions_file_uuid_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_cat_pdf_extractions
    ADD CONSTRAINT phoenix_kit_cat_pdf_extractions_file_uuid_fkey FOREIGN KEY (file_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_files(uuid) ON DELETE CASCADE;


--
-- Name: phoenix_kit_cat_pdf_pages phoenix_kit_cat_pdf_pages_content_hash_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_cat_pdf_pages
    ADD CONSTRAINT phoenix_kit_cat_pdf_pages_content_hash_fkey FOREIGN KEY (content_hash) REFERENCES pk_sqv_s1a.phoenix_kit_cat_pdf_page_contents(content_hash) ON DELETE RESTRICT;


--
-- Name: phoenix_kit_cat_pdf_pages phoenix_kit_cat_pdf_pages_file_uuid_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_cat_pdf_pages
    ADD CONSTRAINT phoenix_kit_cat_pdf_pages_file_uuid_fkey FOREIGN KEY (file_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_files(uuid) ON DELETE CASCADE;


--
-- Name: phoenix_kit_cat_pdfs phoenix_kit_cat_pdfs_file_uuid_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_cat_pdfs
    ADD CONSTRAINT phoenix_kit_cat_pdfs_file_uuid_fkey FOREIGN KEY (file_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_files(uuid) ON DELETE RESTRICT;


--
-- Name: phoenix_kit_comment_dislikes phoenix_kit_comment_dislikes_comment_id_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_comment_dislikes
    ADD CONSTRAINT phoenix_kit_comment_dislikes_comment_id_fkey FOREIGN KEY (comment_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_post_comments(uuid) ON DELETE CASCADE;


--
-- Name: phoenix_kit_comment_likes phoenix_kit_comment_likes_comment_id_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_comment_likes
    ADD CONSTRAINT phoenix_kit_comment_likes_comment_id_fkey FOREIGN KEY (comment_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_post_comments(uuid) ON DELETE CASCADE;


--
-- Name: phoenix_kit_comment_media phoenix_kit_comment_media_comment_uuid_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_comment_media
    ADD CONSTRAINT phoenix_kit_comment_media_comment_uuid_fkey FOREIGN KEY (comment_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_comments(uuid) ON DELETE CASCADE;


--
-- Name: phoenix_kit_comment_media phoenix_kit_comment_media_file_uuid_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_comment_media
    ADD CONSTRAINT phoenix_kit_comment_media_file_uuid_fkey FOREIGN KEY (file_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_files(uuid) ON DELETE RESTRICT;


--
-- Name: phoenix_kit_crm_company_memberships phoenix_kit_crm_company_memberships_company_uuid_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_crm_company_memberships
    ADD CONSTRAINT phoenix_kit_crm_company_memberships_company_uuid_fkey FOREIGN KEY (company_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_crm_companies(uuid) ON DELETE CASCADE;


--
-- Name: phoenix_kit_crm_company_memberships phoenix_kit_crm_company_memberships_contact_uuid_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_crm_company_memberships
    ADD CONSTRAINT phoenix_kit_crm_company_memberships_contact_uuid_fkey FOREIGN KEY (contact_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_crm_contacts(uuid) ON DELETE CASCADE;


--
-- Name: phoenix_kit_crm_contacts phoenix_kit_crm_contacts_user_uuid_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_crm_contacts
    ADD CONSTRAINT phoenix_kit_crm_contacts_user_uuid_fkey FOREIGN KEY (user_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_users(uuid) ON DELETE SET NULL;


--
-- Name: phoenix_kit_crm_interaction_parties phoenix_kit_crm_interaction_parties_contact_uuid_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_crm_interaction_parties
    ADD CONSTRAINT phoenix_kit_crm_interaction_parties_contact_uuid_fkey FOREIGN KEY (contact_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_crm_contacts(uuid) ON DELETE SET NULL;


--
-- Name: phoenix_kit_crm_interaction_parties phoenix_kit_crm_interaction_parties_interaction_uuid_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_crm_interaction_parties
    ADD CONSTRAINT phoenix_kit_crm_interaction_parties_interaction_uuid_fkey FOREIGN KEY (interaction_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_crm_interactions(uuid) ON DELETE CASCADE;


--
-- Name: phoenix_kit_crm_interactions phoenix_kit_crm_interactions_contact_uuid_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_crm_interactions
    ADD CONSTRAINT phoenix_kit_crm_interactions_contact_uuid_fkey FOREIGN KEY (contact_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_crm_contacts(uuid) ON DELETE CASCADE;


--
-- Name: phoenix_kit_crm_interactions phoenix_kit_crm_interactions_owner_user_uuid_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_crm_interactions
    ADD CONSTRAINT phoenix_kit_crm_interactions_owner_user_uuid_fkey FOREIGN KEY (owner_user_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_users(uuid) ON DELETE SET NULL;


--
-- Name: phoenix_kit_crm_list_members phoenix_kit_crm_list_members_contact_uuid_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_crm_list_members
    ADD CONSTRAINT phoenix_kit_crm_list_members_contact_uuid_fkey FOREIGN KEY (contact_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_crm_contacts(uuid) ON DELETE CASCADE;


--
-- Name: phoenix_kit_crm_list_members phoenix_kit_crm_list_members_list_uuid_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_crm_list_members
    ADD CONSTRAINT phoenix_kit_crm_list_members_list_uuid_fkey FOREIGN KEY (list_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_crm_lists(uuid) ON DELETE CASCADE;


--
-- Name: phoenix_kit_crm_role_settings phoenix_kit_crm_role_settings_role_uuid_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_crm_role_settings
    ADD CONSTRAINT phoenix_kit_crm_role_settings_role_uuid_fkey FOREIGN KEY (role_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_user_roles(uuid) ON DELETE CASCADE;


--
-- Name: phoenix_kit_crm_user_role_view phoenix_kit_crm_user_role_view_user_uuid_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_crm_user_role_view
    ADD CONSTRAINT phoenix_kit_crm_user_role_view_user_uuid_fkey FOREIGN KEY (user_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_users(uuid) ON DELETE CASCADE;


--
-- Name: phoenix_kit_dashboards phoenix_kit_dashboards_owner_user_uuid_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_dashboards
    ADD CONSTRAINT phoenix_kit_dashboards_owner_user_uuid_fkey FOREIGN KEY (owner_user_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_users(uuid) ON DELETE CASCADE;


--
-- Name: phoenix_kit_doc_document_sections phoenix_kit_doc_document_sections_document_uuid_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_doc_document_sections
    ADD CONSTRAINT phoenix_kit_doc_document_sections_document_uuid_fkey FOREIGN KEY (document_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_doc_documents(uuid) ON DELETE CASCADE;


--
-- Name: phoenix_kit_doc_document_sections phoenix_kit_doc_document_sections_template_uuid_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_doc_document_sections
    ADD CONSTRAINT phoenix_kit_doc_document_sections_template_uuid_fkey FOREIGN KEY (template_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_doc_templates(uuid) ON DELETE SET NULL;


--
-- Name: phoenix_kit_doc_documents phoenix_kit_doc_documents_category_uuid_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_doc_documents
    ADD CONSTRAINT phoenix_kit_doc_documents_category_uuid_fkey FOREIGN KEY (category_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_doc_categories(uuid) ON DELETE SET NULL;


--
-- Name: phoenix_kit_doc_documents phoenix_kit_doc_documents_template_uuid_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_doc_documents
    ADD CONSTRAINT phoenix_kit_doc_documents_template_uuid_fkey FOREIGN KEY (template_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_doc_templates(uuid) ON DELETE SET NULL;


--
-- Name: phoenix_kit_doc_documents phoenix_kit_doc_documents_type_uuid_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_doc_documents
    ADD CONSTRAINT phoenix_kit_doc_documents_type_uuid_fkey FOREIGN KEY (type_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_doc_types(uuid) ON DELETE SET NULL;


--
-- Name: phoenix_kit_doc_templates phoenix_kit_doc_templates_category_uuid_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_doc_templates
    ADD CONSTRAINT phoenix_kit_doc_templates_category_uuid_fkey FOREIGN KEY (category_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_doc_categories(uuid) ON DELETE SET NULL;


--
-- Name: phoenix_kit_doc_templates phoenix_kit_doc_templates_footer_uuid_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_doc_templates
    ADD CONSTRAINT phoenix_kit_doc_templates_footer_uuid_fkey FOREIGN KEY (footer_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_doc_headers_footers(uuid) ON DELETE SET NULL;


--
-- Name: phoenix_kit_doc_templates phoenix_kit_doc_templates_header_uuid_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_doc_templates
    ADD CONSTRAINT phoenix_kit_doc_templates_header_uuid_fkey FOREIGN KEY (header_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_doc_headers_footers(uuid) ON DELETE SET NULL;


--
-- Name: phoenix_kit_doc_templates phoenix_kit_doc_templates_type_uuid_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_doc_templates
    ADD CONSTRAINT phoenix_kit_doc_templates_type_uuid_fkey FOREIGN KEY (type_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_doc_types(uuid) ON DELETE SET NULL;


--
-- Name: phoenix_kit_doc_types phoenix_kit_doc_types_category_uuid_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_doc_types
    ADD CONSTRAINT phoenix_kit_doc_types_category_uuid_fkey FOREIGN KEY (category_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_doc_categories(uuid) ON DELETE CASCADE;


--
-- Name: phoenix_kit_entity_data phoenix_kit_entity_data_parent_uuid_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_entity_data
    ADD CONSTRAINT phoenix_kit_entity_data_parent_uuid_fkey FOREIGN KEY (parent_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_entity_data(uuid);


--
-- Name: phoenix_kit_file_instances phoenix_kit_file_instances_file_id_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_file_instances
    ADD CONSTRAINT phoenix_kit_file_instances_file_id_fkey FOREIGN KEY (file_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_files(uuid) ON DELETE CASCADE;


--
-- Name: phoenix_kit_file_locations phoenix_kit_file_locations_bucket_id_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_file_locations
    ADD CONSTRAINT phoenix_kit_file_locations_bucket_id_fkey FOREIGN KEY (bucket_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_buckets(uuid) ON DELETE CASCADE;


--
-- Name: phoenix_kit_file_locations phoenix_kit_file_locations_file_instance_id_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_file_locations
    ADD CONSTRAINT phoenix_kit_file_locations_file_instance_id_fkey FOREIGN KEY (file_instance_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_file_instances(uuid) ON DELETE CASCADE;


--
-- Name: phoenix_kit_files phoenix_kit_files_folder_uuid_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_files
    ADD CONSTRAINT phoenix_kit_files_folder_uuid_fkey FOREIGN KEY (folder_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_media_folders(uuid) ON DELETE SET NULL;


--
-- Name: phoenix_kit_files phoenix_kit_files_parent_file_uuid_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_files
    ADD CONSTRAINT phoenix_kit_files_parent_file_uuid_fkey FOREIGN KEY (parent_file_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_files(uuid) ON DELETE CASCADE;


--
-- Name: phoenix_kit_location_spaces phoenix_kit_location_spaces_location_uuid_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_location_spaces
    ADD CONSTRAINT phoenix_kit_location_spaces_location_uuid_fkey FOREIGN KEY (location_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_locations(uuid) ON DELETE CASCADE;


--
-- Name: phoenix_kit_location_spaces phoenix_kit_location_spaces_parent_uuid_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_location_spaces
    ADD CONSTRAINT phoenix_kit_location_spaces_parent_uuid_fkey FOREIGN KEY (parent_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_location_spaces(uuid) ON DELETE CASCADE;


--
-- Name: phoenix_kit_location_type_assignments phoenix_kit_location_type_assignments_location_type_uuid_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_location_type_assignments
    ADD CONSTRAINT phoenix_kit_location_type_assignments_location_type_uuid_fkey FOREIGN KEY (location_type_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_location_types(uuid) ON DELETE CASCADE;


--
-- Name: phoenix_kit_location_type_assignments phoenix_kit_location_type_assignments_location_uuid_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_location_type_assignments
    ADD CONSTRAINT phoenix_kit_location_type_assignments_location_uuid_fkey FOREIGN KEY (location_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_locations(uuid) ON DELETE CASCADE;


--
-- Name: phoenix_kit_machine_operations phoenix_kit_machine_operations_machine_uuid_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_machine_operations
    ADD CONSTRAINT phoenix_kit_machine_operations_machine_uuid_fkey FOREIGN KEY (machine_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_machines(uuid) ON DELETE CASCADE;


--
-- Name: phoenix_kit_machine_type_assignments phoenix_kit_machine_type_assignments_machine_uuid_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_machine_type_assignments
    ADD CONSTRAINT phoenix_kit_machine_type_assignments_machine_uuid_fkey FOREIGN KEY (machine_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_machines(uuid) ON DELETE CASCADE;


--
-- Name: phoenix_kit_media_folder_links phoenix_kit_media_folder_links_file_uuid_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_media_folder_links
    ADD CONSTRAINT phoenix_kit_media_folder_links_file_uuid_fkey FOREIGN KEY (file_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_files(uuid) ON DELETE CASCADE;


--
-- Name: phoenix_kit_media_folder_links phoenix_kit_media_folder_links_folder_uuid_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_media_folder_links
    ADD CONSTRAINT phoenix_kit_media_folder_links_folder_uuid_fkey FOREIGN KEY (folder_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_media_folders(uuid) ON DELETE CASCADE;


--
-- Name: phoenix_kit_media_folders phoenix_kit_media_folders_cover_file_uuid_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_media_folders
    ADD CONSTRAINT phoenix_kit_media_folders_cover_file_uuid_fkey FOREIGN KEY (cover_file_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_files(uuid) ON DELETE SET NULL;


--
-- Name: phoenix_kit_media_folders phoenix_kit_media_folders_logo_file_uuid_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_media_folders
    ADD CONSTRAINT phoenix_kit_media_folders_logo_file_uuid_fkey FOREIGN KEY (logo_file_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_files(uuid) ON DELETE SET NULL;


--
-- Name: phoenix_kit_media_folders phoenix_kit_media_folders_parent_uuid_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_media_folders
    ADD CONSTRAINT phoenix_kit_media_folders_parent_uuid_fkey FOREIGN KEY (parent_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_media_folders(uuid) ON DELETE SET NULL;


--
-- Name: phoenix_kit_media_folders phoenix_kit_media_folders_user_uuid_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_media_folders
    ADD CONSTRAINT phoenix_kit_media_folders_user_uuid_fkey FOREIGN KEY (user_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_users(uuid);


--
-- Name: phoenix_kit_notifications phoenix_kit_notifications_activity_uuid_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_notifications
    ADD CONSTRAINT phoenix_kit_notifications_activity_uuid_fkey FOREIGN KEY (activity_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_activities(uuid) ON DELETE CASCADE;


--
-- Name: phoenix_kit_notifications phoenix_kit_notifications_recipient_uuid_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_notifications
    ADD CONSTRAINT phoenix_kit_notifications_recipient_uuid_fkey FOREIGN KEY (recipient_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_users(uuid) ON DELETE CASCADE;


--
-- Name: phoenix_kit_og_assignments phoenix_kit_og_assignments_template_uuid_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_og_assignments
    ADD CONSTRAINT phoenix_kit_og_assignments_template_uuid_fkey FOREIGN KEY (template_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_og_templates(uuid) ON DELETE CASCADE;


--
-- Name: phoenix_kit_organization_invitations phoenix_kit_organization_invitations_invited_by_uuid_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_organization_invitations
    ADD CONSTRAINT phoenix_kit_organization_invitations_invited_by_uuid_fkey FOREIGN KEY (invited_by_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_users(uuid) ON DELETE SET NULL;


--
-- Name: phoenix_kit_organization_invitations phoenix_kit_organization_invitations_organization_uuid_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_organization_invitations
    ADD CONSTRAINT phoenix_kit_organization_invitations_organization_uuid_fkey FOREIGN KEY (organization_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_users(uuid) ON DELETE CASCADE;


--
-- Name: phoenix_kit_post_comments phoenix_kit_post_comments_parent_id_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_post_comments
    ADD CONSTRAINT phoenix_kit_post_comments_parent_id_fkey FOREIGN KEY (parent_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_post_comments(uuid) ON DELETE CASCADE;


--
-- Name: phoenix_kit_post_comments phoenix_kit_post_comments_post_id_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_post_comments
    ADD CONSTRAINT phoenix_kit_post_comments_post_id_fkey FOREIGN KEY (post_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_posts(uuid) ON DELETE CASCADE;


--
-- Name: phoenix_kit_post_dislikes phoenix_kit_post_dislikes_post_id_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_post_dislikes
    ADD CONSTRAINT phoenix_kit_post_dislikes_post_id_fkey FOREIGN KEY (post_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_posts(uuid) ON DELETE CASCADE;


--
-- Name: phoenix_kit_post_group_assignments phoenix_kit_post_group_assignments_group_id_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_post_group_assignments
    ADD CONSTRAINT phoenix_kit_post_group_assignments_group_id_fkey FOREIGN KEY (group_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_post_groups(uuid) ON DELETE CASCADE;


--
-- Name: phoenix_kit_post_group_assignments phoenix_kit_post_group_assignments_post_id_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_post_group_assignments
    ADD CONSTRAINT phoenix_kit_post_group_assignments_post_id_fkey FOREIGN KEY (post_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_posts(uuid) ON DELETE CASCADE;


--
-- Name: phoenix_kit_post_groups phoenix_kit_post_groups_cover_image_id_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_post_groups
    ADD CONSTRAINT phoenix_kit_post_groups_cover_image_id_fkey FOREIGN KEY (cover_image_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_files(uuid) ON DELETE SET NULL;


--
-- Name: phoenix_kit_post_likes phoenix_kit_post_likes_post_id_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_post_likes
    ADD CONSTRAINT phoenix_kit_post_likes_post_id_fkey FOREIGN KEY (post_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_posts(uuid) ON DELETE CASCADE;


--
-- Name: phoenix_kit_post_media phoenix_kit_post_media_file_id_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_post_media
    ADD CONSTRAINT phoenix_kit_post_media_file_id_fkey FOREIGN KEY (file_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_files(uuid) ON DELETE CASCADE;


--
-- Name: phoenix_kit_post_media phoenix_kit_post_media_post_id_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_post_media
    ADD CONSTRAINT phoenix_kit_post_media_post_id_fkey FOREIGN KEY (post_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_posts(uuid) ON DELETE CASCADE;


--
-- Name: phoenix_kit_post_mentions phoenix_kit_post_mentions_post_id_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_post_mentions
    ADD CONSTRAINT phoenix_kit_post_mentions_post_id_fkey FOREIGN KEY (post_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_posts(uuid) ON DELETE CASCADE;


--
-- Name: phoenix_kit_post_tag_assignments phoenix_kit_post_tag_assignments_post_id_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_post_tag_assignments
    ADD CONSTRAINT phoenix_kit_post_tag_assignments_post_id_fkey FOREIGN KEY (post_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_posts(uuid) ON DELETE CASCADE;


--
-- Name: phoenix_kit_post_tag_assignments phoenix_kit_post_tag_assignments_tag_id_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_post_tag_assignments
    ADD CONSTRAINT phoenix_kit_post_tag_assignments_tag_id_fkey FOREIGN KEY (tag_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_post_tags(uuid) ON DELETE CASCADE;


--
-- Name: phoenix_kit_post_views phoenix_kit_post_views_post_id_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_post_views
    ADD CONSTRAINT phoenix_kit_post_views_post_id_fkey FOREIGN KEY (post_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_posts(uuid) ON DELETE CASCADE;


--
-- Name: phoenix_kit_project_assignments phoenix_kit_project_assignments_assigned_department_uuid_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_project_assignments
    ADD CONSTRAINT phoenix_kit_project_assignments_assigned_department_uuid_fkey FOREIGN KEY (assigned_department_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_staff_departments(uuid) ON DELETE SET NULL;


--
-- Name: phoenix_kit_project_assignments phoenix_kit_project_assignments_assigned_person_uuid_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_project_assignments
    ADD CONSTRAINT phoenix_kit_project_assignments_assigned_person_uuid_fkey FOREIGN KEY (assigned_person_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_staff_people(uuid) ON DELETE SET NULL;


--
-- Name: phoenix_kit_project_assignments phoenix_kit_project_assignments_assigned_team_uuid_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_project_assignments
    ADD CONSTRAINT phoenix_kit_project_assignments_assigned_team_uuid_fkey FOREIGN KEY (assigned_team_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_staff_teams(uuid) ON DELETE SET NULL;


--
-- Name: phoenix_kit_project_assignments phoenix_kit_project_assignments_child_project_uuid_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_project_assignments
    ADD CONSTRAINT phoenix_kit_project_assignments_child_project_uuid_fkey FOREIGN KEY (child_project_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_projects(uuid) ON DELETE RESTRICT;


--
-- Name: phoenix_kit_project_assignments phoenix_kit_project_assignments_completed_by_uuid_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_project_assignments
    ADD CONSTRAINT phoenix_kit_project_assignments_completed_by_uuid_fkey FOREIGN KEY (completed_by_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_users(uuid) ON DELETE SET NULL;


--
-- Name: phoenix_kit_project_assignments phoenix_kit_project_assignments_project_uuid_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_project_assignments
    ADD CONSTRAINT phoenix_kit_project_assignments_project_uuid_fkey FOREIGN KEY (project_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_projects(uuid) ON DELETE CASCADE;


--
-- Name: phoenix_kit_project_assignments phoenix_kit_project_assignments_task_uuid_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_project_assignments
    ADD CONSTRAINT phoenix_kit_project_assignments_task_uuid_fkey FOREIGN KEY (task_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_project_tasks(uuid) ON DELETE CASCADE;


--
-- Name: phoenix_kit_project_dependencies phoenix_kit_project_dependencies_assignment_uuid_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_project_dependencies
    ADD CONSTRAINT phoenix_kit_project_dependencies_assignment_uuid_fkey FOREIGN KEY (assignment_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_project_assignments(uuid) ON DELETE CASCADE;


--
-- Name: phoenix_kit_project_dependencies phoenix_kit_project_dependencies_depends_on_uuid_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_project_dependencies
    ADD CONSTRAINT phoenix_kit_project_dependencies_depends_on_uuid_fkey FOREIGN KEY (depends_on_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_project_assignments(uuid) ON DELETE CASCADE;


--
-- Name: phoenix_kit_project_statuses phoenix_kit_project_statuses_project_uuid_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_project_statuses
    ADD CONSTRAINT phoenix_kit_project_statuses_project_uuid_fkey FOREIGN KEY (project_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_projects(uuid) ON DELETE CASCADE;


--
-- Name: phoenix_kit_project_task_dependencies phoenix_kit_project_task_dependencies_depends_on_task_uuid_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_project_task_dependencies
    ADD CONSTRAINT phoenix_kit_project_task_dependencies_depends_on_task_uuid_fkey FOREIGN KEY (depends_on_task_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_project_tasks(uuid) ON DELETE CASCADE;


--
-- Name: phoenix_kit_project_task_dependencies phoenix_kit_project_task_dependencies_task_uuid_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_project_task_dependencies
    ADD CONSTRAINT phoenix_kit_project_task_dependencies_task_uuid_fkey FOREIGN KEY (task_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_project_tasks(uuid) ON DELETE CASCADE;


--
-- Name: phoenix_kit_project_tasks phoenix_kit_project_tasks_default_assigned_department_uuid_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_project_tasks
    ADD CONSTRAINT phoenix_kit_project_tasks_default_assigned_department_uuid_fkey FOREIGN KEY (default_assigned_department_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_staff_departments(uuid) ON DELETE SET NULL;


--
-- Name: phoenix_kit_project_tasks phoenix_kit_project_tasks_default_assigned_person_uuid_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_project_tasks
    ADD CONSTRAINT phoenix_kit_project_tasks_default_assigned_person_uuid_fkey FOREIGN KEY (default_assigned_person_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_staff_people(uuid) ON DELETE SET NULL;


--
-- Name: phoenix_kit_project_tasks phoenix_kit_project_tasks_default_assigned_team_uuid_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_project_tasks
    ADD CONSTRAINT phoenix_kit_project_tasks_default_assigned_team_uuid_fkey FOREIGN KEY (default_assigned_team_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_staff_teams(uuid) ON DELETE SET NULL;


--
-- Name: phoenix_kit_projects phoenix_kit_projects_assigned_department_uuid_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_projects
    ADD CONSTRAINT phoenix_kit_projects_assigned_department_uuid_fkey FOREIGN KEY (assigned_department_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_staff_departments(uuid) ON DELETE SET NULL;


--
-- Name: phoenix_kit_projects phoenix_kit_projects_assigned_person_uuid_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_projects
    ADD CONSTRAINT phoenix_kit_projects_assigned_person_uuid_fkey FOREIGN KEY (assigned_person_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_staff_people(uuid) ON DELETE SET NULL;


--
-- Name: phoenix_kit_projects phoenix_kit_projects_assigned_team_uuid_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_projects
    ADD CONSTRAINT phoenix_kit_projects_assigned_team_uuid_fkey FOREIGN KEY (assigned_team_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_staff_teams(uuid) ON DELETE SET NULL;


--
-- Name: phoenix_kit_projects phoenix_kit_projects_status_entity_uuid_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_projects
    ADD CONSTRAINT phoenix_kit_projects_status_entity_uuid_fkey FOREIGN KEY (status_entity_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_entities(uuid) ON DELETE SET NULL;


--
-- Name: phoenix_kit_publishing_categories phoenix_kit_publishing_categories_group_uuid_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_publishing_categories
    ADD CONSTRAINT phoenix_kit_publishing_categories_group_uuid_fkey FOREIGN KEY (group_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_publishing_groups(uuid) ON DELETE CASCADE;


--
-- Name: phoenix_kit_publishing_categories phoenix_kit_publishing_categories_parent_uuid_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_publishing_categories
    ADD CONSTRAINT phoenix_kit_publishing_categories_parent_uuid_fkey FOREIGN KEY (parent_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_publishing_categories(uuid) ON DELETE SET NULL;


--
-- Name: phoenix_kit_publishing_post_categories phoenix_kit_publishing_post_categories_category_uuid_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_publishing_post_categories
    ADD CONSTRAINT phoenix_kit_publishing_post_categories_category_uuid_fkey FOREIGN KEY (category_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_publishing_categories(uuid) ON DELETE CASCADE;


--
-- Name: phoenix_kit_publishing_post_categories phoenix_kit_publishing_post_categories_post_uuid_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_publishing_post_categories
    ADD CONSTRAINT phoenix_kit_publishing_post_categories_post_uuid_fkey FOREIGN KEY (post_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_publishing_posts(uuid) ON DELETE CASCADE;


--
-- Name: phoenix_kit_publishing_post_views phoenix_kit_publishing_post_views_post_uuid_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_publishing_post_views
    ADD CONSTRAINT phoenix_kit_publishing_post_views_post_uuid_fkey FOREIGN KEY (post_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_publishing_posts(uuid) ON DELETE CASCADE;


--
-- Name: phoenix_kit_staff_employments phoenix_kit_staff_employments_primary_department_uuid_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_staff_employments
    ADD CONSTRAINT phoenix_kit_staff_employments_primary_department_uuid_fkey FOREIGN KEY (primary_department_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_staff_departments(uuid) ON DELETE SET NULL;


--
-- Name: phoenix_kit_staff_employments phoenix_kit_staff_employments_primary_team_uuid_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_staff_employments
    ADD CONSTRAINT phoenix_kit_staff_employments_primary_team_uuid_fkey FOREIGN KEY (primary_team_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_staff_teams(uuid) ON DELETE SET NULL;


--
-- Name: phoenix_kit_staff_employments phoenix_kit_staff_employments_staff_person_uuid_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_staff_employments
    ADD CONSTRAINT phoenix_kit_staff_employments_staff_person_uuid_fkey FOREIGN KEY (staff_person_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_staff_people(uuid) ON DELETE CASCADE;


--
-- Name: phoenix_kit_staff_people phoenix_kit_staff_people_primary_department_uuid_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_staff_people
    ADD CONSTRAINT phoenix_kit_staff_people_primary_department_uuid_fkey FOREIGN KEY (primary_department_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_staff_departments(uuid) ON DELETE SET NULL;


--
-- Name: phoenix_kit_staff_people phoenix_kit_staff_people_user_uuid_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_staff_people
    ADD CONSTRAINT phoenix_kit_staff_people_user_uuid_fkey FOREIGN KEY (user_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_users(uuid) ON DELETE CASCADE;


--
-- Name: phoenix_kit_staff_person_skills phoenix_kit_staff_person_skills_skill_uuid_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_staff_person_skills
    ADD CONSTRAINT phoenix_kit_staff_person_skills_skill_uuid_fkey FOREIGN KEY (skill_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_staff_skills(uuid) ON DELETE CASCADE;


--
-- Name: phoenix_kit_staff_person_skills phoenix_kit_staff_person_skills_staff_person_uuid_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_staff_person_skills
    ADD CONSTRAINT phoenix_kit_staff_person_skills_staff_person_uuid_fkey FOREIGN KEY (staff_person_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_staff_people(uuid) ON DELETE CASCADE;


--
-- Name: phoenix_kit_staff_team_memberships phoenix_kit_staff_team_memberships_staff_person_uuid_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_staff_team_memberships
    ADD CONSTRAINT phoenix_kit_staff_team_memberships_staff_person_uuid_fkey FOREIGN KEY (staff_person_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_staff_people(uuid) ON DELETE CASCADE;


--
-- Name: phoenix_kit_staff_team_memberships phoenix_kit_staff_team_memberships_team_uuid_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_staff_team_memberships
    ADD CONSTRAINT phoenix_kit_staff_team_memberships_team_uuid_fkey FOREIGN KEY (team_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_staff_teams(uuid) ON DELETE CASCADE;


--
-- Name: phoenix_kit_staff_teams phoenix_kit_staff_teams_department_uuid_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_staff_teams
    ADD CONSTRAINT phoenix_kit_staff_teams_department_uuid_fkey FOREIGN KEY (department_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_staff_departments(uuid) ON DELETE CASCADE;


--
-- Name: phoenix_kit_subscriptions phoenix_kit_subscriptions_subscription_type_uuid_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_subscriptions
    ADD CONSTRAINT phoenix_kit_subscriptions_subscription_type_uuid_fkey FOREIGN KEY (subscription_type_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_subscription_types(uuid) ON DELETE SET NULL;


--
-- Name: phoenix_kit_ticket_attachments phoenix_kit_ticket_attachments_comment_id_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_ticket_attachments
    ADD CONSTRAINT phoenix_kit_ticket_attachments_comment_id_fkey FOREIGN KEY (comment_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_ticket_comments(uuid) ON DELETE CASCADE;


--
-- Name: phoenix_kit_ticket_attachments phoenix_kit_ticket_attachments_file_id_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_ticket_attachments
    ADD CONSTRAINT phoenix_kit_ticket_attachments_file_id_fkey FOREIGN KEY (file_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_files(uuid) ON DELETE CASCADE;


--
-- Name: phoenix_kit_ticket_attachments phoenix_kit_ticket_attachments_ticket_id_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_ticket_attachments
    ADD CONSTRAINT phoenix_kit_ticket_attachments_ticket_id_fkey FOREIGN KEY (ticket_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_tickets(uuid) ON DELETE CASCADE;


--
-- Name: phoenix_kit_ticket_comments phoenix_kit_ticket_comments_parent_id_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_ticket_comments
    ADD CONSTRAINT phoenix_kit_ticket_comments_parent_id_fkey FOREIGN KEY (parent_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_ticket_comments(uuid) ON DELETE CASCADE;


--
-- Name: phoenix_kit_ticket_comments phoenix_kit_ticket_comments_ticket_id_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_ticket_comments
    ADD CONSTRAINT phoenix_kit_ticket_comments_ticket_id_fkey FOREIGN KEY (ticket_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_tickets(uuid) ON DELETE CASCADE;


--
-- Name: phoenix_kit_ticket_status_history phoenix_kit_ticket_status_history_ticket_id_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_ticket_status_history
    ADD CONSTRAINT phoenix_kit_ticket_status_history_ticket_id_fkey FOREIGN KEY (ticket_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_tickets(uuid) ON DELETE CASCADE;


--
-- Name: phoenix_kit_user_known_devices phoenix_kit_user_known_devices_user_uuid_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_user_known_devices
    ADD CONSTRAINT phoenix_kit_user_known_devices_user_uuid_fkey FOREIGN KEY (user_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_users(uuid) ON DELETE CASCADE;


--
-- Name: phoenix_kit_users phoenix_kit_users_organization_uuid_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_users
    ADD CONSTRAINT phoenix_kit_users_organization_uuid_fkey FOREIGN KEY (organization_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_users(uuid) ON DELETE SET NULL;


--
-- Name: phoenix_kit_warehouse_goods_issues phoenix_kit_warehouse_goods_issues_internal_order_uuid_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_warehouse_goods_issues
    ADD CONSTRAINT phoenix_kit_warehouse_goods_issues_internal_order_uuid_fkey FOREIGN KEY (internal_order_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_warehouse_internal_orders(uuid) ON DELETE SET NULL;


--
-- Name: phoenix_kit_warehouse_goods_issues phoenix_kit_warehouse_goods_issues_performed_by_uuid_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_warehouse_goods_issues
    ADD CONSTRAINT phoenix_kit_warehouse_goods_issues_performed_by_uuid_fkey FOREIGN KEY (performed_by_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_users(uuid) ON DELETE SET NULL;


--
-- Name: phoenix_kit_warehouse_goods_receipts phoenix_kit_warehouse_goods_receipts_performed_by_uuid_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_warehouse_goods_receipts
    ADD CONSTRAINT phoenix_kit_warehouse_goods_receipts_performed_by_uuid_fkey FOREIGN KEY (performed_by_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_users(uuid) ON DELETE SET NULL;


--
-- Name: phoenix_kit_warehouse_goods_receipts phoenix_kit_warehouse_goods_receipts_supplier_order_uuid_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_warehouse_goods_receipts
    ADD CONSTRAINT phoenix_kit_warehouse_goods_receipts_supplier_order_uuid_fkey FOREIGN KEY (supplier_order_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_warehouse_supplier_orders(uuid) ON DELETE SET NULL;


--
-- Name: phoenix_kit_warehouse_internal_orders phoenix_kit_warehouse_internal_orders_performed_by_uuid_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_warehouse_internal_orders
    ADD CONSTRAINT phoenix_kit_warehouse_internal_orders_performed_by_uuid_fkey FOREIGN KEY (performed_by_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_users(uuid) ON DELETE SET NULL;


--
-- Name: phoenix_kit_warehouse_inventory_documents phoenix_kit_warehouse_inventory_document_performed_by_uuid_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_warehouse_inventory_documents
    ADD CONSTRAINT phoenix_kit_warehouse_inventory_document_performed_by_uuid_fkey FOREIGN KEY (performed_by_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_users(uuid) ON DELETE SET NULL;


--
-- Name: phoenix_kit_warehouse_supplier_orders phoenix_kit_warehouse_supplier_orders_internal_order_uuid_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_warehouse_supplier_orders
    ADD CONSTRAINT phoenix_kit_warehouse_supplier_orders_internal_order_uuid_fkey FOREIGN KEY (internal_order_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_warehouse_internal_orders(uuid) ON DELETE SET NULL;


--
-- Name: phoenix_kit_warehouse_supplier_orders phoenix_kit_warehouse_supplier_orders_performed_by_uuid_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_warehouse_supplier_orders
    ADD CONSTRAINT phoenix_kit_warehouse_supplier_orders_performed_by_uuid_fkey FOREIGN KEY (performed_by_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_users(uuid) ON DELETE SET NULL;


--
-- Name: phoenix_kit_warehouse_transfers phoenix_kit_warehouse_transfers_performed_by_uuid_fkey; Type: FK CONSTRAINT; Schema: pk_sqv_s1a; Owner: -
--

ALTER TABLE ONLY pk_sqv_s1a.phoenix_kit_warehouse_transfers
    ADD CONSTRAINT phoenix_kit_warehouse_transfers_performed_by_uuid_fkey FOREIGN KEY (performed_by_uuid) REFERENCES pk_sqv_s1a.phoenix_kit_users(uuid) ON DELETE SET NULL;


--
-- PostgreSQL database dump complete
--

\unrestrict 7FQvLeKrNICKnYbtiHA6y8JANc8dLn8m5TdWklf1oqSfCM0JlydL5LGHKTSM78V


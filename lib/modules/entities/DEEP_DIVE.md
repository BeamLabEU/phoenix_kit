# PhoenixKit Entities System – Deep Dive

**Dynamic Content Types for Elixir/Phoenix**

> Looking for the summary? Start with `OVERVIEW.md` in this directory. This deep dive captures the architecture, rationale, and implementation details behind the feature.

## Table of Contents

1. [Overview](#overview)
2. [Architecture](#architecture)
3. [Database Schema](#database-schema)
4. [Field Types System](#field-types-system)
5. [Core Modules](#core-modules)
6. [Admin Interfaces](#admin-interfaces)
7. [Public Form Builder](#public-form-builder)
8. [HTML Sanitization](#html-sanitization)
9. [Real-Time Collaboration](#real-time-collaboration)
10. [Multi-Language Support](#multi-language-support)
11. [Usage Examples](#usage-examples)
12. [Implementation Details](#implementation-details)
13. [Settings Integration](#settings-integration)

---

## Overview

The PhoenixKit Entities System is a dynamic content type management system. It allows administrators to create custom content types (entities) with flexible field schemas without writing code or running database migrations.

### Key Features

- **Dynamic Schema Creation**: Create custom content types with flexible field definitions stored as JSONB
- **12 Field Types**: Comprehensive field type support including text, textarea, email, url, number, boolean, date, select, radio, checkbox, rich text, and file. *(Image and relation fields exist in the form builder as placeholders but are not registered in FieldTypes.)*
- **Admin Interfaces**: Complete CRUD interfaces for both entity definitions and entity data
- **Dynamic Form Generation**: Forms automatically generated from entity field definitions
- **System-Wide Toggle**: Enable/disable the entire entities system via Settings
- **Status Workflow**: Draft → Published → Archived status for both entities and data records
- **Field Validation**: Comprehensive validation including unique field key enforcement
- **Performance Trade-off**: Accepts 1.5-2x performance cost for schema flexibility using PostgreSQL JSONB

### Use Cases

- **Blog Posts**: Title, content, excerpt, category, featured image, publish date
- **Products**: Name, price, description, SKU, images, variants
- **Team Members**: Name, role, bio, photo, social links
- **Events**: Title, date, location, description, registration link
- **Any Structured Content**: Create custom content types for any business need

---

## Architecture

### Two-Table Design

The system uses a two-table architecture that separates entity definitions (blueprints) from actual data records:

```
┌─────────────────────────────┐
│  phoenix_kit_entities       │  (Entity Definitions)
│  - Content type blueprints  │
│  - Field definitions (JSONB)│
│  - Settings (JSONB)         │
└──────────────┬──────────────┘
               │ 1:N
               │
┌──────────────▼──────────────┐
│  phoenix_kit_entity_data    │  (Entity Data Records)
│  - Actual data records      │
│  - Field values (JSONB)     │
│  - Metadata (JSONB)         │
└─────────────────────────────┘
```

### Why JSONB?

**Advantages:**
- **Schema Flexibility**: Create new content types without migrations
- **Rapid Development**: No code changes needed for new field types
- **Dynamic Forms**: Forms generated at runtime from definitions
- **PostgreSQL Native**: Leverages PostgreSQL's powerful JSONB support

**Trade-offs:**
- **Performance**: 1.5-2x slower than normalized tables (acceptable for admin interfaces)
- **No Foreign Keys**: Field-level relationships require application-level enforcement
- **Indexing Limitations**: Complex queries on JSONB fields can be slower

**Benchmark Data** (referenced during design):
- Normalized schema: ~2000 inserts/sec
- JSONB schema: ~1200 inserts/sec
- Read performance: Similar with proper indexing

---

## Database Schema

### Migration: V17

**File**: `lib/phoenix_kit/migrations/postgres/v17.ex`

### phoenix_kit_entities (Entity Definitions)

Stores content type blueprints with field definitions.

| Column              | Type              | Description                                      |
|---------------------|-------------------|--------------------------------------------------|
| `id`                | integer           | Primary key                                      |
| `name`              | string            | Unique technical identifier (snake_case)         |
| `display_name`      | string            | Human-readable name for UI                       |
| `description`       | text              | Description of what this entity represents       |
| `icon`              | string            | Heroicon name for UI display                     |
| `status`            | string            | draft / published / archived                     |
| `fields_definition` | jsonb             | Array of field definitions                       |
| `settings`          | jsonb             | Entity-specific settings                         |
| `created_by`        | integer           | User ID of creator                               |
| `date_created`      | utc_datetime | Creation timestamp                               |
| `date_updated`      | utc_datetime | Last update timestamp                            |

**Indexes:**
- Unique index on `name`
- Index on `created_by`
- Index on `status`

**Example Entity Record:**

```elixir
%PhoenixKit.Modules.Entities{
  id: 1,
  name: "blog_post",
  display_name: "Blog Post",
  description: "Blog post content type with rich text support",
  icon: "hero-document-text",
  status: "published",
  fields_definition: [
    %{
      "type" => "text",
      "key" => "title",
      "label" => "Title",
      "required" => true
    },
    %{
      "type" => "rich_text",
      "key" => "content",
      "label" => "Content",
      "required" => true
    },
    %{
      "type" => "select",
      "key" => "category",
      "label" => "Category",
      "required" => false,
      "options" => ["Tech", "Business", "Lifestyle"]
    }
  ],
  created_by: 1,
  date_created: ~U[2025-01-15 10:30:00.000000Z],
  date_updated: ~U[2025-01-15 10:30:00.000000Z]
}
```

### phoenix_kit_entity_data (Data Records)

Stores actual content records based on entity blueprints.

| Column         | Type              | Description                                      |
|----------------|-------------------|--------------------------------------------------|
| `id`           | integer           | Primary key                                      |
| `entity_id`    | integer           | Foreign key to phoenix_kit_entities              |
| `title`        | string            | Record title (duplicated for indexing)           |
| `slug`         | string            | URL-friendly identifier                          |
| `status`       | string            | draft / published / archived                     |
| `data`         | jsonb             | All field values as key-value pairs              |
| `metadata`     | jsonb             | Additional metadata (tags, categories, etc.)     |
| `created_by`   | integer           | User ID of creator                               |
| `date_created` | utc_datetime | Creation timestamp                               |
| `date_updated` | utc_datetime | Last update timestamp                            |

**Indexes:**
- Index on `entity_id`
- Index on `slug`
- Index on `status`
- Index on `created_by`
- Index on `title`

**Foreign Key:**
- `entity_id` references `phoenix_kit_entities(id)` with `on_delete: :delete_all`

**Example Data Record:**

```elixir
%PhoenixKit.Modules.Entities.EntityData{
  id: 1,
  entity_id: 1,
  title: "Getting Started with PhoenixKit",
  slug: "getting-started-with-phoenixkit",
  status: "published",
  data: %{
    "title" => "Getting Started with PhoenixKit",
    "content" => "<p>Welcome to PhoenixKit...</p>",
    "category" => "Tech"
  },
  metadata: %{
    "tags" => ["tutorial", "beginner"],
    "featured" => true
  },
  created_by: 1,
  date_created: ~U[2025-01-15 11:00:00.000000Z],
  date_updated: ~U[2025-01-15 11:00:00.000000Z]
}
```

---

## Field Types System

**File**: `lib/modules/entities/field_types.ex`

The system supports 11 fully functional field types organized into 5 categories, plus 3 placeholder types for future implementation:

### Basic Fields

| Type         | Label              | Description                           | Requires Options |
|--------------|--------------------| --------------------------------------|------------------|
| `text`       | Text               | Single-line text input                | No               |
| `textarea`   | Text Area          | Multi-line text input                 | No               |
| `email`      | Email              | Email address input with validation   | No               |
| `url`        | URL                | URL input with validation             | No               |
| `rich_text`  | Rich Text Editor   | WYSIWYG editor for formatted content  | No               |

### Numeric Fields

| Type         | Label              | Description                           | Requires Options |
|--------------|--------------------| --------------------------------------|------------------|
| `number`     | Number             | Numeric input (integer or decimal)    | No               |

### Boolean Fields

| Type         | Label              | Description                           | Requires Options |
|--------------|--------------------| --------------------------------------|------------------|
| `boolean`    | Boolean            | True/false toggle or checkbox         | No               |

### Date & Time Fields

| Type         | Label              | Description                           | Requires Options |
|--------------|--------------------| --------------------------------------|------------------|
| `date`       | Date               | Date picker                           | No               |

### Choice Fields

| Type         | Label              | Description                           | Requires Options |
|--------------|--------------------| --------------------------------------|------------------|
| `select`     | Select Dropdown    | Single choice from dropdown           | **Yes**          |
| `radio`      | Radio Buttons      | Single choice from radio buttons      | **Yes**          |
| `checkbox`   | Checkboxes         | Multiple choices from checkboxes      | **Yes**          |

### Media Fields

| Type         | Label              | Description                           | Requires Options | Status |
|--------------|--------------------| --------------------------------------|------------------|--------|
| `file`       | File Upload        | File upload with configurable constraints | No           | **Registered** |
| `image`      | Image Upload       | Image file upload                     | No               | Placeholder UI |

> **Note**: `file` is fully registered in `FieldTypes` and can be created via `file_field/3`. `image` is defined in the form builder schema but renders a "Coming Soon" placeholder — no actual image upload functionality is implemented yet.

### Relational Fields *(Coming Soon)*

| Type         | Label              | Description                           | Requires Options | Status |
|--------------|--------------------| --------------------------------------|------------------|--------|
| `relation`   | Relation           | Relationship to other entity records  | **Yes**          | Placeholder UI |

> **Note**: Relation fields are defined in the schema but render "Coming Soon" placeholders. The `entities_allow_relations` setting exists but is not yet enforced.

### Field Definition Structure

Each field in `fields_definition` is a map with the following structure:

```elixir
%{
  "type" => "text",              # Field type (required)
  "key" => "field_name",         # Unique identifier (required, snake_case)
  "label" => "Field Name",       # Display label (required)
  "required" => true,            # Whether field is required (optional, default: false)
  "default" => "default value",  # Default value (optional)
  "options" => ["Option 1", "Option 2"]  # Options for choice fields (required for select/radio/checkbox; relation will also require options once implemented)
}
```

### Field Validation

The `FieldTypes.validate_field/1` function validates:

1. **Required Keys**: `type`, `key`, `label` must be present
2. **Valid Type**: Type must be one of the 11 registered types (image/file/relation are not in the registry)
3. **Options Presence**: Choice fields (select/radio/checkbox) must have options array
4. **Options Content**: Options must be non-empty for fields that require them
5. **Unique Keys**: Field keys must be unique within an entity (enforced at LiveView level)

> **Note**: The form builder renders placeholder UI for image/file/relation types, but `FieldTypes.valid_type?/1` will reject them since they're not in the registry.

**Validation Examples:**

```elixir
# Valid field
{:ok, validated_field} = FieldTypes.validate_field(%{
  "type" => "text",
  "key" => "title",
  "label" => "Title",
  "required" => true
})

# Missing required key
{:error, "Field missing required keys: type"} = FieldTypes.validate_field(%{
  "key" => "title",
  "label" => "Title"
})

# Invalid type
{:error, "Invalid field type 'invalid_type'"} = FieldTypes.validate_field(%{
  "type" => "invalid_type",
  "key" => "title",
  "label" => "Title"
})

# Select without options
{:error, "Field type 'select' requires options array"} = FieldTypes.validate_field(%{
  "type" => "select",
  "key" => "category",
  "label" => "Category"
})

# Duplicate field key (LiveView validation)
{:error, "Field key 'title' already exists. Please use a unique key."} =
  validate_unique_field_key(field_params, existing_fields, editing_index)
```

---

## Core Modules

### 1. PhoenixKit.Modules.Entities

**File**: `lib/modules/entities/entities.ex`

Main module for entity management with both Ecto schema and business logic.

**Key Functions:**

```elixir
# List all entities
PhoenixKit.Modules.Entities.list_entities()
# => [%PhoenixKit.Modules.Entities{}, ...]

# List only published entities
PhoenixKit.Modules.Entities.list_active_entities()
# => [%PhoenixKit.Modules.Entities{status: "published"}, ...]

# Get entity by ID (raises if not found)
PhoenixKit.Modules.Entities.get_entity!(1)
# => %PhoenixKit.Modules.Entities{}

# Get entity by ID (returns nil if not found)
PhoenixKit.Modules.Entities.get_entity(1)
# => %PhoenixKit.Modules.Entities{} | nil

# Get entity by unique name
PhoenixKit.Modules.Entities.get_entity_by_name("blog_post")
# => %PhoenixKit.Modules.Entities{}

# Create entity
# Note: created_by is optional - it auto-fills with first admin user if not provided
PhoenixKit.Modules.Entities.create_entity(%{
  name: "blog_post",
  display_name: "Blog Post",
  description: "Blog post content type",
  icon: "hero-document-text",
  status: "draft",
  # created_by: user_id,  # Optional! Auto-filled if omitted
  fields_definition: [...]
})
# => {:ok, %PhoenixKit.Modules.Entities{}}

# Update entity
PhoenixKit.Modules.Entities.update_entity(entity, %{status: "published"})
# => {:ok, %PhoenixKit.Modules.Entities{}}

# Delete entity (also deletes all associated data)
PhoenixKit.Modules.Entities.delete_entity(entity)
# => {:ok, %PhoenixKit.Modules.Entities{}}

# Get changeset for forms
PhoenixKit.Modules.Entities.change_entity(entity, attrs)
# => %Ecto.Changeset{}

# System stats
PhoenixKit.Modules.Entities.get_system_stats()
# => %{total_entities: 5, active_entities: 4, total_data_records: 150}

# Check if enabled
PhoenixKit.Modules.Entities.enabled?()
# => true

# Enable/disable system
PhoenixKit.Modules.Entities.enable_system()
PhoenixKit.Modules.Entities.disable_system()
```

**Validations:**

- **Name**: 2-50 characters, snake_case, unique
- **Display Name**: 2-100 characters
- **Description**: Max 500 characters
- **Status**: Must be "draft", "published", or "archived"
- **Fields Definition**: Must be valid array of field definitions
- **Timestamps**: Auto-set on create/update

### 2. PhoenixKit.Modules.Entities.EntityData

**File**: `lib/modules/entities/entity_data.ex`

Module for entity data records with dynamic validation.

**Key Functions:**

```elixir
# List all data for an entity
PhoenixKit.Modules.Entities.EntityData.list_by_entity(entity_id)
# => [%PhoenixKit.Modules.Entities.EntityData{}, ...]

# List all data across all entities
PhoenixKit.Modules.Entities.EntityData.list_all()
# => [%PhoenixKit.Modules.Entities.EntityData{}, ...]

# Get data record by ID (raises if not found)
PhoenixKit.Modules.Entities.EntityData.get!(id)
# => %PhoenixKit.Modules.Entities.EntityData{}

# Get data record by ID (returns nil if not found)
PhoenixKit.Modules.Entities.EntityData.get(id)
# => %PhoenixKit.Modules.Entities.EntityData{} | nil

# Create data record
# Note: created_by is optional - it auto-fills with first admin user if not provided
PhoenixKit.Modules.Entities.EntityData.create(%{
  entity_id: 1,
  title: "My First Post",
  slug: "my-first-post",
  status: "draft",
  data: %{"title" => "My First Post", "content" => "..."}
  # created_by: user_id  # Optional! Auto-filled if omitted
})
# => {:ok, %PhoenixKit.Modules.Entities.EntityData{}}

# Update data record
PhoenixKit.Modules.Entities.EntityData.update(data_record, %{status: "published"})
# => {:ok, %PhoenixKit.Modules.Entities.EntityData{}}

# Delete data record
PhoenixKit.Modules.Entities.EntityData.delete(data_record)
# => {:ok, %PhoenixKit.Modules.Entities.EntityData{}}

# Get changeset
PhoenixKit.Modules.Entities.EntityData.change(data_record, attrs)
# => %Ecto.Changeset{}
```

**Dynamic Validation:**

The `validate_data_against_entity/1` function validates data records against their entity's field definitions:

1. **Required Fields**: Ensures all required fields have values
2. **Field Types**: Validates values match field type expectations
3. **Options**: For choice fields, validates values are in allowed options
4. **Data Completeness**: Ensures data map contains entries for defined fields

### 3. PhoenixKit.Modules.Entities.FieldTypes

**File**: `lib/modules/entities/field_types.ex`

Field type definitions and validation.

**Key Functions:**

```elixir
# Get all field types
PhoenixKit.Modules.Entities.FieldTypes.all()
# => %{"text" => %{name: "text", label: "Text", ...}, ...}

# Get field types by category
PhoenixKit.Modules.Entities.FieldTypes.by_category(:basic)
# => [%{name: "text", label: "Text", ...}, ...]

# Get category list
PhoenixKit.Modules.Entities.FieldTypes.category_list()
# => [{:basic, "Basic Fields"}, {:numeric, "Numeric"}, ...]

# Get specific type
PhoenixKit.Modules.Entities.FieldTypes.get_type("text")
# => %{name: "text", label: "Text", category: :basic, icon: "hero-document-text"}

# Check if type requires options
PhoenixKit.Modules.Entities.FieldTypes.requires_options?("select")
# => true

# Validate field definition
PhoenixKit.Modules.Entities.FieldTypes.validate_field(field_map)
# => {:ok, validated_field} | {:error, error_message}

# Format for picker UI
PhoenixKit.Modules.Entities.FieldTypes.for_picker()
# => Structured data for UI dropdowns

# Field Builder Helpers (for programmatic entity creation)
# These helpers make it easy to create field definitions with proper structure

# Create a field with options
PhoenixKit.Modules.Entities.FieldTypes.new_field("text", "title", "Title", required: true)
# => %{"type" => "text", "key" => "title", "label" => "Title", "required" => true, ...}

# Create choice fields with options
PhoenixKit.Modules.Entities.FieldTypes.select_field("category", "Category", ["Tech", "Business", "Other"])
# => %{"type" => "select", "key" => "category", "label" => "Category", "options" => [...], ...}

PhoenixKit.Modules.Entities.FieldTypes.radio_field("priority", "Priority", ["Low", "Medium", "High"])
# => %{"type" => "radio", "key" => "priority", "label" => "Priority", "options" => [...], ...}

PhoenixKit.Modules.Entities.FieldTypes.checkbox_field("tags", "Tags", ["Featured", "Popular", "New"])
# => %{"type" => "checkbox", "key" => "tags", "label" => "Tags", "options" => [...], ...}

# Convenience helpers for common field types
PhoenixKit.Modules.Entities.FieldTypes.text_field("name", "Full Name", required: true)
PhoenixKit.Modules.Entities.FieldTypes.textarea_field("bio", "Biography")
PhoenixKit.Modules.Entities.FieldTypes.email_field("email", "Email Address", required: true)
PhoenixKit.Modules.Entities.FieldTypes.number_field("age", "Age")
PhoenixKit.Modules.Entities.FieldTypes.boolean_field("active", "Is Active", default: true)
PhoenixKit.Modules.Entities.FieldTypes.rich_text_field("content", "Content")
```

### 4. PhoenixKit.Modules.Entities.FormBuilder

**File**: `lib/modules/entities/form_builder.ex`

Dynamic form generation from entity field definitions.

**Key Functions:**

```elixir
# Generate form fields from entity (returns Phoenix.Component HTML)
PhoenixKit.Modules.Entities.FormBuilder.build_fields(entity, changeset, opts \\ [])
# => Phoenix.LiveView.Rendered (HEEx template)

# Generate single field (multi-clause function handles all field types)
PhoenixKit.Modules.Entities.FormBuilder.build_field(field_definition, changeset, opts \\ [])
# => Phoenix.LiveView.Rendered (HEEx template)

# Validate entity data against field definitions
PhoenixKit.Modules.Entities.FormBuilder.validate_data(entity, data_params)
# => {:ok, validated_data} | {:error, errors}
```

**Options for build_fields/build_field:**

- `:wrapper_class` - CSS class for field wrapper divs
- `:input_class` - CSS class for input elements
- `:label_class` - CSS class for label elements

**Internal Field Rendering:**

The `build_field/3` function uses pattern matching on field type to render appropriate inputs.
Media fields (`image`, `file`) and relation fields render "Coming Soon" placeholders.

---

## Admin Interfaces

### 1. Entities Manager

**Route**: `/phoenix_kit/admin/entities`
**File**: `lib/modules/entities/web/entities.ex`
**Template**: `lib/modules/entities/web/entities.html.heex`

**Features:**

- List all entities with status badges (Draft/Published/Archived)
- System statistics cards (Total Entities, Active Entities, Data Records)
- Create new entity button
- Edit entity button for each entity
- View data button to browse entity records
- Delete entity with confirmation (cascades to all data)
- Empty state with helpful onboarding message

**LiveView Events:**

```elixir
handle_event("delete_entity", %{"id" => id}, socket)
```

### 2. Entity Form (Create/Edit)

**Routes**:
- Create: `/phoenix_kit/admin/entities/new`
- Edit: `/phoenix_kit/admin/entities/:id/edit`

**Files**:
- `lib/modules/entities/web/entity_form.ex`
- `lib/modules/entities/web/entity_form.html.heex`

**Features:**

- **Entity Metadata Section**:
  - Entity Name (technical identifier, snake_case)
  - Display Name (human-readable)
  - Icon (Heroicon name)
  - Status (draft/published/archived dropdown)
  - Description (optional)

- **Field Definitions Section**:
  - Add Field button
  - List of defined fields with:
    - Field icon, label, key, type, required status
    - Move Up/Down buttons for reordering
    - Edit button
    - Delete button with confirmation
  - Empty state when no fields defined

- **Field Form Modal**:
  - Field Type dropdown (organized by category)
  - Field Key input (snake_case, unique validation)
  - Field Label input
  - Required toggle
  - Default value input
  - Options management (for choice fields):
    - Add Option button
    - List of options with delete buttons
    - Empty state for options

- **Form Validation**:
  - Real-time validation with `phx-change="validate"`
  - Submit button disabled until valid and has fields
  - Flash messages for errors
  - Field key uniqueness enforcement

**LiveView Events:**

```elixir
handle_event("validate", %{"entities" => params}, socket)
handle_event("save", %{"entities" => params}, socket)
handle_event("add_field", _params, socket)
handle_event("edit_field", %{"index" => index}, socket)
handle_event("delete_field", %{"index" => index}, socket)
handle_event("move_field_up", %{"index" => index}, socket)
handle_event("move_field_down", %{"index" => index}, socket)
handle_event("save_field", %{"field" => params}, socket)
handle_event("cancel_field", _params, socket)
handle_event("update_field_form", %{"field" => params}, socket)
handle_event("add_option", _params, socket)
handle_event("remove_option", %{"index" => index}, socket)
handle_event("update_option", %{"index" => index, "value" => value}, socket)
```

### 3. Data Navigator

**Route**: `/phoenix_kit/admin/entities/:entity_slug/data`

**Files**:
- `lib/modules/entities/web/data_navigator.ex`
- `lib/modules/entities/web/data_navigator.html.heex`

> **Note**: The route requires `:entity_slug`. The LiveView mounts with a nil entity if the slug doesn't resolve to a valid entity.

**Features:**

- Browse a single entity's records in table or card layouts
- Status filters (all/published/draft/archived) and keyword search scoped to the selected entity
- At-a-glance stats (total/published/draft/archived) for that entity
- Quick navigation links back to the entity definition plus "Add" shortcuts for new data
- Row/card actions include view, edit, archive/restore, and status toggle buttons
- Empty states that prompt the user to publish an entity or add the first record

**LiveView Events:**

```elixir
handle_event("toggle_view_mode", _params, socket)   # Switch table/card view
handle_event("filter_by_status", %{"status" => status}, socket)
handle_event("search", %{"search" => %{"query" => query}}, socket)
handle_event("clear_filters", _params, socket)
handle_event("archive_data", %{"id" => id}, socket)
handle_event("restore_data", %{"id" => id}, socket)
handle_event("toggle_status", %{"id" => id}, socket)
```

### 4. Data Form (Create/Edit/View)

**Routes**:
- Create: `/phoenix_kit/admin/entities/:entity_slug/data/new`
- View: `/phoenix_kit/admin/entities/:entity_slug/data/:id`
- Edit: `/phoenix_kit/admin/entities/:entity_slug/data/:id/edit`

**Files**:
- `lib/modules/entities/web/data_form.ex`
- `lib/modules/entities/web/data_form.html.heex`
- `lib/modules/entities/web/data_view.ex` (for :show action)

> **Note**: Routes use `:entity_slug` (not `:entity_id`).

**Features:**

- **Record Metadata Section**:
  - Title (required, indexed)
  - Slug (optional, URL-friendly)
  - Status (draft/published/archived)

- **Dynamic Fields Section**:
  - Fields auto-generated from entity definition
  - Field types render appropriate inputs
  - Required field indicators
  - Help text from field labels

- **Three Modes**:
  - **View**: Read-only display of record
  - **Edit**: Editable form with save button
  - **Create**: New record form

**LiveView Events:**

```elixir
handle_event("validate", %{"entity_data" => params}, socket)
handle_event("save", %{"entity_data" => params}, socket)
```

---

## Public Form Builder

The Entities system includes a Public Form Builder that allows administrators to create embeddable forms for public-facing pages. This enables use cases like contact forms, lead capture, surveys, and user submissions.

### Overview

The Public Form Builder provides:

- **Embeddable Forms**: Use `<EntityForm entity_slug="contact" />` in publishing pages
- **Field Selection**: Choose which entity fields appear on the public form
- **Security Options**: Honeypot, time-based validation, and rate limiting
- **Configurable Actions**: Choose what happens when security checks trigger
- **Statistics Tracking**: Monitor submissions, rejections, and security events
- **Debug Mode**: Detailed error messages for troubleshooting

### Configuration

Public form settings are stored in the entity's `settings` JSONB column:

| Setting Key | Type | Default | Description |
|-------------|------|---------|-------------|
| `public_form_enabled` | boolean | false | Master toggle for public form |
| `public_form_fields` | array | [] | List of field keys to include |
| `public_form_title` | string | "" | Form title displayed to users |
| `public_form_description` | string | "" | Form description/instructions |
| `public_form_submit_text` | string | "Submit" | Submit button text |
| `public_form_success_message` | string | "Form submitted successfully!" | Success message |
| `public_form_collect_metadata` | boolean | true | Collect IP, browser, device info |
| `public_form_debug_mode` | boolean | false | Show detailed security errors |

### Security Options

#### Honeypot Protection

Adds a hidden field that bots typically fill out:

| Setting | Type | Default | Description |
|---------|------|---------|-------------|
| `public_form_honeypot` | boolean | false | Enable honeypot field |
| `public_form_honeypot_action` | string | "reject_silent" | Action when triggered |

#### Time-Based Validation

Rejects submissions that happen too quickly (less than 3 seconds):

| Setting | Type | Default | Description |
|---------|------|---------|-------------|
| `public_form_time_check` | boolean | false | Enable time validation |
| `public_form_time_check_action` | string | "reject_error" | Action when triggered |

#### Rate Limiting

Limits submissions per IP address (5 per minute):

| Setting | Type | Default | Description |
|---------|------|---------|-------------|
| `public_form_rate_limit` | boolean | false | Enable rate limiting |
| `public_form_rate_limit_action` | string | "reject_error" | Action when triggered |

### Security Actions

Each security option can be configured with one of four actions:

| Action | Description |
|--------|-------------|
| `reject_silent` | Show fake success message, don't save data |
| `reject_error` | Show error message to user, don't save data |
| `save_suspicious` | Save data with "draft" status, add security warnings to metadata |
| `save_log` | Save data normally, log warning for monitoring |

### Form Statistics

Statistics are automatically tracked in `settings["public_form_stats"]`:

```elixir
%{
  "total_submissions" => 150,
  "successful_submissions" => 142,
  "rejected_submissions" => 8,
  "honeypot_triggers" => 5,
  "too_fast_triggers" => 2,
  "rate_limited_triggers" => 1,
  "last_submission_at" => "2025-01-15T10:30:00Z"
}
```

### Submission Metadata

When `public_form_collect_metadata` is enabled, each submission includes:

```elixir
%{
  "source" => "public_form",
  "ip_address" => "192.168.1.1",
  "user_agent" => "Mozilla/5.0...",
  "browser" => "Chrome",
  "os" => "macOS",
  "device" => "desktop",
  "referer" => "https://example.com/contact",
  "form_loaded_at" => "2025-01-15T10:29:30Z",
  "submitted_at" => "2025-01-15T10:30:00Z",
  "time_to_submit_seconds" => 30,
  "security_warnings" => []  # Added if any security checks triggered with save actions
}
```

### Embedding Forms

Use the `<EntityForm>` component in publishing pages:

```heex
<EntityForm entity_slug="contact" />
```

The component:
1. Loads the entity by slug
2. Checks if public form is enabled AND has fields selected
3. Renders the form with selected fields only
4. Includes CSRF token, honeypot (if enabled), and timing data
5. Posts to `/phoenix_kit/entities/{slug}/submit`

### Controller Flow

**File**: `lib/phoenix_kit_web/controllers/entity_form_controller.ex`

1. **Validation**: Check entity exists and public form is enabled with fields
2. **Security Checks**: Run honeypot, time, and rate limit checks
3. **Handle Result**:
   - If any check triggers "reject" action → reject submission
   - If checks trigger "save" actions → save with flags
   - If all checks pass → save normally
4. **Statistics**: Update form statistics asynchronously
5. **Redirect**: Return to referrer with flash message

### Admin Interface

The Entity Form page includes a "Public Form Configuration" section when editing an entity:

1. **Enable/Disable Toggle**: Master switch for public form
2. **Form Details**: Title, description, submit text, success message
3. **Field Selection**: Checkboxes for each entity field
4. **Security Section**:
   - Collect Metadata toggle
   - Debug Mode toggle (with warning)
   - Honeypot Protection with action dropdown
   - Time-Based Validation with action dropdown
   - Rate Limiting with action dropdown
5. **Statistics Display**: Shows submission counts, security triggers, last submission time

### Security Warnings in Data View

When viewing a submission that triggered security checks (with save actions), the Data View shows:

- Alert banner with "Security Flags" heading
- Badges for each triggered check (Honeypot, Too Fast, Rate Limited)
- Action taken for each (Marked as suspicious, Logged warning)

---

## HTML Sanitization

Rich text fields are automatically sanitized to prevent XSS attacks.

### HtmlSanitizer Module

**File**: `lib/modules/entities/html_sanitizer.ex`

The sanitizer removes dangerous content while preserving safe HTML:

**Removed:**
- `<script>` tags and content
- `<style>` tags and content
- Event handlers (`onclick`, `onerror`, `onload`, etc.)
- `javascript:`, `vbscript:`, `data:` URLs
- Dangerous tags: `iframe`, `object`, `embed`, `form`, `input`, `button`, `meta`, `link`, `base`

**Preserved:**
- Block elements: `p`, `div`, `br`, `hr`, `h1-h6`, `blockquote`, `pre`, `code`
- Inline elements: `span`, `strong`, `b`, `em`, `i`, `u`, `s`, `a`, `sub`, `sup`, `mark`
- Lists: `ul`, `ol`, `li`
- Tables: `table`, `thead`, `tbody`, `tr`, `th`, `td`
- Images: `img` (with URL validation)

### Integration

Sanitization is integrated into the `EntityData` changeset pipeline:

```elixir
def changeset(entity_data, attrs) do
  entity_data
  |> cast(attrs, [...])
  |> validate_required([...])
  |> sanitize_rich_text_data()  # ← Sanitizes all rich_text fields
  |> validate_data_against_entity()
  |> ...
end
```

### Usage

```elixir
# Sanitize a single string
PhoenixKit.Modules.Entities.HtmlSanitizer.sanitize("<script>alert('xss')</script><p>Hello</p>")
# => "<p>Hello</p>"

# Sanitize all rich_text fields in data map
PhoenixKit.Modules.Entities.HtmlSanitizer.sanitize_rich_text_fields(fields_definition, data)
```

---

## Real-Time Collaboration

The entity form editor supports real-time collaboration with FIFO (First In, First Out) locking.

### Presence System

**Files**:
- `lib/modules/entities/presence.ex` - Phoenix.Presence wrapper
- `lib/modules/entities/presence_helpers.ex` - Helper functions

### How It Works

1. **First user** to open an entity form becomes the **lock owner** (can edit)
2. **Subsequent users** become **spectators** (read-only view)
3. **Spectators see live updates** as the owner makes changes
4. **When owner leaves**, the next spectator is automatically promoted to owner

### Presence Tracking

```elixir
# Track user presence when mounting (in LiveView mount)
PresenceHelpers.track_editing_session(:entity, entity.id, socket, current_user)
# => {:ok, ref}

# Get sorted presences (FIFO order)
presences = PresenceHelpers.get_sorted_presences(:entity, entity.id)
# => [{socket_id, %{user: %User{}, joined_at: timestamp}}, ...]

# Determine if current socket is owner or spectator
case PresenceHelpers.get_editing_role(:entity, entity.id, socket.id, current_user.id) do
  {:owner, all_presences} ->
    # This socket can edit

  {:spectator, owner_metadata, all_presences} ->
    # Read-only mode, sync with owner's state
end
```

### UI Indicators

The entity form shows:
- **Lock owner badge**: "Editing" with user name
- **Spectator list**: Shows all spectators with "Spectating" label
- **Read-only notice**: When viewing as spectator
- **Live updates**: Changes broadcast to all viewers

### Event Broadcasting

**File**: `lib/modules/entities/events.ex`

Changes are broadcast via Phoenix PubSub:

```elixir
# Subscribe to entity definition lifecycle events (create/update/delete)
Events.subscribe_to_entities()

# Subscribe to data lifecycle events for a specific entity
Events.subscribe_to_entity_data(entity.id)

# Subscribe to collaborative form events
Events.subscribe_to_entity_form(form_key)
Events.subscribe_to_data_form(entity_id, record_key)

# Broadcast entity lifecycle events
Events.broadcast_entity_created(entity.id)
Events.broadcast_entity_updated(entity.id)
Events.broadcast_entity_deleted(entity.id)

# Broadcast data lifecycle events
Events.broadcast_data_created(entity_id, data_id)
Events.broadcast_data_updated(entity_id, data_id)

# Handle incoming updates in LiveView
def handle_info({:entity_updated, entity_id}, socket)
def handle_info({:data_updated, entity_id, data_id}, socket)
```

---

## Multi-Language Support

The Entities system integrates with the **Languages module** to provide multilang content storage. When the Languages module is enabled with 2+ languages, all entities automatically support multilang data — no per-entity configuration needed.

### Architecture

The multilang system is built around three principles:

1. **Override-only storage** — Secondary languages only store fields that differ from primary. This minimizes storage and makes it clear what's been translated.
2. **Lazy migration** — Existing flat records are automatically wrapped into multilang structure on first edit. No bulk migration needed.
3. **Embedded primary** — Each record stores its own `_primary_language` key, allowing records created under different primary languages to coexist.

### Core Module: `PhoenixKit.Modules.Entities.Multilang`

Pure-function module with zero side effects. All functions operate on data maps without touching the database.

| Function | Purpose |
|----------|---------|
| `enabled?/0` | Checks Languages module has 2+ enabled languages |
| `primary_language/0` | Gets global default language code |
| `enabled_languages/0` | Lists all enabled language codes |
| `multilang_data?/1` | Detects `_primary_language` key in data map |
| `get_language_data/2` | Returns merged data for a language (primary base + overrides) |
| `get_primary_data/1` | Returns primary language data only |
| `get_raw_language_data/2` | Returns raw overrides only (for UI inherited-vs-override detection) |
| `put_language_data/3` | Merges form data into multilang JSONB (primary: all fields, secondary: overrides only) |
| `migrate_to_multilang/2` | Wraps flat data into multilang structure |
| `flatten_to_primary/1` | Extracts primary language data from multilang structure |
| `rekey_primary/2` | Changes primary language, promotes new primary to full data |
| `maybe_rekey_data/1` | Auto-rekeys if embedded primary differs from global |
| `build_language_tabs/0` | Builds language tab UI data with adaptive short codes |

### JSONB Data Structure

```
# Flat (single language)
data: {"name": "Acme", "category": "Tech"}

# Multilang
data: {
  "_primary_language": "en-US",
  "en-US": {"name": "Acme", "category": "Tech", "desc": "A company"},
  "es-ES": {"name": "Acme España"}          ← override only
}
```

The `_primary_language` key cannot collide with user field keys because field keys must match `^[a-z][a-z0-9_]*$` (start with lowercase letter).

### Translation Storage Locations

| Content | Primary language | Secondary languages |
|---------|-----------------|---------------------|
| Data custom fields | `data[primary_lang]` | `data[lang_code]` (overrides) |
| Record title | `title` column | `metadata["translations"][lang_code]["title"]` |
| Entity display_name | `display_name` column | `settings["translations"][lang_code]["display_name"]` |
| Entity description | `description` column | `settings["translations"][lang_code]["description"]` |

### Primary Language Re-keying

When the global primary language changes (via Languages admin), existing records have stale `_primary_language` values. The system handles this lazily:

1. **Read paths** (navigator, data view) use the **embedded** `_primary_language` — old records display correctly without any migration.
2. **Edit paths** (data form) detect the mismatch on mount and silently restructure:
   - Update `_primary_language` to the new global primary
   - Promote new primary to have all fields (missing fields filled from old primary)
   - Swap title between column and metadata translations
   - Changes persist when the user saves

This approach avoids bulk migrations and is idempotent — if the user doesn't save, re-keying happens again on next edit.

### Convenience API

The translation API provides high-level functions so that scripts and AI agents can manage translations without understanding the internal JSONB structure:

**Entity definitions** (`PhoenixKit.Modules.Entities`):
```elixir
Entities.set_entity_translation(entity, "es-ES", %{"display_name" => "Productos"})
Entities.get_entity_translation(entity, "es-ES")
Entities.get_entity_translations(entity)
Entities.remove_entity_translation(entity, "es-ES")
Entities.multilang_enabled?()
```

**Data records** (`PhoenixKit.Modules.Entities.EntityData`):
```elixir
EntityData.set_translation(record, "es-ES", %{"name" => "Acme España"})
EntityData.get_translation(record, "es-ES")
EntityData.get_all_translations(record)
EntityData.get_raw_translation(record, "es-ES")
EntityData.remove_translation(record, "es-ES")

EntityData.set_title_translation(record, "es-ES", "Mi Producto")
EntityData.get_title_translation(record, "es-ES")
EntityData.get_all_title_translations(record)
```

### Admin UI Behavior

- **Language tabs** appear in entity form and data form when multilang is enabled
- Translatable fields (display_name, title, custom fields) are inside the language tab area
- Non-translatable fields (slug, icon, status) are in a separate card
- Secondary language fields show primary values as ghost text (placeholders)
- Required field indicators (`*`) are hidden on secondary language tabs
- When >5 languages, tabs show adaptive short codes (EN, ES) with full names on hover
- Tabs wrap and use `|` separators in compact mode

### Known Limitations

| Limitation | Details | Workaround |
|------------|---------|------------|
| **Search is primary-language only** | The data navigator search queries the primary language data. Secondary language content is not included in search results. | Use the convenience API (`get_translation/2`) for programmatic cross-language search. |
| **Public form builder creates flat data** | The public-facing entity form (`EntityFormBuilder`) writes flat JSONB (no multilang structure). Records created via public forms only contain one language. | Edit the record in the admin UI to add translations, or use `set_translation/3` programmatically. |
| **Clearing a secondary field inherits from primary** | When a secondary language field is cleared (empty string), the display falls back to the primary language value. There is no way to set a field to explicitly empty. | This is by design — override-only storage treats empty as "not overridden". |
| **Entity definition translations are manual** | When the global primary language changes, entity definition translations (display_name, description) are not automatically re-keyed. | Edit the entity definition to enter the new primary language values manually. This is acceptable since entity definitions are low-volume. |
| **Un-saved re-keying is repeated** | Lazy re-keying on edit is not persisted until the user saves. If the user opens and closes without saving, re-keying happens again on next edit. | This is idempotent and by design. |

---

## Usage Examples

### Creating a Blog Post Entity

```elixir
# 1. Create the entity definition
{:ok, blog_entity} = PhoenixKit.Modules.Entities.create_entity(%{
  name: "blog_post",
  display_name: "Blog Post",
  description: "Blog post content type with rich text and categories",
  icon: "hero-document-text",
  status: "published",
  created_by: admin_user.id,
  fields_definition: [
    %{
      "type" => "text",
      "key" => "title",
      "label" => "Post Title",
      "required" => true
    },
    %{
      "type" => "textarea",
      "key" => "excerpt",
      "label" => "Excerpt",
      "required" => false
    },
    %{
      "type" => "rich_text",
      "key" => "content",
      "label" => "Post Content",
      "required" => true
    },
    %{
      "type" => "select",
      "key" => "category",
      "label" => "Category",
      "required" => true,
      "options" => ["Tech", "Business", "Lifestyle", "Tutorial"]
    },
    %{
      "type" => "boolean",
      "key" => "featured",
      "label" => "Featured Post",
      "required" => false,
      "default" => "false"
    },
    %{
      "type" => "date",
      "key" => "publish_date",
      "label" => "Publish Date",
      "required" => true
    },
    %{
      "type" => "image",
      "key" => "featured_image",
      "label" => "Featured Image",
      "required" => false
    }
  ]
})

# 2. Create blog post data records
{:ok, post} = PhoenixKit.Modules.Entities.EntityData.create(%{
  entity_id: blog_entity.id,
  title: "Getting Started with PhoenixKit Entities",
  slug: "getting-started-phoenixkit-entities",
  status: "published",
  created_by: author_user.id,
  data: %{
    "title" => "Getting Started with PhoenixKit Entities",
    "excerpt" => "Learn how to create dynamic content types...",
    "content" => "<h1>Introduction</h1><p>PhoenixKit Entities...</p>",
    "category" => "Tutorial",
    "featured" => true,
    "publish_date" => "2025-01-15",
    "featured_image" => "/uploads/blog-post-1.jpg"
  },
  metadata: %{
    "tags" => ["phoenixkit", "tutorial", "elixir"],
    "views" => 0,
    "likes" => 0
  }
})

# 3. Query published blog posts
published_posts =
  PhoenixKit.Modules.Entities.EntityData.list_by_entity(blog_entity.id)
  |> Enum.filter(&(&1.status == "published"))
  |> Enum.sort_by(&(&1.data["publish_date"]), :desc)
```

### Creating a Product Catalog

```elixir
{:ok, product_entity} = PhoenixKit.Modules.Entities.create_entity(%{
  name: "product",
  display_name: "Product",
  description: "Product catalog with pricing and inventory",
  icon: "hero-shopping-bag",
  status: "published",
  created_by: admin_user.id,
  fields_definition: [
    %{"type" => "text", "key" => "name", "label" => "Product Name", "required" => true},
    %{"type" => "textarea", "key" => "description", "label" => "Description", "required" => true},
    %{"type" => "number", "key" => "price", "label" => "Price (USD)", "required" => true},
    %{"type" => "text", "key" => "sku", "label" => "SKU", "required" => true},
    %{"type" => "number", "key" => "inventory", "label" => "Stock Quantity", "required" => true},
    %{"type" => "select", "key" => "category", "label" => "Category", "required" => true,
      "options" => ["Electronics", "Clothing", "Home & Garden", "Books"]},
    %{"type" => "image", "key" => "image", "label" => "Product Image", "required" => false},
    %{"type" => "boolean", "key" => "on_sale", "label" => "On Sale", "required" => false}
  ]
})
```

### Creating Team Members

```elixir
{:ok, team_entity} = PhoenixKit.Modules.Entities.create_entity(%{
  name: "team_member",
  display_name: "Team Member",
  description: "Team member profiles with bio and social links",
  icon: "hero-user-group",
  status: "published",
  created_by: admin_user.id,
  fields_definition: [
    %{"type" => "text", "key" => "name", "label" => "Full Name", "required" => true},
    %{"type" => "text", "key" => "role", "label" => "Job Title", "required" => true},
    %{"type" => "email", "key" => "email", "label" => "Email Address", "required" => true},
    %{"type" => "textarea", "key" => "bio", "label" => "Biography", "required" => false},
    %{"type" => "image", "key" => "photo", "label" => "Profile Photo", "required" => false},
    %{"type" => "url", "key" => "linkedin", "label" => "LinkedIn URL", "required" => false},
    %{"type" => "url", "key" => "twitter", "label" => "Twitter URL", "required" => false},
    %{"type" => "boolean", "key" => "active", "label" => "Currently Active", "required" => false}
  ]
})
```

---

## Implementation Details

### Status System Unification

Both entities and entity data use the same three-status workflow:

- **Draft**: Work in progress, not visible to public
- **Published**: Active and available for use
- **Archived**: Hidden but preserved for historical purposes

**Migration Change**: Originally, entity status was a boolean. Changed to string-based status in V17 migration to unify with entity_data status system.

### Field Key Uniqueness

**Problem**: Field keys are used as map keys in the JSONB `data` column. Duplicate keys would cause data loss and confusion.

**Solution**: Added `validate_unique_field_key/3` function in `entity_form_live.ex` that checks for duplicates before saving a field:

```elixir
defp validate_unique_field_key(field_params, existing_fields, editing_index) do
  new_key = field_params["key"]

  duplicate? =
    existing_fields
    |> Enum.with_index()
    |> Enum.any?(fn {field, index} ->
      field["key"] == new_key && index != editing_index
    end)

  if duplicate? do
    {:error, "Field key '#{new_key}' already exists. Please use a unique key."}
  else
    :ok
  end
end
```

**Enforcement**: Validation occurs in `handle_event("save_field", ...)` before calling `FieldTypes.validate_field/1`.

### Field Type Select Preservation

**Problem**: Field type dropdown was resetting during form validation due to LiveView re-rendering.

**Solution**: Added `selected={@field_form["type"] == type.name}` attribute to option tags to preserve selection:

```heex
<select name="field[type]" value={@field_form["type"]}>
  <%= for type <- FieldTypes.by_category(category_key) do %>
    <option value={type.name} selected={@field_form["type"] == type.name}>
      {type.label}
    </option>
  <% end %>
</select>
```

### Form State Management

**Challenge**: Maintaining form state during real-time validation without losing user input.

**Solution**: Separate `field_form` assign that updates via `phx-change="update_field_form"` event, merging new params with existing state:

```elixir
def handle_event("update_field_form", %{"field" => field_params}, socket) do
  current_form = socket.assigns.field_form
  updated_form = Map.merge(current_form, field_params)
  socket = assign(socket, :field_form, updated_form)
  {:noreply, socket}
end
```

### Navigation Hierarchy

**Challenge**: Keeping "Entities" nav item highlighted when viewing entity data or editing entities.

**Solution**: Implemented hierarchical path matching in `admin_nav.ex`:

```elixir
defp hierarchical_match?(current_parts, href_parts) do
  String.starts_with?(current_parts.base_path, href_parts.base_path <> "/")
end

defp parse_admin_path(path) do
  base_path = path
    |> String.replace_prefix(admin_prefix, "")
    |> String.trim_trailing("/")  # Fix trailing slash issue
    |> case do
      "" -> "dashboard"
      "/" -> "dashboard"
      path -> String.trim_leading(path, "/")
    end
  %{base_path: base_path}
end
```

### Conditional Navigation

**Feature**: Entities navigation menu items only appear when the system is enabled.

**Implementation**: Used `PhoenixKit.Modules.Entities.enabled?()` check in `layout_wrapper.ex`:

```heex
<%= if PhoenixKit.Modules.Entities.enabled?() do %>
  <.admin_nav_item
    href={Routes.locale_aware_path(assigns, "/admin/entities")}
    icon="entities"
    label="Entities"
    current_path={@current_path || ""}
  />

  <%= if submenu_open?(@current_path, ["/admin/entities"]) do %>
    <%!-- Dynamically list each published entity --%>
    <%= for entity <- PhoenixKit.Modules.Entities.list_entities() do %>
      <%= if entity.status == "published" do %>
        <.admin_nav_item
          href={Routes.locale_aware_path(assigns, "/admin/entities/#{entity.name}/data")}
          icon={entity.icon || "hero-cube"}
          label={entity.display_name_plural || entity.display_name}
          nested={true}
        />
      <% end %>
    <% end %>
  <% end %>
<% end %>
```

> **Note**: The sidebar dynamically lists each published entity with a link to its data navigator. There is no global `/admin/entities/data` route.

### Cascade Delete Protection

**Database Constraint**: Entity deletion cascades to all entity_data records via `on_delete: :delete_all` foreign key constraint.

**UI Confirmation**: Delete button includes data-confirm attribute:

```heex
<button
  phx-click="delete_entity"
  phx-value-id={entity.id}
  data-confirm="Are you sure you want to delete '#{entity.display_name}'? This will also delete all associated data records."
>
  Delete
</button>
```

---

## Settings Integration

### System Settings

The entities system integrates with PhoenixKit's Settings module using the `"entities"` module namespace.

**Settings Keys:**

| Key                         | Type    | Default | Description                                    |
|-----------------------------|---------|---------|------------------------------------------------|
| `entities_enabled`          | boolean | false   | Master toggle for entire entities system       |
| `entities_max_per_user`     | integer | 100     | Maximum entities a single user can create      |
| `entities_allow_relations`  | boolean | true    | Allow relation field type                      |
| `entities_file_upload`      | boolean | false   | Enable file/image upload functionality         |

**Created by V17 Migration:**

```sql
INSERT INTO phoenix_kit_settings (key, value, module, date_added, date_updated)
VALUES
  ('entities_enabled', 'false', 'entities', NOW(), NOW()),
  ('entities_max_per_user', '100', 'entities', NOW(), NOW()),
  ('entities_allow_relations', 'true', 'entities', NOW(), NOW()),
  ('entities_file_upload', 'false', 'entities', NOW(), NOW())
ON CONFLICT (key) DO NOTHING
```

### API Functions

```elixir
# Check if system is enabled
PhoenixKit.Modules.Entities.enabled?()
# => false

# Enable system
PhoenixKit.Modules.Entities.enable_system()
# => {:ok, %Setting{}}

# Disable system
PhoenixKit.Modules.Entities.disable_system()
# => {:ok, %Setting{}}

# Get max entities per user
PhoenixKit.Modules.Entities.get_max_per_user()
# => 100

# Validate user hasn't exceeded limit
PhoenixKit.Modules.Entities.validate_user_entity_limit(user_id)
# => {:ok, :valid} | {:error, "You have reached the maximum limit of 100 entities"}

# Get full config
PhoenixKit.Modules.Entities.get_config()
# => %{
#   enabled: false,
#   max_per_user: 100,
#   allow_relations: true,
#   file_upload: false
# }
```

### Modules System Integration

The entities system is integrated as a module in PhoenixKit's modules page at `/phoenix_kit/admin/modules`.

**Icon**: Uses the existing `hero-cube` icon provided by the core icon helper.

---

## Technical Decisions

### 1. JSONB vs Normalized Tables

**Decision**: Use JSONB for field definitions and data storage
**Rationale**: Schema flexibility outweighs 1.5-2x performance cost for admin interfaces
**Trade-off**: Accepted slower write performance for rapid development and zero-migration schema changes

### 2. Two-Table Architecture

**Decision**: Separate entity definitions from entity data
**Rationale**: Clean separation of concerns, efficient queries, proper normalization
**Alternative Considered**: Single table with entity definitions embedded in each record (rejected due to redundancy)

### 3. Status System Unification

**Decision**: Use draft/published/archived for both entities and entity_data
**Rationale**: Consistent workflow, clearer intent than boolean
**Change**: Rolled back V13 migration to convert boolean to string

### 4. Field Key Uniqueness

**Decision**: Enforce uniqueness at application level in LiveView
**Rationale**: JSONB doesn't support database-level key uniqueness constraints
**Implementation**: Validation in `validate_unique_field_key/3` before save

### 5. No Settings Page for Entities

**Decision**: Removed dedicated entities settings page
**Rationale**: System-wide settings sufficient, entity-specific settings deferred
**Future**: May add per-entity settings later if needed

### 6. Field Reordering

**Decision**: Manual up/down buttons instead of drag-and-drop
**Rationale**: Simpler implementation, no JavaScript required
**Future**: Could add drag-and-drop with LiveView JS hooks

### 7. Title Field Duplication

**Decision**: Duplicate title in both `title` column and `data["title"]`
**Rationale**: Indexed column for efficient sorting/searching while maintaining JSONB flexibility
**Trade-off**: Slight data redundancy for query performance

---

## Future Enhancements

### Planned Features

1. **Per-Entity Settings**: Custom settings for each entity (permissions, display options, API access)
2. **Validation Rules**: Min/max length, regex patterns, custom validation functions
3. **Field Dependencies**: Show/hide fields based on other field values
4. **Bulk Operations**: Import/export data, bulk status changes
5. **Revisions**: Version history for entity definitions and data
6. **API Generation**: Auto-generate REST/GraphQL APIs for entities
7. **Webhooks**: Trigger webhooks on create/update/delete events
8. **Media Library**: Centralized asset management for image/file fields
9. **Permissions**: Granular entity and field-level permissions
10. **Templates**: Pre-built entity templates (Blog, E-commerce, CRM, etc.)

### Technical Improvements

1. **JSONB Indexing**: Add GIN indexes for frequently queried JSONB paths
2. **Query Optimization**: Add list/search/filter helpers for entity data
3. **Caching**: Cache entity definitions to reduce database queries
4. **Validation Refinement**: More comprehensive field validation rules
5. **Type Coercion**: Automatic type conversion for field values
6. **Relations Implementation**: Complete relation field type functionality
7. **File Upload**: Implement actual file/image upload handlers
8. **Rich Text Editor**: Integrate actual WYSIWYG editor (TipTap, Quill, etc.)

---

## Performance Considerations

### JSONB Performance

**Write Performance**: 1.5-2x slower than normalized tables
**Read Performance**: Similar with proper indexing
**Query Performance**: Complex JSONB queries can be slower

**Mitigation Strategies**:
1. Index frequently queried columns (title, slug, status, created_by)
2. Duplicate critical fields outside JSONB for indexing (e.g., title)
3. Use JSONB operators and functions for efficient queries
4. Add GIN indexes on JSONB columns for contains operations

### Recommended Indexes

```sql
-- Already included in V13 migration
CREATE INDEX phoenix_kit_entities_status_idx ON phoenix_kit_entities(status);
CREATE INDEX phoenix_kit_entities_created_by_idx ON phoenix_kit_entities(created_by);
CREATE UNIQUE INDEX phoenix_kit_entities_name_uidx ON phoenix_kit_entities(name);

CREATE INDEX phoenix_kit_entity_data_entity_id_idx ON phoenix_kit_entity_data(entity_id);
CREATE INDEX phoenix_kit_entity_data_status_idx ON phoenix_kit_entity_data(status);
CREATE INDEX phoenix_kit_entity_data_title_idx ON phoenix_kit_entity_data(title);
CREATE INDEX phoenix_kit_entity_data_slug_idx ON phoenix_kit_entity_data(slug);
CREATE INDEX phoenix_kit_entity_data_created_by_idx ON phoenix_kit_entity_data(created_by);

-- Future: Add GIN indexes for JSONB queries
CREATE INDEX phoenix_kit_entity_data_data_gin_idx ON phoenix_kit_entity_data USING GIN (data);
```

### Query Examples

```sql
-- Efficient: Uses entity_id index
SELECT * FROM phoenix_kit_entity_data
WHERE entity_id = 1 AND status = 'published'
ORDER BY date_created DESC;

-- Efficient: Uses slug index
SELECT * FROM phoenix_kit_entity_data
WHERE slug = 'my-blog-post';

-- Less Efficient: JSONB field query (add GIN index)
SELECT * FROM phoenix_kit_entity_data
WHERE data @> '{"category": "Tech"}';

-- Efficient: Title column index
SELECT * FROM phoenix_kit_entity_data
WHERE title ILIKE '%phoenix%'
ORDER BY date_created DESC;
```

---

## Security Considerations

### Authentication & Authorization

- All entity admin routes require admin authentication via `on_mount: [{PhoenixKitWeb.Users.Auth, :phoenix_kit_ensure_admin}]`
- Entity creation tracks `created_by` user ID
- Future: Add granular permissions per entity

### Input Validation

- Entity names validated with regex: `^[a-z][a-z0-9_]*$`
- Field keys validated for uniqueness
- Field types validated against allowed list
- JSONB data validated against entity field definitions
- SQL injection prevented via Ecto parameterized queries

### Data Integrity

- Foreign key constraint ensures data deletion when entity deleted
- Unique constraints on entity names and field keys
- Required field validation enforced at application level
- Status validation prevents invalid states

### Best Practices

1. **Always validate field definitions** before saving entities
2. **Sanitize user input** for rich text fields (✅ implemented via HtmlSanitizer)
3. **Use parameterized queries** for all database operations (Ecto handles this)
4. **Audit trail**: Track who created/modified entities and data
5. **Rate limiting**: Consider rate limits on entity/data creation (✅ implemented for public forms)
6. **File uploads**: Validate file types and sizes (when implemented)

---

## Testing Strategy

### Unit Tests

Test core business logic:

```elixir
# Test entity CRUD
test "creates entity with valid attributes"
test "validates required fields"
test "enforces unique entity names"
test "validates status values"

# Test field validation
test "validates field type"
test "requires options for choice fields"
test "enforces field key uniqueness"

# Test entity data
test "creates data record"
test "validates against entity definition"
test "enforces required fields"
```

### Integration Tests

Test LiveView interactions:

```elixir
# Test entity form
test "creates entity through form", %{conn: conn}
test "validates entity form inputs"
test "adds field to entity"
test "prevents duplicate field keys"

# Test data form
test "creates data record through form"
test "validates data against entity definition"
test "displays validation errors"
```

### Database Tests

Test migrations and constraints:

```elixir
test "V13 migration creates tables"
test "cascade delete removes entity data"
test "unique constraint on entity name"
```

---

## Troubleshooting

### Common Issues

**Issue**: "Field key already exists" error
**Solution**: Each field key must be unique within an entity. Change the field key to a unique value.

**Issue**: "Field type requires options array" error
**Solution**: Select, radio, checkbox, and relation fields must have at least one option defined.

**Issue**: Entity not appearing in data navigator
**Solution**: Ensure entity status is "published" - only published entities can have data created.

**Issue**: Navigation not highlighting
**Solution**: Check for trailing slashes in URLs - navigation matching handles this automatically.

**Issue**: Form state resetting during validation
**Solution**: Ensure `phx-change="update_field_form"` is set and `field_form` assign is properly merged.

**Issue**: Entities menu not appearing
**Solution**: Enable the entities system via Settings or run `PhoenixKit.Modules.Entities.enable_system()`.

---

## API Reference

### PhoenixKit.Modules.Entities

```elixir
@type t :: %PhoenixKit.Modules.Entities{
  id: integer(),
  name: String.t(),
  display_name: String.t(),
  description: String.t() | nil,
  icon: String.t() | nil,
  status: String.t(),
  fields_definition: [map()],
  settings: map() | nil,
  created_by: integer(),
  date_created: DateTime.t(),
  date_updated: DateTime.t()
}

@spec list_entities() :: [t()]
@spec list_active_entities() :: [t()]
@spec get_entity!(integer()) :: t()
@spec get_entity(integer()) :: t() | nil
@spec get_entity_by_name(String.t()) :: t() | nil
@spec create_entity(map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
@spec update_entity(t(), map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
@spec delete_entity(t()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
@spec change_entity(t(), map()) :: Ecto.Changeset.t()
@spec enabled?() :: boolean()
@spec enable_system() :: {:ok, Setting.t()}
@spec disable_system() :: {:ok, Setting.t()}
@spec get_system_stats() :: map()

# Translation API
@spec multilang_enabled?() :: boolean()
@spec get_entity_translations(t()) :: map()
@spec get_entity_translation(t(), String.t()) :: map()
@spec set_entity_translation(t(), String.t(), map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
@spec remove_entity_translation(t(), String.t()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
```

Note: `create_entity/1` auto-fills `created_by` with the first admin user if not provided.

### PhoenixKit.Modules.Entities.EntityData

```elixir
@type t :: %PhoenixKit.Modules.Entities.EntityData{
  id: integer(),
  entity_id: integer(),
  title: String.t(),
  slug: String.t() | nil,
  status: String.t(),
  data: map(),
  metadata: map() | nil,
  created_by: integer(),
  date_created: DateTime.t(),
  date_updated: DateTime.t()
}

@spec list_by_entity(integer()) :: [t()]
@spec list_all() :: [t()]
@spec get!(integer()) :: t()
@spec get(integer()) :: t() | nil
@spec create(map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
@spec update(t(), map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
@spec delete(t()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
@spec change(t(), map()) :: Ecto.Changeset.t()

# Translation API
@spec get_translation(t(), String.t()) :: map()
@spec get_raw_translation(t(), String.t()) :: map()
@spec get_all_translations(t()) :: map()
@spec set_translation(t(), String.t(), map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
@spec remove_translation(t(), String.t()) :: {:ok, t()} | {:error, :cannot_remove_primary} | {:error, :not_multilang}
@spec get_title_translation(t(), String.t()) :: String.t() | nil
@spec set_title_translation(t(), String.t(), String.t()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
@spec get_all_title_translations(t()) :: map()
```

Note: `create/1` auto-fills `created_by` with the first admin user if not provided.

### PhoenixKit.Modules.Entities.Multilang

```elixir
@spec enabled?() :: boolean()
@spec primary_language() :: String.t()
@spec enabled_languages() :: [String.t()]
@spec multilang_data?(map() | nil) :: boolean()
@spec get_language_data(map() | nil, String.t()) :: map()
@spec get_primary_data(map() | nil) :: map()
@spec get_raw_language_data(map() | nil, String.t()) :: map()
@spec put_language_data(map() | nil, String.t(), map()) :: map()
@spec migrate_to_multilang(map() | nil, String.t()) :: map()
@spec flatten_to_primary(map() | nil) :: map()
@spec rekey_primary(map() | nil, String.t()) :: map()
@spec maybe_rekey_data(map() | nil) :: map() | nil
@spec build_language_tabs() :: [map()]
```

### PhoenixKit.Modules.Entities.FieldTypes

```elixir
@spec all() :: map()
@spec by_category(atom()) :: [map()]
@spec category_list() :: [{atom(), String.t()}]
@spec get_type(String.t()) :: map() | nil
@spec requires_options?(String.t()) :: boolean()
@spec validate_field(map()) :: {:ok, map()} | {:error, String.t()}
@spec for_picker() :: map()

# Field Builder Helpers
@spec new_field(String.t(), String.t(), String.t(), keyword()) :: map()
@spec select_field(String.t(), String.t(), [String.t()], keyword()) :: map()
@spec radio_field(String.t(), String.t(), [String.t()], keyword()) :: map()
@spec checkbox_field(String.t(), String.t(), [String.t()], keyword()) :: map()
@spec text_field(String.t(), String.t(), keyword()) :: map()
@spec textarea_field(String.t(), String.t(), keyword()) :: map()
@spec email_field(String.t(), String.t(), keyword()) :: map()
@spec number_field(String.t(), String.t(), keyword()) :: map()
@spec boolean_field(String.t(), String.t(), keyword()) :: map()
@spec rich_text_field(String.t(), String.t(), keyword()) :: map()
```

---

## Changelog

### V17 Migration (Initial Entities System)

**Added:**
- `phoenix_kit_entities` table for entity definitions
- `phoenix_kit_entity_data` table for data records
- JSONB support for flexible schemas
- Status system (draft/published/archived)
- Field types system with 11 functional types (+ 3 placeholder types for future)
- Admin interfaces for entity and data management
- Dynamic form generation
- Settings integration
- Navigation integration
- Field key uniqueness validation

**Database Schema:**
- Two main tables with indexes
- Foreign key cascade delete
- Unique constraints
- Four system settings keys

**Routes Added:**
- `/admin/entities` - List entities
- `/admin/entities/new` - Create entity
- `/admin/entities/:id/edit` - Edit entity
- `/admin/entities/:entity_slug/data` - Data navigator for entity
- `/admin/entities/:entity_slug/data/new` - Create data record
- `/admin/entities/:entity_slug/data/:id` - View data record
- `/admin/entities/:entity_slug/data/:id/edit` - Edit data record
- `/admin/settings/entities` - Entities module settings

### Multi-Language Support (2026-02)

**Added:**
- `Multilang` module — pure-function helpers for multilang JSONB data
- Language tabs in entity form, data form, and data view
- Override-only storage for secondary languages
- Ghost-text placeholders showing primary values on secondary tabs
- Adaptive compact tabs (short codes) for >5 languages
- Lazy re-keying when global primary language changes
- Translation convenience API on `Entities` and `EntityData` modules
- Multilang-aware category extraction and bulk operations

### Recent Updates (2025-12)

**Added:**
- Public Form Builder with embeddable forms
- Security options: honeypot, time-based validation, rate limiting
- Configurable security actions
- Form submission statistics tracking
- Debug mode for security troubleshooting
- HTML sanitization for rich_text fields (XSS prevention)
- Real-time collaboration with FIFO locking
- Presence tracking via Phoenix.Presence

---

## Credits

**Built with**: Elixir, Phoenix, Phoenix LiveView, PostgreSQL, Ecto, DaisyUI, Tailwind CSS
**Part of**: PhoenixKit - Phoenix Starter Kit with Authentication & Admin

---

## License

This entities system is part of PhoenixKit and follows the same license.

---

## Support

For issues, questions, or contributions related to the entities system:

1. Check this documentation first
2. Review the code examples and usage patterns
3. Test in your PhoenixKit installation
4. Report issues via PhoenixKit's issue tracker

---

**Last Updated**: 2026-02-18
**Version**: V17+ with Public Form Builder & Multi-Language Support
**Status**: Production Ready

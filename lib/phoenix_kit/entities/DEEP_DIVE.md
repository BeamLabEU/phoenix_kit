# PhoenixKit Entities System – Deep Dive

**WordPress ACF (Advanced Custom Fields) Equivalent for Elixir/Phoenix**

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
10. [Usage Examples](#usage-examples)
11. [Implementation Details](#implementation-details)
12. [Settings Integration](#settings-integration)

---

## Overview

The PhoenixKit Entities System is a dynamic content type management system inspired by WordPress Advanced Custom Fields (ACF). It allows administrators to create custom content types (entities) with flexible field schemas without writing code or running database migrations.

### Key Features

- **Dynamic Schema Creation**: Create custom content types with flexible field definitions stored as JSONB
- **13 Field Types**: Comprehensive field type support including text, number, boolean, date, select, radio, checkbox, rich text, image, file, and relation fields
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
| `date_created`      | utc_datetime_usec | Creation timestamp                               |
| `date_updated`      | utc_datetime_usec | Last update timestamp                            |

**Indexes:**
- Unique index on `name`
- Index on `created_by`
- Index on `status`

**Example Entity Record:**

```elixir
%PhoenixKit.Entities{
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
| `date_created` | utc_datetime_usec | Creation timestamp                               |
| `date_updated` | utc_datetime_usec | Last update timestamp                            |

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
%PhoenixKit.Entities.EntityData{
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

**File**: `lib/phoenix_kit/entities/field_types.ex`

The system supports 13 field types organized into 6 categories:

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

| Type         | Label              | Description                           | Requires Options |
|--------------|--------------------| --------------------------------------|------------------|
| `image`      | Image Upload       | Image file upload                     | No               |
| `file`       | File Upload        | Generic file upload                   | No               |

### Relational Fields

| Type         | Label              | Description                           | Requires Options |
|--------------|--------------------| --------------------------------------|------------------|
| `relation`   | Relation           | Relationship to other entity records  | **Yes**          |

### Field Definition Structure

Each field in `fields_definition` is a map with the following structure:

```elixir
%{
  "type" => "text",              # Field type (required)
  "key" => "field_name",         # Unique identifier (required, snake_case)
  "label" => "Field Name",       # Display label (required)
  "required" => true,            # Whether field is required (optional, default: false)
  "default" => "default value",  # Default value (optional)
  "options" => ["Option 1", "Option 2"]  # Options for choice/relation fields (required for select/radio/checkbox/relation)
}
```

### Field Validation

The `FieldTypes.validate_field/1` function validates:

1. **Required Keys**: `type`, `key`, `label` must be present
2. **Valid Type**: Type must be one of the 13 supported types
3. **Options Presence**: Choice and relation fields must have options array
4. **Options Content**: Options must be non-empty for fields that require them
5. **Unique Keys**: Field keys must be unique within an entity (enforced at LiveView level)

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

### 1. PhoenixKit.Entities

**File**: `lib/phoenix_kit/entities/entities.ex`

Main module for entity management with both Ecto schema and business logic.

**Key Functions:**

```elixir
# List all entities
PhoenixKit.Entities.list_entities()
# => [%PhoenixKit.Entities{}, ...]

# List only published entities
PhoenixKit.Entities.list_active_entities()
# => [%PhoenixKit.Entities{status: "published"}, ...]

# Get entity by ID (raises if not found)
PhoenixKit.Entities.get_entity!(1)
# => %PhoenixKit.Entities{}

# Get entity by ID (returns nil if not found)
PhoenixKit.Entities.get_entity(1)
# => %PhoenixKit.Entities{} | nil

# Get entity by unique name
PhoenixKit.Entities.get_entity_by_name("blog_post")
# => %PhoenixKit.Entities{}

# Create entity
# Note: created_by is optional - it auto-fills with first admin user if not provided
PhoenixKit.Entities.create_entity(%{
  name: "blog_post",
  display_name: "Blog Post",
  description: "Blog post content type",
  icon: "hero-document-text",
  status: "draft",
  # created_by: user_id,  # Optional! Auto-filled if omitted
  fields_definition: [...]
})
# => {:ok, %PhoenixKit.Entities{}}

# Update entity
PhoenixKit.Entities.update_entity(entity, %{status: "published"})
# => {:ok, %PhoenixKit.Entities{}}

# Delete entity (also deletes all associated data)
PhoenixKit.Entities.delete_entity(entity)
# => {:ok, %PhoenixKit.Entities{}}

# Get changeset for forms
PhoenixKit.Entities.change_entity(entity, attrs)
# => %Ecto.Changeset{}

# System stats
PhoenixKit.Entities.get_system_stats()
# => %{total_entities: 5, active_entities: 4, total_data_records: 150}

# Check if enabled
PhoenixKit.Entities.enabled?()
# => true

# Enable/disable system
PhoenixKit.Entities.enable_system()
PhoenixKit.Entities.disable_system()
```

**Validations:**

- **Name**: 2-50 characters, snake_case, unique
- **Display Name**: 2-100 characters
- **Description**: Max 500 characters
- **Status**: Must be "draft", "published", or "archived"
- **Fields Definition**: Must be valid array of field definitions
- **Timestamps**: Auto-set on create/update

### 2. PhoenixKit.Entities.EntityData

**File**: `lib/phoenix_kit/entities/entity_data.ex`

Module for entity data records with dynamic validation.

**Key Functions:**

```elixir
# List all data for an entity
PhoenixKit.Entities.EntityData.list_by_entity(entity_id)
# => [%PhoenixKit.Entities.EntityData{}, ...]

# List all data across all entities
PhoenixKit.Entities.EntityData.list_all()
# => [%PhoenixKit.Entities.EntityData{}, ...]

# Get data record by ID (raises if not found)
PhoenixKit.Entities.EntityData.get!(id)
# => %PhoenixKit.Entities.EntityData{}

# Get data record by ID (returns nil if not found)
PhoenixKit.Entities.EntityData.get(id)
# => %PhoenixKit.Entities.EntityData{} | nil

# Create data record
# Note: created_by is optional - it auto-fills with first admin user if not provided
PhoenixKit.Entities.EntityData.create(%{
  entity_id: 1,
  title: "My First Post",
  slug: "my-first-post",
  status: "draft",
  data: %{"title" => "My First Post", "content" => "..."}
  # created_by: user_id  # Optional! Auto-filled if omitted
})
# => {:ok, %PhoenixKit.Entities.EntityData{}}

# Update data record
PhoenixKit.Entities.EntityData.update(data_record, %{status: "published"})
# => {:ok, %PhoenixKit.Entities.EntityData{}}

# Delete data record
PhoenixKit.Entities.EntityData.delete(data_record)
# => {:ok, %PhoenixKit.Entities.EntityData{}}

# Get changeset
PhoenixKit.Entities.EntityData.change(data_record, attrs)
# => %Ecto.Changeset{}
```

**Dynamic Validation:**

The `validate_data_against_entity/1` function validates data records against their entity's field definitions:

1. **Required Fields**: Ensures all required fields have values
2. **Field Types**: Validates values match field type expectations
3. **Options**: For choice fields, validates values are in allowed options
4. **Data Completeness**: Ensures data map contains entries for defined fields

### 3. PhoenixKit.Entities.FieldTypes

**File**: `lib/phoenix_kit/entities/field_types.ex`

Field type definitions and validation.

**Key Functions:**

```elixir
# Get all field types
PhoenixKit.Entities.FieldTypes.all()
# => %{"text" => %{name: "text", label: "Text", ...}, ...}

# Get field types by category
PhoenixKit.Entities.FieldTypes.by_category(:basic)
# => [%{name: "text", label: "Text", ...}, ...]

# Get category list
PhoenixKit.Entities.FieldTypes.category_list()
# => [{:basic, "Basic Fields"}, {:numeric, "Numeric"}, ...]

# Get specific type
PhoenixKit.Entities.FieldTypes.get_type("text")
# => %{name: "text", label: "Text", category: :basic, icon: "hero-document-text"}

# Check if type requires options
PhoenixKit.Entities.FieldTypes.requires_options?("select")
# => true

# Validate field definition
PhoenixKit.Entities.FieldTypes.validate_field(field_map)
# => {:ok, validated_field} | {:error, error_message}

# Format for picker UI
PhoenixKit.Entities.FieldTypes.for_picker()
# => Structured data for UI dropdowns

# Field Builder Helpers (for programmatic entity creation)
# These helpers make it easy to create field definitions with proper structure

# Create a field with options
PhoenixKit.Entities.FieldTypes.new_field("text", "title", "Title", required: true)
# => %{"type" => "text", "key" => "title", "label" => "Title", "required" => true, ...}

# Create choice fields with options
PhoenixKit.Entities.FieldTypes.select_field("category", "Category", ["Tech", "Business", "Other"])
# => %{"type" => "select", "key" => "category", "label" => "Category", "options" => [...], ...}

PhoenixKit.Entities.FieldTypes.radio_field("priority", "Priority", ["Low", "Medium", "High"])
# => %{"type" => "radio", "key" => "priority", "label" => "Priority", "options" => [...], ...}

PhoenixKit.Entities.FieldTypes.checkbox_field("tags", "Tags", ["Featured", "Popular", "New"])
# => %{"type" => "checkbox", "key" => "tags", "label" => "Tags", "options" => [...], ...}

# Convenience helpers for common field types
PhoenixKit.Entities.FieldTypes.text_field("name", "Full Name", required: true)
PhoenixKit.Entities.FieldTypes.textarea_field("bio", "Biography")
PhoenixKit.Entities.FieldTypes.email_field("email", "Email Address", required: true)
PhoenixKit.Entities.FieldTypes.number_field("age", "Age")
PhoenixKit.Entities.FieldTypes.boolean_field("active", "Is Active", default: true)
PhoenixKit.Entities.FieldTypes.rich_text_field("content", "Content")
```

### 4. PhoenixKit.Entities.FormBuilder

**File**: `lib/phoenix_kit/entities/form_builder.ex`

Dynamic form generation from entity field definitions.

**Key Functions:**

```elixir
# Generate form fields from entity
PhoenixKit.Entities.FormBuilder.generate_fields(entity, changeset, assigns)
# => [rendered_field_components]

# Generate single field
PhoenixKit.Entities.FormBuilder.generate_field(field_def, form, assigns)
# => rendered_field_component

# Supported field renderers:
# - render_text_field/3
# - render_textarea_field/3
# - render_email_field/3
# - render_url_field/3
# - render_rich_text_field/3
# - render_number_field/3
# - render_boolean_field/3
# - render_date_field/3
# - render_select_field/3
# - render_radio_field/3
# - render_checkbox_field/3
# - render_image_field/3
# - render_file_field/3
# - render_relation_field/3
```

---

## Admin Interfaces

### 1. Entities Manager

**Route**: `/phoenix_kit/admin/entities`
**File**: `lib/phoenix_kit_web/live/entities/entities_live.ex`
**Template**: `lib/phoenix_kit_web/live/entities/entities_live.html.heex`

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
- `lib/phoenix_kit_web/live/entities/entity_form_live.ex`
- `lib/phoenix_kit_web/live/entities/entity_form_live.html.heex`

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

**Routes**:
- All data: `/phoenix_kit/admin/entities/data`
- Entity data: `/phoenix_kit/admin/entities/:entity_id/data`

**Files**:
- `lib/phoenix_kit_web/live/entities/data_navigator_live.ex`
- `lib/phoenix_kit_web/live/entities/data_navigator_live.html.heex`

**Features:**

- Browse all data records across all entities
- Filter by entity
- Entity selector dropdown
- List view with:
  - Record title
  - Entity name
  - Status badge
  - Created by user
  - Creation date
  - View/Edit/Delete buttons
- New Record button
- Empty state when no data

**LiveView Events:**

```elixir
handle_event("delete_data", %{"id" => id}, socket)
```

### 4. Data Form (Create/Edit/View)

**Routes**:
- Create: `/phoenix_kit/admin/entities/:entity_id/data/new`
- View: `/phoenix_kit/admin/entities/:entity_id/data/:id`
- Edit: `/phoenix_kit/admin/entities/:entity_id/data/:id/edit`

**Files**:
- `lib/phoenix_kit_web/live/entities/data_form_live.ex`
- `lib/phoenix_kit_web/live/entities/data_form_live.html.heex`

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

- **Embeddable Forms**: Use `<EntityForm entity_slug="contact" />` in blogging pages
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

Use the `<EntityForm>` component in blogging pages:

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

**File**: `lib/phoenix_kit/entities/html_sanitizer.ex`

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
PhoenixKit.Entities.HtmlSanitizer.sanitize("<script>alert('xss')</script><p>Hello</p>")
# => "<p>Hello</p>"

# Sanitize all rich_text fields in data map
PhoenixKit.Entities.HtmlSanitizer.sanitize_rich_text_fields(fields_definition, data)
```

---

## Real-Time Collaboration

The entity form editor supports real-time collaboration with FIFO (First In, First Out) locking.

### Presence System

**Files**:
- `lib/phoenix_kit/entities/presence.ex` - Phoenix.Presence wrapper
- `lib/phoenix_kit/entities/presence_helpers.ex` - Helper functions

### How It Works

1. **First user** to open an entity form becomes the **lock owner** (can edit)
2. **Subsequent users** become **spectators** (read-only view)
3. **Spectators see live updates** as the owner makes changes
4. **When owner leaves**, the next spectator is automatically promoted to owner

### Presence Tracking

```elixir
# Track user presence when mounting
PresenceHelpers.track_presence("entity", entity.id, socket.id, %{
  user_id: current_user.id,
  user: current_user,
  joined_at: DateTime.utc_now()
})

# Get sorted presences (FIFO order)
presences = PresenceHelpers.get_sorted_presences("entity", entity.id)
# => [{socket_id, %{user: %User{}, joined_at: ~U[...]}}, ...]

# First in list is owner, rest are spectators
```

### UI Indicators

The entity form shows:
- **Lock owner badge**: "Editing" with user name
- **Spectator list**: Shows all spectators with "Spectating" label
- **Read-only notice**: When viewing as spectator
- **Live updates**: Changes broadcast to all viewers

### Event Broadcasting

**File**: `lib/phoenix_kit/entities/events.ex`

Changes are broadcast via Phoenix PubSub:

```elixir
# Broadcast entity update
Events.broadcast_entity_updated(entity.id)

# Subscribe to entity updates
Events.subscribe_to_entity(entity.id)

# Handle incoming updates
def handle_info({:entity_updated, entity_id}, socket)
```

---

## Usage Examples

### Creating a Blog Post Entity

```elixir
# 1. Create the entity definition
{:ok, blog_entity} = PhoenixKit.Entities.create_entity(%{
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
{:ok, post} = PhoenixKit.Entities.EntityData.create(%{
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
  PhoenixKit.Entities.EntityData.list_by_entity(blog_entity.id)
  |> Enum.filter(&(&1.status == "published"))
  |> Enum.sort_by(&(&1.data["publish_date"]), :desc)
```

### Creating a Product Catalog

```elixir
{:ok, product_entity} = PhoenixKit.Entities.create_entity(%{
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
{:ok, team_entity} = PhoenixKit.Entities.create_entity(%{
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

**Implementation**: Used `PhoenixKit.Entities.enabled?()` check in `layout_wrapper.ex`:

```heex
<%= if PhoenixKit.Entities.enabled?() do %>
  <.admin_nav_item href={Routes.path("/admin/entities")} icon="entities" label="Entities" />

  <%= if submenu_open?(@current_path, ["/admin/entities", "/admin/entities/data"]) do %>
    <.admin_nav_item href={Routes.path("/admin/entities")} label="Manage Entities" nested={true} />
    <.admin_nav_item href={Routes.path("/admin/entities/data")} label="Data Navigator" nested={true} />
  <% end %>
<% end %>
```

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
PhoenixKit.Entities.enabled?()
# => false

# Enable system
PhoenixKit.Entities.enable_system()
# => {:ok, %Setting{}}

# Disable system
PhoenixKit.Entities.disable_system()
# => {:ok, %Setting{}}

# Get max entities per user
PhoenixKit.Entities.get_max_per_user()
# => 100

# Validate user hasn't exceeded limit
PhoenixKit.Entities.validate_user_entity_limit(user_id)
# => {:ok, :valid} | {:error, "You have reached the maximum limit of 100 entities"}

# Get full config
PhoenixKit.Entities.get_config()
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
**Solution**: Enable the entities system via Settings or run `PhoenixKit.Entities.enable_system()`.

---

## API Reference

### PhoenixKit.Entities

```elixir
@type t :: %PhoenixKit.Entities{
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
```

Note: `create_entity/1` auto-fills `created_by` with the first admin user if not provided.

### PhoenixKit.Entities.EntityData

```elixir
@type t :: %PhoenixKit.Entities.EntityData{
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
```

Note: `create/1` auto-fills `created_by` with the first admin user if not provided.

### PhoenixKit.Entities.FieldTypes

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
- Field types system with 13 types
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
- `/admin/entities/data` - Data navigator
- `/admin/entities/:entity_id/data` - Entity data list
- `/admin/entities/:entity_id/data/new` - Create data
- `/admin/entities/:entity_id/data/:id` - View data
- `/admin/entities/:entity_id/data/:id/edit` - Edit data

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

**Inspired by**: WordPress Advanced Custom Fields (ACF)
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

**Last Updated**: 2025-12-03
**Version**: V17+ with Public Form Builder
**Status**: Production Ready

# PhoenixKit Entities Guide

**Dynamic content types without database migrations.**

The Entities system lets you create custom content types (like blog posts, products, forms) programmatically with flexible field schemas. No migrations required.

---

## Table of Contents

1. [Quick Start](#quick-start)
2. [Enable the System](#enable-the-system)
3. [Creating Entities](#creating-entities)
4. [Field Types](#field-types)
5. [Field Builder Helpers](#field-builder-helpers)
6. [Managing Data Records](#managing-data-records)
7. [Public Forms](#public-forms)
8. [API Reference](#api-reference)
9. [Common Patterns](#common-patterns)

---

## Quick Start

```elixir
# 1. Enable the Entities system
PhoenixKit.Modules.Entities.enable_system()

# 2. Create an entity
alias PhoenixKit.Modules.Entities
alias PhoenixKit.Modules.Entities.FieldTypes

{:ok, entity} = Entities.create_entity(%{
  name: "contact_form",
  display_name: "Contact Form",
  status: "published",
  fields_definition: [
    FieldTypes.text_field("name", "Name", required: true),
    FieldTypes.email_field("email", "Email", required: true),
    FieldTypes.textarea_field("message", "Message", required: true)
  ]
})

# 3. Create data records
{:ok, record} = PhoenixKit.Modules.Entities.EntityData.create(%{
  entity_uuid: entity.uuid,
  title: "New Submission",
  status: "published",
  data: %{
    "name" => "John Doe",
    "email" => "john@example.com",
    "message" => "Hello!"
  }
})
```

---

## Enable the System

### Via Code

```elixir
PhoenixKit.Modules.Entities.enable_system()
```

### Via Admin UI

Visit `/phoenix_kit/admin/modules` and enable the Entities module.

---

## Creating Entities

### Basic Entity

```elixir
{:ok, entity} = PhoenixKit.Modules.Entities.create_entity(%{
  name: "article",
  display_name: "Article",
  display_name_plural: "Articles",
  description: "Blog articles and posts",
  icon: "hero-document-text",
  status: "published",
  created_by_uuid: admin_user.uuid,
  fields_definition: [
    %{"type" => "text", "key" => "title", "label" => "Title", "required" => true},
    %{"type" => "rich_text", "key" => "content", "label" => "Content"},
    %{"type" => "select", "key" => "status", "label" => "Status",
      "options" => ["Draft", "Published", "Archived"]}
  ]
})
```

### Entity with Auto-filled Creator

```elixir
# Note: created_by_uuid is optional - it auto-fills with first admin user if not provided
{:ok, entity} = PhoenixKit.Modules.Entities.create_entity(%{
  name: "product",
  display_name: "Product",
  status: "published",
  # created_by_uuid: admin.uuid,  # Optional! Auto-filled if omitted
  fields_definition: [
    FieldTypes.text_field("name", "Name", required: true),
    FieldTypes.number_field("price", "Price"),
    FieldTypes.textarea_field("description", "Description")
  ]
})
```

### Getting Admin User for created_by_uuid

If you need to explicitly set `created_by_uuid`, use these helpers:

```elixir
# Get first admin (Owner or Admin role) - recommended
admin_uuid = PhoenixKit.Users.Auth.get_first_admin_uuid()

# Get first user (any role)
user_uuid = PhoenixKit.Users.Auth.get_first_user_uuid()

# Get full user struct if needed
admin = PhoenixKit.Users.Auth.get_first_admin()
```

**Note:** `created_by_uuid` is now auto-filled for both `Entities.create_entity/1` and `EntityData.create/1` if not provided. It uses the first admin, or falls back to the first user.

---

## Field Types

### Available Field Types

| Type | Description | Requires Options | Status |
|------|-------------|------------------|--------|
| `text` | Single-line text | No | ✅ |
| `textarea` | Multi-line text | No | ✅ |
| `email` | Email with validation | No | ✅ |
| `url` | URL with validation | No | ✅ |
| `number` | Numeric input | No | ✅ |
| `boolean` | True/false toggle | No | ✅ |
| `date` | Date picker | No | ✅ |
| `rich_text` | WYSIWYG editor | No | ✅ |
| `select` | Dropdown | Yes | ✅ |
| `radio` | Radio buttons | Yes | ✅ |
| `checkbox` | Multiple checkboxes | Yes | ✅ |
| `file` | File upload | No | ✅ |
| `image` | Image upload | No | 🚧 Coming soon |
| `relation` | Link to other entity | Yes | 🚧 Coming soon |

> **Note**: `image` and `relation` fields render "Coming Soon" placeholders in forms. The `file` field type is fully implemented.

### Raw Field Definition

```elixir
%{
  "type" => "text",
  "key" => "name",
  "label" => "Full Name",
  "required" => true,
  "default" => nil,
  "validation" => %{},
  "options" => []
}
```

---

## Field Builder Helpers

Use these helpers to create field definitions more easily:

```elixir
alias PhoenixKit.Modules.Entities.FieldTypes

# Text fields
FieldTypes.text_field("name", "Full Name", required: true)
FieldTypes.textarea_field("bio", "Biography")
FieldTypes.email_field("email", "Email Address", required: true)
FieldTypes.url_field("website", "Website")
FieldTypes.rich_text_field("content", "Content")

# Numeric and boolean
FieldTypes.number_field("age", "Age")
FieldTypes.boolean_field("active", "Is Active", default: true)

# Date field
FieldTypes.date_field("published_on", "Published On")

# File upload
FieldTypes.file_field("attachment", "Attachment")
FieldTypes.file_field("documents", "Documents",
  max_entries: 5,
  max_file_size: 10_485_760,  # 10MB
  accept: [".pdf", ".doc", ".docx"]
)

# Choice fields with options
FieldTypes.select_field("category", "Category", ["Tech", "Business", "Other"])
FieldTypes.radio_field("priority", "Priority", ["Low", "Medium", "High"], required: true)
FieldTypes.checkbox_field("tags", "Tags", ["Featured", "Popular", "New"])

# Generic with options
FieldTypes.new_field("select", "status", "Status", options: ["Active", "Inactive"], required: true)
```

### Creating Entity with Choice Fields

```elixir
alias PhoenixKit.Modules.Entities
alias PhoenixKit.Modules.Entities.FieldTypes

{:ok, entity} = Entities.create_entity(%{
  name: "survey_response",
  display_name: "Survey Response",
  status: "published",
  fields_definition: [
    FieldTypes.text_field("name", "Name", required: true),
    FieldTypes.email_field("email", "Email", required: true),
    FieldTypes.select_field("subject", "Subject", [
      "General Inquiry",
      "Support",
      "Sales",
      "Partnership"
    ], required: true),
    FieldTypes.textarea_field("message", "Message", required: true),
    FieldTypes.checkbox_field("interests", "Interests", [
      "Product Updates",
      "Newsletter",
      "Events"
    ])
  ]
})
```

---

## Managing Data Records

### Create a Data Record

```elixir
{:ok, record} = PhoenixKit.Modules.Entities.EntityData.create(%{
  entity_uuid: entity.uuid,
  title: "New Contact",
  status: "published",
  created_by_uuid: user.uuid,
  data: %{
    "name" => "John Doe",
    "email" => "john@example.com",
    "message" => "Hello!"
  }
})
```

### Query Records

```elixir
# All records for an entity
records = PhoenixKit.Modules.Entities.EntityData.list_by_entity(entity.uuid)

# Search by title (search_term first, entity_uuid optional second)
results = PhoenixKit.Modules.Entities.EntityData.search_by_title("John", entity.uuid)

# Get entity by name
entity = PhoenixKit.Modules.Entities.get_entity_by_name("contact_form")

# Get by UUID
record = PhoenixKit.Modules.Entities.EntityData.get(record_uuid)

# Filter by status
records = PhoenixKit.Modules.Entities.EntityData.list_by_entity_and_status(entity.uuid, "published")

# Get by slug
record = PhoenixKit.Modules.Entities.EntityData.get_by_slug(entity.uuid, "my-record-slug")
```

### Update and Delete

```elixir
# Update
{:ok, updated} = PhoenixKit.Modules.Entities.EntityData.update(record, %{
  title: "Updated Title",
  data: Map.put(record.data, "new_field", "value")
})

# Delete
{:ok, deleted} = PhoenixKit.Modules.Entities.EntityData.delete(record)
```

---

## Public Forms

Embed entity-based forms on public pages for contact forms, surveys, lead capture, etc.

### Enable Public Form for an Entity

```elixir
# Via admin UI: /phoenix_kit/admin/entities/:id/edit
# Or programmatically:
PhoenixKit.Modules.Entities.update_entity(entity, %{
  settings: %{
    "public_form_enabled" => true,
    "public_form_fields" => ["name", "email", "message"],
    "public_form_title" => "Contact Us",
    "public_form_description" => "We'll get back to you within 24 hours.",
    "public_form_submit_text" => "Send Message",
    "public_form_success_message" => "Thank you! We received your message."
  }
})
```

### Embed in Your Templates

The EntityForm is a function component (not a LiveComponent), so use it directly:

```heex
<%# In .phk publishing pages (recommended) %>
<EntityForm entity_slug="contact_form" />

<%# Or call the render function directly in regular .heex templates %>
<PhoenixKit.Modules.Shared.Components.EntityForm.render
  attributes={%{"entity_slug" => "contact_form"}}
/>
```

> **Note**: Do not use `live_component` - EntityForm uses `Phoenix.Component`, not `Phoenix.LiveComponent`.

### Security Options

Configure in entity settings or admin UI:

| Setting | Default | Description |
|---------|---------|-------------|
| `public_form_honeypot` | false | Hidden field to catch bots |
| `public_form_time_check` | false | Reject submissions < 3 seconds |
| `public_form_rate_limit` | false | 5 submissions/minute per IP |
| `public_form_debug_mode` | false | Show detailed error messages |
| `public_form_collect_metadata` | true | Capture IP, browser, device |

### Security Actions

Each security check can be configured with an action:

| Action | Behavior |
|--------|----------|
| `reject_silent` | Show fake success, don't save |
| `reject_error` | Show error message, don't save |
| `save_suspicious` | Save with "draft" status, flag in metadata |
| `save_log` | Save normally, log warning |

### Form Submission Route

Forms POST to: `POST /phoenix_kit/entities/:entity_slug/submit`

This is handled by `PhoenixKitWeb.EntityFormController`.

---

## API Reference

### PhoenixKit.Modules.Entities

```elixir
# Check if system is enabled
PhoenixKit.Modules.Entities.enabled?() :: boolean()

# Enable/disable
PhoenixKit.Modules.Entities.enable_system() :: {:ok, Setting.t()}
PhoenixKit.Modules.Entities.disable_system() :: {:ok, Setting.t()}

# Get by ID
PhoenixKit.Modules.Entities.get_entity(id) :: Entity.t() | nil        # Returns nil if not found
PhoenixKit.Modules.Entities.get_entity!(id) :: Entity.t()             # Raises if not found
PhoenixKit.Modules.Entities.get_entity_by_name(name) :: Entity.t() | nil

# List
PhoenixKit.Modules.Entities.list_entities() :: [Entity.t()]
PhoenixKit.Modules.Entities.list_active_entities() :: [Entity.t()]    # Only status: "published"

# Create/Update/Delete
PhoenixKit.Modules.Entities.create_entity(attrs) :: {:ok, Entity.t()} | {:error, Changeset.t()}
PhoenixKit.Modules.Entities.update_entity(entity, attrs) :: {:ok, Entity.t()} | {:error, Changeset.t()}
PhoenixKit.Modules.Entities.delete_entity(entity) :: {:ok, Entity.t()} | {:error, Changeset.t()}

# Changeset (for forms)
PhoenixKit.Modules.Entities.change_entity(entity, attrs \\ %{}) :: Changeset.t()

# Stats
PhoenixKit.Modules.Entities.get_system_stats() :: %{
  total_entities: integer(),
  active_entities: integer(),
  total_data_records: integer()
}
```

### PhoenixKit.Modules.Entities.EntityData

```elixir
# Get by ID
EntityData.get(id) :: EntityData.t() | nil           # Returns nil if not found
EntityData.get!(id) :: EntityData.t()                # Raises if not found
EntityData.get_by_slug(entity_uuid, slug) :: EntityData.t() | nil

# List/Query
EntityData.list_all() :: [EntityData.t()]
EntityData.list_by_entity(entity_uuid) :: [EntityData.t()]
EntityData.list_by_entity_and_status(entity_uuid, status) :: [EntityData.t()]
EntityData.search_by_title(search_term, entity_uuid \\ nil) :: [EntityData.t()]

# Create/Update/Delete
EntityData.create(attrs) :: {:ok, EntityData.t()} | {:error, Changeset.t()}
EntityData.update(record, attrs) :: {:ok, EntityData.t()} | {:error, Changeset.t()}
EntityData.delete(record) :: {:ok, EntityData.t()} | {:error, Changeset.t()}

# Changeset (for forms)
EntityData.change(record, attrs \\ %{}) :: Changeset.t()
```

### PhoenixKit.Modules.Entities.FieldTypes

```elixir
# Field builder helpers (recommended for programmatic entity creation)
FieldTypes.text_field(key, label, opts \\ []) :: map()
FieldTypes.textarea_field(key, label, opts \\ []) :: map()
FieldTypes.email_field(key, label, opts \\ []) :: map()
FieldTypes.url_field(key, label, opts \\ []) :: map()
FieldTypes.number_field(key, label, opts \\ []) :: map()
FieldTypes.boolean_field(key, label, opts \\ []) :: map()
FieldTypes.date_field(key, label, opts \\ []) :: map()
FieldTypes.rich_text_field(key, label, opts \\ []) :: map()
FieldTypes.file_field(key, label, opts \\ []) :: map()

# Choice field helpers (options required)
FieldTypes.select_field(key, label, options, opts \\ []) :: map()
FieldTypes.radio_field(key, label, options, opts \\ []) :: map()
FieldTypes.checkbox_field(key, label, options, opts \\ []) :: map()

# Generic field builder
FieldTypes.new_field(type, key, label, opts \\ []) :: map()
# opts: [required: bool, default: any, options: list]

# Field type info
FieldTypes.all() :: map()
FieldTypes.requires_options?(type) :: boolean()
FieldTypes.validate_field(field_map) :: {:ok, map()} | {:error, String.t()}
```

---

## Common Patterns

### Create a Contact Form Entity

```elixir
# In a migration or seeds.exs
admin = PhoenixKit.Users.Auth.get_user_by_email("admin@example.com")

{:ok, _entity} = PhoenixKit.Modules.Entities.create_entity(%{
  name: "contact",
  display_name: "Contact Submission",
  status: "published",
  created_by_uuid: admin.uuid,
  fields_definition: [
    %{"type" => "text", "key" => "name", "label" => "Name", "required" => true},
    %{"type" => "email", "key" => "email", "label" => "Email", "required" => true},
    %{"type" => "select", "key" => "subject", "label" => "Subject", "required" => true,
      "options" => ["General Inquiry", "Support", "Sales", "Partnership"]},
    %{"type" => "textarea", "key" => "message", "label" => "Message", "required" => true}
  ],
  settings: %{
    "public_form_enabled" => true,
    "public_form_fields" => ["name", "email", "subject", "message"],
    "public_form_title" => "Contact Us",
    "public_form_honeypot" => true,
    "public_form_time_check" => true,
    "public_form_rate_limit" => true
  }
})
```

### List All Contact Submissions

```elixir
entity = PhoenixKit.Modules.Entities.get_entity_by_name("contact")
submissions = PhoenixKit.Modules.Entities.EntityData.list_by_entity(entity.uuid)

for submission <- submissions do
  IO.puts("#{submission.data["name"]} - #{submission.data["email"]}")
end
```

### Export Entity Data

```elixir
entity = PhoenixKit.Modules.Entities.get_entity_by_name("contact")
records = PhoenixKit.Modules.Entities.EntityData.list_by_entity(entity.uuid)

# Convert to list of maps
data = Enum.map(records, fn r ->
  Map.merge(r.data, %{
    "uuid" => r.uuid,
    "created_at" => r.date_created,
    "status" => r.status
  })
end)

# Export as JSON
Jason.encode!(data)
```

---

**Last Updated**: 2026-03-02

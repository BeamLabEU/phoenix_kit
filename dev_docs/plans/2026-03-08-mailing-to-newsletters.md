# Mailing → Newsletters Module Rename Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Rename the `mailing` module to `newsletters` across the entire PhoenixKit codebase — directories, defmodule names, aliases, URL paths, route helpers, settings keys, Oban queue, template categories, and DB migration — without creating new migrations.

**Architecture:** Rename is purely internal to PhoenixKit library. The single v79.ex migration rewrites table/index/constraint names from `mailing` → `newsletters` in-place. All Elixir module references update from `Mailing` → `Newsletters`. URL paths `/admin/mailing/*` → `/admin/newsletters/*` and `/mailing/unsubscribe` → `/newsletters/unsubscribe`.

**Tech Stack:** Elixir/Phoenix, Ecto, Oban, LiveView, DaisyUI 5, PostgreSQL

**Pre-requisite (user must run manually before applying):**
```bash
# In parent app (e.g. hydroforce):
mix ecto.rollback --to 78
# This drops the mailing tables so the rewritten v79 migration can create newsletters tables fresh.
```

---

## Scope Summary

| Category | Count | Details |
|----------|-------|---------|
| Directories to rename | 2 | `lib/modules/mailing/` → `lib/modules/newsletters/`, `lib/modules/mailing/workers/` → `lib/modules/newsletters/workers/` |
| `.ex` files to modify | 22 | All files in `lib/modules/mailing/` + integration files |
| `.heex` files to modify | 9 | All HEEX templates with mailing references |
| `defmodule` renames | 16 | All `Mailing.*` modules → `Newsletters.*` |
| Settings keys | 3 | `mailing_enabled`, `mailing_default_template`, `mailing_rate_limit` → `newsletters_*` |
| DB table renames | 4 | `phoenix_kit_mailing_*` → `phoenix_kit_newsletters_*` |
| Index renames | 10 | All `idx_mailing_*` → `idx_newsletters_*` |
| Constraint renames | 7 | All `fk_mailing_*` → `fk_newsletters_*` |
| Oban queue rename | 1 | `:mailing_delivery` → `:newsletters_delivery` |
| URL paths | 14 | `/admin/mailing/*` → `/admin/newsletters/*`, `/mailing/unsubscribe` → `/newsletters/unsubscribe` |
| Template category | 1 | `"mailing"` → `"newsletters"` in Emails module |
| Module registry | 1 | `PhoenixKit.Modules.Mailing` → `PhoenixKit.Modules.Newsletters` |

---

## Task 1: Rewrite v79 Migration In-Place

**Files:**
- Modify: `lib/phoenix_kit/migrations/postgres/v79.ex`

Rewrite the entire file. Replace every occurrence of `mailing` (table names, index names, constraint names) with `newsletters`. Also update `@moduledoc`.

**Step 1: Rewrite v79.ex**

Replace the file content with:

```elixir
defmodule PhoenixKit.Migrations.Postgres.V79 do
  @moduledoc """
  V79: Newsletters Module — Database Tables

  Creates 4 tables for the newsletter broadcast system:
  - `phoenix_kit_newsletters_lists` — Named newsletter lists for segmentation
  - `phoenix_kit_newsletters_list_members` — User membership in lists
  - `phoenix_kit_newsletters_broadcasts` — Email broadcasts (draft/sent/scheduled)
  - `phoenix_kit_newsletters_deliveries` — Per-recipient delivery tracking

  All UUIDs use `uuid_generate_v7()`. All operations are idempotent.
  """

  use Ecto.Migration

  def up(%{prefix: prefix} = _opts) do
    p = prefix_str(prefix)

    # =========================================================================
    # Table 1: phoenix_kit_newsletters_lists
    # =========================================================================

    execute("""
    CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_newsletters_lists (
      uuid UUID PRIMARY KEY DEFAULT uuid_generate_v7(),
      name VARCHAR(255) NOT NULL,
      slug VARCHAR(255) NOT NULL,
      description TEXT,
      status VARCHAR(20) NOT NULL DEFAULT 'active',
      is_default BOOLEAN NOT NULL DEFAULT false,
      subscriber_count INTEGER NOT NULL DEFAULT 0,
      inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )
    """)

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS idx_newsletters_lists_slug
    ON #{p}phoenix_kit_newsletters_lists (slug)
    """)

    # =========================================================================
    # Table 2: phoenix_kit_newsletters_list_members
    # =========================================================================

    execute("""
    CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_newsletters_list_members (
      uuid UUID PRIMARY KEY DEFAULT uuid_generate_v7(),
      user_uuid UUID NOT NULL,
      list_uuid UUID NOT NULL,
      status VARCHAR(20) NOT NULL DEFAULT 'active',
      subscribed_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      unsubscribed_at TIMESTAMPTZ,
      CONSTRAINT fk_newsletters_list_members_user
        FOREIGN KEY (user_uuid)
        REFERENCES #{p}phoenix_kit_users(uuid)
        ON DELETE CASCADE,
      CONSTRAINT fk_newsletters_list_members_list
        FOREIGN KEY (list_uuid)
        REFERENCES #{p}phoenix_kit_newsletters_lists(uuid)
        ON DELETE CASCADE
    )
    """)

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS idx_newsletters_list_members_user_list
    ON #{p}phoenix_kit_newsletters_list_members (user_uuid, list_uuid)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_newsletters_list_members_list
    ON #{p}phoenix_kit_newsletters_list_members (list_uuid)
    """)

    # =========================================================================
    # Table 3: phoenix_kit_newsletters_broadcasts
    # =========================================================================

    execute("""
    CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_newsletters_broadcasts (
      uuid UUID PRIMARY KEY DEFAULT uuid_generate_v7(),
      subject VARCHAR(998) NOT NULL,
      markdown_body TEXT,
      html_body TEXT,
      text_body TEXT,
      template_uuid UUID,
      list_uuid UUID NOT NULL,
      status VARCHAR(20) NOT NULL DEFAULT 'draft',
      scheduled_at TIMESTAMPTZ,
      sent_at TIMESTAMPTZ,
      total_recipients INTEGER NOT NULL DEFAULT 0,
      sent_count INTEGER NOT NULL DEFAULT 0,
      delivered_count INTEGER NOT NULL DEFAULT 0,
      opened_count INTEGER NOT NULL DEFAULT 0,
      bounced_count INTEGER NOT NULL DEFAULT 0,
      created_by_user_uuid UUID,
      inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      CONSTRAINT fk_newsletters_broadcasts_template
        FOREIGN KEY (template_uuid)
        REFERENCES #{p}phoenix_kit_email_templates(uuid)
        ON DELETE SET NULL,
      CONSTRAINT fk_newsletters_broadcasts_list
        FOREIGN KEY (list_uuid)
        REFERENCES #{p}phoenix_kit_newsletters_lists(uuid)
        ON DELETE RESTRICT,
      CONSTRAINT fk_newsletters_broadcasts_created_by
        FOREIGN KEY (created_by_user_uuid)
        REFERENCES #{p}phoenix_kit_users(uuid)
        ON DELETE SET NULL
    )
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_newsletters_broadcasts_list
    ON #{p}phoenix_kit_newsletters_broadcasts (list_uuid)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_newsletters_broadcasts_status
    ON #{p}phoenix_kit_newsletters_broadcasts (status)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_newsletters_broadcasts_scheduled_at
    ON #{p}phoenix_kit_newsletters_broadcasts (scheduled_at)
    WHERE scheduled_at IS NOT NULL
    """)

    # =========================================================================
    # Table 4: phoenix_kit_newsletters_deliveries
    # =========================================================================

    execute("""
    CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_newsletters_deliveries (
      uuid UUID PRIMARY KEY DEFAULT uuid_generate_v7(),
      broadcast_uuid UUID NOT NULL,
      user_uuid UUID NOT NULL,
      status VARCHAR(20) NOT NULL DEFAULT 'pending',
      sent_at TIMESTAMPTZ,
      delivered_at TIMESTAMPTZ,
      opened_at TIMESTAMPTZ,
      error TEXT,
      message_id VARCHAR(255),
      inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      CONSTRAINT fk_newsletters_deliveries_broadcast
        FOREIGN KEY (broadcast_uuid)
        REFERENCES #{p}phoenix_kit_newsletters_broadcasts(uuid)
        ON DELETE CASCADE,
      CONSTRAINT fk_newsletters_deliveries_user
        FOREIGN KEY (user_uuid)
        REFERENCES #{p}phoenix_kit_users(uuid)
        ON DELETE CASCADE
    )
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_newsletters_deliveries_broadcast
    ON #{p}phoenix_kit_newsletters_deliveries (broadcast_uuid)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_newsletters_deliveries_user
    ON #{p}phoenix_kit_newsletters_deliveries (user_uuid)
    """)

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS idx_newsletters_deliveries_message_id
    ON #{p}phoenix_kit_newsletters_deliveries (message_id)
    WHERE message_id IS NOT NULL
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_newsletters_deliveries_status
    ON #{p}phoenix_kit_newsletters_deliveries (status)
    """)

    # Version marker
    execute("COMMENT ON TABLE #{p}phoenix_kit IS '79'")
  end

  def down(%{prefix: prefix} = _opts) do
    p = prefix_str(prefix)

    execute("DROP TABLE IF EXISTS #{p}phoenix_kit_newsletters_deliveries CASCADE")
    execute("DROP TABLE IF EXISTS #{p}phoenix_kit_newsletters_broadcasts CASCADE")
    execute("DROP TABLE IF EXISTS #{p}phoenix_kit_newsletters_list_members CASCADE")
    execute("DROP TABLE IF EXISTS #{p}phoenix_kit_newsletters_lists CASCADE")

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '78'")
  end

  defp prefix_str(nil), do: ""
  defp prefix_str("public"), do: "public."
  defp prefix_str(prefix), do: "#{prefix}."
end
```

**Step 2: Verify compile**

```bash
cd /app && mix compile 2>&1 | head -20
```
Expected: no errors (module hasn't been referenced yet with new name).

**Step 3: Commit**

```bash
cd /app
git add lib/phoenix_kit/migrations/postgres/v79.ex
git commit -m "Update V79 migration: rename mailing tables to newsletters"
```

---

## Task 2: Rename Directory Structure

**Files:**
- Rename dir: `lib/modules/mailing/` → `lib/modules/newsletters/`
- This moves all 22 files at once. Elixir doesn't care about directory names matching module names.

**Step 1: Move the directory**

```bash
mv /app/lib/modules/mailing /app/lib/modules/newsletters
```

**Step 2: Rename the route file**

```bash
mv /app/lib/phoenix_kit_web/routes/mailing.ex /app/lib/phoenix_kit_web/routes/newsletters.ex
```

**Step 3: Verify files are in place**

```bash
ls /app/lib/modules/newsletters/
ls /app/lib/modules/newsletters/web/
ls /app/lib/modules/newsletters/workers/
```

Expected: all 22 files present under `newsletters/`.

---

## Task 3: Rename Core Schema Files

These 5 schema files need `defmodule` renames and table name string updates.

### 3a: `lib/modules/newsletters/list.ex`

Change `defmodule PhoenixKit.Modules.Mailing.List` → `PhoenixKit.Modules.Newsletters.List`
Change `schema "phoenix_kit_mailing_lists"` → `schema "phoenix_kit_newsletters_lists"`
Change `has_many :members, PhoenixKit.Modules.Mailing.ListMember` → `PhoenixKit.Modules.Newsletters.ListMember`
Change `has_many :broadcasts, PhoenixKit.Modules.Mailing.Broadcast` → `PhoenixKit.Modules.Newsletters.Broadcast`

Full replacement:
```elixir
defmodule PhoenixKit.Modules.Newsletters.List do
  @moduledoc """
  Ecto schema for newsletter lists.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:uuid, UUIDv7, autogenerate: true}

  @valid_statuses ["active", "archived"]

  schema "phoenix_kit_newsletters_lists" do
    field :name, :string
    field :slug, :string
    field :description, :string
    field :status, :string, default: "active"
    field :is_default, :boolean, default: false
    field :subscriber_count, :integer, default: 0

    has_many :members, PhoenixKit.Modules.Newsletters.ListMember,
      foreign_key: :list_uuid,
      references: :uuid

    has_many :broadcasts, PhoenixKit.Modules.Newsletters.Broadcast,
      foreign_key: :list_uuid,
      references: :uuid

    timestamps(type: :utc_datetime)
  end

  def changeset(list, attrs) do
    list
    |> cast(attrs, [:name, :slug, :description, :status, :is_default])
    |> validate_required([:name, :slug])
    |> validate_length(:name, min: 1, max: 255)
    |> validate_length(:slug, min: 1, max: 255)
    |> validate_inclusion(:status, @valid_statuses)
    |> validate_format(:slug, ~r/^[a-z0-9][a-z0-9-]*$/,
      message: "must contain only lowercase letters, numbers, and hyphens"
    )
    |> unique_constraint(:slug)
    |> auto_generate_slug()
  end

  defp auto_generate_slug(changeset) do
    case get_change(changeset, :slug) do
      nil ->
        case get_change(changeset, :name) do
          nil -> changeset
          name -> put_change(changeset, :slug, slugify(name))
        end

      _ ->
        changeset
    end
  end

  defp slugify(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end
end
```

### 3b: `lib/modules/newsletters/list_member.ex`

Change `defmodule PhoenixKit.Modules.Mailing.ListMember` → `PhoenixKit.Modules.Newsletters.ListMember`
Change `schema "phoenix_kit_mailing_list_members"` → `schema "phoenix_kit_newsletters_list_members"`
Change `belongs_to :list, PhoenixKit.Modules.Mailing.List` → `PhoenixKit.Modules.Newsletters.List`

Full replacement:
```elixir
defmodule PhoenixKit.Modules.Newsletters.ListMember do
  @moduledoc """
  Ecto schema for newsletter list membership.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:uuid, UUIDv7, autogenerate: true}

  @valid_statuses ["active", "unsubscribed"]

  schema "phoenix_kit_newsletters_list_members" do
    field :status, :string, default: "active"
    field :subscribed_at, :utc_datetime
    field :unsubscribed_at, :utc_datetime
    field :user_uuid, UUIDv7
    field :list_uuid, UUIDv7

    belongs_to :user, PhoenixKit.Users.Auth.User,
      foreign_key: :user_uuid,
      references: :uuid,
      define_field: false,
      type: UUIDv7

    belongs_to :list, PhoenixKit.Modules.Newsletters.List,
      foreign_key: :list_uuid,
      references: :uuid,
      define_field: false,
      type: UUIDv7

    # No timestamps — uses subscribed_at/unsubscribed_at instead
  end

  def changeset(member, attrs) do
    member
    |> cast(attrs, [:user_uuid, :list_uuid, :status, :subscribed_at, :unsubscribed_at])
    |> validate_required([:user_uuid, :list_uuid])
    |> validate_inclusion(:status, @valid_statuses)
    |> unique_constraint([:user_uuid, :list_uuid])
    |> maybe_set_subscribed_at()
  end

  defp maybe_set_subscribed_at(changeset) do
    case get_field(changeset, :subscribed_at) do
      nil -> put_change(changeset, :subscribed_at, PhoenixKit.Utils.Date.utc_now())
      _ -> changeset
    end
  end
end
```

### 3c: `lib/modules/newsletters/broadcast.ex`

Change `defmodule PhoenixKit.Modules.Mailing.Broadcast` → `PhoenixKit.Modules.Newsletters.Broadcast`
Change `schema "phoenix_kit_mailing_broadcasts"` → `schema "phoenix_kit_newsletters_broadcasts"`
Change `belongs_to :list, PhoenixKit.Modules.Mailing.List` → `PhoenixKit.Modules.Newsletters.List`
Change `has_many :deliveries, PhoenixKit.Modules.Mailing.Delivery` → `PhoenixKit.Modules.Newsletters.Delivery`

Full replacement:
```elixir
defmodule PhoenixKit.Modules.Newsletters.Broadcast do
  @moduledoc """
  Ecto schema for newsletter broadcasts.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:uuid, UUIDv7, autogenerate: true}

  @valid_statuses ["draft", "scheduled", "sending", "sent", "cancelled"]

  schema "phoenix_kit_newsletters_broadcasts" do
    field :subject, :string
    field :markdown_body, :string
    field :html_body, :string
    field :text_body, :string
    field :status, :string, default: "draft"
    field :scheduled_at, :utc_datetime
    field :sent_at, :utc_datetime
    field :total_recipients, :integer, default: 0
    field :sent_count, :integer, default: 0
    field :delivered_count, :integer, default: 0
    field :opened_count, :integer, default: 0
    field :bounced_count, :integer, default: 0
    field :template_uuid, UUIDv7
    field :list_uuid, UUIDv7
    field :created_by_user_uuid, UUIDv7

    belongs_to :list, PhoenixKit.Modules.Newsletters.List,
      foreign_key: :list_uuid,
      references: :uuid,
      define_field: false,
      type: UUIDv7

    belongs_to :template, PhoenixKit.Modules.Emails.Template,
      foreign_key: :template_uuid,
      references: :uuid,
      define_field: false,
      type: UUIDv7

    belongs_to :created_by, PhoenixKit.Users.Auth.User,
      foreign_key: :created_by_user_uuid,
      references: :uuid,
      define_field: false,
      type: UUIDv7

    has_many :deliveries, PhoenixKit.Modules.Newsletters.Delivery,
      foreign_key: :broadcast_uuid,
      references: :uuid

    timestamps(type: :utc_datetime)
  end

  def changeset(broadcast, attrs) do
    broadcast
    |> cast(attrs, [
      :subject,
      :markdown_body,
      :html_body,
      :text_body,
      :status,
      :scheduled_at,
      :sent_at,
      :total_recipients,
      :sent_count,
      :delivered_count,
      :opened_count,
      :bounced_count,
      :template_uuid,
      :list_uuid,
      :created_by_user_uuid
    ])
    |> validate_required([:subject, :list_uuid])
    |> validate_length(:subject, min: 1, max: 998)
    |> validate_inclusion(:status, @valid_statuses)
  end

  def valid_statuses, do: @valid_statuses
end
```

### 3d: `lib/modules/newsletters/delivery.ex`

Change `defmodule PhoenixKit.Modules.Mailing.Delivery` → `PhoenixKit.Modules.Newsletters.Delivery`
Change `schema "phoenix_kit_mailing_deliveries"` → `schema "phoenix_kit_newsletters_deliveries"`
Change `belongs_to :broadcast, PhoenixKit.Modules.Mailing.Broadcast` → `PhoenixKit.Modules.Newsletters.Broadcast`

Full replacement:
```elixir
defmodule PhoenixKit.Modules.Newsletters.Delivery do
  @moduledoc """
  Ecto schema for per-recipient delivery tracking.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:uuid, UUIDv7, autogenerate: true}

  @valid_statuses ["pending", "sent", "delivered", "opened", "bounced", "failed"]

  schema "phoenix_kit_newsletters_deliveries" do
    field :status, :string, default: "pending"
    field :sent_at, :utc_datetime
    field :delivered_at, :utc_datetime
    field :opened_at, :utc_datetime
    field :error, :string
    field :message_id, :string
    field :broadcast_uuid, UUIDv7
    field :user_uuid, UUIDv7

    belongs_to :broadcast, PhoenixKit.Modules.Newsletters.Broadcast,
      foreign_key: :broadcast_uuid,
      references: :uuid,
      define_field: false,
      type: UUIDv7

    belongs_to :user, PhoenixKit.Users.Auth.User,
      foreign_key: :user_uuid,
      references: :uuid,
      define_field: false,
      type: UUIDv7

    timestamps(type: :utc_datetime)
  end

  def changeset(delivery, attrs) do
    delivery
    |> cast(attrs, [
      :broadcast_uuid,
      :user_uuid,
      :status,
      :sent_at,
      :delivered_at,
      :opened_at,
      :error,
      :message_id
    ])
    |> validate_required([:broadcast_uuid, :user_uuid])
    |> validate_inclusion(:status, @valid_statuses)
    |> unique_constraint(:message_id)
  end

  def valid_statuses, do: @valid_statuses
end
```

**Step 2: Compile check**

```bash
cd /app && mix compile 2>&1 | grep -E "error|warning" | head -20
```

**Step 3: Commit**

```bash
cd /app
git add lib/modules/newsletters/list.ex lib/modules/newsletters/list_member.ex \
        lib/modules/newsletters/broadcast.ex lib/modules/newsletters/delivery.ex
git commit -m "Rename Mailing schema modules to Newsletters, update table names"
```

---

## Task 4: Rename Main Module File (newsletters.ex)

**Files:**
- Modify: `lib/modules/newsletters/mailing.ex` (rename to `newsletters.ex` after task 2)

This is the main context module. After Task 2, the file is at `lib/modules/newsletters/mailing.ex`. Rename it and rewrite content.

**Step 1: Rename the file**

```bash
mv /app/lib/modules/newsletters/mailing.ex /app/lib/modules/newsletters/newsletters.ex
```

**Step 2: Rewrite content**

Replace ALL occurrences of:
- `defmodule PhoenixKit.Modules.Mailing do` → `defmodule PhoenixKit.Modules.Newsletters do`
- `@moduledoc` text: "Mailing module" → "Newsletters module", "mailing list" → "newsletter list"
- `def module_key, do: "mailing"` → `def module_key, do: "newsletters"`
- `def module_name, do: "Mailing"` → `def module_name, do: "Newsletters"`
- `Settings.get_boolean_setting("mailing_enabled", false)` → `Settings.get_boolean_setting("newsletters_enabled", false)`
- `Settings.update_boolean_setting_with_module("mailing_enabled", true, "mailing")` → `Settings.update_boolean_setting_with_module("newsletters_enabled", true, "newsletters")`
- `Settings.update_boolean_setting_with_module("mailing_enabled", false, "mailing")` → `Settings.update_boolean_setting_with_module("newsletters_enabled", false, "newsletters")`
- `permission_metadata` key: `key: "mailing"` → `key: "newsletters"`
- `permission_metadata` label: `label: "Mailing"` → `label: "Newsletters"`
- All tab IDs: `:admin_mailing` → `:admin_newsletters`, `:admin_mailing_broadcasts` → `:admin_newsletters_broadcasts`, `:admin_mailing_lists` → `:admin_newsletters_lists`
- Tab labels: `label: "Mailing"` → `label: "Newsletters"`
- Tab paths: `path: "mailing/broadcasts"` → `path: "newsletters/broadcasts"`, `path: "mailing/lists"` → `path: "newsletters/lists"`
- Tab permissions: `permission: "mailing"` → `permission: "newsletters"`
- `parent: :admin_mailing` → `parent: :admin_newsletters`
- `def route_module, do: PhoenixKitWeb.Routes.MailingRoutes` → `def route_module, do: PhoenixKitWeb.Routes.NewslettersRoutes`
- `alias PhoenixKit.Modules.Mailing.{Broadcast, Broadcaster, Delivery, List, ListMember}` → `alias PhoenixKit.Modules.Newsletters.{Broadcast, Broadcaster, Delivery, List, ListMember}`
- `def module_name, do: "Mailing"` → `def module_name, do: "Newsletters"`

The `admin_tabs/0` section becomes:

```elixir
@impl PhoenixKit.Module
def admin_tabs do
  [
    Tab.new!(
      id: :admin_newsletters,
      label: "Newsletters",
      icon: "hero-megaphone",
      path: "newsletters/broadcasts",
      priority: 520,
      level: :admin,
      permission: "newsletters",
      match: :prefix,
      group: :admin_modules,
      subtab_display: :when_active,
      highlight_with_subtabs: false,
      subtab_indent: "pl-4"
    ),
    Tab.new!(
      id: :admin_newsletters_broadcasts,
      label: "Broadcasts",
      icon: "hero-paper-airplane",
      path: "newsletters/broadcasts",
      priority: 521,
      level: :admin,
      permission: "newsletters",
      parent: :admin_newsletters,
      match: :prefix
    ),
    Tab.new!(
      id: :admin_newsletters_lists,
      label: "Lists",
      icon: "hero-list-bullet",
      path: "newsletters/lists",
      priority: 522,
      level: :admin,
      permission: "newsletters",
      parent: :admin_newsletters,
      match: :prefix
    )
  ]
end
```

**Step 3: Commit**

```bash
cd /app
git add lib/modules/newsletters/newsletters.ex
git commit -m "Rename Newsletters main context module, update settings keys and tabs"
```

---

## Task 5: Rename Broadcaster Module

**Files:**
- Modify: `lib/modules/newsletters/broadcaster.ex`

Changes:
- `defmodule PhoenixKit.Modules.Mailing.Broadcaster` → `PhoenixKit.Modules.Newsletters.Broadcaster`
- `alias PhoenixKit.Modules.Mailing` → `alias PhoenixKit.Modules.Newsletters`
- `alias PhoenixKit.Modules.Mailing.{Broadcast, Delivery, ListMember}` → `alias PhoenixKit.Modules.Newsletters.{Broadcast, Delivery, ListMember}`
- `alias PhoenixKit.Modules.Mailing.Workers.DeliveryWorker` → `alias PhoenixKit.Modules.Newsletters.Workers.DeliveryWorker`

**Step 1: Apply changes** (edit the file with the above substitutions)

**Step 2: Commit**

```bash
cd /app
git add lib/modules/newsletters/broadcaster.ex
git commit -m "Rename Broadcaster module to Newsletters namespace"
```

---

## Task 6: Rename DeliveryWorker (Oban Queue)

**Files:**
- Modify: `lib/modules/newsletters/workers/delivery_worker.ex`

Changes:
- `defmodule PhoenixKit.Modules.Mailing.Workers.DeliveryWorker` → `PhoenixKit.Modules.Newsletters.Workers.DeliveryWorker`
- `queue: :mailing_delivery` → `queue: :newsletters_delivery`
- `alias PhoenixKit.Modules.Mailing` → `alias PhoenixKit.Modules.Newsletters`
- `alias PhoenixKit.Modules.Mailing.Delivery` → `alias PhoenixKit.Modules.Newsletters.Delivery`
- `PhoenixKit.Modules.Mailing.Broadcast` (in `update_broadcast_counter`) → `PhoenixKit.Modules.Newsletters.Broadcast`
- URL path in `build_variables`: `Routes.url("/mailing/unsubscribe?token=...")` → `Routes.url("/newsletters/unsubscribe?token=...")`
- `@moduledoc` queue comment: `queues: [mailing_delivery: 10]` → `queues: [newsletters_delivery: 10]`
- `@moduledoc` setting reference: `"mailing_rate_limit"` → `"newsletters_rate_limit"`

**Step 1: Apply changes**

**Step 2: Commit**

```bash
cd /app
git add lib/modules/newsletters/workers/delivery_worker.ex
git commit -m "Rename DeliveryWorker to Newsletters namespace, rename Oban queue to newsletters_delivery"
```

---

## Task 7: Rename Web LiveView Modules

**Files (all in `lib/modules/newsletters/web/`):**
- `broadcasts.ex`
- `broadcast_editor.ex`
- `broadcast_details.ex`
- `lists.ex`
- `list_editor.ex`
- `list_members.ex`
- `unsubscribe_controller.ex`
- `unsubscribe_html.ex`

For **each file**, apply these substitutions:

| Old | New |
|-----|-----|
| `PhoenixKit.Modules.Mailing.Web.Broadcasts` | `PhoenixKit.Modules.Newsletters.Web.Broadcasts` |
| `PhoenixKit.Modules.Mailing.Web.BroadcastEditor` | `PhoenixKit.Modules.Newsletters.Web.BroadcastEditor` |
| `PhoenixKit.Modules.Mailing.Web.BroadcastDetails` | `PhoenixKit.Modules.Newsletters.Web.BroadcastDetails` |
| `PhoenixKit.Modules.Mailing.Web.Lists` | `PhoenixKit.Modules.Newsletters.Web.Lists` |
| `PhoenixKit.Modules.Mailing.Web.ListEditor` | `PhoenixKit.Modules.Newsletters.Web.ListEditor` |
| `PhoenixKit.Modules.Mailing.Web.ListMembers` | `PhoenixKit.Modules.Newsletters.Web.ListMembers` |
| `PhoenixKit.Modules.Mailing.Web.UnsubscribeController` | `PhoenixKit.Modules.Newsletters.Web.UnsubscribeController` |
| `PhoenixKit.Modules.Mailing.Web.UnsubscribeHTML` | `PhoenixKit.Modules.Newsletters.Web.UnsubscribeHTML` |
| `alias PhoenixKit.Modules.Mailing` | `alias PhoenixKit.Modules.Newsletters` |
| `alias PhoenixKit.Modules.Mailing.List` | `alias PhoenixKit.Modules.Newsletters.List` |
| `alias PhoenixKit.Modules.Mailing.Broadcaster` | `alias PhoenixKit.Modules.Newsletters.Broadcaster` |
| `plug :put_view, html: PhoenixKit.Modules.Mailing.Web.UnsubscribeHTML` | `plug :put_view, html: PhoenixKit.Modules.Newsletters.Web.UnsubscribeHTML` |

URL paths in all LiveView files:

| Old path | New path |
|----------|----------|
| `"/admin/mailing/broadcasts"` | `"/admin/newsletters/broadcasts"` |
| `"/admin/mailing/broadcasts/new"` | `"/admin/newsletters/broadcasts/new"` |
| `"/admin/mailing/broadcasts/#{id}/edit"` | `"/admin/newsletters/broadcasts/#{id}/edit"` |
| `"/admin/mailing/broadcasts/#{id}"` | `"/admin/newsletters/broadcasts/#{id}"` |
| `"/admin/mailing/lists"` | `"/admin/newsletters/lists"` |
| `"/admin/mailing/lists/new"` | `"/admin/newsletters/lists/new"` |
| `"/admin/mailing/lists/#{id}/edit"` | `"/admin/newsletters/lists/#{id}/edit"` |
| `"/admin/mailing/lists/#{list_uuid}/members"` | `"/admin/newsletters/lists/#{list_uuid}/members"` |

Flash messages referencing "Mailing module":

| Old | New |
|-----|-----|
| `"Mailing module is not enabled"` | `"Newsletters module is not enabled"` |

Settings key in `broadcast_editor.ex`:

| Old | New |
|-----|-----|
| `Settings.get_setting("mailing_default_template")` | `Settings.get_setting("newsletters_default_template")` |

**Step 1: Apply all changes to all 8 web files**

**Step 2: Commit**

```bash
cd /app
git add lib/modules/newsletters/web/
git commit -m "Rename all Newsletters web modules, update URL paths"
```

---

## Task 8: Update Route File

**Files:**
- Modify: `lib/phoenix_kit_web/routes/newsletters.ex`

Full replacement:

```elixir
defmodule PhoenixKitWeb.Routes.NewslettersRoutes do
  @moduledoc """
  Newsletters module routes.

  Provides route definitions for newsletters admin interfaces and unsubscribe flow.
  Separated to improve compilation time.
  """

  @doc """
  Returns quoted code for newsletters non-LiveView routes (unsubscribe).
  """
  def generate(url_prefix) do
    quote do
      scope unquote(url_prefix) do
        pipe_through [:browser]

        get "/newsletters/unsubscribe",
            PhoenixKit.Modules.Newsletters.Web.UnsubscribeController,
            :unsubscribe

        post "/newsletters/unsubscribe",
             PhoenixKit.Modules.Newsletters.Web.UnsubscribeController,
             :process_unsubscribe
      end
    end
  end

  @doc """
  Returns quoted admin LiveView route declarations for inclusion in the shared admin live_session.
  """
  def admin_routes do
    quote do
      live "/admin/newsletters/broadcasts", PhoenixKit.Modules.Newsletters.Web.Broadcasts, :index,
        as: :newsletters_broadcasts

      live "/admin/newsletters/broadcasts/new", PhoenixKit.Modules.Newsletters.Web.BroadcastEditor, :new,
        as: :newsletters_broadcast_new

      live "/admin/newsletters/broadcasts/:id/edit",
           PhoenixKit.Modules.Newsletters.Web.BroadcastEditor,
           :edit,
           as: :newsletters_broadcast_edit

      live "/admin/newsletters/broadcasts/:id",
           PhoenixKit.Modules.Newsletters.Web.BroadcastDetails,
           :show,
           as: :newsletters_broadcast_details

      live "/admin/newsletters/lists", PhoenixKit.Modules.Newsletters.Web.Lists, :index,
        as: :newsletters_lists

      live "/admin/newsletters/lists/new", PhoenixKit.Modules.Newsletters.Web.ListEditor, :new,
        as: :newsletters_list_new

      live "/admin/newsletters/lists/:id/edit", PhoenixKit.Modules.Newsletters.Web.ListEditor, :edit,
        as: :newsletters_list_edit

      live "/admin/newsletters/lists/:id/members", PhoenixKit.Modules.Newsletters.Web.ListMembers, :index,
        as: :newsletters_list_members
    end
  end
end
```

**Step 2: Commit**

```bash
cd /app
git add lib/phoenix_kit_web/routes/newsletters.ex
git commit -m "Rename route file and module to NewslettersRoutes, update all paths"
```

---

## Task 9: Update integration.ex

**Files:**
- Modify: `lib/phoenix_kit_web/integration.ex`

Three changes (lines 104, 431, 1218):

1. `alias PhoenixKitWeb.Routes.MailingRoutes` → `alias PhoenixKitWeb.Routes.NewslettersRoutes`
2. `mailing_admin = safe_route_call(MailingRoutes, :admin_routes, [])` → `newsletters_admin = safe_route_call(NewslettersRoutes, :admin_routes, [])`
3. `unquote(mailing_admin)` → `unquote(newsletters_admin)`
4. `mailing_routes = safe_route_call(MailingRoutes, :generate, [url_prefix])` → `newsletters_routes = safe_route_call(NewslettersRoutes, :generate, [url_prefix])`
5. `unquote(mailing_routes)` → `unquote(newsletters_routes)`

**Step 2: Commit**

```bash
cd /app
git add lib/phoenix_kit_web/integration.ex
git commit -m "Update integration.ex to use NewslettersRoutes"
```

---

## Task 10: Update Module Registry

**Files:**
- Modify: `lib/phoenix_kit/module_registry.ex`

Change in `internal_modules/0` list:
- `PhoenixKit.Modules.Mailing,` → `PhoenixKit.Modules.Newsletters,`

**Step 2: Commit**

```bash
cd /app
git add lib/phoenix_kit/module_registry.ex
git commit -m "Register Newsletters module in ModuleRegistry"
```

---

## Task 11: Update Oban Config (Install Helper)

**Files:**
- Modify: `lib/phoenix_kit/install/oban_config.ex`

Changes (all occurrences of `mailing_delivery` → `newsletters_delivery`):

1. `@dialyzer {:nowarn_function, ensure_mailing_delivery_queue: 2}` → `@dialyzer {:nowarn_function, ensure_newsletters_delivery_queue: 2}`
2. In `update_existing_oban_config/3`: `|> ensure_mailing_delivery_queue(app_name)` → `|> ensure_newsletters_delivery_queue(app_name)`
3. Rename `defp ensure_mailing_delivery_queue(content, app_name)` → `defp ensure_newsletters_delivery_queue(content, app_name)`
4. Inside that function: all `mailing_delivery` string occurrences → `newsletters_delivery`
5. In the `oban_config` string (around line 125): `mailing_delivery: 10  # Mailing broadcast deliveries` → `newsletters_delivery: 10  # Newsletter broadcast deliveries`
6. In the manual config notice (bottom of file): `mailing_delivery: 10` → `newsletters_delivery: 10`

**Step 2: Commit**

```bash
cd /app
git add lib/phoenix_kit/install/oban_config.ex
git commit -m "Rename mailing_delivery Oban queue to newsletters_delivery in install helper"
```

---

## Task 12: Update Scheduled Jobs Worker

**Files:**
- Modify: `lib/phoenix_kit/scheduled_jobs/workers/process_scheduled_jobs_worker.ex`

Changes:
- `alias PhoenixKit.Modules.Mailing` → `alias PhoenixKit.Modules.Newsletters`
- `if Mailing.enabled?() do` → `if Newsletters.enabled?() do`
- `{:ok, mailing_count} = Mailing.process_scheduled_broadcasts()` → `{:ok, newsletters_count} = Newsletters.process_scheduled_broadcasts()`
- `if mailing_count > 0 do` → `if newsletters_count > 0 do`
- `"ProcessScheduledJobsWorker: Sent #{mailing_count} scheduled broadcast(s)"` → `"ProcessScheduledJobsWorker: Sent #{newsletters_count} scheduled broadcast(s)"`

**Step 2: Commit**

```bash
cd /app
git add lib/phoenix_kit/scheduled_jobs/workers/process_scheduled_jobs_worker.ex
git commit -m "Update ProcessScheduledJobsWorker to use Newsletters module"
```

---

## Task 13: Update Emails Module References

**Files:**
- Modify: `lib/modules/emails/sqs_processor.ex`
- Modify: `lib/modules/emails/template.ex`

### 13a: sqs_processor.ex

The function `maybe_update_mailing_delivery/3` (lines ~1399-1420) references the Mailing module to find deliveries by `message_id` and update status.

Changes:
- Rename function: `defp maybe_update_mailing_delivery(message_id, event_type, timestamp)` → `defp maybe_update_newsletters_delivery(message_id, event_type, timestamp)`
- Update all 3 call sites (lines ~394, ~480, ~547):
  - `maybe_update_mailing_delivery(message_id, "Delivery", ...)` → `maybe_update_newsletters_delivery(message_id, "Delivery", ...)`
  - `maybe_update_mailing_delivery(message_id, "Bounce", ...)` → `maybe_update_newsletters_delivery(message_id, "Bounce", ...)`
  - `maybe_update_mailing_delivery(message_id, "Open", ...)` → `maybe_update_newsletters_delivery(message_id, "Open", ...)`
- Inside the function body: any `Mailing.` references → `Newsletters.`

**Note:** Check whether `sqs_processor.ex` has an `alias PhoenixKit.Modules.Mailing` — if so, update to `alias PhoenixKit.Modules.Newsletters`.

### 13b: template.ex

Change the valid categories list:

```elixir
# Old:
@valid_categories ["system", "marketing", "transactional", "notification", "mailing"]

# New:
@valid_categories ["system", "marketing", "transactional", "notification", "newsletters"]
```

**Step 2: Commit**

```bash
cd /app
git add lib/modules/emails/sqs_processor.ex lib/modules/emails/template.ex
git commit -m "Update Emails module references from mailing to newsletters"
```

---

## Task 14: Update HEEX Templates

**Files:**
- `lib/modules/newsletters/web/broadcasts.html.heex`
- `lib/modules/newsletters/web/broadcast_editor.html.heex`
- `lib/modules/newsletters/web/broadcast_details.html.heex`
- `lib/modules/newsletters/web/lists.html.heex`
- `lib/modules/newsletters/web/list_editor.html.heex`
- `lib/modules/newsletters/web/list_members.html.heex`
- `lib/modules/newsletters/web/unsubscribe_html/unsubscribe.html.heex`
- `lib/modules/emails/web/emails.html.heex`
- `lib/modules/emails/web/templates.html.heex`
- `lib/modules/emails/web/template_editor.html.heex`

### Mailing-namespace templates (newsletters/web/*.heex)

Read each file and replace:
- Any hardcoded `/admin/mailing/` path strings → `/admin/newsletters/`
- Any UI label text `"Mailing"` that refers to the module name → `"Newsletters"`
- Any `mailing` in route helper atom names (e.g. `:mailing_broadcasts`) → `:newsletters_broadcasts`

### Emails module templates

**`emails.html.heex` line ~135:**
```heex
<%!-- Old --%>
<option value="mailing" selected={@filters.category == "mailing"}>
  Mailing
</option>

<%!-- New --%>
<option value="newsletters" selected={@filters.category == "newsletters"}>
  Newsletters
</option>
```

**`templates.html.heex` line ~112:**
```heex
<%!-- Old --%>
<option value="mailing" selected={@filters.category == "mailing"}>
  Mailing
</option>

<%!-- New --%>
<option value="newsletters" selected={@filters.category == "newsletters"}>
  Newsletters
</option>
```

**`template_editor.html.heex` lines ~133-134:**
```heex
<%!-- Old --%>
value="mailing"
selected={Ecto.Changeset.get_field(@changeset, :category) == "mailing"}

<%!-- New --%>
value="newsletters"
selected={Ecto.Changeset.get_field(@changeset, :category) == "newsletters"}
```

**Step 2: Commit**

```bash
cd /app
git add lib/modules/newsletters/web/*.heex \
        lib/modules/newsletters/web/unsubscribe_html/unsubscribe.html.heex \
        lib/modules/emails/web/emails.html.heex \
        lib/modules/emails/web/templates.html.heex \
        lib/modules/emails/web/template_editor.html.heex
git commit -m "Update all HEEX templates: mailing paths and category values to newsletters"
```

---

## Task 15: Update modules.ex and modules.html.heex

**Files:**
- Modify: `lib/phoenix_kit_web/live/modules.ex`
- Modify: `lib/phoenix_kit_web/live/modules.html.heex`

### modules.ex

Changes:
- `defp dispatch_toggle(socket, "mailing")` → `defp dispatch_toggle(socket, "newsletters")`
- `defp toggle_mailing(socket)` → `defp toggle_newsletters(socket)`
- Inside `toggle_newsletters`: `configs["mailing"]` → `configs["newsletters"]`, `mailing_enabled` → `newsletters_enabled`
- `generic_toggle(socket, "mailing")` (both occurrences) → `generic_toggle(socket, "newsletters")`
- The call `dispatch_toggle(socket, "mailing")` → `dispatch_toggle(socket, "newsletters")`

### modules.html.heex

Changes:
- `if "mailing" in @accessible_modules` → `if "newsletters" in @accessible_modules`
- `@module_configs["mailing"]` → `@module_configs["newsletters"]`
- `toggle_key="mailing"` → `toggle_key="newsletters"`
- Path in navigate: `/admin/mailing/broadcasts` → `/admin/newsletters/broadcasts`
- Path in navigate: `/admin/mailing/lists` → `/admin/newsletters/lists`

**Step 2: Commit**

```bash
cd /app
git add lib/phoenix_kit_web/live/modules.ex lib/phoenix_kit_web/live/modules.html.heex
git commit -m "Update Modules LiveView to use newsletters key and paths"
```

---

## Task 16: Full Compile and Quality Check

**Step 1: Format**

```bash
cd /app && mix format
```

**Step 2: Compile with strict warnings**

```bash
cd /app && mix compile --warnings-as-errors 2>&1
```

Expected: zero errors, zero warnings.

**Step 3: Credo**

```bash
cd /app && mix credo --strict 2>&1
```

Expected: no issues.

**Step 4: Full quality suite**

```bash
cd /app && mix quality 2>&1
```

Expected: all checks pass.

**Step 5: Fix any remaining issues**

If compile shows `undefined module PhoenixKit.Modules.Mailing` or similar — search for remaining `Mailing` references:

```bash
cd /app && grep -rn "Modules\.Mailing" lib/ --include="*.ex"
```

If any found, fix them and recompile.

**Step 6: Final commit**

```bash
cd /app
git add -p  # Stage any format changes
git commit -m "Fix formatting after mailing→newsletters rename"
```

---

## Task 17: Verify in Parent App

**Context:** PhoenixKit is a library. Test in Hydroforce (`/root/projects/hydroforce`).

**Step 1: Run rollback in parent app (user must do this if not done)**

```bash
cd /root/projects/hydroforce
mix ecto.rollback --to 78
```

Expected output: `[info] == Rolled back V79 in X.Xs`

**Step 2: Update PhoenixKit dependency**

```bash
cd /root/projects/hydroforce
mix deps.compile phoenix_kit --force
```

**Step 3: Run migration**

```bash
cd /root/projects/hydroforce
mix ecto.migrate
```

Expected: V79 runs and creates `phoenix_kit_newsletters_*` tables.

**Step 4: Update Oban queue config in parent app**

In `/root/projects/hydroforce/config/config.exs`, change:
```elixir
# Old:
mailing_delivery: 10

# New:
newsletters_delivery: 10
```

**Step 5: Start server and verify**

```bash
# In TMUX phoenixkit:1.2 — restart server
# Then check:
curl -s http://localhost:4000/phoenix_kit/admin/newsletters/broadcasts | head -5
```

Expected: 200 response (or redirect to login), not 404.

**Step 6: Check admin panel**

Navigate to `http://localhost:4000/phoenix_kit/admin` and verify:
- "Newsletters" tab appears in sidebar (when Newsletters module enabled)
- Links go to `/admin/newsletters/broadcasts` and `/admin/newsletters/lists`

---

## Task 18: Final Commit and Changelog

**Step 1: Check current version**

```bash
cd /app && mix run --eval "IO.puts Mix.Project.config[:version]"
```

**Step 2: Update CHANGELOG.md**

Add entry for this rename under the current version:

```markdown
### Changed
- Renamed `mailing` module to `newsletters` — all table names, URL paths,
  settings keys, Oban queue, and Elixir modules updated accordingly
- DB tables: `phoenix_kit_mailing_*` → `phoenix_kit_newsletters_*`
- URL paths: `/admin/mailing/*` → `/admin/newsletters/*`
- Oban queue: `mailing_delivery` → `newsletters_delivery`
- Settings keys: `mailing_enabled`, `mailing_default_template`, `mailing_rate_limit`
  → `newsletters_enabled`, `newsletters_default_template`, `newsletters_rate_limit`
- Email template category: `"mailing"` → `"newsletters"`

### Migration Notes
- V79 migration rewritten in-place — run `mix ecto.rollback --to 78` in parent app
  before applying new V79
```

**Step 3: Final commit**

```bash
cd /app
git add CHANGELOG.md
git commit -m "Update CHANGELOG for mailing→newsletters rename"
```

---

## Quick Reference: All Files Changed

### New directory location
```
lib/modules/mailing/          → lib/modules/newsletters/
lib/phoenix_kit_web/routes/mailing.ex → lib/phoenix_kit_web/routes/newsletters.ex
lib/modules/newsletters/mailing.ex → lib/modules/newsletters/newsletters.ex  (renamed)
```

### Modified files (not moved)
```
lib/phoenix_kit/migrations/postgres/v79.ex           # Task 1
lib/phoenix_kit/module_registry.ex                   # Task 10
lib/phoenix_kit/install/oban_config.ex               # Task 11
lib/phoenix_kit/scheduled_jobs/workers/process_scheduled_jobs_worker.ex  # Task 12
lib/phoenix_kit_web/integration.ex                   # Task 9
lib/phoenix_kit_web/live/modules.ex                  # Task 15
lib/phoenix_kit_web/live/modules.html.heex           # Task 15
lib/modules/emails/sqs_processor.ex                  # Task 13
lib/modules/emails/template.ex                       # Task 13
lib/modules/emails/web/emails.html.heex              # Task 14
lib/modules/emails/web/templates.html.heex           # Task 14
lib/modules/emails/web/template_editor.html.heex     # Task 14
```

### Moved + modified (all in lib/modules/newsletters/)
```
newsletters.ex (was mailing.ex)          # Task 4
list.ex                                  # Task 3
list_member.ex                           # Task 3
broadcast.ex                             # Task 3
delivery.ex                              # Task 3
broadcaster.ex                           # Task 5
workers/delivery_worker.ex              # Task 6
web/broadcasts.ex                       # Task 7
web/broadcast_editor.ex                 # Task 7
web/broadcast_details.ex                # Task 7
web/lists.ex                            # Task 7
web/list_editor.ex                      # Task 7
web/list_members.ex                     # Task 7
web/unsubscribe_controller.ex           # Task 7
web/unsubscribe_html.ex                 # Task 7
web/broadcasts.html.heex                # Task 14
web/broadcast_editor.html.heex          # Task 14
web/broadcast_details.html.heex         # Task 14
web/lists.html.heex                     # Task 14
web/list_editor.html.heex               # Task 14
web/list_members.html.heex              # Task 14
web/unsubscribe_html/unsubscribe.html.heex  # Task 14
```

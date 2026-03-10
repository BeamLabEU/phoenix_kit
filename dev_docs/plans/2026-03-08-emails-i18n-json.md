# Emails Module i18n (JSON Fields) Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add multilingual support to the emails module using JSON map fields (`%{"en" => "...", "uk" => "..."}`) for translatable content, enabling templates to be created and sent in multiple languages.

**Architecture:** Translatable fields (`subject`, `html_body`, `text_body`, `display_name`, `description`) in `phoenix_kit_email_templates` are converted from `string` to `jsonb` columns storing language-keyed maps. A shared `get_translation/3` helper extracts the correct locale's value at render time. The template editor UI gains a locale tab bar for per-language editing. Email logs gain a `locale` field to track which language was sent.

**Tech Stack:** Elixir/Phoenix, Ecto, PostgreSQL JSONB, LiveView, DaisyUI 5, Gettext

---

## Pre-requisites

```bash
# Verify current migration version (should be 79)
ls lib/phoenix_kit/migrations/postgres/v*.ex | sed 's/.*\/v\([0-9]*\)\.ex/\1/' | sort -rn | head -1

# Verify starting point compiles cleanly
mix compile --warnings-as-errors
mix credo --strict
```

---

## Task 1: Migration V80 — Convert email_templates fields to JSONB, add locale to logs

**Files:**
- Create: `lib/phoenix_kit/migrations/postgres/v80.ex`
- Modify: `lib/phoenix_kit/migrations/postgres.ex` (register V80)

### Step 1: Create the migration file

```elixir
# lib/phoenix_kit/migrations/postgres/v80.ex
defmodule PhoenixKit.Migrations.Postgres.V80 do
  @moduledoc """
  V80: Emails Module i18n — JSON language fields

  Converts 5 text fields in phoenix_kit_email_templates to JSONB for multilingual support.
  Existing data is preserved by wrapping current values under the "en" key.

  Adds `locale` field to phoenix_kit_email_logs for tracking which language was sent.
  """

  use Ecto.Migration

  def up(%{prefix: prefix} = _opts) do
    p = prefix_str(prefix)

    # Convert template content fields to JSONB
    # Existing string values are preserved as {"en": "original_value"}
    execute("""
    ALTER TABLE #{p}phoenix_kit_email_templates
      ALTER COLUMN subject TYPE jsonb
        USING jsonb_build_object('en', subject),
      ALTER COLUMN html_body TYPE jsonb
        USING jsonb_build_object('en', html_body),
      ALTER COLUMN text_body TYPE jsonb
        USING jsonb_build_object('en', text_body),
      ALTER COLUMN display_name TYPE jsonb
        USING jsonb_build_object('en', display_name),
      ALTER COLUMN description TYPE jsonb
        USING CASE
          WHEN description IS NULL THEN NULL
          ELSE jsonb_build_object('en', description)
        END
    """)

    # Add locale tracking to email logs
    execute("""
    ALTER TABLE #{p}phoenix_kit_email_logs
      ADD COLUMN IF NOT EXISTS locale VARCHAR(10) NOT NULL DEFAULT 'en'
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_email_logs_locale
      ON #{p}phoenix_kit_email_logs (locale)
    """)
  end

  def down(%{prefix: prefix} = _opts) do
    p = prefix_str(prefix)

    # Revert JSONB back to text — extract the "en" value
    execute("""
    ALTER TABLE #{p}phoenix_kit_email_templates
      ALTER COLUMN subject TYPE varchar(300)
        USING (subject->>'en'),
      ALTER COLUMN html_body TYPE text
        USING (html_body->>'en'),
      ALTER COLUMN text_body TYPE text
        USING (text_body->>'en'),
      ALTER COLUMN display_name TYPE varchar(200)
        USING (display_name->>'en'),
      ALTER COLUMN description TYPE text
        USING (description->>'en')
    """)

    execute("DROP INDEX IF EXISTS #{p}idx_email_logs_locale")

    execute("""
    ALTER TABLE #{p}phoenix_kit_email_logs
      DROP COLUMN IF EXISTS locale
    """)
  end

  defp prefix_str(nil), do: ""
  defp prefix_str(""), do: ""
  defp prefix_str(prefix), do: "#{prefix}."
end
```

### Step 2: Register V80 in the migration runner

Open `lib/phoenix_kit/migrations/postgres.ex`. Find the `@migrations` list and add V80:

```elixir
# Before (end of list):
{79, PhoenixKit.Migrations.Postgres.V79}

# After:
{79, PhoenixKit.Migrations.Postgres.V79},
{80, PhoenixKit.Migrations.Postgres.V80}
```

Also update the `@current_version` or equivalent constant if present.

### Step 3: Compile and verify

```bash
cd /app
mix compile --warnings-as-errors
```

Expected: no errors. If there are pattern match warnings on `prefix_str/1`, check existing V79 for the correct private helper pattern used in your codebase and match it.

### Step 4: Commit

```bash
git add lib/phoenix_kit/migrations/postgres/v80.ex lib/phoenix_kit/migrations/postgres.ex
git commit -m "Add V80 migration: convert email template fields to JSONB, add locale to logs"
```

---

## Task 2: Update Ecto Schemas — Template and Log

**Files:**
- Modify: `lib/modules/emails/template.ex`
- Modify: `lib/modules/emails/log.ex`

### Step 1: Update Template schema field types

In `lib/modules/emails/template.ex`, find the schema block (around line 116):

```elixir
# Replace these 5 fields:
field :display_name, :string
field :description, :string
field :subject, :string
field :html_body, :string
field :text_body, :string

# With:
field :display_name, :map, default: %{}
field :description, :map, default: nil
field :subject, :map, default: %{}
field :html_body, :map, default: %{}
field :text_body, :map, default: %{}
```

Note: `description` is nullable in DB (NULL allowed), so `default: nil` is correct.

### Step 2: Update Log schema

In `lib/modules/emails/log.ex`, find the schema block and add `locale` field after `template_name`:

```elixir
# After:
field :template_name, :string

# Add:
field :locale, :string, default: "en"
```

### Step 3: Compile

```bash
mix compile --warnings-as-errors
```

Expected: compilation errors in changeset functions and any code that calls `.subject`, `.html_body`, `.text_body`, `.display_name`, `.description` as plain strings. These are expected and will be fixed in subsequent tasks.

### Step 4: Commit (with compilation errors noted — fixes come next)

```bash
git add lib/modules/emails/template.ex lib/modules/emails/log.ex
git commit -m "Update Template schema fields to :map for i18n JSON support, add locale to Log"
```

---

## Task 3: Shared i18n Helper — `get_translation/3`

**Files:**
- Modify: `lib/modules/emails/template.ex` (add private + public helpers)

This helper is the cornerstone of the entire feature. It extracts the correct language string from a JSON map field, with fallback.

### Step 1: Add `get_translation/3` to the Template module

In `lib/modules/emails/template.ex`, add after the module-level `@valid_statuses` or constants section (before the schema definition), add a public function:

```elixir
@doc """
Extracts a translated string from a JSON language map field.

## Parameters
- `field_map` — a map like `%{"en" => "...", "uk" => "..."}`
- `locale` — the desired locale code, e.g. `"uk"` or `"en-US"`
- `default_locale` — fallback locale, defaults to `"en"`

## Behaviour
1. Try exact match: `field_map[locale]`
2. Try base language: `field_map["en"]` (if locale is e.g. `"en-US"`)
3. Try default_locale
4. Return `""` if nothing found

## Examples

    iex> get_translation(%{"en" => "Hello", "uk" => "Привіт"}, "uk")
    "Привіт"

    iex> get_translation(%{"en" => "Hello"}, "uk")
    "Hello"

    iex> get_translation(%{"en" => "Hello"}, "uk", "en")
    "Hello"

    iex> get_translation(nil, "uk")
    ""

"""
def get_translation(field_map, locale, default_locale \\ "en")

def get_translation(nil, _locale, _default_locale), do: ""
def get_translation(field_map, locale, default_locale) when is_map(field_map) do
  # 1. Exact locale match
  # 2. Base language (e.g. "en" from "en-US")
  # 3. Default locale
  # 4. First available value (last resort)
  base_locale = locale |> String.split("-") |> List.first()

  Map.get(field_map, locale) ||
    Map.get(field_map, base_locale) ||
    Map.get(field_map, default_locale) ||
    (field_map |> Map.values() |> List.first()) ||
    ""
end
def get_translation(_field_map, _locale, _default_locale), do: ""
```

### Step 2: Compile

```bash
mix compile --warnings-as-errors
```

### Step 3: Commit

```bash
git add lib/modules/emails/template.ex
git commit -m "Add get_translation/3 helper for i18n JSON map field extraction"
```

---

## Task 4: Fix `extract_variables/1` — Handle JSON map fields

**Files:**
- Modify: `lib/modules/emails/template.ex` (around line 306)

`extract_variables/1` currently concatenates `template.subject`, `template.html_body`, `template.text_body` as strings. Now they are maps — we must extract content from all language versions.

### Step 1: Update `extract_variables/1`

```elixir
# Replace current implementation:
def extract_variables(%__MODULE__{} = template) do
  content = "#{template.subject} #{template.html_body} #{template.text_body}"

  Regex.scan(~r/\{\{([^}]+)\}\}/, content)
  |> Enum.map(fn [_, var] -> String.trim(var) end)
  |> Enum.uniq()
  |> Enum.sort()
end

# With:
def extract_variables(%__MODULE__{} = template) do
  # Collect all language values from all map fields and scan for {{variables}}
  content =
    [template.subject, template.html_body, template.text_body]
    |> Enum.flat_map(fn
      map when is_map(map) -> Map.values(map)
      str when is_binary(str) -> [str]
      _ -> []
    end)
    |> Enum.join(" ")

  Regex.scan(~r/\{\{([^}]+)\}\}/, content)
  |> Enum.map(fn [_, var] -> String.trim(var) end)
  |> Enum.uniq()
  |> Enum.sort()
end
```

### Step 2: Compile and check

```bash
mix compile --warnings-as-errors
mix credo --strict
```

### Step 3: Commit

```bash
git add lib/modules/emails/template.ex
git commit -m "Fix extract_variables to handle JSON map fields across all locales"
```

---

## Task 5: Fix `substitute_variables/2` — Accept locale, work with strings

**Files:**
- Modify: `lib/modules/emails/template.ex` (around line 336)

`substitute_variables/2` currently mutates `template.subject`, `template.html_body`, `template.text_body` as strings. Now these are maps. The function should accept a `locale` parameter and return resolved strings (not a template struct).

### Step 1: Update `substitute_variables/2`

```elixir
# Replace current implementation entirely:

@doc """
Substitutes variables in template content for a specific locale.

Returns a map with `:subject`, `:html_body`, `:text_body` as rendered strings.

## Parameters
- `template` — the EmailTemplate struct
- `variables` — map of variable names to values
- `locale` — the target locale (default: `"en"`)

## Examples

    iex> template = %EmailTemplate{
    ...>   subject: %{"en" => "Welcome {{user_name}}!"},
    ...>   html_body: %{"en" => "<p>Hi {{user_name}}</p>"},
    ...>   text_body: %{"en" => "Hi {{user_name}}"}
    ...> }
    iex> result = EmailTemplate.substitute_variables(template, %{"user_name" => "John"}, "en")
    iex> result.subject
    "Welcome John!"

"""
def substitute_variables(%__MODULE__{} = template, variables, locale \\ "en")
    when is_map(variables) do
  %{
    subject: template.subject |> get_translation(locale) |> substitute_string(variables),
    html_body: template.html_body |> get_translation(locale) |> substitute_string(variables),
    text_body: template.text_body |> get_translation(locale) |> substitute_string(variables)
  }
end
```

Note: `substitute_string/2` is the existing private helper that replaces `{{var}}` in a string — it does not change.

### Step 2: Fix `validate_template_variables/1` (private)

This private function calls `get_field(changeset, :subject)` expecting a string. Update it to extract from the map:

In the `validate_template_variables/1` private function, find where it matches:
```elixir
{subject, html_body, text_body}
when is_binary(subject) and is_binary(html_body) and is_binary(text_body) ->
```

Replace the pattern match and logic with map-aware extraction:
```elixir
{subject_map, html_body_map, text_body_map}
when is_map(subject_map) or is_map(html_body_map) or is_map(text_body_map) ->
  # Collect all text from all locales for variable validation
  all_text =
    [subject_map, html_body_map, text_body_map]
    |> Enum.flat_map(fn
      m when is_map(m) -> Map.values(m)
      s when is_binary(s) -> [s]
      _ -> []
    end)
    |> Enum.join(" ")

  template = %__MODULE__{
    subject: %{"en" => all_text},
    html_body: %{"en" => ""},
    text_body: %{"en" => ""}
  }
  # ... rest of validation logic
```

Alternatively, simplify: since `extract_variables/1` is already fixed to handle maps, call it directly on the template being validated.

### Step 3: Compile

```bash
mix compile --warnings-as-errors
```

Fix any remaining compilation errors related to calling `.subject` as a string elsewhere.

### Step 4: Commit

```bash
git add lib/modules/emails/template.ex
git commit -m "Update substitute_variables to accept locale and work with JSON map fields"
```

---

## Task 6: Fix Changeset — Validate JSON map structure

**Files:**
- Modify: `lib/modules/emails/template.ex` (changeset function, around line 223)

The changeset must accept and validate the new JSON map structure for the 5 translatable fields.

### Step 1: Update changeset field types and validation

```elixir
def changeset(template, attrs) do
  template
  |> cast(attrs, [
    :name,
    :slug,
    :display_name,    # now :map
    :description,     # now :map
    :subject,         # now :map
    :html_body,       # now :map
    :text_body,       # now :map
    :category,
    :status,
    :variables,
    :metadata,
    :is_system,
    :created_by_user_uuid,
    :updated_by_user_uuid
  ])
  |> auto_generate_slug()
  |> validate_required([
    :name,
    :slug,
    :display_name,
    :subject,
    :html_body,
    :text_body,
    :category,
    :status
  ])
  |> validate_length(:name, min: 2, max: 100)
  |> validate_length(:slug, min: 2, max: 100)
  # Remove validate_length on :display_name, :subject, :html_body, :text_body
  # (they are now maps — use custom validation below)
  |> validate_i18n_map(:display_name, min_length: 2, max_length: 200)
  |> validate_i18n_map(:subject, min_length: 1, max_length: 300)
  |> validate_i18n_map(:html_body, min_length: 1)
  |> validate_i18n_map(:text_body, min_length: 1)
  |> validate_inclusion(:category, @valid_categories)
  |> validate_inclusion(:status, @valid_statuses)
  |> validate_format(:name, ~r/^[a-z][a-z0-9_]*$/,
    message:
      "must start with a letter and contain only lowercase letters, numbers, and underscores"
  )
  |> validate_format(:slug, ~r/^[a-z][a-z0-9-]*$/,
    message: "must start with a letter and contain only lowercase letters, numbers, and hyphens"
  )
  |> unique_constraint(:name)
  |> unique_constraint(:slug)
  |> validate_template_variables()
end
```

### Step 2: Add `validate_i18n_map/3` private helper

```elixir
# Add this private function:
defp validate_i18n_map(changeset, field, opts \\ []) do
  min_length = Keyword.get(opts, :min_length, 0)
  max_length = Keyword.get(opts, :max_length, nil)

  case get_field(changeset, field) do
    nil ->
      changeset

    map when is_map(map) and map_size(map) == 0 ->
      add_error(changeset, field, "must have at least one language")

    map when is_map(map) ->
      # Validate each language value
      errors =
        Enum.flat_map(map, fn {lang, value} ->
          cond do
            not is_binary(value) ->
              ["#{lang}: must be a string"]

            String.length(value) < min_length ->
              ["#{lang}: must be at least #{min_length} characters"]

            max_length != nil and String.length(value) > max_length ->
              ["#{lang}: must be at most #{max_length} characters"]

            true ->
              []
          end
        end)

      case errors do
        [] -> changeset
        msgs -> add_error(changeset, field, Enum.join(msgs, "; "))
      end

    _ ->
      add_error(changeset, field, "must be a language map (e.g. %{\"en\" => \"...\"})")
  end
end
```

### Step 3: Update `display_name` in `handle_params` (template_editor.ex)

The `page_title` assign uses `template.display_name` directly as a string. Update to:

```elixir
# Before:
|> assign(:page_title, "Edit Template: #{template.display_name}")

# After (extract default locale for admin display):
|> assign(:page_title, "Edit Template: #{Template.get_translation(template.display_name, "en")}")
```

### Step 4: Compile

```bash
mix compile --warnings-as-errors
mix credo --strict
```

### Step 5: Commit

```bash
git add lib/modules/emails/template.ex lib/modules/emails/web/template_editor.ex
git commit -m "Add validate_i18n_map validation for JSON language map fields in Template changeset"
```

---

## Task 7: Fix `render_template/2` → `render_template/3` with locale

**Files:**
- Modify: `lib/modules/emails/templates.ex` (around line 366)

### Step 1: Update `render_template` signature and implementation

```elixir
@doc """
Renders a template by substituting variables for a specific locale.

## Parameters
- `template` — the EmailTemplate struct
- `variables` — map of variable names to values
- `locale` — the target locale code (default: `"en"`)

## Returns
`%{subject: string, html_body: string, text_body: string}`

## Examples

    iex> Templates.render_template(template, %{"user_name" => "John"}, "uk")
    %{subject: "Ласкаво просимо, John!", html_body: "...", text_body: "..."}

"""
def render_template(%Template{} = template, variables \\ %{}, locale \\ "en") do
  # Extract required variables from all language versions
  required_vars = Template.extract_variables(template)
  provided_vars = Map.keys(variables)

  missing_vars = required_vars -- provided_vars

  if missing_vars != [] do
    Logger.warning(
      "Template '#{template.name}' is missing required variables: #{Enum.join(missing_vars, ", ")}"
    )
  end

  unused_vars = provided_vars -- required_vars

  if unused_vars != [] do
    Logger.info(
      "Template '#{template.name}' has unused variables: #{Enum.join(unused_vars, ", ")}"
    )
  end

  # Perform locale-aware variable substitution
  rendered = Template.substitute_variables(template, variables, locale)

  # Validate for unreplaced variables
  validate_rendered_content(template.name, rendered)

  rendered
end
```

Note: `validate_rendered_content/2` already receives a map `%{subject:, html_body:, text_body:}` — verify it works with the new return type from `substitute_variables/2` (it should, since both return the same shape).

### Step 2: Find all callers of `render_template/2` and update

```bash
# Find all call sites
grep -rn "render_template" lib/ --include="*.ex"
```

For each caller, check if a locale is available in context and pass it:
- `PhoenixKit.Mailer` or `mailer.ex` — should accept `locale` option
- Any test send logic in `template_editor.ex` — use the editor's current locale

### Step 3: Compile

```bash
mix compile --warnings-as-errors
```

### Step 4: Commit

```bash
git add lib/modules/emails/templates.ex
git commit -m "Update render_template/3 to accept locale for i18n template rendering"
```

---

## Task 8: Fix Interceptor — Pass locale to email logs

**Files:**
- Modify: `lib/modules/emails/interceptor.ex`

### Step 1: Update `extract_email_data/2` to capture locale

In `interceptor.ex`, find `extract_email_data/2`. Add locale extraction from opts:

```elixir
defp extract_email_data(%Email{} = email, opts) do
  # ... existing code ...

  # Add locale extraction (opts comes from caller like send_from_template)
  locale = Keyword.get(opts, :locale, "en")

  %{
    # ... existing fields ...
    locale: locale
  }
end
```

### Step 2: Update callers of `create_email_log/2`

When `PhoenixKit.Mailer.send_from_template/4` (or equivalent) calls the interceptor, pass `locale: locale` in opts:

```bash
grep -rn "create_email_log\|deliver_email\|send_from_template" lib/ --include="*.ex"
```

For each call site, ensure locale is threaded through.

### Step 3: Compile

```bash
mix compile --warnings-as-errors
mix credo --strict
```

### Step 4: Commit

```bash
git add lib/modules/emails/interceptor.ex
git commit -m "Pass locale through interceptor to email log for i18n tracking"
```

---

## Task 9: Template Editor LiveView — Locale State & Switching

**Files:**
- Modify: `lib/modules/emails/web/template_editor.ex`

This is the main LiveView logic change. Add locale awareness to the editor.

### Step 1: Add locale assigns to `mount/3`

```elixir
def mount(_params, _session, socket) do
  project_title = Settings.get_project_title()

  # Get available locales from Languages module (or default to ["en"])
  available_locales = get_available_locales()
  default_locale = List.first(available_locales) || "en"

  socket =
    socket
    |> assign(:project_title, project_title)
    |> assign(:template, nil)
    |> assign(:mode, :new)
    |> assign(:loading, false)
    |> assign(:saving, false)
    |> assign(:changeset, Template.changeset(%Template{}, %{}))
    |> assign(:preview_mode, "html")
    |> assign(:show_test_modal, false)
    |> assign(:test_sending, false)
    |> assign(:test_form, %{recipient: "", sample_variables: %{}, errors: %{}})
    |> assign(:extracted_variables, [])
    |> assign(:available_locales, available_locales)   # ["en", "uk", "et"]
    |> assign(:current_editor_locale, default_locale)  # "en"

  {:ok, socket}
end
```

Add private helper at the bottom of the file:

```elixir
# Get locales enabled in the Languages module, fallback to ["en"]
defp get_available_locales do
  if function_exported?(PhoenixKit.Modules.Languages, :enabled?, 0) and
       PhoenixKit.Modules.Languages.enabled?() do
    PhoenixKit.Modules.Languages.get_enabled_language_codes()
  else
    [PhoenixKit.Settings.get_content_language() || "en"]
  end
end
```

### Step 2: Add locale switching event handler

```elixir
def handle_event("switch_editor_locale", %{"locale" => locale}, socket) do
  available = socket.assigns.available_locales

  if locale in available do
    {:noreply, assign(socket, :current_editor_locale, locale)}
  else
    {:noreply, socket}
  end
end
```

### Step 3: Update `validate` handler to work with nested locale params

The form will now send params like:
```
%{"email_template" => %{
  "subject" => %{"en" => "...", "uk" => "..."},
  "html_body" => %{"en" => "...", "uk" => "..."},
  ...
}}
```

The existing `validate` handler:
```elixir
def handle_event("validate", %{"email_template" => template_params}, socket) do
  template = socket.assigns.template || %Template{}
  # ...
  changeset = Template.changeset(template, template_params)
  # ...
end
```

This already works if form params send maps — Ecto's `cast/3` with `:map` type accepts nested maps from form params. However, the HTML form inputs must be structured correctly (see Task 10).

### Step 4: Update test send to use current locale

In `handle_event("send_test", ...)`, pass the current locale to render:

```elixir
def handle_event("send_test", params, socket) do
  # ...
  locale = socket.assigns.current_editor_locale
  changeset_data = Ecto.Changeset.apply_changes(socket.assigns.changeset)

  # Use locale when rendering
  rendered = Templates.render_template(changeset_data, variables, locale)
  # ...
end
```

### Step 5: Update live preview to use current locale

If there's a `preview` computation in the LiveView that renders subject/body for display, update it to use `current_editor_locale`:

```bash
grep -n "preview\|html_body\|subject\|text_body" lib/modules/emails/web/template_editor.ex
```

### Step 6: Compile

```bash
mix compile --warnings-as-errors
mix credo --strict
```

### Step 7: Commit

```bash
git add lib/modules/emails/web/template_editor.ex
git commit -m "Add locale state management and switching to template editor LiveView"
```

---

## Task 10: Template Editor UI — Locale Tab Bar

**Files:**
- Modify: `lib/modules/emails/web/template_editor.html.heex`

This is the largest UI change. Replace single-field inputs with locale-tabbed inputs for the 5 translatable fields.

### Step 1: Add locale tab bar above the Email Content section

Find the "Email Content" section header in `template_editor.html.heex`. Insert a locale tab bar BEFORE the subject/html_body/text_body inputs:

```heex
<%!-- Locale tab bar — only shown when multiple locales available --%>
<%= if length(@available_locales) > 1 do %>
  <div class="tabs tabs-border mb-4">
    <%= for locale <- @available_locales do %>
      <button
        class={"tab #{if locale == @current_editor_locale, do: "tab-active", else: ""}"}
        phx-click="switch_editor_locale"
        phx-value-locale={locale}
        type="button"
      >
        <%= String.upcase(locale) %>
      </button>
    <% end %>
  </div>
<% end %>
```

### Step 2: Replace subject input with locale-aware hidden + visible inputs

The form must submit ALL locale values, but show only the current locale's input.

```heex
<%!-- Subject: hidden inputs for all locales + visible input for current locale --%>
<div class="form-control">
  <label class="label">
    <span class="label-text font-medium">Subject Line</span>
  </label>

  <%!-- Hidden inputs preserve all locale values in form state --%>
  <%= for locale <- @available_locales do %>
    <%= if locale != @current_editor_locale do %>
      <input
        type="hidden"
        name={"email_template[subject][#{locale}]"}
        value={Template.get_translation(@changeset |> Ecto.Changeset.get_field(:subject) || %{}, locale)}
      />
    <% end %>
  <% end %>

  <%!-- Visible input for current locale --%>
  <input
    type="text"
    name={"email_template[subject][#{@current_editor_locale}]"}
    value={Template.get_translation(@changeset |> Ecto.Changeset.get_field(:subject) || %{}, @current_editor_locale)}
    class={"input input-bordered w-full #{if @changeset.action && @changeset.errors[:subject], do: "input-error", else: ""}"}
    placeholder="Subject in #{String.upcase(@current_editor_locale)}..."
    phx-change="validate"
    phx-debounce="300"
  />

  <%= if @changeset.action do %>
    <.error :for={{msg, _} <- (@changeset.errors[:subject] || [])}><%= msg %></.error>
  <% end %>
</div>
```

### Step 3: Apply same pattern to `html_body` and `text_body`

```heex
<%!-- HTML Body: hidden + visible textareas per locale --%>
<div class="form-control">
  <label class="label">
    <span class="label-text font-medium">HTML Body</span>
  </label>

  <%= for locale <- @available_locales do %>
    <%= if locale != @current_editor_locale do %>
      <textarea
        name={"email_template[html_body][#{locale}]"}
        hidden
      ><%= Template.get_translation(@changeset |> Ecto.Changeset.get_field(:html_body) || %{}, locale) %></textarea>
    <% end %>
  <% end %>

  <textarea
    name={"email_template[html_body][#{@current_editor_locale}]"}
    class="textarea textarea-bordered w-full font-mono"
    rows="12"
    phx-change="validate"
    phx-debounce="300"
  ><%= Template.get_translation(@changeset |> Ecto.Changeset.get_field(:html_body) || %{}, @current_editor_locale) %></textarea>

  <%= if @changeset.action do %>
    <.error :for={{msg, _} <- (@changeset.errors[:html_body] || [])}><%= msg %></.error>
  <% end %>
</div>
```

Repeat for `text_body` (rows="8").

### Step 4: Apply to `display_name` and `description` (Basic Information section)

Same pattern but in the "Basic Information" section:

```heex
<%!-- Display Name --%>
<div class="form-control">
  <label class="label">
    <span class="label-text font-medium">Display Name</span>
  </label>
  <%= for locale <- @available_locales do %>
    <%= if locale != @current_editor_locale do %>
      <input type="hidden"
        name={"email_template[display_name][#{locale}]"}
        value={Template.get_translation(@changeset |> Ecto.Changeset.get_field(:display_name) || %{}, locale)}
      />
    <% end %>
  <% end %>
  <input
    type="text"
    name={"email_template[display_name][#{@current_editor_locale}]"}
    value={Template.get_translation(@changeset |> Ecto.Changeset.get_field(:display_name) || %{}, @current_editor_locale)}
    class="input input-bordered w-full"
    placeholder="Display name in #{String.upcase(@current_editor_locale)}..."
    phx-change="validate"
    phx-debounce="300"
  />
</div>
```

### Step 5: Update Live Preview to show current locale content

Find the preview panel. Replace any direct `@changeset.changes.subject` / `@changeset.data.html_body` references with locale-aware extraction:

```heex
<%!-- Preview header shows current locale --%>
<div class="text-sm text-base-content/60">
  Subject (<%= String.upcase(@current_editor_locale) %>):
  <%= Template.get_translation(Ecto.Changeset.get_field(@changeset, :subject) || %{}, @current_editor_locale) %>
</div>
```

### Step 6: Compile and test manually

```bash
mix compile --warnings-as-errors
mix format
```

Manual test in browser:
1. Navigate to `/admin/emails/templates/new`
2. Verify locale tabs appear (if Languages module is enabled with multiple locales)
3. Switch between tabs — verify subject/body inputs change to show locale-specific content
4. Fill in EN content, switch to UK, fill UK content
5. Save and verify both locales are stored in DB

### Step 7: Commit

```bash
git add lib/modules/emails/web/template_editor.html.heex
git commit -m "Add locale tab bar and per-locale field inputs to template editor"
```

---

## Task 11: Fix `templates.html.heex` — Display multilingual display_name

**Files:**
- Modify: `lib/modules/emails/web/templates.html.heex`

The templates list shows `template.display_name` and `template.description` — these are now maps.

### Step 1: Find all references to `.display_name` and `.description` in the template list

```bash
grep -n "display_name\|description" lib/modules/emails/web/templates.html.heex
```

### Step 2: Replace direct field access with `get_translation`

```heex
<%!-- Before: --%>
<%= template.display_name %>

<%!-- After: --%>
<%= Template.get_translation(template.display_name, @current_editor_locale || "en") %>
```

Note: The templates LiveView (`templates.ex`) may not have a `current_editor_locale` assign. Add it from the URL params or use a default. Check `templates.ex` mount function and add:

```elixir
|> assign(:display_locale, socket.assigns[:current_locale] || "en")
```

### Step 3: Fix subject display in the list table

```heex
<%!-- Before: --%>
<td><%= template.subject %></td>

<%!-- After: --%>
<td><%= Template.get_translation(template.subject, @display_locale) %></td>
```

### Step 4: Compile

```bash
mix compile --warnings-as-errors
```

### Step 5: Commit

```bash
git add lib/modules/emails/web/templates.html.heex lib/modules/emails/web/templates.ex
git commit -m "Update templates list to display multilingual fields with locale-aware extraction"
```

---

## Task 12: Fix Remaining Template References Across All .heex Files

**Files:**
- Check all `.heex` files in `lib/modules/emails/web/`

### Step 1: Find all remaining raw field references

```bash
grep -rn "\.display_name\|\.subject\|\.html_body\|\.text_body\|\.description" \
  lib/modules/emails/web/ --include="*.heex"
```

### Step 2: Fix each occurrence

For each reference, replace with `Template.get_translation(field_map, locale)`.

Common patterns to fix in `details.html.heex`:
```heex
<%!-- Before: --%>
<td><%= @email_log.subject %></td>

<%!-- After (log.subject is still a string — already sent content, not a map): --%>
<td><%= @email_log.subject %></td>
```

Note: `email_log.subject` stores the RENDERED subject that was actually sent (a string), not the template map. Only `email_template.*` fields are maps.

### Step 3: Fix .ex LiveView files too

```bash
grep -rn "\.display_name\|template\.subject\|template\.html_body" \
  lib/modules/emails/web/ --include="*.ex"
```

Fix any `template.display_name` → `Template.get_translation(template.display_name, locale)`.

### Step 4: Compile

```bash
mix compile --warnings-as-errors
mix credo --strict
```

### Step 5: Commit

```bash
git add lib/modules/emails/web/
git commit -m "Fix all template field references across emails LiveViews for i18n map fields"
```

---

## Task 13: Gettext for Admin UI Strings (9 files)

**Goal:** Wrap all hardcoded English UI strings in `gettext()` across all `.heex` files in the emails module. This is separate from the content i18n (JSON maps) — this is for the admin interface itself.

**Scale:** ~250 strings across 9 files. Do one file at a time.

**Priority order:**
1. `template_editor.html.heex` (~50 strings) — highest traffic
2. `emails.html.heex` (~40 strings)
3. `settings.html.heex` (~40 strings)
4. `templates.html.heex` (~30 strings) — partially done
5. `details.html.heex` (~30 strings)
6. `metrics.html.heex` (~25 strings)
7. `queue.html.heex` (~25 strings) — partially done
8. `blocklist.html.heex` (~20 strings) — partially done

### Step 1: For each file, find hardcoded strings

```bash
# Example for template_editor.html.heex
grep -n '"[A-Z][a-zA-Z ]*"' lib/modules/emails/web/template_editor.html.heex | head -20
```

### Step 2: Wrap each string

```heex
<%!-- Before: --%>
<span>Basic Information</span>

<%!-- After: --%>
<span><%= gettext("Basic Information") %></span>
```

For strings with variables:
```heex
<%!-- Before: --%>
<span>Email: <%= @email.to %></span>

<%!-- After: --%>
<span><%= gettext("Email: %{email}", email: @email.to) %></span>
```

### Step 3: After each file — compile, format, commit

```bash
mix compile --warnings-as-errors
mix format
git add lib/modules/emails/web/<filename>.html.heex
git commit -m "Wrap admin UI strings in gettext() for <filename>"
```

### Step 4: After all files — extract translations

```bash
# Generate .pot file with all found gettext strings
mix gettext.extract

# Merge into existing .po files
mix gettext.merge priv/gettext
```

This is done ONCE after all 9 files are updated. Note: actual translations (en.po, uk.po, et.po) are populated separately and are out of scope for this plan.

### Step 5: Commit

```bash
git add priv/gettext/
git commit -m "Extract gettext strings for emails module admin UI"
```

---

## Task 14: Quality Check & Final Verification

### Step 1: Full quality run

```bash
cd /app
mix format
mix compile --warnings-as-errors
mix credo --strict
mix test
```

Fix any issues found.

### Step 2: Manual verification checklist

In a parent app (Hydroforce) with PhoenixKit updated:

- [ ] Run `mix ecto.migrate` — V80 runs cleanly
- [ ] Open `/admin/emails/templates` — templates list shows correctly, display_name renders
- [ ] Click "New Template" — locale tab bar appears (if multiple languages enabled)
- [ ] Fill in EN subject/body → switch to UK tab → fill UK content → Save
- [ ] Verify DB: `SELECT subject, html_body FROM phoenix_kit_email_templates LIMIT 1` — shows `{"en": "...", "uk": "..."}`
- [ ] Send test email from template editor — uses current editor locale
- [ ] Check email log — `locale` column populated correctly
- [ ] Test `render_template(template, vars, "uk")` — returns Ukrainian content
- [ ] Test `render_template(template, vars, "fr")` — falls back to "en" gracefully
- [ ] Old templates (pre-migration) show correctly (content under "en" key)
- [ ] Run `mix ecto.rollback` — down migration runs cleanly, data preserved as "en" values

### Step 3: Run precommit

```bash
mix precommit
```

### Step 4: Final commit

```bash
git add -A
git commit -m "Complete emails module i18n: JSON language map fields, locale-aware rendering, editor tabs"
```

---

## Implementation Notes

### Form param structure for LiveView

When using nested input names like `email_template[subject][en]`, Phoenix/LiveView receives:
```elixir
%{"email_template" => %{"subject" => %{"en" => "Hello", "uk" => "Привіт"}}}
```

Ecto's `cast/3` with field type `:map` accepts this structure directly — no special handling needed.

### Locale resolution priority

`get_translation/3` uses this fallback chain:
1. Exact locale match (`"uk"`)
2. Base language (`"en"` from `"en-US"`)
3. Configured default locale
4. Any available value (last resort)
5. `""` if map is empty or nil

### System templates

System templates (`is_system: true`) — consider whether they need all locales or just "en". The plan doesn't restrict system templates, but they may need special handling in `changeset/2` if you want to lock their locale content.

### Languages module dependency

The `get_available_locales/0` helper in the template editor uses `PhoenixKit.Modules.Languages` if enabled. If the Languages module is not active, falls back to `[Settings.get_content_language()]` — typically `["en"]`. This means the locale tab bar only appears when the Languages module is enabled with multiple languages, which is the correct behavior.

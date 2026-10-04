defmodule PhoenixKit.Activity do
  alias PhoenixKit.Utils.Pagination

  @moduledoc """
  Activity feed for tracking business-level actions across the platform.

  Provides a simple API for logging and querying activities. Any module can call
  `Activity.log/1` to record an action. The admin dashboard shows a real-time
  activity stream.

  ## Usage

      PhoenixKit.Activity.log(%{
        action: "post.created",
        actor_uuid: user.uuid,
        resource_type: "post",
        resource_uuid: post.uuid,
        metadata: %{"title" => post.title}
      })

  ## Action naming convention

  Use dotted format: `resource.verb` — e.g., "post.created", "comment.liked",
  "user.registered", "password.changed", "role.assigned".
  """

  import Ecto.Query, warn: false
  require Logger

  alias PhoenixKit.Activity.Entry
  alias PhoenixKit.PubSub.Manager, as: PubSubManager
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Role

  @pubsub_topic "phoenix_kit:activity"

  @doc """
  Logs an activity.

  ## Required fields

  - `:action` — dotted action string (e.g., "post.created")

  ## Optional fields

  - `:actor_uuid` — who performed the action
  - `:resource_type` — type of resource acted on
  - `:resource_uuid` — UUID of the resource
  - `:target_uuid` — who was affected (e.g., follow target)
  - `:metadata` — map of additional context
  - `:permanent` — never pruned (default false). For an entry that is a
    record, not news: a settings change is one (`PhoenixKit.Settings.History`),
    and any module may keep an entry the same way.

  Returns `{:ok, entry}` or `{:error, changeset}`. Failures are logged but never crash.
  """
  def log(attrs) when is_map(attrs) do
    case attrs |> entry_changeset() |> repo().insert() do
      {:ok, entry} ->
        broadcast_activity(entry)
        # An attempt that did not land (`log_failed/3`) is an audit row, not
        # news: nobody is told about an action that did not happen.
        unless attempt?(entry), do: maybe_notify(entry)
        {:ok, entry}

      {:error, changeset} ->
        Logger.warning("Failed to log activity: #{inspect(changeset.errors)}")
        {:error, changeset}
    end
  rescue
    e ->
      Logger.warning("Activity logging error: #{inspect(e)}")
      {:error, e}
  catch
    # A dead pool / checkout timeout exits rather than raises, and a throw
    # must not unwind into the caller either — on a checkout that caller is
    # the shopper's LiveView.
    kind, reason when kind in [:exit, :throw] ->
      Logger.warning("Activity logging error: #{inspect(kind)} #{inspect(reason)}")
      {:error, reason}
  end

  defp attempt?(%Entry{metadata: %{"db_pending" => true}}), do: true
  defp attempt?(_entry), do: false

  # Fan out to per-user notifications. Guarded with `Code.ensure_loaded?` so
  # the core Activity module keeps working if the Notifications module is
  # ever stripped out or not yet compiled during recompile cascades.
  #
  # The entry is already committed here, so nothing the fan-out does — a
  # raise, an exit or a throw — may turn `log/1`'s result into an error.
  defp maybe_notify(entry) do
    if Code.ensure_loaded?(PhoenixKit.Notifications) do
      PhoenixKit.Notifications.maybe_create_from_activity(entry)
    end
  rescue
    e -> Logger.warning("Notifications fan-out failed: #{inspect(e)}")
  catch
    kind, reason ->
      Logger.warning("Notifications fan-out failed: #{inspect(kind)} #{inspect(reason)}")
  end

  @typedoc "What `log/3` and `log_failed/3` take besides the module and the action."
  @type log_opt ::
          {:actor_uuid, String.t() | nil}
          | {:mode, String.t()}
          | {:resource_type, String.t()}
          | {:resource_uuid, String.t()}
          | {:target_uuid, String.t()}
          | {:metadata, map()}
          | {:permanent, boolean()}

  @doc """
  Logs an activity on behalf of a module — the call every module used to
  wrap in its own `Activity` helper. `module` is the module key
  (`"catalogue"`, `"crm"`, …), stored on the entry.

  Options: `:actor_uuid`, `:mode` (default `"manual"`), `:resource_type`,
  `:resource_uuid`, `:target_uuid`, `:metadata` (a map, or a keyword or
  pair list; keep it PII-free) and `:permanent` (only `true` keeps the
  entry from being pruned). Same result and same never-crash guarantee as `log/1`:
  a blank module key or a non-list `opts` is `{:error, :invalid_arguments}`,
  logged, not a raise.

      PhoenixKit.Activity.log("crm", "crm.company_updated",
        actor_uuid: PhoenixKitWeb.Actor.uuid(socket),
        resource_type: "company",
        resource_uuid: company.uuid
      )
  """
  @spec log(String.t(), String.t(), [log_opt()]) :: {:ok, Entry.t()} | {:error, term()}
  def log(module, action, opts \\ [])

  def log(module, action, opts)
      when is_binary(module) and module != "" and is_binary(action) and is_list(opts) do
    # Whitespace is blank, and a keyword list that is improper (or holds
    # something that is not a pair) raises inside `Keyword.get/3` — both
    # are the caller's mistake, answered rather than raised.
    if String.trim(module) == "" or not Keyword.keyword?(opts) do
      invalid_arguments(module, action)
    else
      log_opts(module, action, opts)
    end
  end

  def log(module, action, _opts), do: invalid_arguments(module, action)

  defp log_opts(module, action, opts) do
    %{
      action: action,
      module: module,
      mode: Keyword.get(opts, :mode, "manual"),
      actor_uuid: Keyword.get(opts, :actor_uuid),
      resource_type: Keyword.get(opts, :resource_type),
      resource_uuid: Keyword.get(opts, :resource_uuid),
      target_uuid: Keyword.get(opts, :target_uuid),
      metadata: metadata_opt(opts),
      permanent: Keyword.get(opts, :permanent) == true
    }
    |> log()
  end

  @doc """
  Logs a user action that did not land — a mutation that returned an
  error. Same as `log/3` with `"db_pending" => true` in the metadata, so
  the feed still shows what was attempted and readers can tell it apart
  from what happened. It notifies nobody, `target_uuid` or not.
  """
  @spec log_failed(String.t(), String.t(), [log_opt()]) ::
          {:ok, Entry.t()} | {:error, term()}
  def log_failed(module, action, opts \\ [])

  def log_failed(module, action, opts)
      when is_binary(module) and module != "" and is_binary(action) and is_list(opts) do
    if Keyword.keyword?(opts) do
      log(
        module,
        action,
        Keyword.put(opts, :metadata, Map.put(metadata_opt(opts), "db_pending", true))
      )
    else
      invalid_arguments(module, action)
    end
  end

  def log_failed(module, action, _opts), do: invalid_arguments(module, action)

  # The options are left out of the log line: their metadata is the
  # caller's and may not be fit for a log.
  defp invalid_arguments(module, action) do
    Logger.warning(
      "Activity not logged: a module key and an action are required, got #{inspect(module)} and #{inspect(action)}"
    )

    {:error, :invalid_arguments}
  end

  # A keyword or pair list is taken as the map it spells — it is the
  # natural thing to write beside a keyword list of options.
  defp metadata_opt(opts) do
    case Keyword.get(opts, :metadata) do
      %{} = metadata -> metadata
      [_ | _] = pairs -> pairs_to_map(pairs)
      _ -> %{}
    end
  end

  # An improper list, or one holding something that is not a pair, is not
  # metadata — and must not raise out of a call that never raises.
  defp pairs_to_map(pairs) do
    Map.new(pairs)
  rescue
    _ -> %{}
  end

  @doc """
  Logs a user change with automatic from/to diff extraction from a changeset.

  Extracts changed fields from the changeset and builds `field_from` / `field_to`
  metadata pairs. Skips logging if nothing actually changed.

  ## Options

  - `:actor_uuid` — who performed the action (default: the user's own UUID)
  - `:target_uuid` — who was affected (default: nil)
  - `:mode` — "auto" or "manual" (default: "auto")
  - `:actor_role` — "user" or "admin" (default: "user")
  - `:extra_metadata` — additional metadata to merge in (default: %{})
  - `:skip_fields` — fields to exclude from diff (default: [:custom_fields])
  """
  def log_user_change(
        action,
        %{uuid: user_uuid} = user,
        %Ecto.Changeset{} = changeset,
        opts \\ []
      ) do
    skip_fields = Keyword.get(opts, :skip_fields, [:custom_fields])

    changed_fields =
      changeset.changes
      |> Map.drop(skip_fields)
      |> Enum.flat_map(fn {k, new_val} ->
        old_val = Map.get(user, k)
        [{"#{k}_from", to_string(old_val || "")}, {"#{k}_to", to_string(new_val)}]
      end)
      |> Map.new()

    if changed_fields == %{} do
      :noop
    else
      actor_uuid = Keyword.get(opts, :actor_uuid, user_uuid)
      target_uuid = Keyword.get(opts, :target_uuid)
      mode = Keyword.get(opts, :mode, "manual")
      actor_role = Keyword.get(opts, :actor_role, "user")
      extra = Keyword.get(opts, :extra_metadata, %{})

      metadata =
        changed_fields
        |> Map.put("actor_role", actor_role)
        |> Map.merge(extra)

      log(%{
        action: action,
        module: "users",
        mode: mode,
        actor_uuid: actor_uuid,
        resource_type: "user",
        resource_uuid: user_uuid,
        target_uuid: target_uuid,
        metadata: metadata
      })
    end
  end

  @doc """
  Lists activities with filtering and pagination.

  ## Options

  - `:action` — filter by action string (exact match or prefix with "post.*")
  - `:actor_uuid` — filter by who performed the action
  - `:resource_type` — filter by resource type
  - `:resource_uuid` — filter by the specific resource's UUID (scope to one resource)
  - `:target_uuid` — filter by who was affected
  - `:since` — filter activities after this datetime
  - `:until` — filter activities before this datetime
  - `:page` — page number (default: 1)
  - `:per_page` — items per page (default: 50)
  - `:preload` — associations to preload (default: [:actor])
  - `:query` — an Ecto queryable to filter and paginate (default: `Entry`)
  """
  def list(opts \\ []) do
    page = Keyword.get(opts, :page, 1)
    per_page = Keyword.get(opts, :per_page, 50)
    preloads = Keyword.get(opts, :preload, [:actor])

    query =
      Keyword.get(opts, :query, Entry)
      |> order_by([e], desc: e.inserted_at, desc: e.uuid)
      |> apply_filters(opts)

    total = repo().aggregate(query, :count)

    entries =
      query
      |> limit(^per_page)
      |> offset(^((page - 1) * per_page))
      |> repo().all()
      |> repo().preload(preloads)

    %{
      entries: entries,
      total: total,
      page: page,
      per_page: per_page,
      total_pages: Pagination.total_pages(total, per_page)
    }
  end

  @doc "Gets a single activity entry by UUID with preloaded associations."
  def get_entry(uuid) do
    case repo().get(Entry, uuid) do
      nil -> nil
      entry -> repo().preload(entry, [:actor, :target])
    end
  end

  @doc "Gets a single activity entry by UUID. Raises if not found."
  def get_entry!(uuid) do
    Entry
    |> repo().get!(uuid)
    |> repo().preload([:actor, :target])
  end

  @doc "Lists activities for a specific user (as actor)."
  def list_for_user(user_uuid, opts \\ []) do
    opts = Keyword.put(opts, :actor_uuid, user_uuid)
    list(opts)
  end

  @doc "Returns the N most recent activities."
  def recent(limit \\ 20) do
    Entry
    |> order_by([e], desc: e.inserted_at, desc: e.uuid)
    |> limit(^limit)
    |> preload([:actor])
    |> repo().all()
  end

  @doc "Counts activities matching the given filters."
  def count(opts \\ []) do
    Entry
    |> apply_filters(opts)
    |> repo().aggregate(:count)
  rescue
    _ -> 0
  end

  @doc """
  Resolves resource info for entries where `resource_type` is "user".

  Returns a map of `resource_uuid => %{email: ..., first_name: ..., last_name: ...}`.
  Batch-queries to avoid N+1.
  """
  def resolve_resource_users(entries) do
    user_uuids =
      entries
      |> Enum.filter(&(&1.resource_type == "user" && &1.resource_uuid))
      |> Enum.map(& &1.resource_uuid)
      |> Enum.uniq()

    if user_uuids == [] do
      %{}
    else
      from(u in PhoenixKit.Users.Auth.User,
        where: u.uuid in ^user_uuids,
        select: {u.uuid, %{email: u.email, first_name: u.first_name, last_name: u.last_name}}
      )
      |> repo().all()
      |> Map.new()
    end
  rescue
    _ -> %{}
  end

  @doc "Returns distinct modes that have been logged."
  def list_modes do
    from(e in Entry,
      distinct: true,
      select: e.mode,
      where: not is_nil(e.mode),
      order_by: e.mode
    )
    |> repo().all()
  rescue
    _ -> []
  end

  @doc "Returns distinct modules that have been logged."
  def list_modules do
    from(e in Entry,
      distinct: true,
      select: e.module,
      where: not is_nil(e.module),
      order_by: e.module
    )
    |> repo().all()
  rescue
    _ -> []
  end

  @doc "Returns distinct action types that have been logged."
  def list_action_types do
    from(e in Entry, distinct: true, select: e.action, order_by: e.action)
    |> repo().all()
  rescue
    _ -> []
  end

  @doc "Returns distinct resource types that have been logged."
  def list_resource_types do
    from(e in Entry,
      distinct: true,
      select: e.resource_type,
      where: not is_nil(e.resource_type),
      order_by: e.resource_type
    )
    |> repo().all()
  rescue
    _ -> []
  end

  @doc """
  Deletes activities older than the given number of days — except permanent
  ones (`permanent: true` at `log/1`), which are kept whatever their age.
  """
  def prune(days) when is_integer(days) and days > 0 do
    cutoff = DateTime.add(DateTime.utc_now(), -days * 86_400, :second)

    {count, _} =
      from(e in Entry, where: e.inserted_at < ^cutoff and not e.permanent)
      |> repo().delete_all()

    Logger.info("Pruned #{count} activities older than #{days} days")
    {:ok, count}
  end

  @doc "Returns the configured retention period in days."
  def retention_days do
    case Settings.get_setting("activity_retention_days", "90") do
      val when is_binary(val) ->
        case Integer.parse(val) do
          {n, _} when n > 0 -> n
          _ -> 90
        end

      _ ->
        90
    end
  rescue
    _ -> 90
  end

  @doc "PubSub topic for activity events."
  def pubsub_topic, do: @pubsub_topic

  @doc "Returns a CSS badge class based on the action verb."
  def action_badge_color(action) do
    cond do
      String.contains?(action, "created") ->
        "badge-success"

      String.contains?(action, "deleted") ->
        "badge-error"

      String.contains?(action, "updated") or String.contains?(action, "changed") ->
        "badge-warning"

      String.contains?(action, "liked") or String.contains?(action, "followed") ->
        "badge-info"

      true ->
        "badge-ghost"
    end
  end

  @doc """
  Whether `scope` may read the WHOLE activity log — every user's actions —
  rather than only its own.

  Administrators qualify: the Admin or Owner role, or any `"*"` superadmin
  role. Everyone else (a custom role that merely holds `dashboard`) is scoped
  to their own actions. The activity LiveViews share this as the single gate
  for both the list and the single-entry page.
  """
  @spec full_log_access?(Scope.t() | nil) :: boolean()
  def full_log_access?(scope) do
    Scope.superadmin?(scope) or Scope.owner?(scope) or
      Scope.has_role?(scope, Role.system_roles().admin)
  end

  @doc """
  Whether `entry` is `scope`'s OWN activity.

  "Own" is defined by AUTHORSHIP: the scope's user is the entry's `actor_uuid`
  (the account that performed the action). A record where the user is only the
  `target_uuid` — someone else acted on or for them — is NOT their own and stays
  hidden from a non-administrator.

  This is the single definition the audit log enforces in two places, and they
  must not drift: the list pins `actor_uuid` to the user (`Activity.Index`) and
  the single-entry page gates on this predicate (`Activity.Show`). If "own" ever
  needs to include target-side records, change it HERE and switch the list's
  filter in lock-step — do not fork the rule per view.
  """
  @spec own_entry?(Scope.t() | nil, Entry.t()) :: boolean()
  def own_entry?(%Scope{user: %{uuid: uuid}}, %Entry{actor_uuid: actor_uuid})
      when is_binary(uuid) and is_binary(actor_uuid),
      do: actor_uuid == uuid

  def own_entry?(_scope, _entry), do: false

  @doc "Returns a CSS badge class based on the mode."
  def mode_badge_color("manual"), do: "badge-warning"
  def mode_badge_color("auto"), do: "badge-info"
  def mode_badge_color("cron"), do: "badge-secondary"
  def mode_badge_color("script"), do: "badge-accent"
  def mode_badge_color(_), do: "badge-ghost"

  @doc """
  The reserved metadata key a module records a field diff under.

  `%{"changes" => %{"sku" => %{"from" => "T-21", "to" => "T-22"}}}`. Reserved
  so identity and change can never collide: before this existed, a module that
  merged a diff into the metadata's own keys overwrote the very value the
  entry was named by, and anything calling `to_string/1` on it raised.
  """
  def changes_key, do: "changes"

  @doc """
  Splits an entry's metadata into `{changes, everything_else}`.

  The Activity detail page leads with the changes and keeps the rest as
  context. A module that records no diff yields an empty changes map, and the
  page then shows no "What changed" section at all rather than an empty one.
  """
  @spec split_changes(map() | nil) :: {map(), map()}
  def split_changes(metadata) when is_map(metadata) and not is_struct(metadata) do
    # Only LIFT the reserved key when it holds a diff. A row whose "changes"
    # is a plain string — a host's own note, or a module that used the word
    # first — keeps it as ordinary metadata instead of having it deleted on
    # the way past (codex and zai, 2026-09-20).
    {changes, rest} =
      case Map.get(metadata, changes_key()) do
        %{} = map when map_size(map) > 0 -> {map, Map.delete(metadata, changes_key())}
        %{} -> {%{}, Map.delete(metadata, changes_key())}
        _ -> {%{}, metadata}
      end

    {legacy, rest} = legacy_changes(rest)
    {Map.merge(legacy, changes), rest}
  end

  def split_changes(_metadata), do: {%{}, %{}}

  # `log_user_change/4` and older module writers record a diff as two FLAT
  # keys — `email_from` / `email_to` — rather than the reserved map. Folding
  # those into the same shape means the "What changed" section works on rows
  # already in the table, which is most of them, instead of only on whatever
  # is written from now on. A `_from` with no matching `_to` (or the reverse)
  # is left in the metadata untouched: it is not a pair, and guessing the
  # missing side would invent history.
  defp legacy_changes(metadata) do
    Enum.reduce(metadata, {%{}, metadata}, fn
      {key, from}, {changes, rest} ->
        with true <- is_binary(key),
             true <- String.ends_with?(key, "_from"),
             field <- String.replace_suffix(key, "_from", ""),
             true <- field != "",
             to_key <- field <> "_to",
             true <- Map.has_key?(metadata, to_key) do
          {
            Map.put(changes, field, %{"from" => from, "to" => Map.get(metadata, to_key)}),
            rest |> Map.delete(key) |> Map.delete(to_key)
          }
        else
          _ -> {changes, rest}
        end
    end)
  end

  @doc """
  One side of a change, for a two-column before/after table.

  Handles the shapes a diff can take: a `from`/`to` pair, a reference whose
  label was snapshotted, and a long value recorded as changed without keeping
  either copy.
  """
  @spec change_side(term(), :from | :to) :: String.t() | :changed
  # The flag case carries no value to show. `:to` answers `:changed` rather
  # than a word, because this module has no Gettext backend — core keeps its
  # translations in the web layer — and a bare English "changed" would have
  # rendered untranslated on every locale's admin (zai, 2026-09-20). The
  # template turns the atom into a translated word.
  def change_side(%{"changed" => true}, :from), do: "…"
  def change_side(%{"changed" => true}, :to), do: :changed

  def change_side(%{} = change, side) when side in [:from, :to] do
    change |> Map.get(to_string(side)) |> humanize_metadata_value()
  end

  def change_side(value, :to), do: humanize_metadata_value(value)
  def change_side(_value, :from), do: ""

  @doc """
  A metadata key as a person reads it: `"base_price"` → `"Base price"`.
  """
  @spec humanize_metadata_key(String.t() | atom()) :: String.t()
  def humanize_metadata_key(key) do
    key
    |> to_string()
    |> String.replace("_", " ")
    |> String.trim()
    |> case do
      "" -> ""
      text -> String.capitalize(String.at(text, 0)) <> String.slice(text, 1..-1//1)
    end
  end

  @doc """
  Renders an activity-metadata VALUE as human-readable text, tolerant of the
  shapes host apps store.

  The admin feed and detail page display arbitrary per-module metadata, so this
  must never raise `Protocol.UndefinedError` (`String.Chars`/`to_string` on a
  Map): a field-change diff carries a nested `%{"from" => _, "to" => _}` map,
  which is rendered as `"1 → 2"`; any other map is rendered as
  `"key: value, ..."`. Legacy entries whose scalar was serialised via `inspect`
  (`"Decimal.new(\\"1\\")"`) are unwrapped to their inner value so old rows read
  cleanly instead of leaking Elixir syntax.
  """
  def humanize_metadata_value(%{"from" => from, "to" => to}),
    do: "#{humanize_metadata_value(from)} → #{humanize_metadata_value(to)}"

  # A REFERENCE to another record, snapshotted when the row was written:
  # `%{"uuid" => …, "label" => "Hardware"}`. Reading it back shows the label,
  # because "moved from Hardware to Frames" is the sentence — the uuid is
  # there so a reader (or a future link) can still identify the row, and so
  # the name a deleted record had survives it. Without this clause the
  # generic map branch below rendered the pair as `label: Hardware, uuid:
  # 019da…`, which is the uuid wall this exists to remove.
  def humanize_metadata_value(%{"label" => label}) when is_binary(label), do: label

  # A long value that is recorded as changed without keeping both copies.
  def humanize_metadata_value(%{"changed" => true}), do: "changed"

  def humanize_metadata_value(value) when is_map(value) and not is_struct(value) do
    Enum.map_join(value, ", ", fn {k, v} -> "#{k}: #{humanize_metadata_value(v)}" end)
  end

  def humanize_metadata_value(value) when is_list(value),
    do: Enum.map_join(value, ", ", &humanize_metadata_value/1)

  def humanize_metadata_value(value) when is_binary(value), do: unwrap_inspect_scalar(value)
  def humanize_metadata_value(nil), do: ""
  def humanize_metadata_value(value), do: to_string(value)

  # Legacy rows serialised a Decimal via inspect/1 ("Decimal.new(\"1\")"); show
  # the number instead. Anything that doesn't match is returned unchanged.
  defp unwrap_inspect_scalar(str) do
    case Regex.run(~r/^Decimal\.new\("?(-?\d+(?:\.\d+)?)"?\)$/, str) do
      [_, number] -> number
      _ -> str
    end
  end

  # Private

  defp apply_filters(query, opts) do
    query
    |> maybe_filter_module(Keyword.get(opts, :module))
    |> maybe_filter_mode(Keyword.get(opts, :mode))
    |> maybe_filter_action(Keyword.get(opts, :action))
    |> maybe_filter_actor(Keyword.get(opts, :actor_uuid))
    |> maybe_filter_resource_type(Keyword.get(opts, :resource_type))
    |> maybe_filter_resource_uuid(Keyword.get(opts, :resource_uuid))
    |> maybe_filter_target(Keyword.get(opts, :target_uuid))
    |> maybe_filter_since(Keyword.get(opts, :since))
    |> maybe_filter_until(Keyword.get(opts, :until))
  end

  defp maybe_filter_module(query, nil), do: query
  defp maybe_filter_module(query, mod), do: where(query, [e], e.module == ^mod)

  defp maybe_filter_mode(query, nil), do: query
  defp maybe_filter_mode(query, mode), do: where(query, [e], e.mode == ^mode)

  defp maybe_filter_action(query, nil), do: query

  defp maybe_filter_action(query, action) do
    if String.ends_with?(action, ".*") do
      prefix = String.trim_trailing(action, ".*") <> "."
      where(query, [e], like(e.action, ^"#{prefix}%"))
    else
      where(query, [e], e.action == ^action)
    end
  end

  defp maybe_filter_actor(query, nil), do: query
  defp maybe_filter_actor(query, uuid), do: where(query, [e], e.actor_uuid == ^uuid)

  defp maybe_filter_resource_type(query, nil), do: query
  defp maybe_filter_resource_type(query, type), do: where(query, [e], e.resource_type == ^type)

  defp maybe_filter_resource_uuid(query, nil), do: query
  defp maybe_filter_resource_uuid(query, uuid), do: where(query, [e], e.resource_uuid == ^uuid)

  defp maybe_filter_target(query, nil), do: query
  defp maybe_filter_target(query, uuid), do: where(query, [e], e.target_uuid == ^uuid)

  defp maybe_filter_since(query, nil), do: query
  defp maybe_filter_since(query, dt), do: where(query, [e], e.inserted_at >= ^dt)

  defp maybe_filter_until(query, nil), do: query
  defp maybe_filter_until(query, dt), do: where(query, [e], e.inserted_at <= ^dt)

  @doc """
  The changeset `log/1` inserts, for a caller that must insert inside its
  own transaction and publish after commit (`PhoenixKit.Settings.History`).
  `permanent` is taken ONLY as the atom key with the boolean `true` — never
  cast from a params map — so forwarded user input cannot keep an entry
  forever.
  """
  @spec entry_changeset(map()) :: Ecto.Changeset.t()
  def entry_changeset(attrs) when is_map(attrs) do
    permanent? = Map.get(attrs, :permanent) == true

    %Entry{}
    |> Entry.changeset(Map.delete(attrs, :permanent))
    |> Ecto.Changeset.put_change(:permanent, permanent?)
  end

  @doc """
  Publishes an already-inserted entry on the activity topic — for a caller
  that inserted it inside a transaction and waited for the commit.
  """
  @spec broadcast(Entry.t()) :: :ok
  def broadcast(%Entry{} = entry) do
    broadcast_activity(entry)
    unless attempt?(entry), do: maybe_notify(entry)
    :ok
  end

  # Committed already — same rule as `maybe_notify/1`.
  defp broadcast_activity(entry) do
    PubSubManager.broadcast(@pubsub_topic, {:activity_logged, entry})
  rescue
    _ -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp repo do
    PhoenixKit.RepoHelper.repo()
  end
end

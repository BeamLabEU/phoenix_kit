defmodule PhoenixKit.Activity do
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
  alias PhoenixKit.Settings

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

  Returns `{:ok, entry}` or `{:error, changeset}`. Failures are logged but never crash.
  """
  def log(attrs) when is_map(attrs) do
    case %Entry{} |> Entry.changeset(attrs) |> repo().insert() do
      {:ok, entry} ->
        broadcast_activity(entry)
        {:ok, entry}

      {:error, changeset} ->
        Logger.warning("Failed to log activity: #{inspect(changeset.errors)}")
        {:error, changeset}
    end
  rescue
    e ->
      Logger.warning("Activity logging error: #{inspect(e)}")
      {:error, e}
  end

  @doc """
  Lists activities with filtering and pagination.

  ## Options

  - `:action` — filter by action string (exact match or prefix with "post.*")
  - `:actor_uuid` — filter by who performed the action
  - `:resource_type` — filter by resource type
  - `:target_uuid` — filter by who was affected
  - `:since` — filter activities after this datetime
  - `:until` — filter activities before this datetime
  - `:page` — page number (default: 1)
  - `:per_page` — items per page (default: 50)
  - `:preload` — associations to preload (default: [:actor])
  """
  def list(opts \\ []) do
    page = Keyword.get(opts, :page, 1)
    per_page = Keyword.get(opts, :per_page, 50)
    preloads = Keyword.get(opts, :preload, [:actor])

    query =
      Entry
      |> order_by([e], desc: e.inserted_at)
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
      total_pages: max(ceil(total / per_page), 1)
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
    |> order_by([e], desc: e.inserted_at)
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

  @doc "Deletes activities older than the given number of days."
  def prune(days) when is_integer(days) and days > 0 do
    cutoff = DateTime.add(DateTime.utc_now(), -days * 86_400, :second)

    {count, _} =
      from(e in Entry, where: e.inserted_at < ^cutoff)
      |> repo().delete_all()

    Logger.info("Pruned #{count} activities older than #{days} days")
    {:ok, count}
  end

  @doc "Returns the configured retention period in days."
  def retention_days do
    case Settings.get_setting("activity_retention_days", "90") do
      val when is_binary(val) ->
        case Integer.parse(val) do
          {n, _} -> n
          :error -> 90
        end

      _ ->
        90
    end
  rescue
    _ -> 90
  end

  @doc "PubSub topic for activity events."
  def pubsub_topic, do: @pubsub_topic

  # Private

  defp apply_filters(query, opts) do
    query
    |> maybe_filter_module(Keyword.get(opts, :module))
    |> maybe_filter_mode(Keyword.get(opts, :mode))
    |> maybe_filter_action(Keyword.get(opts, :action))
    |> maybe_filter_actor(Keyword.get(opts, :actor_uuid))
    |> maybe_filter_resource_type(Keyword.get(opts, :resource_type))
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

  defp maybe_filter_target(query, nil), do: query
  defp maybe_filter_target(query, uuid), do: where(query, [e], e.target_uuid == ^uuid)

  defp maybe_filter_since(query, nil), do: query
  defp maybe_filter_since(query, dt), do: where(query, [e], e.inserted_at >= ^dt)

  defp maybe_filter_until(query, nil), do: query
  defp maybe_filter_until(query, dt), do: where(query, [e], e.inserted_at <= ^dt)

  defp broadcast_activity(entry) do
    PhoenixKit.PubSub.Manager.broadcast(@pubsub_topic, {:activity_logged, entry})
  rescue
    _ -> :ok
  end

  defp repo do
    PhoenixKit.RepoHelper.repo()
  end
end

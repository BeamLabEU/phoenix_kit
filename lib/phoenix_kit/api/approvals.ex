defmodule PhoenixKit.API.Approvals do
  @moduledoc """
  The approval queue of API write operations (the approval path of the confirmation flow):
  every write call of a key marked "requires approval", dangerous or not, waits here for a
  person. A read or a `dry_run` of such a key is never held.

  ## Life of an approval

      pending -> approved -> executing -> executed | failed
      pending -> rejected | stale | expired

  `request/2` creates the `pending` row (the danger gate calls it with the preview the
  handler produced in dry-run mode). An agent follows its approval with
  `system.get_approval` (`get_for_key/2` and `status_view/1`).

  ## Rules

    * An identical pending request (same key, tool, arguments) returns the existing
      approval.
    * A key holds at most `api_approval_pending_max` pending approvals; one more is
      `{:error, :pending_cap}`. Both rules run under a per-key advisory lock.
    * `input` is the arguments the approval will run with; at most 1 MB; cleared when
      the approval is decided or expires.
    * Who may decide: an Owner, or a person who holds `api`, created the key and holds
      the tool's `permission` (`may_decide?/2`).
    * An approved operation is run once: only an `approved` row starts, and it moves to
      `executing` first. If it runs for more than 15 minutes without calling `ctx.progress`,
      the stuck-operation sweep marks it `failed` (`interrupted`) although the process is
      still working; when the handler then succeeds, the row is corrected to `executed`
      (with a `note`). Until then, and if the process really died, the row stays `failed`
      and part of the operation may have been applied: an agent must check the data and
      not queue the operation again before it has.

  Changes are announced on the PubSub topic `"phoenix_kit:api:approvals"` as
  `{:api_approval_changed, approval_uuid}`, which the approvals page listens to.
  """

  import Ecto.Query, warn: false

  require Logger

  alias PhoenixKit.Activity
  alias PhoenixKit.API.Actor
  alias PhoenixKit.API.Approvals.Notifier
  alias PhoenixKit.API.Config
  alias PhoenixKit.API.Confirm
  alias PhoenixKit.API.Confirm.Confirmation
  alias PhoenixKit.API.Executor
  alias PhoenixKit.API.FlowConfig
  alias PhoenixKit.API.Idempotency
  alias PhoenixKit.API.Keys
  alias PhoenixKit.API.Keys.Key
  alias PhoenixKit.API.LogSafe
  alias PhoenixKit.API.Registry
  alias PhoenixKit.API.Tool
  alias PhoenixKit.PubSub.Manager, as: PubSub
  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Role
  alias PhoenixKit.Users.Roles

  @topic "phoenix_kit:api:approvals"

  # The views never show `input`, which can hold up to 1 MB per approval: leave it in the
  # database.
  @light_fields Confirmation.__schema__(:fields) -- [:input]
  @max_input_bytes 1_048_576

  @doc "The PubSub topic of approval changes."
  @spec topic() :: String.t()
  def topic, do: @topic

  # --- requesting --------------------------------------------------------------

  @doc """
  Queues an approval. `args` is `%{actor, tool, input, input_hash, preview, fingerprint,
  context}`: the key's actor, the tool name, the validated arguments without the control
  fields, their canonical hash, the preview and fingerprint of the dry run, and the
  request context (`language currency hosts base_url request_id`) the operation will
  run with.
  """
  @spec request(map(), DateTime.t()) ::
          {:ok, Confirmation.t(), :created | :existing}
          | {:error, :pending_cap | :input_too_large | Ecto.Changeset.t()}
  def request(args, now \\ DateTime.utc_now())

  def request(%{actor: %Actor{kind: :key} = actor, input: input} = args, now) do
    now = second(now)

    with :ok <- check_size(input) do
      case repo().transaction(fn -> in_lock(actor, args, now) end) do
        {:ok, {row, :created}} ->
          created(row, actor, now)
          {:ok, row, :created}

        {:ok, {row, :existing}} ->
          {:ok, row, :existing}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp check_size(input) do
    if byte_size(JSON.encode!(input)) > @max_input_bytes,
      do: {:error, :input_too_large},
      else: :ok
  end

  defp in_lock(actor, args, now) do
    repo().query!("SELECT pg_advisory_xact_lock(hashtext($1))", [
      "api_approval:" <> actor.key_uuid
    ])

    expire_key(actor.key_uuid, now)
    supersede(actor.key_uuid, args, now)

    case pending_row(actor.key_uuid, args.tool, args.input_hash, now) do
      %Confirmation{} = row ->
        {row, :existing}

      nil ->
        if pending_for_key(actor.key_uuid, now) >= FlowConfig.approval_pending_max(),
          do: repo().rollback(:pending_cap),
          else: insert_or_rollback(actor, args, now)
    end
  end

  defp expire_key(key_uuid, now) do
    repo().update_all(
      from(c in Confirmation,
        where:
          c.actor_key_uuid == ^key_uuid and c.kind == "approval" and c.status == "pending" and
            c.expires_at <= ^now
      ),
      set: [status: "expired", input: nil, updated_at: now]
    )
  end

  # A request repeated after the values it touches changed would otherwise get the old
  # pending row back, with its outdated preview: the approver decides on a stale view and
  # the approval then ends as `stale`. The old row is closed instead, so the repeat gets a
  # fresh one.
  defp supersede(key_uuid, args, now) do
    repo().update_all(
      from(c in Confirmation,
        where:
          c.actor_key_uuid == ^key_uuid and c.kind == "approval" and c.status == "pending" and
            c.tool == ^args.tool and c.input_hash == ^args.input_hash and
            c.fingerprint != ^args.fingerprint
      ),
      set: [status: "expired", input: nil, updated_at: now]
    )
  end

  # `c.expires_at > ^now` is equivalent to the status test while `expire_key/2` runs first
  # under the same lock and `now`; it stays as a second line of defence.
  defp pending_row(key_uuid, tool, input_hash, now) do
    repo().one(
      from(c in Confirmation,
        where:
          c.actor_key_uuid == ^key_uuid and c.kind == "approval" and c.status == "pending" and
            c.tool == ^tool and
            c.input_hash == ^input_hash and c.expires_at > ^now,
        limit: 1
      )
    )
  end

  defp pending_for_key(key_uuid, now) do
    repo().aggregate(
      from(c in Confirmation,
        where:
          c.actor_key_uuid == ^key_uuid and c.kind == "approval" and c.status == "pending" and
            c.expires_at > ^now
      ),
      :count
    )
  end

  defp insert_or_rollback(actor, args, now) do
    case insert(actor, args, now) do
      {:ok, row} -> {row, :created}
      {:error, changeset} -> repo().rollback(changeset)
    end
  end

  defp insert(actor, args, now) do
    ttl = FlowConfig.approval_ttl_hours() * 3600

    %Confirmation{}
    |> Confirmation.changeset(%{
      kind: "approval",
      tool: args.tool,
      input_hash: args.input_hash,
      fingerprint: args.fingerprint,
      input: args.input,
      context: args.context,
      actor_key_uuid: actor.key_uuid,
      preview: args.preview,
      status: "pending",
      expires_at: DateTime.add(now, ttl, :second)
    })
    |> repo().insert()
  end

  defp created(%Confirmation{} = row, %Actor{} = actor, %DateTime{} = now) do
    Activity.log("api", "api.approval_requested",
      actor_uuid: actor.user_uuid,
      mode: "auto",
      resource_type: "api_approval",
      resource_uuid: row.uuid,
      permanent: true,
      metadata: %{
        "via" => "api",
        "tool" => row.tool,
        "key_prefix" => actor.key_prefix,
        "approval_id" => row.uuid
      }
    )

    broadcast(row.uuid)
    Notifier.notify_requested(row, now)
    :ok
  end

  @doc false
  @spec broadcast(String.t() | :expired) :: :ok
  def broadcast(approval_uuid) do
    PubSub.broadcast(@topic, {:api_approval_changed, approval_uuid})
    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  # --- what an agent may read ---------------------------------------------------

  @doc """
  The approval `approval_id` if it belongs to the key `key_uuid`, else `nil` (an unknown
  id, a malformed id, another key's approval and a confirmation code all read the same).
  A pending approval past its time reads as `expired`.
  """
  @spec get_for_key(term(), term()) :: Confirmation.t() | nil
  def get_for_key(approval_id, key_uuid) when is_binary(approval_id) and is_binary(key_uuid) do
    with {:ok, uuid} <- Ecto.UUID.cast(approval_id),
         %Confirmation{kind: "approval", actor_key_uuid: ^key_uuid} = row <-
           repo().get(Confirmation, uuid) do
      effective(row)
    else
      _ -> nil
    end
  end

  def get_for_key(_approval_id, _key_uuid), do: nil

  defp effective(%Confirmation{status: "pending", expires_at: expires_at} = row) do
    if DateTime.compare(expires_at, DateTime.utc_now()) == :gt,
      do: row,
      else: %{row | status: "expired"}
  end

  defp effective(row), do: row

  @doc """
  The JSON-able view `system.get_approval` answers: id, status, tool, preview, times,
  and by status the result, or the error and the partial results. Never the input.
  """
  @spec status_view(Confirmation.t()) :: map()
  def status_view(%Confirmation{} = row) do
    %{
      "approval_id" => row.uuid,
      "status" => row.status,
      "tool" => row.tool,
      "preview" => row.preview,
      "requested_at" => iso(row.inserted_at),
      "expires_at" => iso(row.expires_at)
    }
    |> put_if(
      row.status == "pending",
      "expires_in_seconds",
      max(DateTime.diff(row.expires_at, DateTime.utc_now()), 0)
    )
    |> put_if(row.decided_at != nil, "decided_at", iso(row.decided_at))
    |> outcome(row)
  end

  defp outcome(view, %Confirmation{status: "executed", result: result}),
    do: Map.put(view, "result", result)

  defp outcome(view, %Confirmation{status: status, result: %{} = result})
       when status in ["failed", "stale"] do
    view
    |> Map.put("error", result["error"])
    |> put_if(Map.has_key?(result, "partial"), "partial", result["partial"])
  end

  defp outcome(view, _row), do: view

  defp put_if(map, true, key, value), do: Map.put(map, key, value)
  defp put_if(map, false, _key, _value), do: map

  defp iso(nil), do: nil
  defp iso(%DateTime{} = at), do: DateTime.to_iso8601(at)

  # --- who may decide -----------------------------------------------------------

  @doc """
  Whether the person behind `scope` may approve or reject `approval`: an Owner, or a
  holder of `api` who created the key and holds the tool's `permission`.
  """
  @spec may_decide?(Scope.t(), Confirmation.t()) :: boolean()
  def may_decide?(
        %Scope{} = scope,
        %Confirmation{kind: "approval", actor_key_uuid: key_uuid} = approval
      ) do
    case Keys.get_key(key_uuid) do
      %Key{} = key -> decider?(scope, approval, key)
      nil -> false
    end
  end

  def may_decide?(_scope, _approval), do: false

  defp decider?(scope, approval, key, permits? \\ nil) do
    permits? = permits? || (&tool_permission?(scope, &1))

    cond do
      not Scope.can?(scope, "api") ->
        false

      Scope.owner?(scope) ->
        true

      key.created_by_uuid != nil and key.created_by_uuid == Scope.user_uuid(scope) ->
        permits?.(approval.tool)

      true ->
        false
    end
  end

  defp tool_permission?(scope, tool_name) do
    case Registry.find(tool_name, :admin) do
      {:ok, %Tool{permission: permission}} when is_binary(permission) ->
        Scope.can?(scope, permission)

      _ ->
        false
    end
  end

  @doc "The active people who may decide `approval`: the Owners and the key's creator, if they qualify."
  @spec deciders(Confirmation.t()) :: [PhoenixKit.Users.Auth.User.t()]
  def deciders(%Confirmation{actor_key_uuid: key_uuid} = approval),
    do: deciders(approval, Keys.get_key(key_uuid))

  @doc false
  @spec deciders(Confirmation.t(), Key.t() | nil) :: [PhoenixKit.Users.Auth.User.t()]
  def deciders(%Confirmation{kind: "approval"} = approval, %Key{} = key) do
    owners = Roles.users_with_role(Role.system_roles().owner)

    creator =
      case key.created_by_uuid do
        id when is_binary(id) -> [Auth.get_user(id)]
        _ -> []
      end

    (owners ++ creator)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(& &1.uuid)
    |> Enum.filter(fn user ->
      user.is_active and decider?(Scope.for_user(user, narrow: false), approval, key)
    end)
  end

  def deciders(_approval, _key), do: []

  # --- the views of the page -------------------------------------------------------

  @doc "The pending approvals `scope` may decide, oldest first, with their keys."
  @spec list_pending(Scope.t(), DateTime.t()) :: [%{approval: Confirmation.t(), key: Key.t()}]
  def list_pending(%Scope{} = scope, now \\ DateTime.utc_now()) do
    now = second(now)

    from(c in Confirmation,
      join: k in Key,
      on: k.uuid == c.actor_key_uuid,
      where: c.kind == "approval" and c.status == "pending" and c.expires_at > ^now,
      order_by: [asc: c.inserted_at],
      select: {struct(c, ^@light_fields), k}
    )
    |> visible_to(scope)
    |> repo().all()
    |> decidable(scope)
  end

  @doc "The latest decided approvals `scope` may see, newest change first."
  @spec list_recent(Scope.t(), pos_integer()) :: [%{approval: Confirmation.t(), key: Key.t()}]
  def list_recent(%Scope{} = scope, limit) when is_integer(limit) and limit > 0 do
    from(c in Confirmation,
      join: k in Key,
      on: k.uuid == c.actor_key_uuid,
      where: c.kind == "approval" and c.status != "pending",
      order_by: [desc: c.updated_at, desc: c.uuid],
      limit: ^(limit * 5),
      select: {struct(c, ^@light_fields), k}
    )
    |> visible_to(scope)
    |> repo().all()
    |> decidable(scope)
    |> Enum.take(limit)
  end

  @doc """
  How many pending approvals `scope` may decide: what `list_pending/2` would list, counted
  without reading the rows (the menu draws it on every render). An Owner's is one count;
  anyone else's is a count per tool of the approvals of their keys, kept for the tools they
  hold the permission of.
  """
  @spec pending_count(Scope.t()) :: non_neg_integer()
  def pending_count(%Scope{} = scope) do
    now = second(DateTime.utc_now())

    pending =
      from(c in Confirmation,
        join: k in Key,
        on: k.uuid == c.actor_key_uuid,
        where: c.kind == "approval" and c.status == "pending" and c.expires_at > ^now
      )

    if Scope.can?(scope, "api") and Scope.owner?(scope) do
      repo().aggregate(pending, :count)
    else
      pending
      |> visible_to(scope)
      |> group_by([c], c.tool)
      |> select([c], {c.tool, count(c.uuid)})
      |> repo().all()
      |> Enum.filter(fn {tool, _count} -> tool_permission?(scope, tool) end)
      |> Enum.map(fn {_tool, count} -> count end)
      |> Enum.sum()
    end
  end

  @doc """
  Whether the site uses approvals at all: a key that still works (`Keys.dead_reason/1` is
  `nil`: a revocation or expiry in the future has not been reached) is marked "requires
  approval", or an approval of any status is still kept (a pending one outlives the flag
  being switched off, and the decided ones are the page's history). The admin menu offers
  the Approvals entry only then; the page itself answers either way.
  """
  @spec in_use?() :: boolean()
  def in_use? do
    now = second(DateTime.utc_now())

    keys =
      from(k in Key,
        where:
          k.requires_approval and (is_nil(k.revoked_at) or k.revoked_at > ^now) and
            (is_nil(k.expires_at) or k.expires_at > ^now)
      )

    repo().exists?(keys) or repo().exists?(from(c in Confirmation, where: c.kind == "approval"))
  end

  # The part of `decider?/3` that the database can answer: nothing without `api`, every key
  # for an Owner, the keys one created for anyone else. Done in SQL so the other keys'
  # approvals neither get loaded nor crowd the person's own out of the `limit`. What is
  # left for `decidable/2` is the tool's permission, which only the registry knows; the
  # `limit * 5` of `list_recent/2` only has to cover the person's own approvals of tools
  # they no longer hold the permission of.
  defp visible_to(query, %Scope{} = scope) do
    user_uuid = Scope.user_uuid(scope)

    cond do
      not Scope.can?(scope, "api") -> where(query, [c, k], false)
      Scope.owner?(scope) -> query
      is_binary(user_uuid) -> where(query, [c, k], k.created_by_uuid == ^user_uuid)
      true -> where(query, [c, k], false)
    end
  end

  # The registry is asked once per tool name, not once per row, and not at all for an Owner.
  defp decidable(rows, scope) do
    permits =
      if Scope.owner?(scope) do
        %{}
      else
        for tool <- rows |> Enum.map(fn {approval, _key} -> approval.tool end) |> Enum.uniq(),
            into: %{},
            do: {tool, tool_permission?(scope, tool)}
      end

    permits? = &Map.get(permits, &1, false)

    for {approval, key} <- rows,
        decider?(scope, approval, key, permits?),
        do: %{approval: approval, key: key}
  end

  # --- deciding ---------------------------------------------------------------------------

  @doc """
  Approves `approval_id` and runs it now, in the calling process: the decision, the checks
  of the request path repeated against the key as it stands, the values fingerprint, then
  the operation. On `{:ok, row}` the row is final: `executed`, `failed` or `stale`.
  """
  @spec approve(term(), Scope.t(), DateTime.t()) ::
          {:ok, Confirmation.t()} | {:error, :not_found | :forbidden | :not_pending | :expired}
  def approve(approval_id, %Scope{} = scope, now \\ DateTime.utc_now()) do
    now = second(now)

    with {:ok, row} <- fetch(approval_id),
         :ok <- authorize(scope, row),
         {:ok, row} <- decide(row, "approved", scope, now) do
      log_decision(row, "approved", scope)
      broadcast(row.uuid)
      {:ok, execute(row, scope)}
    end
  end

  @doc "Rejects `approval_id`: nothing runs and its input is discarded."
  @spec reject(term(), Scope.t(), DateTime.t()) ::
          {:ok, Confirmation.t()} | {:error, :not_found | :forbidden | :not_pending | :expired}
  def reject(approval_id, %Scope{} = scope, now \\ DateTime.utc_now()) do
    now = second(now)

    with {:ok, row} <- fetch(approval_id),
         :ok <- authorize(scope, row),
         {:ok, row} <- decide(row, "rejected", scope, now) do
      log_decision(row, "rejected", scope)
      broadcast(row.uuid)
      {:ok, row}
    end
  end

  defp fetch(approval_id) when is_binary(approval_id) do
    with {:ok, uuid} <- Ecto.UUID.cast(approval_id),
         %Confirmation{kind: "approval"} = row <- repo().get(Confirmation, uuid) do
      {:ok, row}
    else
      _ -> {:error, :not_found}
    end
  end

  defp fetch(_approval_id), do: {:error, :not_found}

  defp authorize(scope, row), do: if(may_decide?(scope, row), do: :ok, else: {:error, :forbidden})

  # One compare-and-set: of any number of simultaneous decisions exactly one updates the row.
  defp decide(%Confirmation{} = row, new_status, %Scope{} = scope, now) do
    changes =
      [
        status: new_status,
        decided_by_uuid: Scope.user_uuid(scope),
        decided_at: now,
        updated_at: now
      ] ++
        if(new_status == "rejected", do: [input: nil], else: [])

    query =
      from(c in Confirmation,
        where:
          c.uuid == ^row.uuid and c.kind == "approval" and c.status == "pending" and
            c.expires_at > ^now
      )

    case repo().update_all(query, set: changes) do
      {1, _} -> {:ok, repo().get!(Confirmation, row.uuid)}
      {0, _} -> {:error, why_not_decided(row.uuid, now)}
    end
  end

  defp why_not_decided(uuid, now) do
    case repo().get(Confirmation, uuid) do
      %Confirmation{status: "pending", expires_at: expires_at} ->
        if DateTime.compare(expires_at, now) == :gt do
          :not_pending
        else
          repo().update_all(
            from(c in Confirmation, where: c.uuid == ^uuid and c.status == "pending"),
            set: [status: "expired", input: nil, updated_at: now]
          )

          broadcast(uuid)
          :expired
        end

      _decided_or_gone ->
        :not_pending
    end
  end

  # --- executing --------------------------------------------------------------------------

  defp execute(%Confirmation{} = row, %Scope{} = approver) do
    approver_uuid = Scope.user_uuid(approver)

    outcome =
      with :ok <- admin_api_on(),
           {:ok, actor} <- live_actor(row),
           {:ok, tool} <- find_tool(row, actor),
           {:ok, input} <- revalidate(tool, row),
           :ok <- same_values(tool, row, input, actor, approver_uuid),
           :ok <- start(row) do
        run(tool, row, input, actor, approver_uuid)
      end

    case outcome do
      {:executed, result} -> finish(row, "executed", result)
      {:stale, error} -> finish(row, "stale", %{"error" => error})
      {:failed, error} -> finish(row, "failed", %{"error" => error})
    end
  end

  # The `api_admin_enabled` switch is the operator's way to stop the admin API at once; an
  # approval waiting for a decision must not run once it is off.
  defp admin_api_on do
    if Config.admin_enabled?(),
      do: :ok,
      else: {:failed, error(:not_found, "The admin API is switched off. Nothing was run.")}
  end

  # A connection that no Owner has approved runs nothing, an approved operation included: its
  # row can only come from before the approval was a rule (a code-only rollback and forward).
  defp live_actor(row) do
    case Confirm.live_actor(row.actor_key_uuid) do
      {:ok, %{awaiting_approval: true}} ->
        {:failed,
         error(:unauthorized, "The connection is waiting for approval. Nothing was run.")}

      {:ok, actor} ->
        {:ok, actor}

      {:error, reason} ->
        {:failed, error(:unauthorized, "The API key is no longer valid (#{reason}).")}
    end
  end

  # The executor's own steps (tool exists, module enabled, scope held), not a copy of them.
  defp find_tool(row, actor) do
    case Executor.authorize_tool(row.tool, :admin, actor.scopes) do
      {:ok, %Tool{} = tool} -> {:ok, tool}
      {:error, code, detail, context} -> {:failed, error(code, detail, context)}
    end
  end

  # The executor's own validation (`max_items`, then the closed schema), not a copy of it.
  defp revalidate(%Tool{} = tool, %Confirmation{input: input}) when is_map(input) do
    case Executor.validate_input(tool, input) do
      {:ok, valid} ->
        {:ok, valid}

      {:error, errors} ->
        {:failed,
         error(:validation_failed, "The stored input no longer matches the tool's schema.", %{
           "errors" => errors
         })}
    end
  end

  defp revalidate(_tool, _row),
    do: {:failed, error(:validation_failed, "The approval holds no input to run.")}

  # The handler as a dry run: it must still see the values the person saw.
  defp same_values(tool, %Confirmation{fingerprint: expected} = row, input, actor, approver_uuid) do
    case call(tool, input, ctx(row, actor, approver_uuid, true)) do
      {:preview, _preview, ^expected} ->
        :ok

      {:preview, _preview, _other} ->
        {:stale,
         error(
           :stale,
           "The values this operation touches changed since it was requested. Nothing was written."
         )}

      {:error, code, message, context}
      when is_atom(code) and is_binary(message) and is_map(context) ->
        {:failed, error(code, message, context)}

      {:crashed, _what} ->
        {:failed, error(:internal_error, "The tool failed unexpectedly.")}

      other ->
        Logger.error(
          "[PhoenixKit.API] #{tool.name} answered a dry run with #{LogSafe.shape(other)}"
        )

        {:failed, error(:internal_error, "The tool did not answer its dry run with a preview.")}
    end
  end

  defp start(%Confirmation{uuid: uuid}) do
    now = second(DateTime.utc_now())
    query = from(c in Confirmation, where: c.uuid == ^uuid and c.status == "approved")

    case repo().update_all(query, set: [status: "executing", updated_at: now]) do
      {1, _} ->
        :ok

      {0, _} ->
        {:failed, error(:internal_error, "The approval was changed while it was being run.")}
    end
  end

  defp run(tool, row, input, actor, approver_uuid) do
    case call(tool, input, ctx(row, actor, approver_uuid, false)) do
      {:ok, result} when is_map(result) ->
        {:executed, result}

      {:ok, result, effects} when is_map(result) and is_list(effects) ->
        {:executed, Map.put(result, "effects", effects)}

      {:error, code, message, context}
      when is_atom(code) and is_binary(message) and is_map(context) ->
        {:failed, error(code, message, context)}

      {:crashed, _what} ->
        {:failed, error(:internal_error, "The tool failed unexpectedly.")}

      other ->
        Logger.error(
          "[PhoenixKit.API] #{tool.name} answered an approval with #{LogSafe.shape(other)}"
        )

        {:failed, error(:internal_error, "The tool returned an unexpected answer.")}
    end
  end

  # The handler context of the original call, rebuilt from what the request left in the row.
  # `Executor.context_from/1` is the one definition of the context's shape, so a key the
  # executor adds later reaches approved operations too (a test compares the key sets).
  defp ctx(%Confirmation{} = row, actor, approver_uuid, dry_run?) do
    snapshot = row.context || %{}
    keys = credential_keys(row.tool)

    Executor.context_from(%{
      actor: actor,
      scopes: actor.scopes,
      audience: :admin,
      language: snapshot["language"],
      currency: snapshot["currency"],
      hosts: snapshot["hosts"] || [],
      base_url: snapshot["base_url"],
      request_id: snapshot["request_id"],
      dry_run?: dry_run?,
      approved_by_uuid: approver_uuid,
      confirmation_uuid: row.uuid,
      progress: fn partial -> record_progress(row.uuid, partial, keys) end
    })
  end

  # A handler that works through many rows reports what it has done; if the process
  # dies, the sweep keeps these results on the failed approval.
  defp record_progress(uuid, partial, keys) do
    now = second(DateTime.utc_now())

    repo().update_all(
      from(c in Confirmation, where: c.uuid == ^uuid and c.status == "executing"),
      set: [result: %{"partial" => storable_result(partial, keys)}, updated_at: now]
    )

    :ok
  rescue
    _ -> :ok
  end

  # The handler runs under a rescue: whatever it does, approve/3 returns a row.
  defp call(%Tool{handler: {module, function}} = tool, input, ctx) do
    apply(module, function, [input, ctx])
  rescue
    exception ->
      Logger.error(
        "[PhoenixKit.API] approval of #{tool.name} crashed: " <>
          Executor.exception_report(exception, __STACKTRACE__)
      )

      {:crashed, LogSafe.exception_label(exception)}
  catch
    kind, reason ->
      Logger.error(
        "[PhoenixKit.API] approval of #{tool.name} failed: #{kind}: #{LogSafe.shape(reason)}"
      )

      {:crashed, to_string(kind)}
  end

  # `finish` is reached only by the process that moved the row to `executing`. If the stuck
  # sweep failed the row meanwhile (a handler that ran past the sweep window without
  # reporting progress) and the handler then succeeds, the row is corrected to `executed`:
  # the write happened. No other outcome reopens a swept row, and a row that is not
  # `approved` or `executing` can never be run again, so this cannot run it twice.
  defp finish(%Confirmation{uuid: uuid} = row, status, result) do
    now = second(DateTime.utc_now())
    current = repo().get(Confirmation, uuid)

    result =
      result
      |> jsonable()
      |> keep_partial(status, current)
      |> Idempotency.redact_credentials(credential_keys(row.tool))

    write_final(uuid, status, result, now, status == "executed" and swept?(current))

    # The key (or its owner) can be deleted while the handler runs, which takes the row with
    # it (ON DELETE CASCADE). The operation has run all the same: answer with what was
    # written rather than raise after the write.
    final =
      repo().get(Confirmation, uuid) ||
        %{row | status: status, result: result, input: nil, updated_at: now}

    log_finished(final)
    broadcast(uuid)
    final
  end

  # The sweep can land between the read in `finish` and this write. A handler that
  # succeeded finds the row no longer `approved`/`executing`; it is then written once more
  # with the guard of a swept row, so the sweep never wins against a finished write.
  defp write_final(uuid, status, result, now, swept?) do
    set = [status: status, result: note_swept(result, swept?), input: nil, updated_at: now]

    case repo().update_all(finishable(uuid, swept?), set: set) do
      {0, _} when status == "executed" and not swept? ->
        write_final(uuid, status, result, now, true)

      _ ->
        :ok
    end
  end

  defp swept?(%Confirmation{status: "failed", result: %{"error" => %{"code" => "interrupted"}}}),
    do: true

  defp swept?(_current), do: false

  defp finishable(uuid, true) do
    from(c in Confirmation,
      where:
        c.uuid == ^uuid and c.status == "failed" and
          fragment("?->'error'->>'code' = 'interrupted'", c.result)
    )
  end

  defp finishable(uuid, false) do
    from(c in Confirmation, where: c.uuid == ^uuid and c.status in ["approved", "executing"])
  end

  defp note_swept(result, true) when is_map(result),
    do:
      Map.put(
        result,
        "note",
        "The stuck-operation sweep had marked this approval interrupted; it did finish."
      )

  defp note_swept(result, _swept?), do: result

  defp keep_partial(result, "executed", _current), do: result

  defp keep_partial(result, _status, %Confirmation{result: %{"partial" => partial}})
       when is_map(result),
       do: Map.put(result, "partial", partial)

  defp keep_partial(result, _status, _current), do: result

  # The result goes into a jsonb column: atoms, dates and the like are turned into their
  # JSON form first, and a value that has none is replaced by an error, not a crash.
  defp jsonable(value) do
    value |> JSON.encode!() |> JSON.decode!()
  rescue
    _ -> %{"error" => error(:internal_error, "The result could not be stored.")}
  end

  defp storable_result(value, keys),
    do: value |> jsonable() |> Idempotency.redact_credentials(keys)

  # The output fields the approved tool declares as credentials. A tool that is gone (its
  # module was disabled or removed since the request) declares nothing: core's rule still redacts.
  defp credential_keys(tool_name) do
    case Registry.find(tool_name, :admin) do
      {:ok, %Tool{} = tool} -> Tool.credential_keys(tool)
      _gone -> []
    end
  end

  defp error(code, detail, context \\ %{}),
    do: %{"code" => to_string(code), "detail" => detail, "context" => context}

  defp log_decision(%Confirmation{} = row, decision, %Scope{} = scope) do
    Activity.log("api", "api.approval_decided",
      actor_uuid: Scope.user_uuid(scope),
      resource_type: "api_approval",
      resource_uuid: row.uuid,
      permanent: true,
      metadata: %{
        "decision" => decision,
        "tool" => row.tool,
        "key_prefix" => key_prefix(row),
        "approval_id" => row.uuid
      }
    )

    :ok
  end

  defp log_finished(%Confirmation{} = row) do
    Activity.log("api", "api.approval_finished",
      actor_uuid: row.decided_by_uuid,
      mode: "auto",
      resource_type: "api_approval",
      resource_uuid: row.uuid,
      metadata: %{
        "status" => row.status,
        "tool" => row.tool,
        "key_prefix" => key_prefix(row),
        "approved_by_uuid" => row.decided_by_uuid,
        "error_code" => get_in(row.result || %{}, ["error", "code"])
      }
    )

    :ok
  end

  defp key_prefix(%Confirmation{actor_key_uuid: key_uuid}) do
    case Keys.get_key(key_uuid) do
      %Key{prefix: prefix} -> prefix
      nil -> nil
    end
  end

  # --- helpers ---

  @doc false
  def second(%DateTime{} = time), do: DateTime.truncate(time, :second)

  @doc false
  def repo, do: RepoHelper.repo()
end

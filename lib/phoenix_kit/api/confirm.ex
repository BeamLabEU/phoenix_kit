defmodule PhoenixKit.API.Confirm do
  @moduledoc """
  Confirmation codes of dangerous API operations, and the helpers the approval queue
  shares.

  A dangerous call without a code changes nothing and returns a preview plus a code
  (`issue_token/6`). Repeating the call with the same arguments and the code runs it.
  The code is valid only when all of these hold:

    * its row is `unused` and has not expired;
    * it was issued to the same actor (an API key, or a client-token hash for a public
      tool);
    * it was issued for the same tool and the same arguments (`input_hash`, a hash of
      the arguments without the control fields);
    * the `fingerprint` (a hash of the *current values* the operation touches) is
      still the one in the row.

  `lookup_token/5` checks the cheap parts and changes nothing. `claim_token/3` is the
  atomic part: one `UPDATE` that sets `used` only if the row is still `unused`, not
  expired, and its fingerprint equals the fresh one the caller computed by running the
  handler as a dry run. Exactly one caller can win, so two simultaneous confirmations
  run the operation once; the loser sees `{:error, :used}`. A batch that then fails
  part-way keeps its code spent.

  `live_actor/1` rebuilds an actor from a key row without a token, for the approval
  queue. `expire_due/1`, `sweep_stuck/2` and `prune/1` are the maintenance functions
  the cron workers call.

  ## A person's live session

  A write a live session asks for (`PhoenixKit.API.Executor.execute_as/5`) is held in a
  row bound to the person (`actor_user_uuid`), not to a code: the session is never given
  one (`issue_token/6` refuses a `:user` actor, and `lookup_token/5` never accepts a
  session's row). `issue_for_user/6` stores the row, every call a new one, for
  `api_user_confirm_ttl_seconds`; the executor redeems it by its uuid
  (`PhoenixKit.API.Executor.redeem_as/6`), repeating the call with the arguments the caller
  brings, and checks them against the row as for a code. This module only stores and
  finds those rows:

    * `lookup_for_user/2` finds the person's row by uuid;
    * `get_for_user/2` reads it for the page that shows the confirmation, while the session
      may still write with its tool;
    * `reject_for_user/2` turns it down;
    * `reissue_for_user/7` replaces it when the values changed under it.

  A uuid that does not exist and one of another person get the same `{:error, :unknown}`,
  so nobody learns whether somebody else's confirmation exists.
  """

  import Ecto.Query, warn: false

  alias PhoenixKit.Activity
  alias PhoenixKit.API.Actor
  alias PhoenixKit.API.Approvals
  alias PhoenixKit.API.Confirm.Confirmation
  alias PhoenixKit.API.Confirm.Token
  alias PhoenixKit.API.Executor
  alias PhoenixKit.API.FlowConfig
  alias PhoenixKit.API.Keys
  alias PhoenixKit.API.Keys.Key
  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Auth.SessionRef

  @doc """
  Issues a code for `actor`, `tool_name` and `input_hash`, holding `preview` and
  `fingerprint`. The row lives `api_confirm_ttl_seconds`.

  A key that repeats the very same call (same tool, arguments and current values) while
  its earlier code is still unused and unexpired gets **that** code again, with the time
  it has left: an agent that polls a dangerous call does not pile up rows. A public actor
  is bound to a client token it chose itself, so nothing is shared between two of its calls;
  what keeps that table small is the early prune of never-used codes (`prune/1`) and the
  rate limit of the public API.
  """
  @spec issue_token(Actor.t(), String.t(), String.t(), map(), String.t(), DateTime.t()) ::
          {:ok,
           %{token: String.t(), row: Confirmation.t(), expires_in_seconds: non_neg_integer()}}
          | {:error, :no_secret | :no_binding | Ecto.Changeset.t()}
  def issue_token(
        %Actor{} = actor,
        tool_name,
        input_hash,
        preview,
        fingerprint,
        now \\ DateTime.utc_now()
      ) do
    now = second(now)

    with {:ok, owner} <- bind_to(actor) do
      case live_code(owner, tool_name, input_hash, fingerprint, now) do
        %Confirmation{} = row -> hand_out_again(row, now)
        nil -> insert_code(owner, tool_name, input_hash, preview, fingerprint, now)
      end
    end
  end

  defp insert_code(owner, tool_name, input_hash, preview, fingerprint, now) do
    uuid = UUIDv7.generate()
    ttl = FlowConfig.confirm_ttl_seconds()

    with {:ok, token} <- Token.sign(uuid),
         {:ok, row} <-
           %Confirmation{uuid: uuid}
           |> Confirmation.changeset(
             Map.merge(owner, %{
               kind: "token",
               tool: tool_name,
               input_hash: input_hash,
               fingerprint: fingerprint,
               preview: preview,
               status: "unused",
               expires_at: DateTime.add(now, ttl, :second)
             })
           )
           |> repo().insert() do
      {:ok, %{token: token, row: row, expires_in_seconds: ttl}}
    end
  end

  # The unused, unexpired code this key already holds for the same call and values. Only a
  # key is looked up (index `actor_key_uuid, status`); the client-token binding of a public
  # actor has no index, and the actor is self-chosen anyway.
  defp live_code(%{actor_key_uuid: key_uuid}, tool_name, input_hash, fingerprint, now) do
    repo().one(
      from(c in Confirmation,
        where:
          c.actor_key_uuid == ^key_uuid and c.status == "unused" and c.kind == "token" and
            c.tool == ^tool_name and
            c.input_hash == ^input_hash and c.fingerprint == ^fingerprint and c.expires_at > ^now,
        order_by: [desc: c.expires_at],
        limit: 1
      )
    )
  end

  defp live_code(_client_token_binding, _tool_name, _input_hash, _fingerprint, _now), do: nil

  defp hand_out_again(%Confirmation{} = row, now) do
    with {:ok, token} <- Token.sign(row.uuid) do
      {:ok,
       %{token: token, row: row, expires_in_seconds: max(DateTime.diff(row.expires_at, now), 0)}}
    end
  end

  defp bind_to(%Actor{kind: :key, key_uuid: uuid}) when is_binary(uuid),
    do: {:ok, %{actor_key_uuid: uuid}}

  # A session is never given a code: its writes are held by `issue_for_user/6`.
  defp bind_to(%Actor{kind: :user}), do: {:error, :no_binding}

  defp bind_to(%Actor{client_token_hash: hash}) when is_binary(hash),
    do: {:ok, %{client_token_hash: hash}}

  defp bind_to(_actor), do: {:error, :no_binding}

  @doc """
  The cheap checks of a presented code. Changes nothing. `{:ok, row}` or the first
  reason it is refused.
  """
  @spec lookup_token(String.t(), Actor.t(), String.t(), String.t(), DateTime.t()) ::
          {:ok, Confirmation.t()}
          | {:error, :malformed | :unknown | :wrong_binding | :wrong_input | :used | :expired}
  def lookup_token(token, %Actor{} = actor, tool_name, input_hash, now \\ DateTime.utc_now()) do
    now = second(now)

    with {:ok, uuid} <- verify(token),
         {:ok, row} <- fetch_code(uuid),
         :ok <- bound_to(row, actor),
         :ok <- same_call(row, tool_name, input_hash),
         :ok <- usable(row, now) do
      {:ok, row}
    end
  end

  defp verify(token) do
    case Token.verify(token) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :malformed}
    end
  end

  defp fetch_code(uuid) do
    case repo().get(Confirmation, uuid) do
      %Confirmation{kind: "token"} = row -> {:ok, row}
      _none_or_approval -> {:error, :unknown}
    end
  end

  defp bound_to(%Confirmation{actor_key_uuid: key}, %Actor{kind: :key, key_uuid: key})
       when is_binary(key),
       do: :ok

  defp bound_to(%Confirmation{client_token_hash: hash}, %Actor{client_token_hash: hash})
       when is_binary(hash),
       do: :ok

  # Neither a session's row (`actor_user_uuid`) nor a session actor ever passes here: a
  # code is not how a session confirms.
  defp bound_to(_row, _actor), do: {:error, :wrong_binding}

  defp same_call(%Confirmation{tool: tool, input_hash: hash}, tool, hash), do: :ok
  defp same_call(_row, _tool_name, _input_hash), do: {:error, :wrong_input}

  defp usable(%Confirmation{status: "used"}, _now), do: {:error, :used}
  defp usable(%Confirmation{status: "rejected"}, _now), do: {:error, :rejected}
  defp usable(%Confirmation{status: status}, _now) when status != "unused", do: {:error, :expired}

  defp usable(%Confirmation{expires_at: expires_at}, now) do
    if DateTime.compare(expires_at, now) == :gt, do: :ok, else: {:error, :expired}
  end

  @doc """
  Spends a code, atomically. `fresh_fingerprint` is the fingerprint of the values the
  operation touches *now*. `:ok` for exactly one caller; `{:error, :used}`,
  `{:error, :rejected}` (a session's row the person turned down), `{:error, :expired}` or
  `{:error, :changed}` for the others.
  """
  @spec claim_token(Confirmation.t(), String.t(), DateTime.t()) ::
          :ok | {:error, :used | :expired | :changed | :rejected}
  def claim_token(%Confirmation{uuid: uuid}, fresh_fingerprint, now \\ DateTime.utc_now()) do
    now = second(now)

    query =
      from(c in Confirmation,
        where:
          c.uuid == ^uuid and c.kind == "token" and c.status == "unused" and c.expires_at > ^now and
            c.fingerprint == ^fresh_fingerprint
      )

    case repo().update_all(query, set: [status: "used", used_at: now, updated_at: now]) do
      {1, _} -> :ok
      {0, _} -> {:error, why_not_claimed(uuid, now)}
    end
  end

  defp why_not_claimed(uuid, now) do
    case repo().get(Confirmation, uuid) do
      %Confirmation{status: "used"} ->
        :used

      %Confirmation{status: "rejected"} ->
        :rejected

      %Confirmation{status: "unused", expires_at: expires_at} ->
        if DateTime.compare(expires_at, now) == :gt, do: :changed, else: :expired

      _expired_or_gone ->
        :expired
    end
  end

  # --- a person's live session ---------------------------------------------------------

  @doc """
  Holds a write of the live session of `actor` (a `:user`) for `tool_name` and
  `input_hash`, with `preview` and `fingerprint`, until the person confirms it, for
  `api_user_confirm_ttl_seconds`. Every call stores a new row: an earlier one is never
  handed out again. No code is made. The insert is not logged (`log: false`): its
  parameters carry the preview, the data the person works on.
  """
  @spec issue_for_user(Actor.t(), String.t(), String.t(), map(), String.t(), DateTime.t()) ::
          {:ok, Confirmation.t()} | {:error, :no_binding | Ecto.Changeset.t()}
  def issue_for_user(
        actor,
        tool_name,
        input_hash,
        preview,
        fingerprint,
        now \\ DateTime.utc_now()
      )

  def issue_for_user(
        %Actor{kind: :user, user_uuid: user_uuid},
        tool_name,
        input_hash,
        preview,
        fingerprint,
        now
      )
      when is_binary(user_uuid) do
    now = second(now)

    %Confirmation{}
    |> Confirmation.changeset(%{
      kind: "token",
      tool: tool_name,
      input_hash: input_hash,
      fingerprint: fingerprint,
      preview: preview,
      actor_user_uuid: user_uuid,
      status: "unused",
      expires_at: DateTime.add(now, FlowConfig.user_confirm_ttl_seconds(), :second)
    })
    |> repo().insert(log: false)
  end

  def issue_for_user(_actor, _tool_name, _input_hash, _preview, _fingerprint, _now),
    do: {:error, :no_binding}

  @doc """
  The person's row `confirmation_uuid`, whatever its status. `{:error, :unknown}` for a
  uuid that names no row, a row of somebody else, an approval, a code of a key, or a value
  that is not a uuid: the answer never tells them apart.
  """
  @spec lookup_for_user(term(), term()) :: {:ok, Confirmation.t()} | {:error, :unknown}
  def lookup_for_user(confirmation_uuid, user_uuid)
      when is_binary(confirmation_uuid) and is_binary(user_uuid) do
    with {:ok, uuid} <- Ecto.UUID.cast(confirmation_uuid),
         {:ok, user_uuid} <- Ecto.UUID.cast(user_uuid),
         %Confirmation{} = row <-
           repo().get_by(Confirmation, uuid: uuid, kind: "token", actor_user_uuid: user_uuid) do
      {:ok, row}
    else
      _none -> {:error, :unknown}
    end
  end

  def lookup_for_user(_confirmation_uuid, _user_uuid), do: {:error, :unknown}

  @doc """
  The cheap checks of a session's row before it is redeemed, as for a code: the same tool
  and arguments (`:wrong_input`), still `unused` and not expired (`:used`, `:rejected`,
  `:expired`). Changes nothing.
  """
  @spec redeemable(Confirmation.t(), String.t(), String.t(), DateTime.t()) ::
          :ok | {:error, :wrong_input | :used | :rejected | :expired}
  def redeemable(%Confirmation{} = row, tool_name, input_hash, now \\ DateTime.utc_now()) do
    with :ok <- same_call(row, tool_name, input_hash), do: usable(row, second(now))
  end

  @doc """
  Replaces a session's row whose values changed since its preview (`claim_token/3` said
  `:changed`) by a new one holding the fresh `preview` and `fingerprint`. The old row goes
  from `unused` to `expired` in the same transaction, so it can never be redeemed after
  the new one exists. `{:error, reason}` when the old row is no longer `unused` (it was
  used or rejected meanwhile), and nothing is stored. Neither statement is logged
  (`log: false`), as in `issue_for_user/6`.
  """
  @spec reissue_for_user(
          Confirmation.t(),
          Actor.t(),
          String.t(),
          String.t(),
          map(),
          String.t(),
          DateTime.t()
        ) ::
          {:ok, Confirmation.t()}
          | {:error, :used | :rejected | :expired | :changed | :no_binding | Ecto.Changeset.t()}
  def reissue_for_user(
        %Confirmation{uuid: old_uuid},
        %Actor{} = actor,
        tool_name,
        input_hash,
        preview,
        fingerprint,
        now \\ DateTime.utc_now()
      ) do
    now = second(now)

    query =
      from(c in Confirmation,
        where: c.uuid == ^old_uuid and c.kind == "token" and c.status == "unused"
      )

    repo().transaction(fn ->
      with {1, _} <-
             repo().update_all(query, [set: [status: "expired", updated_at: now]], log: false),
           {:ok, row} <- issue_for_user(actor, tool_name, input_hash, preview, fingerprint, now) do
        row
      else
        {0, _} -> repo().rollback(why_not_claimed(old_uuid, now))
        {:error, reason} -> repo().rollback(reason)
      end
    end)
  end

  @doc """
  What the page that shows a session's confirmation needs: `%{uuid, tool, preview, status,
  expires_at}` of the row `confirmation_uuid`, if it belongs to the user of the live
  session `session_ref` (`{session_token_uuid, user_uuid}`). `status` is `"unused"`,
  `"used"`, `"rejected"` or `"expired"` (an unused row past its time reads `"expired"`).

  `{:error, :unauthorized}` when the session cannot act any more
  (`SessionRef.scope_for_session/2`), `{:error, :unknown}` as in `lookup_for_user/2`, and
  `{:error, :forbidden}`, without the preview, when the session may no longer write with the
  row's tool, whatever the row's status: the tool must still be callable (its module on, the
  module's API on, the tool not hidden), its scope and permission held by the session's
  scope now, and its module in `api_session_write_modules`, as
  `PhoenixKit.API.Executor.redeem_as/6` checks before it runs.

  The core does not tell an impersonated session from the person's own: the caller must
  refuse a session that `PhoenixKitWeb.Users.MultiSession.impersonated?/1` marks before it
  calls, so an administrator acting as somebody else does not read their previews.
  """
  @spec get_for_user(term(), term(), DateTime.t()) ::
          {:ok,
           %{
             uuid: String.t(),
             tool: String.t(),
             preview: map(),
             status: String.t(),
             expires_at: DateTime.t()
           }}
          | {:error, :unauthorized | :unknown | :forbidden}
  def get_for_user(confirmation_uuid, session_ref, now \\ DateTime.utc_now()) do
    with {:ok, scope} <- session_scope(session_ref),
         {:ok, row} <- lookup_for_user(confirmation_uuid, scope.user.uuid),
         :ok <- may_write(scope, row) do
      {:ok,
       %{
         uuid: row.uuid,
         tool: row.tool,
         preview: row.preview,
         status: card_status(row, second(now)),
         expires_at: row.expires_at
       }}
    end
  end

  defp may_write(scope, %Confirmation{tool: tool_name}) do
    if Executor.session_may_write?(scope, tool_name), do: :ok, else: {:error, :forbidden}
  end

  defp card_status(%Confirmation{status: "unused"} = row, now),
    do: if(usable(row, now) == :ok, do: "unused", else: "expired")

  defp card_status(%Confirmation{status: status}, _now), do: status

  @doc """
  The person turns down their confirmation `confirmation_uuid`: one atomic `UPDATE` from
  `unused` (and not expired) to `rejected`, so a rejected row can never be redeemed and a
  redeemed one never rejected. `{:error, :used | :rejected | :expired}` when it is no longer
  waiting; `{:error, :unauthorized}` and `{:error, :unknown}` as in `get_for_user/2`. The
  person may turn a row down after losing the right to the tool: nothing runs.

  As for `get_for_user/2`, the caller must refuse an impersonated session
  (`PhoenixKitWeb.Users.MultiSession.impersonated?/1`) before it calls.
  """
  @spec reject_for_user(term(), term(), DateTime.t()) ::
          :ok | {:error, :unauthorized | :unknown | :used | :rejected | :expired | :changed}
  def reject_for_user(confirmation_uuid, session_ref, now \\ DateTime.utc_now()) do
    now = second(now)

    with {:ok, scope} <- session_scope(session_ref),
         {:ok, %Confirmation{uuid: uuid}} <- lookup_for_user(confirmation_uuid, scope.user.uuid) do
      query =
        from(c in Confirmation,
          where:
            c.uuid == ^uuid and c.kind == "token" and c.status == "unused" and
              c.expires_at > ^now
        )

      case repo().update_all(query, set: [status: "rejected", updated_at: now]) do
        {1, _} -> :ok
        {0, _} -> {:error, why_not_claimed(uuid, now)}
      end
    end
  end

  # The scope of a session that can still act, rebuilt as the executor rebuilds it.
  defp session_scope({token_uuid, user_uuid}) do
    case SessionRef.scope_for_session(token_uuid, user_uuid) do
      {:ok, %Scope{user: %{uuid: _uuid}} = scope} -> {:ok, scope}
      {:error, _reason} -> {:error, :unauthorized}
    end
  end

  defp session_scope(_not_a_pair), do: {:error, :unauthorized}

  @doc """
  The actor of an API key as it stands **now**, without a token: the key is read from
  the database (not the cache), must not be revoked or expired (`Keys.dead_reason/1`), and
  its owner must be active (and, for a personal key, hold `api_personal_keys` or `api`,
  else `{:error, :personal_keys_not_allowed}`); `scopes` are the key's scopes filtered by
  the owner's live permissions. This is the request-path check of the executor, for code that has no
  request.
  """
  @spec live_actor(String.t()) ::
          {:ok, Actor.t()}
          | {:error,
             :not_found | :revoked | :expired | :owner_inactive | :personal_keys_not_allowed}
  def live_actor(key_uuid) do
    with %Key{} = key <- Keys.get_key(key_uuid) || {:error, :not_found},
         :ok <- alive(key),
         {:ok, owner} <- Keys.active_owner(key) do
      {:ok, Keys.actor(key, owner, nil)}
    end
  end

  defp alive(%Key{} = key) do
    case Keys.dead_reason(key) do
      nil -> :ok
      reason -> {:error, reason}
    end
  end

  # --- maintenance (the cron workers) ---------------------------------------------------

  @stuck_after_seconds 900
  @retention_days 30
  @unused_code_retention_seconds 3_600
  @interrupted "The process that was running this operation stopped before it finished. Part of it may have been applied: check the data."

  @doc """
  Marks the pending approvals and the unused codes whose `expires_at` has passed as
  `expired` (an approval's input is cleared). Returns how many of each.
  """
  @spec expire_due(DateTime.t()) :: %{approvals: non_neg_integer(), tokens: non_neg_integer()}
  def expire_due(now \\ DateTime.utc_now()) do
    now = second(now)

    {approvals, _} =
      repo().update_all(
        from(c in Confirmation,
          where: c.kind == "approval" and c.status == "pending" and c.expires_at <= ^now
        ),
        set: [status: "expired", input: nil, updated_at: now]
      )

    {tokens, _} =
      repo().update_all(
        from(c in Confirmation,
          where: c.kind == "token" and c.status == "unused" and c.expires_at <= ^now
        ),
        set: [status: "expired", updated_at: now]
      )

    if approvals > 0, do: Approvals.broadcast(:expired)
    %{approvals: approvals, tokens: tokens}
  end

  @doc """
  Fails every approval that is still `approved` or `executing` although nothing has
  touched it for `stale_after_seconds` (default 15 minutes): the process that was running
  it died. The error `interrupted` is added to whatever partial results it had reported,
  its input is cleared, and the outcome is logged and announced. Returns how many.
  """
  @spec sweep_stuck(DateTime.t(), pos_integer()) :: non_neg_integer()
  def sweep_stuck(now \\ DateTime.utc_now(), stale_after_seconds \\ @stuck_after_seconds) do
    now = second(now)
    cutoff = DateTime.add(now, -stale_after_seconds, :second)
    error = %{"code" => "interrupted", "detail" => @interrupted, "context" => %{}}

    stuck =
      repo().all(
        from(c in Confirmation,
          where:
            c.kind == "approval" and c.status in ["approved", "executing"] and
              c.updated_at < ^cutoff
        )
      )

    # Row by row: a row that moved on since it was read (its updated_at changed) is skipped.
    swept =
      Enum.filter(stuck, fn row ->
        query =
          from(c in Confirmation,
            where:
              c.uuid == ^row.uuid and c.status in ["approved", "executing"] and
                c.updated_at < ^cutoff
          )

        changes = [
          status: "failed",
          input: nil,
          result: Map.put(row.result || %{}, "error", error),
          updated_at: now
        ]

        match?({1, _}, repo().update_all(query, set: changes))
      end)

    Enum.each(swept, &announce_swept/1)
    length(swept)
  end

  defp announce_swept(%Confirmation{} = row) do
    Activity.log("api", "api.approval_finished",
      mode: "auto",
      resource_type: "api_approval",
      resource_uuid: row.uuid,
      metadata: %{"status" => "failed", "tool" => row.tool, "error_code" => "interrupted"}
    )

    Approvals.broadcast(row.uuid)
  end

  @doc """
  Deletes the rows nobody needs any more. Returns how many rows went.

    * a code that was **never used** (still `unused`, marked `expired`, or `rejected` by the
      person of a session) one hour after it ran out: every dangerous call without a code
      inserts one, and a public client can ask for many, so these must not stay for a month;
    * a code that **was used** 30 days after it ran out (it is the trace of what was confirmed);
    * an approval 30 days after its last change, once decided, executed, failed, found stale
      or expired. A pending, approved or executing approval is never deleted.
  """
  @spec prune(DateTime.t()) :: non_neg_integer()
  def prune(now \\ DateTime.utc_now()) do
    cutoff = now |> second() |> DateTime.add(-@retention_days * 86_400, :second)
    live = ["pending", "approved", "executing"]

    unused_cutoff = now |> second() |> DateTime.add(-@unused_code_retention_seconds, :second)

    {unused, _} =
      repo().delete_all(
        from(c in Confirmation,
          where:
            c.kind == "token" and c.status in ["unused", "expired", "rejected"] and
              c.expires_at < ^unused_cutoff
        )
      )

    {used, _} =
      repo().delete_all(
        from(c in Confirmation, where: c.kind == "token" and c.expires_at < ^cutoff)
      )

    {approvals, _} =
      repo().delete_all(
        from(c in Confirmation,
          where: c.kind == "approval" and c.status not in ^live and c.updated_at < ^cutoff
        )
      )

    unused + used + approvals
  end

  defp second(%DateTime{} = time), do: DateTime.truncate(time, :second)

  defp repo, do: RepoHelper.repo()
end

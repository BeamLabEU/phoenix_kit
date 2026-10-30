defmodule PhoenixKit.Users.Sessions.Revocation do
  @moduledoc """
  Internal, transaction-aware session and manager-grant deletion.

  Locks the rows being removed before collecting their dependent organization
  sessions. The foreign key's KEY SHARE lock serializes an incoming token with
  this FOR UPDATE lock: an insert finishes before collection or fails after
  deletion. Only the locked set is deleted; an unlocked second query must not
  delete rows whose dependent sockets were never collected.

  `transaction/2` retains Ecto's result shape and shares a disconnect collector
  across nested calls. Successful outer commits disconnect synchronously. A
  host may also call a drain inside its own repo transaction: a small observer
  waits for that transaction's outcome from another connection. It holds no
  connection while waiting and re-checks token absence after commit, including
  when a host rolls back a savepoint and commits the surrounding transaction.

  Raw tokens stay in process memory. They are never written to a job, database
  notification or log. The observer uses PostgreSQL's transaction-status
  functions (available since PostgreSQL 13); no extension or host hook is needed.
  Observation stops after 30 consecutive failed database checks. An open,
  reachable transaction does not count as a failure. On exhaustion, token
  validation still refuses deleted sessions but sockets may remain connected
  until their next authorization check or reconnect.

  These are system primitives, not authorization APIs. A request-driven caller
  authorizes before invoking them. Manager lifecycle callers must also hold
  the organization's lock and enforce the last-active-manager rule.
  """

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Users.Auth.UserToken
  alias PhoenixKit.Users.OrganizationManager
  alias PhoenixKit.Users.Sessions
  alias PhoenixKit.Users.Sessions.Revocation.Observer

  @doc "An Ecto transaction whose session disconnects are deferred until commit."
  def transaction(fun_or_multi, opts \\ []) do
    repo = RepoHelper.repo()
    dynamic_repo = repo.get_dynamic_repo()
    key = collector_key(repo, dynamic_repo)

    if Process.get(key) do
      repo.transaction(fun_or_multi, opts)
    else
      outer_transaction(repo, dynamic_repo, key, fun_or_multi, opts)
    end
  end

  defp outer_transaction(repo, dynamic_repo, key, fun_or_multi, opts) do
    external? = repo.in_transaction?()
    Process.put(key, [])

    try do
      result = repo.transaction(fun_or_multi, opts)
      tokens = Process.get(key) |> Enum.uniq()

      if match?({:ok, _}, result) and tokens != [] do
        if external? do
          %{rows: [[xid]]} =
            repo.query!("SELECT pg_catalog.pg_current_xact_id()::text", [], log: false)

          observe_later(repo, dynamic_repo, xid, tokens)
        else
          finish(repo, dynamic_repo, tokens)
        end
      end

      result
    after
      Process.delete(key)
    end
  end

  @doc "Deletes a UserToken query, preserving delete_all's count and selected result."
  def delete_all(query, opts \\ []) do
    drain(query, UserToken, :acting_session_uuid, opts)
  end

  @doc "Adds a token drain to an Ecto.Multi; run the multi through transaction/2."
  def multi_delete_all(multi, name, query, opts \\ []) do
    Ecto.Multi.run(multi, name, fn _repo, _changes -> {:ok, delete_all(query, opts)} end)
  end

  @doc "Deletes a manager-grant query and disconnects the sessions it cascades away."
  def delete_manager_grants(query) do
    drain(query, OrganizationManager, :organization_manager_uuid, [])
  end

  defp drain(query, schema, dependency, opts) do
    {:ok, result} =
      transaction(fn ->
        repo = RepoHelper.repo()
        rows = lock_sources(repo, query, schema)
        ids = Enum.map(rows, & &1.uuid)
        dependents = dependent_tokens(repo, ids, dependency)

        deleted = repo.delete_all(from(row in query, where: row.uuid in ^ids), log: false)

        direct = for %{context: "session", token: token} <- rows, do: token
        tokens = Enum.reject(direct ++ dependents, &(&1 == opts[:except_token]))
        enqueue(tokens)
        deleted
      end)

    result
  end

  defp lock_sources(repo, query, schema) do
    query = query |> exclude(:select) |> exclude(:order_by)

    query =
      if schema == UserToken do
        from(row in query,
          order_by: row.uuid,
          lock: "FOR UPDATE",
          select: %{uuid: row.uuid, token: row.token, context: row.context}
        )
      else
        from(row in query, order_by: row.uuid, lock: "FOR UPDATE", select: %{uuid: row.uuid})
      end

    repo.all(query, log: false)
  end

  defp dependent_tokens(_repo, [], _dependency), do: []

  defp dependent_tokens(repo, ids, dependency) do
    repo.all(
      from(t in UserToken,
        where: field(t, ^dependency) in ^ids and t.context == "session",
        order_by: t.uuid,
        lock: "FOR UPDATE",
        select: t.token
      ),
      log: false
    )
  end

  defp enqueue(tokens) do
    repo = RepoHelper.repo()
    key = collector_key(repo, repo.get_dynamic_repo())
    Process.put(key, tokens ++ Process.get(key))
  end

  defp collector_key(repo, dynamic_repo), do: {__MODULE__, repo, dynamic_repo}

  defp finish(repo, dynamic_repo, tokens) do
    disconnect_absent(repo, tokens)
  rescue
    _ -> observe_later(repo, dynamic_repo, :committed, tokens)
  catch
    :exit, _ -> observe_later(repo, dynamic_repo, :committed, tokens)
  end

  defp disconnect_absent(repo, tokens) do
    existing =
      repo.all(
        from(t in UserToken,
          where: t.context == "session" and t.token in ^tokens,
          select: t.token
        ),
        log: false
      )

    Sessions.disconnect_tokens(tokens -- existing)
  end

  defp observe_later(repo, dynamic_repo, xid, tokens) do
    fun = fn ->
      repo.put_dynamic_repo(dynamic_repo)
      Observer.run(fn -> check_outcome(repo, xid, tokens) end, length(tokens))
    end

    start_observer(fun)
    :ok
  end

  defp start_observer(fun) do
    case Process.whereis(PhoenixKit.TaskSupervisor) do
      nil ->
        Task.start(fun)

      supervisor ->
        case Task.Supervisor.start_child(supervisor, fun) do
          {:ok, _pid} = started -> started
          {:error, _reason} -> Task.start(fun)
        end
    end
  catch
    :exit, _ -> Task.start(fun)
  end

  defp check_outcome(repo, xid, tokens) do
    independently(repo, fn ->
      case transaction_status(repo, xid) do
        "in progress" ->
          :retry

        "aborted" ->
          :done

        _committed_or_pruned ->
          disconnect_absent(repo, tokens)
          :done
      end
    end)
  rescue
    _ -> :unavailable
  catch
    :exit, _ -> :unavailable
  end

  defp transaction_status(_repo, :committed), do: "committed"

  defp transaction_status(repo, xid) do
    %{rows: [[status]]} =
      repo.query!("SELECT pg_catalog.pg_xact_status($1::text::pg_catalog.xid8)", [xid],
        log: false
      )

    status
  end

  # A test sandbox's implicit transaction is not an application transaction.
  # Observers need a real, independent connection to see a host-owned commit.
  defp independently(repo, fun) do
    if repo.config()[:pool] == Sandbox,
      do: Sandbox.unboxed_run(repo, fun),
      else: fun.()
  end
end

defmodule PhoenixKit.API.OAuth.Prune do
  @moduledoc """
  The clean-up of the OAuth tables, run daily by `PhoenixKit.API.OAuth.PruneWorker`.

  In this order (a consent nobody finished goes first, so the registered clients it kept alive
  can go in the same run):

    1. **Consents nobody finished** - a grant never activated (`activated_at` is `nil`) whose
       authorization code ran out at least an hour ago (and which is itself an hour old), with
       its hidden key, which has no history. The check is made again under the key then grant
       lock, so a code exchanged a moment ago keeps its grant.
    2. **Requests** past their ten minutes.
    3. **Codes** past their minute.
    4. **Tokens** past their own end. A refresh token ends with its grant, so a used refresh
       token is never removed before the grant is over (reuse of it is still told from a retry).
    5. **Registered clients** (`dcr`) with no grant, a day after they registered, and with no
       authorization request still waiting.

  What it never does: remove a grant that was activated, or the hidden key of one. Those keys
  have history (confirmations and activity point at them); an ended grant keeps its key row,
  revoked or expired.

  Every step works in batches of `#{500}` rows and a run that finds more leaves the rest for
  tomorrow. Returns the counts per step.
  """

  import Ecto.Query, only: [from: 2]

  alias PhoenixKit.API.OAuth.Client
  alias PhoenixKit.API.OAuth.Code
  alias PhoenixKit.API.OAuth.Grant
  alias PhoenixKit.API.OAuth.Grants
  alias PhoenixKit.API.OAuth.Request
  alias PhoenixKit.API.OAuth.Token
  alias PhoenixKit.RepoHelper

  @batch 500
  @abandoned_grace_seconds 3600
  @dcr_client_seconds 86_400

  @doc "Runs every step at `now`; returns `%{grants: n, requests: n, codes: n, tokens: n, clients: n}`."
  @spec run(DateTime.t()) :: %{atom() => non_neg_integer()}
  def run(now \\ DateTime.utc_now()) do
    now = DateTime.truncate(now, :second)

    %{
      grants: abandoned_grants(now),
      requests: delete_batch(from(r in Request, where: r.expires_at < ^now)),
      codes: delete_batch(from(c in Code, where: c.expires_at < ^now)),
      tokens: delete_batch(from(t in Token, where: t.expires_at < ^now)),
      clients: idle_clients(now)
    }
  end

  defp abandoned_grants(now) do
    cutoff = DateTime.add(now, -@abandoned_grace_seconds, :second)

    from(g in Grant,
      where: is_nil(g.activated_at) and g.inserted_at < ^cutoff,
      where:
        not exists(
          from(c in Code,
            where: c.grant_uuid == parent_as(:grant).uuid and c.expires_at > ^cutoff
          )
        ),
      limit: @batch,
      select: g.uuid
    )
    |> Ecto.Query.from(as: :grant)
    |> repo().all()
    |> Enum.count(&(Grants.delete_unactivated(&1, cutoff) == :deleted))
  end

  defp idle_clients(now) do
    cutoff = DateTime.add(now, -@dcr_client_seconds, :second)

    from(c in Client,
      as: :client,
      where: c.kind == "dcr" and c.inserted_at < ^cutoff,
      where: not exists(from(g in Grant, where: g.client_uuid == parent_as(:client).uuid)),
      where:
        not exists(
          from(r in Request,
            where:
              r.client_uuid == parent_as(:client).uuid and is_nil(r.consumed_at) and
                r.expires_at >= ^now
          )
        ),
      limit: @batch,
      select: c.uuid
    )
    |> repo().all()
    |> then(fn uuids -> delete_batch(from(c in Client, where: c.uuid in ^uuids)) end)
  end

  # `delete_all` takes no `limit`, so the batch is cut by uuid first.
  defp delete_batch(query) do
    uuids = repo().all(from(q in query, select: q.uuid, limit: @batch))
    schema = query.from.source |> elem(1)

    {count, _} = repo().delete_all(from(s in schema, where: s.uuid in ^uuids))
    count
  end

  defp repo, do: RepoHelper.repo()
end

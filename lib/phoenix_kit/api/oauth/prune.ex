defmodule PhoenixKit.API.OAuth.Prune do
  @moduledoc """
  The clean-up of the OAuth tables, run daily by `PhoenixKit.API.OAuth.PruneWorker`.

  In this order (a consent nobody finished goes first, so the registered clients it kept alive
  can go in the same run):

    1. **Consents nobody finished** - a grant never activated (`activated_at` is `nil`) whose
       authorization code ran out at least an hour ago (and which is itself an hour old), with
       its hidden key, which has no history. The check is made again under the key then grant
       lock, so a code exchanged a moment ago keeps its grant.
    2. **Grants that are over** - revoked, or past their `expires_at` - three days ago or more
       (the same grace as the tokens below), with their hidden key, tokens and codes. Without
       this step every consent would leave a grant and a key row behind for good. A grant whose
       key has confirmations is **not** removed (the tables cascade: the approval history would
       go with the key); it is removed in a later run, once `Confirm.Prune` has cleared them.
       The activity entries (`oauth.grant_revoked`, the key's `api.*` entries) stay in any case,
       as they point at the key by uuid only.
    3. **Requests** past their ten minutes.
    4. **Codes** past their minute.
    5. **Tokens** three days past their own end: an application that comes back after its
       access token ran out is still told "expired" (not charged to the failure bucket) and
       not "unknown". A refresh token ends with its grant, so a used refresh token is never
       removed before the grant is over (reuse of it is still told from a retry).
    6. **Registered clients** (`dcr`) with no grant, a day after they registered, and with no
       authorization request still waiting; **metadata document clients** (`cimd`) with no
       grant, a day after the cache of their document ran out, and with no request waiting (an
       unauthenticated authorization request makes the server fetch and store one, so they
       must not pile up). Pre-registered clients stay.

  What it never does: remove a grant that is still alive (or ended less than three days ago),
  a key with confirmations, or any key that is not the hidden key of a grant. A person's own keys are not its business.

  Every step works in batches of 500 rows and repeats until a batch comes back short, so a
  busy install is cleared in one run. Returns the counts per step.
  """

  import Ecto.Query, only: [from: 2]

  alias PhoenixKit.API.Confirm.Confirmation
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
  @token_grace_seconds 3 * 86_400

  @doc """
  Runs every step at `now`; returns
  `%{grants: n, ended: n, requests: n, codes: n, tokens: n, clients: n}`.
  """
  @spec run(DateTime.t()) :: %{atom() => non_neg_integer()}
  def run(now \\ DateTime.utc_now()) do
    now = DateTime.truncate(now, :second)

    %{
      grants: abandoned_grants(now),
      ended: ended_grants(now),
      requests: delete_all_batches(from(r in Request, where: r.expires_at < ^now)),
      codes: delete_all_batches(from(c in Code, where: c.expires_at < ^now)),
      tokens: delete_all_batches(from(t in Token, where: t.expires_at < ^token_cutoff(now))),
      clients: idle_clients(now)
    }
  end

  defp token_cutoff(now), do: DateTime.add(now, -@token_grace_seconds, :second)

  # A grant that stays (`:kept`: a code is alive after all, or it was just activated) comes back
  # in the next batch; the run goes on while a full batch still deleted something.
  defp abandoned_grants(now, deleted \\ 0) do
    cutoff = DateTime.add(now, -@abandoned_grace_seconds, :second)

    uuids =
      from(g in Grant,
        where: is_nil(g.activated_at) and g.inserted_at < ^cutoff,
        where:
          not exists(
            from(c in Code,
              where: c.grant_uuid == parent_as(:grant).uuid and c.expires_at > ^cutoff
            )
          ),
        order_by: [asc: g.inserted_at],
        limit: @batch,
        select: g.uuid
      )
      |> Ecto.Query.from(as: :grant)
      |> repo().all()

    removed = Enum.count(uuids, &(Grants.delete_unactivated(&1, cutoff) == :deleted))

    if length(uuids) == @batch and removed > 0,
      do: abandoned_grants(now, deleted + removed),
      else: deleted + removed
  end

  # The same loop for the grants that are over. A grant whose key has confirmations is left out
  # of the query itself, so rows that stay for a long time cannot crowd out the ones behind them;
  # one that stays for another reason (`:kept`: it was removed meanwhile) leaves the next
  # batch's query on its own.
  defp ended_grants(now, deleted \\ 0) do
    cutoff = token_cutoff(now)

    uuids =
      from(g in Grant,
        as: :grant,
        where: (not is_nil(g.revoked_at) and g.revoked_at < ^cutoff) or g.expires_at < ^cutoff,
        where:
          not exists(
            from(c in Confirmation, where: c.actor_key_uuid == parent_as(:grant).key_uuid)
          ),
        order_by: [asc: g.inserted_at],
        limit: @batch,
        select: g.uuid
      )
      |> repo().all()

    removed = Enum.count(uuids, &(Grants.delete_ended(&1, cutoff) == :deleted))

    if length(uuids) == @batch and removed > 0,
      do: ended_grants(now, deleted + removed),
      else: deleted + removed
  end

  defp idle_clients(now, deleted \\ 0) do
    cutoff = DateTime.add(now, -@dcr_client_seconds, :second)

    uuids =
      from(c in Client,
        as: :client,
        where:
          (c.kind == "dcr" and c.inserted_at < ^cutoff) or
            (c.kind == "cimd" and c.metadata_expires_at < ^cutoff),
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

    {removed, _} = repo().delete_all(from(c in Client, where: c.uuid in ^uuids))

    if length(uuids) == @batch and removed > 0,
      do: idle_clients(now, deleted + removed),
      else: deleted + removed
  end

  # `delete_all` takes no `limit`, so a batch is cut by uuid first; goes on while a batch is full.
  defp delete_all_batches(query, deleted \\ 0) do
    uuids = repo().all(from(q in query, select: q.uuid, limit: @batch))
    schema = query.from.source |> elem(1)

    {removed, _} = repo().delete_all(from(s in schema, where: s.uuid in ^uuids))

    if length(uuids) == @batch and removed > 0,
      do: delete_all_batches(query, deleted + removed),
      else: deleted + removed
  end

  defp repo, do: RepoHelper.repo()
end

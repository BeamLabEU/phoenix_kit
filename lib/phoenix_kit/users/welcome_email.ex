defmodule PhoenixKit.Users.WelcomeEmail do
  @moduledoc """
  The welcome email: sent once, after a user confirms their address.

  Off by default — the `email_welcome_enabled` setting, switched on under
  Settings → Emails Transactional → Branding. Its copy is core's `welcome`
  email (`PhoenixKit.Email.CoreTemplates.welcome_defaults/0`), overridable
  with files like any other.

  ## When it is sent

  `after_confirmation/1` is called where a user's own action confirms their
  address:

    * `Auth.confirm_user/1` — the link in the confirmation email;
    * `Auth.confirm_user_from_external_proof/1` — signing in with a magic
      link, or with an OAuth provider that verified the address, while the
      account is unconfirmed (a new OAuth account included);
    * `Auth.update_user_email/2` — an unconfirmed account that corrects its
      address ("Wrong email?") and so confirms the new one;
    * magic-link registration, which confirms the new account itself.

  An administrator confirming an account by hand (`Auth.toggle_user_confirmation/2`,
  `Auth.admin_confirm_user/1`) sends nothing: the reader did not do anything,
  and an operator confirming imported accounts must not mail every one of
  them. `admin_confirm_user/1` stays silent for the same reason — magic-link
  registration calls this module itself, after it.

  ## Only a real transition

  The transactional paths record, before they confirm, whether the row is
  still unconfirmed as their transaction sees it (`track_transition/2`, a
  `SELECT … FOR NO KEY UPDATE`), and enqueue only then (`multi/1`). A confirmation
  link clicked after an administrator already confirmed the account, or a
  second tab holding a stale unconfirmed struct, confirms nothing new and
  enqueues nothing. Magic-link registration confirms an account it has just
  created, so its transition is real by construction.

  ## After the confirmation commits

  `after_confirmation/1` only enqueues a job
  (`PhoenixKit.Users.WelcomeEmailWorker`, queue `notifications`). The
  confirmation link, the external-proof confirmation and the address
  correction enqueue it as a step of the transaction that confirms the
  address (`multi/1`), so the job exists exactly when the confirmation does:
  a rollback — of the confirmation, or of a caller's transaction around it,
  such as the OAuth callback's — takes the job with it. Magic-link
  registration enqueues it right after `admin_confirm_user/1` has committed,
  outside any transaction. Nothing is claimed and nothing is sent while a
  transaction is open, and no mail server ever holds a row lock — except
  under Oban's `testing: :inline`, which runs a job the moment it is
  inserted (a host's test setup, never production).

  ## Once — at most

  One job is enqueued per real transition, and before sending it claims
  the account with one conditional `UPDATE` that records
  `welcome_email_sent_at` in its `custom_fields` only if it is not there
  yet. A confirmation repeated later (an address unconfirmed and confirmed
  again) finds the mark and sends nothing. The mark is cleared for a retry
  only when the email is known not to have gone out; see
  `PhoenixKit.Users.WelcomeEmailWorker` for why a failure during delivery,
  or a node dying between the claim and the send, loses the email instead
  of risking a second one.

  ## Never in the way

  Enqueueing the welcome email never fails a confirmation that would
  otherwise succeed. A node without Oban running logs that the job could not
  be enqueued. Inside a transaction the insert runs under its own savepoint,
  with a two-second `lock_timeout`: if it fails — refused, or kept
  waiting on a locked `oban_jobs` — the error is logged, only the savepoint
  is rolled back, and the confirmation commits without a job. (A connection
  lost in the middle of the transaction fails the confirmation either way.)
  """

  import Ecto.Query, only: [from: 2]

  require Logger

  alias PhoenixKit.RepoHelper, as: Repo
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Users.WelcomeEmailWorker

  @setting "email_welcome_enabled"
  # How long the job insert waits for a lock on `oban_jobs` inside the
  # confirmation's transaction.
  @lock_timeout "2s"
  @sent_key "welcome_email_sent_at"

  @doc ~s(The setting that switches the welcome email on: `"true"` or `"false"`.)
  @spec setting_key() :: String.t()
  def setting_key, do: @setting

  @doc "The `custom_fields` key that records when the welcome email was sent."
  @spec sent_key() :: String.t()
  def sent_key, do: @sent_key

  @doc "Whether the welcome email is switched on. Off unless set."
  @spec enabled?() :: boolean()
  def enabled?, do: Settings.get_boolean_setting(@setting, false)

  @doc """
  Enqueues the welcome email for a user who has just confirmed their
  address, unless it is switched off.

  Returns `:enqueued`, `:skipped` (off, not confirmed) or `:error` (logged).
  """
  @spec after_confirmation(User.t() | term()) :: :enqueued | :skipped | :error
  def after_confirmation(%User{confirmed_at: %_{}, uuid: uuid} = user) when is_binary(uuid) do
    if enabled?(), do: enqueue(user), else: :skipped
  end

  def after_confirmation(_user), do: :skipped

  @doc """
  Records, as a step of `multi` placed **before** the step that confirms
  `user`, whether the user's row is still unconfirmed — locked
  (`FOR NO KEY UPDATE`: it serialises confirmations of the row without
  blocking foreign-key checks that only share its key), so of two
  transactions confirming the same row only the first sees the transition.
  `multi/1` reads it.
  """
  @spec track_transition(Ecto.Multi.t(), User.t()) :: Ecto.Multi.t()
  def track_transition(multi, %User{uuid: uuid}) do
    Ecto.Multi.run(multi, :welcome_transition, fn repo, _changes ->
      unconfirmed? =
        repo.one(
          from(u in User,
            where: u.uuid == ^uuid,
            select: is_nil(u.confirmed_at),
            lock: "FOR NO KEY UPDATE"
          )
        )

      {:ok, unconfirmed? == true}
    end)
  end

  @doc """
  `after_confirmation/1` as a step of `multi`, after the step that confirms
  the user (`:user`) — so the job is inserted in the confirmation's own
  transaction — when `track_transition/2` saw the row unconfirmed. Without
  that step nothing is enqueued.
  """
  @spec multi(Ecto.Multi.t()) :: Ecto.Multi.t()
  def multi(multi) do
    Ecto.Multi.run(multi, :welcome_email, fn _repo, changes ->
      case changes do
        %{welcome_transition: true, user: user} -> {:ok, after_confirmation(user)}
        _ -> {:ok, :skipped}
      end
    end)
  end

  # Oban not running on this node is the expected miss, told apart before any
  # SQL runs.
  defp enqueue(user) do
    if Oban.whereis(Oban) do
      guarded_insert(user)
    else
      log_failure(user, "Oban is not running on this node")
      :error
    end
  end

  # Inside a transaction the insert gets a savepoint of its own: a statement
  # that fails would otherwise abort the confirmation's transaction too. Under
  # it, a short `lock_timeout`: a table held by a migration or `VACUUM FULL`
  # would otherwise keep the insert waiting past the client's timeout, and a
  # connection error cannot be rolled back to a savepoint. Rolling back to the
  # savepoint undoes the `SET LOCAL` too; on success the caller's own value is
  # put back before the savepoint is released.
  defp guarded_insert(user) do
    repo = Repo.repo()

    if repo.in_transaction?() do
      repo.query!("SAVEPOINT pk_welcome_email")
      %{rows: [[previous]]} = repo.query!("SELECT current_setting('lock_timeout')")
      repo.query!("SET LOCAL lock_timeout = '#{@lock_timeout}'")

      case insert(user) do
        {:ok, result} ->
          repo.query!("SELECT set_config('lock_timeout', $1, true)", [previous])
          repo.query!("RELEASE SAVEPOINT pk_welcome_email")
          result

        {:failed, reason} ->
          # Logged first: should rolling back fail as well, the reason is
          # still on record.
          log_failure(user, reason)
          repo.query!("ROLLBACK TO SAVEPOINT pk_welcome_email")
          :error
      end
    else
      case insert(user) do
        {:ok, result} ->
          result

        {:failed, reason} ->
          log_failure(user, reason)
          :error
      end
    end
  end

  defp insert(user) do
    case Oban.insert(WelcomeEmailWorker.new(%{"user_uuid" => user.uuid})) do
      {:ok, _job} -> {:ok, :enqueued}
      {:error, reason} -> {:failed, inspect(reason)}
    end
  rescue
    error -> {:failed, Exception.message(error)}
  catch
    kind, reason -> {:failed, inspect({kind, reason})}
  end

  defp log_failure(user, reason) do
    Logger.error(
      "[PhoenixKit] Could not enqueue the welcome email for user #{inspect(user.uuid)}: #{reason}"
    )
  end
end

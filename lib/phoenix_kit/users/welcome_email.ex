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

  ## After the confirmation commits

  `after_confirmation/1` only enqueues a job
  (`PhoenixKit.Users.WelcomeEmailWorker`, queue `notifications`). The
  confirmation paths enqueue it inside the transaction that confirms the
  address (`multi/1`), so the job exists exactly when the confirmation does:
  a rollback — of the confirmation, or of a caller's transaction around it,
  such as the OAuth callback's — takes the job with it. Nothing is claimed
  and nothing is sent while a transaction is open, and no mail server ever
  holds a row lock.

  ## Once

  The job is unique per user, and before sending it claims the account with
  one conditional `UPDATE` that records `welcome_email_sent_at` in its
  `custom_fields` only if it is not there yet. A confirmation repeated later
  (an address unconfirmed and confirmed again) finds the mark and sends
  nothing. A send that fails clears the mark again and the job is retried
  (up to three attempts).

  ## Never in the way

  A node without Oban running logs that the job could not be enqueued, and
  the confirmation goes on. An error from the insert itself is re-raised
  inside a transaction rather than swallowed: a statement failed, so the
  transaction is aborted already, and hiding the error would only move the
  failure to the caller's next statement (or turn the confirmation into a
  silent rollback).
  """

  require Logger

  alias PhoenixKit.RepoHelper, as: Repo
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Users.WelcomeEmailWorker

  @setting "email_welcome_enabled"
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
  `after_confirmation/1` as a step of `multi`, after the step that confirms
  the user (`:user`) — so the job is inserted in the confirmation's own
  transaction.
  """
  @spec multi(Ecto.Multi.t()) :: Ecto.Multi.t()
  def multi(multi) do
    Ecto.Multi.run(multi, :welcome_email, fn _repo, %{user: user} ->
      {:ok, after_confirmation(user)}
    end)
  end

  # Oban not running on this node is the expected miss, told apart before any
  # SQL runs. Anything the insert itself raises inside a transaction is
  # re-raised: a statement failed, so the transaction is aborted already.
  defp enqueue(user) do
    if Oban.whereis(Oban) do
      insert(user)
    else
      log_failure(user, "Oban is not running on this node")
      :error
    end
  end

  defp insert(user) do
    case Oban.insert(WelcomeEmailWorker.new(%{"user_uuid" => user.uuid})) do
      {:ok, _job} ->
        :enqueued

      {:error, reason} ->
        log_failure(user, inspect(reason))
        :error
    end
  rescue
    error ->
      if Repo.repo().in_transaction?(), do: reraise(error, __STACKTRACE__)

      log_failure(user, Exception.message(error))
      :error
  catch
    :exit, reason ->
      if Repo.repo().in_transaction?(), do: exit(reason)

      log_failure(user, inspect(reason))
      :error
  end

  defp log_failure(user, reason) do
    Logger.error(
      "[PhoenixKit] Could not enqueue the welcome email for user #{inspect(user.uuid)}: #{reason}"
    )
  end
end

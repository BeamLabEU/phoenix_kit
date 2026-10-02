defmodule PhoenixKit.Users.WelcomeEmail do
  @moduledoc """
  The welcome email: sent once, after a user confirms their address.

  Off by default — the `email_welcome_enabled` setting, switched on under
  Settings → Emails Transactional → Branding. Its copy is core's `welcome`
  email (`PhoenixKit.Email.CoreTemplates.welcome_defaults/0`), overridable
  with files like any other.

  ## When it is sent

  `after_confirmation/1` is called by every path where a user proves they
  own their address — and by nothing else:

    * `Auth.confirm_user/1` — the link in the confirmation email;
    * `Auth.confirm_user_from_external_proof/1` — signing in with a magic
      link, or with an OAuth provider that verified the address, while the
      account is unconfirmed (a new OAuth account included);
    * magic-link registration, which confirms the new account itself.

  An administrator confirming an account by hand (`Auth.toggle_user_confirmation/2`,
  `Auth.admin_confirm_user/1`) sends nothing: the reader did not do anything,
  and an operator confirming imported accounts must not mail every one of
  them. `admin_confirm_user/1` stays silent for the same reason — magic-link
  registration calls this module itself, after it.

  ## Once

  Before sending, the account is claimed with one conditional `UPDATE` that
  records `welcome_email_sent_at` in its `custom_fields` only if it is not
  there yet. Postgres serialises concurrent updates of a row, so of two
  confirmations racing (two magic-link tabs) exactly one claims it, and a
  confirmation repeated later (an address unconfirmed and confirmed again)
  finds the mark and sends nothing. The mark is set before the send, so a
  send that fails is logged and not retried: at most once, never twice.

  ## Never in the way

  The send runs in the confirming request, after the confirmation is
  committed, and nothing it raises or exits with reaches the caller — the
  confirmation succeeds whatever happens to the email; a failure is logged.
  """

  import Ecto.Query, only: [from: 2]

  require Logger

  alias PhoenixKit.RepoHelper, as: Repo
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Users.Auth.UserNotifier

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
  Sends the welcome email to a user who has just confirmed their address,
  unless it is switched off or was already sent.

  Returns `:sent`, `:skipped` (off, already sent, not confirmed) or
  `:error` (logged). Never raises.
  """
  @spec after_confirmation(User.t() | term()) :: :sent | :skipped | :error
  def after_confirmation(%User{confirmed_at: %_{}} = user) do
    with true <- enabled?(),
         {:ok, claimed} <- claim(user) do
      deliver(claimed)
    else
      _ -> :skipped
    end
  rescue
    error ->
      log_failure(user, Exception.message(error))
      :error
  catch
    kind, reason ->
      log_failure(user, inspect({kind, reason}))
      :error
  end

  def after_confirmation(_user), do: :skipped

  # One statement: the mark is written only where it is absent, so the row
  # lock decides which of two racing confirmations sends.
  defp claim(user) do
    sent_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    query =
      from(u in User,
        where:
          u.uuid == ^user.uuid and not is_nil(u.confirmed_at) and
            fragment("(? -> ?) IS NULL", u.custom_fields, ^@sent_key),
        update: [
          set: [
            custom_fields:
              fragment(
                "COALESCE(?, '{}'::jsonb) || jsonb_build_object(?::text, ?::text)",
                u.custom_fields,
                ^@sent_key,
                ^sent_at
              )
          ]
        ],
        select: u
      )

    case Repo.update_all(query, []) do
      {1, [claimed]} -> {:ok, claimed}
      {0, _} -> :already_sent
    end
  end

  defp deliver(user) do
    case UserNotifier.deliver_welcome(user) do
      {:ok, _email} ->
        :sent

      {:error, reason} ->
        log_failure(user, inspect(reason))
        :error
    end
  end

  defp log_failure(user, reason) do
    Logger.error(
      "[PhoenixKit] Welcome email to user #{inspect(Map.get(user, :uuid))} failed: #{reason}"
    )
  end
end

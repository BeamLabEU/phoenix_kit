defmodule PhoenixKit.Users.WelcomeEmailWorker do
  @moduledoc """
  Sends one user's welcome email, after the confirmation that enqueued it has
  committed. See `PhoenixKit.Users.WelcomeEmail`.

  ## Job args

      %{"user_uuid" => "<uuid>"}

  ## What a run does

    1. Nothing, when the welcome email has been switched off since, or the
       user is gone or no longer confirmed.
    2. Claims the account: one conditional `UPDATE` writes
       `welcome_email_sent_at` into `custom_fields` only where it is absent.
       No row updated means it was sent already — done.
    3. Sends. A failed send clears the mark and returns the error, so Oban
       retries; a mark is only left behind by a send that went out.
  """

  use Oban.Worker,
    queue: :notifications,
    max_attempts: 3,
    # One job per user for as long as Oban keeps it; the claim in the user's
    # row is what holds for ever.
    unique: [keys: [:user_uuid], period: :infinity]

  import Ecto.Query, only: [from: 2]

  require Logger

  alias PhoenixKit.RepoHelper, as: Repo
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Users.Auth.UserNotifier
  alias PhoenixKit.Users.WelcomeEmail

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"user_uuid" => uuid}}) when is_binary(uuid) do
    if WelcomeEmail.enabled?(), do: claim_and_send(uuid), else: :ok
  end

  def perform(_job), do: :ok

  defp claim_and_send(uuid) do
    case claim(uuid) do
      {:ok, user} -> send_claimed(user)
      :not_claimed -> :ok
    end
  end

  defp send_claimed(user) do
    case UserNotifier.deliver_welcome(user) do
      {:ok, _email} ->
        :ok

      {:error, reason} ->
        release(user.uuid)
        log_failure(user.uuid, inspect(reason))
        {:error, reason}
    end
  rescue
    error ->
      release(user.uuid)
      log_failure(user.uuid, Exception.message(error))
      reraise error, __STACKTRACE__
  end

  # One statement: the mark is written only where it is absent and the
  # address is confirmed, so the row lock decides between racing runs.
  defp claim(uuid) do
    sent_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    key = WelcomeEmail.sent_key()

    query =
      from(u in User,
        where:
          u.uuid == ^uuid and not is_nil(u.confirmed_at) and
            fragment("(? -> ?) IS NULL", u.custom_fields, ^key),
        update: [
          set: [
            custom_fields:
              fragment(
                "COALESCE(?, '{}'::jsonb) || jsonb_build_object(?::text, ?::text)",
                u.custom_fields,
                ^key,
                ^sent_at
              )
          ]
        ],
        select: u
      )

    case Repo.update_all(query, []) do
      {1, [claimed]} -> {:ok, claimed}
      {0, _} -> :not_claimed
    end
  end

  defp release(uuid) do
    from(u in User,
      where: u.uuid == ^uuid,
      update: [set: [custom_fields: fragment("? - ?", u.custom_fields, ^WelcomeEmail.sent_key())]]
    )
    |> Repo.update_all([])
  end

  defp log_failure(uuid, reason) do
    Logger.error("[PhoenixKit] Welcome email to user #{inspect(uuid)} failed: #{reason}")
  end
end

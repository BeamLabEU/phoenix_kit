defmodule PhoenixKit.Users.WelcomeEmailWorker do
  @moduledoc """
  Sends one user's welcome email, after the confirmation that enqueued it has
  committed. See `PhoenixKit.Users.WelcomeEmail`.

  ## Job args

      %{"user_uuid" => "<uuid>"}

  ## What a run does

    1. Nothing, when the welcome email has been switched off since, or the
       user is gone. A deactivated user (`is_active` false) gets nothing
       either, with a line in the log.
    2. Claims the account: one conditional `UPDATE` writes
       `welcome_email_sent_at` into `custom_fields` only where it is absent
       and the address is confirmed. No row updated means it was sent
       already, or the address is no longer confirmed — done.
    3. Builds the message, then hands it to the mailer.

  ## At most once

  The mark is cleared — and the job retried — only when the message is known
  not to have gone out: building it failed (rendering, a template, the
  provider; raised, thrown or exited), or the mailer reported that it was not
  sent (`{:error, reason}`). A raise or exit *during* delivery leaves it unknown
  whether the message went out, so the mark stays, the error is logged and
  the job is cancelled rather than retried. So is a node that dies between
  the claim and the send: that welcome email is lost. Both are deliberate —
  a missing welcome email is a smaller harm than a second one.
  """

  # No `unique:` on purpose. Oban checks uniqueness inside a nested
  # transaction of its own, and a failed nested transaction marks the
  # caller's — the confirmation's — for rollback; the plain insert can be
  # guarded with a savepoint instead (`PhoenixKit.Users.WelcomeEmail`). A job
  # is enqueued once per real unconfirmed -> confirmed transition, and the
  # mark in the user's row keeps a second job (an address confirmed, unconfirmed
  # and confirmed again before the first ran) from sending a second email.
  use Oban.Worker, queue: :notifications, max_attempts: 3

  import Ecto.Query, only: [from: 2]

  require Logger

  alias PhoenixKit.RepoHelper, as: Repo
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Users.Auth.UserNotifier
  alias PhoenixKit.Users.WelcomeEmail

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"user_uuid" => uuid}} = job) when is_binary(uuid) do
    if WelcomeEmail.enabled?(), do: run(uuid, retry?(job)), else: :ok
  end

  def perform(_job), do: :ok

  defp retry?(%Oban.Job{attempt: attempt, max_attempts: max}), do: attempt < max

  defp run(uuid, retry?) do
    case Repo.get(User, uuid) do
      %User{is_active: false} ->
        Logger.warning("[PhoenixKit] Welcome email to user #{inspect(uuid)} skipped: deactivated")
        :ok

      %User{} ->
        claim_and_send(uuid, retry?)

      nil ->
        :ok
    end
  end

  defp claim_and_send(uuid, retry?) do
    case claim(uuid) do
      {:ok, user} -> build_and_send(user, retry?)
      :not_claimed -> :ok
    end
  end

  defp build_and_send(user, retry?) do
    case build(user) do
      {:ok, email} ->
        send_built(user, email, retry?)

      {:error, reason} ->
        not_sent(user, reason, retry?)
    end
  end

  # Before the mailer: whatever goes wrong here, nothing was sent.
  defp build(user) do
    {:ok, UserNotifier.build_welcome(user)}
  rescue
    error -> {:error, Exception.message(error)}
  catch
    kind, reason -> {:error, inspect({kind, reason})}
  end

  defp send_built(user, email, retry?) do
    case UserNotifier.deliver_built(email) do
      {:ok, _email} -> :ok
      {:error, reason} -> not_sent(user, inspect(reason), retry?)
    end
  rescue
    error -> unknown(user, Exception.message(error))
  catch
    kind, reason -> unknown(user, inspect({kind, reason}))
  end

  # Known not to have gone out: clear the mark so a retry, or a later
  # confirmation, can send it.
  defp not_sent(user, reason, retry?) do
    release(user.uuid)
    log_failure(user.uuid, reason <> if(retry?, do: " (will retry)", else: " (giving up)"))
    {:error, reason}
  end

  # It may have gone out: keep the mark, do not retry.
  defp unknown(user, reason) do
    log_failure(user.uuid, reason <> " (it may have been sent; not retried)")
    {:cancel, reason}
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

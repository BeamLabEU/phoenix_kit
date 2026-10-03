defmodule PhoenixKit.Integration.Users.WelcomeEmailTest do
  @moduledoc """
  The welcome email: off by default; enqueued in the confirmation's own
  transaction from each path where the reader confirms their address — and
  never from an administrator's confirmation; sent once, after the commit,
  by `WelcomeEmailWorker`.
  """

  # One test swaps the global `:email_provider`, and Oban runs under a fixed
  # name: not async.
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Users.Auth.UserToken
  alias PhoenixKit.Users.MagicLinkRegistration
  alias PhoenixKit.Users.OAuth
  alias PhoenixKit.Users.WelcomeEmail
  alias PhoenixKit.Users.WelcomeEmailWorker
  alias PhoenixKit.Utils.Routes

  @password "ValidPassword123!"

  defmodule RaisingProvider do
    @moduledoc false
    def get_active_template_by_name(_name), do: raise("provider down")
  end

  setup do
    # No Oban runs under `mix test` otherwise. `:manual` inserts the job row
    # (enforcing `unique:`) without running it; `run_jobs/0` runs them.
    start_supervised!(
      {Oban, name: Oban, repo: PhoenixKit.Test.Repo, testing: :manual, queues: [], plugins: []}
    )

    :ok
  end

  defp unique_email, do: "welcome_#{System.unique_integer([:positive])}@example.com"

  defp create_user do
    {:ok, user} = Auth.register_user(%{email: unique_email(), password: @password})
    user
  end

  defp enable, do: {:ok, _} = Settings.update_setting(WelcomeEmail.setting_key(), "true")

  defp confirmation_token(user) do
    {encoded, user_token} = UserToken.build_email_token(user, "confirm")
    Repo.insert!(user_token)
    encoded
  end

  defp jobs do
    Repo.all(
      from(j in Oban.Job, where: j.worker == "PhoenixKit.Users.WelcomeEmailWorker", select: j)
    )
  end

  defp run_jobs, do: Oban.drain_queue(queue: :notifications)

  # Every email this test process was sent, drained from the mailbox.
  defp sent_emails(acc \\ []) do
    receive do
      {:email, email} -> sent_emails([email | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp welcome_emails(address) do
    Enum.filter(sent_emails(), fn email ->
      email.to == [{"", address}] and email.subject =~ "Welcome to"
    end)
  end

  defp reload(user), do: Repo.get!(User, user.uuid)

  defp marked?(user),
    do: Map.has_key?(reload(user).custom_fields || %{}, WelcomeEmail.sent_key())

  defp oauth_auth(email) do
    %Ueberauth.Auth{
      provider: :google,
      uid: "uid_#{System.unique_integer([:positive])}",
      info: %Ueberauth.Auth.Info{email: email, first_name: "Test", last_name: "User"},
      credentials: %Ueberauth.Auth.Credentials{token: "at"},
      extra: %Ueberauth.Auth.Extra{
        raw_info: %{token: "tok", user: %{"email" => email, "email_verified" => true}}
      }
    }
  end

  describe "switched off (the default)" do
    test "confirming enqueues nothing, sends nothing, leaves no mark" do
      user = create_user()

      assert {:ok, _} = Auth.confirm_user(confirmation_token(user))

      assert jobs() == []
      run_jobs()
      assert welcome_emails(user.email) == []
      refute marked?(user)
    end

    test "a job enqueued before it was switched off sends nothing" do
      enable()
      user = create_user()
      assert {:ok, _} = Auth.confirm_user(confirmation_token(user))
      {:ok, _} = Settings.update_setting(WelcomeEmail.setting_key(), "false")

      run_jobs()
      assert welcome_emails(user.email) == []
    end
  end

  describe "switched on" do
    setup do
      enable()
      :ok
    end

    test "the confirmation link enqueues it; the job sends one, in the layout with a button" do
      user = create_user()

      assert {:ok, %User{confirmed_at: %_{}}} = Auth.confirm_user(confirmation_token(user))

      # Nothing is sent by the confirming request itself.
      assert welcome_emails(user.email) == []
      assert [%Oban.Job{args: %{"user_uuid" => uuid}}] = jobs()
      assert uuid == user.uuid

      assert %{success: 1} = run_jobs()
      assert [email] = welcome_emails(user.email)
      site_url = Routes.base_url()
      assert email.html_body =~ "<!DOCTYPE html>"
      assert email.html_body =~ ~s(<a href="#{site_url}" style="display:inline-block;)
      assert email.text_body =~ user.email
      refute email.text_body =~ "<"

      assert %{"welcome_email_sent_at" => sent_at} = reload(user).custom_fields
      assert {:ok, _, _} = DateTime.from_iso8601(sent_at)
    end

    test "confirming again later sends no second welcome email" do
      user = create_user()
      assert {:ok, confirmed} = Auth.confirm_user(confirmation_token(user))
      run_jobs()
      assert [_] = welcome_emails(user.email)

      # An administrator unconfirms the address; the reader confirms it again.
      {:ok, unconfirmed} = Auth.admin_unconfirm_user(confirmed)
      assert {:ok, _} = Auth.confirm_user(confirmation_token(unconfirmed))
      run_jobs()

      assert welcome_emails(user.email) == []
    end

    test "a magic-link sign-in that confirms the account sends it once" do
      user = create_user()

      assert {:ok, confirmed} = Auth.confirm_user_from_external_proof(user)
      # Already confirmed: nothing to confirm, nothing to enqueue.
      assert {:ok, _} = Auth.confirm_user_from_external_proof(confirmed)
      # A second tab with the stale, unconfirmed struct confirms again: the
      # job is unique per user.
      assert {:ok, _} = Auth.confirm_user_from_external_proof(user)

      assert [_] = jobs()
      run_jobs()
      assert [_] = welcome_emails(user.email)
    end

    test "an OAuth sign-in confirming the account enqueues it in the callback's transaction" do
      user = create_user()

      assert {:ok, %User{confirmed_at: %_{}}} =
               OAuth.handle_oauth_callback(oauth_auth(user.email))

      assert welcome_emails(user.email) == []
      assert [_] = jobs()
      run_jobs()
      assert [_] = welcome_emails(user.email)
    end

    test "a rollback after the OAuth callback takes the job with the confirmation" do
      user = create_user()

      assert {:error, :later_step_failed} =
               Repo.transaction(fn ->
                 {:ok, _} = OAuth.handle_oauth_callback(oauth_auth(user.email))
                 Repo.rollback(:later_step_failed)
               end)

      assert reload(user).confirmed_at == nil
      assert jobs() == []
      refute marked?(user)

      # The retried sign-in confirms, and the welcome email goes out once.
      assert {:ok, _} = OAuth.handle_oauth_callback(oauth_auth(user.email))
      run_jobs()
      assert [_] = welcome_emails(user.email)
    end

    test "a new OAuth account sends it once" do
      email = unique_email()

      assert {:ok, %User{confirmed_at: %_{}}} = OAuth.handle_oauth_callback(oauth_auth(email))
      run_jobs()
      assert [_] = welcome_emails(email)
    end

    test "an unconfirmed account correcting its address (Wrong email?) sends it to the new one" do
      user = create_user()
      new_email = unique_email()

      {:ok, applied} = Auth.apply_user_email(user, @password, %{email: new_email})

      {:ok, change_email} =
        Auth.deliver_user_update_email_instructions(
          applied,
          user.email,
          &"http://example.com/confirm_email/#{&1}"
        )

      [_, token] = Regex.run(~r/confirm_email\/([^\s"<)\]]+)/, change_email.text_body)

      assert :ok = Auth.update_user_email(user, token)
      run_jobs()
      assert [_] = welcome_emails(new_email)
    end

    test "a confirmed account changing its address sends nothing" do
      user = create_user()
      {:ok, confirmed} = Auth.admin_confirm_user(user)
      new_email = unique_email()

      {:ok, applied} = Auth.apply_user_email(confirmed, @password, %{email: new_email})

      {:ok, change_email} =
        Auth.deliver_user_update_email_instructions(
          applied,
          confirmed.email,
          &"http://example.com/confirm_email/#{&1}"
        )

      [_, token] = Regex.run(~r/confirm_email\/([^\s"<)\]]+)/, change_email.text_body)

      assert :ok = Auth.update_user_email(confirmed, token)
      assert jobs() == []
    end

    test "changing the password of a confirmed account enqueues nothing" do
      user = create_user()
      {:ok, confirmed} = Auth.admin_confirm_user(user)

      assert {:ok, _} =
               Auth.update_user_password(confirmed, @password, %{
                 password: "AnotherPassword456!",
                 password_confirmation: "AnotherPassword456!"
               })

      assert jobs() == []
    end

    test "magic-link registration sends it once, for the account it creates" do
      email = unique_email()
      {:ok, _email, token} = MagicLinkRegistration.send_registration_link(email)

      assert {:ok, %User{confirmed_at: %_{}}} =
               MagicLinkRegistration.complete_registration(token, %{"password" => @password})

      run_jobs()
      assert [_] = welcome_emails(email)
    end

    test "an administrator's confirmation enqueues nothing" do
      user = create_user()

      assert {:ok, %User{confirmed_at: %_{}}} = Auth.toggle_user_confirmation(user)

      assert jobs() == []
      assert WelcomeEmail.after_confirmation(%User{user | confirmed_at: nil}) == :skipped
    end

    # Sequential on one sandbox connection: this pins the conditional UPDATE
    # (a second claim finds the mark), not real concurrency — that rests on
    # Postgres' row lock under READ COMMITTED.
    test "a second run for the same user finds the mark and sends nothing" do
      user = create_user()
      {:ok, _confirmed} = Auth.admin_confirm_user(user)
      job = %Oban.Job{args: %{"user_uuid" => user.uuid}}

      assert :ok = WelcomeEmailWorker.perform(job)
      assert :ok = WelcomeEmailWorker.perform(job)
      assert [_] = welcome_emails(user.email)
    end

    test "with no Oban running the confirmation still succeeds, and says why in the log" do
      stop_supervised!(Oban)
      user = create_user()

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, %User{confirmed_at: %_{}}} = Auth.confirm_user(confirmation_token(user))
        end)

      assert log =~ "Could not enqueue the welcome email"
    end

    # The transaction is aborted by then: swallowing the error would only fail
    # the caller's next statement (25P02) — or, as the last step, turn the
    # confirmation into a silent rollback.
    test "a database error while enqueueing inside the confirmation's transaction is raised" do
      # An insert the database refuses — rolled back with the test's sandbox
      # transaction.
      Repo.query!(
        "ALTER TABLE oban_jobs ADD CONSTRAINT pk_test_refuse_welcome " <>
          "CHECK (worker <> 'PhoenixKit.Users.WelcomeEmailWorker')"
      )

      user = create_user()
      token = confirmation_token(user)

      assert_raise Ecto.ConstraintError, fn -> Auth.confirm_user(token) end
      assert reload(user).confirmed_at == nil
    end

    test "a send that fails clears the mark, so the job's retry can send it" do
      previous = Application.get_env(:phoenix_kit, :email_provider)
      Application.put_env(:phoenix_kit, :email_provider, __MODULE__.RaisingProvider)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:phoenix_kit, :email_provider, previous),
          else: Application.delete_env(:phoenix_kit, :email_provider)
      end)

      user = create_user()
      assert {:ok, %User{confirmed_at: %_{}}} = Auth.confirm_user(confirmation_token(user))

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert_raise RuntimeError, "provider down", fn ->
            WelcomeEmailWorker.perform(%Oban.Job{args: %{"user_uuid" => user.uuid}})
          end
        end)

      assert log =~ "Welcome email to user"
      refute marked?(user)

      Application.put_env(
        :phoenix_kit,
        :email_provider,
        previous || PhoenixKit.Email.DefaultProvider
      )

      assert :ok = WelcomeEmailWorker.perform(%Oban.Job{args: %{"user_uuid" => user.uuid}})
      assert [_] = welcome_emails(user.email)
      assert marked?(user)
    end
  end
end

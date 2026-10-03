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

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Users.Auth.UserToken
  alias PhoenixKit.Users.MagicLinkRegistration
  alias PhoenixKit.Users.OAuth
  alias PhoenixKit.Users.RoleAssignment
  alias PhoenixKit.Users.WelcomeEmail
  alias PhoenixKit.Users.WelcomeEmailWorker
  alias PhoenixKit.Utils.Routes

  @password "ValidPassword123!"

  defmodule RaisingProvider do
    @moduledoc false
    def get_active_template_by_name(_name), do: raise("provider down")
  end

  defmodule ExitingProvider do
    @moduledoc false
    def get_active_template_by_name(_name), do: exit(:provider_gone)
  end

  defmodule ThrowingProvider do
    @moduledoc false
    def get_active_template_by_name(_name), do: throw(:provider_threw)
  end

  # Fail after the message was handed over: whether it went out is unknown.
  defmodule RaisingAdapter do
    @moduledoc false
    use Swoosh.Adapter

    @impl true
    def deliver(_email, _config), do: raise("connection reset after DATA")
  end

  defmodule ExitingAdapter do
    @moduledoc false
    use Swoosh.Adapter

    @impl true
    def deliver(_email, _config), do: exit(:timeout)
  end

  defp put_env_for_test(key, value) do
    previous = Application.get_env(:phoenix_kit, key)
    Application.put_env(:phoenix_kit, key, value)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:phoenix_kit, key, previous),
        else: Application.delete_env(:phoenix_kit, key)
    end)
  end

  defp perform(user), do: WelcomeEmailWorker.perform(%Oban.Job{args: %{"user_uuid" => user.uuid}})

  setup do
    # No Oban runs under `mix test` otherwise. `:manual` inserts the job row
    # without running it; `run_jobs/0` runs them.
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
      # A second tab with the stale, unconfirmed struct confirms again, but
      # the row is no longer unconfirmed: no transition, no job.
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

      assert :ok = perform(user)
      assert :ok = perform(user)
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

    # Nothing about the welcome email fails a confirmation: the insert runs
    # under its own savepoint, so a statement the database refuses rolls back
    # only that savepoint.
    defp refuse_welcome_jobs do
      Repo.query!(
        "ALTER TABLE oban_jobs ADD CONSTRAINT pk_test_refuse_welcome " <>
          "CHECK (worker <> 'PhoenixKit.Users.WelcomeEmailWorker')"
      )
    end

    test "an enqueue the database refuses: the confirmation link still confirms, without a job" do
      refuse_welcome_jobs()
      user = create_user()
      token = confirmation_token(user)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, %User{confirmed_at: %_{}}} = Auth.confirm_user(token)
        end)

      assert log =~ "Could not enqueue the welcome email"
      assert reload(user).confirmed_at
      assert jobs() == []
    end

    test "an enqueue the database refuses: a magic-link or OAuth confirmation still confirms" do
      refuse_welcome_jobs()
      user = create_user()

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, %User{confirmed_at: %_{}}} = Auth.confirm_user_from_external_proof(user)
        end)

      assert log =~ "Could not enqueue the welcome email"
      assert reload(user).confirmed_at
      assert jobs() == []
    end

    test "building the email fails: the mark is cleared and the retry sends it" do
      put_env_for_test(:email_provider, __MODULE__.RaisingProvider)
      user = create_user()
      assert {:ok, %User{confirmed_at: %_{}}} = Auth.confirm_user(confirmation_token(user))

      log = ExUnit.CaptureLog.capture_log(fn -> assert {:error, _} = perform(user) end)

      assert log =~ "provider down (will retry)"
      refute marked?(user)

      Application.delete_env(:phoenix_kit, :email_provider)
      assert :ok = perform(user)
      assert [_] = welcome_emails(user.email)
      assert marked?(user)
    end

    test "the mailer refuses it: the mark is cleared and the retry sends one" do
      user = create_user()
      assert {:ok, _} = Auth.confirm_user(confirmation_token(user))

      # A default send integration missing a required field: the mailer
      # answers {:error, _} without handing the message to anyone.
      {:ok, %{uuid: uuid}} = PhoenixKit.Integrations.add_connection("smtp", "half relay")

      {:ok, _} =
        PhoenixKit.Integrations.save_setup(uuid, %{
          "host" => "smtp.example.com",
          "port" => "587",
          "username" => "user",
          "password" => "pw"
        })

      :ok = PhoenixKit.Integrations.record_validation(uuid, :ok)
      {:ok, _} = Settings.update_setting("default_email_integration_uuid", uuid)
      {:ok, _} = PhoenixKit.Integrations.save_setup(uuid, %{"host" => ""})

      log = ExUnit.CaptureLog.capture_log(fn -> assert {:error, _} = perform(user) end)
      assert log =~ "will retry"
      refute marked?(user)

      {:ok, _} = Settings.update_setting("default_email_integration_uuid", "")
      assert :ok = perform(user)
      assert [_] = welcome_emails(user.email)
    end

    test "delivery raises: the mark stays and the job is cancelled, never retried" do
      user = create_user()
      assert {:ok, _} = Auth.confirm_user(confirmation_token(user))
      put_env_for_test(PhoenixKit.Mailer, adapter: __MODULE__.RaisingAdapter)

      log = ExUnit.CaptureLog.capture_log(fn -> assert {:cancel, _} = perform(user) end)

      assert log =~ "it may have been sent; not retried"
      assert marked?(user)
    end

    test "an address unconfirmed again before the job runs gets nothing" do
      user = create_user()
      assert {:ok, confirmed} = Auth.confirm_user(confirmation_token(user))
      {:ok, _} = Auth.admin_unconfirm_user(confirmed)

      run_jobs()
      assert welcome_emails(user.email) == []
      refute marked?(user)
    end

    test "a user deactivated before the job runs gets nothing" do
      user = create_user()
      assert {:ok, confirmed} = Auth.confirm_user(confirmation_token(user))
      {:ok, _} = confirmed |> Ecto.Changeset.change(is_active: false) |> Repo.update()

      log = ExUnit.CaptureLog.capture_log(fn -> run_jobs() end)

      assert log =~ "skipped: deactivated"
      assert welcome_emails(user.email) == []
      refute marked?(user)
    end

    test "an old confirmation link clicked after an administrator confirmed enqueues nothing" do
      user = create_user()
      token = confirmation_token(user)
      {:ok, _} = Auth.admin_confirm_user(user)

      assert {:ok, _} = Auth.confirm_user(token)
      assert jobs() == []
    end

    test "delivery exits: the mark stays and the job is cancelled" do
      user = create_user()
      assert {:ok, _} = Auth.confirm_user(confirmation_token(user))
      put_env_for_test(PhoenixKit.Mailer, adapter: __MODULE__.ExitingAdapter)

      log = ExUnit.CaptureLog.capture_log(fn -> assert {:cancel, _} = perform(user) end)

      assert log =~ "it may have been sent; not retried"
      assert marked?(user)
    end

    for {provider, label} <- [{ExitingProvider, "exits"}, {ThrowingProvider, "throws"}] do
      test "building the email #{label}: the mark is cleared for a retry" do
        put_env_for_test(:email_provider, unquote(provider))
        user = create_user()
        assert {:ok, _} = Auth.confirm_user(confirmation_token(user))

        log = ExUnit.CaptureLog.capture_log(fn -> assert {:error, _} = perform(user) end)

        assert log =~ "(will retry)"
        refute marked?(user)
      end
    end

    test "the last attempt says it gives up" do
      put_env_for_test(:email_provider, __MODULE__.RaisingProvider)
      user = create_user()
      assert {:ok, _} = Auth.confirm_user(confirmation_token(user))
      job = %Oban.Job{args: %{"user_uuid" => user.uuid}, attempt: 3, max_attempts: 3}

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, _} = WelcomeEmailWorker.perform(job)
        end)

      assert log =~ "(giving up)"
      refute log =~ "(will retry)"
    end

    test "Wrong email? after an administrator confirmed the account in between enqueues nothing" do
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
      {:ok, _} = Auth.admin_confirm_user(user)

      # The struct still says unconfirmed; the row no longer is.
      assert :ok = Auth.update_user_email(user, token)
      assert jobs() == []
    end

    test "oban_jobs locked by another connection: the confirmation commits without a job" do
      parent = self()

      holder =
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            Repo.transaction(fn ->
              Repo.query!("LOCK TABLE oban_jobs IN ACCESS EXCLUSIVE MODE")
              send(parent, :locked)

              receive do
                :release -> :ok
              after
                30_000 -> :ok
              end
            end)
          end)
        end)

      assert_receive :locked, 10_000
      user = create_user()
      token = confirmation_token(user)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, %User{confirmed_at: %_{}}} = Auth.confirm_user(token)
        end)

      send(holder.pid, :release)
      Task.await(holder, 15_000)

      assert log =~ "Could not enqueue the welcome email"
      assert log =~ "lock"
      assert reload(user).confirmed_at
      assert jobs() == []
    end

    test "a job that ran while it was switched off does not block a later one" do
      user = create_user()
      assert {:ok, confirmed} = Auth.confirm_user(confirmation_token(user))
      {:ok, _} = Settings.update_setting(WelcomeEmail.setting_key(), "false")
      run_jobs()
      assert welcome_emails(user.email) == []

      enable()
      {:ok, unconfirmed} = Auth.admin_unconfirm_user(confirmed)
      assert {:ok, _} = Auth.confirm_user(confirmation_token(unconfirmed))
      assert length(jobs()) == 2

      run_jobs()
      assert [_] = welcome_emails(user.email)
    end
  end

  # On real connections, outside the sandbox: the only way two transactions
  # can race. A third connection holds the user's row while both start, so
  # both read it only after it is released — one after the other, thanks to
  # `track_transition/2`'s lock, or both as unconfirmed without it.
  describe "two confirmations of one stale struct, on separate connections" do
    defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)

    setup do
      previous = unboxed(fn -> Settings.get_setting(WelcomeEmail.setting_key()) end)
      unboxed(fn -> {:ok, _} = Settings.update_setting(WelcomeEmail.setting_key(), "true") end)

      user =
        unboxed(fn ->
          {:ok, user} = Auth.register_user(%{email: unique_email(), password: @password})
          user
        end)

      on_exit(fn ->
        unboxed(fn ->
          Repo.delete_all(
            from(j in Oban.Job, where: fragment("?->>'user_uuid' = ?", j.args, ^user.uuid))
          )

          Repo.delete_all(from(t in UserToken, where: t.user_uuid == ^user.uuid))
          Repo.delete_all(from(a in RoleAssignment, where: a.user_uuid == ^user.uuid))
          Repo.delete_all(from(u in User, where: u.uuid == ^user.uuid))
          {:ok, _} = Settings.update_setting(WelcomeEmail.setting_key(), previous || "false")
        end)
      end)

      %{user: user}
    end

    test "enqueue one job", %{user: user} do
      parent = self()

      holder =
        Task.async(fn ->
          unboxed(fn ->
            Repo.transaction(fn ->
              Repo.one!(
                from(u in User, where: u.uuid == ^user.uuid, lock: "FOR UPDATE", select: u.uuid)
              )

              send(parent, :held)

              receive do
                :release -> :ok
              after
                30_000 -> :ok
              end
            end)
          end)
        end)

      assert_receive :held, 10_000

      racers =
        for _ <- 1..2 do
          Task.async(fn -> unboxed(fn -> Auth.confirm_user_from_external_proof(user) end) end)
        end

      # Both are waiting on the held row by now.
      Process.sleep(500)
      send(holder.pid, :release)
      Task.await(holder, 15_000)

      assert [{:ok, _}, {:ok, _}] = Task.await_many(racers, 15_000)

      jobs =
        unboxed(fn ->
          Repo.all(
            from(j in Oban.Job,
              where:
                j.worker == "PhoenixKit.Users.WelcomeEmailWorker" and
                  fragment("?->>'user_uuid' = ?", j.args, ^user.uuid)
            )
          )
        end)

      assert length(jobs) == 1
    end
  end
end

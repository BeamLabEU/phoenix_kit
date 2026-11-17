defmodule PhoenixKitWeb.OAuth.ConnectedMailTest do
  @moduledoc """
  The email that tells a person an application was connected to their account: sent once, when the
  code is exchanged, for a connection that works at once and for one that waits for approval; not
  sent to an account that may not get automated mail; a failure of the delivery does not touch
  the exchange; the subject does not carry the application's own name.
  """
  use PhoenixKitWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import PhoenixKit.API.OAuthFlowSupport
  import PhoenixKit.API.OAuthTestSupport, only: [enable_oauth!: 0]
  import PhoenixKit.Test.ApiHarness, only: [put_setting: 2, setup_api: 0]

  alias PhoenixKit.API.OAuth.Client
  alias PhoenixKit.API.OAuth.ConnectedMail
  alias PhoenixKit.API.OAuth.Grant
  alias PhoenixKit.Test.Repo
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Users.Auth.UserNotifier
  alias PhoenixKit.Utils.Routes

  @read "testkit.items:read"
  @write "testkit.items:write"

  defmodule RaisingAdapter do
    @moduledoc false
    use Swoosh.Adapter

    def deliver(_email, _config), do: raise("the mail server is down")
  end

  setup do
    setup_api()
    enable_oauth!()
    put_setting("api_oauth_client_policy", "approval")
    {user, _role} = holder(["dashboard", "settings"])

    app =
      Repo.insert!(%Client{
        kind: "dcr",
        client_id: "dcr_mail_#{System.unique_integer([:positive])}",
        client_name: "Mail Agent",
        redirect_uris: ["https://app.example/cb"]
      })

    %{user: user, app: app}
  end

  # The suites run the delivery in the calling process (config/test.exs); the task itself is
  # tested here, each test waiting for the one it starts.
  defp run_on_a_task do
    previous = Application.get_env(:phoenix_kit, :oauth_connected_mail)
    Application.delete_env(:phoenix_kit, :oauth_connected_mail)
    on_exit(fn -> Application.put_env(:phoenix_kit, :oauth_connected_mail, previous) end)
  end

  defp connect!(user, client) do
    flow = code_for(user, client, [@read, @write])
    answer = exchange_code(flow)
    assert answer.status == 200
    %{flow: flow, tokens: body(answer)}
  end

  # The delivery runs on its own; its message is the test's own, the mailer sends it to the
  # callers of the task.
  defp await_mail do
    assert_receive {:email, email}, 2_000
    email
  end

  describe "a connection that works at once" do
    test "tells the person once, when the code is exchanged", %{user: user, app: app} do
      put_setting("api_oauth_client_allow_hosts", "app.example")
      %{tokens: tokens} = connect!(user, app)

      email = await_mail()
      assert [{_name, address}] = email.to
      assert address == user.email
      assert email.text_body =~ ~s("Mail Agent")
      assert email.text_body =~ "app.example"
      assert email.text_body =~ "State: Works"
      refute email.text_body =~ "waiting"
      refute email.text_body =~ tokens["access_token"]
      refute email.text_body =~ tokens["refresh_token"]

      # A refresh is not a connection: no second mail.
      assert refresh(app, tokens["refresh_token"]).status == 200
      refute_receive {:email, _}, 200
    end

    test "says what the rights are, the expiry, the time and the link to the keys page", %{
      user: user,
      app: app
    } do
      put_setting("api_oauth_client_allow_hosts", "app.example")
      connect!(user, app)

      email = await_mail()
      assert email.text_body =~ "Rights:"
      assert email.text_body =~ "Valid until:"
      assert email.text_body =~ "Time:"
      assert email.text_body =~ Routes.url("/profile/settings/api-keys")
      assert email.html_body =~ ~s(style="display:inline-block;)
    end

    test "has a subject without the name the application gave itself", %{user: user, app: app} do
      put_setting("api_oauth_client_allow_hosts", "app.example")
      connect!(user, app)

      email = await_mail()
      assert email.subject == "An application was connected to your account"
      refute email.subject =~ "Mail Agent"
    end

    test "shows the name in quotes, cut to 60 characters, beside the sentence that it is unchecked",
         %{user: user} do
      put_setting("api_oauth_client_allow_hosts", "app.example")
      long = String.duplicate("a", 59) <> "BCDEFGH Security notice: call +1 555 0100 now"

      app =
        Repo.insert!(%Client{
          kind: "dcr",
          client_id: "dcr_mail_long_#{System.unique_integer([:positive])}",
          client_name: long,
          redirect_uris: ["https://app.example/cb"]
        })

      connect!(user, app)

      email = await_mail()
      assert email.text_body =~ ~s("#{String.duplicate("a", 59)}B…")
      refute email.text_body =~ "Security notice"
      refute email.text_body =~ "BCDEFGH"
      assert email.text_body =~ "has not been checked"
    end

    test "drops quote characters from the name so it cannot close its own quotes", %{user: user} do
      put_setting("api_oauth_client_allow_hosts", "app.example")

      app =
        Repo.insert!(%Client{
          kind: "dcr",
          client_id: "dcr_mail_quotes_#{System.unique_integer([:positive])}",
          client_name: ~s(Agent" Call +1 555 0100 “now” „x“ «y»),
          redirect_uris: ["https://app.example/cb"]
        })

      connect!(user, app)

      email = await_mail()
      assert email.text_body =~ ~s("Agent Call +1 555 0100 now x y")
      refute email.text_body =~ ~r/[“”„«»]/u
    end

    test "writes a name with markup as text, never as markup", %{user: user} do
      put_setting("api_oauth_client_allow_hosts", "app.example")

      app =
        Repo.insert!(%Client{
          kind: "dcr",
          client_id: "dcr_mail_markup_#{System.unique_integer([:positive])}",
          client_name: "[Disconnect](https://evil.example/x) <b>now</b>",
          redirect_uris: ["https://app.example/cb"]
        })

      connect!(user, app)

      email = await_mail()
      refute email.html_body =~ ~s(href="https://evil.example)
      refute email.html_body =~ "<b>now</b>"
      assert email.html_body =~ "&lt;b&gt;now&lt;/b&gt;"
    end
  end

  describe "a connection that waits for approval" do
    test "tells the person too, and says it waits", %{user: user, app: app} do
      connect!(user, app)

      email = await_mail()
      assert email.text_body =~ "Waiting for approval by the owner of the system"
      refute email.text_body =~ "State: Works"
    end
  end

  describe "who gets it" do
    # A person who is not confirmed cannot sign in to consent, but the check is the notifier's own
    # and holds for every sender: the same one the other automated emails take.
    test "not an account that may not get automated mail", %{user: user} do
      user |> Ecto.Changeset.change(confirmed_at: nil) |> Repo.update!()
      put_setting("require_email_confirmation", "true")
      unconfirmed = Repo.get!(User, user.uuid)

      attrs = %{
        name: "Mail Agent",
        host: "app.example",
        rights: [],
        expires_at: DateTime.utc_now(),
        at: DateTime.utc_now(),
        ip: nil,
        waiting?: false
      }

      assert {:ok, %{suppressed: true}} = UserNotifier.deliver_app_connected(unconfirmed, attrs)
      refute_receive {:email, _}, 100
    end
  end

  describe "a failure of the delivery" do
    setup do
      previous = Application.get_env(:phoenix_kit, PhoenixKit.Mailer)
      Application.put_env(:phoenix_kit, PhoenixKit.Mailer, adapter: RaisingAdapter)

      on_exit(fn -> Application.put_env(:phoenix_kit, PhoenixKit.Mailer, previous) end)
    end

    test "does not break the exchange", %{user: user, app: app} do
      capture_log(fn ->
        flow = code_for(user, app, [@read])
        answer = exchange_code(flow)

        assert answer.status == 200
        assert %{"access_token" => _, "refresh_token" => _} = body(answer)
        assert %Grant{activated_at: %DateTime{}} = Repo.one!(Grant)

        refute_receive {:email, _}, 200
      end)
    end

    test "on its own task is logged by its kind, without the request's values", %{
      user: user,
      app: app
    } do
      put_setting("api_oauth_client_allow_hosts", "app.example")

      capture_log(fn -> connect!(user, app) end)
      grant = Repo.one!(Grant)
      run_on_a_task()

      log =
        capture_log(fn ->
          assert {:ok, pid} = ConnectedMail.start(grant, "https://app.example/cb")
          ref = Process.monitor(pid)
          assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
        end)

      assert log =~ "OAuth connection mail failed"
      refute log =~ "the mail server is down"
      refute log =~ "Mail Agent"
      refute log =~ "app.example"
    end
  end

  describe "start/2" do
    test "delivers from a task of its own, which the caller does not wait for", %{
      user: user,
      app: app
    } do
      put_setting("api_oauth_client_allow_hosts", "app.example")
      connect!(user, app)
      assert_receive {:email, _inline}
      grant = Repo.one!(Grant)
      run_on_a_task()

      assert {:ok, pid} = ConnectedMail.start(grant, "https://app.example/cb")
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000

      assert_received {:email, email}
      assert email.subject == "An application was connected to your account"
    end

    test "ends quietly for a person who is gone, and says so in the log" do
      run_on_a_task()
      grant = %Grant{user_uuid: UUIDv7.generate(), scopes: []}

      log =
        capture_log(fn ->
          assert {:ok, pid} = ConnectedMail.start(grant, "https://app.example/cb")
          ref = Process.monitor(pid)
          assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
        end)

      assert log =~ "OAuth connection mail not sent"
    end
  end
end

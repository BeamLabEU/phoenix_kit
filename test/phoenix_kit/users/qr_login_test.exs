defmodule PhoenixKit.Users.QrLoginTest do
  @moduledoc """
  Covers the PhoenixKit-side QR device-handoff wrapper end to end: the
  mint → approve → consume rendezvous (routed through PhoenixKit's internal
  PubSub), single-use enforcement, and the best-effort location formatter.

  `:phoenix_kit_internal_pubsub` is started by the test helper; the keyfob
  ETS store is started per-test (async: false — it's a named process).
  """
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Users.QrLogin

  setup do
    start_supervised!(Keyfob.Store.ETS)
    # location_for/1 runs the geo lookup under this Task.Supervisor (started
    # by PhoenixKit.Supervisor in a real app, but not in the bare test env).
    start_supervised!({Task.Supervisor, name: PhoenixKit.TaskSupervisor})

    user =
      %User{}
      |> Ecto.Changeset.change(%{
        email: "qr-#{System.unique_integer([:positive])}@example.com",
        hashed_password: "unused-for-qr"
      })
      |> Repo.insert!()

    %{user_uuid: user.uuid}
  end

  describe "create_request/approve/consume" do
    test "approve broadcasts a login token that consumes to the user, exactly once", %{
      user_uuid: uuid
    } do
      {:ok, %{token: token}} = QrLogin.create_request(meta: %{browser: "Chrome"})
      :ok = QrLogin.subscribe(token)

      assert {:ok, %{state: :pending, meta: %{browser: "Chrome"}}} = QrLogin.peek(token)

      assert :ok = QrLogin.approve(token, uuid)
      assert_receive {:keyfob, ^token, {:approved, login_token}}

      # The QR-borne request token is NOT a credential — only the minted
      # login token consumes, and only once.
      refute login_token == token
      assert {:ok, ^uuid} = QrLogin.consume(login_token)
      assert {:error, :not_found} = QrLogin.consume(login_token)
    end

    test "the request token itself cannot be consumed", %{user_uuid: uuid} do
      {:ok, %{token: token}} = QrLogin.create_request()
      :ok = QrLogin.approve(token, uuid)
      assert {:error, :not_found} = QrLogin.consume(token)
    end

    test "deny broadcasts and prevents later approval", %{user_uuid: uuid} do
      {:ok, %{token: token}} = QrLogin.create_request()
      :ok = QrLogin.subscribe(token)

      assert :ok = QrLogin.deny(token)
      assert_receive {:keyfob, ^token, :denied}
      assert {:error, :not_found} = QrLogin.approve(token, uuid)
    end
  end

  describe "location_for/1" do
    test "returns nil for nil and non-routable/placeholder IPs (no network call)" do
      assert QrLogin.location_for(nil) == nil
      assert QrLogin.location_for("") == nil
      assert QrLogin.location_for("unknown") == nil
      assert QrLogin.location_for("127.0.0.1") == nil
    end
  end
end

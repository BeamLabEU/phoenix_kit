defmodule PhoenixKit.API.OAuth.ClientsTest do
  @moduledoc """
  The pre-registered client: what an administrator may enter (the redirect addresses and the
  `client_id` are checked, nothing a database cannot hold reaches it) and the lookup by the
  `client_id` a stranger presents.
  """
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.API.OAuth.Client
  alias PhoenixKit.API.OAuth.Clients

  defp attrs(extra \\ %{}) do
    Map.merge(
      %{
        client_id: "pre-#{System.unique_integer([:positive])}",
        client_name: "Tool",
        redirect_uris: ["https://client.example/callback"]
      },
      extra
    )
  end

  defp errors(changeset), do: Map.new(changeset.errors, fn {field, {msg, _}} -> {field, msg} end)

  describe "register_preregistered/1" do
    test "keeps a client with https and loopback redirects" do
      uris = ["https://client.example/callback", "http://127.0.0.1:7777/cb", "http://[::1]/cb"]

      assert {:ok, %Client{kind: "preregistered", redirect_uris: ^uris}} =
               Clients.register_preregistered(attrs(%{redirect_uris: uris}))
    end

    test "a client without redirect addresses is still a client" do
      assert {:ok, %Client{redirect_uris: []}} =
               Clients.register_preregistered(attrs(%{redirect_uris: []}))
    end

    test "refuses every redirect address a code must never be sent to, and stores nothing" do
      for bad <- [
            "*",
            "https://*.client.example/cb",
            "http://client.example/cb",
            "javascript:alert(1)",
            "https://client.example/cb#fragment",
            "https://client.example/cb\0",
            "cursor://callback"
          ] do
        assert {:error, changeset} =
                 Clients.register_preregistered(attrs(%{redirect_uris: [bad]}))

        assert %{redirect_uris: _} = errors(changeset), inspect(bad)
      end

      assert {:error, changeset} =
               Clients.register_preregistered(
                 attrs(%{
                   redirect_uris: ["https://client.example/ok", "http://client.example/no"]
                 })
               )

      assert %{redirect_uris: _} = errors(changeset)
      assert Repo.all(Client) == []
    end

    test "a client_id or home page a database cannot hold is an error, not a raised query" do
      # A name is not here: `Clients.clean_name/1` strips what it cannot keep (clients_resolve_test).
      for field <- [:client_id, :client_uri] do
        for bad <- ["a\0b", <<0xFF, ?a>>] do
          assert {:error, changeset} = Clients.register_preregistered(attrs(%{field => bad}))
          assert Map.has_key?(errors(changeset), field), "#{field} #{inspect(bad)}"
        end
      end
    end

    test "a client_id is required, bounded and unique" do
      assert {:error, changeset} = Clients.register_preregistered(attrs(%{client_id: nil}))
      assert %{client_id: _} = errors(changeset)

      assert {:error, changeset} =
               Clients.register_preregistered(attrs(%{client_id: String.duplicate("a", 2049)}))

      assert %{client_id: _} = errors(changeset)

      assert {:ok, client} = Clients.register_preregistered(attrs())

      assert {:error, changeset} =
               Clients.register_preregistered(attrs(%{client_id: client.client_id}))

      assert errors(changeset) == %{client_id: "has already been taken"}
    end
  end

  describe "get_by_client_id/1" do
    test "finds a client by the id it presents" do
      {:ok, client} = Clients.register_preregistered(attrs())
      assert %Client{uuid: uuid} = Clients.get_by_client_id(client.client_id)
      assert uuid == client.uuid
    end

    test "text the table cannot hold finds nothing instead of raising" do
      assert Clients.get_by_client_id("a\0b") == nil
      assert Clients.get_by_client_id(<<0xFF, ?a>>) == nil
      assert Clients.get_by_client_id(5) == nil
    end
  end
end

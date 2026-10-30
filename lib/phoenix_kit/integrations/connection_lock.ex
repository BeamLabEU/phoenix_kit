defmodule PhoenixKit.Integrations.ConnectionLock do
  @moduledoc false

  import Ecto.Query

  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Settings.Setting

  # Both credential mutations and bucket attachment take this lock before
  # reading the connection. Nothing cached is used for the ownership check.
  # The row lock works through transaction-pooling PgBouncer too.
  def run(uuid, fun) when is_function(fun, 0) do
    repo = RepoHelper.repo()

    repo.transaction(fn ->
      if is_binary(uuid) and match?({:ok, _}, Ecto.UUID.cast(uuid)) do
        repo.one(from(s in Setting, where: s.uuid == ^uuid, lock: "FOR UPDATE"), log: false)
      end

      case fun.() do
        {:error, reason} -> repo.rollback(reason)
        result -> result
      end
    end)
    |> case do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end
end

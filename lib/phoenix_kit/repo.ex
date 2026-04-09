defmodule PhoenixKit.Repo do
  use Ecto.Repo,
    otp_app: :phoenix_kit,
    adapter: Ecto.Adapters.Postgres
end

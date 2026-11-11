defmodule PhoenixKit.Users.Auth.Passkey do
  @moduledoc """
  A person's passkey: one WebAuthn credential (V231, `phoenix_kit_user_passkeys`).

  Holds the public half only. `public_key` is the COSE key in its standard CBOR
  encoding (`encode_public_key/1`, `decode_public_key/1`), so the rows stay readable
  outside this library. `rp_id` is the domain the passkey was made for: it works there
  and nowhere else (`PhoenixKit.Users.Passkeys.usable?/1`).

  Written through `PhoenixKit.Users.Passkeys` only.
  """
  use Ecto.Schema
  use PhoenixKit.SchemaPrefix

  import Ecto.Changeset

  alias PhoenixKit.Users.Auth.User

  @primary_key {:uuid, UUIDv7, autogenerate: true}

  # What a browser may report (WebAuthn `AuthenticatorTransport`); anything else is
  # dropped rather than stored.
  @transports ~w(usb nfc ble smart-card hybrid internal)

  @type t :: %__MODULE__{}

  schema "phoenix_kit_user_passkeys" do
    field :credential_id, :binary
    field :public_key, :binary
    field :sign_count, :integer, default: 0
    field :rp_id, :string
    field :transports, {:array, :string}, default: []
    field :backup_eligible, :boolean, default: false
    field :name, :string
    field :last_used_at, :utc_datetime

    belongs_to :user, User, foreign_key: :user_uuid, references: :uuid, type: UUIDv7

    timestamps(type: :utc_datetime)
  end

  @doc false
  def create_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [
      :user_uuid,
      :credential_id,
      :public_key,
      :sign_count,
      :rp_id,
      :transports,
      :backup_eligible,
      :name
    ])
    |> update_change(:transports, &clean_transports/1)
    |> validate_required([:user_uuid, :credential_id, :public_key, :rp_id, :name])
    |> validate_name()
    |> unique_constraint(:credential_id, name: :phoenix_kit_user_passkeys_credential_id_index)
  end

  @doc false
  def rename_changeset(passkey, name) do
    passkey |> cast(%{name: name}, [:name]) |> validate_required([:name]) |> validate_name()
  end

  @doc false
  def used_changeset(passkey, sign_count, now) do
    change(passkey, sign_count: sign_count, last_used_at: now)
  end

  defp validate_name(changeset) do
    changeset
    |> update_change(:name, &String.trim/1)
    |> validate_length(:name, min: 1, max: 100)
  end

  defp clean_transports(list) when is_list(list),
    do: list |> Enum.filter(&(&1 in @transports)) |> Enum.uniq()

  defp clean_transports(_), do: []

  @doc """
  The COSE key (a map of integer labels to integers and byte strings) in CBOR.
  Byte strings are tagged as such, so they do not come back as text.
  """
  @spec encode_public_key(map()) :: binary()
  def encode_public_key(cose_key) when is_map(cose_key) do
    cose_key
    |> Map.new(fn
      {k, v} when is_binary(v) -> {k, %CBOR.Tag{tag: :bytes, value: v}}
      pair -> pair
    end)
    |> CBOR.encode()
  end

  @doc "The inverse of `encode_public_key/1`."
  @spec decode_public_key(binary()) :: {:ok, map()} | :error
  def decode_public_key(cbor) when is_binary(cbor) do
    case CBOR.decode(cbor) do
      {:ok, %{} = map, ""} ->
        {:ok,
         Map.new(map, fn
           {k, %CBOR.Tag{tag: :bytes, value: v}} -> {k, v}
           pair -> pair
         end)}

      _ ->
        :error
    end
  rescue
    _ -> :error
  end
end

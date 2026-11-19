defmodule PhoenixKitWeb.Components.PeoplePicker.UserSourceTest do
  @moduledoc """
  The default source answers anyone who can render a picker, so it follows
  core's other people search (`PhoenixKit.Mentions.Users`): confirmed
  accounts only, no email on a row, and the address matched only from its
  start.
  """
  use PhoenixKit.DataCase, async: true

  alias Ecto.Changeset
  alias PhoenixKit.Users.Auth
  alias PhoenixKitWeb.Components.PeoplePicker.UserSource

  defp user!(first, opts \\ []) do
    tag = System.unique_integer([:positive])

    {:ok, user} =
      Auth.register_user(%{
        email: "#{String.downcase(first)}_#{tag}@picker-domain-#{tag}.example",
        password: "ValidPassword123!"
      })

    {:ok, user} =
      Auth.update_user_profile(user, %{"first_name" => first, "last_name" => "Pick#{tag}"})

    if Keyword.get(opts, :confirmed, true) do
      user
      |> Changeset.change(confirmed_at: DateTime.truncate(DateTime.utc_now(), :second))
      |> Repo.update!()
    else
      user
    end
  end

  defp search(text) do
    {rows, _next} = UserSource.page({:search, text}, nil, 50, %{})
    rows
  end

  test "an unconfirmed sign-up is neither listed nor described" do
    user = user!("Unproven", confirmed: false)

    refute Enum.any?(search(user.last_name), &(&1.uuid == user.uuid))
    assert UserSource.describe({"user", user.uuid}, %{}) == nil
  end

  test "a confirmed account is found by name, and its row carries no email" do
    user = user!("Visible")

    assert [row] = Enum.filter(search(user.last_name), &(&1.uuid == user.uuid))
    refute row.sublabel == user.email
    refute inspect(Map.drop(row, [:user])) =~ user.email
  end

  test "the address matches from its start, never from inside it" do
    user = user!("Prefix")
    [_local, domain] = String.split(user.email, "@")

    assert Enum.any?(search(user.email), &(&1.uuid == user.uuid))
    refute Enum.any?(search(domain), &(&1.uuid == user.uuid))
  end
end

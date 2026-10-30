defmodule PhoenixKit.API.Access do
  @moduledoc """
  The rights of a person behind an admin page, read again from the database.

  A LiveView captures the person's `Scope` at mount; a role may change after that, and
  core's PubSub refresh of the page is asynchronous and can be missed. An event that
  changes something (a key, a setting, an approval) must not act with rights the person
  no longer has, so it calls `fresh_scope/1`: the user is loaded again and must still be
  active, and both the scope captured at mount (which may be narrowed to one active role)
  and a scope built now from **all** held roles (the way the API computes rights) must
  hold `api`. The fresh scope is the one to hand to `PhoenixKit.API.Keys`,
  `PhoenixKit.API.ServiceUsers` and `PhoenixKit.API.Approvals`, which check again on
  their own.

  `fresh_scope/2` is the same check for a page that any one of several permissions
  opens: "My API keys" (`["api_personal_keys", "api"]`).
  """

  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.Scope

  @doc "`{:ok, fresh_scope}` while the person may still manage the API, else `:error`."
  @spec fresh_scope(Scope.t() | nil) :: {:ok, Scope.t()} | :error
  def fresh_scope(current), do: fresh_scope(current, ["api"])

  @doc """
  `{:ok, fresh_scope}` while both the scope captured at mount and a full scope built now
  (`narrow: false`) hold at least one of `permissions` (`Scope.can?/2`) and the person is
  still active, else `:error`. An empty list opens nothing.
  """
  @spec fresh_scope(Scope.t() | nil, [String.t()]) :: {:ok, Scope.t()} | :error
  def fresh_scope(current, permissions) when is_list(permissions) do
    with true <- holds_any?(current, permissions),
         uuid when is_binary(uuid) <- Scope.user_uuid(current),
         user when not is_nil(user) <- Auth.get_user(uuid),
         user when not is_nil(user) <- Auth.ensure_active_user(user),
         fresh = Scope.for_user(user, narrow: false),
         true <- holds_any?(fresh, permissions) do
      {:ok, fresh}
    else
      _ -> :error
    end
  end

  defp holds_any?(scope, permissions), do: Enum.any?(permissions, &Scope.can?(scope, &1))
end

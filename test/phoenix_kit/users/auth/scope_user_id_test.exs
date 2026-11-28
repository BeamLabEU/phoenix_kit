defmodule PhoenixKit.Users.Auth.ScopeUserIdTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Auth.User

  # Called through a variable module so the deprecation does not warn at compile time.
  defp user_id(scope) do
    module = Process.get(:scope_module, Scope)
    module.user_id(scope)
  end

  test "user_id/1 returns the same UUID as user_uuid/1" do
    uuid = "0193a5e4-0000-7000-8000-000000000001"
    scope = %Scope{user: %User{uuid: uuid}, authenticated?: true}

    assert user_id(scope) == uuid
    assert user_id(scope) == Scope.user_uuid(scope)
  end

  test "user_id/1 returns nil without a user" do
    assert user_id(nil) == nil
    assert user_id(%Scope{user: nil, authenticated?: false}) == nil
  end

  test "user_id/1 is marked deprecated in favour of user_uuid/1" do
    {:docs_v1, _, _, _, _, _, docs} = Code.fetch_docs(Scope)

    assert Enum.any?(docs, fn
             {{:function, :user_id, 1}, _, _, _, %{deprecated: "Use user_uuid/1"}} -> true
             _ -> false
           end)
  end
end

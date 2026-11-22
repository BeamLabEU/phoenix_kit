defmodule PhoenixKit.Users.Auth.UserTokenInheritTest do
  @moduledoc """
  `UserToken.build_session_token/2` with `:inherit_session` (the cross-domain handoff): the new
  session takes the age and acting role of the session it continues, but only a session of the
  same account and one that is not in the future. Anything else is a normal, fresh session.
  """
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.API.KeyTestSupport
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.UserToken

  defp source(user, overrides \\ %{}) do
    Map.merge(
      %{
        user_uuid: user.uuid,
        inserted_at:
          DateTime.add(DateTime.utc_now(), -7_200, :second) |> DateTime.truncate(:second),
        active_role_uuid: Ecto.UUID.generate()
      },
      overrides
    )
  end

  test "a session of the same account lends its age and its acting role" do
    user = KeyTestSupport.register_user!()
    inherited = source(user)

    {_token, row} = UserToken.build_session_token(user, inherit_session: inherited)

    assert row.inserted_at == inherited.inserted_at
    assert row.active_role_uuid == inherited.active_role_uuid
  end

  test "a session of another account lends nothing" do
    user = KeyTestSupport.register_user!()
    other = KeyTestSupport.register_user!()

    {_token, row} = UserToken.build_session_token(user, inherit_session: source(other))

    assert is_nil(row.inserted_at)
    assert is_nil(row.active_role_uuid)
  end

  test "a session from the future lends nothing" do
    user = KeyTestSupport.register_user!()
    future = DateTime.add(DateTime.utc_now(), 86_400, :second) |> DateTime.truncate(:second)

    {_token, row} =
      UserToken.build_session_token(user, inherit_session: source(user, %{inserted_at: future}))

    assert is_nil(row.inserted_at)
    assert is_nil(row.active_role_uuid)
  end

  test "something that is not a session lends nothing" do
    user = KeyTestSupport.register_user!()

    for bad <- [nil, %{}, %{user_uuid: user.uuid}, "x", source(user, %{inserted_at: nil})] do
      {_token, row} = UserToken.build_session_token(user, inherit_session: bad)
      assert is_nil(row.inserted_at)
      assert is_nil(row.active_role_uuid)
    end
  end

  test "a stored session is never dated later than now, whatever it was asked to inherit" do
    user = KeyTestSupport.register_user!()
    future = DateTime.add(DateTime.utc_now(), 86_400, :second) |> DateTime.truncate(:second)

    token =
      Auth.generate_user_session_token(user,
        inherit_session: source(user, %{inserted_at: future})
      )

    assert %UserToken{inserted_at: at} = Auth.get_session_token_record(token)
    assert DateTime.compare(at, DateTime.utc_now()) in [:lt, :eq]
  end
end

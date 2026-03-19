defmodule PhoenixKit.Integration.RepoSmokeTest do
  use PhoenixKit.DataCase, async: true

  test "repo is connected and migrations ran" do
    assert Repo.query!("SELECT 1").rows == [[1]]
  end

  test "core tables exist" do
    %{rows: rows} =
      Repo.query!("""
      SELECT table_name FROM information_schema.tables
      WHERE table_schema = 'public' AND table_name LIKE 'phoenix_kit_%'
      ORDER BY table_name
      """)

    table_names = List.flatten(rows)

    assert "phoenix_kit_users" in table_names
    assert "phoenix_kit_users_tokens" in table_names
    assert "phoenix_kit_settings" in table_names
  end
end

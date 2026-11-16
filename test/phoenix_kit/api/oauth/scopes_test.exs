defmodule PhoenixKit.API.OAuth.ScopesTest do
  @moduledoc "`PhoenixKit.API.OAuth.Scopes`: the scopes a request may name, and what the consent screen shows."
  use PhoenixKit.DataCase, async: false

  import PhoenixKit.API.KeyTestSupport

  alias PhoenixKit.API.OAuth.Scopes

  setup do
    register_fake_module!()
    :ok
  end

  test "parse/1 keeps the known scopes, once, in the order asked" do
    read = read_scope()

    assert Scopes.parse("#{read} nope.x:read #{read}") == [read]
    assert Scopes.parse("") == []
    assert Scopes.parse("   ") == []
    assert Scopes.parse(nil) == []
    assert Scopes.parse(["a"]) == []
    assert Scopes.parse("openid profile") == []
  end

  test "parse/1 takes a bounded number of names" do
    assert Scopes.parse(String.duplicate("x:y ", 5000)) == []
  end

  test "known/0 holds the scopes of the admin tools only" do
    assert read_scope() in Scopes.known()
    assert Scopes.known() == Enum.sort(Scopes.known())
  end

  test "read?/1" do
    assert Scopes.read?("a.b:read")
    refute Scopes.read?("a.b:write")
  end

  test "describe/1 groups by scope, reads first, with the tools each unlocks" do
    read = read_scope()
    [entry] = Scopes.describe([read])
    assert entry.scope == read
    assert entry.read?
    assert is_list(entry.tools) and entry.tools != []
  end
end

defmodule PhoenixKit.API.OAuth.InputTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.API.OAuth.Input

  test "text the database can hold passes, in any shape" do
    assert Input.valid?("plain õ ✓")
    assert Input.valid?("")
    assert Input.valid?(%{"a" => ["b", %{"c" => "d"}], "n" => 1, "ok" => true, "none" => nil})
    assert Input.valid?(~U[2026-01-01 00:00:00Z])
    assert Input.valid?(5)
  end

  test "a NUL byte fails wherever it hides" do
    assert not Input.valid?("a\0b")
    assert not Input.valid?(%{"a\0" => "b"})
    assert not Input.valid?(%{"a" => "\0"})
    assert not Input.valid?(%{"a" => ["x", %{"b" => ["\0"]}]})
    assert not Input.valid?(["ok", "no\0"])
  end

  test "bytes that are not UTF-8 fail" do
    assert not Input.valid?(<<0xFF>>)
    assert not Input.valid?(<<"a", 0xC3, 0x28>>)
    assert not Input.valid?(%{"k" => <<0x80>>})
  end
end

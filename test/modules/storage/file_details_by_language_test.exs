defmodule PhoenixKit.Modules.Storage.FileDetailsByLanguageTest do
  @moduledoc """
  `FileDetails.by_language/3`: what a form with a block per language posted, as
  `%{language => attrs}` — and that a posted code cannot invent a language.
  """
  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Storage.FileDetails

  test "a block per language is read per language" do
    params = %{
      "en" => %{"title" => "Harbour"},
      "et" => %{"title" => "Sadam", "description" => "Paadid."}
    }

    assert FileDetails.by_language(params, "en", ["en", "et"]) == params
  end

  test "a flat map with the three keys is the default language's text" do
    assert FileDetails.by_language(%{"title" => "Harbour", "alt" => "Boats"}, "et", ["en", "et"]) ==
             %{"et" => %{"title" => "Harbour", "alt" => "Boats"}}
  end

  test "a code that is not an allowed language is dropped" do
    params = %{"en" => %{"title" => "A"}, "xx" => %{"title" => "B"}}
    assert FileDetails.by_language(params, "en", ["en", "et"]) == %{"en" => %{"title" => "A"}}
  end

  test "the default language is allowed without being listed" do
    assert FileDetails.by_language(%{"en" => %{"title" => "A"}}, "en", []) ==
             %{"en" => %{"title" => "A"}}
  end

  test "only the three keys of a block are kept" do
    params = %{"en" => %{"title" => "A", "user_uuid" => "x", "data" => %{}}}
    assert FileDetails.by_language(params, "en", ["en"]) == %{"en" => %{"title" => "A"}}
  end

  test "a value that is not text is dropped like a key that was not sent" do
    params = %{"en" => %{"title" => %{"x" => "1"}, "alt" => "Boats"}}
    assert FileDetails.by_language(params, "en", ["en"]) == %{"en" => %{"alt" => "Boats"}}
    assert FileDetails.by_language(%{"title" => ["a"]}, "en", []) == %{"en" => %{}}
  end

  test "anything but a map is no text" do
    assert FileDetails.by_language(nil, "en", ["en"]) == %{}
    assert FileDetails.by_language("title", "en", ["en"]) == %{}
    assert FileDetails.by_language(%{"en" => "title"}, "en", ["en"]) == %{}
  end
end

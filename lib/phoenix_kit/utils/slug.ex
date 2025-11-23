defmodule PhoenixKit.Utils.Slug do
  @moduledoc """
  Helpers for generating consistent, URL-friendly slugs across PhoenixKit.

  Provides functions to slugify arbitrary text, enforce separator rules,
  and ensure uniqueness by delegating existence checks via callback.
  """

  @doc """
  Converts the given `text` into a slug.

  Options:
    * `:separator` - character used between words (defaults to "-")

  Returns an empty string when the input is blank or cannot be converted.
  """
  @spec slugify(String.t() | nil, keyword()) :: String.t()
  def slugify(text, opts \\ [])

  def slugify(nil, _opts), do: ""

  def slugify(text, opts) when is_binary(text) do
    separator = Keyword.get(opts, :separator, "-")
    escaped_separator = Regex.escape(separator)

    text
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, separator)
    |> String.replace(~r/#{escaped_separator}+/, separator)
    |> String.trim(separator)
  end

  def slugify(_text, _opts), do: ""

  @doc """
  Ensures the provided slug is unique by calling `exists_fun`.

  `exists_fun` should return truthy when the slug is already taken.
  """
  @spec ensure_unique(String.t(), (String.t() -> boolean())) :: String.t()
  def ensure_unique("", _exists_fun), do: ""

  def ensure_unique(slug, exists_fun) when is_function(exists_fun, 1) do
    if exists_fun.(slug) do
      increment_slug(slug, 2, exists_fun)
    else
      slug
    end
  end

  defp increment_slug(base_slug, counter, exists_fun) do
    candidate = "#{base_slug}-#{counter}"

    if exists_fun.(candidate) do
      increment_slug(base_slug, counter + 1, exists_fun)
    else
      candidate
    end
  end
end

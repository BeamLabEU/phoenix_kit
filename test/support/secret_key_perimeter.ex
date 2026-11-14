defmodule PhoenixKit.Test.SecretKeyPerimeter do
  @moduledoc """
  Closes a specific hole in the partition invariant (`settings_test.exs`,
  "every get_defaults/0 key is classified exactly once") — that check only
  walks `Settings.get_defaults/0`, so a secret-shaped setting key core never
  added to `get_defaults/0` at all is invisible to it, not merely
  misclassified. That is exactly how `billing_stripe_secret_key` and its
  siblings went unrestricted: they are written through
  `PhoenixKit.Settings.update_setting/2` by a separate hex package, and no
  `get_defaults/0` entry ever named them, so the invariant had nothing to
  compare them against.

  This module answers a narrower question than "every key core's source
  references must be classified" — that assertion fails today against dozens
  of legitimate module settings never meant to be on either list
  (`entities_max_per_user`, `shop_hide_zero_decimals`, the whole
  `billing_company_*`/`billing_bank_*` invoice-detail group in
  `lib/phoenix_kit/utils/country_data.ex`, ...). Instead: find every key
  literal that LOOKS like it carries live credential material, wherever
  core's own source references or seeds one, so the caller can assert those
  specifically are restricted.

  ## What this can and cannot see

  Scans core's own `lib/` tree and its migration seeds — the two places a
  gap of this exact shape (seeded/referenced, never classified) can actually
  occur inside THIS repository. It structurally CANNOT see a key that only
  exists inside a separate hex package's source (`phoenix_kit_billing`,
  `phoenix_kit_emails`, ...) — those are different git repositories with no
  path into this one. It closes the perimeter for what core owns and can
  read; a module package's own secret-shaped keys are that package's
  responsibility to assert against `PhoenixKit.Settings.restricted_setting_keys/0`
  in its own test suite (it already depends on core, so it can).
  """

  # Ends this way => public by design (an id meant for client-side use), even
  # when the generic "ends in _key" rule below would otherwise catch it —
  # the same reasoning settings.ex's own comment gives for
  # oauth_*_client_id/oauth_*_app_id, core's own public OAuth identifiers.
  # `_site_key`: Cloudflare Turnstile's public half, printed into every page
  # that shows the widget (its secret half is `turnstile_secret_key`).
  @secret_suffix_exclusions ~w(
    _client_id
    _app_id
    _site_key
  )

  @secret_substrings ~w(secret password private_key api_key token credential passphrase)

  @doc """
  Whether a setting key's NAME looks like it carries live credential material
  worth guarding — independent of whether it is actually classified
  anywhere.
  """
  @spec secret_shaped?(String.t()) :: boolean()
  def secret_shaped?(key) when is_binary(key) do
    cond do
      Enum.any?(@secret_suffix_exclusions, &String.ends_with?(key, &1)) -> false
      Enum.any?(@secret_substrings, &String.contains?(key, &1)) -> true
      String.ends_with?(key, "_key") -> true
      true -> false
    end
  end

  @attribute_definition ~r/@([a-zA-Z_][a-zA-Z0-9_]*)\s+"([a-z0-9_]+)"/
  @call_with_literal ~r/(?:PhoenixKit\.Settings|(?<!\.)Settings)\.\w+\(\s*"([a-z0-9_]+)"/
  @call_with_attribute ~r/(?:PhoenixKit\.Settings|(?<!\.)Settings)\.\w+\(\s*@([a-zA-Z_][a-zA-Z0-9_]*)/

  @doc """
  Every setting-key literal passed as the first argument to ANY
  `PhoenixKit.Settings` function anywhere under `root`'s `.ex` files —
  aliased (`Settings.foo("key")`) or fully qualified
  (`PhoenixKit.Settings.foo("key")`), covering `get_setting/1,2`,
  `get_boolean_setting/1,2`, `get_setting_cached/1,2`, `get_json_setting/1,2`,
  `update_setting/2`, `update_boolean_setting/2`, `update_json_setting/2`,
  `update_setting_with_module/3` and anything else with the same shape — not
  a fixed function list, so a new reader/writer added later needs no update
  here. `(?<!\\.)Settings\\.` (rather than a bare `\\bSettings\\.`) so a call
  through some OTHER module also named `Settings` (`Foo.Settings.bar(...)`)
  is not mistaken for this one.

  Also resolves the common `@key_name "literal"` module-attribute pattern
  (`Settings.foo(@key_name)`) back to its literal, in the same file — this is
  how core's own `website_access_password`/`website_access_link_token` are
  actually referenced (`PhoenixKit.WebsiteAccess.Gate`), so without it this
  scan would never see either despite both being real, already-restricted
  keys.

  List-taking readers (`get_settings_direct/1`, `get_settings_cached/2`,
  taking a list of keys rather than one) are not covered — the key isn't a
  single literal argument there, it's a list built from data the scan cannot
  resolve statically.
  """
  @spec scan_settings_literals(String.t()) :: [String.t()]
  def scan_settings_literals(root) do
    for path <- Path.wildcard(Path.join(root, "**/*.ex")),
        {:ok, content} = File.read(path) do
      literal_keys = for [_, key] <- Regex.scan(@call_with_literal, content), do: key

      attribute_values =
        for [_, name, value] <- Regex.scan(@attribute_definition, content), into: %{} do
          {name, value}
        end

      attribute_keys =
        for [_, name] <- Regex.scan(@call_with_attribute, content),
            value = Map.get(attribute_values, name),
            not is_nil(value) do
          value
        end

      literal_keys ++ attribute_keys
    end
    |> List.flatten()
    |> Enum.uniq()
  end

  @doc """
  Every setting key seeded by a `phoenix_kit_settings` INSERT in a core
  migration (`lib/phoenix_kit/migrations/postgres/*.ex`) — the exact shape
  `billing_stripe_enabled` and its siblings were added by, in v135, without
  ever reaching `get_defaults/0`. Matches the two-line
  `INSERT INTO ... phoenix_kit_settings (...)` / `VALUES ('key', ...)` shape
  every seed in this codebase uses.
  """
  @spec scan_migration_seed_literals(String.t()) :: [String.t()]
  def scan_migration_seed_literals(root) do
    for path <- Path.wildcard(Path.join(root, "**/*.ex")),
        {:ok, content} = File.read(path) do
      lines = String.split(content, "\n")

      lines
      |> Enum.zip(tl(lines) ++ [""])
      |> Enum.filter(fn {line, _next} ->
        String.contains?(line, "phoenix_kit_settings") and String.contains?(line, "INSERT INTO")
      end)
      |> Enum.flat_map(fn {_line, next_line} ->
        case Regex.run(~r/VALUES\s*\(\s*'([a-z0-9_]+)'/, next_line) do
          [_, key] -> [key]
          nil -> []
        end
      end)
    end
    |> List.flatten()
    |> Enum.uniq()
  end
end

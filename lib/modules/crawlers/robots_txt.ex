defmodule PhoenixKit.Modules.Crawlers.RobotsTxt do
  @moduledoc """
  Renders the complete `robots.txt` an operator should serve, from the
  Crawlers module's per-group toggles.

  PhoenixKit deliberately does **not** serve this file — `robots.txt` is host
  policy and `Plug.Static` answers before the router is consulted, so a
  generated route would be dead code on most installs and a silent override on
  the rest. What changed with the group toggles is how much there is to say:
  one `Sitemap:` line was dictation, a per-group policy is a file. So the
  settings page renders the whole thing for copy-paste, and this module is the
  pure builder behind it.

  ## Shape of the output

  robots.txt is default-allow, so only *blocked* groups produce stanzas — one
  `User-agent:` line per bot token, sharing a single `Disallow: /`. An
  explicit `User-agent: * / Disallow:` (empty = allow all) stanza leads the
  file so the operator's intent is visible rather than implied, and the
  `Sitemap:` line closes it.

  ## The host's own lines (`:extra`)

  A host usually has paths of its own to keep out of every index
  (`Disallow: /phoenix_kit/`, `Disallow: /dev/`). Pass them as `extra:` and
  they become the rules of the leading `User-agent: *` group, replacing its
  empty `Disallow:`:

      RobotsTxt.build(
        sitemap_url: "https://example.com/sitemap.xml",
        extra: ["Disallow: /phoenix_kit/", "Disallow: /dev/"]
      )

      # Default: everyone not listed below follows these rules.
      User-agent: *
      Disallow: /phoenix_kit/
      Disallow: /dev/
      ...

  Why inside the `*` group rather than a second `User-agent: *` group of
  their own: a crawler obeys exactly one group, the most specific one that
  names it. Every bot this module writes a stanza for is a *blocked* bot
  (`Disallow: /` already covers the host's paths), so every bot still allowed
  in reads the `*` group — that is where the host's rules have to live.
  RFC 9309 merges repeated groups for one agent, but older parsers take the
  first match only and would never see a second `*` group.

  The lines are rules for that group: `Allow:`, `Disallow:`, `Crawl-delay:`,
  comments (`Sitemap:` is a file-wide record and is fine too). A
  `User-agent:` line raises `ArgumentError` — placed there it would not start
  a new group but join the `*` group, silently handing the host's agent every
  rule above it. Blank lines are dropped, since some parsers end a group at
  one.
  """

  alias PhoenixKit.Modules.Crawlers
  alias PhoenixKit.Modules.Crawlers.Bots

  @doc """
  Build the robots.txt contents from the current settings.

  Options:

    * `:sitemap_url` — absolute URL for the `Sitemap:` line; omitted when nil.
    * `:extra` — the host's own rules for the `User-agent: *` group, as one
      string (newline-separated) or a list of lines. See "The host's own
      lines" in the moduledoc.
  """
  @spec build(keyword()) :: String.t()
  def build(opts \\ []) do
    blocked = Enum.reject(Bots.group_keys(), &Crawlers.group_allowed?/1)
    build_for(blocked, opts)
  end

  @doc """
  Pure variant: build for an explicit list of blocked group keys. `build/1`
  reads the settings and delegates here; tests come in through this door.
  """
  @spec build_for([Bots.group()], keyword()) :: String.t()
  def build_for(blocked_group_keys, opts \\ []) do
    sitemap_url = Keyword.get(opts, :sitemap_url)
    extra = opts |> Keyword.get(:extra) |> extra_lines()

    sections =
      [default_stanza(extra)] ++
        Enum.map(blocked_group_keys, &blocked_stanza/1) ++
        sitemap_section(sitemap_url)

    sections
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  defp default_stanza([]) do
    "# Default: everyone not listed below may crawl everything.\nUser-agent: *\nDisallow:\n"
  end

  defp default_stanza(extra) do
    # A group needs at least one rule; comments and Sitemap lines are not one.
    rules = if Enum.any?(extra, &rule_line?/1), do: extra, else: ["Disallow:" | extra]

    "# Default: everyone not listed below follows these rules.\nUser-agent: *\n" <>
      Enum.join(rules, "\n") <> "\n"
  end

  defp extra_lines(nil), do: []
  defp extra_lines(text) when is_binary(text), do: text |> String.split(~r/\R/) |> extra_lines()

  defp extra_lines(lines) when is_list(lines) do
    lines
    |> Enum.flat_map(&String.split(&1, ~r/\R/))
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&reject_user_agent!/1)
  end

  defp reject_user_agent!(line) do
    if field?(line, "user-agent") do
      raise ArgumentError,
            "RobotsTxt :extra holds rules for the User-agent: * group; " <>
              "a User-agent line there would merge into that group: #{inspect(line)}"
    end

    line
  end

  defp rule_line?(line), do: field?(line, "allow") or field?(line, "disallow")

  defp field?(line, name) do
    case String.split(line, ":", parts: 2) do
      [key, _] -> key |> String.trim() |> String.downcase() == name
      _ -> false
    end
  end

  defp blocked_stanza(group_key) do
    case Bots.group(group_key) do
      nil ->
        nil

      group ->
        agents = Enum.map_join(group.bots, "\n", &"User-agent: #{&1.token}")
        "# #{group.label}: blocked.\n#{agents}\nDisallow: /\n"
    end
  end

  defp sitemap_section(nil), do: []
  defp sitemap_section(url), do: ["Sitemap: #{url}\n"]
end

defmodule PhoenixKit.Install.ConfigVerify do
  @moduledoc """
  I103: the config-editing helpers across `oban_config.ex`, `phoenix_kit.update.ex`,
  `boot_hook.ex`, and `runtime_detector.ex` all splice text into a host's own
  `.ex`/`.exs` file via regex, then hand the result back without ever checking
  what they produced. Two independent ways that goes wrong, found the same day:

    * The splice lands on the wrong delimiter (a `]` inside a comment, inside a
      string) and produces text that is not valid Elixir at all — reproduced
      live as `MismatchedDelimiterError` from `add_scheduled_posts_job_to_crontab/1`
      given nothing more unusual than an ordinary explanatory comment.
    * The splice lands on the wrong delimiter and STILL produces valid Elixir —
      the new entry ends up nested inside an unrelated value (an existing
      entry's own `args: %{tags: [...]}` list) instead of as a sibling of the
      list it was meant to join. A parse check alone accepts this silently;
      it is the exact shape of a green that doesn't back its own claim, same
      as I082's doctor check before it named its own scope.

  This module is the shared fix for both: parse the candidate text, then hand
  the parsed AST to a caller-supplied predicate that confirms the SPECIFIC
  change is actually present where it was meant to land — not just that some
  valid Elixir came out. Either failure returns the ORIGINAL, untouched
  content plus a reason a caller turns into the same kind of manual-fallback
  message the safe call sites in this codebase already print. A rollback is
  never worse than what the file had before; a wrong bracket must never win
  silently over "tell the operator to do it by hand".

  ## What this deliberately does NOT cover

  `PhoenixKit.Install.JsIntegration` and `PhoenixKit.Install.CssIntegration`
  splice regex-built text into a host's `assets/js/app.js`,
  `root.html.heex`, and `app.css` the same way — but `Code.string_to_quoted/1`
  only understands Elixir, so there is no equivalent parse-then-verify step
  for JavaScript, HEEX, or CSS available here. That is a real, permanent gap
  in coverage, not an oversight: those splices stay regex-only, checked (where
  they are checked at all) by a plain `if updated != content` before writing.
  Each site says so in its own comment.
  """

  @typedoc "Whether the candidate came back invalid, or valid but the intended change wasn't found."
  @type failure :: :syntax | :semantic

  @doc """
  Parses `candidate`, then runs `semantic_check` against the resulting AST.

  Returns `{:ok, candidate}` only when both the parse succeeds AND
  `semantic_check` returns `true`. Otherwise returns `{:error, reason}` —
  the caller is expected to fall back to whatever content it started from
  (this module never sees or returns `original`; it isn't needed to make
  that decision, and threading it through here would only invite a caller
  to skip the fallback by mistake).
  """
  @spec verify(String.t(), (Macro.t() -> boolean())) :: {:ok, String.t()} | {:error, failure()}
  def verify(candidate, semantic_check)
      when is_binary(candidate) and is_function(semantic_check, 1) do
    # `emit_warnings: false`: a host's single-quoted charlists would otherwise
    # print a deprecation warning for every parse the updater does.
    case Code.string_to_quoted(candidate, emit_warnings: false) do
      {:ok, ast} ->
        if semantic_check.(ast) do
          {:ok, candidate}
        else
          {:error, :semantic}
        end

      {:error, _reason} ->
        {:error, :syntax}
    end
  end

  @doc """
  Runs a regex-built `candidate` through `verify/2` and returns either the
  candidate (accepted) or `original` (rolled back) — the one-line shape
  every call site in this codebase wants: try the insertion, keep it only
  if it's provably correct, otherwise behave exactly as if the insertion
  had never been attempted.
  """
  @spec verify_or_rollback(String.t(), String.t(), (Macro.t() -> boolean())) ::
          {:ok, String.t()} | {:rolled_back, String.t(), failure()}
  def verify_or_rollback(original, candidate, semantic_check) do
    case verify(candidate, semantic_check) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:rolled_back, original, reason}
    end
  end

  @doc """
  True if any node in `ast` satisfies `matcher`. Stops at the first match —
  every caller here asks "is this one thing present", not "collect every
  occurrence".
  """
  @spec ast_contains?(Macro.t(), (Macro.t() -> boolean())) :: boolean()
  def ast_contains?(ast, matcher) when is_function(matcher, 1) do
    {_, found} =
      Macro.prewalk(ast, false, fn node, acc ->
        if acc, do: {node, acc}, else: {node, matcher.(node)}
      end)

    found
  end

  @doc """
  The elements of a quoted tuple of any size.

  A literal 2-tuple is its own AST node (`{a, b}`) — but Elixir represents
  every OTHER tuple size as `{:{}, meta, elements}`, the one case a bare
  `is_tuple/1` check on quoted code would miss. Returns `nil` for anything
  that isn't a quoted tuple at all.
  """
  @spec tuple_elements(Macro.t()) :: [Macro.t()] | nil
  def tuple_elements({:{}, _meta, elements}), do: elements

  def tuple_elements(tuple) when is_tuple(tuple) and tuple_size(tuple) == 2,
    do: Tuple.to_list(tuple)

  def tuple_elements(_), do: nil

  @doc "True if the quoted node is a `__aliases__` resolving to exactly `module`."
  @spec alias_matches?(Macro.t(), module()) :: boolean()
  def alias_matches?({:__aliases__, _meta, parts}, module), do: Module.concat(parts) == module
  def alias_matches?(_, _), do: false

  @doc """
  True if `module` appears as one of the elements of the quoted tuple `node` —
  used to confirm a newly-spliced plugin/worker tuple actually landed as its
  own list entry, not nested deeper inside an unrelated value.
  """
  @spec tuple_names_module?(Macro.t(), module()) :: boolean()
  def tuple_names_module?(node, module) do
    case tuple_elements(node) do
      nil -> false
      elements -> Enum.any?(elements, &alias_matches?(&1, module))
    end
  end

  @doc "Looks up `key` in a quoted keyword list; `{:ok, value}` or `nil`."
  @spec keyword_get(Macro.t(), atom()) :: {:ok, Macro.t()} | nil
  def keyword_get(kw, key) when is_list(kw) do
    Enum.find_value(kw, fn
      {^key, value} -> {:ok, value}
      _ -> nil
    end)
  end

  def keyword_get(_, _), do: nil

  @doc """
  True if `ast` contains a `{root_key, list}` pair (e.g. a `crontab:`,
  `plugins:`, or `queues:` entry inside some enclosing keyword list) where
  `list` satisfies `list_check` — the shared shape behind "did my new entry
  land inside the RIGHT list", regardless of how deep that list sits.
  """
  @spec keyword_list_satisfies?(Macro.t(), atom(), ([Macro.t()] -> boolean())) :: boolean()
  def keyword_list_satisfies?(ast, root_key, list_check) when is_function(list_check, 1) do
    ast_contains?(ast, fn
      {^root_key, list} when is_list(list) -> list_check.(list)
      _ -> false
    end)
  end

  @doc """
  Scopes a `keyword_list_satisfies?/3`-style check to ONE application's
  config block.

  True if `ast` contains a `config(app_name, module, opts)` call — the
  `Config.config/3` macro invoked as `config :app_name, Module, key: value` —
  whose `opts` contain a `{root_key, list}` pair (at any depth, e.g. a
  `crontab:` nested inside an `Oban.Plugins.Cron` tuple inside `plugins:`)
  satisfying `list_check`.

  `keyword_list_satisfies?/3` alone answers "does a `root_key: [...]` list
  like this appear ANYWHERE in the file" — true even when it belongs to a
  DIFFERENT application's block. Paired with a splice that isn't anchored to
  the right app either, that isn't a safety net: it is a check that can
  confirm the WRONG outcome, reporting success while the intended
  application's config was never touched. See
  `PhoenixKit.Install.ObanConfig`'s `plugins:`/`crontab:` splices, which
  anchor both the insertion and this check to `app_name`.
  """
  @spec app_config_satisfies?(
          Macro.t(),
          atom() | String.t(),
          module(),
          atom(),
          ([Macro.t()] -> boolean())
        ) :: boolean()
  def app_config_satisfies?(ast, app_name, module, root_key, list_check)
      when is_function(list_check, 1) do
    target = to_app_atom(app_name)

    ast_contains?(ast, fn
      {:config, _meta, [app, alias_node, opts]} when is_atom(app) and is_list(opts) ->
        app == target and alias_matches?(alias_node, module) and
          keyword_list_satisfies?(opts, root_key, list_check)

      _ ->
        false
    end)
  end

  defp to_app_atom(app) when is_atom(app), do: app
  defp to_app_atom(app) when is_binary(app), do: String.to_atom(app)
end

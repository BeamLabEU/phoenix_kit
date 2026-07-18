defmodule PhoenixKit.Install.ChildOrder do
  @moduledoc """
  Reads a host application's `application.ex` and checks that the Ecto Repo
  starts BEFORE `PhoenixKit.Supervisor` and `Oban` in the supervision
  `children` list.

  `PhoenixKit.Supervisor` reads Settings / OAuth configuration from the
  database as it boots, and Oban opens a connection pool against the same
  Repo — so both MUST appear after the Repo in the children list. A
  mis-ordered list crashes the app at startup (typically an Oban crash-loop:
  the pool has no database to reach yet).

  `mix phoenix_kit.install` positions its child after the detected Repo, but a
  hand-edited `application.ex` — or an Igniter anchor miss that prepends the
  child instead of inserting it after the Repo — can regress the order. This
  module is the deterministic safety net: `mix phoenix_kit.doctor` runs
  `check/2` against the host's source so both fresh and existing installs are
  caught, independent of how the children ended up ordered.

  Everything here is a pure function over source text — no application boot,
  no database — so it is unit-testable in isolation.
  """

  # Children that depend on the Repo already being started.
  @repo_dependents [PhoenixKit.Supervisor, Oban]

  @typedoc "A module extracted from a child spec, or `nil` when unrecognized."
  @type child :: module() | nil

  @doc """
  Checks the child ordering in `source` relative to `repo_module`.

  Returns:

    * `{:ok, detail}` — the Repo precedes every Repo-dependent child that is
      present (or none are present); `detail` is a human-readable summary.
    * `{:misordered, [module]}` — the listed Repo-dependent modules appear
      *before* the Repo. This is the crash case.
    * `:no_repo_in_children` — `repo_module` wasn't found in the children list,
      so ordering can't be judged (verify manually).
    * `:no_children` — no `children` list could be located in the source.
  """
  @spec check(String.t(), module()) ::
          {:ok, String.t()} | {:misordered, [module()]} | :no_repo_in_children | :no_children
  def check(source, repo_module) when is_binary(source) and is_atom(repo_module) do
    case ordered_children(source) do
      {:ok, mods} ->
        case Enum.find_index(mods, &(&1 == repo_module)) do
          nil ->
            :no_repo_in_children

          repo_index ->
            offenders = Enum.filter(@repo_dependents, &before?(mods, &1, repo_index))

            if offenders == [] do
              {:ok, describe(mods, repo_module, repo_index)}
            else
              {:misordered, offenders}
            end
        end

      :error ->
        :no_children
    end
  end

  @doc """
  Extracts the ordered list of head modules from the host's `children` list.

  Each element is the module heading a child spec (`MyApp.Repo`,
  `{Oban, opts}` → `Oban`, `{Phoenix.PubSub, ...}` → `Phoenix.PubSub`), or
  `nil` for a spec whose module can't be read cheaply (e.g. a `%{}` map spec).
  Returns `:error` if no children list can be found.
  """
  @spec ordered_children(String.t()) :: {:ok, [child()]} | :error
  def ordered_children(source) when is_binary(source) do
    with {:ok, ast} <- Code.string_to_quoted(source),
         [list | _] <- children_lists(ast) do
      {:ok, Enum.map(list, &child_head_module/1)}
    else
      _ -> :error
    end
  end

  # ── Locating the children list ──────────────────────────────────────

  # Collects every candidate children list in document order, from the two
  # shapes the Phoenix generator and hand-written apps use:
  #   children = [ ... ]
  #   Supervisor.start_link([ ... ], opts)
  defp children_lists(ast) do
    {_ast, acc} = Macro.prewalk(ast, [], fn node, acc -> {node, collect_list(node, acc)} end)
    acc |> Enum.reverse() |> Enum.map(fn {_pos, list} -> list end)
  end

  # `children = [ ... ]`
  defp collect_list({:=, meta, [{:children, _, ctx}, list]}, acc)
       when is_atom(ctx) and is_list(list),
       do: [{meta[:line] || 0, list} | acc]

  # `Supervisor.start_link([ ... ], opts)`
  defp collect_list(
         {{:., _, [{:__aliases__, _, [:Supervisor]}, :start_link]}, meta, [list | _]},
         acc
       )
       when is_list(list),
       do: [{meta[:line] || 0, list} | acc]

  defp collect_list(_node, acc), do: acc

  # ── Reading a child spec's head module ──────────────────────────────

  # Bare module: `MyApp.Repo`
  defp child_head_module({:__aliases__, _, parts}), do: safe_concat(parts)

  # 3+-element tuple literal: `{Mod, a, b}` — module heads it.
  defp child_head_module({:{}, _, [first | _]}), do: child_head_module(first)

  # 2-element tuple literal: `{Oban, opts}` / `{Phoenix.PubSub, name: ...}`.
  # (Alias/call/`{:{}}` nodes are all 3-tuples, so only genuine 2-tuples reach
  # here.)
  defp child_head_module({first, _second}), do: child_head_module(first)

  defp child_head_module(_other), do: nil

  defp safe_concat(parts) do
    if Enum.all?(parts, &is_atom/1), do: Module.concat(parts), else: nil
  end

  # ── Helpers ─────────────────────────────────────────────────────────

  defp before?(mods, module, repo_index) do
    case Enum.find_index(mods, &(&1 == module)) do
      nil -> false
      index -> index < repo_index
    end
  end

  defp describe(mods, repo_module, repo_index) do
    present =
      @repo_dependents
      |> Enum.filter(&(&1 in mods))
      |> Enum.map(&inspect/1)

    dependents =
      case present do
        [] -> "no Repo-dependent children in the list"
        names -> "before #{Enum.join(names, ", ")}"
      end

    "#{inspect(repo_module)} (position #{repo_index}) starts #{dependents}"
  end
end

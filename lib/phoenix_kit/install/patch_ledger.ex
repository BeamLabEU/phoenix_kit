defmodule PhoenixKit.Install.PatchLedger do
  @moduledoc """
  The host's record of which optional edits `mix phoenix_kit.update` made to
  its project and which it declined: `.phoenix_kit.exs` in the project root.
  **Commit it.**

  Without it the updater could not tell "never added" from "added, then
  deliberately removed", and re-added every removed piece on every run (a
  module-hooks script tag, an Oban queue for a package the host never
  installed, `themes: all` in a host that turned daisyUI's themes off).

  ## Patch IDs

  Every optional edit has a stable ID:

  | ID | What it adds |
  |----|--------------|
  | `module_js_seed` | the module-hooks `<script>` tag in the root layout and the seeded `phoenix_kit_modules.js` |
  | `oban_queues` | every Oban queue PhoenixKit or an installed module declares; `oban_queues:<name>` is one queue |
  | `daisyui_themes` | `themes: false` → `themes: all` on the daisyUI plugin in `app.css` |
  | `css_sources_import` | `@import "./_phoenix_kit_sources.css";` in `app.css` |
  | `theme_bootstrap` | the theme bootstrap in the root layout — opt-in only, see `mix phoenix_kit.update --install-root-theme` |

  Required configuration (Ueberauth, Hammer, the Oban block and its
  supervisor child, the compilers, the boot hook) and security-relevant
  edits (`body_guard`, the request-size and error guard in the endpoint) are
  **not declinable**: `--skip-patch` refuses them.

  ## How a patch is decided

  1. `--skip-patch ID` declines it (recorded as declined; nothing is removed).
  2. An inline marker in the file the patch edits declines it:
     `# phoenix_kit:skip ID` (Elixir, CSS-style `/* phoenix_kit:skip ID */`
     works too) or `<%!-- phoenix_kit:skip ID --%>` (HEEx).
  3. Already present → recorded as applied.
  4. `--repair-patch ID` applies it again whatever the ledger says.
  5. Recorded as declined → left out.
  6. Recorded as applied but now absent → you removed it: treated as
     declined, not re-added, and reported at the end of the run with the
     `--repair-patch` hint.
  7. Not recorded at all → applied, exactly as before the ledger existed.

  So the **first run without a ledger behaves exactly as an update always
  did**, and then records what is present.

  ## The file

      # .phoenix_kit.exs
      %{
        patches: %{"module_js_seed" => :applied, "oban_queues:posts" => :declined},
        daisyui_notice: %{kit: "3.1.0", daisyui: "5.5.20"}
      }

  Edit it by hand or with the flags. It also remembers which daisyUI notice
  was already shown (`PhoenixKit.Install.DaisyUI`).
  """

  @file_name ".phoenix_kit.exs"
  @state_key {__MODULE__, :state}

  @declinable ~w(module_js_seed oban_queues daisyui_themes css_sources_import theme_bootstrap)
  @not_declinable ~w(body_guard ueberauth hammer oban_config oban_supervisor compilers boot_hook)

  @type outcome :: :applied | :declined
  @type reason :: :flag | :marker | :ledger | :removed
  @type decision :: :present | :apply | {:declined, reason()}

  @doc "The ledger's file name, relative to the project root."
  @spec file_name() :: String.t()
  def file_name, do: @file_name

  @doc "The IDs `--skip-patch` / `--repair-patch` accept (plus `oban_queues:<name>`)."
  @spec declinable_ids() :: [String.t()]
  def declinable_ids, do: @declinable

  @doc "IDs that name a required or security-relevant edit."
  @spec not_declinable_ids() :: [String.t()]
  def not_declinable_ids, do: @not_declinable

  @doc """
  Reads the ledger at `root`. A missing file is an empty ledger; an
  unreadable one raises, naming the file (a guess could re-add what the host
  declined).
  """
  @spec load(Path.t()) :: map()
  def load(root \\ File.cwd!()) do
    path = Path.join(root, @file_name)

    case File.read(path) do
      {:ok, content} -> parse!(content, path)
      {:error, :enoent} -> empty()
      {:error, reason} -> Mix.raise("Could not read #{path}: #{inspect(reason)}")
    end
  end

  defp empty, do: %{patches: %{}}

  defp parse!(content, path) do
    with {:ok, quoted} <- Code.string_to_quoted(content),
         true <- Macro.quoted_literal?(quoted),
         {%{} = map, _} <- Code.eval_quoted(quoted) do
      case Map.get(map, :patches, %{}) do
        patches when is_map(patches) ->
          Map.put(map, :patches, patches)

        other ->
          Mix.raise("""
          #{path}: `patches:` must be a map of patch ID => :applied | :declined,
          got #{inspect(other)}. Fix it (or delete the file to start over).
          """)
      end
    else
      _ ->
        Mix.raise("""
        #{path} is not a literal Elixir map, so PhoenixKit cannot tell which
        patches you declined. Fix it (or delete it to start over: the next
        `mix phoenix_kit.update` records what is present).
        """)
    end
  end

  @doc "Writes `ledger` to `root`, with a header saying what the file is."
  @spec save(map(), Path.t()) :: :ok
  def save(ledger, root \\ File.cwd!()) do
    body =
      inspect(Map.update(ledger, :patches, %{}, &sort_map/1),
        pretty: true,
        limit: :infinity,
        printable_limit: :infinity
      )

    File.write!(Path.join(root, @file_name), """
    # PhoenixKit's record of the optional edits `mix phoenix_kit.update` made to
    # this project (:applied) and the ones you declined (:declined). Commit it.
    # A patch recorded as applied and later removed is not added back; run
    # `mix phoenix_kit.update --repair-patch ID` to restore one. See
    # PhoenixKit.Install.PatchLedger for the IDs.
    #{body}
    """)
  end

  defp sort_map(map), do: map |> Enum.sort() |> Map.new()

  @doc """
  Starts a run: loads the ledger at `root` and validates the flags.

  `opts` takes `:skip_patch` and `:repair_patch` (lists of IDs). Raises on an
  unknown ID or a non-declinable one. Until `begin/2` is called (unit tests,
  the installer), `decide/3` answers as if there were no ledger and nothing
  is recorded.
  """
  @spec begin(keyword(), Path.t()) :: :ok
  def begin(opts, root \\ File.cwd!()) do
    skip = opts |> Keyword.get_values(:skip_patch) |> List.flatten() |> validate_ids!()
    repair = opts |> Keyword.get_values(:repair_patch) |> List.flatten() |> validate_ids!()

    Process.put(@state_key, %{
      root: root,
      ledger: load(root),
      skip: MapSet.new(skip),
      repair: MapSet.new(repair),
      outcomes: %{},
      removed: [],
      dirty: false
    })

    :ok
  end

  @doc "Whether a run is in progress."
  @spec active?() :: boolean()
  def active?, do: Process.get(@state_key) != nil

  @doc "Ends the run without writing."
  @spec abandon() :: :ok
  def abandon do
    Process.delete(@state_key)
    :ok
  end

  @doc false
  @spec validate_ids!([String.t()]) :: [String.t()]
  def validate_ids!(ids) do
    Enum.each(ids, fn id ->
      cond do
        id in @not_declinable ->
          Mix.raise(
            "#{id} is a required or security-relevant part of PhoenixKit and cannot be " <>
              "declined or repaired with a patch flag."
          )

        known?(id) ->
          :ok

        true ->
          Mix.raise(
            "Unknown patch ID #{inspect(id)}. Known: " <>
              Enum.join(@declinable ++ ["oban_queues:<queue>"], ", ")
          )
      end
    end)

    ids
  end

  defp known?(id) do
    case String.split(id, ":", parts: 2) do
      [base] -> base in @declinable
      ["oban_queues", name] -> Regex.match?(~r/^[a-z][a-z0-9_]*$/, name)
      _ -> false
    end
  end

  @doc """
  Decides one patch. `present?` says whether its edit is in the project now;
  `content` is the text of the file it edits (searched for the inline skip
  marker; `nil` when there is none).

  The caller applies on `:apply` and then calls `record/2`; every other
  answer is recorded here.
  """
  @spec decide(String.t(), boolean(), String.t() | nil) :: decision()
  def decide(id, present?, content \\ nil) do
    state = Process.get(@state_key)
    decision = decision(id, present?, content, state)

    case decision do
      :present -> record(id, :applied)
      {:declined, reason} -> record_declined(id, reason)
      :apply -> :ok
    end

    decision
  end

  # Pure: see the moduledoc's numbered list.
  @doc false
  def decision(id, present?, content, state) do
    ledger = if state, do: state.ledger.patches, else: %{}
    skip = if state, do: state.skip, else: MapSet.new()
    repair = if state, do: state.repair, else: MapSet.new()

    cond do
      matches?(skip, id) -> {:declined, :flag}
      marker?(content, id) -> {:declined, :marker}
      present? -> :present
      matches?(repair, id) -> :apply
      recorded(ledger, id) == :declined -> {:declined, :ledger}
      recorded(ledger, id) == :applied -> {:declined, :removed}
      true -> :apply
    end
  end

  @doc "Whether `--repair-patch` named `id` (or its group) in this run."
  @spec repair?(String.t()) :: boolean()
  def repair?(id) do
    case Process.get(@state_key) do
      nil -> false
      state -> matches?(state.repair, id)
    end
  end

  @doc """
  Whether the ledger of this run records `id` (or its group) as `:declined`.
  `false` outside a run.
  """
  @spec declined?(String.t()) :: boolean()
  def declined?(id) do
    case Process.get(@state_key) do
      nil -> false
      state -> recorded(state.ledger.patches, id) == :declined
    end
  end

  @doc "Whether `--skip-patch` named `id` (or its group) in this run."
  @spec skip?(String.t()) :: boolean()
  def skip?(id) do
    case Process.get(@state_key) do
      nil -> false
      state -> matches?(state.skip, id)
    end
  end

  # `oban_queues` covers every `oban_queues:<name>`.
  defp matches?(set, id), do: MapSet.member?(set, id) or MapSet.member?(set, group(id))

  defp recorded(ledger, id) do
    case Map.get(ledger, id) do
      nil -> if group(id) != id, do: group_declined(ledger, id), else: nil
      outcome -> outcome
    end
  end

  # A declined group declines its members; an applied group says nothing
  # about a member it never listed.
  defp group_declined(ledger, id) do
    if Map.get(ledger, group(id)) == :declined, do: :declined, else: nil
  end

  defp group(id), do: id |> String.split(":", parts: 2) |> hd()

  @doc """
  Whether `content` carries an inline skip marker for `id` (or its group):
  `phoenix_kit:skip ID` inside a comment of any syntax.
  """
  @spec marker?(String.t() | nil, String.t()) :: boolean()
  def marker?(nil, _id), do: false

  def marker?(content, id) when is_binary(content) do
    Enum.any?(Enum.uniq([id, group(id)]), fn candidate ->
      Regex.match?(~r/phoenix_kit:skip\s+#{Regex.escape(candidate)}(?![\w:])/, content)
    end)
  end

  @doc """
  Records an outcome for `id` in the current run (no-op without one).

  `confirm` (optional) is checked when the ledger is written: an edit made in
  Igniter's buffer reaches the disk only if the run's changes are accepted,
  so an `:applied` that the file does not show by then is not recorded (the
  next run would otherwise read the edit as removed by the host).
  """
  @spec record(String.t(), outcome(), (-> boolean()) | nil) :: :ok
  def record(id, outcome, confirm \\ nil) when outcome in [:applied, :declined] do
    value = if confirm, do: {outcome, confirm}, else: outcome
    update(fn state -> put_in(state.outcomes[id], value) end)
  end

  defp record_declined(id, reason) do
    update(fn state ->
      state = put_in(state.outcomes[id], :declined)
      if reason == :removed, do: %{state | removed: [id | state.removed]}, else: state
    end)
  end

  defp update(fun) do
    case Process.get(@state_key) do
      nil -> :ok
      state -> Process.put(@state_key, fun.(state)) && :ok
    end
  end

  @doc "Reads a top-level value of the ledger (`begin/2`'s, else the file at `root`)."
  @spec get(atom(), term(), Path.t()) :: term()
  def get(key, default \\ nil, root \\ File.cwd!()) do
    ledger =
      case Process.get(@state_key) do
        nil -> load(root)
        state -> state.ledger
      end

    Map.get(ledger, key, default)
  end

  @doc """
  Sets a top-level value. Inside a run it is written by `flush/0`; outside
  one it is written to `root` at once.
  """
  @spec put(atom(), term(), Path.t()) :: :ok
  def put(key, value, root \\ File.cwd!()) do
    case Process.get(@state_key) do
      nil ->
        root |> load() |> Map.put(key, value) |> save(root)

      state ->
        Process.put(@state_key, %{
          state
          | ledger: Map.put(state.ledger, key, value),
            dirty: true
        })

        :ok
    end
  end

  @doc """
  Writes the run's outcomes into the ledger file — only when they change
  what the file says (the first run, which records what is present, always
  does).
  """
  @spec flush() :: :ok
  def flush do
    case Process.get(@state_key) do
      nil ->
        :ok

      state ->
        merged = Map.update!(state.ledger, :patches, &Map.merge(&1, confirmed(state.outcomes)))

        if merged != state.ledger or state.dirty do
          save(merged, state.root)
        end

        Process.put(@state_key, %{state | ledger: merged, outcomes: %{}, dirty: false})
        :ok
    end
  end

  defp confirmed(outcomes) do
    Enum.reduce(outcomes, %{}, fn
      {id, {outcome, confirm}}, acc ->
        if safe_confirm(confirm), do: Map.put(acc, id, outcome), else: acc

      {id, outcome}, acc ->
        Map.put(acc, id, outcome)
    end)
  end

  defp safe_confirm(confirm) do
    confirm.() == true
  rescue
    _ -> false
  end

  @doc """
  The closing report of a run: one block naming each patch that was recorded
  as applied and is now gone (so it was not re-added), with the flag that
  restores it. `""` when there is none.
  """
  @spec summary() :: String.t()
  def summary do
    case Process.get(@state_key) do
      %{removed: [_ | _] = removed} ->
        lines =
          removed
          |> Enum.reverse()
          |> Enum.uniq()
          |> Enum.map_join("\n", &"  • #{&1} — mix phoenix_kit.update --repair-patch #{&1}")

        """

        ℹ️  Left out because you removed them after an earlier update
           (recorded in #{@file_name}; nothing was re-added):
        #{lines}
        """

      _ ->
        ""
    end
  end
end

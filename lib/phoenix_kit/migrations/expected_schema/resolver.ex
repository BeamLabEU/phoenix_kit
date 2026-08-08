defmodule PhoenixKit.Migrations.ExpectedSchema.Resolver do
  @moduledoc """
  Finds the concrete `PhoenixKit.Migrations.ExpectedSchema.Behaviour`
  implementation to consume — the single choke point every P2 consumer
  (the repair engine, `mix phoenix_kit.repair`, `mix phoenix_kit.doctor`,
  `mix phoenix_kit.release_check`'s chain-hash assertion) goes through,
  so "the manifest is not generated yet" is handled identically everywhere
  instead of once per call site.

  ## Why this has to exist at all

  `PhoenixKit.Migrations.ExpectedSchema` — the tool-generated manifest — does
  not exist in this repository. It is produced from a real migrated scratch
  database (spec §5.1/§8.3) and lands with the squash PR (P3); everything in
  P2 has to build and run correctly *before* that happens. Every consumer
  must therefore treat "the module is absent" as an ordinary, expected
  runtime condition — not an exception to guard against defensively in each
  of them — which is exactly what `resolve/0` turns it into:
  `{:error, :not_generated}`, no raise, no crash, ever.

  ## Resolution order

    1. `Application.get_env(:phoenix_kit, :expected_schema_module)` — the
       test/override hook. Not read from `config/config.exs` anywhere in this
       library; set it with `Application.put_env/3` (and clean up with
       `on_exit/1` — this is process-global application config, not
       per-process state).
    2. `default_module/0` (`PhoenixKit.Migrations.ExpectedSchema`) — the real
       manifest, once P3 generates it.

  Either way, the resolved module must actually be loaded
  (`Code.ensure_loaded?/1`) *and* export `objects/1`, `data_invariants/1`, and
  `chain_hash/0` (checked via `__info__(:functions)` membership, not
  `function_exported?/3` — this codebase hit real async-test flakiness from
  that check running before a just-compiled test-support module was loaded
  into the process calling it; see `PhoenixKit.MigrationTest`'s `exports?/3`
  for the same fix applied previously). A misconfigured override pointing at
  some unrelated-but-loaded module therefore resolves to the same
  `{:error, :not_generated}` as a genuinely absent module, rather than
  surfacing as a confusing `UndefinedFunctionError` deep inside a caller —
  both cases mean "there is nothing usable to hand back".

  ## Usage

      case Resolver.resolve() do
        {:ok, module} ->
          module.objects(prefix)

        {:error, :not_generated} ->
          {:error, Resolver.not_generated_message()}
      end

  Testing against a fixture:

      setup do
        Application.put_env(:phoenix_kit, :expected_schema_module, PhoenixKit.Test.FixtureExpectedSchema)
        on_exit(fn -> Application.delete_env(:phoenix_kit, :expected_schema_module) end)
      end
  """

  @default_module PhoenixKit.Migrations.ExpectedSchema
  @not_generated_message "PhoenixKit manifest not generated yet (P2 pending scratch DB)"
  @required_exports [objects: 1, data_invariants: 1, chain_hash: 0]

  @typedoc "`resolve/0`'s return shape."
  @type resolution :: {:ok, module()} | {:error, :not_generated}

  @doc """
  The manifest module name every consumer resolves to absent an override —
  `PhoenixKit.Migrations.ExpectedSchema`, the module P3's squash PR generates.
  Exposed so callers/tests can reference it without repeating the literal
  atom (and so a future rename only has to change it here).
  """
  @spec default_module() :: module()
  def default_module, do: @default_module

  @doc """
  The exact wording every P2 consumer should surface for
  `{:error, :not_generated}`, so the message is identical whether it comes
  from the repair engine, `mix phoenix_kit.repair`, or `mix phoenix_kit.doctor`.
  """
  @spec not_generated_message() :: String.t()
  def not_generated_message, do: @not_generated_message

  @doc """
  Resolves the `PhoenixKit.Migrations.ExpectedSchema.Behaviour` implementation
  to consume. Never raises.

  Returns `{:ok, module}` when the resolved module is loaded and exports the
  full contract, `{:error, :not_generated}` otherwise (absent, not yet
  compiled, or loaded-but-not-conformant — see the moduledoc's "Resolution
  order" section for why those collapse to the same result).
  """
  @spec resolve() :: resolution()
  def resolve do
    module = configured_module()

    if Code.ensure_loaded?(module) and exports_contract?(module) do
      {:ok, module}
    else
      {:error, :not_generated}
    end
  end

  defp configured_module do
    Application.get_env(:phoenix_kit, :expected_schema_module, @default_module)
  end

  defp exports_contract?(module) do
    exported = module.__info__(:functions)
    Enum.all?(@required_exports, &(&1 in exported))
  end
end

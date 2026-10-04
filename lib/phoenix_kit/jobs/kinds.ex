defmodule PhoenixKit.Jobs.Kinds do
  @moduledoc """
  The registry of job kinds: the modules the enabled `PhoenixKit.Module`s declare
  (`job_kinds/0`) and those a host lists under `config :phoenix_kit, job_kinds:
  [...]`. A kind is looked up by the name stored on a run.
  """

  alias PhoenixKit.ModuleRegistry

  @doc "Every kind module known now."
  @spec all() :: [module()]
  def all do
    configured =
      :phoenix_kit
      |> Application.get_env(:job_kinds, [])
      |> List.wrap()
      |> Enum.filter(
        &(is_atom(&1) and Code.ensure_loaded?(&1) and function_exported?(&1, :kind, 0))
      )

    Enum.uniq(configured ++ ModuleRegistry.all_job_kinds())
  end

  @doc "The kind module named `kind`, or nil (its module is disabled or gone)."
  @spec get(String.t() | nil) :: module() | nil
  def get(kind) when is_binary(kind), do: Enum.find(all(), &(&1.kind() == kind))
  def get(_kind), do: nil

  @doc "The kind module of `run`."
  @spec for_run(PhoenixKit.Jobs.Run.t()) :: module() | nil
  def for_run(%{kind: kind}), do: get(kind)
end

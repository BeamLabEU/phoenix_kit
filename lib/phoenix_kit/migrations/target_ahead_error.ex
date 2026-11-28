defmodule PhoenixKit.Migrations.TargetAheadError do
  @moduledoc """
  Raised when a migration asks for a PhoenixKit version newer than the chain
  of the release now running — typically a `..._phoenix_kit_update_vNN_to_vMM.exs`
  step file written by a later release, replayed after the pin moved back.

  Fields: `:target` (the version asked for), `:chain_version` (this release's
  last version), `:db_version` (where the database is).
  """

  defexception [:target, :chain_version, :db_version]

  @type t :: %__MODULE__{
          target: pos_integer(),
          chain_version: pos_integer(),
          db_version: non_neg_integer()
        }

  @impl true
  def message(%__MODULE__{} = error) do
    "PhoenixKit migration asks for V#{error.target}, but this release's chain ends at " <>
      "V#{error.chain_version} (the database is at V#{error.db_version}). The migration " <>
      "file was written by a later PhoenixKit: move the dependency back to that release " <>
      "(or newer), or take the file out of priv/repo/migrations while this pin is in use."
  end
end

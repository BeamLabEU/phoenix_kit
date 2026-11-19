defmodule PhoenixKit.API.ModuleLabel do
  @moduledoc """
  A module's name as the API pages and mails show it: its `module_name/0`, translated by the
  gettext backend the module declares in its `permission_metadata/0` (the one the permissions
  matrix uses for its label), then by core's own catalogue. A module without a backend reads as
  before.

  Settings -> API, the "Waiting for approval" block, the consent screen and the mail about a new
  connection all name a module this way.
  """

  alias PhoenixKit.ModuleRegistry

  @doc """
  The name of `mod` (`%{key: key, name: name}`), translated for the current locale. A module that
  already carries its `:label` is not resolved again: resolving one asks every module for its
  metadata (`ModuleRegistry.permission_gettext/0`), which a page must not repeat for each row.
  """
  @spec label(map()) :: String.t()
  def label(%{label: label}) when is_binary(label), do: label
  def label(mod), do: label(mod, ModuleRegistry.permission_gettext())

  @doc """
  `label/1` with the backends of `ModuleRegistry.permission_gettext/0` read once by the caller,
  for a list of modules.
  """
  @spec label(map(), map()) :: String.t()
  def label(%{key: key, name: name}, backends) when is_map(backends) do
    with {backend, domain} <- Map.get(backends, key),
         translated when translated != name <- Gettext.dgettext(backend, domain, name) do
      translated
    else
      _ -> Gettext.gettext(PhoenixKitWeb.Gettext, name)
    end
  end
end

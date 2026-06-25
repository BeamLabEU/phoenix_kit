defmodule PhoenixKit.Users.Referrals do
  @moduledoc """
  Core-side runtime bridge to the optional `phoenix_kit_referrals` package.

  The referral-codes feature lives in the standalone `phoenix_kit_referrals`
  module. Core has **no compile-time dependency** on it — this facade resolves
  the installed module at runtime by its `PhoenixKit.Module` key (`"referrals"`)
  via `PhoenixKit.ModuleRegistry` and dispatches through it.

  When the package isn't installed (or doesn't export a given function) every
  call degrades safely: the system reads as disabled, lookups return `nil`, and
  `use_code/2` is a no-op. That lets the registration / OAuth / magic-link flows
  treat referrals as optional — with the module absent, the referral field never
  appears and nothing is recorded.

  The function surface here mirrors exactly what the signup flows call, so those
  call sites only had to swap their alias to this module.
  """

  alias PhoenixKit.ModuleRegistry

  @key "referrals"

  # Shape core reads from `get_config/0` when no module is installed.
  @disabled_config %{enabled: false, required: false}

  @doc """
  Referral-codes configuration map. Disabled defaults when the module is absent.
  """
  def get_config do
    case dispatch(:get_config, []) do
      {:ok, config} -> config
      :error -> @disabled_config
    end
  end

  @doc "Whether a referrals module is installed and enabled."
  def enabled? do
    get_config()[:enabled] == true
  end

  @doc "Look up a referral code struct by its string, or `nil`."
  def get_code_by_string(code_string) do
    case dispatch(:get_code_by_string, [code_string]) do
      {:ok, code} -> code
      :error -> nil
    end
  end

  @doc "Whether the given code is expired (`false` when the module is absent)."
  def expired?(code) do
    case dispatch(:expired?, [code]) do
      {:ok, result} -> result
      :error -> false
    end
  end

  @doc "Whether the given code hit its usage limit (`false` when absent)."
  def usage_limit_reached?(code) do
    case dispatch(:usage_limit_reached?, [code]) do
      {:ok, result} -> result
      :error -> false
    end
  end

  @doc """
  Record a use of `code_string` by `user_uuid`.

  No-op returning `{:error, :referrals_not_installed}` when the module is absent.
  """
  def use_code(code_string, user_uuid) do
    case dispatch(:use_code, [code_string, user_uuid]) do
      {:ok, result} -> result
      :error -> {:error, :referrals_not_installed}
    end
  end

  # Resolve the installed referrals module by key and call it. Returns
  # `{:ok, result}` or `:error` when nothing handles it. `apply/3` keeps the
  # target out of compile-time xref, so core needs no dependency on the package.
  defp dispatch(fun, args) do
    with mod when not is_nil(mod) <- ModuleRegistry.get_by_key(@key),
         true <- function_exported?(mod, fun, length(args)) do
      {:ok, apply(mod, fun, args)}
    else
      _ -> :error
    end
  end
end

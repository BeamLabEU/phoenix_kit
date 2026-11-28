defmodule PhoenixKit.Console do
  @moduledoc """
  Settings and modules from the console, for an install with nobody to sign in yet (or a
  script). The functions the mix tasks `mix phoenix_kit.settings` and
  `mix phoenix_kit.modules` call; in a release, where there is no `mix`, call them
  inside the running node:

      $ bin/my_app rpc 'PhoenixKit.Console.settings_set("project_title", "Acme") |> IO.inspect()'
      $ bin/my_app rpc 'PhoenixKit.Console.module_enable("crawlers") |> IO.inspect()'
      $ bin/my_app rpc 'PhoenixKit.Console.modules_list() |> IO.inspect()'

  They go through the functions the admin pages use, so the same validation applies:

    * **Settings** are the keys the admin settings forms own (`PhoenixKit.Settings.form_setting_keys/0`);
      any other key is `{:error, :unknown_key}`. A value is written by
      `PhoenixKit.Settings.update_settings/2` (the form's changeset, so an invalid value is
      `{:error, %Ecto.Changeset{}}`), and each change is a permanent `setting.changed`
      history entry with source `"console"`. A secret (an OAuth client secret) is never
      printed: `settings_get/1` and `settings_list/0` show `:secret` in its place.
    * **Modules** are switched with the module's own `enable_system/0` / `disable_system/0`,
      as the Modules page does, after the same dependency checks (Newsletters needs Emails;
      a module's own refusal, such as Legal's `:publishing_required`, comes back as is). Each
      switch is a permanent `module.enabled` / `module.disabled` activity entry of module
      `modules`, mode `"console"`, with no actor.

  A switch made from the mix task (its own VM) reaches a running node's caches when the
  cached value expires or the node restarts; the `rpc` form above takes effect at once.
  """

  alias PhoenixKit.Activity
  alias PhoenixKit.Admin.Events
  alias PhoenixKit.ModuleRegistry
  alias PhoenixKit.Settings

  @source "console"

  # --- Settings -----------------------------------------------------------------

  @typedoc "A setting as the console shows it; `:secret` stands in for a secret's value."
  @type setting :: %{key: String.t(), value: String.t() | :secret | nil}

  @doc "Every setting the console may read and write, sorted by key."
  @spec settings_list() :: [setting()]
  def settings_list do
    stored = Settings.list_all_settings()
    defaults = Settings.get_defaults()

    Settings.form_setting_keys()
    |> Enum.sort()
    |> Enum.map(fn key ->
      %{key: key, value: shown(key, Map.get(stored, key, Map.get(defaults, key)))}
    end)
  end

  @doc "The value of `key`, or `{:error, :unknown_key}`."
  @spec settings_get(String.t()) :: {:ok, String.t() | :secret | nil} | {:error, :unknown_key}
  def settings_get(key) when is_binary(key) do
    if known_setting?(key), do: {:ok, shown(key, current(key))}, else: {:error, :unknown_key}
  end

  @doc """
  Sets `key` to `value` through the settings form's validation (see the moduledoc).

  Returns `{:ok, value}` (what is stored now), `{:error, :unknown_key}`, or
  `{:error, %Ecto.Changeset{}}` for a value the form refuses.
  """
  @spec settings_set(String.t(), String.t()) ::
          {:ok, String.t() | :secret} | {:error, :unknown_key | Ecto.Changeset.t()}
  def settings_set(key, value) when is_binary(key) and is_binary(value) do
    if known_setting?(key) do
      write_setting(key, value)
    else
      {:error, :unknown_key}
    end
  end

  @doc "True when the console may read and write `key`."
  @spec known_setting?(String.t()) :: boolean()
  def known_setting?(key) when is_binary(key), do: key in Settings.form_setting_keys()

  # The form needs its required fields to validate. Only the key asked for and the
  # required fields the form says are blank are sent, the latter with what is stored
  # now, so nothing else is written.
  defp write_setting(key, value) do
    base = %{key => value}

    params =
      base
      |> Settings.validate_settings()
      |> blank_required()
      |> Enum.reject(&(&1 == key))
      |> Enum.reduce(base, &Map.put(&2, &1, form_value(&1)))

    case Settings.update_settings(params, source: @source) do
      {:ok, _updated} -> {:ok, shown(key, current(key))}
      {:error, %Ecto.Changeset{} = changeset} -> {:error, changeset}
    end
  end

  defp blank_required(%Ecto.Changeset{errors: errors}) do
    for {field, {_message, meta}} <- errors, meta[:validation] == :required, do: to_string(field)
  end

  defp form_value("new_user_default_role"), do: Settings.effective_new_user_default_role()
  defp form_value(key), do: current(key)

  defp current(key) do
    case Map.fetch(Settings.list_all_settings(), key) do
      {:ok, value} -> value
      :error -> Map.get(Settings.get_defaults(), key)
    end
  end

  defp shown(key, value) do
    if Settings.secret_setting?(key, nil) and value not in [nil, ""], do: :secret, else: value
  end

  # --- Modules ------------------------------------------------------------------

  @typedoc "A module as the console shows it."
  @type module_row :: %{key: String.t(), name: String.t(), enabled: boolean()}

  @doc "Every registered module with a key, sorted by key."
  @spec modules_list() :: [module_row()]
  def modules_list do
    ModuleRegistry.all_modules()
    |> Enum.filter(&(Code.ensure_loaded?(&1) and function_exported?(&1, :module_key, 0)))
    |> Enum.map(fn mod ->
      %{key: mod.module_key(), name: module_name(mod), enabled: enabled?(mod)}
    end)
    |> Enum.sort_by(& &1.key)
  end

  @doc """
  Switches the module `key` on. `{:ok, :enabled}` (also when it already was),
  `{:error, :unknown_module}`, `{:error, {:requires, "emails"}}` (Newsletters without Emails),
  or the module's own `{:error, reason}`.
  """
  @spec module_enable(String.t()) :: {:ok, :enabled} | {:error, term()}
  def module_enable(key) when is_binary(key), do: switch(key, true)

  @doc "Switches the module `key` off; the results mirror `module_enable/1`."
  @spec module_disable(String.t()) :: {:ok, :disabled} | {:error, term()}
  def module_disable(key) when is_binary(key), do: switch(key, false)

  defp switch(key, on?) do
    with {:ok, mod} <- find_module(key),
         :ok <- check_dependencies(key, on?) do
      cond do
        enabled?(mod) == on? -> {:ok, state(on?)}
        on? -> apply_switch(mod, key, :enable_system, true)
        true -> apply_switch(mod, key, :disable_system, false)
      end
    end
  end

  defp find_module(key) do
    case ModuleRegistry.get_by_key(key) do
      nil -> {:error, :unknown_module}
      mod -> {:ok, mod}
    end
  end

  # The Modules page's own rule (`PhoenixKitWeb.Live.Modules`): Newsletters only with Emails.
  defp check_dependencies("newsletters", true) do
    case find_module("emails") do
      {:ok, emails} -> if enabled?(emails), do: :ok, else: {:error, {:requires, "emails"}}
      {:error, _} -> {:error, {:requires, "emails"}}
    end
  end

  defp check_dependencies(_key, _on?), do: :ok

  defp apply_switch(mod, key, fun, on?) do
    case normalize(apply(mod, fun, [])) do
      :ok ->
        broadcast(key, on?)

        Activity.log("modules", if(on?, do: "module.enabled", else: "module.disabled"),
          mode: @source,
          permanent: true,
          resource_type: "module",
          metadata: %{"module" => key, "source" => @source}
        )

        {:ok, state(on?)}

      {:error, _reason} = error ->
        error
    end
  end

  # As the Modules page does; a console without the kit's PubSub just skips it.
  defp broadcast(key, on?) do
    if on?,
      do: Events.broadcast_module_enabled(key),
      else: Events.broadcast_module_disabled(key)
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp normalize(:ok), do: :ok
  defp normalize({:ok, _}), do: :ok
  defp normalize({:error, _reason} = error), do: error
  defp normalize(other), do: {:error, other}

  defp state(true), do: :enabled
  defp state(false), do: :disabled

  defp enabled?(mod) do
    function_exported?(mod, :enabled?, 0) and mod.enabled?() == true
  rescue
    _ -> false
  end

  defp module_name(mod) do
    if function_exported?(mod, :module_name, 0), do: mod.module_name(), else: inspect(mod)
  rescue
    _ -> inspect(mod)
  end
end

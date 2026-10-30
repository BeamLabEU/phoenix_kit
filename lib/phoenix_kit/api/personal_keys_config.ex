defmodule PhoenixKit.API.PersonalKeysConfig do
  @moduledoc """
  Settings of personal API keys (`PhoenixKit.API.Keys.create_personal_key/3`): how long
  one may live and how many a person may have.

  | Setting | Default | Allowed |
  |---|---|---|
  | `api_personal_key_max_days` | `90` | 1 to 365 |
  | `api_personal_key_max_count` | `5` | 1 to 50 |

  `api_personal_key_max_days` is both the ceiling of a personal key's expiry and the
  expiry the "My API keys" form proposes and a rotation gives the new key: the end of the
  UTC day that many days from today (`latest_expiry/0`). Lowering it does not shorten
  keys already issued. `api_personal_key_max_count` counts a person's live personal keys,
  a key in the grace period of a rotation included.

  A stored value that does not parse or is below its minimum reads as the default; one
  above its maximum reads as the maximum. A Settings read error reads as the default
  (`PhoenixKit.API.Config.int/2`).

  The same table drives the form on Settings -> API: `fields/0`, `current/0`,
  `validate/1` and `save/2`, all or nothing like `PhoenixKit.API.FlowConfig`'s.
  """

  alias PhoenixKit.API.Config
  alias PhoenixKit.Settings

  @fields [
    %{
      field: "max_days",
      setting: "api_personal_key_max_days",
      default: 90,
      min: 1,
      max: 365,
      reader: :max_days
    },
    %{
      field: "max_count",
      setting: "api_personal_key_max_count",
      default: 5,
      min: 1,
      max: 50,
      reader: :max_count
    }
  ]

  @doc "Days a personal key may live at most (`api_personal_key_max_days`)."
  @spec max_days() :: pos_integer()
  def max_days, do: read("api_personal_key_max_days")

  @doc "Live personal keys one person may have (`api_personal_key_max_count`)."
  @spec max_count() :: pos_integer()
  def max_count, do: read("api_personal_key_max_count")

  @doc """
  The latest expiry a personal key may have now: the end of the UTC day `max_days/0`
  days from today, as the form's dates are read.
  """
  @spec latest_expiry() :: DateTime.t()
  def latest_expiry,
    do: DateTime.new!(Date.add(Date.utc_today(), max_days()), ~T[23:59:59], "Etc/UTC")

  @doc "The two fields of the form, in the order the page shows them."
  @spec fields() :: [map()]
  def fields, do: @fields

  @doc "The current value of every form field, as the text the field shows."
  @spec current() :: %{String.t() => String.t()}
  def current do
    Map.new(@fields, fn %{field: field, reader: reader} ->
      {field, __MODULE__ |> apply(reader, []) |> Integer.to_string()}
    end)
  end

  @doc """
  Checks a submitted form. `{:ok, [{setting, integer}]}` when every field is a whole
  number inside its range; otherwise `{:error, fields}` naming every bad field
  (a missing field is bad, never the default).
  """
  @spec validate(map()) :: {:ok, [{String.t(), integer()}]} | {:error, [String.t()]}
  def validate(params) when is_map(params) do
    parsed =
      Enum.map(@fields, fn %{field: field, setting: setting, min: min, max: max} ->
        {field, setting, parse(Map.get(params, field), min, max)}
      end)

    case for({field, _setting, :error} <- parsed, do: field) do
      [] -> {:ok, for({_field, setting, {:ok, number}} <- parsed, do: {setting, number})}
      bad -> {:error, bad}
    end
  end

  def validate(_params), do: {:error, Enum.map(@fields, & &1.field)}

  @doc """
  Validates and writes a form. Returns the settings that changed. `opts` are the
  history options of `Settings.update_setting_with_module/4` (`actor_uuid:`,
  `source:`).
  """
  @spec save(map(), keyword()) :: {:ok, [String.t()]} | {:error, [String.t()] | :save_failed}
  def save(params, opts) do
    with {:ok, pairs} <- validate(params) do
      current = current()
      fields = Map.new(@fields, &{&1.setting, &1.field})

      changed =
        for {setting, number} <- pairs,
            Integer.to_string(number) != current[fields[setting]],
            do: {setting, number}

      results =
        Enum.map(changed, fn {setting, number} ->
          Settings.update_setting_with_module(setting, Integer.to_string(number), "api", opts)
        end)

      if Enum.all?(results, &match?({:ok, _setting}, &1)),
        do: {:ok, Enum.map(changed, &elem(&1, 0))},
        else: {:error, :save_failed}
    end
  end

  # --- reading ---------------------------------------------------------

  defp read(setting) do
    %{default: default, min: min, max: max} = Enum.find(@fields, &(&1.setting == setting))

    case Config.int(setting, default) do
      value when value > max -> max
      value when value >= min -> value
      _below_minimum -> default
    end
  end

  defp parse(value, min, max) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {number, ""} when number >= min and number <= max -> {:ok, number}
      _ -> :error
    end
  end

  defp parse(_value, _min, _max), do: :error
end

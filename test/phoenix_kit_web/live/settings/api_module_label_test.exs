defmodule PhoenixKitWeb.Live.Settings.ApiModuleLabelTest do
  @moduledoc """
  Settings -> API names each module by its `module_name/0`, translated. A module that
  declares a gettext backend in its `permission_metadata/0` (the same backend the
  permissions matrix uses for its label) is translated by that backend first; core's own
  catalogue is the fallback, so a module without one reads as before.
  """
  use ExUnit.Case, async: false

  alias PhoenixKit.ModuleRegistry
  alias PhoenixKit.API.ModuleLabel

  defmodule LabelledModule do
    @moduledoc false
    # The name is a msgid of core's "errors" domain only: it is translated through the
    # module's declared backend and domain, never through core's "default" catalogue.
    def module_key, do: "apilabeltest"
    def module_name, do: "can't be blank"
    def enabled?, do: true

    def permission_metadata do
      %{
        key: "apilabeltest",
        label: "can't be blank",
        icon: "hero-cube",
        description: "",
        gettext_backend: PhoenixKitWeb.Gettext,
        gettext_domain: "errors"
      }
    end
  end

  setup do
    ModuleRegistry.register(LabelledModule)
    previous = Gettext.get_locale(PhoenixKitWeb.Gettext)

    on_exit(fn ->
      ModuleRegistry.unregister(LabelledModule)
      Gettext.put_locale(PhoenixKitWeb.Gettext, previous)
    end)

    Gettext.put_locale(PhoenixKitWeb.Gettext, "ru")
    :ok
  end

  test "a module with its own backend is named in that backend's translation" do
    assert ModuleLabel.label(%{key: "apilabeltest", name: "can't be blank"}) ==
             "не может быть пустым"
  end

  test "a module without a backend is named through core's catalogue, as before" do
    assert ModuleLabel.label(%{key: "nobackend", name: "Users"}) ==
             Gettext.gettext(PhoenixKitWeb.Gettext, "Users")

    assert ModuleLabel.label(%{key: "nobackend", name: "Users"}) != "Users"
  end

  test "a name the module's backend does not translate falls back to core's catalogue" do
    assert ModuleLabel.label(%{key: "apilabeltest", name: "Users"}) ==
             Gettext.gettext(PhoenixKitWeb.Gettext, "Users")
  end

  test "a module that already carries its label is not resolved again" do
    assert ModuleLabel.label(%{key: "apilabeltest", name: "can't be blank", label: "Already"}) ==
             "Already"
  end
end

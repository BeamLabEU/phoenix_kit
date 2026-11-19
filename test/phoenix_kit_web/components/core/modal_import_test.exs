defmodule PhoenixKitWeb.Components.Core.ModalImportTest do
  @moduledoc """
  `Modal.max_width_class/1` and `Modal.max_height_style/1` are public (the
  resizable modal shares the first, and the placement tests call the second)
  but `use PhoenixKitWeb` must not import them: a module or a host with a
  function of its own by either name would stop compiling ("imported ...
  conflicts with local function").
  """
  use ExUnit.Case, async: true

  for kind <- [:live_view, :html, :live_component, :controller] do
    test "a module with `use PhoenixKitWeb, :#{kind}` can define its own max_width_class/1 and max_height_style/1" do
      name = "PhoenixKitWeb.ModalImportTest.Probe#{System.unique_integer([:positive])}"

      code = """
      defmodule #{name} do
        use PhoenixKitWeb, :#{unquote(kind)}

        defp max_width_class(_), do: "mine"
        defp max_height_style(_), do: "mine"

        def both, do: {max_width_class(:x), max_height_style(:x)}
      end
      """

      assert [{module, _binary}] = Code.compile_string(code)
      assert module.both() == {"mine", "mine"}
    end
  end
end

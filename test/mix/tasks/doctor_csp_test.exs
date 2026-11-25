defmodule Mix.Tasks.PhoenixKit.DoctorCspTest do
  @moduledoc """
  `mix phoenix_kit.doctor`, "Content-Security-Policy": a `csp_nonce_assign_key` of the wrong
  shape, or a nonce plug that may run after the integration plug, read as "no nonce" at
  runtime with nothing said. The doctor says it.
  """
  use ExUnit.Case, async: true

  alias Mix.Tasks.PhoenixKit.Doctor

  defp router(plugs) do
    """
    defmodule MyAppWeb.Router do
      pipeline :browser do
    #{Enum.map_join(plugs, "\n", &"    plug #{&1}")}
      end

      pipeline :api do
        plug :accepts, ["json"]
      end
    end
    """
  end

  test "nothing configured is fine" do
    assert {:pass, _} = Doctor.csp_verdict(nil, nil, router(["PhoenixKitWeb.Plugs.Integration"]))
  end

  test "an unusable value is named" do
    assert {:warn, message} = Doctor.csp_verdict("csp_nonce", "expected an atom", nil)
    assert message =~ "not usable"
    assert message =~ "expected an atom"
  end

  test "Integration last in the browser pipeline passes" do
    source = router([":fetch_session", "MyAppWeb.Plugs.CSP", "PhoenixKitWeb.Plugs.Integration"])
    assert {:pass, message} = Doctor.csp_verdict(:csp_nonce, nil, source)
    assert message =~ "last plug"
  end

  test "plugs after Integration are listed" do
    source =
      router([
        ":fetch_session",
        "PhoenixKitWeb.Plugs.Integration",
        "MyAppWeb.Plugs.CSP",
        ":other, 1"
      ])

    assert {:warn, message} = Doctor.csp_verdict(:csp_nonce, nil, source)
    assert message =~ "MyAppWeb.Plugs.CSP, :other"
  end

  test "a browser pipeline without Integration is said" do
    assert {:warn, message} = Doctor.csp_verdict(:csp_nonce, nil, router([":fetch_session"]))
    assert message =~ "was not found"
  end

  test "an unreadable router is not a failure" do
    assert {:pass, _} = Doctor.csp_verdict(:csp_nonce, nil, nil)
  end
end

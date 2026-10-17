defmodule PhoenixKitWeb.Components.Core.DateInputDiffTest do
  @moduledoc """
  A change elsewhere in the form must not resend the date field: a `{...}`
  spread at a component call switches the callee's change tracking off, and
  a resent field makes the client walk it again (and reset its text).

  Not covered, and resent whenever the form changes: `field={@form[:d]}` (and
  so `<.input type="date">`). Its values are derived from the field in the
  function head, which LiveView always treats as changed. The hook keeps a
  rejected text across such a resend.
  """
  use ExUnit.Case, async: true

  import Phoenix.Component
  import PhoenixKitWeb.Components.Core.DateInput

  alias Phoenix.LiveView.Diff

  defp direct(assigns) do
    ~H"""
    <date-host>
      <.date_input
        id="d"
        name="d"
        value={@value}
        format="d.m.Y"
        locale="en"
        week_start={1}
        today={~D[2026-10-16]}
      />
      <span>{@other}</span>
    </date-host>
    """
  end

  defp bare(assigns) do
    ~H"""
    <date-host>
      <.date_input
        id="d"
        name="d"
        value={@value}
        bare
        format="d.m.Y"
        locale="en"
        week_start={1}
        today={~D[2026-10-16]}
      />
      <span>{@other}</span>
    </date-host>
    """
  end

  # The second render's diff, as a string, when only the changes named in
  # `changed` happened.
  defp second_diff(fun, first, second, changed) do
    socket = %Phoenix.LiveView.Socket{}

    {_, prints, comps} =
      Diff.render(
        socket,
        fun.(Map.put(first, :__changed__, nil)),
        Diff.new_fingerprints(),
        Diff.new_components()
      )

    {diff, _, _} =
      Diff.render(socket, fun.(Map.put(second, :__changed__, changed)), prints, comps)

    inspect(diff, limit: :infinity, printable_limit: 200)
  end

  test "date_input: another assign changing does not resend the field" do
    diff =
      second_diff(
        &direct/1,
        %{value: ~D[2026-01-05], other: 1},
        %{value: ~D[2026-01-05], other: 2},
        %{other: true}
      )

    refute diff =~ "05.01.2026"
  end

  test "bare date_input: the same" do
    diff =
      second_diff(
        &bare/1,
        %{value: ~D[2026-01-05], other: 1},
        %{value: ~D[2026-01-05], other: 2},
        %{other: true}
      )

    refute diff =~ "05.01.2026"
  end

  test "the field is sent when its date changes" do
    diff =
      second_diff(
        &direct/1,
        %{value: ~D[2026-01-05], other: 1},
        %{value: ~D[2026-02-06], other: 1},
        %{value: true}
      )

    assert diff =~ "06.02.2026"
  end
end

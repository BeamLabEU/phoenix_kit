defmodule PhoenixKitWeb.Components.Core.DecimalInputTest do
  use ExUnit.Case, async: true

  import Phoenix.Component, only: [sigil_H: 2, to_form: 2]
  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]
  import PhoenixKitWeb.Components.Core.DecimalInput

  defp render(template), do: rendered_to_string(template)

  defp input_tag(html) do
    [tag] = Regex.run(~r/<input[^>]*name="[^"]*"[^>]*>/, html)
    tag
  end

  test "renders a text control with a decimal keyboard, never a number spinner" do
    assigns = %{}

    tag =
      render(~H"""
      <.decimal_input id="qty" name="qty" value={Decimal.new("2.50")} />
      """)
      |> input_tag()

    assert tag =~ ~s(type="text")
    assert tag =~ ~s(inputmode="decimal")
    assert tag =~ ~s(autocomplete="off")
    assert tag =~ ~s(value="2.5")
    refute tag =~ "step="
    refute tag =~ ~s(type="number")
  end

  test "a bound field supplies name, id, value and errors" do
    changeset =
      {%{}, %{qty: :decimal}}
      |> Ecto.Changeset.cast(%{"qty" => "abc"}, [:qty])
      |> Map.put(:action, :validate)

    assigns = %{form: to_form(changeset, as: "row")}

    html =
      render(~H"""
      <.decimal_input field={@form[:qty]} label="Quantity" />
      """)

    assert html =~ ~s(name="row[qty]")
    assert html =~ ~s(id="row_qty")
    assert html =~ ~s(value="abc")
    assert html =~ "Quantity"
    assert html =~ "input-error"
    assert html =~ "is invalid"
  end

  test "the raw text a user typed is echoed back unchanged, so a comma survives a round trip" do
    assigns = %{}

    tag =
      render(~H"""
      <.decimal_input id="qty" name="qty" value="2,5" />
      """)
      |> input_tag()

    assert tag =~ ~s(value="2,5")
  end

  test "numbers and decimals are shown normalized" do
    assigns = %{}

    html =
      render(~H"""
      <.decimal_input id="a" name="a" value={Decimal.new("1E+3")} />
      <.decimal_input id="b" name="b" value={2} />
      <.decimal_input id="c" name="c" value={nil} />
      """)

    assert html =~ ~s(value="1000")
    assert html =~ ~s(value="2")
    assert html =~ ~s(name="c" id="c" value="")
  end

  test "a unit suffix renders inside the field" do
    assigns = %{}

    html =
      render(~H"""
      <.decimal_input id="qty" name="qty" value={1} unit="kg" />
      """)

    assert html =~ ~s(<label class="input)
    assert html =~ "kg"
    assert html =~ ~s(aria-hidden="true")
  end

  test "class, wrapper_class, placeholder and phx attributes pass through" do
    assigns = %{}

    html =
      render(~H"""
      <.decimal_input
        id="qty"
        name="qty"
        value={1}
        class="input-sm text-right"
        wrapper_class="w-24"
        placeholder="0"
        phx-debounce="400"
        phx-blur="commit"
      />
      """)

    assert html =~ ~s(class="w-24")
    assert html =~ "input-sm text-right"
    assert html =~ ~s(placeholder="0")
    assert html =~ ~s(phx-debounce="400")
    assert html =~ ~s(phx-blur="commit")
  end

  test "the default layout renders one control, whether bare is omitted or false" do
    assigns = %{}

    for html <- [
          render(~H"""
          <.decimal_input id="q" name="value" value="0" />
          """),
          render(~H"""
          <.decimal_input id="q" name="value" value="0" unit="kg" />
          """)
        ] do
      assert length(Regex.scan(~r/<input/, html)) == 1
      assert html =~ ~r/\A<div phx-feedback-for="value"/
    end

    assert render(~H"""
           <.decimal_input id="q" name="value" value="0" label="Qty" bare={false} />
           """) ==
             render(~H"""
             <.decimal_input id="q" name="value" value="0" label="Qty" />
             """)
  end

  # The contrast `bare` exists for: the default layouts fill their width
  # (the plain control itself, or the unit variant's <label>), and the
  # unit variant's inner control grows inside that label.
  test "the default layouts keep their own classes on the control and the unit label" do
    assigns = %{}

    plain =
      render(~H"""
      <.decimal_input id="q" name="value" value="1" />
      """)
      |> input_tag()

    assert plain =~ ~s(class="input w-full transition-colors focus:input-primary)

    unit =
      render(~H"""
      <.decimal_input
        id="q"
        name="value"
        value="1"
        unit="kg"
        errors={["is invalid"]}
        placeholder="0"
      />
      """)

    [label] = Regex.run(~r/<label class="input[^"]*"/, unit)
    assert label =~ "w-full"
    assert label =~ "input-error"

    inner = input_tag(unit)
    assert inner =~ ~s(class="grow min-w-0")
    assert inner =~ ~s(placeholder="0")
  end

  describe "bare" do
    # A host that sets the control inside its own group — a daisyUI `join`
    # with a unit button, a table cell — gets the <input> alone: the
    # wrapper <div> would sit between `.join` and its `.join-item`.
    test "renders the control alone: no wrapper, label, unit or error list" do
      assigns = %{}

      html =
        render(~H"""
        <.decimal_input
          bare
          id="q"
          name="value"
          value="0"
          label="Quantity"
          unit="kg"
          errors={["is invalid"]}
          wrapper_class="mb-4"
          class="join-item w-20 text-center"
        />
        """)

      assert html =~ ~r/\A<input [^>]*\/?>\z/
      assert html =~ ~s(id="q")
      refute html =~ "<div"
      refute html =~ "<label"
      refute html =~ ">Quantity<"
      refute html =~ "kg"
      refute html =~ "is invalid"
      refute html =~ "mb-4"
    end

    test "keeps what makes it a decimal control: text, decimal keyboard, no autofill" do
      assigns = %{}

      tag =
        render(~H"""
        <.decimal_input bare id="q" name="value" value={Decimal.new("2.50")} />
        """)
        |> input_tag()

      assert tag =~ ~s(type="text")
      assert tag =~ ~s(inputmode="decimal")
      assert tag =~ ~s(autocomplete="off")
      assert tag =~ ~s(value="2.5")
    end

    test "the host's classes go on the control, with no full width to fight them" do
      assigns = %{}

      tag =
        render(~H"""
        <.decimal_input bare id="q" name="value" value="1" class="join-item w-20" />
        """)
        |> input_tag()

      assert tag =~ "input "
      assert tag =~ "join-item w-20"
      refute tag =~ "w-full"
      refute tag =~ "input-error"
    end

    test "a bound field supplies name, id, value and errors to the bare control too" do
      changeset =
        {%{}, %{qty: :decimal}}
        |> Ecto.Changeset.cast(%{"qty" => "abc"}, [:qty])
        |> Map.put(:action, :validate)

      assigns = %{form: to_form(changeset, as: "row")}

      html =
        render(~H"""
        <.decimal_input bare field={@form[:qty]} label="Quantity" />
        """)

      assert html =~ ~r/\A<input [^>]*\/?>\z/
      assert html =~ ~s(name="row[qty]")
      assert html =~ ~s(id="row_qty")
      assert html =~ ~s(value="abc")
      assert html =~ "input-error"
      refute html =~ "is invalid"
    end

    test "a label has nowhere to render, so it names the control" do
      assigns = %{}

      tag =
        render(~H"""
        <.decimal_input bare id="q" name="value" value="1" label="Quantity" />
        """)
        |> input_tag()

      assert tag =~ ~s(aria-label="Quantity")
    end

    test "the host's own aria-label wins over the label" do
      assigns = %{}

      html =
        render(~H"""
        <.decimal_input bare id="q" name="value" value="1" label="Quantity" aria-label="Qty in kg" />
        """)

      assert html =~ ~s(aria-label="Qty in kg")
      assert length(Regex.scan(~r/aria-label=/, html)) == 1
    end

    test "no label and no aria-label adds no empty name" do
      assigns = %{}

      html =
        render(~H"""
        <.decimal_input bare id="q" name="value" value="1" label="" />
        """)

      refute html =~ "aria-label"
    end

    test "errors still mark the control" do
      assigns = %{}

      tag =
        render(~H"""
        <.decimal_input bare id="q" name="value" value="x" errors={["is invalid"]} />
        """)
        |> input_tag()

      assert tag =~ "input-error"
    end

    test "the zero handlers and the host's own, chained, and phx attributes all stay" do
      assigns = %{}

      tag =
        render(~H"""
        <.decimal_input
          bare
          id="q"
          name="value"
          value="0"
          onfocus="hostFocus()"
          phx-blur="qty_commit"
          phx-value-uuid="u-1"
          aria-label="Quantity"
        />
        """)
        |> input_tag()

      assert tag =~ "data-pk-zero-clear"
      assert tag =~ ~s|onfocus="hostFocus()"|
      assert tag =~ ~s(phx-blur="qty_commit")
      assert tag =~ ~s(phx-value-uuid="u-1")
      assert tag =~ ~s(aria-label="Quantity")
    end
  end

  test "required renders the marker next to the label" do
    assigns = %{}

    html =
      render(~H"""
      <.decimal_input id="qty" name="qty" value={1} label="Qty" required />
      """)

    assert html =~ "text-error"
    assert html =~ ~s(required)
  end

  defp zero_tag(extra \\ %{}) do
    assigns = %{extra: extra}

    render(~H"""
    <.decimal_input id="qty" name="qty" value={Decimal.new("0")} {@extra} />
    """)
    |> input_tag()
  end

  # The behaviour is listeners in phoenix_kit.js keyed on this attribute
  # (test/js/declared_handlers.test.cjs runs them); an inline handler would
  # be blocked by a Content-Security-Policy without 'unsafe-inline'.
  test "the control asks for the zero behaviour with an attribute, not inline handlers" do
    tag = zero_tag()

    assert tag =~ "data-pk-zero-clear"
    for name <- ~w(onfocus onblur onkeydown), do: refute(tag =~ ~s( #{name}="))
  end

  test "a host's own onfocus/onblur/onkeydown are rendered as the host wrote them" do
    tag =
      zero_tag(%{onfocus: "HOST_FOCUS()", onblur: "HOST_BLUR()", onkeydown: "HOST_KEY()"})

    assert tag =~ ~s| onfocus="HOST_FOCUS()"|
    assert tag =~ ~s| onblur="HOST_BLUR()"|
    assert tag =~ ~s| onkeydown="HOST_KEY()"|
    assert tag =~ "data-pk-zero-clear"
  end

  test "the unit variant asks for the same behaviour" do
    assigns = %{}

    tag =
      render(~H"""
      <.decimal_input id="w" name="w" value={Decimal.new("0")} unit="kg" />
      """)
      |> input_tag()

    assert tag =~ "data-pk-zero-clear"
  end
end

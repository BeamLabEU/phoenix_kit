defmodule PhoenixKitWeb.Components.Core.InputTest do
  use ExUnit.Case, async: true

  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]
  import PhoenixKitWeb.Components.Core.Input

  defp render(template), do: template |> rendered_to_string() |> LazyHTML.from_fragment()

  defp attr(doc, selector, name) do
    doc |> LazyHTML.query(selector) |> LazyHTML.attribute(name)
  end

  describe "hint" do
    test "renders under the field and describes it" do
      assigns = %{}

      doc =
        render(~H"""
        <.input id="limit" name="limit" value="5" label="Limit" hint="Per minute" />
        """)

      assert doc |> LazyHTML.query("p#limit-help") |> LazyHTML.text() =~ "Per minute"
      assert attr(doc, "input#limit", "aria-describedby") == ["limit-help"]
    end

    test "keeps an aria-describedby the caller gave" do
      assigns = %{}

      doc =
        render(~H"""
        <.input id="limit" name="limit" value="5" hint="Per minute" aria-describedby="other" />
        """)

      assert attr(doc, "input#limit", "aria-describedby") == ["other limit-help"]
    end

    test "without a hint nothing changes" do
      assigns = %{}

      doc =
        render(~H"""
        <.input id="limit" name="limit" value="5" label="Limit" />
        """)

      assert doc |> LazyHTML.query("#limit-help") |> Enum.count() == 0
      assert attr(doc, "input#limit", "aria-describedby") == []
    end

    test "a date input carries the hint too" do
      assigns = %{}

      doc =
        render(~H"""
        <.input id="due" name="due" type="date" value="" label="Due" hint="Optional" />
        """)

      assert doc |> LazyHTML.query("p#due-help") |> LazyHTML.text() =~ "Optional"
      # The date widget's own live region keeps its id and stays described too.
      assert [described] = attr(doc, "input#due", "aria-describedby")
      assert String.split(described) == ["due-help", "due-hint"]
    end
  end

  describe "wrap_label" do
    test "lets a long label wrap" do
      assigns = %{}

      doc =
        render(~H"""
        <.input id="limit" name="limit" value="5" label="A long label" wrap_label />
        """)

      [class] = attr(doc, "label[for=limit]", "class")
      assert class =~ "whitespace-normal"
    end

    test "is off by default: the label stays as it was" do
      assigns = %{}

      doc =
        render(~H"""
        <.input id="limit" name="limit" value="5" label="A long label" />
        """)

      assert attr(doc, "label[for=limit]", "class") == ["label mb-2"]
    end
  end

  describe "password_toggle" do
    test "puts an eye button beside the field, outside any label" do
      assigns = %{}

      doc =
        render(~H"""
        <.input id="pw" name="user[password]" type="password" value="" password_toggle />
        """)

      [click] = attr(doc, "button[data-pk-password-toggle]", "phx-click")
      assert click =~ ~s([id=\\"pw\\"])
      assert attr(doc, "button[data-pk-password-toggle]", "type") == ["button"]
      assert attr(doc, "button[data-pk-password-toggle]", "aria-label") == ["Show password"]
      assert attr(doc, "button[data-pk-password-toggle]", "aria-pressed") == ["false"]
      assert attr(doc, "button[data-pk-password-toggle]", "aria-controls") == ["pw"]
      assert doc |> LazyHTML.query("div.relative > input#pw") |> Enum.count() == 1
    end

    test "with the icon slot the button stays out of the label, or it names the input" do
      assigns = %{}

      doc =
        render(~H"""
        <.input id="pw" name="pw" type="password" value="" password_toggle>
          <:icon><span>i</span></:icon>
        </.input>
        """)

      assert doc |> LazyHTML.query("label.input input#pw") |> Enum.count() == 1
      assert doc |> LazyHTML.query("label button") |> Enum.empty?()
      assert doc |> LazyHTML.query("div.relative > button") |> Enum.count() == 1
    end

    test "a revealed field is kept from spellcheck and capitalization" do
      assigns = %{}

      doc =
        render(~H"""
        <.input id="pw" name="pw" type="password" value="" password_toggle />
        """)

      assert attr(doc, "input#pw", "spellcheck") == ["false"]
      assert attr(doc, "input#pw", "autocapitalize") == ["none"]
      assert attr(doc, "input#pw", "autocorrect") == ["off"]
    end

    test "without an id one comes from the name, or the button has nothing to target" do
      assigns = %{}

      doc =
        render(~H"""
        <.input name="user[password]" type="password" value="" password_toggle />
        """)

      assert attr(doc, "input", "id") == ["user_password_"]
      assert attr(doc, "button", "aria-controls") == ["user_password_"]
    end

    test "is off by default: a password field stays as it was" do
      assigns = %{}

      doc =
        render(~H"""
        <.input id="pw" name="pw" type="password" value="" />
        """)

      assert doc |> LazyHTML.query("button") |> Enum.empty?()
      assert doc |> LazyHTML.query("div.relative") |> Enum.empty?()
      assert attr(doc, "input#pw", "spellcheck") == []
    end

    test "means nothing on another type" do
      assigns = %{}

      doc =
        render(~H"""
        <.input id="name" name="name" type="text" value="" password_toggle />
        """)

      assert doc |> LazyHTML.query("button") |> Enum.empty?()
    end
  end
end

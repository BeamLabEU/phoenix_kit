defmodule PhoenixKitWeb.Components.Core.DateInputTest do
  # async: false — one test flips the `native_date_inputs` env.
  use ExUnit.Case, async: false

  import Phoenix.Component, only: [sigil_H: 2, to_form: 2]
  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]
  import PhoenixKitWeb.Components.Core.DateInput
  import PhoenixKitWeb.Components.Core.Input, only: [input: 1]

  @today ~D[2026-10-16]

  defp render(template), do: rendered_to_string(template)

  # The opening tag of the element carrying `attr`.
  defp tag(html, attr) do
    [tag] = Regex.run(~r/<(?:input|button|div)\b[^>]*\b#{attr}\b[^>]*>/s, html)
    tag
  end

  defp text_tag(html), do: tag(html, "data-date-text")
  defp value_tag(html), do: tag(html, "data-date-value")

  defp date(extra \\ []) do
    assigns = %{
      extra:
        Keyword.merge(
          [
            id: "due",
            name: "order[due]",
            value: ~D[2026-01-05],
            format: "d.m.Y",
            locale: "et",
            week_start: 1,
            today: @today
          ],
          extra
        )
    }

    render(~H"""
    <.date_input {@extra} />
    """)
  end

  describe "visible text in the site format" do
    for {format, text} <- [
          {"Y-m-d", "2026-01-05"},
          {"m/d/Y", "01/05/2026"},
          {"d/m/Y", "05/01/2026"},
          {"d.m.Y", "05.01.2026"},
          {"d-m-Y", "05-01-2026"},
          {"F j, Y", "January 5, 2026"}
        ] do
      test "format #{format}" do
        html = date(format: unquote(format))
        assert text_tag(html) =~ ~s(value="#{unquote(text)}")
        assert html =~ ~s(data-format="#{unquote(format)}")
        # The value element keeps the ISO value whatever the format is.
        assert value_tag(html) =~ ~s(value="2026-01-05")
      end
    end

    test "an unknown format falls back to Y-m-d, as format_date/2 does" do
      assert text_tag(date(format: "d.m")) =~ ~s(value="2026-01-05")
      assert date(format: "d.m") =~ ~s(data-format="Y-m-d")
    end

    test "the default format and today need no database" do
      assigns = %{}

      html =
        render(~H"""
        <.date_input id="x" name="x" value={~D[2026-01-05]} />
        """)

      assert text_tag(html) =~ ~s(value="2026-01-05")
      assert html =~ ~r/data-today="\d{4}-\d{2}-\d{2}"/
    end

    test "the placeholder is the format pattern, not a date" do
      assert text_tag(date()) =~ ~s(placeholder="dd.mm.yyyy")
      assert text_tag(date(format: "m/d/Y")) =~ ~s(placeholder="mm/dd/yyyy")
      assert text_tag(date(placeholder: "pick")) =~ ~s(placeholder="pick")
    end

    test "text mode: a textual format gets the text keyboard" do
      assert text_tag(date()) =~ ~s(inputmode="numeric")
      assert text_tag(date(format: "F j, Y")) =~ ~s(inputmode="text")
    end

    test "a DateTime and a NaiveDateTime are shown as dates" do
      assert text_tag(date(value: ~U[2026-01-05 10:00:00Z])) =~ ~s(value="05.01.2026")
      assert value_tag(date(value: ~N[2026-01-05 10:00:00])) =~ ~s(value="2026-01-05")
    end

    test "an ISO string is understood; anything else is echoed unchanged" do
      html = date(value: "2026-01-05")
      assert text_tag(html) =~ ~s(value="05.01.2026")

      html = date(value: "5.1.26")
      assert text_tag(html) =~ ~s(value="5.1.26")
      assert value_tag(html) =~ ~s(value="5.1.26")
    end

    test "nil and empty are empty in both elements" do
      for v <- [nil, ""] do
        html = date(value: v)
        assert text_tag(html) =~ ~s(value="")
        assert value_tag(html) =~ ~s(value="")
      end
    end
  end

  describe "markup" do
    test "the visible input has the caller's id and no name; the value element has the name" do
      html = date()
      text = text_tag(html)
      value = value_tag(html)

      assert text =~ ~s(id="due")
      assert text =~ ~s(type="text")
      refute text =~ ~s(name=)
      assert value =~ ~s(type="date")
      assert value =~ ~s(id="due-value")
      assert value =~ ~s(name="order[due]")
      assert value =~ ~s(tabindex="-1")
      # Rendered but invisible: not hidden / display:none.
      assert value =~ "opacity-0"
      assert value =~ "pointer-events-none"
      refute value =~ ~s(type="hidden")
      refute value =~ "display:none"
    end

    test "the wrapper carries the hook and the server data" do
      html = date(min: ~D[2026-01-01], max: "2026-12-31", week_start: 7, locale: "de_AT")
      wrap = tag(html, "phx-hook")

      assert wrap =~ ~s(id="due-wrap")
      assert wrap =~ ~s(phx-hook="PkDateInput")
      assert wrap =~ ~s(data-min="2026-01-01")
      assert wrap =~ ~s(data-max="2026-12-31")
      assert wrap =~ ~s(data-today="2026-10-16")
      # ISO Sunday (7) is Cally's 0; `_` becomes `-`.
      assert wrap =~ ~s(data-week-start="0")
      assert wrap =~ ~s(data-locale="de-AT")
      assert wrap =~ ~s(data-expected="Expected 16.10.2026")
      assert value_tag(html) =~ ~s(min="2026-01-01")
      assert value_tag(html) =~ ~s(max="2026-12-31")
    end

    test "week_start accepts the Settings string and falls back to Monday" do
      assert tag(date(week_start: "3"), "phx-hook") =~ ~s(data-week-start="3")
      assert tag(date(week_start: "junk"), "phx-hook") =~ ~s(data-week-start="1")
    end

    test "a malformed locale falls back to en" do
      assert tag(date(locale: "not a tag!"), "phx-hook") =~ ~s(data-locale="en")
    end

    test "the id is derived from the name when none is given" do
      assigns = %{}

      html =
        render(~H"""
        <.date_input
          name="value[from]"
          value={nil}
          format="d.m.Y"
          locale="en"
          week_start={1}
          today={~D[2026-10-16]}
        />
        """)

      assert html =~ ~s(id="value-from")
      assert html =~ ~s(id="value-from-wrap")
      assert html =~ ~s(id="value-from-value")
    end

    test "size sets the daisyUI modifier" do
      assert text_tag(date(size: "xs")) =~ "input-xs"
      assert text_tag(date(size: "sm")) =~ "input-sm"
      refute text_tag(date()) =~ "input-xs"
    end

    test "a label is tied to the visible input and shows the required marker" do
      html = date(label: "Due", required: true)
      assert html =~ ~s(for="due")
      assert html =~ "Due"
      assert html =~ ~s(text-error)
    end
  end

  describe "the clear button" do
    defp clear_tag(html), do: Regex.run(~r/<button[^>]*data-clear[^>]*>/s, html)

    test "shown for a filled optional field" do
      [tag] = clear_tag(date())
      refute tag =~ "hidden"
      assert tag =~ ~s(tabindex="-1")
      assert tag =~ ~s(aria-label="Clear date")
    end

    test "rendered but hidden while the field is empty" do
      [tag] = clear_tag(date(value: nil))
      assert tag =~ "hidden"
    end

    test "not rendered when required, disabled or readonly" do
      assert clear_tag(date(required: true)) == nil
      assert clear_tag(date(disabled: true)) == nil
      assert clear_tag(date(readonly: true)) == nil
    end

    test "the calendar button is a tab stop" do
      assert tag(date(), "data-open") =~ ~s(tabindex="0")
      assert tag(date(), "data-open") =~ ~s(aria-label="Open calendar")
    end
  end

  describe "accessibility and routing details" do
    test "the calendar button names its popup; the popup is a labelled dialog" do
      html = date(label: "Due")
      button = tag(html, "data-open")
      assert button =~ ~s(aria-haspopup="dialog")
      assert button =~ ~s(aria-expanded="false")
      assert button =~ ~s(aria-controls="due-popup")
      [popup] = Regex.run(~r/<div[^>]*id="due-popup"[^>]*>/s, html)
      assert popup =~ ~s(role="dialog")
      assert popup =~ ~s(aria-label="Due")
    end

    test "style, title and focus/key handlers go to the visible input" do
      html = date(style: "width: 9rem", title: "T", onfocus: "f()", onkeyup: "k()")

      for attr <- [~s(style="width: 9rem"), ~s(title="T"), "onfocus=\"f()\"", "onkeyup=\"k()\""] do
        assert text_tag(html) =~ attr
        refute value_tag(html) =~ attr
      end
    end

    test "the button padding follows what is on the right" do
      assert text_tag(date()) =~ "pr-14"
      assert text_tag(date(required: true)) =~ "pr-9"
      assert text_tag(date(size: "xs", required: true)) =~ "pr-7"
    end

    test "html: a map of attributes behaves like rest" do
      html = date(html: %{"phx-change": "c", "phx-blur": "b", "phx-debounce": "9"})
      assert value_tag(html) =~ ~s(phx-change="c")
      assert text_tag(html) =~ ~s(phx-blur="b")
      refute html =~ "phx-debounce"
    end
  end

  describe "range, form and popup details" do
    test "min/max give a message for a date outside the range, in the site format" do
      wrap = fn extra -> tag(date(extra), "phx-hook") end

      assert wrap.(min: ~D[2026-10-01], max: ~D[2026-10-31]) =~
               ~s(data-range-message="Pick a date between 01.10.2026 and 31.10.2026")

      assert wrap.(min: ~D[2026-10-01]) =~
               ~s(data-range-message="Pick a date on or after 01.10.2026")

      assert wrap.(max: "2026-10-31") =~
               ~s(data-range-message="Pick a date on or before 31.10.2026")

      refute wrap.([]) =~ "data-range-message"
    end

    test "Today is disabled when today lies outside min/max" do
      today_button = fn extra ->
        hd(Regex.run(~r/<button[^>]*data-popup-today[^>]*>/s, date(extra)))
      end

      refute today_button.([]) =~ "disabled"
      assert today_button.(min: ~D[2026-10-17]) =~ "disabled"
      assert today_button.(max: ~D[2026-10-15]) =~ "disabled"
      refute today_button.(min: ~D[2026-10-16], max: ~D[2026-10-16]) =~ "disabled"
    end

    test "form= goes to both inputs, so Enter in the text submits that form" do
      html = date(form: "other-form")
      assert text_tag(html) =~ ~s(form="other-form")
      assert value_tag(html) =~ ~s(form="other-form")
    end

    test "native honours the html map" do
      html = date(native: true, html: %{"phx-change": "c", "data-x": "y"})
      assert html =~ ~s(phx-change="c")
      assert html =~ ~s(data-x="y")
    end

    test "the popup is labelled Calendar when the field has no label" do
      [popup] = Regex.run(~r/<div[^>]*id="due-popup"[^>]*>/s, date())
      assert popup =~ ~s(aria-label="Calendar")
    end
  end

  describe "calendar popup" do
    test "a template carries the calendar and the server's strings" do
      html = date()

      assert html =~ "data-popup-template"
      assert html =~ ~r/<calendar-date[^>]*class="cally"/
      assert html =~ ~s(slot="previous")
      assert html =~ ~s(slot="next")
      assert html =~ "<calendar-month>"
      assert html =~ "Previous month"
      assert html =~ "Next month"
      assert html =~ ~r/<button[^>]*data-popup-today[^>]*>\s*Today/
      assert html =~ ~r/<button[^>]*data-popup-clear[^>]*>\s*Clear/
    end

    test "the popup container is a manual popover LiveView leaves alone" do
      html = date()
      [popup] = Regex.run(~r/<div[^>]*id="due-popup"[^>]*>/s, html)

      assert popup =~ ~s(id="due-popup")
      assert popup =~ ~s(popover="manual")
      assert popup =~ ~s(phx-update="ignore")
      # The UA centres a popover with `inset: 0; margin: auto`: undone for positioning.
      assert popup =~ "inset-auto"
      assert popup =~ "m-0"
    end

    test "footer Clear follows the ✕ rules" do
      refute date(required: true) =~ "data-popup-clear"
      assert date(required: true) =~ "data-popup-today"
    end

    test "disabled and readonly fields have no popup" do
      for extra <- [[disabled: true], [readonly: true]] do
        html = date(extra)
        refute html =~ "-popup"
        refute html =~ "calendar-date"
      end
    end

    test "native has no popup or hook" do
      refute date(native: true) =~ "calendar-date"
    end
  end

  describe "attribute routing" do
    test "required and readonly go to the visible input only" do
      html = date(required: true, readonly: true)
      assert text_tag(html) =~ "required"
      assert text_tag(html) =~ "readonly"
      refute value_tag(html) =~ "required"
      refute value_tag(html) =~ "readonly"
    end

    test "disabled goes to both" do
      html = date(disabled: true)
      assert text_tag(html) =~ "disabled"
      assert value_tag(html) =~ "disabled"
      refute html =~ "data-open"
    end

    test "phx-debounce is dropped, focus and key bindings go to the visible input" do
      html =
        date(
          "phx-debounce": "blur",
          "phx-blur": "b",
          "phx-keydown": "k",
          onkeydown: "x()",
          "aria-label": "Deadline",
          "phx-change": "chg",
          form: "f1",
          "data-x": "y"
        )

      refute html =~ "phx-debounce"
      text = text_tag(html)
      value = value_tag(html)

      for attr <- [
            ~s(phx-blur="b"),
            ~s(phx-keydown="k"),
            "onkeydown=\"x()\"",
            ~s(aria-label="Deadline")
          ] do
        assert text =~ attr
        refute value =~ attr
      end

      assert text =~ ~s(form="f1")

      for attr <- [~s(phx-change="chg"), ~s(form="f1"), ~s(data-x="y")] do
        assert value =~ attr
        if attr != ~s(form="f1"), do: refute(text =~ attr)
      end
    end
  end

  describe "errors" do
    test "FormField errors mark the input and render under it" do
      changeset =
        {%{}, %{due: :date}}
        |> Ecto.Changeset.cast(%{"due" => "2026-01-05"}, [:due])
        |> Ecto.Changeset.add_error(:due, "is bad")
        |> Map.put(:action, :validate)

      assigns = %{form: to_form(changeset, as: "order")}

      html =
        render(~H"""
        <.date_input field={@form[:due]} format="d.m.Y" locale="en" week_start={1} today={~D[2026-10-16]} />
        """)

      text = text_tag(html)
      assert text =~ ~s(id="order_due")
      assert text =~ "input-error"
      assert text =~ ~s(aria-invalid="true")
      assert text =~ "data-has-errors"
      assert text =~ ~s(value="05.01.2026")
      assert value_tag(html) =~ ~s(name="order[due]")
      assert html =~ "is bad"
    end

    test "no errors, no marks" do
      text = text_tag(date())
      refute text =~ "input-error"
      refute text =~ "aria-invalid"
    end
  end

  describe "bare" do
    test "no label, outer wrapper or error list; the label becomes aria-label" do
      html = date(bare: true, label: "From", errors: ["x"])
      refute html =~ "phx-feedback-for"
      refute html =~ "<label"
      refute html =~ "text-error"
      assert text_tag(html) =~ ~s(aria-label="From")
      assert text_tag(html) =~ "input-error"
      refute text_tag(html) =~ "w-full"
      assert html =~ "inline-block"
    end

    test "an explicit aria-label wins" do
      assert text_tag(date(bare: true, label: "From", "aria-label": "Own")) =~
               ~s(aria-label="Own")
    end
  end

  describe "native" do
    test "renders today's plain date input" do
      html = date(native: true, "phx-debounce": "300")

      assert html =~ ~s(type="date")
      assert html =~ ~s(name="order[due]")
      assert html =~ ~s(id="due")
      assert html =~ ~s(value="2026-01-05")
      assert html =~ ~s(phx-debounce="300")
      refute html =~ "phx-hook"
      refute html =~ "data-date-text"
    end
  end

  describe "<.input type=\"date\">" do
    defp input_date(extra \\ []) do
      assigns = %{
        extra:
          Keyword.merge(
            [type: "date", id: "d1", name: "row[d]", value: ~D[2026-01-05]],
            extra
          )
      }

      render(~H"""
      <.input {@extra} />
      """)
    end

    test "delegates to date_input" do
      html = input_date(label: "When", min: "2026-01-01", max: "2026-12-31", required: true)

      assert html =~ ~s(phx-hook="PkDateInput")
      assert html =~ ~s(for="d1")
      assert value_tag(html) =~ ~s(name="row[d]")
      assert value_tag(html) =~ ~s(min="2026-01-01")
      assert value_tag(html) =~ ~s(max="2026-12-31")
      assert text_tag(html) =~ "required"
    end

    test "size is the HTML size there, so it is not passed on" do
      html = input_date(size: "20")
      refute html =~ ~s(size="20")
      refute text_tag(html) =~ "input-xs"
    end

    test "per-call native keeps the plain input" do
      html = input_date(native: true)
      assert html =~ ~s(<input type="date")
      refute html =~ "phx-hook"
    end

    test "the host opt-out restores the plain input everywhere" do
      Application.put_env(:phoenix_kit, :native_date_inputs, true)
      on_exit(fn -> Application.delete_env(:phoenix_kit, :native_date_inputs) end)

      html = input_date()
      assert html =~ ~s(<input type="date")
      refute html =~ "phx-hook"
    end

    test "other types are untouched" do
      assigns = %{}

      html =
        render(~H"""
        <.input type="datetime-local" id="t" name="t" value="2026-01-05T10:00" />
        """)

      assert html =~ ~s(type="datetime-local")
      refute html =~ "phx-hook"
    end

    test "a bound field delegates with its name, id and errors" do
      changeset =
        {%{}, %{due: :date}}
        |> Ecto.Changeset.cast(%{"due" => "2026-01-05"}, [:due])
        |> Ecto.Changeset.add_error(:due, "is bad")
        |> Map.put(:action, :validate)

      assigns = %{form: to_form(changeset, as: "order")}

      html =
        render(~H"""
        <.input field={@form[:due]} type="date" />
        """)

      assert text_tag(html) =~ ~s(id="order_due")
      assert value_tag(html) =~ ~s(name="order[due]")
      assert html =~ "is bad"
    end
  end
end

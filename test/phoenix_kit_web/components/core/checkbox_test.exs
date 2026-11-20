defmodule PhoenixKitWeb.Components.Core.CheckboxTest do
  use ExUnit.Case, async: true

  import Phoenix.Component, only: [sigil_H: 2, to_form: 2]
  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]
  import PhoenixKitWeb.Components.Core.Checkbox

  defp render(template), do: rendered_to_string(template)

  defp form(values), do: to_form(values, as: "event")

  test "a field-bound checkbox derives checked from the field's value" do
    # Regression: `attr :checked, default: false` used to materialize into
    # assigns before the field clause ran, so assign_new never derived from
    # the field and a truthy value STILL rendered unchecked — the classic
    # "toggling visually unchecks itself on the next patch" symptom.
    assigns = %{form: form(%{"all_day" => "true"})}

    html =
      render(~H"""
      <.checkbox field={@form[:all_day]} label="All day" />
      """)

    assert html =~ ~s(type="checkbox")
    assert html =~ "checked"

    assigns = %{form: form(%{"all_day" => "false"})}

    html =
      render(~H"""
      <.checkbox field={@form[:all_day]} label="All day" />
      """)

    refute html =~ ~s(<input type="checkbox" checked)
    refute html =~ ~s(checked="checked")
  end

  test "an explicit checked= overrides the field's value" do
    assigns = %{form: form(%{"all_day" => "true"})}

    html =
      render(~H"""
      <.checkbox field={@form[:all_day]} checked={false} label="All day" />
      """)

    refute html =~ ~s(checked="checked")
  end

  test "a raw (non-field) checkbox still renders without passing checked" do
    assigns = %{}

    html =
      render(~H"""
      <.checkbox name="agree" label="Agree" />
      """)

    assert html =~ ~s(name="agree")
    refute html =~ ~s(checked="checked")
  end

  test "label survives a :description slot (regression: blank labels)" do
    # HEEx hands the component BODY to the default slot even when that body
    # contains nothing but named-slot tags and whitespace. The old either/or
    # guard (`if @inner_block != []`) then rendered that whitespace INSTEAD of
    # the label, blanking every label= + <:description> checkbox app-wide.
    assigns = %{}

    html =
      render(~H"""
      <.checkbox name="opt" checked={false} label="Enabled">
        <:description>Disabled profiles are never used.</:description>
      </.checkbox>
      """)

    assert html =~ "Enabled"
    assert html =~ "Disabled profiles are never used."
  end

  test "with a description the box centers against the first text line, not a fixed nudge" do
    # The label goes items-start when a description is present, so the input
    # needs its own first-line-height (h-6, matching leading-6) centering
    # wrapper. The old `mt-0.5` nudge was tuned for checkbox-sm and sat the
    # default 24px box 2px below the text's centerline.
    assigns = %{}

    with_description =
      render(~H"""
      <.checkbox name="opt" checked={false} label="Enabled">
        <:description>Secondary line.</:description>
      </.checkbox>
      """)

    # Pin the wrapper itself, not just the substring: a later refactor that
    # moved `h-6` onto the text span would keep a bare `=~ "h-6"` green while
    # un-fixing the alignment.
    assert with_description =~ ~s(<span class="flex items-center shrink-0 h-6">)
    refute with_description =~ "mt-0.5"

    # Without a description the whole label is items-center — no wrapper height.
    without_description =
      render(~H"""
      <.checkbox name="opt" checked={false} label="Enabled" />
      """)

    refute without_description =~ "h-6"
    assert without_description =~ "items-center cursor-pointer"
  end

  test "rich default-slot content renders alongside (not instead of) the label" do
    assigns = %{}

    html =
      render(~H"""
      <.checkbox name="opt" checked={false} label="Allow login">
        Connects the contact to a user account.
      </.checkbox>
      """)

    assert html =~ "Allow login"
    assert html =~ "Connects the contact to a user account."
  end

  test "a slot-only checkbox (no label attr) still renders its content" do
    assigns = %{}

    html =
      render(~H"""
      <.checkbox name="opt" checked={false}>
        <span class="badge">Rich label</span>
      </.checkbox>
      """)

    assert html =~ "Rich label"
  end

  describe "variant" do
    test "the default is a square box" do
      assigns = %{}
      html = render(~H|<.checkbox name="x" label="X" checked={true} />|)
      assert html =~ ~s(class="checkbox checkbox-primary")
      refute html =~ "toggle"
    end

    test "variant=toggle is daisyUI's switch, and class still merges" do
      assigns = %{}

      html =
        render(
          ~H|<.checkbox name="x" label="X" checked={false} variant="toggle" class="toggle-lg" />|
        )

      assert html =~ ~s(class="toggle toggle-primary toggle-lg")
      refute html =~ "checkbox checkbox-primary"
      assert html =~ ~s(<input type="hidden" name="x" value="false">)
    end
  end

  describe "value and unchecked_value" do
    test "by default the box submits true and an unchecked one false" do
      assigns = %{}
      html = render(~H|<.checkbox name="x" label="X" checked={false} />|)
      assert html =~ ~s(<input type="hidden" name="x" value="false">)
      assert html =~ ~s(value="true")
    end

    test "one box of a name[] group: its own value and no hidden fallback" do
      assigns = %{}

      html =
        render(~H"""
        <.checkbox name="scopes[]" value="items:read" unchecked_value={nil} checked label="Read" />
        """)

      assert html =~ ~s(value="items:read")
      refute html =~ ~s(type="hidden")
      refute html =~ ~s(value="true")
    end
  end

  describe "the field's errors" do
    defp terms_form(params) do
      {%{}, %{terms: :boolean, email: :string}}
      |> Ecto.Changeset.cast(params, [:terms, :email])
      |> Ecto.Changeset.validate_acceptance(:terms)
      |> Map.put(:action, :validate)
      |> to_form(as: "user")
    end

    test "show under a field-bound checkbox" do
      # Regression: the field clause never read `field.errors`, so a refused
      # checkbox showed nothing even after a failed submit.
      assigns = %{form: terms_form(%{"terms" => "false", "email" => "a@b.c"})}

      html =
        render(~H"""
        <.checkbox field={@form[:terms]} label="I agree" />
        """)

      assert html =~ "must be accepted"
    end

    test "wait while LiveView reports the checkbox unused" do
      assigns = %{form: terms_form(%{"terms" => "false", "_unused_terms" => "", "email" => "a"})}

      html =
        render(~H"""
        <.checkbox field={@form[:terms]} label="I agree" />
        """)

      refute html =~ "must be accepted"
    end

    test "a list given by the caller wins, an empty one included" do
      assigns = %{form: terms_form(%{"terms" => "false", "email" => "a@b.c"})}

      html =
        render(~H"""
        <.checkbox field={@form[:terms]} label="I agree" errors={[]} />
        """)

      refute html =~ "must be accepted"
    end
  end
end

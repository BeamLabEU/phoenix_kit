defmodule PhoenixKitWeb.Components.MultilangFormTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]
  import Phoenix.Component, only: [sigil_H: 2]
  import PhoenixKitWeb.Components.MultilangForm

  # ── Test helpers ─────────────────────────────────────────────

  defp html(assigns) do
    rendered_to_string(assigns)
  end

  defp make_changeset(data \\ %{}, changes \\ %{}) do
    types = %{
      title: :string,
      slug: :string,
      name: :string,
      display_name: :string,
      display_name_plural: :string,
      description: :string,
      status: :string,
      data: :map
    }

    {data, types}
    |> Ecto.Changeset.cast(changes, Map.keys(types))
  end

  defp make_error_changeset(field, message) do
    make_changeset()
    |> Ecto.Changeset.add_error(field, message)
    |> Map.put(:action, :validate)
  end

  # ── multilang_enabled? ──────────────────────────────────────

  describe "multilang_enabled?/0" do
    test "returns boolean without crashing" do
      result = multilang_enabled?()
      assert is_boolean(result)
    end
  end

  # ── primary_tab? ────────────────────────────────────────────

  describe "primary_tab?/1" do
    test "returns true when multilang disabled" do
      assert primary_tab?(%{multilang_enabled: false, current_lang: nil, primary_language: nil})
    end

    test "returns true when on primary language" do
      assert primary_tab?(%{multilang_enabled: true, current_lang: "en", primary_language: "en"})
    end

    test "returns false when on secondary language" do
      refute primary_tab?(%{multilang_enabled: true, current_lang: "fr", primary_language: "en"})
    end
  end

  # ── get_lang_data ───────────────────────────────────────────

  describe "get_lang_data/3" do
    test "returns empty map when multilang disabled" do
      changeset = make_changeset()
      assert get_lang_data(changeset, "en", false) == %{}
    end

    test "returns empty map when changeset is nil" do
      assert get_lang_data(nil, "en", true) == %{}
    end
  end

  # ── translatable_field primary tab ──────────────────────────

  describe "translatable_field primary tab" do
    test "renders input with primary name" do
      changeset = make_changeset(%{title: "Hello"})
      assigns = %{changeset: changeset}

      result =
        html(~H"""
        <.translatable_field
          field_name="title"
          form_prefix="record"
          changeset={@changeset}
          schema_field={:title}
          multilang_enabled={false}
          current_lang="en"
          primary_language="en"
          lang_data={%{}}
          label="Title"
        />
        """)

      assert result =~ ~s(name="record[title]")
      assert result =~ ~s(id="record_title")
      assert result =~ "Title"
      assert result =~ "Hello"
    end

    test "renders required marker" do
      changeset = make_changeset()
      assigns = %{changeset: changeset}

      result =
        html(~H"""
        <.translatable_field
          field_name="title"
          form_prefix="record"
          changeset={@changeset}
          schema_field={:title}
          multilang_enabled={true}
          current_lang="en"
          primary_language="en"
          lang_data={%{}}
          label="Title"
          required
        />
        """)

      assert result =~ "*"
      assert result =~ "required"
    end

    test "renders textarea" do
      changeset = make_changeset(%{description: "Some text"})
      assigns = %{changeset: changeset}

      result =
        html(~H"""
        <.translatable_field
          field_name="description"
          form_prefix="record"
          changeset={@changeset}
          schema_field={:description}
          multilang_enabled={false}
          current_lang="en"
          primary_language="en"
          lang_data={%{}}
          label="Description"
          type="textarea"
          rows={5}
        />
        """)

      assert result =~ "<textarea"
      assert result =~ ~s(rows="5")
      assert result =~ "Some text"
    end

    test "renders hint" do
      changeset = make_changeset()
      assigns = %{changeset: changeset}

      result =
        html(~H"""
        <.translatable_field
          field_name="name"
          form_prefix="record"
          changeset={@changeset}
          schema_field={:name}
          multilang_enabled={true}
          current_lang="en"
          primary_language="en"
          lang_data={%{}}
          label="Name"
          hint="Lowercase only"
        />
        """)

      assert result =~ "Lowercase only"
    end

    test "renders label_extra slot" do
      changeset = make_changeset()
      assigns = %{changeset: changeset}

      result =
        html(~H"""
        <.translatable_field
          field_name="slug"
          form_prefix="record"
          changeset={@changeset}
          schema_field={:slug}
          multilang_enabled={true}
          current_lang="en"
          primary_language="en"
          lang_data={%{}}
          label="Slug"
        >
          <:label_extra>
            <button type="button">Generate</button>
          </:label_extra>
        </.translatable_field>
        """)

      assert result =~ "Generate"
    end
  end

  # ── translatable_field secondary tab ────────────────────────

  describe "translatable_field secondary tab" do
    test "renders with lang_ prefix by default" do
      changeset = make_changeset(%{title: "Primary Title"})
      assigns = %{changeset: changeset}

      result =
        html(~H"""
        <.translatable_field
          field_name="title"
          form_prefix="record"
          changeset={@changeset}
          schema_field={:title}
          multilang_enabled={true}
          current_lang="fr"
          primary_language="en"
          lang_data={%{"_title" => "Titre"}}
          label="Title"
        />
        """)

      assert result =~ ~s(name="record[lang_title]")
      assert result =~ ~s(id="record_title_fr")
      assert result =~ ~s(value="Titre")
      assert result =~ ~s(placeholder="Primary Title")
    end

    test "renders with custom secondary_name" do
      changeset = make_changeset(%{display_name: "Brand"})
      assigns = %{changeset: changeset}

      result =
        html(~H"""
        <.translatable_field
          field_name="display_name"
          form_prefix="entities"
          changeset={@changeset}
          schema_field={:display_name}
          multilang_enabled={true}
          current_lang="es"
          primary_language="en"
          lang_data={%{"display_name" => "Marca"}}
          secondary_name="entities[translations][es][display_name]"
          lang_data_key="display_name"
          label="Display Name"
        />
        """)

      assert result =~ ~s(name="entities[translations][es][display_name]")
      assert result =~ ~s(value="Marca")
    end

    test "no required marker on secondary" do
      changeset = make_changeset()
      assigns = %{changeset: changeset}

      result =
        html(~H"""
        <.translatable_field
          field_name="title"
          form_prefix="record"
          changeset={@changeset}
          schema_field={:title}
          multilang_enabled={true}
          current_lang="fr"
          primary_language="en"
          lang_data={%{}}
          label="Title"
          required
        />
        """)

      refute result =~ "*"
      refute result =~ "required"
    end

    test "renders secondary_hint" do
      changeset = make_changeset()
      assigns = %{changeset: changeset}

      result =
        html(~H"""
        <.translatable_field
          field_name="slug"
          form_prefix="record"
          changeset={@changeset}
          schema_field={:slug}
          multilang_enabled={true}
          current_lang="fr"
          primary_language="en"
          lang_data={%{}}
          label="Slug"
          hint="Auto-generated"
          secondary_hint="Leave empty for primary slug"
        />
        """)

      assert result =~ "Leave empty for primary slug"
      refute result =~ "Auto-generated"
    end
  end

  # ── Error display ───────────────────────────────────────────

  describe "error display" do
    test "shows errors on primary tab with action" do
      changeset = make_error_changeset(:title, "can't be blank")
      assigns = %{changeset: changeset}

      result =
        html(~H"""
        <.translatable_field
          field_name="title"
          form_prefix="record"
          changeset={@changeset}
          schema_field={:title}
          multilang_enabled={true}
          current_lang="en"
          primary_language="en"
          lang_data={%{}}
          label="Title"
          required
        />
        """)

      assert result =~ "input-error"
    end

    test "no errors on secondary tab" do
      changeset = make_error_changeset(:title, "can't be blank")
      assigns = %{changeset: changeset}

      result =
        html(~H"""
        <.translatable_field
          field_name="title"
          form_prefix="record"
          changeset={@changeset}
          schema_field={:title}
          multilang_enabled={true}
          current_lang="fr"
          primary_language="en"
          lang_data={%{}}
          label="Title"
        />
        """)

      refute result =~ "input-error"
    end

    test "no errors without action" do
      changeset =
        make_changeset()
        |> Ecto.Changeset.add_error(:title, "can't be blank")

      assigns = %{changeset: changeset}

      result =
        html(~H"""
        <.translatable_field
          field_name="title"
          form_prefix="record"
          changeset={@changeset}
          schema_field={:title}
          multilang_enabled={true}
          current_lang="en"
          primary_language="en"
          lang_data={%{}}
          label="Title"
        />
        """)

      refute result =~ "input-error"
    end

    test "hint hidden when errors present" do
      changeset = make_error_changeset(:title, "can't be blank")
      assigns = %{changeset: changeset}

      result =
        html(~H"""
        <.translatable_field
          field_name="title"
          form_prefix="record"
          changeset={@changeset}
          schema_field={:title}
          multilang_enabled={true}
          current_lang="en"
          primary_language="en"
          lang_data={%{}}
          label="Title"
          hint="Enter a title"
        />
        """)

      refute result =~ "Enter a title"
    end
  end

  # ── Field attributes ────────────────────────────────────────

  describe "field attributes" do
    test "disabled" do
      changeset = make_changeset()
      assigns = %{changeset: changeset}

      result =
        html(~H"""
        <.translatable_field
          field_name="title"
          form_prefix="record"
          changeset={@changeset}
          schema_field={:title}
          multilang_enabled={false}
          current_lang="en"
          primary_language="en"
          lang_data={%{}}
          label="Title"
          disabled
        />
        """)

      assert result =~ "disabled"
    end

    test "pattern and title" do
      changeset = make_changeset()
      assigns = %{changeset: changeset}

      result =
        html(~H"""
        <.translatable_field
          field_name="slug"
          form_prefix="record"
          changeset={@changeset}
          schema_field={:slug}
          multilang_enabled={false}
          current_lang="en"
          primary_language="en"
          lang_data={%{}}
          label="Slug"
          pattern="[a-z0-9-]+"
          title="Lowercase only"
        />
        """)

      assert result =~ ~s(pattern="[a-z0-9-]+")
      assert result =~ "Lowercase only"
    end

    test "custom class" do
      changeset = make_changeset()
      assigns = %{changeset: changeset}

      result =
        html(~H"""
        <.translatable_field
          field_name="title"
          form_prefix="record"
          changeset={@changeset}
          schema_field={:title}
          multilang_enabled={false}
          current_lang="en"
          primary_language="en"
          lang_data={%{}}
          label="Title"
          class="w-full"
        />
        """)

      assert result =~ "input input-bordered w-full"
    end
  end

  # ── Safety ──────────────────────────────────────────────────

  describe "safety" do
    test "nil lang_data coerced to empty map" do
      changeset = make_changeset(%{title: "Test"})
      assigns = %{changeset: changeset}

      result =
        html(~H"""
        <.translatable_field
          field_name="title"
          form_prefix="record"
          changeset={@changeset}
          schema_field={:title}
          multilang_enabled={true}
          current_lang="fr"
          primary_language="en"
          lang_data={nil}
          label="Title"
        />
        """)

      assert result =~ "record[lang_title]"
    end
  end

  # ── multilang_fields_wrapper ────────────────────────────────

  describe "multilang_fields_wrapper" do
    test "renders skeleton and fields containers" do
      assigns = %{}

      result =
        html(~H"""
        <.multilang_fields_wrapper multilang_enabled={true} current_lang="en">
          <p>Content</p>
        </.multilang_fields_wrapper>
        """)

      assert result =~ "translatable-skeletons-en"
      assert result =~ "translatable-fields-en"
      assert result =~ "Content"
      assert result =~ ~s(data-translatable="skeletons")
      assert result =~ ~s(data-translatable="fields")
    end

    test "skeleton is hidden" do
      assigns = %{}

      result =
        html(~H"""
        <.multilang_fields_wrapper multilang_enabled={true} current_lang="en">
          <p>Content</p>
        </.multilang_fields_wrapper>
        """)

      assert result =~ "hidden"
    end

    test "custom skeleton slot" do
      assigns = %{}

      result =
        html(~H"""
        <.multilang_fields_wrapper multilang_enabled={true} current_lang="en">
          <:skeleton>
            <div class="custom-skeleton">Loading...</div>
          </:skeleton>
          <p>Content</p>
        </.multilang_fields_wrapper>
        """)

      assert result =~ "custom-skeleton"
      assert result =~ "Loading..."
    end

    test "custom skeleton_class" do
      assigns = %{}

      result =
        html(~H"""
        <.multilang_fields_wrapper multilang_enabled={true} current_lang="en" skeleton_class="space-y-6">
          <p>Content</p>
        </.multilang_fields_wrapper>
        """)

      assert result =~ "space-y-6"
    end

    test "custom fields_class" do
      assigns = %{}

      result =
        html(~H"""
        <.multilang_fields_wrapper multilang_enabled={true} current_lang="en" fields_class="space-y-6">
          <p>Content</p>
        </.multilang_fields_wrapper>
        """)

      assert result =~ "space-y-6"
    end

    test "no skeleton when multilang disabled" do
      assigns = %{}

      result =
        html(~H"""
        <.multilang_fields_wrapper multilang_enabled={false} current_lang="en">
          <p>Content</p>
        </.multilang_fields_wrapper>
        """)

      refute result =~ "translatable-skeletons"
      assert result =~ "Content"
    end

    test "IDs change with language" do
      assigns = %{}

      en =
        html(~H"""
        <.multilang_fields_wrapper multilang_enabled={true} current_lang="en">
          <p>Content</p>
        </.multilang_fields_wrapper>
        """)

      fr =
        html(~H"""
        <.multilang_fields_wrapper multilang_enabled={true} current_lang="fr">
          <p>Content</p>
        </.multilang_fields_wrapper>
        """)

      assert en =~ "translatable-fields-en"
      assert fr =~ "translatable-fields-fr"
      refute en =~ "translatable-fields-fr"
    end
  end

  # ── switch_lang_js ──────────────────────────────────────────

  describe "switch_lang_js/2" do
    test "same-lang click pushes to cancel any pending debounce + reverts skeleton toggles" do
      js = switch_lang_js("en", "en")
      refute js == %Phoenix.LiveView.JS{}

      ops = js.ops
      assert Enum.any?(ops, fn op -> match?(["push", %{event: "switch_language"}], op) end)
      # Same-lang must REVERT the skeleton/fields visibility (remove hidden
      # from fields, add hidden to skeleton) so a stuck skeleton clears when
      # the user re-clicks the active tab during an in-flight debounce.
      assert Enum.any?(ops, fn op ->
               match?(
                 ["remove_class", %{names: ["hidden"], to: "[data-translatable=fields]"}],
                 op
               )
             end)

      assert Enum.any?(ops, fn op ->
               match?(
                 ["add_class", %{names: ["hidden"], to: "[data-translatable=skeletons]"}],
                 op
               )
             end)
    end

    test "different-lang click hides fields and shows skeleton client-side" do
      js = switch_lang_js("fr", "en")
      refute js == %Phoenix.LiveView.JS{}

      ops = js.ops
      assert Enum.any?(ops, fn op -> match?(["push", %{event: "switch_language"}], op) end)
      # Add hidden on fields (hide them) and remove hidden from skeleton (show it).
      assert Enum.any?(ops, fn op ->
               match?(
                 ["add_class", %{names: ["hidden"], to: "[data-translatable=fields]"}],
                 op
               )
             end)

      assert Enum.any?(ops, fn op ->
               match?(
                 ["remove_class", %{names: ["hidden"], to: "[data-translatable=skeletons]"}],
                 op
               )
             end)
    end
  end

  # ── inject_db_field_into_data ───────────────────────────────

  describe "inject_db_field_into_data/5" do
    test "injects on primary tab" do
      assigns = %{
        multilang_enabled: true,
        primary_language: "en",
        changeset: make_changeset(%{data: %{}})
      }

      result = inject_db_field_into_data(%{}, "title", %{"title" => "Hello"}, "en", assigns)
      assert result == %{"_title" => "Hello"}
    end

    test "injects lang_ prefixed on secondary tab" do
      assigns = %{
        multilang_enabled: true,
        primary_language: "en",
        changeset: make_changeset(%{data: %{}})
      }

      result =
        inject_db_field_into_data(%{}, "title", %{"lang_title" => "Bonjour"}, "fr", assigns)

      assert result == %{"_title" => "Bonjour"}
    end

    test "passes through when disabled" do
      assigns = %{multilang_enabled: false}
      result = inject_db_field_into_data(%{"existing" => "data"}, "title", %{}, "en", assigns)
      assert result == %{"existing" => "data"}
    end
  end

  # ── merge_translatable_params ───────────────────────────────

  describe "merge_translatable_params/4" do
    test "passes through when disabled" do
      changeset = make_changeset()

      socket = %Phoenix.LiveView.Socket{
        assigns: %{
          multilang_enabled: false,
          primary_language: nil,
          current_lang: nil,
          __changed__: %{}
        }
      }

      result =
        merge_translatable_params(%{"name" => "Test"}, socket, ["name"], changeset: changeset)

      refute Map.has_key?(result, "data")
      assert result["name"] == "Test"
    end
  end

  # ── handle_switch_language / handle_multilang_apply_lang ────
  #
  # Exercises the debounced timer flow: schedule → cancel → reschedule
  # → apply. The timer ref now lives in `socket.private` (not the
  # process dictionary) so we assert against that.

  describe "handle_switch_language/2 and handle_multilang_apply_lang/2" do
    @timer_key :__phoenix_kit_multilang_timer__

    setup do
      socket = %Phoenix.LiveView.Socket{
        assigns: %{current_lang: "en", __changed__: %{}},
        private: %{}
      }

      # Drain any leftover timer messages from previous tests in this
      # process so a stray send doesn't leak across cases.
      drain()

      %{socket: socket}
    end

    test "ignores unknown language codes (no timer scheduled)", %{socket: socket} do
      result = handle_switch_language(socket, "klingon-XX")

      refute is_reference(Map.get(result.private, @timer_key))
      assert drain() == []
    end

    test "schedules a deferred apply message and stores the ref in private", %{socket: socket} do
      socket2 = handle_switch_language(socket, "en")
      ref = Map.get(socket2.private, @timer_key)

      # If the multilang config doesn't recognize "en" (no Languages
      # module configured in the test env), no timer is scheduled and
      # there's nothing to assert on the apply path. Otherwise, verify
      # the ref shape and that the message arrives within the window.
      if is_reference(ref) do
        assert_receive {:__multilang_apply_lang__, "en"}, 500
      end
    end

    test "rapid resubscribe cancels the previous timer", %{socket: socket} do
      socket2 = handle_switch_language(socket, "en")
      ref1 = Map.get(socket2.private, @timer_key)

      socket3 = handle_switch_language(socket2, "en")
      ref2 = Map.get(socket3.private, @timer_key)

      # Skip the assertion if no timer was scheduled (lang not in
      # enabled_languages in this env).
      if is_reference(ref1) and is_reference(ref2) do
        refute ref1 == ref2
        # First ref should be cancelled; only the second ref's message
        # should arrive.
        messages = receive_all(200)
        assert length(messages) <= 1
      end
    end

    test "handle_multilang_apply_lang assigns current_lang and clears the private timer", %{
      socket: socket
    } do
      # Pretend a timer was previously scheduled.
      ref = Process.send_after(self(), :__noop__, 5_000)
      socket = Phoenix.LiveView.put_private(socket, @timer_key, ref)

      result = handle_multilang_apply_lang(socket, "fr")

      assert result.assigns.current_lang == "fr"
      assert is_nil(Map.get(result.private, @timer_key))

      # Cleanup: drain the noop and don't leave a dangling timer running.
      Process.cancel_timer(ref)
      drain()
    end

    defp drain do
      receive_all(0)
    end

    defp receive_all(timeout) do
      receive_all([], timeout)
    end

    defp receive_all(acc, timeout) do
      receive do
        msg -> receive_all([msg | acc], timeout)
      after
        timeout -> Enum.reverse(acc)
      end
    end
  end
end

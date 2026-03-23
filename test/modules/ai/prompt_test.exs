defmodule PhoenixKit.Modules.AI.PromptTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.AI.Prompt

  # ============================================================================
  # extract_variables/1
  # ============================================================================

  describe "extract_variables/1" do
    test "extracts single variable" do
      assert Prompt.extract_variables("Hello {{Name}}!") == ["Name"]
    end

    test "extracts multiple variables" do
      assert Prompt.extract_variables("{{A}} and {{B}}") == ["A", "B"]
    end

    test "deduplicates variables" do
      assert Prompt.extract_variables("{{A}} and {{A}}") == ["A"]
    end

    test "returns empty list for no variables" do
      assert Prompt.extract_variables("No variables here") == []
    end

    test "returns empty list for nil" do
      assert Prompt.extract_variables(nil) == []
    end

    test "handles underscores in variable names" do
      assert Prompt.extract_variables("{{user_name}}") == ["user_name"]
    end

    test "handles numbers in variable names" do
      assert Prompt.extract_variables("{{item1}}") == ["item1"]
    end

    test "ignores invalid variable syntax with spaces" do
      assert Prompt.extract_variables("{{User Name}}") == []
    end
  end

  # ============================================================================
  # render/2
  # ============================================================================

  describe "render/2" do
    test "replaces variables with string key values" do
      prompt = %Prompt{content: "Hello {{Name}}!"}
      assert Prompt.render(prompt, %{"Name" => "World"}) == {:ok, "Hello World!"}
    end

    test "replaces variables with atom key values" do
      prompt = %Prompt{content: "Hello {{Name}}!"}
      assert Prompt.render(prompt, %{Name: "World"}) == {:ok, "Hello World!"}
    end

    test "leaves unmatched variables as-is" do
      prompt = %Prompt{content: "Hello {{Name}}!"}
      assert Prompt.render(prompt, %{}) == {:ok, "Hello {{Name}}!"}
    end

    test "replaces multiple variables" do
      prompt = %Prompt{content: "{{A}} + {{B}} = result"}
      assert Prompt.render(prompt, %{"A" => "1", "B" => "2"}) == {:ok, "1 + 2 = result"}
    end

    test "handles content without variables" do
      prompt = %Prompt{content: "No variables here"}
      assert Prompt.render(prompt, %{}) == {:ok, "No variables here"}
    end

    test "returns content when variables is not a map" do
      prompt = %Prompt{content: "Hello {{Name}}!"}
      assert Prompt.render(prompt, nil) == {:ok, "Hello {{Name}}!"}
    end
  end

  # ============================================================================
  # render_system_prompt/2
  # ============================================================================

  describe "render_system_prompt/2" do
    test "returns {:ok, nil} when system_prompt is nil" do
      prompt = %Prompt{system_prompt: nil, content: "test"}
      assert Prompt.render_system_prompt(prompt, %{}) == {:ok, nil}
    end

    test "returns {:ok, nil} when system_prompt is empty string" do
      prompt = %Prompt{system_prompt: "", content: "test"}
      assert Prompt.render_system_prompt(prompt, %{}) == {:ok, nil}
    end

    test "renders system prompt with variables" do
      prompt = %Prompt{system_prompt: "You are a {{Role}}", content: "test"}

      assert Prompt.render_system_prompt(prompt, %{"Role" => "translator"}) ==
               {:ok, "You are a translator"}
    end

    test "renders system prompt with atom key variables" do
      prompt = %Prompt{system_prompt: "Speak {{Language}}", content: "test"}

      assert Prompt.render_system_prompt(prompt, %{Language: "French"}) ==
               {:ok, "Speak French"}
    end

    test "leaves unmatched variables in system prompt" do
      prompt = %Prompt{system_prompt: "You are a {{Role}}", content: "test"}
      assert Prompt.render_system_prompt(prompt, %{}) == {:ok, "You are a {{Role}}"}
    end

    test "renders system prompt without variables" do
      prompt = %Prompt{system_prompt: "You are helpful", content: "test"}
      assert Prompt.render_system_prompt(prompt, %{}) == {:ok, "You are helpful"}
    end

    test "renders system prompt when variables is not a map" do
      prompt = %Prompt{system_prompt: "You are a {{Role}}", content: "test"}
      assert Prompt.render_system_prompt(prompt, nil) == {:ok, "You are a {{Role}}"}
    end
  end

  # ============================================================================
  # changeset/2 - variable extraction from both fields
  # ============================================================================

  describe "changeset/2 variable extraction" do
    test "extracts variables from content only" do
      changeset = Prompt.changeset(%Prompt{}, %{name: "Test", content: "Hello {{Name}}"})
      assert Ecto.Changeset.get_change(changeset, :variables) == ["Name"]
    end

    test "extracts variables from system_prompt only" do
      changeset =
        Prompt.changeset(%Prompt{}, %{
          name: "Test",
          content: "Hello",
          system_prompt: "You are {{Role}}"
        })

      assert Ecto.Changeset.get_change(changeset, :variables) == ["Role"]
    end

    test "extracts variables from both fields and deduplicates" do
      changeset =
        Prompt.changeset(%Prompt{}, %{
          name: "Test",
          content: "Hello {{Name}}",
          system_prompt: "You are {{Role}} speaking {{Name}}"
        })

      variables = Ecto.Changeset.get_change(changeset, :variables)
      assert "Role" in variables
      assert "Name" in variables
      assert length(variables) == 2
    end

    test "extracts variables preserving order from system_prompt first" do
      changeset =
        Prompt.changeset(%Prompt{}, %{
          name: "Test",
          content: "{{C}} and {{D}}",
          system_prompt: "{{A}} and {{B}}"
        })

      assert Ecto.Changeset.get_change(changeset, :variables) == ["A", "B", "C", "D"]
    end

    test "returns empty list when no variables in either field" do
      changeset =
        Prompt.changeset(%Prompt{}, %{
          name: "Test",
          content: "No vars",
          system_prompt: "Also no vars"
        })

      assert Ecto.Changeset.get_field(changeset, :variables) == []
    end
  end

  # ============================================================================
  # validate_variables/2
  # ============================================================================

  describe "validate_variables/2" do
    test "returns :ok when all variables provided" do
      prompt = %Prompt{variables: ["Name", "Age"]}
      assert Prompt.validate_variables(prompt, %{"Name" => "John", "Age" => "30"}) == :ok
    end

    test "returns error with missing variables" do
      prompt = %Prompt{variables: ["Name", "Age"]}
      assert Prompt.validate_variables(prompt, %{"Name" => "John"}) == {:error, ["Age"]}
    end

    test "returns :ok for empty variables list" do
      prompt = %Prompt{variables: []}
      assert Prompt.validate_variables(prompt, %{}) == :ok
    end
  end

  # ============================================================================
  # has_variables?/1
  # ============================================================================

  describe "has_variables?/1" do
    test "returns true when variables exist" do
      assert Prompt.has_variables?(%Prompt{variables: ["A"]})
    end

    test "returns false when variables empty" do
      refute Prompt.has_variables?(%Prompt{variables: []})
    end

    test "returns false for non-prompt" do
      refute Prompt.has_variables?(nil)
    end
  end

  # ============================================================================
  # valid_content?/1
  # ============================================================================

  describe "valid_content?/1" do
    test "returns true for valid variable syntax" do
      assert Prompt.valid_content?("Hello {{Name}}!")
    end

    test "returns true for no variables" do
      assert Prompt.valid_content?("Hello world!")
    end

    test "returns false for invalid variable with spaces" do
      refute Prompt.valid_content?("Hello {{User Name}}!")
    end

    test "returns false for nil" do
      refute Prompt.valid_content?(nil)
    end
  end

  # ============================================================================
  # content_preview/1
  # ============================================================================

  describe "content_preview/1" do
    test "returns empty string for nil" do
      assert Prompt.content_preview(nil) == ""
    end

    test "returns short content as-is" do
      assert Prompt.content_preview("Hello") == "Hello"
    end

    test "truncates long content with ellipsis" do
      long = String.duplicate("a", 150)
      preview = Prompt.content_preview(long)
      assert String.ends_with?(preview, "...")
      assert String.length(preview) <= 103
    end
  end

  # ============================================================================
  # generate_slug/1
  # ============================================================================

  describe "generate_slug/1" do
    test "generates slug from name" do
      assert Prompt.generate_slug("My Cool Prompt!") == "my-cool-prompt"
    end

    test "returns empty string for nil" do
      assert Prompt.generate_slug(nil) == ""
    end

    test "returns empty string for empty string" do
      assert Prompt.generate_slug("") == ""
    end
  end

  # ============================================================================
  # format_variables_for_display/1
  # ============================================================================

  describe "format_variables_for_display/1" do
    test "formats variables with curly braces" do
      prompt = %Prompt{variables: ["Name", "Age"]}
      assert Prompt.format_variables_for_display(prompt) == "{{Name}}, {{Age}}"
    end

    test "returns empty string for no variables" do
      prompt = %Prompt{variables: []}
      assert Prompt.format_variables_for_display(prompt) == ""
    end
  end
end

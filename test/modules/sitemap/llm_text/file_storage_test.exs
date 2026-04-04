defmodule PhoenixKit.Modules.Sitemap.LLMText.FileStorageTest do
  use ExUnit.Case, async: false

  alias PhoenixKit.Modules.Sitemap.LLMText.FileStorage

  setup do
    tmp_dir = System.tmp_dir!() |> Path.join("llm_text_test_#{:rand.uniform(1_000_000)}")
    Application.put_env(:phoenix_kit, :sitemap_llm_text_test_storage_dir, tmp_dir)

    on_exit(fn ->
      Application.delete_env(:phoenix_kit, :sitemap_llm_text_test_storage_dir)
      File.rm_rf(tmp_dir)
    end)

    {:ok, tmp_dir: tmp_dir}
  end

  describe "storage_dir/0" do
    test "returns the test override directory", %{tmp_dir: tmp_dir} do
      assert FileStorage.storage_dir() == tmp_dir
    end
  end

  describe "index_path/0" do
    test "returns llms.txt inside storage dir", %{tmp_dir: tmp_dir} do
      assert FileStorage.index_path() == Path.join(tmp_dir, "llms.txt")
    end
  end

  describe "file_path/1" do
    test "returns full path for relative path", %{tmp_dir: tmp_dir} do
      assert FileStorage.file_path("posts/article.md") ==
               Path.join(tmp_dir, "posts/article.md")
    end
  end

  describe "write/2" do
    test "writes content and creates parent dirs" do
      assert :ok = FileStorage.write("nested/dir/file.md", "# Hello")
      assert File.read!(FileStorage.file_path("nested/dir/file.md")) == "# Hello"
    end

    test "overwrites existing file" do
      :ok = FileStorage.write("page.md", "v1")
      :ok = FileStorage.write("page.md", "v2")
      assert File.read!(FileStorage.file_path("page.md")) == "v2"
    end
  end

  describe "write_index/1" do
    test "writes llms.txt" do
      assert :ok = FileStorage.write_index("# Index\n- [Page](/page)")
      assert File.read!(FileStorage.index_path()) == "# Index\n- [Page](/page)"
    end
  end

  describe "delete/1" do
    test "deletes an existing file" do
      :ok = FileStorage.write("to_delete.md", "content")
      assert :ok = FileStorage.delete("to_delete.md")
      refute File.exists?(FileStorage.file_path("to_delete.md"))
    end

    test "returns :ok when file does not exist" do
      assert :ok = FileStorage.delete("nonexistent.md")
    end
  end

  describe "exists?/1" do
    test "returns true for existing file" do
      :ok = FileStorage.write("exists.md", "yes")
      assert FileStorage.exists?("exists.md") == true
    end

    test "returns false for missing file" do
      assert FileStorage.exists?("missing.md") == false
    end
  end

  describe "delete_all/0" do
    test "removes the entire storage directory", %{tmp_dir: tmp_dir} do
      :ok = FileStorage.write("a.md", "a")
      :ok = FileStorage.write("b/c.md", "c")
      assert :ok = FileStorage.delete_all()
      refute File.exists?(tmp_dir)
    end

    test "returns :ok if directory does not exist" do
      FileStorage.delete_all()
      assert :ok = FileStorage.delete_all()
    end
  end
end

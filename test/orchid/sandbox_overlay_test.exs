defmodule Orchid.Sandbox.OverlayTest do
  use ExUnit.Case

  alias Orchid.Sandbox.Overlay

  setup do
    base = "tmp/test_overlay_#{:crypto.strong_rand_bytes(4) |> Base.url_encode64(padding: false)}"
    upper = Path.join(base, "upper")
    lower = Path.join(base, "lower")

    File.mkdir_p!(upper)
    File.mkdir_p!(lower)

    on_exit(fn -> File.rm_rf(base) end)

    %{upper: upper, lower: lower, base: base}
  end

  describe "union_read" do
    test "reads from lower when file only in lower", %{upper: upper, lower: lower} do
      File.write!(Path.join(lower, "hello.txt"), "from lower")

      assert {:ok, "from lower"} = Overlay.union_read("hello.txt", upper, lower)
    end

    test "reads from upper when file only in upper", %{upper: upper, lower: lower} do
      File.write!(Path.join(upper, "hello.txt"), "from upper")

      assert {:ok, "from upper"} = Overlay.union_read("hello.txt", upper, lower)
    end

    test "upper wins when file exists in both", %{upper: upper, lower: lower} do
      File.write!(Path.join(lower, "hello.txt"), "from lower")
      File.write!(Path.join(upper, "hello.txt"), "from upper")

      assert {:ok, "from upper"} = Overlay.union_read("hello.txt", upper, lower)
    end

    test "returns error for missing file", %{upper: upper, lower: lower} do
      assert {:error, :enoent} = Overlay.union_read("nope.txt", upper, lower)
    end
  end

  describe "union_write" do
    test "writes to upper layer", %{upper: upper, lower: lower} do
      :ok = Overlay.union_write("output.txt", "written data", upper)

      assert File.read!(Path.join(upper, "output.txt")) == "written data"
      refute File.exists?(Path.join(lower, "output.txt"))
    end

    test "creates parent directories", %{upper: upper} do
      :ok = Overlay.union_write("deep/nested/file.txt", "nested", upper)

      assert File.read!(Path.join(upper, "deep/nested/file.txt")) == "nested"
    end
  end

  describe "union_list" do
    test "merges entries from both layers", %{upper: upper, lower: lower} do
      File.write!(Path.join(lower, "a.txt"), "a")
      File.write!(Path.join(lower, "b.txt"), "b")
      File.write!(Path.join(upper, "c.txt"), "c")

      {:ok, listing} = Overlay.union_list(".", upper, lower)
      entries = String.split(listing, "\n")

      assert length(entries) == 3
      assert Enum.any?(entries, &String.contains?(&1, "a.txt"))
      assert Enum.any?(entries, &String.contains?(&1, "b.txt"))
      assert Enum.any?(entries, &String.contains?(&1, "c.txt"))
    end

    test "upper entry wins on conflict (no duplicates)", %{upper: upper, lower: lower} do
      File.write!(Path.join(lower, "same.txt"), "lower version")
      File.write!(Path.join(upper, "same.txt"), "upper version")

      {:ok, listing} = Overlay.union_list(".", upper, lower)
      entries = String.split(listing, "\n")

      # Should only appear once
      same_entries = Enum.filter(entries, &String.contains?(&1, "same.txt"))
      assert length(same_entries) == 1
    end

    test "handles empty directories", %{upper: upper, lower: lower} do
      {:ok, listing} = Overlay.union_list(".", upper, lower)
      assert listing == ""
    end
  end
end

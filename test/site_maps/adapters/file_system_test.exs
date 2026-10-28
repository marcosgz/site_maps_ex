defmodule SiteMaps.Adapters.FileSystemTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  use SiteMaps.AdapterContract, adapter: SiteMaps.Adapters.FileSystem

  alias SiteMaps.Adapters.FileSystem

  setup %{tmp_dir: tmp_dir} do
    root = Path.join(tmp_dir, "sitemaps")
    %{adapter: {FileSystem, directory: root}, root: root, opts: [directory: root]}
  end

  @meta %{content_type: "application/xml", cache_control: nil, last_modified: nil}

  test "creates nested directories with dir_mode", %{root: root} do
    opts = [directory: root, dir_mode: 0o750]

    assert :ok = FileSystem.write(opts, "posts/2026-03/sitemap1.xml", "x", @meta)
    assert mode(Path.join(root, "posts/2026-03")) == 0o750
    assert mode(Path.join(root, "posts")) == 0o750
  end

  test "applies file_mode", %{root: root} do
    assert :ok = FileSystem.write([directory: root, file_mode: 0o640], "sitemap.xml", "x", @meta)
    assert mode(Path.join(root, "sitemap.xml")) == 0o640
  end

  test "sets the file mtime from last_modified", %{root: root, opts: opts} do
    time = ~U[2025-12-31 23:59:58Z]

    assert :ok = FileSystem.write(opts, "sitemap.xml", "x", %{@meta | last_modified: time})
    assert {:ok, %File.Stat{mtime: mtime}} = File.stat(Path.join(root, "sitemap.xml"), time: :posix)
    assert mtime == DateTime.to_unix(time)
  end

  test "never exposes a partial file to readers during a write", %{root: root, opts: opts} do
    old = String.duplicate("o", 1_000)
    new = String.duplicate("n", 20_000_000)
    assert :ok = FileSystem.write(opts, "sitemap.xml", old, @meta)

    writer = Task.async(fn -> FileSystem.write(opts, "sitemap.xml", new, @meta) end)
    {result, reads} = read_until_done(Path.join(root, "sitemap.xml"), writer, [])

    assert result == :ok
    assert length(reads) > 1
    assert Enum.all?(reads, &(&1 in [old, new]))
    assert File.read!(Path.join(root, "sitemap.xml")) == new
  end

  test "leaves only a tmp file when the writer dies mid-write", %{root: root, opts: opts, tmp_dir: tmp_dir} do
    assert :ok = FileSystem.write(opts, "sitemap.xml", "published", @meta)
    fifo = Path.join(tmp_dir, "source.fifo")
    {_, 0} = System.cmd("mkfifo", [fifo])

    {:ok, feeder} = :file.open(fifo, [:read, :write, :raw])

    writer = spawn(fn -> FileSystem.write(opts, "sitemap.xml", {:file, fifo}, @meta) end)
    tmp = wait_for_tmp(root)
    ref = Process.monitor(writer)
    Process.exit(writer, :kill)
    :file.close(feeder)
    assert_receive {:DOWN, ^ref, :process, ^writer, :killed}

    assert File.read!(Path.join(root, "sitemap.xml")) == "published"
    assert Enum.sort(File.ls!(root)) == Enum.sort(["sitemap.xml", tmp])
    assert {:ok, ["sitemap.xml"]} = FileSystem.list(opts, "")
  end

  test "removes stale tmp files when listing", %{root: root, opts: opts} do
    assert :ok = FileSystem.write(opts, "posts/sitemap1.xml", "x", @meta)
    stale = Path.join(root, "posts/.sitemap2.xml.0123abcd.tmp")
    File.write!(stale, "partial")

    assert {:ok, ["posts/sitemap1.xml"]} = FileSystem.list(opts, "")
    assert File.exists?(stale)

    assert {:ok, ["posts/sitemap1.xml"]} = FileSystem.list([tmp_ttl: 0] ++ opts, "")
    refute File.exists?(stale)
  end

  test "keeps tmp files whose mtime is old but were just created", %{root: root, opts: opts} do
    tmp = Path.join(root, ".sitemap.xml.0123abcd.tmp")
    File.mkdir_p!(root)
    File.write!(tmp, "in flight")
    File.touch!(tmp, DateTime.to_unix(~U[2020-01-01 00:00:00Z]))

    assert {:ok, []} = FileSystem.list(opts, "")
    assert File.exists?(tmp)
  end

  test "follows symlinked files and directories", %{root: root, opts: opts, tmp_dir: tmp_dir} do
    real = Path.join(tmp_dir, "real")
    File.mkdir_p!(Path.join(real, "sub"))
    File.write!(Path.join(real, "sub/sitemap1.xml"), "hi")
    File.mkdir_p!(root)
    File.ln_s!(real, Path.join(root, "linked"))
    File.ln_s!(Path.join(real, "sub/sitemap1.xml"), Path.join(root, "alias.xml"))
    File.ln_s!(root, Path.join(root, "loop"))
    File.ln_s!(Path.join(tmp_dir, "missing"), Path.join(root, "broken.xml"))

    assert {:ok, "hi", _meta} = FileSystem.read(opts, "linked/sub/sitemap1.xml")
    assert {:ok, ["alias.xml", "linked/sub/sitemap1.xml"]} = FileSystem.list(opts, "")
  end

  test "creates the missing parents of the root directory", %{tmp_dir: tmp_dir} do
    opts = [directory: Path.join(tmp_dir, "missing/parent/root")]

    assert :ok = FileSystem.write(opts, "sitemap.xml", "x", @meta)
    assert {:ok, "x", _meta} = FileSystem.read(opts, "sitemap.xml")
  end

  test "keeps the published file and leaves no tmp file when a write fails", %{root: root, opts: opts} do
    assert :ok = FileSystem.write(opts, "sitemap.xml", "published", @meta)
    assert {:error, :enoent} = FileSystem.write(opts, "sitemap.xml", {:file, "/nonexistent/source"}, @meta)

    assert File.read!(Path.join(root, "sitemap.xml")) == "published"
    assert File.ls!(root) == ["sitemap.xml"]
  end

  test "ignores leftover tmp files in list", %{root: root, opts: opts} do
    assert :ok = FileSystem.write(opts, "posts/sitemap1.xml", "x", @meta)
    File.write!(Path.join(root, "posts/.sitemap2.xml.0123abcd.tmp"), "partial")

    assert {:ok, ["posts/sitemap1.xml"]} = FileSystem.list(opts, "")
    assert {:ok, ["posts/sitemap1.xml"]} = FileSystem.list(opts, "posts/")
  end

  test "returns the error when the target directory is not writable", %{root: root, opts: opts} do
    target_dir = Path.join(root, "posts")
    File.mkdir_p!(target_dir)
    File.chmod!(target_dir, 0o500)
    on_exit(fn -> File.chmod(target_dir, 0o755) end)

    assert {:error, :eacces} = FileSystem.write(opts, "posts/sitemap1.xml", "x", @meta)
  end

  test "works without fsync", %{root: root} do
    assert :ok = FileSystem.write([directory: root, fsync: false], "sitemap.xml", "x", @meta)
    assert {:ok, "x", _meta} = FileSystem.read([directory: root], "sitemap.xml")
  end

  test "resolves a relative directory against the cwd", %{tmp_dir: tmp_dir} do
    relative = Path.relative_to_cwd(Path.join(tmp_dir, "relative"))
    refute relative == Path.expand(relative)

    assert :ok = FileSystem.write([directory: relative], "sitemap.xml", "x", @meta)
    assert File.exists?(Path.join(tmp_dir, "relative/sitemap.xml"))
  end

  test "rejects keys escaping the directory", %{opts: opts} do
    for key <- ["../etc/passwd.xml", "/abs.xml", "a/../../b.xml", "a//b.xml", "./a.xml", "", ".a.xml.1.tmp"] do
      assert {:error, :invalid_key} = FileSystem.write(opts, key, "x", @meta)
      assert {:error, :invalid_key} = FileSystem.read(opts, key)
      assert {:error, :invalid_key} = FileSystem.delete(opts, key)
    end

    assert {:error, :invalid_key} = FileSystem.list(opts, "../")
  end

  test "writes keys with a segment close to the file name limit", %{root: root, opts: opts} do
    key = "posts/" <> String.duplicate("a", 236) <> ".xml"

    assert :ok = FileSystem.write(opts, key, "x", @meta)
    assert {:ok, "x", _meta} = FileSystem.read(opts, key)
    assert File.ls!(Path.join(root, "posts")) == [Path.basename(key)]
  end

  test "reads a directory key as not_found", %{opts: opts} do
    assert :ok = FileSystem.write(opts, "posts/sitemap1.xml", "x", @meta)
    assert {:error, :not_found} = FileSystem.read(opts, "posts")
  end

  test "lists nothing when the directory does not exist", %{opts: opts} do
    assert {:ok, []} = FileSystem.list(opts, "")
  end

  test "raises on missing directory option" do
    assert_raise NimbleOptions.ValidationError, fn -> FileSystem.read([], "sitemap.xml") end
  end

  defp read_until_done(path, task, acc) do
    acc = [File.read!(path) | acc]

    case Task.yield(task, 0) do
      nil -> read_until_done(path, task, acc)
      {:ok, result} -> {result, acc}
    end
  end

  defp wait_for_tmp(root, attempts \\ 500) do
    case Enum.find(File.ls!(root), &String.ends_with?(&1, ".tmp")) do
      nil when attempts > 0 -> Process.sleep(10) && wait_for_tmp(root, attempts - 1)
      nil -> flunk("no tmp file was written")
      tmp -> tmp
    end
  end

  defp mode(path), do: Bitwise.band(File.stat!(path).mode, 0o777)
end

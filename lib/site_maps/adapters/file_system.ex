defmodule SiteMaps.Adapters.FileSystem do
  @schema NimbleOptions.new!(
            directory: [
              type: :string,
              required: true,
              doc: "Root directory, absolute or relative to the current working directory."
            ],
            file_mode: [type: :non_neg_integer, default: 0o644, doc: "Mode of written files."],
            dir_mode: [
              type: :non_neg_integer,
              default: 0o755,
              doc: "Mode of directories created by the adapter."
            ],
            fsync: [
              type: :boolean,
              default: true,
              doc: "Flush file contents to disk before the rename."
            ],
            tmp_ttl: [
              type: :non_neg_integer,
              default: 3600,
              doc: "Seconds after which a leftover `.tmp` file is removed by `list/2`."
            ]
          )

  @moduledoc """
  Stores sitemaps in a local directory, including network mounts (NFS, EFS, SMB)
  and container volumes.

      adapter: {SiteMaps.Adapters.FileSystem, directory: "/mnt/nfs/sitemaps/acme"}

  ## Atomic publish

  Every file is first written to `<target dir>/.<name>.<random>.tmp`, with
  `<name>` cut to its first 100 bytes, in the same directory as the final file,
  flushed to disk (`fsync: true`) and then moved into place with a rename. A rename inside one directory is atomic on POSIX file
  systems and NFS, so readers on any node see either the old file or the new one,
  never a partial file. Leftover `.tmp` files from a crash are never listed;
  `list/2` removes the ones whose inode change time is older than `tmp_ttl`, so a
  prune run clears them.

  When the write meta carries `last_modified`, it becomes the file mtime (whole
  seconds) and `read/2` reports it back.

  Symbolic links to files and directories are followed by both `read/2` and
  `list/2`. The root directory and its missing parents are created on the first
  write.

  ## Options

  #{NimbleOptions.docs(@schema)}
  """

  @behaviour SiteMaps.Adapter

  @impl true
  def write(opts, key, source, meta) do
    opts = NimbleOptions.validate!(opts, @schema)

    with :ok <- validate_key(key) do
      root = root(opts)
      target = Path.join(root, key)
      dir = Path.dirname(target)
      tmp = Path.join(dir, tmp_name(Path.basename(target)))

      with :ok <- mkdir_p(dir, opts[:dir_mode]),
           :ok <- write_tmp(tmp, source, opts[:fsync]),
           :ok <- File.chmod(tmp, opts[:file_mode]),
           :ok <- set_mtime(tmp, meta[:last_modified]),
           :ok <- File.rename(tmp, target) do
        :ok
      else
        error ->
          File.rm(tmp)
          error
      end
    end
  end

  @impl true
  def read(opts, key) do
    opts = NimbleOptions.validate!(opts, @schema)

    with :ok <- validate_key(key) do
      path = Path.join(root(opts), key)

      with {:ok, %File.Stat{type: :regular, mtime: mtime}} <- File.stat(path, time: :posix),
           {:ok, binary} <- File.read(path) do
        meta = %{
          content_type: SiteMaps.Adapter.content_type(key),
          last_modified: DateTime.from_unix!(mtime)
        }

        {:ok, binary, meta}
      else
        {:ok, %File.Stat{}} -> {:error, :not_found}
        {:error, reason} when reason in [:enoent, :enotdir] -> {:error, :not_found}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @impl true
  def delete(opts, key) do
    opts = NimbleOptions.validate!(opts, @schema)

    with :ok <- validate_key(key) do
      case File.rm(Path.join(root(opts), key)) do
        :ok -> :ok
        {:error, reason} when reason in [:enoent, :enotdir] -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @impl true
  def list(opts, prefix) do
    opts = NimbleOptions.validate!(opts, @schema)

    if Enum.any?(String.split(prefix, "/"), &(&1 in [".", ".."])) do
      {:error, :invalid_key}
    else
      base = prefix_dir(prefix)
      sweep = {System.os_time(:second) - opts[:tmp_ttl], []}

      with {:ok, keys} <- walk(Path.join(root(opts), base), base, sweep) do
        {:ok, keys |> Enum.filter(&String.starts_with?(&1, prefix)) |> Enum.sort()}
      end
    end
  end

  defp root(opts), do: Path.expand(opts[:directory])

  defp validate_key(key), do: SiteMaps.Adapter.validate_key(key)

  @tmp_basename_bytes 100

  defp tmp_name(basename) do
    ".#{binary_slice(basename, 0, @tmp_basename_bytes)}.#{random_suffix()}.tmp"
  end

  defp random_suffix, do: Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

  defp mkdir_p(dir, mode) do
    cond do
      File.dir?(dir) -> :ok
      Path.dirname(dir) == dir -> make_dir(dir, mode)
      true -> with :ok <- mkdir_p(Path.dirname(dir), mode), do: make_dir(dir, mode)
    end
  end

  defp make_dir(dir, mode) do
    case File.mkdir(dir) do
      :ok -> File.chmod(dir, mode)
      {:error, :eexist} -> :ok
      error -> error
    end
  end

  defp write_tmp(tmp, source, fsync?) do
    with {:ok, fd} <- :file.open(tmp, [:write, :binary, :exclusive, :raw]) do
      result = with :ok <- copy(source, fd), do: sync(fd, fsync?)
      close_result = :file.close(fd)
      if result == :ok, do: close_result, else: result
    end
  end

  defp sync(fd, true), do: :file.sync(fd)
  defp sync(_fd, false), do: :ok

  defp copy({:file, path}, fd) do
    case :file.copy(path, fd) do
      {:ok, _bytes} -> :ok
      error -> error
    end
  end

  defp copy(iodata, fd), do: :file.write(fd, iodata)

  defp set_mtime(_path, nil), do: :ok
  defp set_mtime(path, %DateTime{} = time), do: File.touch(path, DateTime.to_unix(time))

  defp prefix_dir(prefix) do
    case :binary.matches(prefix, "/") do
      [] -> ""
      matches -> binary_part(prefix, 0, elem(List.last(matches), 0) + 1)
    end
  end

  defp walk(dir, rel, {cutoff, ancestors}) do
    with {:ok, %File.Stat{} = stat} <- File.stat(dir),
         false <- inode(stat) in ancestors,
         {:ok, names} <- File.ls(dir) do
      sweep = {cutoff, [inode(stat) | ancestors]}
      Enum.reduce_while(names, {:ok, []}, &walk_entry(dir, rel, sweep, &1, &2))
    else
      true -> {:ok, []}
      {:error, reason} when reason in [:enoent, :enotdir] -> {:ok, []}
      error -> error
    end
  end

  defp walk_entry(dir, rel, sweep, name, {:ok, acc}) do
    case entry(Path.join(dir, name), rel <> name, name, sweep) do
      {:ok, keys} -> {:cont, {:ok, keys ++ acc}}
      error -> {:halt, error}
    end
  end

  defp entry(path, key, name, {cutoff, _ancestors} = sweep) do
    if SiteMaps.Adapter.tmp_name?(name) do
      remove_stale_tmp(path, cutoff)
    else
      case File.stat(path) do
        {:ok, %File.Stat{type: :directory}} -> walk(path, key <> "/", sweep)
        {:ok, %File.Stat{type: :regular}} -> {:ok, [key]}
        {:ok, %File.Stat{}} -> {:ok, []}
        {:error, reason} when reason in [:enoent, :eloop] -> {:ok, []}
        error -> error
      end
    end
  end

  defp remove_stale_tmp(path, cutoff) do
    case File.lstat(path, time: :posix) do
      {:ok, %File.Stat{type: :regular, ctime: ctime}} when ctime <= cutoff -> File.rm(path)
      _ -> :ok
    end

    {:ok, []}
  end

  defp inode(%File.Stat{major_device: device, inode: inode}), do: {device, inode}
end

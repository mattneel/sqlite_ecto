defmodule Sqlite.Ecto do
  @moduledoc ~S"""
  Ecto Adapter module for SQLite.

  It uses Sqlitex and Esqlite for accessing the SQLite database.

  ## Features

  ## Options

  There are a limited number of options available because SQLite is so simple to use.

  ### Compile time options

  These options should be set in the config file and require recompilation in
  order to make an effect.

    * `:adapter` - The adapter name, in this case, `Sqlite.Ecto`
    * `:timeout` - The default timeout to use on queries, defaults to `5000`

  ### Connection options

    * `:database` - This option can take the form of a path to the SQLite
      database file or `":memory:"` for an in-memory database.  See the
      [SQLite docs](https://sqlite.org/uri.html) for more options such as
      shared memory caches.

  """

  import Sqlite.Ecto.Util, only: [json_library: 0]

  # Inherit all behaviour from Ecto.Adapters.SQL
  use Ecto.Adapters.SQL, :sqlitex

  # And provide a custom storage implementation
  @behaviour Ecto.Adapter.Storage

  ## Custom SQLite Types

  def loaders({:embed, _} = type, _), do: [&load_embed(type, &1)]
  def loaders(:map, _), do: [&json_library.decode/1]
  def loaders({:map, _}, _), do: [&json_library.decode/1]
  def loaders(:datetime, _), do: [&load_datetime/1]
  def loaders(primitive_type, ecto_type), do: super(primitive_type, ecto_type)

  defp load_embed(type, data) do
    case json_library.decode(data) do
      {:ok, map} ->
        Ecto.Type.load(type, map, fn
          {:embed, _} = type, value -> load_embed(type, value)
          type, value -> Ecto.Type.cast(type, value)
        end)
      _ -> :error
    end
  end

  defp load_datetime(datetime) do
    # Datetime loading is a bit odd: sometimes we'll get erlang datetime tuples
    # out, because Sqlitex does that conversion for us. Other times Sqlitex
    # doesn't realise we've got a DATETIME column, so we get a string.
    # Luckily, Ecto.DateTime.cast handles both of these cases.
    Ecto.DateTime.cast(datetime)
  end

  ## Storage API

  @doc false
  def storage_up(opts) do
    database = Keyword.get(opts, :database)
    if File.exists?(database) do
      {:error, :already_up}
    else
      database |> Path.dirname |> File.mkdir_p!
      case Sqlitex.open(database) do
        {:error, _msg} = err -> err
        {:ok, db} ->
          Sqlitex.close(db)
          :ok
      end
    end
  end

  @doc false
  def storage_down(opts) do
    database = Keyword.get(opts, :database)
    case File.rm(database) do
      {:error, :enoent} -> {:error, :already_down}
      result -> result
    end
  end

  @doc false
  def supports_ddl_transaction?, do: true
end

defmodule Sqlite.Ecto.Protocol do
  @moduledoc false


  use DBConnection
  require Logger

  defmodule Query do
    defstruct [:sql]

    defimpl String.Chars, for: __MODULE__ do
      def to_string(%Query{sql: sql}) do
        "Query{sql: \"#{sql}\"}"
      end
    end

    defimpl DBConnection.Query, for: Query do
      def parse(query, _), do: query
      def describe(query, _), do: query
      def encode(_, params, _), do: params
      def decode(_, result, _), do: result
    end

  end

  def connect(opts) do
    {database, opts} = Keyword.pop(opts, :database)
    case Sqlitex.Server.start_link(database) do
      {:ok, db} ->
        :ok = Sqlitex.Server.exec(db, "PRAGMA foreign_keys = ON")
        {:ok, [[foreign_keys: 1]]} = Sqlitex.Server.query(db, "PRAGMA foreign_keys")
        {:ok, db}
      error ->
        error
    end
  end

  def disconnect(_, db) do
    Sqlitex.Server.stop(db)
    :ok
  end

  def checkout(s), do: {:ok, s}

  def checkin(s), do: {:ok, s}

  def handle_begin(opts, db) do
    case Keyword.get(opts, :mode, :transaction) do
      :transaction ->
        exec(db, "BEGIN TRANSACTION;")
      :savepoint ->
        exec(db, "SAVEPOINT sqlite_ecto_savepoint;")
    end
  end

  def handle_commit(opts, db) do
    case Keyword.get(opts, :mode, :transaction) do
      :transaction ->
        exec(db, "COMMIT TRANSACTION;")
      :savepoint ->
        exec(db, "RELEASE SAVEPOINT sqlite_ecto_savepoint;")
    end
  end

  def handle_rollback(opts, db) do
    case Keyword.get(opts, :mode, :transaction) do
      :transaction ->
        exec(db, "ROLLBACK TRANSACTION;")
      :savepoint ->
        exec(db, "ROLLBACK TO SAVEPOINT sqlite_ecto_savepoint;")
    end
  end

  def handle_prepare(query, opts, db), do: {:ok, query, db}

  def handle_execute(%{sql: sql}, params, opts, db) do
    {status, result} = Sqlite.Ecto.Query.execute(db, sql, params, opts)
    {status, result, db}
  end

  defp exec(db, sql) do
    case Sqlitex.Server.exec(db, sql) do
      :ok ->
        {:ok, nil, db}
      {:error, err} ->
        {:error, err, db}
    end
  end

end

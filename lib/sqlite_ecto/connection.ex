if Code.ensure_loaded?(Sqlitex.Server) do
  defmodule Sqlite.Ecto.Connection do
    @moduledoc false

    @behaviour Ecto.Adapters.SQL.Connection

    def prepare_execute(conn, name, sql, params, opts) do
      query = %Sqlite.Ecto.Protocol.Query{sql: sql}
      case DBConnection.prepare_execute(conn, query, params, opts) do
        {:ok, _, _} = ok ->
          ok
        error ->
          error
      end
    end

    def execute(conn, query, params, opts) when is_binary(query) do
      execute(conn, %Sqlite.Ecto.Query{sql: query}, params, opts)
    end

    def execute(conn, %Sqlite.Ecto.Query{} = query, params, opts) do
      query = %Sqlite.Ecto.Protocol.Query{sql: query}
      execute(conn, query, params, opts)
    end

    def execute(conn, query, params, opts) do
      case DBConnection.execute(conn, query, params, opts) do
        {:ok, _, result} ->
          {:ok, result}
        error ->
          error
      end
    end

    def child_spec(opts) do
      DBConnection.child_spec(Sqlite.Ecto.Protocol, opts)
    end

    defdelegate to_constraints(error), to: Sqlite.Ecto.Error

    ## Transaction

    alias Sqlite.Ecto.Transaction

    defdelegate begin_transaction, to: Transaction

    defdelegate rollback, to: Transaction

    defdelegate commit, to: Transaction

    defdelegate savepoint(name), to: Transaction

    defdelegate rollback_to_savepoint(name), to: Transaction

    ## Query

    alias Sqlite.Ecto.Query

    defdelegate query(pid, sql, params, opts), to: Query

    defdelegate all(query), to: Query

    defdelegate update_all(query), to: Query

    defdelegate delete_all(query), to: Query

    defdelegate insert(prefix, table, header, rows, returning), to: Query

    defdelegate update(prefix, table, fields, filters, returning), to: Query

    defdelegate delete(prefix, table, filters, returning), to: Query

    ## DDL

    alias Sqlite.Ecto.DDL

    defdelegate execute_ddl(ddl), to: DDL
  end
end

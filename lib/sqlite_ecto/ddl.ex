defmodule Sqlite.Ecto.DDL do
  @moduledoc false

  alias Ecto.Migration.Table
  alias Ecto.Migration.Index
  alias Ecto.Migration.Reference
  import Sqlite.Ecto.Util, only: [assemble: 1, map_intersperse: 3, quote_id: 1]

  # Raise error on NoSQL arguments.
  def execute_ddl({_command, %Table{options: keyword}, _}) when is_list(keyword) do
    raise ArgumentError, "SQLite adapter does not support keyword lists in :options"
  end

  # Create a table.
  def execute_ddl({command, %Table{} = table, columns})
  when command in [:create, :create_if_not_exists] do
    table_name = quote_table(table)
    column_defs = column_definitions(table, columns)

    defs_and_constraints =
      case table_constraints(table, columns) do
        [] -> column_defs
        constraints -> [column_defs, ",", constraints]
      end

    assemble [create_table(command), table_name, "(", defs_and_constraints, ")", table.options]
  end

  # Drop a table.
  def execute_ddl({command, %Table{} = table})
  when command in [:drop, :drop_if_exists] do
    assemble [drop_table(command), quote_table(table)]
  end

  # Alter a table.
  def execute_ddl({:alter, %Table{} = table, changes}) do
    Enum.map_join(changes, "; ", fn (change) ->
      assemble ["ALTER TABLE", quote_table(table), alter_table_suffix(table, change)]
    end)
  end

  # Rename a table.
  def execute_ddl({:rename, %Table{} = old, %Table{} = new}) do
    "ALTER TABLE #{quote_table(old)} RENAME TO #{quote_table(new)}"
  end

  # Rename a table column.
  def execute_ddl({:rename, %Table{}, _old_col, _new_col}) do
    raise ArgumentError, "RENAME COLUMN not supported by SQLite"
  end

  # Create an index.
  # NOTE Ignores concurrently and using values.
  def execute_ddl({command, %Index{}=index})
  when command in [:create, :create_if_not_exists] do
    create_index = create_index(command, index.unique)
    table = quote_table(index.prefix, index.table)
    fields = map_intersperse(index.columns, ",", &quote_id/1)
    assemble [create_index, quote_id(index.name), "ON", table, "(", fields, ")"]
  end

  # Drop an index.
  def execute_ddl({command, %Index{name: name}})
  when command in [:drop, :drop_if_exists] do
    assemble [drop_index(command), quote_id(name)]
  end

  # Raise error on NoSQL arguments.
  def execute_ddl(keyword) when is_list(keyword) do
    raise ArgumentError, "SQLite adapter does not support keyword lists in execute"
  end

  # Default:
  def execute_ddl(default) when is_binary(default), do: default

  ## Helpers

  # Returns a create table prefix.
  defp create_table(:create), do: "CREATE TABLE"
  defp create_table(:create_if_not_exists), do: "CREATE TABLE IF NOT EXISTS"

  # Quotes a table name.
  defp quote_table(%Table{prefix: prefix, name: name}) do
    quote_table(prefix, name)
  end
  defp quote_table(nil, name), do: quote_id(name)
  defp quote_table(prefix, name) do
    [prefix, name] |> Enum.map(&quote_id/1) |> Enum.join(".")
  end

  # Returns a drop table prefix.
  defp drop_table(:drop), do: "DROP TABLE"
  defp drop_table(:drop_if_exists), do: "DROP TABLE IF EXISTS"

  defp column_definitions(table, cols) do
    map_intersperse(cols, ",", &column_definition(table, &1))
  end

  defp column_definition(table, {_action, name, ref = %Reference{}, opts}) do
    opts = Enum.into(opts, %{})
    [quote_id(name), column_constraints(opts), reference_expr(ref, table, name)]
  end
  defp column_definition(_table, action), do: column_definition(action)
  defp column_definition({_action, name, type, opts}) do
    opts = Enum.into(opts, %{})
    [quote_id(name), column_type(type, opts), column_constraints(type, opts)]
  end

  def table_constraints(table, columns) do
    IO.inspect table
    IO.inspect columns

    primary_keys =
      columns
      |> Enum.filter(fn
        {_, _, :serial, _} -> false
        {_, _, _, opts} -> Keyword.get(opts, :primary_key, false)
      end)

    case primary_keys do
      [] -> []
      keys ->
        key_names = Enum.map(keys, fn {_, name, _, _} -> quote_id(name) end)

        ["PRIMARY KEY(", Enum.join(key_names, ", "), ")"]
    end
  end

  # Foreign keys:
  defp reference_expr(%Reference{} = ref, %Table{} = table, col) do
    ["CONSTRAINT", reference_name(ref, table, col),
     "REFERENCES #{quote_table(table.prefix, ref.table)}(#{quote_id(ref.column)})",
     reference_on_delete(ref.on_delete)]
  end

  defp reference_name(%Reference{name: nil}, %Table{name: table}, col) do
    [table, col, "fkey"] |> Enum.join("_") |> quote_id
  end
  defp reference_name(%Reference{name: name}, _table, _col), do: quote_id(name)

  # Decimals are the only type for which we care about the options:
  defp column_type(:decimal, opts=%{precision: precision}) do
    scale = Dict.get(opts, :scale, 0)
    "DECIMAL(#{precision},#{scale})"
  end
  # Simple column types.  Note that we ignore options like :size, :precision,
  # etc. because columns do not have types, and SQLite will not coerce any
  # stored value.  Thus, "strings" are all text and "numerics" have arbitrary
  # precision regardless of the declared column type.  Decimals above are the
  # only exception.
  defp column_type(:serial, _opts), do: "INTEGER"
  defp column_type(:string, _opts), do: "TEXT"
  defp column_type(:map, _opts), do: "TEXT"
  defp column_type({:map, _}, _opts), do: "TEXT"
  defp column_type({:array, _}, _opts), do: raise(ArgumentError, "Array type is not supported by SQLite")
  defp column_type(type, _opts), do: type |> Atom.to_string |> String.upcase

  # NOTE SQLite requires autoincrement integers to be primary keys
  defp column_constraints(:serial, _), do: "PRIMARY KEY AUTOINCREMENT"
  # Return a string of constraints for the column.
  # NOTE The order of these constraints does not matter to SQLite, but
  # rearranging them may cause tests that rely on their order to fail.
  defp column_constraints(_type, opts), do: column_constraints(opts)
  defp column_constraints(opts=%{default: default}) do
    val = case default do
      true -> 1
      false -> 0
      {:fragment, expr} -> "(#{expr})"
      string when is_binary(string) -> "'#{string}'"
      other -> other
    end
    other_constraints = opts |> Map.delete(:default) |> column_constraints
    ["DEFAULT", val, other_constraints]
  end
  defp column_constraints(opts=%{null: false}) do
    other_constraints = opts |> Map.delete(:null) |> column_constraints
    ["NOT NULL", other_constraints]
  end
  defp column_constraints(_), do: []

  # Define how to handle deletion of foreign keys on parent table.
  # See: https://www.sqlite.org/foreignkeys.html#fk_actions
  defp reference_on_delete(:nilify_all), do: "ON DELETE SET NULL"
  defp reference_on_delete(:delete_all), do: "ON DELETE CASCADE"
  defp reference_on_delete(_), do: []

  # Returns a create index prefix.
  defp create_index(:create, unique?), do: create_unique_index(unique?)
  defp create_index(:create_if_not_exists, unique?) do
    [create_unique_index(unique?), "IF NOT EXISTS"]
  end

  defp create_unique_index(true), do: "CREATE UNIQUE INDEX"
  defp create_unique_index(false), do: "CREATE INDEX"

  # Returns a drop index prefix.
  defp drop_index(:drop), do: "DROP INDEX"
  defp drop_index(:drop_if_exists), do: "DROP INDEX IF EXISTS"

  # If we are adding a DATETIME column with the NOT NULL constraint, SQLite
  # will force us to give it a DEFAULT value.  The only default value
  # that makes sense is CURRENT_TIMESTAMP, but when adding a column to a
  # table, defaults must be constant values.
  #
  # Therefore the best option is just to remove the NOT NULL constraint when
  # we add new datetime columns.
  defp alter_table_suffix(_table, {:add, column, :datetime, opts}) do
    opts = opts |> Enum.into(%{}) |> Dict.delete(:null)
    change = {:add, column, :datetime, opts}
    ["ADD COLUMN", column_definition(change)]
  end

  defp alter_table_suffix(table, change={:add, _column, _type, _opts}) do
    ["ADD COLUMN", column_definition(table, change)]
  end

  defp alter_table_suffix(_table, {:modify, _column, _type, _opts}) do
    raise ArgumentError, "ALTER COLUMN not supported by SQLite"
  end

  defp alter_table_suffix(_table, {:remove, _column}) do
    raise ArgumentError, "DROP COLUMN not supported by SQLite"
  end
end

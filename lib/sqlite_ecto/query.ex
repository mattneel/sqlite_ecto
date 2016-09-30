defmodule Sqlite.Ecto.Query do
  @moduledoc false

  import Sqlite.Ecto.Transaction, only: [with_savepoint: 2]
  import Sqlite.Ecto.Util

  alias Sqlite.Ecto.Query

  defmodule ReturningInfo do
    defstruct [:table, :cols, :query_type]

    @type t :: %__MODULE__{
      table: String.t,
      cols: [String.t],
      query_type: String.t
    }
  end

  # sql: A query string, or a list of query strings.
  # sql_param_count: the (usually optional) number of parameters in each sql
  # query.
  # returning: ReturningInfo if the query has a reutrning clause.
  defstruct [:sql, :sql_param_count, :returning]

  @type t :: %__MODULE__{
    sql: String.t | [String.t],
    sql_param_count: non_neg_integer | [non_neg_integer] | nil,
    returning: ReturningInfo.t | nil
  }

  defimpl String.Chars, for: __MODULE__ do
    def to_string(%Query{sql: sql}) do
      # TODO: Add returning to this?
      "Query{sql: \"#{sql}\"}"
    end
  end

  def execute(pid, %Query{returning: returning} = query, params, opts)
  when not is_nil(returning) do
    returning_query(pid, query, params, opts)
  end

  def execute(pid, %Query{sql: sql}, [], opts) when is_list(sql) do
    sql
    |> Enum.scan(:ok, fn
      (_, {:error, _} = error) -> error
      (statement, _) -> execute(pid, %Query{sql: statement}, [], opts)
    end)
    |> merge_query_results
  end

  def execute(pid, %Query{sql: sql, sql_param_count: param_counts}, params, opts)
  when is_list(sql) and is_list(param_counts) do
    param_counts
    |> Enum.scan({nil, params}, fn
      (count, {_, params}) ->
        Enum.split(params, count)
    end)
    |> Enum.map(fn {chunk, _} -> chunk end)
    |> Enum.zip(sql)
    |> Enum.scan(:ok, fn
      (_, {:error, _} = error) ->
        error
      ({params, statement}, _) ->
        execute(pid, %Query{sql: statement}, params, opts)
    end)
    |> merge_query_results
  end

  def execute(pid, %Query{sql: <<"ALTER TABLE ", _ :: binary>>=sql}, params, opts) do
    sql
    |> String.split("; ")
    |> Enum.reduce(:ok, fn
      (_, {:error, _} = error) -> error
      (alter_stmt, _) -> do_execute(pid, alter_stmt, params, opts)
    end)
  end

  # all other queries:
  def execute(pid, %Query{sql: sql}, params, opts) do
    params = Enum.map(params, fn
      %Ecto.Query.Tagged{type: :binary, value: value} when is_binary(value) -> {:blob, value}
      %Ecto.Query.Tagged{value: value} -> value
      %{__struct__: _} = value -> value
      %{} = value -> json_library.encode! value
      value -> value
    end)

    do_execute(pid, sql, params, opts)
  end

  defp merge_query_results(results) do
    Enum.reduce(results, fn
      ({:ok, %{num_rows: n, rows: rows}}, {:ok, %{num_rows: n2}}) ->
        {:ok, %{num_rows: n + n2, rows: rows}}
      ({:error, _} = error, _) ->
        error
      (_, {:error, _} = error) ->
        error
    end)
  end

  def all(%Ecto.Query{lock: lock}) when lock != nil do
    raise ArgumentError, "locks are not supported by SQLite"
  end
  def all(query) do
    sources = create_names(query, :select)

    select = select(query.select, query.distinct, sources)
    from = from(sources)
    join = join(query.joins, sources)
    where = where(query.wheres, sources)
    group_by = group_by(query.group_bys, query.havings, sources)
    order_by = order_by(query.order_bys, sources)
    limit = limit(query.limit, query.offset, sources)

    %Query{
      sql: assemble [select, from, join, where, group_by, order_by, limit]
    }
  end

  def update_all(%Ecto.Query{joins: [_ | _]}) do
    raise ArgumentError, "JOINS are not supported on UPDATE statements by SQLite"
  end
  def update_all(query) do
    sources = create_names(query, :update)
    {table, _name, _model} = elem(sources, 0)
    fields = update_fields(query.updates, sources)
    where = where(query.wheres, sources)
    %Query{
      sql: assemble ["UPDATE", quote_id(table), "SET", fields, where]
    }
  end

  def delete_all(%Ecto.Query{joins: [_ | _]}) do
    raise ArgumentError, "JOINS are not supported on DELETE statements by SQLite"
  end
  def delete_all(query) do
    sources = create_names(query, :delete)
    {table, _name, _model} = elem(sources, 0)
    where = where(query.wheres, sources)
    %Query{
      sql: assemble ["DELETE FROM", quote_id(table), where]
    }
  end

  def insert(prefix, table, [], rows, returning) do
    returning = returning_info(prefix, table, returning, "INSERT")
    %Query{
      sql: assemble(["INSERT INTO", quote_id({prefix, table}), "DEFAULT VALUES"]),
      sql_param_count: 0,
      returning: returning
    }
  end
  def insert(prefix, table, header, rows, returning) do
    # Ecto sometimes populates columns in a row with nil, which it expects to be
    # replaced by DEFAULT. However, sqlite doesn't support DEFAULT in an INSERT
    # statement, so we need to split this into many different queries.
    if Enum.any?(rows, fn row -> nil in row end) do
      multiple_insert(prefix, table, header, rows, returning)
    else
      simple_insert(prefix, table, header, rows, returning)
    end
  end

  defp multiple_insert(prefix, table, header, rows, returning) do
    # We've got some default values to handle, so create a Query that contains
    # some sql for each individual row we need to insert.
    {sql, param_counts} =
      rows
      |> Enum.map(fn row ->
        {header, row} = drop_default_cols(header, row)

        %Query{sql: sql, sql_param_count: param_count} =
          insert(prefix, table, header, [row], [])

        {sql, param_count}
      end)
      |> Enum.unzip

    %Query{
      sql: sql,
      sql_param_count: param_counts,
      returning: returning_info(prefix, table, returning, "INSERT")
    }
  end

  defp drop_default_cols(header, row) do
    Enum.zip(header, row)
    |> Enum.reject(fn
      {_, nil} -> true
      _ -> false
    end)
    |> Enum.unzip
  end

  def simple_insert(prefix, table, header, rows, returning) do
    cols = map_intersperse(header, ",", &quote_id/1)
    {param_counter, vals} = insert_all(rows, 1, "")
    returning = returning_info(prefix, table, returning, "INSERT")
    %Query{
      sql: assemble([
        "INSERT INTO", quote_id({prefix, table}), "(", cols, ")",
        "VALUES", vals
      ]),
      sql_param_count: param_counter - 1,
      returning: returning
    }
  end

  defp insert_all([row|rows], counter, acc) do
    {counter, row} = insert_each(row, counter, "")
    insert_all(rows, counter, acc <> ",(" <> row <> ")")
  end
  defp insert_all([], counter, "," <> acc) do
    {counter, acc}
  end

  defp insert_each([nil|t], counter, acc),
    do: insert_each(t, counter, acc <> ",DEFAULT")
  defp insert_each([_|t], counter, acc),
    do: insert_each(t, counter + 1, acc <> ",?" <> Integer.to_string(counter))
  defp insert_each([], counter, "," <> acc),
    do: {counter, acc}

  def update(prefix, table, fields, filters, returning) do
    {vals, count} = Enum.map_reduce(fields, 1, fn (i, acc) ->
      {"#{quote_id(i)} = ?#{acc}", acc + 1}
    end)
    vals = Enum.intersperse(vals, ",")
    where = where_filter(filters, count)
    returning = returning_info(prefix, table, returning, "UPDATE")
    %Query{
      sql: assemble(["UPDATE", quote_id({prefix, table}), "SET", vals, where]),
      returning: returning
    }
  end

  def delete(prefix, table, filters, returning) do
    where = where_filter(filters)
    returning = returning_info(prefix, table, returning, "DELETE")
    %Query{
      sql: assemble(["DELETE FROM", quote_id({prefix, table}), where]),
      returning: returning
    }
  end

  ## Returning Clause Helpers

  @pseudo_returning_statement " ;--RETURNING ON "

  # SQLite does not have any sort of "RETURNING" clause upon which Ecto
  # relies.  Therefore, we have made up our own with its own syntax:
  #
  #    ;--RETURNING ON [INSERT | UPDATE | DELETE] <table>,<col>,<col>,...
  #
  # When the query/4 function is given a query with the above returning
  # clause, (1) it strips it from the end of the query, (2) parses it, and
  # (3) performs the query with the following transaction logic:
  #
  #   SAVEPOINT sp_<random>;
  #   CREATE TEMP TABLE temp.t_<random> (<returning>);
  #   CREATE TEMP TRIGGER tr_<random> AFTER UPDATE ON main.<table> BEGIN
  #       INSERT INTO t_<random> SELECT NEW.<returning>;
  #   END;
  #   UPDATE ...;
  #   DROP TRIGGER tr_<random>;
  #   SELECT <returning> FROM temp.t_<random>;
  #   DROP TABLE temp.t_<random>;
  #   RELEASE sp_<random>;
  #
  # which is implemented by the following code:
  defp returning_query(pid, query, params, opts) do
    %{table: table, cols: returning, query_type: query_type} = query.returning

    ref = case query_type do
      "DELETE" -> "OLD"
      "INSERT" -> "NEW"
      "UPDATE" -> "NEW"
    end

    with_savepoint(pid, fn ->
      with_temp_table(pid, returning, fn (tmp_tbl) ->
        err = with_temp_trigger(pid, table, tmp_tbl, returning, query_type, ref, fn ->
          execute(pid, %{query | returning: nil}, params, opts)
        end)

        case err do
          {:error, _} -> err
          _ ->
            fields = Enum.join(returning, ", ")
            do_execute(pid, "SELECT #{fields} FROM #{tmp_tbl}", [], opts)
        end
      end)
    end)
  end

  # Create a temp table to save the values we will write with our trigger
  # (below), call func.(), and drop the table afterwards.  Returns the
  # result of func.().
  defp with_temp_table(pid, returning, func) do
    tmp = "t_" <> random_id
    fields = Enum.join(returning, ", ")
    results = case exec(pid, "CREATE TEMP TABLE #{tmp} (#{fields})") do
      {:error, _} = err -> err
      _ -> func.(tmp)
    end
    exec(pid, "DROP TABLE IF EXISTS #{tmp}")
    results
  end

  # Create a trigger to capture the changes from our query, call func.(),
  # and drop the trigger when done.  Returns the result of func.().
  defp with_temp_trigger(pid, table, tmp_tbl, returning, query, ref, func) do
    tmp = "tr_" <> random_id
    fields = Enum.map_join(returning, ", ", &"#{ref}.#{&1}")
    sql = """
    CREATE TEMP TRIGGER #{tmp} AFTER #{query} ON main.#{table} BEGIN
        INSERT INTO #{tmp_tbl} SELECT #{fields};
    END;
    """
    results = case exec(pid, sql) do
      {:error, _} = err -> err
      _ -> func.()
    end
    exec(pid, "DROP TRIGGER IF EXISTS #{tmp}")
    results
  end

  # Execute a query with (possibly) binded parameters and handle busy signals
  # from the database.
  defp do_execute(pid, sql, params, opts) do
    mapper = opts[:decode_mapper] || fn x -> x end
    opts = opts |> Keyword.put(:bind, params)

    case Sqlitex.Server.query(pid, sql, opts) do
      # busy error means another process is writing to the database; try again
      {:error, {:busy, _}} -> do_execute(pid, sql, params, opts)
      {:error, msg} -> {:error, Sqlite.Ecto.Error.exception(msg)}
      {:ok, rows} -> query_result(pid, sql, rows, mapper)
    end
  end

  # If this is an INSERT, UPDATE, or DELETE, then return the number of changed
  # rows.  Otherwise (e.g. for SELECT) return the queried column values.
  defp query_result(pid, <<"INSERT ", _::binary>>, [], _), do: changes_result(pid)
  defp query_result(pid, <<"UPDATE ", _::binary>>, [], _), do: changes_result(pid)
  defp query_result(pid, <<"DELETE ", _::binary>>, [], _), do: changes_result(pid)
  defp query_result(_pid, _sql, rows, mapper) do
    rows = Enum.map(rows, fn row ->
      row
      |> cast_any_datetimes
      |> Keyword.values
      |> Enum.map(fn
        {:blob, binary} -> binary
        other -> other
      end)
    end) |> Enum.map(mapper)
    {:ok, %{rows: rows, num_rows: length(rows)}}
  end

  defp changes_result(pid) do
    {:ok, [["changes()": count]]} = Sqlitex.Server.query(pid, "SELECT changes()")
    {:ok, %{rows: nil, num_rows: count}}
  end

  # HACK: We have to do a special conversion if the user is trying to cast to
  # a DATETIME type.  Sqlitex cannot determine that the type of the cast is a
  # datetime value because datetime defaults to an integer type in SQLite.
  # Thus, we cast the value to a TEXT_DATETIME pseudo-type to preserve the
  # datetime string.  Then when we get here, we convert the string to an Ecto
  # datetime tuple if it looks like a cast was attempted.
  defp cast_any_datetimes(row) do
    Enum.map row, fn {key, value} ->
      str = Atom.to_string(key)
      if String.contains?(str, "CAST (") && String.contains?(str, "TEXT_DATE") do
        {key, string_to_datetime(value)}
      else
        {key, value}
      end
    end
  end

  defp string_to_datetime(<<yr::binary-size(4), "-", mo::binary-size(2), "-", da::binary-size(2)>>) do
    {String.to_integer(yr), String.to_integer(mo), String.to_integer(da)}
  end
  defp string_to_datetime(str) do
    <<yr::binary-size(4), "-", mo::binary-size(2), "-", da::binary-size(2), " ", hr::binary-size(2), ":", mi::binary-size(2), ":", se::binary-size(2), ".", fr::binary-size(6)>> = str
    {{String.to_integer(yr), String.to_integer(mo), String.to_integer(da)},{String.to_integer(hr), String.to_integer(mi), String.to_integer(se), String.to_integer(fr)}}
  end

  # SQLite does not have a returning clause, but we store a ReturningInfo
  # struct that query() can use later to emulate it with a transaction and
  # trigger.
  # See: returning_query()
  defp returning_info(_prefix, _table, [], _cmd), do: nil
  defp returning_info(prefix, table, returning, cmd) do
    %ReturningInfo{
      table: quote_id({prefix, table}),
      cols: Enum.map(returning, &quote_id/1),
      query_type: cmd
    }
  end

  ## Query generation

  binary_ops =
    [==: "=", !=: "!=", <=: "<=", >=: ">=", <:  "<", >:  ">",
     and: "AND", or: "OR",
     ilike: "ILIKE", like: "LIKE"]

  @binary_ops Keyword.keys(binary_ops)

  Enum.map(binary_ops, fn {op, str} ->
    defp handle_call(unquote(op), 2), do: {:binary_op, unquote(str)}
  end)

  defp handle_call(fun, _arity), do: {:fun, Atom.to_string(fun)}

  ## Generic Query Helpers

  alias Ecto.Query.JoinExpr
  alias Ecto.Query.QueryExpr
  alias Ecto.Query.SelectExpr

  defp create_names(%{prefix: prefix, sources: sources}, stmt) do
    create_names(prefix, sources, 0, tuple_size(sources), stmt) |> List.to_tuple()
  end
  defp create_names(prefix, sources, pos, limit, stmt) when pos < limit do
    current = case elem(sources, pos) do
      {table, model} ->
        {{prefix, table}, table_identifier(stmt, table, pos), model}
      {:fragment, _, _} = fragment ->
        {fragment, fragment_identifier(pos), nil}
    end
    [current | create_names(prefix, sources, pos + 1, limit, stmt)]
  end
  defp create_names(_, _, pos, pos, _), do: []

  defp table_identifier(:select, table, pos) do
    String.first(table) <> Integer.to_string(pos)
  end
  defp table_identifier(_stmt, table, _pos), do: quote_id(table)

  defp fragment_identifier(pos), do: "f" <> Integer.to_string(pos)

  defp select(%SelectExpr{expr: expr, fields: []}, distinct, sources) do
    ["SELECT", distinct(distinct), expr(expr, sources)]
  end

  defp select(%SelectExpr{fields: fields}, distinct, sources) do
    fields = Enum.map_join(fields, ", ", fn (f) ->
      assemble(expr(f, sources))
    end)
    ["SELECT", distinct(distinct), fields]
  end

  defp distinct(nil), do: []
  defp distinct(%QueryExpr{expr: true}), do: "DISTINCT"
  defp distinct(%QueryExpr{expr: false}), do: []
  defp distinct(%QueryExpr{expr: exprs}) when is_list(exprs) do
    raise ArgumentError, "DISTINCT with multiple columns is not supported by SQLite"
  end

  defp from(sources) do
    {table, id, _model} = elem(sources, 0)
    ["FROM", quote_id(table), "AS", id]
  end

  defp expr({:^, [], [_ix]}, _sources) do
    "?"
  end

  defp expr({{:., _, [{:&, _, [idx]}, field]}, _, []}, sources) when is_atom(field) do
    {_, name, _} = elem(sources, idx)
    "#{name}.#{quote_id(field)}"
  end

  defp expr({:&, _, [idx, fields, _counter]}, sources) do
    {table, name, model} = elem(sources, idx)
    if is_nil(model) and is_nil(fields) do
      raise ArgumentError, "SQLite requires a model when using selector #{inspect name} but " <>
                           "only the table #{inspect table} was given. Please specify a model " <>
                           "or specify exactly which fields from #{inspect name} you desire"
    end
    map_intersperse(fields, ",", &"#{name}.#{quote_id(&1)}")
  end

  defp expr({:in, _, [left, right]}, sources) when is_list(right) do
    args = Enum.map_join(right, ", ", &expr(&1, sources))
    if args == "", do: args = []
    [expr(left, sources), "IN (", args, ")"]
  end

  defp expr({:in, _, [left, {:^, _, [ix, 0]}]}, sources) do
    [expr(left, sources), "IN ()"]
  end

  defp expr({:in, _, [left, {:^, _, [ix, length]}]}, sources) do
    args = Enum.map_join(ix+1..ix+length, ", ", fn (_) -> "?" end)
    if args == "", do: args = []
    [expr(left, sources), "IN (", args, ")"]
  end

  defp expr({:in, _, [left, right]}, sources) do
    [expr(left, sources), "IN (", expr(right, sources), ")"]
  end

  defp expr({:is_nil, _, [arg]}, sources) do
    [expr(arg, sources), "IS", "NULL"]
  end

  defp expr({:not, _, [expr]}, sources) do
    ["NOT (", expr(expr, sources), ")"]
  end

  defp expr({:fragment, _, [kw]}, _sources) when is_list(kw) or tuple_size(kw) == 3 do
    raise ArgumentError, "SQLite adapter does not support keyword or interpolated fragments"
  end

  defp expr({:fragment, _, parts}, sources) do
    Enum.map_join(parts, "", fn
      {:raw, part}  -> part
      {:expr, expr} -> expr(expr, sources)
    end)
  end

  # start of SQLite function to display date
  # NOTE the open parenthesis must be closed
  @date_format "strftime('%Y-%m-%d'"

  defp expr({:date_add, _, [date, count, interval]}, sources) do
    ["CAST (", @date_format, ",", expr(date, sources), ",", interval(count, interval, sources), ") AS TEXT_DATE)"]
  end

  # start of SQLite function to display datetime
  # NOTE the open parenthesis must be closed
  @datetime_format "strftime('%Y-%m-%d %H:%M:%f000'"

  defp expr({:datetime_add, _, [datetime, count, interval]}, sources) do
    ["CAST (", @datetime_format, ",", expr(datetime, sources), ",", interval(count, interval, sources), ") AS TEXT_DATETIME)"]
  end

  defp expr({fun, _, args}, sources) when is_atom(fun) and is_list(args) do
    {modifier, args} =
      case args do
        [rest, :distinct] -> {"DISTINCT ", [rest]}
        _ -> {"", args}
      end

    case handle_call(fun, length(args)) do
      {:binary_op, op} ->
        [left, right] = args
        [op_to_binary(left, sources), op, op_to_binary(right, sources)]

      {:fun, fun} ->
        [fun, "(" <> modifier, map_intersperse(args, ",", &expr(&1, sources)), ")"]
    end
  end

  defp expr(%Decimal{} = decimal, _sources) do
    Decimal.to_string(decimal, :normal)
  end

  defp expr(%Ecto.Query.Tagged{value: binary, type: :binary}, _sources) when is_binary(binary) do
    "X'#{Base.encode16(binary, case: :upper)}'"
  end

  defp expr(%Ecto.Query.Tagged{value: other, type: type}, sources) when type in [:id, :integer, :float] do
    expr(other, sources)
  end

  defp expr(%Ecto.Query.Tagged{value: other, type: type}, sources) do
    ["CAST (", expr(other, sources), "AS", ecto_to_sqlite_type(type), ")"]
  end

  defp expr(nil, _sources),   do: "NULL"
  defp expr(true, _sources),  do: "1"
  defp expr(false, _sources), do: "0"

  defp expr(literal, _sources) when is_integer(literal) do
    String.Chars.Integer.to_string(literal)
  end

  defp expr(literal, _sources) when is_float(literal) do
    String.Chars.Float.to_string(literal)
  end

  defp expr(literal, _sources) when is_binary(literal) do
    "'#{:binary.replace(literal, "'", "''", [:global])}'"
  end

  defp interval(_, "microsecond", _sources) do
    raise ArgumentError, "SQLite does not support microsecond precision in datetime intervals"
  end

  defp interval(count, "millisecond", sources) do
    "(#{expr(count, sources)} / 1000.0) || ' seconds'"
  end

  defp interval(count, "week", sources) do
    "(#{expr(count, sources)} * 7) || ' days'"
  end

  defp interval(count, interval, sources) do
    "#{expr(count, sources)} || ' #{interval}'"
  end

  defp op_to_binary({op, _, [_, _]} = expr, sources) when op in @binary_ops do
    ["(", expr(expr, sources), ")"]
  end

  defp op_to_binary(expr, sources) do
    expr(expr, sources)
  end

  defp ecto_to_sqlite_type(type) do
    case type do
      {:array, _} -> raise ArgumentError, "Array type is not supported by SQLite"
      :id -> "INTEGER"
      :binary_id -> "TEXT"
      :uuid -> "TEXT" # SQLite does not support UUID
      :binary -> "BLOB"
      :float -> "NUMERIC"
      :string -> "TEXT"
      :date -> "TEXT_DATE"          # HACK see: cast_any_datetimes/1
      :datetime -> "TEXT_DATETIME"  # HACK see: cast_any_datetimes/1
      :map -> "TEXT"
      other -> other |> Atom.to_string |> String.upcase
    end
  end

  defp where([], _), do: []
  defp where(query_exprs, sources) do
    exprs = map_intersperse query_exprs, "AND", fn %QueryExpr{expr: expr} ->
      ["(", expr(expr, sources), ")"]
    end
    ["WHERE" | exprs]
  end

  # Generate a where clause from the given filters.
  defp where_filter(filters), do: where_filter(filters, 1)
  defp where_filter([], _start), do: []
  defp where_filter(filters, start) do
    {filters, _} = Enum.map_reduce filters, start, fn (filter, count) ->
      {"#{quote_id(filter)} = ?#{count}", count + 1}
    end
    ["WHERE" | Enum.intersperse(filters, "AND")]
  end

  defp order_by(order_bys, sources) do
    Enum.map_join(order_bys, ", ", fn %QueryExpr{expr: expr} ->
      Enum.map_join(expr, ", ", &ordering_term(&1, sources))
    end)
    |> order_by_clause
  end

  defp order_by_clause(""), do: []
  defp order_by_clause(exprs), do: ["ORDER BY", exprs]

  defp ordering_term({:asc, expr}, sources), do: assemble(expr(expr, sources))
  defp ordering_term({:desc, expr}, sources) do
    assemble(expr(expr, sources)) <> " DESC"
  end

  defp limit(nil, _offset, _sources), do: []
  defp limit(%QueryExpr{expr: expr}, offset, sources) do
    ["LIMIT", expr(expr, sources), offset(offset, sources)]
  end

  defp offset(nil, _sources), do: []
  defp offset(%QueryExpr{expr: expr}, sources) do
    ["OFFSET", expr(expr, sources)]
  end

  defp group_by(group_bys, havings, sources) do
    Enum.map_join(group_bys, ", ", fn %QueryExpr{expr: expr} ->
      Enum.map_join(expr, ", ", &assemble(expr(&1, sources)))
    end)
    |> group_by_clause(havings, sources)
  end

  defp group_by_clause("", _, _), do: []
  defp group_by_clause(exprs, havings, sources) do
    ["GROUP BY", exprs, having(havings, sources)]
  end

  defp having([], _sources), do: []
  defp having(havings, sources) do
    exprs = map_intersperse havings, "AND", fn %QueryExpr{expr: expr} ->
      ["(", expr(expr, sources), ")"]
    end
    ["HAVING" | exprs]
  end

  defp update_fields(updates, sources) do
    for(%{expr: expr} <- updates,
        {op, kw} <- expr,
        {key, value} <- kw,
        do: update_op(op, key, value, sources)) |> Enum.intersperse(",")
  end

  defp update_op(:set, key, value, sources) do
    [quote_id(key), "=", expr(value, sources)]
  end
  defp update_op(:inc, key, value, sources) do
    quoted = quote_id(key)
    [quoted, "=", quoted, "+", expr(value, sources)]
  end
  defp update_op(op, _key, _value, _sources) do
    raise ArgumentError, "Unknown update operation #{inspect op} for SQLite"
  end

  defp join([], _sources), do: []
  defp join(joins, sources) do
    Enum.map(joins, fn
      %JoinExpr{on: %QueryExpr{expr: expr}, qual: qual, ix: ix} ->
        qual = join_qual(qual)
        {join, name, _model} = elem(sources, ix)
        join = case join do
          {_, _} = table ->
            quote_id(table)
          {:fragment, _, _} ->
            ["(", expr(join, sources), ")"]
        end
        [qual, "JOIN", join, "AS", name, "ON", expr(expr, sources)]
    end)
  end

  defp join_qual(:inner), do: "INNER"
  defp join_qual(:left),  do: "LEFT"
  defp join_qual(:right) do
    raise ArgumentError, "RIGHT OUTER JOIN not supported by SQLite"
  end
  defp join_qual(:full) do
    raise ArgumentError, "FULL OUTER JOIN not supported by SQLite"
  end
end

require "db"
require "./conflict_handler"
require "./types"

module Stitch
  # :nodoc:
  struct CreateOperation(T)
    def initialize(@queryable : DB::Database | DB::Connection)
    end

    def call(query : QueryBuilder(T), params, on_conflict conflict_handler : ConflictHandler? = nil) : T
      args = Array(Value).new
      params.each_value { |v| args << v.as(Value) }
      sql = generate_query query.sql_table_name, params, args,
        on_conflict: conflict_handler,
        returning: ->(io : IO) { query.select_columns io }

      @queryable.query_one sql, args: args, as: T
    end

    def call!(query : QueryBuilder(T), params, on_conflict conflict_handler : ConflictHandler? = nil) : Bool
      args = Array(Value).new
      params.each_value { |v| args << v.as(Value) }
      sql = generate_query query.sql_table_name, params, args,
        on_conflict: conflict_handler,
        returning: nil

      @queryable.exec(sql, args: args).rows_affected == 1
    end

    protected def generate_query(
      table_name : String,
      params,
      args,
      on_conflict conflict_handler : ConflictHandler?,
      returning returning_clause,
    )
      sql = String.build do |str|
        str << "INSERT INTO " << table_name << " ("
        params.each_with_index(1) do |key, value, index|
          key.to_s.inspect str
          str << ", " if index < params.size
        end
        str << ") VALUES ("
        params.each_with_index(1) do |key, value, index|
          str << '?'
          str << ", " if index < params.size
        end
        str << ") "
        if conflict_handler
          if (action = conflict_handler.action) && (handler_params = action.params)
            handler_params.each_value do |value|
              args << value.as(Value)
            end
          end
          conflict_handler.to_sql str, start_at: 1
        end
        if returning_clause
          str << " RETURNING "
          returning_clause.call str
        end
      end
    end
  end
end

require "db"
require "./conflict_handler"
require "./types"

module Stitch
  # :nodoc:
  struct CreateManyOperation(T)
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

    def call!(query : QueryBuilder(T), params : Array(NamedTuple), on_conflict conflict_handler : ConflictHandler? = nil) : Int32
      args = Array(Value).new
      params.each do |param|
        param.each_value { |v| args << v.as(Value) }
      end
      sql = generate_query query.sql_table_name, params, args,
        on_conflict: conflict_handler

      @queryable.exec(sql, args: args)
        .rows_affected
        .to_i32
    end

    protected def generate_query(
      table_name : String,
      params : Array(NamedTuple),
      args,
      on_conflict conflict_handler : ConflictHandler?,
    )
      String.build do |str|
        str << "INSERT INTO " << table_name << " ("
        params.first.each_with_index(1) do |key, value, index|
          key.to_s.inspect str
          str << ", " if index < params.first.size
        end
        str << ") VALUES "
        params.each_with_index do |param, param_index|
          str << '('
          param.each_with_index(1) do |_key, _value, record_index|
            str << '?'
            str << ", " if record_index < param.size
          end
          str << ')'
          if param_index < params.size - 1
            str << ','
          end
          str << ' '
        end
        if conflict_handler
          if (action = conflict_handler.action) && (handler_params = action.params)
            handler_params.each_value do |value|
              args << value.as(Value)
            end
          end
          conflict_handler.to_sql str, start_at: 1
        end
      end
    end
  end
end

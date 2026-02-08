require "db"

require "./types"
require "./query"
require "./config"
require "./query_builder"
require "./model"

module Stitch
  VERSION = "0.1.0"

  class Error < ::Exception
  end

  class UnexpectedEmptyResultSet < Error
  end

  def self.transaction(& : DB::Transaction -> T) forall T
    result = uninitialized T
    completed = false
    CONFIG.write_db.transaction do |txn|
      result = yield txn
      completed = true
    end

    if completed
      result
    else
      raise "Transaction block is incomplete - unexpected rollback?"
    end
  end

  # :nodoc:
  struct UpdateOperation(T)
    def initialize(@queryable : DB::Database | DB::Connection)
    end

    def call(query, set values : NamedTuple, where : QueryExpression? = nil) forall U
      if values.is_a? NamedTuple()
        args = [] of Value
      else
        args = Array(Value).new
        values.each_value { |v| args << v.as(Value) }
        if where
          args = args + where.values
        end
      end

      @queryable.query_all to_sql(query, where, values), args: args, as: T
    end

    def call(query, set values : String, args : Array(Value) = [] of Value, where : QueryExpression? = nil)
      if where
        args = args + where.values
      end

      @queryable.query_all to_sql(query, where, values), args: args, as: T
    end

    def to_sql(query, where, values)
      table_name = query.sql_table_name

      sql = String.build do |str|
        str << "UPDATE " << table_name << ' '
        str << "SET "
        sqlize values, where, to: str

        if where
          str << " WHERE "
          where.to_sql str
        end

        str << " RETURNING "
        query.select_columns str
      end
    end

    private def sqlize(values : NamedTuple, where, to io) : Nil
      last_index = values.size
      values.each_with_index(1) do |key, value, index|
        key.to_s io
        io << " = ?"
        if index < last_index
          io << ", "
        end
      end
    end

    private def sqlize(values : String, where, to io) : Nil
      io << values
    end
  end

  # :nodoc:
  struct DeleteOperation
    def initialize(@queryable : DB::Database | DB::Connection)
    end

    def call(table_name : String, where : QueryExpression)
      sql = String.build do |str|
        str << "DELETE FROM " << table_name
        str << " WHERE "
        where.to_sql str
      end

      @queryable
        .exec(sql, args: where.values)
        .rows_affected
    end

    def call(table_name : String, where : Nil)
      raise UnscopedDeleteOperation.new("Invoked a DeleteOperation with no WHERE clause. If this is intentional, use a TruncateOperation instead")
    end

    class UnscopedDeleteOperation < Exception
    end
  end

  class Exception < ::Exception
  end

  class NotFound < Exception
  end
end

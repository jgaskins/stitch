require "./query_builder"

module Stitch
  abstract struct QueryBuilder(T)
    protected def fetch(columns : NamedTuple, delegate = self)
      fetch columns.keys.join(", "),
        as: columns.values,
        delegate: self
    end

    protected def fetch(columns : String, as type : U, delegate : V = self) forall U, V
      {% begin %}
        DynamicQuery(
          {% if U < Tuple %}
            { {{U.type_vars.map(&.instance).join(", ").id}} },
          {% else %}
            {{U.instance}},
          {% end %}
          V
        ).new(
          select: columns,
          distinct: @distinct,
          from: sql_table_name,
          join: @join_clause,
          where: @where_clause,
          order_by: @order_by_clause,
          offset: @offset_clause,
          limit: @limit_clause,
          args: @args,
          transaction: transaction,
          delegate: delegate,
        )
      {% end %}
    end
  end

  struct DynamicQuery(T, U) < QueryBuilder(T)
    protected property select_columns : String
    getter sql_table_name : String

    def initialize(
      select @select_columns,
      @distinct,
      from @sql_table_name,
      join @join_clause,
      where @where_clause,
      order_by @order_by_clause,
      offset @offset_clause,
      limit @limit_clause,
      @args,
      @transaction,
      @delegate : U,
    )
    end

    delegate(
      sql_table_alias,
      model_table_mappings,
      to: @delegate
    )

    protected def fetch(columns : String, as type : U, delegate : V = @delegate) forall U, V
      delegate.fetch "#{@select_columns}, #{columns}",
        as: {{(T < Tuple ? "T" : "{T}").id}} + {{(U < Tuple ? "U" : "{U}").id}},
        delegate: self
    end

    # Set operations are defined here rather than forwarded to `@delegate` so
    # that the compound query reflects *this* query's projected columns and
    # result type (`T`) rather than the delegate's. The right-hand side is
    # re-projected through the same `SELECT` list so both halves line up.
    def |(other : QueryBuilder) : CompoundQuery(T)
      CompoundQuery(T).new(self, "UNION", project(other), connection(CONFIG.read_db))
    end

    def &(other : QueryBuilder) : CompoundQuery(T)
      CompoundQuery(T).new(self, "INTERSECT", project(other), connection(CONFIG.read_db))
    end

    def -(other : QueryBuilder) : CompoundQuery(T)
      CompoundQuery(T).new(self, "EXCEPT", project(other), connection(CONFIG.read_db))
    end

    # Re-project `other` through this query's `SELECT` list so it produces the
    # same columns (and result type `T`) as the receiver, making it suitable as
    # the other half of a set operation.
    protected def project(other : QueryBuilder)
      DynamicQuery(T, typeof(other)).new(
        select: @select_columns,
        distinct: other.distinct?,
        from: other.sql_table_name,
        join: other.join_clause,
        where: other.where_clause,
        order_by: other.order_by_clause,
        offset: other.offset_clause,
        limit: other.limit_clause,
        args: other.args,
        transaction: other.transaction,
        delegate: other,
      )
    end

    macro method_missing(call)
      @delegate.distinct = @distinct
      @delegate.join_clause = @join_clause
      @delegate.where_clause = @where_clause
      @delegate.order_by_clause = @order_by_clause
      @delegate.offset_clause = @offset_clause
      @delegate.limit_clause = @limit_clause
      @delegate.args = @args
      @delegate.transaction = @transaction
      %new_query = @delegate.{{call}}
      case %new_query
      when U
        {{@type.id}}.new(
          @select_columns,
          @distinct,
          from: sql_table_name,
          join: %new_query.join_clause,
          where: %new_query.where_clause,
          order_by: %new_query.order_by_clause,
          offset: %new_query.offset_clause,
          limit: %new_query.limit_clause,
          args: %new_query.args,
          transaction: %new_query.transaction,
          delegate: @delegate,
        )
      else
        %new_query
      end
    end

    protected def select_columns(io) : Nil
      io << @select_columns
    end
  end
end

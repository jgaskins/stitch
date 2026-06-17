require "db"
require "./join_clause"
require "./query_record"
require "./dynamic_query"
require "./validations"
require "./create_operation"
require "./create_many_operation"

module Stitch
  alias OrderBy = Hash(String, String)

  abstract struct QueryBuilder(T)
    include Enumerable(T)
    include Iterable(T)
    include Validations

    macro table(name, as table_alias = nil)
      def sql_table_name
        {{name}}
      end

      def sql_table_alias
        {{table_alias || name}}
      end

      def model_table_mappings
        { T => {{name}} }
      end
    end

    macro from(name, *joins)
      def sql_table_name
        {{name}}
      end

      def sql_table_alias
        sql_table_name
      end

      def model_table_mappings
        {
          {% for type_var, index in T.type_vars %}
            {% if index == 0 %}
              {{type_var}} => {{name}},
            {% else %}
              {% args = joins[index - 1].named_args %}

              {{type_var}} => {{(args.find { |arg| arg.name == "as".id } || args.first).value}},
            {% end %}
          {% end %}
        }
      end

      def self.new
        super
          {% for join in joins %}
            .{{join}}
          {% end %}
      end
    end

    def self.[](transaction : ::DB::Transaction) : self
      new.with_transaction(transaction)
    end

    def self.[](transaction : Nil) : self
      new
    end

    def self.new(transaction_owner : ::Stitch::QueryBuilder)
      self[transaction_owner.transaction]
    end

    protected property? distinct : Bool = false
    protected property join_clause = [] of JoinClause
    protected property where_clause : QueryExpression?
    protected property order_by_clause : OrderBy?
    protected property limit_clause : Int32? = nil
    protected property offset_clause : Int32? = nil
    protected property transaction : ::DB::Transaction? = nil
    protected property args : Array(Value) = Array(Value).new

    def first
      first? || raise UnexpectedEmptyResultSet.new("#{self} returned no results")
    end

    def first(count : Int)
      limit count
    end

    def first?
      limit(1).each { |obj| return obj }
      nil
    end

    def each
      args = build_query_args
      ResultSetIterator(T).new(
        db: connection(CONFIG.read_db),
        query: to_sql,
        args: args,
      )
    end

    def each(& : T ->)
      args = build_query_args

      connection(Stitch::CONFIG.read_db).query_each to_sql, args: args do |rs|
        {% begin %}
          {% if T < Tuple %}
            yield({ {% for type, index in T.type_vars %} rs.read({{type}}) {% if index < T.type_vars.size - 1 %},{% end %} {% end %} })
          {% else %}
            yield T.new(rs)
          {% end %}
        {% end %}
      end
    end

    private def build_query_args : Array(Value)
      args = @args.dup
      if limit = limit_clause
        args << limit.as(Value)
      end
      if offset = offset_clause
        args << offset.as(Value)
      end
      args
    end

    def merge(other : QueryBuilder) : self
      new = dup
      new.join_clause += other.join_clause
      if (my_where = new.where_clause) && (their_where = other.where_clause)
        new.where_clause = my_where & their_where
      else
        new.where_clause ||= other.where_clause
      end
      new.args += other.args
      if (my_order = new.order_by_clause) && (their_order = other.order_by_clause)
        new.order_by_clause = my_order.merge(their_order)
      else
        new.order_by_clause ||= other.order_by_clause
      end
      new
    end

    def to_json(json : JSON::Builder) : Nil
      json.array do
        each(&.to_json(json))
      end
    end

    def to_sql : String
      String.build do |str|
        to_sql str
      end
    end

    def |(other : self) : CompoundQuery
      CompoundQuery.new(self, "UNION", other, connection(CONFIG.read_db))
    end

    def &(other : self) : CompoundQuery
      CompoundQuery.new(self, "INTERSECT", other, connection(CONFIG.read_db))
    end

    def -(other : self) : CompoundQuery
      CompoundQuery.new(self, "EXCEPT", other, connection(CONFIG.read_db))
    end

    def count : Int64
      scalar "count(*)", as: Int64
    end

    # :doc:
    protected def find(**params) : T?
      query = where(**params).limit(1)
      args = query.args + [1] of Value

      connection(CONFIG.read_db).query_one? query.to_sql, args: args, as: T
    end

    # :doc:
    protected def inner_join(other_table, on condition : String, as relation = nil)
      new = dup
      new.join_clause = join_clause.dup
      new.join_clause << JoinClause.new(other_table, relation, condition)
      new
    end

    # :doc:
    protected def left_join(other_table, on condition : String, as relation = nil)
      new = dup
      new.join_clause = join_clause.dup
      new.join_clause << JoinClause.new(other_table, relation, condition, join_type: "LEFT")
      new
    end

    # :doc:
    protected def where(**params : Value) : self
      where_clause = nil
      args = Array(Value).new(initial_capacity: params.size)
      params.each do |key, value|
        case value
        when Nil
          new_clause = QueryExpression.new(key.to_s, "IS", "NULL", [] of Value)
        else
          args << value.as(Value)
          new_clause = QueryExpression.new(key.to_s, "=", "?", [value.as(Value)])
        end

        if where_clause
          where_clause &= new_clause
        else
          where_clause = new_clause
        end
      end

      if where_clause && (current_where_clause = @where_clause)
        where_clause = current_where_clause & where_clause
      end

      new = dup
      if where_clause
        new.where_clause = where_clause
        if @args.any?
          new.args = @args + args
        else
          new.args = args
        end
      end
      new
    end

    # :doc:
    protected def where(table = sql_table_alias, &block : QueryRecord -> QueryExpression) : self
      index = @args.size
      where_clause = yield(QueryRecord.new(table) { index += 1 })
      values = where_clause.values

      if current_where_clause = @where_clause
        where_clause = current_where_clause & where_clause
      end

      new = dup
      new.where_clause = where_clause
      new.args = @args + values
      new
    end

    # :doc:
    protected def where(lhs : String, comparator : String, rhs : String, values : Array(Value) = [] of Value) : self
      where_clause = Stitch::QueryExpression.new(lhs, comparator, rhs, values)

      if current_where_clause = @where_clause
        where_clause = current_where_clause & where_clause
      end

      new = dup
      new.where_clause = where_clause
      if @args.any?
        new.args = @args + values
      else
        new.args = values
      end
      new
    end

    # :doc:
    protected def where(expression : String, values : Array(Value) = [] of Value) : self
      where_clause = Stitch::QueryExpression.new(expression, values)

      if current_where_clause = @where_clause
        where_clause = current_where_clause & where_clause
      end

      new = dup
      new.where_clause = where_clause
      if @args.any?
        new.args = @args + values
      else
        new.args = values
      end
      new
    end

    # :doc:
    protected def order_by(**params : OrderByDirection) : self
      order_by(**params.transform_values(&.to_s))
    end

    enum OrderByDirection
      ASC
      DESC
      ASC_NULLS_FIRST
      ASC_NULLS_LAST
      DESC_NULLS_FIRST
      DESC_NULLS_LAST

      def to_s
        {% for member in @type.constants %}
          if value == {{@type.constant(member)}}
            return {{member.stringify.tr("_", " ")}}
          end

          value.to_s
        {% end %}
      end
    end

    # :doc:
    protected def order_by(**params : String) : self
      order_by_clause = OrderBy.new(initial_capacity: params.size)
      params.each { |key, value| order_by_clause[key.to_s] = value }

      if current_order_clause = @order_by_clause
        order_by_clause = current_order_clause.merge(order_by_clause)
      end

      new = dup
      new.order_by_clause = order_by_clause
      new
    end

    # :doc:
    protected def order_by(expression, direction) : self
      order_by_clause = OrderBy{expression => direction}

      if current_order_clause = @order_by_clause
        order_by_clause = current_order_clause.merge(order_by_clause)
      end

      new = dup
      new.order_by_clause = order_by_clause
      new
    end

    # :doc:
    protected def limit(count : Int) : self
      new = dup
      new.limit_clause = count
      new
    end

    # :doc:
    protected def offset(count : Int) : self
      new = dup
      new.offset_clause = count
      new
    end

    # :doc:
    protected def distinct : self
      new = dup
      new.distinct = true
      new
    end

    protected def with_transaction(transaction : DB::Transaction) : self
      new = dup
      new.transaction = transaction
      new
    end

    # :doc:
    protected def scalar(select expression : String, as type : U.class) : U forall U
      args = build_query_args

      sql = String.build do |str|
        to_sql str do
          expression.to_s str
        end
      end
      connection(CONFIG.read_db).scalar(sql, args: args).as(U)
    end

    def empty?
      none?
    end

    def any? : Bool
      !none?
    end

    def none? : Bool
      sql = String.build do |str|
        str << "SELECT 1 AS one"
        str << " FROM " << sql_table_name

        if join = join_clause
          join.each(&.to_sql(str))
        end

        if where = where_clause
          str << " WHERE " << where.to_sql
        end

        str << " LIMIT 1"
      end

      !connection(CONFIG.read_db).query_one? sql, args: @args, as: Int32
    end

    # :doc:
    protected def insert(**values) : T
      insert values
    end

    # :doc:
    protected def insert(values : NamedTuple) : T
      insert values: values, on_conflict: nil
    end

    # :doc:
    protected def insert!(**values) : Bool
      insert! values
    end

    # :doc:
    protected def insert!(values : NamedTuple) : Bool
      insert! values: values, on_conflict: nil
    end

    # :doc:
    protected def insert(values : NamedTuple, on_conflict : ConflictHandler?) : T
      create_operation.call(self, values, on_conflict: on_conflict)
    end

    # :doc:
    protected def insert!(values : NamedTuple, on_conflict : ConflictHandler?) : Bool
      create_operation.call!(self, values, on_conflict: on_conflict)
    end

    # :doc:
    protected def insert!(records : Array(NamedTuple), on_conflict : ConflictHandler? = nil) : Int32
      create_many_operation.call!(self, records, on_conflict: on_conflict)
    end

    private def create_operation
      CreateOperation(T).new(connection(CONFIG.write_db))
    end

    private def create_many_operation
      CreateManyOperation(T).new(connection(CONFIG.write_db))
    end

    # :doc:
    protected def update(**params) : Array(T)
      update params
    end

    # :doc:
    protected def update(*expressions) : Array(T)
      UpdateOperation(T).new(connection(CONFIG.write_db))
        .call self,
          set: expressions.join(", "),
          where: @where_clause
    end

    # :doc:
    protected def update(set clause : String, args : Array)
      UpdateOperation(T).new(connection(CONFIG.write_db))
        .call self,
          set: clause,
          args: args,
          where: @where_clause
    end

    # :doc:
    protected def update(params : NamedTuple) : Array(T)
      UpdateOperation(T).new(connection(CONFIG.write_db))
        .call self,
          set: params,
          where: @where_clause
    end

    # :doc:
    protected def delete
      DeleteOperation.new(connection(CONFIG.write_db))
        .call sql_table_name,
          where: @where_clause
    end

    protected def write_db
      connection(CONFIG.write_db)
    end

    protected def read_db
      connection(CONFIG.read_db)
    end

    # :doc:
    protected def transaction(&)
      Stitch.transaction do |txn|
        old_txn = @transaction
        @transaction = txn
        yield txn
      ensure
        @transaction = old_txn
      end
    end

    protected def select_columns(io : IO) : Nil
      {% if T < Tuple %}
        {% for type, index in T.type_vars %}
          select_columns_for_model {{type}}, io
          {% if index < T.type_vars.size - 1 %}
            io << ", "
          {% end %}
        {% end %}
      {% else %}
        select_columns_for_model T, io
      {% end %}
    end

    protected def select_columns_for_model(model : U.class, io) : Nil forall U
      model_table_mappings = self.model_table_mappings

      {% begin %}
        {%
          ivars = U.instance_vars.reject do |ivar|
            ann = ivar.annotation(::Stitch::Field) || ivar.annotation(::DB::Field)
            ann && ann[:ignore]
          end
        %}

        {% for ivar, index in ivars %}
          {% ann = ivar.annotation(::Stitch::Field) || ivar.annotation(::DB::Field) %}

            {% if ann && (key = ann[:key]) %}
              io << model_table_mappings[model] << ".{{key.id}}"
            {% elsif ann && ann[:select] %}
              io << {{ann[:select]}} << " AS {{(ann[:as] || ivar).id}}"
            {% else %}
              io << model_table_mappings[model] << ".{{ivar.name}}"
            {% end %}

          {% if index < ivars.size - 1 %}
            io << ", "
          {% end %}
        {% end %}
      {% end %}
    end

    # :doc:
    protected def select_columns
      String.build { |str| select_columns str }
    end

    # :doc:
    protected def select_columns(relation_name : String? = nil)
      relation_name ||= model_table_mappings[T]
      String.build { |str| select_columns str, relation_name }
    end

    protected def select_columns(io : IO, relation_name = model_table_mappings[T]) : Nil
      {% if T < Tuple %}
        {% for type, index in T.type_vars %}
          select_columns_for_model {{type}}, io, relation_name
          {% if index < T.type_vars.size - 1 %}
            io << ", "
          {% end %}
        {% end %}
      {% else %}
        select_columns_for_model T, io, relation_name
      {% end %}
    end

    protected def select_columns_for_model(model : U.class, io : IO, relation_name = model_table_mappings[model]) : Nil forall U
      {% begin %}
        {%
          ivars = U.instance_vars.reject do |ivar|
            ann = ivar.annotation(::Stitch::Field) || ivar.annotation(::DB::Field)
            ann && ann[:ignore]
          end
        %}

        {% for ivar, index in ivars %}
          {% ann = ivar.annotation(::Stitch::Field) || ivar.annotation(::DB::Field) %}

          {% if ann && (key = ann[:key]) %}
            relation_name.inspect io
            io << ".{{key.id}}"
          {% elsif ann && ann[:select] %}
            {{ann[:select]}}.to_s io
            io << " AS {{(ann[:as] || ivar).id}}"
          {% else %}
            relation_name.inspect io
            io << %{."{{ivar.name}}"}
          {% end %}

          {% if index < ivars.size - 1 %}
            io << ", "
          {% end %}
        {% end %}
      {% end %}
    end

    # :doc:
    protected def to_sql(io) : Nil
      to_sql(io) { select_columns io }
    end

    private def to_sql(str, &) : Nil
      str << "SELECT "
      if distinct?
        str << "DISTINCT "
      end

      # SELECT columns
      yield str

      str << " FROM " << sql_table_name
      if sql_table_name != sql_table_alias
        str << " AS " << sql_table_alias
      end

      @join_clause.each do |join|
        join.to_sql str
      end

      if where = @where_clause
        str << " WHERE "
        where.to_sql str
      end

      if order = @order_by_clause
        str << " ORDER BY "
        order.each_with_index(1) do |(key, direction), index|
          str << key << ' ' << direction.upcase
          if index < order.size
            str << ", "
          end
        end
      end

      if limit = @limit_clause
        str << " LIMIT ?"
      end

      if offset = @offset_clause
        str << " OFFSET ?"
      end
    end

    private def connection(db)
      @transaction.try(&.connection) || db
    end

    class ResultSetIterator(T)
      include Iterator(T)

      @result_set : DB::ResultSet

      def initialize(db : DB::Database | DB::Connection, query : String, args : Array)
        @result_set = db.query(query, args: args)
      end

      def next
        if @result_set.move_next
          {% if T < Tuple %}
            {
              {% for type in T.type_vars %}
                @result_set.read({{type}}),
              {% end %}
            }
          {% else %}
            T.new(@result_set)
          {% end %}
        else
          @result_set.close
          stop
        end
      end

      def finalize
        @result_set.close
      end
    end

    struct CompoundQuery(T)
      include Enumerable(T)

      protected property limit : Int64? = nil

      def initialize(
        @lhs : QueryBuilder(T),
        @combinator : String,
        @rhs : QueryBuilder(T),
        @connection : ::DB::Database | ::DB::Connection,
      )
      end

      def each(& : T ->)
        args = @lhs.args + @rhs.args
        if limit = @limit
          args << limit.as(Value)
        end

        @connection.query_each to_sql, args: args do |rs|
          {% if T < Tuple %}
            yield({ {% for type, index in T.type_vars %} rs.read({{type}}) {% if index < T.type_vars.size - 1 %},{% end %} {% end %} })
          {% else %}
            yield T.new(rs)
          {% end %}
        end
      end

      def first(count : Int)
        new = dup
        new.limit = count
        new
      end

      def to_sql
        lhs = @lhs.to_sql
        rhs = @rhs.to_sql

        String.build do |str|
          str << lhs
          str << ' ' << @combinator << ' '
          str << rhs
          if @limit
            str << " LIMIT ?"
          end
        end
      end
    end
  end
end

struct NamedTuple
  def transform_values(&)
    {% begin %}
      {
        {% for key, value in T %}
          {{key.stringify}}: yield(self[:{{key.stringify}}]),
        {% end %}
      }
    {% end %}
  end
end

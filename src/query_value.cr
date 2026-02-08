require "./types"
require "./query_expression"

module Stitch
  struct QueryValue
    getter value : String
    getter index : Int32

    def initialize(@value, @index)
    end

    def ==(other : Value)
      QueryExpression.new(value, "=", "?", [other] of Value)
    end

    def ==(other : Nil)
      QueryExpression.new(value, "IS", "NULL", [] of Value)
    end

    def <=(other : Value)
      QueryExpression.new(value, "<=", "?", [other] of Value)
    end

    def >=(other : Value)
      QueryExpression.new(value, ">=", "?", [other] of Value)
    end

    def <(other : Value)
      QueryExpression.new(value, "<", "?", [other] of Value)
    end

    def >(other : Value)
      QueryExpression.new(value, ">", "?", [other] of Value)
    end

    def !=(other : Value)
      QueryExpression.new(value, "!=", "?", [other] of Value)
    end

    def !=(other : Nil)
      QueryExpression.new(value, "IS NOT", "NULL", [] of Value)
    end

    def in?(array : Enumerable)
      values = Array(Value).new
      array.each { |v| values << v.as(Value) }
      placeholders = values.map { "?" }.join(", ")
      QueryExpression.new(value, "IN", "(#{placeholders})", values)
    end

    def not_in?(array : Enumerable)
      values = Array(Value).new
      array.each { |v| values << v.as(Value) }
      placeholders = values.map { "?" }.join(", ")
      QueryExpression.new(value, "NOT IN", "(#{placeholders})", values)
    end

    {% for operator in %w[& | ^] %}
      def {{operator.id}}(other : Value)
        QueryExpression.new(value, {{operator}}, "?", [other] of Value)
      end
    {% end %}
  end
end

module Stitch
  struct JoinClause
    getter other_table : String
    getter relation : String?
    getter condition : String
    getter join_type : String

    def initialize(@other_table, as @relation, on @condition, @join_type = "INNER")
    end

    def to_sql(io)
      io << ' ' << @join_type << " JOIN "
      other_table.inspect io
      if relation
        io << " AS "
        relation.inspect io
      end
      io << " ON " << condition << ' '
    end

    def to_sql
      String.build { |str| to_sql str }
    end
  end
end

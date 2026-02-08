# stitch

Stitch is a SQLite-based ORM for Crystal, inspired by [Interro](https://github.com/jgaskins/interro).

## Installation

1. Add the dependency to your `shard.yml`:

   ```yaml
   dependencies:
     stitch:
       github: jgaskins/stitch
   ```

2. Run `shards install`

## Usage

```crystal
require "stitch"
require "db"
require "sqlite3"

Stitch.config do |c|
  c.db = DB.open("sqlite3://my_app.db")

  # or if you're using separate DBs for reads and writes:
  c.read_db = DB.open("sqlite3://read.db")
  c.write_db = DB.open("sqlite3://write.db")
end
```

## Migrations

Migrations are, by convention, in the `./db/migrations` directory.

### Generating a migration

```
bin/stitch-migration g CreateUsers
```

This creates a directory called `db/migrations/YYYY_MM_DD_HH_MM_SS_NANOSECONDS-CreateUsers`. Inside this directory are two files called `up.sql` and `down.sql`. Respectively, these files represent the SQL queries needed to execute and roll-back the migration. Opening our `up.sql` file, we can edit it to say:

```sql
CREATE TABLE users(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  email TEXT UNIQUE NOT NULL,
  name TEXT NOT NULL,
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at TEXT NOT NULL DEFAULT (datetime('now'))
)
```

and in our `down.sql` file:

```sql
DROP TABLE users
```

**Note:** You can only execute one statement per SQL file. Additional statements must be done inside a separate migration.

### Executing the migration

Your `CreateUsers` migration can be executed with the following command:

```
bin/stitch-migration run CreateUsers
```

If you want to execute _all_ migrations that have not yet been run (say, if you just pulled someone else's changes that contained a migration), you can simply omit the migration name. The default is to run all migrations.

### Rolling back a migration

You can roll back a specific migration by executing the following command:

```
bin/stitch-migration rollback CreateUsers
```

## Models

Once our table is created, we can create a model to represent that data inside the application. To do that, we create a `class` or `struct` with the desired name (for example, we might choose `User` to represent a row in the `users` table):

```crystal
struct User
  include DB::Serializable

  getter id : Int64
  getter name : String
  getter email : String
  getter created_at : String
  getter updated_at : String
end
```

There are 3 things to note here:

1. We `include DB::Serializable`. This mixin is provided by the `crystal-lang/crystal-db` shard to deserialize rows into objects. Stitch does not require anything else of your models than that.
2. Since we specified `NOT NULL` on all of the columns in our migration, we can avoid making any of the properties `nil`-able. If any of your columns do not have `NOT NULL` constraints, you should allow them to be `nil` here or you will not be able to deserialize those rows.
3. Our model only specifies properties using `getter` and not `property`. This makes the models immutable.

## Queries

Stitch supports 2 different concepts for queries:

1. `Stitch::QueryBuilder(T)` for generating SQL queries
2. `Stitch::Query` to allow you to write your own SQL queries

### `QueryBuilder(T)`

The simplest way to get started is to write a `struct` that inherits from `Stitch::QueryBuilder` for your model:

```crystal
struct UserQuery < Stitch::QueryBuilder(User)
  table "users" # Send queries to the "users" table
end
```

If you're familiar with ActiveRecord in Ruby, you might be tempted to then run something like `UserQuery.where(foo: "bar")`, but Stitch's query builder works a little differently. First, it must be instantiated.

```crystal
users = UserQuery.new
```

Then, instead of using methods like `where` all over your application, you need to add methods to give names to those concepts. For example, if you want to find all the users in a given group:

```crystal
struct UserQuery < Stitch::QueryBuilder(User)
  table "users"

  def members_of(group : Group)
    where(group_id: group.id)
  end
end
```

If you're familiar with ActiveRecord, these are very similar to scopes. Stitch requires you to put your queries behind these "scope" methods in order to insulate your application from your database structure. Methods like `where` are unavailable outside the class. This way, when your database structure changes, it isolates the code changes to the methods inside these classes.

Here are a few methods provided by `Stitch::QueryBuilder`:

- `where(name: "Jamie")`
- `where { |user| user.created_at < timestamp }`
- `inner_join("groups", as: "g", on: "users.group_id = g.id")`
- `order_by(created_at: "DESC")`
- `limit(25)`
- `scalar("count(*)", as: Int64)`
- `insert(name: "Jamie", email: "jamie@example.com") : T`: returns the created record
- `update(role: "admin") : T`: returns the updated models (allowing for immutable models)
- `delete`

Each one of these methods returns a new instance of the query builder. This lets you compose them in your query builder's methods and even makes your own methods composable. For example:

```crystal
struct UserQuery < Stitch::QueryBuilder(User)
  table "users"

  def with_id(id : Int64)
    where(id: id).first
  end

  def registered_before(timestamp : Time)
    where { |user| user.created_at < timestamp }
  end

  def oldest_first
    order_by created_at: "DESC"
  end

  def in_group(group : Group)
    where(group_id: group.id)
  end

  def in_group_with_name(group_name : String)
    self
      .inner_join("groups", as: "g", on: "users.group_id = g.id")
      .where("g.name": group_name)
  end

  def deactivate!(user : User) : User
    update active: false
  end

  def at_most(count : Int32)
    limit count
  end

  def count
    scalar("count(*)", as: Int64)
  end
end

UserQuery.new
  .in_group(group)
  .oldest_first
  .at_most(25)
```

This query will get you the 25 oldest users (by registration date) in the specified group. The benefit here is that if we change the relationship between users and groups such that users can be a member of multiple groups, for example, this call doesn't need to change. You only need to change the internals of the query classes that know about that and you can keep the interfaces the exact same.

#### Transactions

You can operate a transaction using the `Stitch.transaction(&)` method and passing that transaction to your query objects. For example, to deactivate a group and all its users within the same transaction:

```crystal
Stitch.transaction do |txn|
  group = GroupQuery[txn].deactivate! id: group_id
  UserQuery[txn]
    .in_group(group)
    .deactivate_all!
end
```

If an exception occurs within the transaction block, it will be rolled back, so it may be important not to overwrite any variables from outside the block until the block completes:

```crystal
group = GroupQuery.new.with_id(group_id)

Stitch.transaction do |txn|
  group = GroupQuery[txn].deactivate!(id: group_id)
  UserQuery[txn]
    .in_group(group)
    .deactivate_all!

  # oops, connection to the database goes out!
end

group # This will be the deactivated one even if the transaction fails
```

### `Stitch::Query`

The other way to create queries with Stitch is to create entire query objects. These are structs that represent a single SQL query:

```crystal
struct GetUserByID < Stitch::Query
  def call(id : Int64) : User?
    read_one? <<-SQL, id, as: User
      SELECT *
      FROM users
      WHERE id = ?
      LIMIT 1
    SQL
  end
end

if user = GetUserByID[user_id]
  # ...
end
```

The use case for these query objects are when a query is more complex than `Stitch::QueryBuilder` can generate. For example, complex reporting queries, queries that return multiple entities per row, or any arbitrary SQL statement needed.

Methods you can use within `Stitch::Query` objects:

- Run against the read DB:
  - `read_one(query, *args, as: MyClass)`: asserts that one and only one row matches your query. If there are 0 or >1, an exception is raised.
  - `read_one?(query, *args, as: MyClass)`: returns either the first matching row or `nil` if no rows match.
  - `read_all(query, *args, as: MyClass) : Array(MyClass)`: returns all matching rows as an array
- Run against the write DB:
  - `write_one(query, *args, as: MyClass)`: asserts a single match, assumes a `RETURNING` clause
  - `write(query, *args)`: runs the specified query and ignores any returned data

#### Transactions

Transactions are performed the same way as with `QueryBuilder`, by passing the transaction to the queries with the transaction in brackets:

```crystal
Stitch.transaction do |txn|
  user = GetUserByID[txn][user_id]
  ChangeUserPassword[txn][new_password]
end
```

## Contributing

1. Fork it (<https://github.com/jgaskins/stitch/fork>)
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create a new Pull Request

## Contributors

- [Jamie Gaskins](https://github.com/jgaskins) - creator and maintainer

require "spec"
require "sqlite3"
require "../src/stitch"

TEST_DB = DB.open("sqlite3::memory:")

Stitch.config do |c|
  c.db = TEST_DB
end

TEST_DB.exec <<-SQL
  CREATE TABLE posts (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    title TEXT NOT NULL,
    body TEXT NOT NULL,
    published INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
  )
SQL

TEST_DB.exec <<-SQL
  CREATE TABLE comments (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    post_id INTEGER NOT NULL,
    body TEXT NOT NULL,
    author TEXT NOT NULL,
    FOREIGN KEY (post_id) REFERENCES posts(id)
  )
SQL

TEST_DB.exec <<-SQL
  CREATE TABLE tags (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT UNIQUE NOT NULL
  )
SQL

TEST_DB.exec <<-SQL
  CREATE TABLE articles (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    title TEXT NOT NULL,
    published BOOLEAN NOT NULL DEFAULT 0
  )
SQL

struct Post
  include DB::Serializable

  getter id : Int64
  getter title : String
  getter body : String
  getter published : Int64
  getter created_at : String
end

struct Comment
  include DB::Serializable

  getter id : Int64
  getter post_id : Int64
  getter body : String
  getter author : String
end

struct Tag
  include DB::Serializable

  getter id : Int64
  getter name : String
end

struct Article
  include DB::Serializable

  getter id : Int64
  getter title : String
  getter published : Bool
end

struct ArticleQuery < Stitch::QueryBuilder(Article)
  table "articles"

  def create(title : String, published : Bool = false)
    insert(title: title, published: published)
  end

  def create!(title : String, published : Bool = false) : Bool
    insert!(title: title, published: published)
  end

  def published_articles
    where(published: true)
  end

  def unpublished_articles
    where(published: false)
  end
end

struct PostQuery < Stitch::QueryBuilder(Post)
  table "posts"

  def create(title : String, body : String, published : Int64 = 0_i64)
    insert(title: title, body: body, published: published)
  end

  def create!(title : String, body : String, published : Int64 = 0_i64) : Bool
    insert!(title: title, body: body, published: published)
  end

  def with_id(id : Int64)
    where(id: id).first?
  end

  def published_posts
    where(published: 1_i64)
  end

  def with_title(title : String)
    where(title: title)
  end

  def created_before(timestamp : String)
    where { |post| post.created_at < timestamp }
  end

  def ordered_by_title(direction = "ASC")
    order_by(title: direction)
  end

  def at_most(count : Int32)
    limit count
  end

  def skip(count : Int32)
    offset count
  end

  def unique_titles
    distinct
  end

  def update_title(new_title : String)
    update(title: new_title)
  end

  def remove
    delete
  end

  def record_count
    count
  end

  def validate_and_create(title : String, body : String)
    Result(Post).new
      .validate_presence(title: title, body: body)
      .validate_uniqueness("title") { with_title(title).any? }
      .valid { create(title: title, body: body) }
  end

  def validate_format_and_create(title : String, body : String)
    Result(Post).new
      .validate_presence(title: title, body: body)
      .validate_format(/\A[A-Z]/, title: title)
      .valid { create(title: title, body: body) }
  end

  def validate_size_and_create(title : String, body : String)
    Result(Post).new
      .validate_size("title", title, 3..100, "characters")
      .valid { create(title: title, body: body) }
  end
end

struct CommentQuery < Stitch::QueryBuilder(Comment)
  table "comments"

  def create(post_id : Int64, body : String, author : String)
    insert(post_id: post_id, body: body, author: author)
  end

  def for_post(post_id : Int64)
    where(post_id: post_id)
  end

  def by_author(author : String)
    where(author: author)
  end

  def with_inner_join_on_posts
    inner_join("posts", as: "p", on: "comments.post_id = p.id")
  end

  def with_left_join_on_posts
    left_join("posts", as: "p", on: "comments.post_id = p.id")
  end
end

struct TagQuery < Stitch::QueryBuilder(Tag)
  table "tags"

  def create(name : String)
    insert(name: name)
  end

  def create_or_ignore(name : String) : Bool
    insert!(
      values: {name: name},
      on_conflict: Stitch::ConflictHandler.new("name", do: Stitch::DoNothing.new),
    )
  end

  def with_name(name : String)
    where(name: name)
  end

  def record_count_for_tags
    count
  end
end

struct GetPostByID < Stitch::Query
  def call(id : Int64) : Post?
    read_one? <<-SQL, id, as: Post
      SELECT *
      FROM posts
      WHERE id = ?
      LIMIT 1
    SQL
  end
end

struct CountPosts < Stitch::Query
  def call : Int64
    read_scalar(<<-SQL).as(Int64)
      SELECT count(*) FROM posts
    SQL
  end
end

struct CreatePostRaw < Stitch::Query
  def call(title : String, body : String) : Nil
    write <<-SQL, title, body
      INSERT INTO posts (title, body) VALUES (?, ?)
    SQL
  end
end

def clear_tables
  TEST_DB.exec "DELETE FROM comments"
  TEST_DB.exec "DELETE FROM posts"
  TEST_DB.exec "DELETE FROM tags"
  TEST_DB.exec "DELETE FROM articles"
end

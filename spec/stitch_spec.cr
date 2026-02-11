require "./spec_helper"

describe Stitch do
  before_each { clear_tables }

  describe "version" do
    it "has a version" do
      Stitch::VERSION.should_not be_nil
    end
  end

  describe "config" do
    it "provides read_db and write_db" do
      Stitch::CONFIG.read_db.should eq TEST_DB
      Stitch::CONFIG.write_db.should eq TEST_DB
    end
  end

  describe "QueryBuilder" do
    describe "insert" do
      it "inserts a record and returns it" do
        post = PostQuery.new.create("Hello", "World")
        post.title.should eq "Hello"
        post.body.should eq "World"
        post.id.should be > 0
      end

      it "inserts multiple records" do
        p1 = PostQuery.new.create("First", "Body 1")
        p2 = PostQuery.new.create("Second", "Body 2")
        p1.id.should_not eq p2.id
      end

      it "insert! returns true on success" do
        result = PostQuery.new.create!("Test", "Body")
        result.should be_true
      end
    end

    describe "where (keyword args)" do
      it "filters by single column" do
        PostQuery.new.create("AAA", "body1")
        PostQuery.new.create("BBB", "body2")

        results = PostQuery.new.with_title("AAA").to_a
        results.size.should eq 1
        results.first.title.should eq "AAA"
      end

      it "filters by multiple columns" do
        PostQuery.new.create("AAA", "body1", published: 1_i64)
        PostQuery.new.create("BBB", "body2", published: 0_i64)

        results = PostQuery.new.published_posts.to_a
        results.size.should eq 1
        results.first.title.should eq "AAA"
      end

      it "chains where clauses" do
        PostQuery.new.create("AAA", "body1", published: 1_i64)
        PostQuery.new.create("AAA", "body2", published: 0_i64)
        PostQuery.new.create("BBB", "body3", published: 1_i64)

        results = PostQuery.new.with_title("AAA").published_posts.to_a
        results.size.should eq 1
        results.first.body.should eq "body1"
      end
    end

    describe "where (block)" do
      it "filters using block syntax with comparison operators" do
        PostQuery.new.create("Old", "body", published: 1_i64)
        PostQuery.new.create("New", "body", published: 0_i64)

        results = PostQuery.new.published_posts.to_a
        results.size.should eq 1
        results.first.title.should eq "Old"
      end
    end

    describe "where (raw expression)" do
      it "filters using raw SQL expression" do
        PostQuery.new.create("Hello", "World")
        PostQuery.new.create("Goodbye", "World")

        q = PostQuery.new
        # Use the raw expression overload through a wrapper
        results = q.with_title("Hello").to_a
        results.size.should eq 1
      end
    end

    describe "first / first?" do
      it "returns the first result" do
        PostQuery.new.create("First", "body1")
        PostQuery.new.create("Second", "body2")

        post = PostQuery.new.ordered_by_title.first?
        post.should_not be_nil
        post.not_nil!.title.should eq "First"
      end

      it "first? returns nil when no results" do
        PostQuery.new.with_title("nonexistent").first?.should be_nil
      end

      it "first raises on empty result" do
        expect_raises(Stitch::UnexpectedEmptyResultSet) do
          PostQuery.new.with_title("nonexistent").first
        end
      end
    end

    describe "order_by" do
      it "orders results ascending" do
        PostQuery.new.create("Banana", "b")
        PostQuery.new.create("Apple", "a")
        PostQuery.new.create("Cherry", "c")

        results = PostQuery.new.ordered_by_title("ASC").to_a
        results.map(&.title).should eq ["Apple", "Banana", "Cherry"]
      end

      it "orders results descending" do
        PostQuery.new.create("Banana", "b")
        PostQuery.new.create("Apple", "a")
        PostQuery.new.create("Cherry", "c")

        results = PostQuery.new.ordered_by_title("DESC").to_a
        results.map(&.title).should eq ["Cherry", "Banana", "Apple"]
      end
    end

    describe "limit" do
      it "limits the number of results" do
        5.times { |i| PostQuery.new.create("Post #{i}", "body") }

        results = PostQuery.new.ordered_by_title.at_most(2).to_a
        results.size.should eq 2
      end
    end

    describe "offset" do
      it "skips results" do
        PostQuery.new.create("A", "body")
        PostQuery.new.create("B", "body")
        PostQuery.new.create("C", "body")

        results = PostQuery.new.ordered_by_title.at_most(2).skip(1).to_a
        results.size.should eq 2
        results.map(&.title).should eq ["B", "C"]
      end
    end

    describe "count / scalar" do
      it "counts records" do
        PostQuery.new.create("A", "body")
        PostQuery.new.create("B", "body")
        PostQuery.new.create("C", "body")

        PostQuery.new.record_count.should eq 3_i64
      end

      it "counts with where clause" do
        PostQuery.new.create("A", "body", published: 1_i64)
        PostQuery.new.create("B", "body", published: 0_i64)
        PostQuery.new.create("C", "body", published: 1_i64)

        PostQuery.new.published_posts.record_count.should eq 2_i64
      end
    end

    describe "any? / none? / empty?" do
      it "any? returns true when records exist" do
        PostQuery.new.create("Test", "body")
        PostQuery.new.any?.should be_true
      end

      it "any? returns false when no records" do
        PostQuery.new.any?.should be_false
      end

      it "none? returns true when no records" do
        PostQuery.new.none?.should be_true
      end

      it "none? returns false when records exist" do
        PostQuery.new.create("Test", "body")
        PostQuery.new.none?.should be_false
      end

      it "empty? delegates to none?" do
        PostQuery.new.empty?.should be_true
        PostQuery.new.create("Test", "body")
        PostQuery.new.empty?.should be_false
      end

      it "any?/none? respect where clauses" do
        PostQuery.new.create("A", "body", published: 0_i64)
        PostQuery.new.published_posts.any?.should be_false
        PostQuery.new.published_posts.none?.should be_true
      end
    end

    describe "update" do
      it "updates records and returns them" do
        PostQuery.new.create("Old Title", "body")

        updated = PostQuery.new.with_title("Old Title").update_title("New Title")
        updated.size.should eq 1
        updated.first.title.should eq "New Title"
      end

      it "only updates matching records" do
        PostQuery.new.create("Keep", "body")
        PostQuery.new.create("Change", "body")

        PostQuery.new.with_title("Change").update_title("Changed")

        PostQuery.new.with_title("Keep").any?.should be_true
        PostQuery.new.with_title("Changed").any?.should be_true
        PostQuery.new.with_title("Change").any?.should be_false
      end
    end

    describe "delete" do
      it "deletes matching records" do
        PostQuery.new.create("Keep", "body")
        PostQuery.new.create("Remove", "body")

        rows = PostQuery.new.with_title("Remove").remove
        rows.should eq 1_i64

        PostQuery.new.with_title("Remove").any?.should be_false
        PostQuery.new.with_title("Keep").any?.should be_true
      end

      it "raises on unscoped delete" do
        PostQuery.new.create("Test", "body")

        expect_raises(Stitch::DeleteOperation::UnscopedDeleteOperation) do
          PostQuery.new.remove
        end
      end
    end

    describe "joins" do
      it "supports inner join" do
        post = PostQuery.new.create("Post", "body")
        CommentQuery.new.create(post.id, "Great!", "Alice")

        results = CommentQuery.new.with_inner_join_on_posts.to_a
        results.size.should eq 1
        results.first.body.should eq "Great!"
      end

      it "supports left join" do
        post = PostQuery.new.create("Post", "body")
        CommentQuery.new.create(post.id, "Comment", "Bob")

        results = CommentQuery.new.with_left_join_on_posts.to_a
        results.size.should eq 1
      end
    end

    describe "on_conflict / do_nothing" do
      it "ignores duplicate inserts with DO NOTHING" do
        TagQuery.new.create("crystal")

        result = TagQuery.new.create_or_ignore("crystal")
        result.should be_false

        TagQuery.new.record_count_for_tags.should eq 1_i64
      end
    end

    describe "to_sql" do
      it "generates correct SELECT SQL" do
        sql = PostQuery.new.to_sql
        sql.should contain "SELECT"
        sql.should contain "FROM posts"
      end

      it "generates WHERE clause" do
        sql = PostQuery.new.with_title("test").to_sql
        sql.should contain "WHERE"
        sql.should contain "title = ?"
      end

      it "generates ORDER BY" do
        sql = PostQuery.new.ordered_by_title.to_sql
        sql.should contain "ORDER BY"
        sql.should contain "title ASC"
      end

      it "generates LIMIT before OFFSET" do
        sql = PostQuery.new.at_most(10).skip(5).to_sql
        limit_pos = sql.index("LIMIT").not_nil!
        offset_pos = sql.index("OFFSET").not_nil!
        limit_pos.should be < offset_pos
      end

      it "uses ? placeholders, not $N" do
        sql = PostQuery.new.with_title("test").to_sql
        sql.should_not contain "$"
        sql.should contain "?"
      end
    end
  end

  describe "Validations" do
    describe "validate_presence" do
      it "passes when values are present" do
        result = PostQuery.new.validate_and_create("Title", "Body")
        result.should be_a Post
      end

      it "fails when values are blank" do
        result = PostQuery.new.validate_and_create("", "Body")
        result.should be_a Stitch::Validations::Failure
        failure = result.as(Stitch::Validations::Failure)
        failure.errors.any? { |e| e.attribute == "title" }.should be_true
      end
    end

    describe "validate_uniqueness" do
      it "fails when value already exists" do
        PostQuery.new.create("Unique", "body")

        result = PostQuery.new.validate_and_create("Unique", "body2")
        result.should be_a Stitch::Validations::Failure
        failure = result.as(Stitch::Validations::Failure)
        failure.errors.any? { |e| e.message == "has already been taken" }.should be_true
      end
    end

    describe "validate_format" do
      it "passes when format matches" do
        result = PostQuery.new.validate_format_and_create("Hello", "body")
        result.should be_a Post
      end

      it "fails when format doesn't match" do
        result = PostQuery.new.validate_format_and_create("hello", "body")
        result.should be_a Stitch::Validations::Failure
      end
    end

    describe "validate_size" do
      it "passes when size is in range" do
        result = PostQuery.new.validate_size_and_create("Hello", "body")
        result.should be_a Post
      end

      it "fails when size is too small" do
        result = PostQuery.new.validate_size_and_create("Hi", "body")
        result.should be_a Stitch::Validations::Failure
      end
    end
  end

  describe "Query (raw SQL)" do
    it "reads a single record" do
      post = PostQuery.new.create("Test", "body")

      found = GetPostByID[post.id]
      found.should_not be_nil
      found.not_nil!.title.should eq "Test"
    end

    it "returns nil when not found" do
      GetPostByID[999_i64].should be_nil
    end

    it "reads a scalar value" do
      PostQuery.new.create("A", "body")
      PostQuery.new.create("B", "body")

      CountPosts.call.should eq 2_i64
    end

    it "writes raw SQL" do
      CreatePostRaw.call("Raw", "body")

      PostQuery.new.with_title("Raw").any?.should be_true
    end
  end

  describe "transactions" do
    it "commits on success" do
      Stitch.transaction do |txn|
        PostQuery[txn].create("In Transaction", "body")
      end

      PostQuery.new.with_title("In Transaction").any?.should be_true
    end

    it "rolls back on exception" do
      begin
        Stitch.transaction do |txn|
          PostQuery[txn].create("Will Rollback", "body")
          raise "oops"
        end
      rescue
      end

      PostQuery.new.with_title("Will Rollback").any?.should be_false
    end
  end

  describe "Bool values in models" do
    it "inserts and reads a false Bool value" do
      article = ArticleQuery.new.create("Draft")
      article.published.should be_false
    end

    it "inserts and reads a true Bool value" do
      article = ArticleQuery.new.create("Live", published: true)
      article.published.should be_true
    end

    it "filters by Bool value" do
      ArticleQuery.new.create("Draft", published: false)
      ArticleQuery.new.create("Live", published: true)

      published = ArticleQuery.new.published_articles.to_a
      published.size.should eq 1
      published.first.title.should eq "Live"

      unpublished = ArticleQuery.new.unpublished_articles.to_a
      unpublished.size.should eq 1
      unpublished.first.title.should eq "Draft"
    end
  end

  describe "Enumerable integration" do
    it "supports to_a" do
      PostQuery.new.create("A", "body")
      PostQuery.new.create("B", "body")

      posts = PostQuery.new.to_a
      posts.size.should eq 2
    end

    it "supports map" do
      PostQuery.new.create("A", "body")
      PostQuery.new.create("B", "body")

      titles = PostQuery.new.ordered_by_title.map(&.title)
      titles.should eq ["A", "B"]
    end

    it "supports select/filter" do
      PostQuery.new.create("Apple", "body")
      PostQuery.new.create("Banana", "body")

      results = PostQuery.new.select { |p| p.title.starts_with?("A") }
      results.size.should eq 1
    end
  end
end

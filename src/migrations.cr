require "option_parser"
require "db"
require "dotenv"
Dotenv.load?

migrations = Stitch::MigrationRunner.new(DB.open(ENV["DATABASE_URL"]))

OptionParser.parse do |parser|
  parser.on "run", "Run pending migrations" do
    migrations.command = :run
  end

  parser.on "rollback", "Roll back the most recent migration" do
    migrations.command = :rollback
  end

  parser.on "redo", "Redo the most recent migration" do
    migrations.command = :redo
  end
end

migrations.call

module Stitch
  class MigrationRunner
    getter db : DB::Database
    property command : Command = :unknown

    def initialize(@db = Config.db)
      db.exec <<-SQL
      CREATE TABLE IF NOT EXISTS schema_migrations (name TEXT PRIMARY KEY)
    SQL
    end

    def call
      case command
      in .run?      then run
      in .rollback? then rollback
      in .redo?     then redo
      in .unknown?  then unknown
      end
    end

    def redo
      rollback
      run
    end

    def run
      count = 0
      Dir["db/migrations/*"].each do |dir|
        migration = dir.lchop("db/migrations/")
        next if completed_migrations.includes? migration

        puts "-- Running #{migration}"
        sql = File.read("#{dir}/up.sql")
        puts sql
        db.exec sql
        puts "-- Done"
        db.exec "INSERT INTO schema_migrations (name) VALUES (?)", migration
        puts
        count += 1
      end

      if count == 0
        puts "Migrations up to date."
      end
    end

    def rollback
      unless migration = completed_migrations.to_a.sort.last?
        puts "No migration to roll back"
        exit 1
      end
      dir = "db/migrations/#{migration}"

      puts "-- Rolling back #{migration}"
      sql = File.read("#{dir}/down.sql")
      puts sql
      db.exec sql
      puts "-- Done"
      db.exec "DELETE FROM schema_migrations WHERE name = ?", migration
      @completed_migrations = nil
    end

    def unknown
      puts "Must supply a command:"
      Command.each do |value|
        puts "- #{value.to_s.underscore}" unless value.unknown?
      end
    end

    getter completed_migrations : Set(String) do
      db.query_all(<<-SQL, as: String).to_set
      SELECT name
      FROM schema_migrations
      ORDER BY name
    SQL
    end

    enum Command
      Run
      Rollback
      Redo
      Unknown
    end
  end
end

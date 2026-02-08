require "log"
require "db"

module Stitch
  CONFIG = Config.new
  LOG    = ::Log.for("stitch")

  def self.config(&)
    yield CONFIG
    CONFIG
  end

  class Config
    property! read_db : DB::Database
    property! write_db : DB::Database
    property log = LOG

    def db=(db)
      self.read_db = db
      self.write_db = db
    end
  end
end

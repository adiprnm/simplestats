# frozen_string_literal: true

require_relative './database'

def migrate!
  db = create_database_connection

  db.execute <<-SQL
  CREATE TABLE IF NOT EXISTS websites (
    id INTEGER PRIMARY KEY,
    identifier TEXT,
    name TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
  )
  SQL

  db.execute <<-SQL
  CREATE TABLE IF NOT EXISTS visits (
    id INTEGER PRIMARY KEY,
    website_id INTEGER,
    browser TEXT,
    device TEXT,
    country TEXT,
    referer TEXT,
    visit_hash TEXT,
    date DATE,
    entry_name TEXT,
    entry_path TEXT,
    visitor_id TEXT,
    FOREIGN KEY(website_id) REFERENCES websites(id)
  )
  SQL

  db.execute <<-SQL
  CREATE UNIQUE INDEX IF NOT EXISTS website_visit_hash_unique
  ON visits (website_id, visit_hash)
  SQL

  db.close
end

migrate!

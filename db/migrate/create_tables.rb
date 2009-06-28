# creates the tables if they don't already exist
def ensure_schema_exists
  begin
    $logger.info("Database contains #{Scan.count} scans.")
  rescue ActiveRecord::StatementInvalid => e
    if e.message["Could not find table 'scans'"]  # if no table found
      $logger.info("Initializing db schema")
      ActiveRecord::Schema.define do
        create_table :scans, :force => true do |t|
          t.datetime  :start
          t.datetime  :complete
          t.integer   :infections_count
          t.string    :dir
          t.integer   :dirs_scanned
          t.integer   :files_scanned
          t.float     :data_scanned
          t.float     :data_read
          t.integer   :known_viruses
          t.string    :engine_version
        end
        create_table :infections, :force => true do |t|
          t.text      :file
          t.text      :infection
        end
        create_table :infections_scans, :id => false, :force => true do |t|
          t.integer   :scan_id
          t.integer   :infection_id
        end
      end
    end
  end
end

class Infection < ActiveRecord::Base
  has_and_belongs_to_many :scans
end

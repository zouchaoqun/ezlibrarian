class HolderChangeHistory < ActiveRecord::Base
  belongs_to :book, :counter_cache => true
  
  validates_presence_of :book_id, :holder_id
end

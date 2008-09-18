class Review < ActiveRecord::Base
  belongs_to :book, :counter_cache => true
  
  validates_presence_of :author_id, :book_id, :review
end

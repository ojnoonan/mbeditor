# frozen_string_literal: true

class User < ApplicationRecord
  has_one  :profile
  has_many :addresses
  has_many :orders
  has_many :reviews
  has_many :comments
  has_many :posts, foreign_key: :author_id, inverse_of: :author
  has_many :ordered_products, through: :orders, source: :products
end

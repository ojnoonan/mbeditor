# frozen_string_literal: true

class Product < ApplicationRecord
  belongs_to :category
  has_many   :variants
  has_many   :line_items
  has_many   :reviews
  has_many   :attachments, as: :attachable
end

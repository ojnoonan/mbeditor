# frozen_string_literal: true

# Self-referential: exercises the graph's cycle handling.
class Category < ApplicationRecord
  belongs_to :parent, class_name: "Category", optional: true
  has_many   :children, class_name: "Category", foreign_key: :parent_id, inverse_of: :parent
  has_many   :products
end

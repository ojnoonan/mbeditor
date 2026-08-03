# frozen_string_literal: true

class Post < ApplicationRecord
  belongs_to :author, class_name: "User"
  has_many   :comments
  has_many   :taggings
  has_many   :tags, through: :taggings
  has_many   :attachments, as: :attachable
end

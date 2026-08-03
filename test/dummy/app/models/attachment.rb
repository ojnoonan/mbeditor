# frozen_string_literal: true

# Polymorphic: the graph resolves both sides rather than guessing from the
# column name.
class Attachment < ApplicationRecord
  belongs_to :attachable, polymorphic: true
end

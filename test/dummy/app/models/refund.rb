# frozen_string_literal: true

class Refund < ApplicationRecord
  belongs_to :payment
end

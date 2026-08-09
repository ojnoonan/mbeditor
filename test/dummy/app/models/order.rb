# frozen_string_literal: true

class Order < ApplicationRecord
  belongs_to :user
  belongs_to :coupon, optional: true
  has_many   :line_items
  has_many   :products, through: :line_items
  has_one    :payment
  has_one    :shipment
end

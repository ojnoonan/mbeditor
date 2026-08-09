# frozen_string_literal: true

# Schema for the dummy app's demo domain — a small shop with a blog attached,
# plus a couple of standalone models. Chosen to exercise the model graph the way
# a real app does: a hub (User) with many dependants, a chain
# (Order -> LineItem -> Product -> Category), a self-referential association, a
# join table, a polymorphic association, and two models connected to nothing.
ActiveRecord::Schema[7.1].define(version: 1) do
  create_table :users do |t|
    t.string  :email, null: false
    t.string  :name
    t.string  :role
    t.boolean :active, default: true
    t.timestamps
  end

  create_table :profiles do |t|
    t.references :user
    t.string     :bio
    t.string     :avatar_url
    t.timestamps
  end

  create_table :addresses do |t|
    t.references :user
    t.string     :line1
    t.string     :city
    t.string     :postcode
    t.string     :country
    t.timestamps
  end

  create_table :categories do |t|
    t.string     :name
    t.string     :slug
    t.references :parent
    t.timestamps
  end

  create_table :products do |t|
    t.references :category
    t.string     :name
    t.string     :sku
    t.integer    :price_cents
    t.integer    :stock
    t.timestamps
  end

  create_table :variants do |t|
    t.references :product
    t.string     :size
    t.string     :colour
    t.string     :sku
    t.timestamps
  end

  create_table :orders do |t|
    t.references :user
    t.references :coupon
    t.string     :number
    t.string     :status
    t.integer    :total_cents
    t.datetime   :placed_at
    t.timestamps
  end

  create_table :line_items do |t|
    t.references :order
    t.references :product
    t.integer    :quantity
    t.integer    :unit_price_cents
    t.timestamps
  end

  create_table :payments do |t|
    t.references :order
    t.string     :provider
    t.integer    :amount_cents
    t.string     :state
    t.timestamps
  end

  create_table :refunds do |t|
    t.references :payment
    t.integer    :amount_cents
    t.string     :reason
    t.timestamps
  end

  create_table :shipments do |t|
    t.references :order
    t.string     :carrier
    t.string     :tracking_code
    t.datetime   :shipped_at
    t.timestamps
  end

  create_table :coupons do |t|
    t.string   :code
    t.integer  :percent_off
    t.datetime :expires_at
    t.timestamps
  end

  create_table :reviews do |t|
    t.references :product
    t.references :user
    t.integer    :rating
    t.text       :body
    t.timestamps
  end

  create_table :posts do |t|
    t.references :author
    t.string     :title
    t.string     :slug
    t.text       :body
    t.datetime   :published_at
    t.timestamps
  end

  create_table :comments do |t|
    t.references :post
    t.references :user
    t.text       :body
    t.boolean    :approved, default: false
    t.timestamps
  end

  create_table :tags do |t|
    t.string :name
    t.string :slug
    t.timestamps
  end

  create_table :taggings do |t|
    t.references :tag
    t.references :post
    t.timestamps
  end

  create_table :attachments do |t|
    t.references :attachable, polymorphic: true
    t.string     :filename
    t.integer    :byte_size
    t.timestamps
  end

  create_table :settings do |t|
    t.string :key
    t.string :value
    t.timestamps
  end

  create_table :feature_flags do |t|
    t.string  :key
    t.boolean :enabled, default: false
    t.integer :rollout
    t.timestamps
  end
end

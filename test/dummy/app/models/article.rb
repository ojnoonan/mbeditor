# frozen_string_literal: true

class Article
  attr_accessor :id, :title, :body, :author, :published_at, :tags

  def initialize(attrs = {})
    attrs.each { |k, v| public_send(:"#{k}=", v) }
  end

  # Returns true when the article has been published.
  def published?
    !published_at.nil?
  end

  # Returns a URL-friendly slug derived from the title.
  def slug
    title.to_s.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-|-\z/, "")
  end

  # Returns a short excerpt (first 160 characters of the body).
  def excerpt
    body.to_s.slice(0, 160)
  end

  # Returns true when the article has one or more tags.
  def tagged?
    tags.is_a?(Array) && tags.any?
  end

  # Formats the published_at timestamp for display.
  # Falls back to "Unpublished" when not yet published.
  def formatted_date
    return "Unpublished" unless published?

    published_at.strftime("%B %-d, %Y")
  end

  # Returns a plain-text reading-time estimate based on an average of 200 wpm.
  def reading_time
    words = body.to_s.split.size
    minutes = (words / 200.0).ceil
    minutes == 1 ? "1 min read" : "#{minutes} min read"
  end

  # Convenience constructor — builds an article and marks it as published now.
  def self.publish(attrs = {})
    new(attrs.merge(published_at: Time.now))
  end

  # Returns a human-readable summary line, e.g. for list views.
  def self.summary_line(article)
    "[#{article.formatted_date}] #{article.title}"
  end
end

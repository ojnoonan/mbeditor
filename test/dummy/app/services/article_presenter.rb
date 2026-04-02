# frozen_string_literal: true

class ArticlePresenter
  def initialize(article)
    @article = article
  end

  # Returns the full header block: title, meta line, and tag list.
  def header
    lines = []
    lines << "# #{@article.title}"
    lines << "#{@article.formatted_date}  ·  #{@article.reading_time}"
    lines << "Tags: #{@article.tags&.join(', ') || 'none'}"
    lines.join("\n")
  end

  # Returns the body text with a trailing reading-time hint.
  def body_with_hint
    "#{@article.body}\n\n---\n#{@article.reading_time}"
  end

  # Returns the article's canonical slug for use in links.
  def canonical_slug
    @article.slug
  end

  # Returns true when the article can be shown publicly.
  def publicly_visible?
    @article.published? && !@article.excerpt.empty?
  end
end

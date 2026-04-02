# frozen_string_literal: true

# ArticlesController — demo file for mbeditor go-to-definition / hover.
#
# Every method call below is defined in one of these files:
#   app/models/article.rb          — Article instance and class methods
#   app/helpers/articles_helper.rb — View helper methods
#   app/services/article_presenter.rb — Presenter wrapping an article
#
# Try hovering over any highlighted method name, or Ctrl/Cmd+click to jump
# to the file where it is defined.
class ArticlesController < ApplicationController
  include ArticlesHelper

  # GET /articles
  def index
    @articles = sample_articles

    # Hover over `slug`, `published?`, `tagged?`, `formatted_date`, `reading_time`
    @articles.each do |article|
      _ = article.slug
      _ = article.published?
      _ = article.tagged?
      _ = article.formatted_date
      _ = article.reading_time
    end

    # Hover over `summary_line` — class method on Article
    @summaries = @articles.map { |a| Article.summary_line(a) }
  end

  # GET /articles/:id
  def show
    article = sample_articles.first

    # Hover over `excerpt` and `published?`
    @excerpt = article.excerpt if article.published?

    # Hover over `publicly_visible?`, `header`, `body_with_hint`, `canonical_slug`
    presenter = ArticlePresenter.new(article)
    if presenter.publicly_visible?
      @header = presenter.header
      @body_with_hint = presenter.body_with_hint
      @path           = presenter.canonical_slug
    end

    # Hover over `article_title_tag`, `tag_list`, `status_class`, `article_path`
    @title_html  = article_title_tag(article)
    @tags_line   = tag_list(article, none_text: 'Untagged')
    @css_status  = status_class(article)
    @link        = article_path(article)
  end

  # POST /articles
  def create
    # Hover over `publish` — class method on Article
    article = Article.publish(
      title: params[:title],
      body: params[:body],
      tags: params[:tags]&.split(',')
    )

    @presenter = ArticlePresenter.new(article)

    # Hover over `header` and `publicly_visible?`
    if @presenter.publicly_visible?
      render plain: @presenter.header
    else
      render plain: "Draft saved: #{article.slug}"
    end
  end

  private

  def sample_articles
    [
      Article.new(
        id: 1,
        title: 'Getting started with Rails',
        body: 'Rails is a web application framework written in Ruby.',
        author: 'DHH',
        published_at: Time.now - 86_400,
        tags: %w[rails ruby web]
      ),
      Article.new(
        id: 2,
        title: 'Draft post',
        body: 'Work in progress.',
        author: 'Alice',
        tags: []
      )
    ]
  end
end

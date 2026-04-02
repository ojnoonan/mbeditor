# frozen_string_literal: true

module ArticlesHelper
  # Wraps the article title in an <h1> tag with an optional CSS class.
  def article_title_tag(article, css_class: "article-title")
    "<h1 class=\"#{css_class}\">#{article.title}</h1>"
  end

  # Renders a comma-separated tag list, or a fallback message when there are none.
  def tag_list(article, none_text: "No tags")
    return none_text unless article.tagged?

    article.tags.join(", ")
  end

  # Returns a CSS class string based on the article's published state.
  def status_class(article)
    article.published? ? "status--published" : "status--draft"
  end

  # Builds a canonical URL path for the article using its slug.
  def article_path(article)
    "/articles/#{article.slug}"
  end
end

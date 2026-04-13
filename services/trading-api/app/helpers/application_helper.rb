# frozen_string_literal: true

module ApplicationHelper
  MARKDOWN_ALLOWED_TAGS = %w[
    a blockquote br code del em h1 h2 h3 h4 h5 h6 hr li ol p pre
    strong table tbody td th thead tr ul
  ].freeze
  MARKDOWN_ALLOWED_ATTRIBUTES = %w[class href rel target title].freeze

  # Load Discord user mappings from ENV (JSON format)
  def discord_users
    @discord_users ||= begin
      json = ENV.fetch("DISCORD_USER_MAPPINGS", "{}")
      JSON.parse(json)
    rescue JSON::ParserError
      {}
    end
  end

  # Replace Discord mentions like <@1234567890> or <@!1234567890> with display names
  def format_discord_mentions(text)
    return "".html_safe if text.blank?

    safe_join(
      text.to_s.split(/(<@!?\d+>)/).map do |segment|
        mention = segment.match(/\A<@!?(\d+)>\z/)
        next h(segment) unless mention

        name = discord_users[mention[1]]
        name.present? ? content_tag(:span, "@#{name}", class: "mention") : h(segment)
      end
    )
  end

  def markdown(text)
    return "".html_safe if text.blank?

    sanitize(
      markdown_renderer.render(text.to_s),
      tags: MARKDOWN_ALLOWED_TAGS,
      attributes: MARKDOWN_ALLOWED_ATTRIBUTES
    )
  end

  private

  def markdown_renderer
    @markdown_renderer ||= begin
      renderer = Redcarpet::Render::HTML.new(
        filter_html: true,
        hard_wrap: true,
        safe_links_only: true,
        link_attributes: { target: "_blank", rel: "noopener noreferrer" }
      )

      Redcarpet::Markdown.new(
        renderer,
        autolink: true,
        tables: true,
        fenced_code_blocks: true,
        strikethrough: true,
        highlight: true,
        no_intra_emphasis: true
      )
    end
  end
end

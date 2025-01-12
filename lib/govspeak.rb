require 'kramdown'
require 'govspeak/header_extractor'
require 'govspeak/structured_header_extractor'
require 'govspeak/html_validator'
require 'govspeak/html_sanitizer'
require 'govspeak/kramdown_overrides'
require 'kramdown/parser/kramdown_with_automatic_external_links'
require 'htmlentities'

module Govspeak

  class Document

    Parser = Kramdown::Parser::KramdownWithAutomaticExternalLinks
    PARSER_CLASS_NAME = Parser.name.split("::").last

    @@extensions = []

    attr_accessor :images

    def self.to_html(source, options = {})
      new(source, options).to_html
    end

    def initialize(source, options = {})
      @source = source ? source.dup : ""
      @images = options.delete(:images) || []
      @options = {input: PARSER_CLASS_NAME, entity_output: :symbolic}.merge(options)
    end

    def kramdown_doc
      @kramdown_doc ||= Kramdown::Document.new(preprocess(@source), @options)
    end
    private :kramdown_doc

    def to_html
      kramdown_doc.to_html
    end
    
    def to_liquid
      to_html
    end

    def to_sanitized_html
      HtmlSanitizer.new(to_html).sanitize
    end

    def to_sanitized_html_without_images
      HtmlSanitizer.new(to_html).sanitize_without_images
    end

    def to_text
      HTMLEntities.new.decode(to_html.gsub(/(?:<[^>]+>|\s)+/, " ").strip)
    end

    def valid?(validation_options = {})
      Govspeak::HtmlValidator.new(@source, validation_options).valid?
    end

    def headers
      Govspeak::HeaderExtractor.convert(kramdown_doc).first
    end

    def structured_headers
      Govspeak::StructuredHeaderExtractor.new(self).call
    end

    def preprocess(source)
      @@extensions.each do |title,regexp,block|
        source.gsub!(regexp) {
          instance_exec(*Regexp.last_match.captures, &block)
        }
      end
      source
    end

    def encode(text)
      HTMLEntities.new.encode(text)
    end
    private :encode

    def self.extension(title, regexp = nil, &block)
      regexp ||= %r${::#{title}}(.*?){:/#{title}}$m
      @@extensions << [title, regexp, block]
    end

    def self.surrounded_by(open, close=nil)
      open = Regexp::escape(open)
      if close
        close = Regexp::escape(close)
        %r+(?:\r|\n|^)#{open}(.*?)#{close} *(\r|\n|$)?+m
      else
        %r+(?:\r|\n|^)#{open}(.*?)#{open}? *(\r|\n|$)+m
      end
    end

    def self.wrap_with_div(class_name, character, parser=Kramdown::Document)
      extension(class_name, surrounded_by(character)) { |body|
        content = parser ? parser.new("#{body.strip}\n").to_html : body.strip
        %{\n<div class="#{class_name}">\n#{content}</div>\n}
      }
    end

    def insert_strong_inside_p(body, parser=Govspeak::Document)
      parser.new(body.strip).to_html.sub(/^<p>(.*)<\/p>$/,"<p><strong>\\1</strong></p>")
    end

    extension('reverse') { |body|
      body.reverse
    }

    extension('highlight-answer') { |body|
      %{\n\n<div class="highlight-answer">
#{Govspeak::Document.new(body.strip).to_html}</div>\n}
    }

    # FIXME: these surrounded_by arguments look dodgy
    extension('external', surrounded_by("x[", ")x")) { |body|
      Kramdown::Document.new("[#{body.strip}){:rel='external'}").to_html
    }

    extension('informational', surrounded_by("^")) { |body|
      %{\n\n<div role="note" aria-label="Information" class="application-notice info-notice">
#{Govspeak::Document.new(body.strip).to_html}</div>\n}
    }

    extension('important', surrounded_by("@")) { |body|
      %{\n\n<div role="note" aria-label="Important" class="advisory">#{insert_strong_inside_p(body)}</div>\n}
    }

    extension('helpful', surrounded_by("%")) { |body|
      %{\n\n<div role="note" aria-label="Help" class="application-notice help-notice">\n#{Govspeak::Document.new(body.strip).to_html}</div>\n}
    }

    extension('attached-image', /^!!([0-9]+)/) do |image_number|
      image = images[image_number.to_i - 1]
      if image
        caption = image.caption rescue nil
        render_image(image.url, image.alt_text, caption)
      else
        ""
      end
    end

    def render_image(url, alt_text, caption = nil)
      lines = []
      lines << '<figure class="image embedded">'
      lines << %Q{  <div class="img"><img alt="#{encode(alt_text)}" src="#{encode(url)}" /></div>}
      lines << %Q{  <figcaption>#{encode(caption.strip)}</figcaption>} if caption && !caption.strip.empty?
      lines << '</figure>'
      lines.join "\n"
    end

    wrap_with_div('summary', '$!')
    wrap_with_div('form-download', '$D')
    wrap_with_div('contact', '$C')
    wrap_with_div('place', '$P', Govspeak::Document)
    wrap_with_div('information', '$I', Govspeak::Document)
    wrap_with_div('additional-information', '$AI')
    wrap_with_div('example', '$E', Govspeak::Document)
    wrap_with_div('call-to-action', '$CTA', Govspeak::Document)

    extension('address', surrounded_by("$A")) { |body|
      %{\n<div class="address"><div class="adr org fn"><p>\n#{body.sub("\n", "").gsub("\n", "<br />")}\n</p></div></div>\n}
    }

    extension("legislative list", /(?<=\A|\n\n|\r\n\r\n)^\$LegislativeList\s*$(.*?)\$EndLegislativeList/m) do |body|
      Govspeak::KramdownOverrides.with_kramdown_ordered_lists_disabled do
        Kramdown::Document.new(body.strip).to_html.tap do |doc|
          doc.gsub!('<ul>', '<ol>')
          doc.gsub!('</ul>', '</ol>')
          doc.sub!('<ol>', '<ol class="legislative-list">')
        end
      end
    end

    extension("numbered list", /^[ \t]*((s\d+\.\s.*(?:\n|$))+)/) do |body|
      steps ||= 0
      body.gsub!(/s(\d+)\.\s(.*)(?:\n|$)/) do |b|
          "<li>#{Govspeak::Document.new($2.strip).to_html}</li>\n"
      end
      %{<ol class="steps">\n#{body}</ol>}
    end

    def self.devolved_options
     { 'scotland' => 'Scotland',
       'england' => 'England',
       'england-wales' => 'England and Wales',
       'northern-ireland' => 'Northern Ireland',
       'wales' => 'Wales',
       'london' => 'London' }
    end

    devolved_options.each do |k,v|
      extension("devolved-#{k}",/:#{k}:(.*?):#{k}:/m) do |body|
%{<div class="devolved-content #{k}">
<p class="devolved-header">This section applies to #{v}</p>
<div class="devolved-body">#{Govspeak::Document.new(body.strip).to_html}</div>
</div>\n}
      end
    end

    extension("Priority list", /(?<=\A|\n\n|\r\n\r\n)^\$PriorityList:(\d+)\s*$(.*?)(?:^\s*$|\Z)/m) do |number_to_show, body|
      number_to_show = number_to_show.to_i
      tagged = 0
      Govspeak::Document.new(body.strip).to_html.gsub(/<li>/) do |match|
        if tagged < number_to_show
          tagged += 1
          '<li class="primary-item">'
        else
          match
        end
      end
    end
  end
end

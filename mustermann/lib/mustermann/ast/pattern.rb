# frozen_string_literal: true
require 'mustermann/ast/parser'
require 'mustermann/ast/boundaries'
require 'mustermann/ast/compiler'
require 'mustermann/ast/explainer'
require 'mustermann/ast/transformer'
require 'mustermann/ast/validation'
require 'mustermann/ast/template_generator'
require 'mustermann/ast/param_scanner'
require 'mustermann/regexp_based'
require 'mustermann/expander'
require 'mustermann/equality_map'

module Mustermann
  # @see Mustermann::AST::Pattern
  module AST
    # Superclass for pattern styles that parse an AST from the string pattern.
    # @abstract
    class Pattern < Mustermann::RegexpBased
      supported_options :capture, :except, :greedy, :space_matches_plus

      extend Forwardable, SingleForwardable
      single_delegate on: :parser, suffix: :parser
      instance_delegate %i[parser compiler transformer validation template_generator param_scanner boundaries] => 'self.class'
      instance_delegate parse: :parser, transform: :transformer, validate: :validation,
        generate_templates: :template_generator, scan_params: :param_scanner, set_boundaries: :boundaries
      
      # @api private
      def self.ast_cache
        @ast_cache ||= EqualityMap.new
      end

      # @api private
      # @return [#parse] parser object for pattern
      # @!visibility private
      def self.parser
        return Parser if self == AST::Pattern
        const_set :Parser, Class.new(superclass.parser) unless const_defined? :Parser, false
        const_get :Parser
      end

      # @api private
      # @return [#compile] compiler object for pattern
      # @!visibility private
      def self.compiler
        Compiler
      end

      # @api private
      # @return [#set_boundaries] translator making sure start and stop is set on all nodes
      # @!visibility private
      def self.boundaries
        Boundaries
      end

      # @api private
      # @return [#transform] transformer object for pattern
      # @!visibility private
      def self.transformer
        Transformer
      end

      # @api private
      # @return [#validate] validation object for pattern
      # @!visibility private
      def self.validation
        Validation
      end

      # @api private
      # @return [#generate_templates] generates URI templates for pattern
      # @!visibility private
      def self.template_generator
        TemplateGenerator
      end

      # @api private
      # @return [#scan_params] param scanner for pattern
      # @!visibility private
      def self.param_scanner
        ParamScanner
      end

      # @!visibility private
      def compile(**options)
        options[:except] &&= parse options[:except]
        compiler.compile(to_ast, **options)
      rescue CompileError => error
        raise error.class, "#{error.message}: #{@string.inspect}", error.backtrace
      end

      # Returns a regexp that matches strings excluded by the +except+ option,
      # or +nil+ if no +except+ constraint was given. Used by the trie matcher
      # to filter out excluded strings at leaf nodes.
      # @return [Regexp, nil]
      # @!visibility private
      def except_regexp
        return unless except_str = options[:except]
        @except_regexp ||= begin
          source = compiler.new.translate(parse(except_str), no_captures: true, **options.except(:except))
          Mustermann.dedup(Regexp.new("\\A#{source}\\z"))
        end
      end

      # Internal AST representation of pattern.
      # @!visibility private
      def to_ast
        ast = self.class.ast_cache.fetch([@string, options]) do
          ast   = parse(@string, pattern: self)
          ast &&= transform(ast)
          ast &&= set_boundaries(ast, string: @string)
          validate(ast)
        end
        @param_converters ||= Mustermann.dedup(scan_params(ast, options)) if ast
        ast
      end

      # All AST-based pattern implementations support expanding.
      #
      # @example (see Mustermann::Pattern#expand)
      # @param (see Mustermann::Pattern#expand)
      # @return (see Mustermann::Pattern#expand)
      # @raise (see Mustermann::Pattern#expand)
      # @see Mustermann::Pattern#expand
      # @see Mustermann::Expander
      def expand(behavior = nil, values = EMPTY_HASH)
        @expander ||= Mustermann::Expander.new(self)
        @expander.expand(behavior, values)
      end

      # All AST-based pattern implementations support generating templates.
      #
      # @example (see Mustermann::Pattern#to_templates)
      # @param (see Mustermann::Pattern#to_templates)
      # @return (see Mustermann::Pattern#to_templates)
      # @see Mustermann::Pattern#to_templates
      def to_templates
        @to_templates ||= Mustermann.dedup(generate_templates(to_ast))
      end

      # Explains how the pattern matches (or fails to match) the given string.
      #
      # Unlike {#match}, this is meant for diagnostics (for instance figuring
      # out why a request resulted in a 404) and returns an
      # {Mustermann::AST::Explanation} either way:
      #
      # * On a successful match, the explanation carries the same params a
      #   regular match would produce, plus the byte range each capture
      #   occupied in the original string. Ranges always refer to raw bytes;
      #   URI-decoded values are available separately, so multibyte
      #   characters and percent escapes cannot shift the reported positions.
      # * On a failed match, the explanation reports the furthest byte
      #   position any candidate reached and the set of segments that were
      #   expected at that position. Expectations from parallel candidates
      #   (unions, optional branches) are merged, each keeping the pattern
      #   range it originates from.
      #
      # The failing path is explored by walking the AST with a bounded search
      # budget instead of relying on regular expression backtracking, so
      # diagnostics stay cheap even for pathological patterns. Regular
      # matching is not affected by any of this.
      #
      # @example
      #   pattern = Mustermann.new('/foo/:bar')
      #   pattern.explain_match('/foo/baz').captures['bar'].range # => 5...8
      #   pattern.explain_match('/fo').message
      #   # => "\"/foo/:bar\" does not match: expected \"o\" at byte 3 (after \"/fo\")"
      #
      # @param [String] string the string to match against
      # @param [Integer] budget maximum number of candidate attempts for the
      #   failure diagnostics
      # @return [Mustermann::AST::Explanation] the explanation
      def explain_match(string, budget: Explainer::DEFAULT_BUDGET)
        return Explainer.new(self, string, budget: budget).explain unless match = regexp.match(string)
        Explanation.new(pattern: self, string: string, matched: true,
                        params: build_params(match), captures: explain_captures(string, match))
      end

      # @!visibility private
      # @see Mustermann::Pattern#map_param
      def map_param(key, value)
        return super unless param_converters.include? key
        converted = super
        converted.nil? ? converted : param_converters[key][converted]
      end

      # @!visibility private
      def explain_captures(string, match)
        offsets = Explainer.byte_offsets(string)
        match.regexp.named_captures.each_with_object({}) do |(name, positions), captures|
          entries = positions.filter_map do |index|
            next unless match.begin(index)
            range = offsets[match.begin(index)]...offsets[match.end(index)]
            Explanation::Capture.new(name: name, range: range,
              raw: string.byteslice(range), value: map_param(name, match[index]))
          end
          next if entries.empty?
          captures[name] = positions.size < 2 && !always_array?(name) ? entries.first : entries
        end
      end

      # @!visibility private
      def param_converters
        @param_converters ||= Mustermann.dedup(scan_params(to_ast, options))
      end

      # @api private
      def identity_params?(params)
        param_converters.empty? && super
      end

      private :compile, :parse, :transform, :validate, :generate_templates, :param_converters, :scan_params, :set_boundaries
    end
  end
end

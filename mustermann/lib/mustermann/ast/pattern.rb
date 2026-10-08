# frozen_string_literal: true
require 'mustermann/ast/parser'
require 'mustermann/ast/boundaries'
require 'mustermann/ast/compiler'
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
      supported_options :capture, :except, :greedy, :space_matches_plus, :repeated_capture

      extend Forwardable, SingleForwardable
      single_delegate on: :parser, suffix: :parser
      instance_delegate %i[parser compiler transformer validation template_generator param_scanner boundaries] => 'self.class'
      instance_delegate parse: :parser, transform: :transformer, validate: :validation,
        generate_templates: :template_generator, scan_params: :param_scanner, set_boundaries: :boundaries
      
      # @api private
      def self.ast_cache
        @ast_cache ||= EqualityMap.new
      end

      # @param (see Mustermann::Pattern#initialize)
      # @option options [Symbol] repeated_capture
      #   How to treat a capture name that appears more than once in the pattern.
      #   By default (or when set to +false+), repeated names keep the behavior of the
      #   underlying regexp engine. When set to +:equal+, all occurrences of the same
      #   name must capture values that are equal after URI decoding and param
      #   conversion, otherwise the pattern does not match. Captures inside optional
      #   branches that did not participate in the match are exempt from this
      #   constraint. Expanding such a pattern only takes a single value per name,
      #   which is used (with the same encoding) at every position the name appears.
      # @return (see Mustermann::Pattern#initialize)
      # @raise [ArgumentError] if an unknown repeated_capture mode is given
      # @see (see Mustermann::Pattern#initialize)
      def initialize(string, **options)
        mode = options[:repeated_capture]
        unless mode.nil? or mode == false or mode == :equal
          raise ArgumentError, "unsupported repeated_capture mode %p, expected :equal" % mode
        end
        super
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
          validate(ast, repeated_capture: options[:repeated_capture])
        end
        @param_converters ||= Mustermann.dedup(scan_params(ast, options)) if ast
        ast
      end

      # @see Mustermann::Pattern#===
      def ===(string)
        return super unless repeated_capture_equal?
        string.is_a?(String) ? !!match(string) : false
      end

      # @see Mustermann::Pattern#=~
      def =~(string)
        return super unless repeated_capture_equal?
        string.is_a?(String) && match(string) ? 0 : nil
      end

      # @!visibility private
      # Whether the repeated_capture: :equal mode is enabled for this pattern.
      def repeated_capture_equal?
        options[:repeated_capture] == :equal
      end

      # @return [Array<String>] capture names appearing more than once in the pattern
      # @!visibility private
      def repeated_capture_names
        @repeated_capture_names ||= Mustermann.dedup(
          regexp.named_captures.select { |_name, positions| positions.size > 1 }.keys)
      end

      # Enforces the repeated_capture: :equal constraint after URI decoding and
      # param conversion, and collapses all occurrences of a repeated name to a
      # single value. A failed param conversion is treated as "no match".
      # @!visibility private
      def build_params(match)
        params = super
        return params unless repeated_capture_equal?
        return unless params
        repeated_capture_names.each do |name|
          values = params[name].compact
          return unless values.each_cons(2).all? { |a, b| a == b }
          params[name] = always_array?(name) ? values.first(1) : values.first
        end
        params
      rescue StandardError
        raise unless repeated_capture_equal?
        nil
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

      # @!visibility private
      # @see Mustermann::Pattern#map_param
      def map_param(key, value)
        return super unless param_converters.include? key
        converted = super
        converted.nil? ? converted : param_converters[key][converted]
      end

      # @!visibility private
      def param_converters
        @param_converters ||= Mustermann.dedup(scan_params(to_ast, options))
      end

      # @api private
      def identity_params?(params)
        param_converters.empty? && super
      end

      private :compile, :parse, :transform, :validate, :generate_templates, :param_converters, :scan_params, :set_boundaries,
        :repeated_capture_equal?, :repeated_capture_names, :build_params
    end
  end
end

# frozen_string_literal: true
module Mustermann
  # Class for pattern objects that are a concatenation of other patterns.
  # @see Mustermann::Pattern#+
  class Concat < Composite
    # Mixin for patterns to support native concatenation.
    # @!visibility private
    module Native
      # @see Mustermann::Pattern#+
      # @!visibility private
      def +(other)
        other &&= Mustermann.new(other, type: :identity, **options)
        if (patterns = look_ahead(other)) && !patterns.empty?
          concat = (self + patterns.inject(:+))
          concat + other.patterns.slice(patterns.length..-1).inject(:+)
        else
          native, opts = native_concat(other)
          native ? self.class.new(native, **options, **opts.to_h) : super
        end
      end

      # @!visibility private
      def look_ahead(other)
        return unless other.is_a?(Concat)
        other.patterns.take_while(&method(:native_concat?))
      end

      # @!visibility private
      def native_concat(other)
        "#{self}#{other}" if native_concat?(other)
      end

      # @!visibility private
      def native_concat?(other)
        other.class == self.class and other.options == options
      end

      private :native_concat, :native_concat?
    end

    # Should not be used directly.
    # @!visibility private
    def initialize(*, **)
      super
      if respond_to? :expand
        AST::Validation.validate(combined_ast, repeated_capture: repeated_capture_equal? ? :equal : nil)
      end
    end

    # @see Mustermann::Composite#operator
    # @return [Symbol] always :+
    def operator
      :+
    end

    # @see Mustermann::Pattern#===
    def ===(string)
      return !!match(string) if repeated_capture_equal?
      peek_size(string) == string.size
    end

    # @see Mustermann::Pattern#match
    def match(string)
      peeked = peek_match(string)
      peeked if peeked.to_s == string
    end

    # @see Mustermann::Pattern#params
    def params(string)
      params, size = peek_params(string)
      params if size == string.size
    end

    # @see Mustermann::Pattern#peek_size
    def peek_size(string)
      return pump(string) { |p,s| p.peek_size(s) } unless repeated_capture_equal?
      match = peek_match(string)
      match.to_s.size if match
    end

    # @see Mustermann::Pattern#peek_match
    def peek_match(string)
      post_match      = string
      params         = {}
      captures       = []
      named_captures = {}

      patterns.each do |pattern|
        return unless part = pattern.peek_match(post_match)
        return unless params = merge_params(params, part.params)
        named_captures.merge!(part.named_captures)
        captures.concat(part.captures)
        post_match = post_match[part.to_s.size..-1]
      end

      matched = string[0, string.size - post_match.size]
      Match.new(self, string, matched:, params:, captures:, named_captures:, post_match:)
    end

    # @see Mustermann::Pattern#peek_params
    def peek_params(string)
      return equal_mode_peek_params(string) if repeated_capture_equal?
      pump(string, inject_with: :merge, with_size: true) { |p, s| p.peek_params(s) }
    end

    # @!visibility private
    # Whether all subpatterns use repeated_capture: :equal (or don't care about
    # repeated captures), so repeated names across subpatterns are constrained
    # to capture equal values.
    def repeated_capture_equal?
      patterns.all? do |pattern|
        !pattern.respond_to?(:repeated_capture_equal?, true) || pattern.send(:repeated_capture_equal?)
      end
    end

    # (see Mustermann::Pattern#expand)
    def expand(behavior = nil, values = {})
      raise NotImplementedError, 'expanding not supported' unless respond_to? :expand
      @expander ||= Mustermann::Expander.new(self) { combined_ast }
      @expander.expand(behavior, values)
    end

    # (see Mustermann::Pattern#to_templates)
    def to_templates
      raise NotImplementedError, 'template generation not supported' unless respond_to? :to_templates
      @to_templates ||= patterns.inject([EMPTY_STRING]) { |list, pattern| list.product(pattern.to_templates).map(&:join) }.uniq
    end

    # @!visibility private
    def respond_to_special?(method)
      method = :to_ast if method.to_sym == :expand
      patterns.all? { |p| p.respond_to?(method) }
    end

    # used to generate results for various methods by scanning through an input string
    # @!visibility private
    def pump(string, inject_with: :+, initial: nil, with_size: false)
      substring = string
      results   = Array(initial)

      patterns.each do |pattern|
        result, size = yield(pattern, substring)
        return unless result
        results << result
        size    ||= result
        substring = substring[size..-1]
      end

      results = results.inject(inject_with)
      with_size ? [results, string.size - substring.size] : results
    end

    # generates one big AST from all patterns
    # will not check if patterns support AST generation
    # @!visibility private
    def combined_ast
      payload = patterns.map { |p| AST::Node[:group].new(p.to_ast.payload) }
      AST::Node[:root].new(payload)
    end

    # Merges params from a subpattern into the accumulated params. In
    # repeated_capture: :equal mode, values for the same name must be equal
    # (nil values, stemming from optional branches that did not participate,
    # are exempt); a conflict means there is no match.
    # @!visibility private
    def merge_params(params, new_params)
      return params.merge!(new_params) unless repeated_capture_equal?
      new_params.each do |key, value|
        next if value.nil?
        current = params[key]
        return if params.key?(key) && !current.nil? && current != value
        params[key] = value
      end
      params
    end

    # Like #peek_params, but enforcing the repeated_capture: :equal constraint
    # across subpatterns.
    # @!visibility private
    def equal_mode_peek_params(string)
      substring = string
      params    = {}

      patterns.each do |pattern|
        part_params, size = pattern.peek_params(substring)
        return unless part_params
        return unless params = merge_params(params, part_params)
        substring = substring[size..-1]
      end

      [params, string.size - substring.size]
    end

    private :combined_ast, :pump, :repeated_capture_equal?, :merge_params, :equal_mode_peek_params
  end
end

# frozen_string_literal: true
require 'mustermann/pattern'
require 'forwardable'

module Mustermann
  # Superclass for patterns that internally compile to a regular expression.
  # @see Mustermann::Pattern
  # @abstract
  class RegexpBased < Pattern
    # @return [Regexp] regular expression equivalent to the pattern.
    attr_reader :regexp
    alias_method :to_regexp, :regexp

    # @api private
    supported_options :cache

    # @param (see Mustermann::Pattern#initialize)
    # @return (see Mustermann::Pattern#initialize)
    # @see (see Mustermann::Pattern#initialize)
    def initialize(string, **options)
      cache = options.delete(:cache) { true }

      super
      regexp           = compile(**options)
      @peek_regexp     = Mustermann.dedup(/\A#{regexp}/)
      @regexp          = Mustermann.dedup(/\A#{regexp}\Z/)
      @simple_captures = @regexp.named_captures.none? { |name, positions| positions.size > 1 || always_array?(name) }

      cache_class = ObjectSpace::WeakKeyMap if defined?(ObjectSpace::WeakKeyMap)

      case cache
      when true
        @match_cache = cache_class&.new || false
        @peek_cache  = cache_class&.new || false
      when false
        @match_cache = false
        @peek_cache  = false
      when Hash
        @match_cache = cache[:match] || cache_class&.new || false
        @peek_cache  = cache[:peek]  || cache_class&.new || false
      else
        @match_cache = cache.new
        @peek_cache  = cache.new
      end
    end

    # @param (see Mustermann::Pattern#peek_size)
    # @return (see Mustermann::Pattern#peek_size)
    # @see (see Mustermann::Pattern#peek_size)
    def peek_size(string)
      return unless match = peek_match(string)
      match.to_s.size
    end

    # @param (see Mustermann::Pattern#peek_match)
    # @return (see Mustermann::Pattern#peek_match)
    # @see (see Mustermann::Pattern#peek_match)
    def peek_match(string) = cache_match(@peek_cache, @peek_regexp, string)

    # @param (see Mustermann::Pattern#match)
    # @return (see Mustermann::Pattern#match)
    # @see (see Mustermann::Pattern#match)
    def match(string) = cache_match(@match_cache, @regexp, string)

    # @param (see Mustermann::Pattern#===)
    # @return (see Mustermann::Pattern#===)
    # @see (see Mustermann::Pattern#===)
    def ===(string)
      repeated_capture_equal? ? !match(string).nil? : regexp === string
    end

    # @param (see Mustermann::Pattern#=~)
    # @return (see Mustermann::Pattern#=~)
    # @see (see Mustermann::Pattern#=~)
    def =~(string)
      return regexp =~ string unless repeated_capture_equal?
      match(string) ? 0 : nil
    end

    # Extracts params directly from the regexp without allocating a Match object or
    # populating the match cache — significant GC savings when called in hot loops.
    # @param (see Mustermann::Pattern#params)
    # @return (see Mustermann::Pattern#params)
    def params(string = nil)
      return unless md = @regexp.match(string)
      build_params(md)
    end

    extend Forwardable
    def_delegators :regexp, :names

    private

    def cache_match(cache, regexp, string)
      if cache
        return cache[string] if cache.key?(string)
        cache[string] = build_match(regexp, string)
      else
        build_match(regexp, string)
      end
    end

    def build_match(regexp, string)
      return unless match = regexp.match(string)
      return unless params = build_params(match)
      Match.new(self, match, params: params)
    end

    def build_params(match)
      if repeated_capture_equal?
        build_equal_params(match)
      elsif @simple_captures
        params = match.named_captures
        return params if params.empty? || identity_params?(params)
        params.each_with_object({}) { |(k, v), h| h[k] = map_param(k, v) }
      else
        match.regexp.named_captures.to_h do |name, positions|
          value = positions.size < 2 && !always_array?(name) ? map_param(name, match[name]) :
            positions.flat_map { |pos| map_param(name, match[pos]) }
          [name, value]
        end
      end
    end

    # Builds the params hash for +repeated_capture: :equal+ patterns.
    #
    # Values captured under the same name are compared after URI decoding and
    # param conversion, so different legal encodings of the same value are
    # considered equal. Captures inside optional branches that did not
    # participate in the match do not take part in the constraint. Values of
    # names that are always arrays (like +splat+) are compared element-wise.
    #
    # Returns nil if any repeated value differs or any conversion fails, which
    # is treated as the pattern not matching at all.
    # @!visibility private
    def build_equal_params(match)
      match.regexp.named_captures.each_with_object({}) do |(name, positions), params|
        converted = positions.filter_map { |pos| match[pos] }.map! { |value| map_param(name, value) }
        next if converted.empty?
        return unless converted.all? { |value| value == converted.first }
        params[name] = always_array?(name) ? converted : converted.first
      end
    rescue StandardError
      nil
    end

    def compile(**options) = raise NotImplementedError, 'subclass responsibility'
  end
end

# frozen_string_literal: true
require 'mustermann/ast/node'

module Mustermann
  module AST
    # The result of {Mustermann::AST::Pattern#explain_match}.
    #
    # Explains how a pattern relates to a given string. When the pattern
    # matches, it carries each capture along with the byte range it occupies
    # in the original string. When the pattern does not match, it carries the
    # furthest byte position any candidate reached and the set of expectations
    # at that position, each traceable back to a range in the pattern source.
    class Explanation
      # A single named capture located in the original string.
      class Capture
        # @return [String] name of the capture
        attr_reader :name

        # @return [Range] byte offsets into the original string
        attr_reader :byte_range

        # @return [String] raw bytes sliced from the original string
        attr_reader :raw

        # @return [Object] decoded value (URI-decoded and converted), as it
        #   would appear in the params hash
        attr_reader :value

        def initialize(name:, byte_range:, raw:, value:)
          @name       = name
          @byte_range = byte_range
          @raw        = raw
          @value      = value
        end

        def ==(other)
          other.class == self.class and other.name == name and
            other.byte_range == byte_range and other.raw == raw and other.value == value
        end

        alias_method :eql?, :==

        def hash
          name.hash ^ byte_range.hash ^ raw.hash
        end

        def inspect
          "#<#{self.class.name} #{name}: #{byte_range} #{raw.inspect}>"
        end
      end

      # A single expectation at the furthest position of a failed match.
      class Expectation
        # @return [String, nil] the expected token (a literal or a slice of the
        #   pattern source), or +nil+ when the end of the string was expected
        attr_reader :expected

        # @return [Range, nil] byte offsets into the pattern source this
        #   expectation originates from, or +nil+ if not traceable
        attr_reader :pattern_range

        # @return [Symbol] type of the AST node that produced the expectation
        attr_reader :node_type

        def initialize(expected:, pattern_range:, node_type:)
          @expected      = expected
          @pattern_range = pattern_range
          @node_type     = node_type
        end

        def ==(other)
          other.class == self.class and other.expected == expected and
            other.pattern_range == pattern_range and other.node_type == node_type
        end

        alias_method :eql?, :==

        def hash
          expected.hash ^ pattern_range.hash ^ node_type.hash
        end

        def to_s
          expected ? expected.inspect : "end of string"
        end

        def inspect
          "#<#{self.class.name} #{self}>"
        end
      end

      # @return [Mustermann::AST::Pattern] the pattern that was explained
      attr_reader :pattern

      # @return [Array<Capture>] captures with their byte ranges, empty unless matched
      attr_reader :captures

      # @return [Integer, nil] furthest byte position reached, +nil+ when matched
      attr_reader :position

      # @return [Array<Expectation>] expectations at {#position}, empty when matched
      attr_reader :expected

      # @return [Hash, nil] Sinatra style params when matched, +nil+ otherwise
      attr_reader :params

      def initialize(pattern, matched:, captures: [], params: nil, position: nil, expected: [], truncated: false)
        @pattern   = pattern
        @matched   = matched
        @captures  = captures
        @params    = params
        @position  = position
        @expected  = expected
        @truncated = truncated
      end

      # @return [Boolean] whether the pattern matches the string
      def matched? = @matched

      # @return [Boolean] whether the search budget was exhausted before the
      #   failure diagnosis completed
      def truncated? = @truncated

      # Human readable summary. Never includes the unmatched remainder of the
      # inspected string, so it is safe to log for untrusted input.
      # @return [String]
      def message
        return "matched" if matched?
        note = truncated? ? " (search budget exhausted)" : ""
        "expected #{expected.map(&:to_s).join(' or ')} at byte #{position}#{note}"
      end

      alias_method :to_s, :message

      def inspect
        "#<#{self.class.name}: #{message}>"
      end
    end

    # Diagnostic matcher walking the AST directly instead of relying on one
    # big regular expression. Only used for failure diagnosis: the verdict and
    # the captures of a successful match come from the pattern's own regular
    # expression, so both always agree with {Mustermann::Pattern#match}.
    #
    # The search is bounded by a step budget. When the budget is exhausted the
    # best diagnosis collected so far is returned, flagged as truncated.
    # @!visibility private
    class Explainer
      # @!visibility private
      DEFAULT_BUDGET = 10_000

      # @!visibility private
      BudgetExceeded = Class.new(StandardError)
      private_constant :BudgetExceeded

      # @!visibility private
      def self.explain(pattern, string, budget: DEFAULT_BUDGET)
        new(pattern).explain(string, budget: budget)
      end

      # @!visibility private
      def initialize(pattern)
        @pattern   = pattern
        @compiler  = pattern.class.compiler
        @options   = pattern.options.merge(uri_decode: pattern.uri_decode)
        @fragments = {}.compare_by_identity
        @chars     = {}.compare_by_identity
      end

      # @!visibility private
      def explain(string, budget: DEFAULT_BUDGET)
        if match_data = @pattern.regexp.match(string)
          return Explanation.new(@pattern, matched: true,
            captures: captures_from(match_data, string), params: @pattern.params(string))
        end

        tracker = Tracker.new
        context = Context.new(string, tracker, budget || DEFAULT_BUDGET, @options, @pattern.to_s)
        begin
          walk_node(@pattern.to_ast, 0, context, &final_continuation(context))
        rescue BudgetExceeded
          context.truncated = true
        end
        tracker.register(0, root_expectation) if tracker.empty?

        Explanation.new(@pattern, matched: false, position: tracker.position,
          expected: tracker.expectations, truncated: context.truncated?)
      end

      private

      # Captures for a successful match, taken from the pattern's own regular
      # expression so they always agree with #match. MatchData offsets are
      # character based, so they are converted to byte offsets here.
      def captures_from(match_data, string)
        match_data.regexp.named_captures.flat_map do |name, indices|
          indices.filter_map do |index|
            next unless start = match_data.begin(index)
            byte_begin = string[0...start].bytesize
            byte_end   = string[0...match_data.end(index)].bytesize
            raw        = string.byteslice(byte_begin, byte_end - byte_begin)
            Explanation::Capture.new(name: name, byte_range: byte_begin...byte_end,
              raw: raw, value: @pattern.send(:map_param, name, raw))
          end
        end
      end

      def final_continuation(context)
        string = context.string
        ->(pos) do
          if pos == string.bytesize
            return true unless except_matches?(string)
            context.tracker.register(pos, except_expectation)
          else
            context.tracker.register(pos,
              Explanation::Expectation.new(expected: nil, pattern_range: nil, node_type: :end))
          end
          false
        end
      end

      def except_regexp
        return @except_regexp if defined? @except_regexp
        @except_regexp = begin
          except = @options[:except]
          if except
            ast    = @pattern.class.parser.parse(except)
            source = @compiler.new.translate(ast, no_captures: true, **@options)
            Regexp.new("\\A(?:#{source})\\z")
          end
        end
      end

      def except_matches?(string)
        except_regexp ? except_regexp.match?(string) : false
      end

      def except_expectation
        Explanation::Expectation.new(expected: "not #{@options[:except]}",
          pattern_range: nil, node_type: :except)
      end

      def root_expectation
        source = @pattern.to_s
        Explanation::Expectation.new(expected: source,
          pattern_range: 0...source.bytesize, node_type: :root)
      end

      def walk_node(node, pos, context, &cont)
        context.step!
        case node.type
        when :root, :group    then walk_sequence(node.payload, 0, pos, context, &cont)
        when :char            then walk_char(node, pos, context, &cont)
        when :separator       then walk_literal(node, node.payload, pos, context, &cont)
        when :capture         then walk_fragment(node, pos, context, greedy: context.greedy, &cont)
        when :splat, :named_splat then walk_fragment(node, pos, context, greedy: false, &cont)
        when :variable        then walk_fragment(node, pos, context, greedy: context.greedy, &cont)
        when :optional        then walk_node(node.payload, pos, context, &cont) || cont.call(pos)
        when :union           then node.payload.any? { |alt| walk_node(alt, pos, context, &cont) }
        when :expression      then walk_expression(node, pos, context, &cont)
        when :with_look_ahead then walk_fragment(node, pos, context, greedy: context.greedy, expect: node.head, &cont)
        when :node
          case payload = node.payload
          when Array  then walk_sequence(payload, 0, pos, context, &cont)
          when Node   then walk_node(payload, pos, context, &cont)
          when String then walk_literal(node, payload, pos, context, &cont)
          else walk_fragment(node, pos, context, greedy: context.greedy, &cont)
          end
        else walk_fragment(node, pos, context, greedy: context.greedy, &cont)
        end
      end

      def walk_sequence(nodes, index, pos, context, &cont)
        return cont.call(pos) if index >= nodes.length
        walk_node(nodes[index], pos, context) do |next_pos|
          walk_sequence(nodes, index + 1, next_pos, context, &cont)
        end
      end

      def walk_char(node, pos, context, &cont)
        representations(node).each do |representation|
          next unless context.string.byteslice(pos, representation.bytesize) == representation
          return true if cont.call(pos + representation.bytesize)
        end
        context.expect(pos, node)
        false
      end

      def walk_literal(node, literal, pos, context, &cont)
        if context.string.byteslice(pos, literal.bytesize) == literal
          cont.call(pos + literal.bytesize)
        else
          context.expect(pos, node)
          false
        end
      end

      def walk_expression(node, pos, context, &cont)
        operator = node.operator
        context.with_options(
          allow_reserved: operator.allow_reserved,
          parametric:     operator.parametric,
          separator:      operator.separator,
          greedy:         context.greedy && !operator.allow_reserved
        ) { walk_sequence(node.payload, 0, pos, context, &cont) }
      end

      # Matches a node by compiling it to a small, anchored fragment regexp
      # (via the same compiler the pattern itself uses) and enumerating its
      # feasible end positions. Greedy fragments try the longest candidate
      # first, non-greedy fragments the shortest.
      def walk_fragment(node, pos, context, greedy:, expect: node, &cont)
        context.step!
        fragment = fragment_for(node, context)
        yielded  = false
        each_end_position(fragment, pos, context, greedy: greedy) do |end_pos|
          yielded = true
          return true if cont.call(end_pos)
        end
        context.expect(pos, expect) unless yielded
        false
      end

      def each_end_position(fragment, pos, context, greedy:)
        rest = context.rest(pos)
        if greedy
          return unless match = fragment.greedy.match(rest)
          matched = match[0]
          yield pos + matched.bytesize
          (matched.length - 1).downto(1) do |i|
            context.step!
            candidate = matched[0...i]
            yield pos + candidate.bytesize if fragment.exact.match?(candidate)
          end
          yield pos if fragment.exact.match?("")
        else
          index = 0
          while index <= rest.length
            context.step!
            candidate = rest[0...index]
            yield pos + candidate.bytesize if fragment.exact.match?(candidate)
            index += 1
          end
        end
      end

      def fragment_for(node, context)
        @fragments[node] ||=
          Fragment.new(@compiler.new.translate(node, no_captures: true, **context.options))
      end

      def representations(node)
        @chars[node] ||= begin
          char = node.payload
          if @options[:uri_decode]
            @compiler.char_representations(char, uri_decode: true,
              space_matches_plus: @options.fetch(:space_matches_plus, true))
          else
            [char]
          end
        end
      end

      # A small anchored regular expression for a single AST node.
      # @!visibility private
      class Fragment
        attr_reader :greedy, :exact

        def initialize(source)
          @greedy = Regexp.new("\\A(?:#{source})")
          @exact  = Regexp.new("\\A(?:#{source})\\z")
        end
      end

      # Tracks the furthest position reached by any candidate and merges the
      # expectations reported there. Expectations at shorter positions never
      # replace ones collected further into the string.
      # @!visibility private
      class Tracker
        attr_reader :position, :expectations

        def initialize
          @position     = -1
          @expectations = []
          @seen         = {}
        end

        def empty?
          @position.negative?
        end

        def register(position, expectation)
          return if position < @position
          if position > @position
            @position = position
            @expectations.clear
            @seen.clear
          end
          key = [expectation.expected, expectation.pattern_range]
          return if @seen.key?(key)
          @seen[key] = true
          @expectations << expectation
        end
      end

      # Mutable state shared by one diagnosis run.
      # @!visibility private
      class Context
        attr_reader :string, :tracker
        attr_accessor :truncated

        def initialize(string, tracker, budget, options, pattern_source)
          @string         = string
          @bytesize       = string.bytesize
          @tracker        = tracker
          @budget         = budget
          @stack          = [options]
          @pattern_source = pattern_source
          @truncated      = false
        end

        def truncated? = @truncated
        def options    = @stack.last
        def greedy     = options.fetch(:greedy, true)

        def with_options(overrides)
          @stack.push(options.merge(overrides))
          yield
        ensure
          @stack.pop
        end

        def step!
          raise BudgetExceeded if (@budget -= 1) < 0
        end

        def rest(pos)
          return +"" if pos >= @bytesize
          @string.byteslice(pos..-1)
        end

        def expect(pos, node)
          @tracker.register(pos, expectation_for(node))
        end

        private

        def expectation_for(node)
          expected = case node.type
                     when :char, :separator then node.payload
                     else @pattern_source.byteslice(node.start...node.stop)
                     end
          Explanation::Expectation.new(expected: expected,
            pattern_range: node.start...node.stop, node_type: node.type)
        end
      end

      private_constant :Fragment, :Tracker, :Context
    end

    private_constant :Explainer
  end
end

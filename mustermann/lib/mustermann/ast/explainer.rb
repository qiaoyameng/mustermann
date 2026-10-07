# frozen_string_literal: true
require 'mustermann/ast/compiler'

module Mustermann
  module AST
    # The return value of {Mustermann::AST::Pattern#explain_match}.
    #
    # On a successful match it exposes the params (identical to a regular
    # match) plus the byte ranges each capture occupied in the original
    # string. On a failed match it reports the furthest byte position any
    # candidate reached and the set of segments that were expected there.
    class Explanation
      # A single capture occurrence in the matched string.
      #
      # @!attribute [r] name
      #   @return [String] name of the capture
      # @!attribute [r] range
      #   @return [Range<Integer>] byte offsets into the original string
      # @!attribute [r] raw
      #   @return [String] raw bytes the capture matched (still URI-escaped)
      # @!attribute [r] value
      #   @return decoded and converted value, as it appears in the params hash
      Capture = Struct.new(:name, :range, :raw, :value, keyword_init: true)

      # A single "expected" entry at the furthest position of a failed match.
      #
      # @!attribute [r] description
      #   @return [String] human readable description of the expected segment
      # @!attribute [r] pattern_range
      #   @return [Range<Integer>, nil] character offsets into the pattern
      #     string this expectation originates from, +nil+ for implicit
      #     expectations (like the end of the input)
      Expectation = Struct.new(:description, :pattern_range, keyword_init: true) do
        # @return [String] the description
        def to_s = description

        # @return [String] the description and the pattern range, if any
        def inspect
          return description unless pattern_range
          "%s (pattern %d...%d)" % [description, pattern_range.begin, pattern_range.end]
        end
      end

      # @return [Mustermann::AST::Pattern] the pattern that was explained
      attr_reader :pattern

      # @return [String] the string that was matched against
      attr_reader :string

      # @return [Hash, nil] params hash, like {Mustermann::Pattern#params}, if matched
      attr_reader :params

      # @return [Hash, nil] maps capture names to {Capture} objects (or arrays
      #   of {Capture} objects for repeated names), if matched
      attr_reader :captures

      # @return [Integer, nil] byte offset of the furthest position any
      #   candidate reached, if not matched
      attr_reader :position

      # @return [Array<Expectation>] what could have followed at {#position},
      #   if not matched
      attr_reader :expectations

      # @!visibility private
      def initialize(pattern:, string:, matched:, params: nil, captures: nil,
                     position: nil, expectations: nil, exhausted: false)
        @pattern      = pattern
        @string       = string
        @matched      = matched
        @params       = params
        @captures     = captures
        @position     = position
        @expectations = expectations
        @exhausted    = exhausted
      end

      # @return [Boolean] whether the string matches the pattern
      def matched? = @matched

      # @return [Boolean] whether the diagnostic search budget ran out before
      #   all candidates could be explored (failure explanations only)
      def exhausted? = @exhausted

      # The part of the string that was successfully consumed before matching
      # stopped at {#position}.
      # @return [String, nil] matched prefix, if not matched
      def prefix
        @string.byteslice(0, @position) if @position
      end

      # The part of the string that could not be matched. Potentially
      # sensitive, therefore not included in {#message} by default.
      # @return [String, nil] unmatched suffix, if not matched
      def suffix
        @string.byteslice(@position..) if @position
      end

      # Human readable summary of the explanation. Does not include the
      # unmatched suffix of the input string unless explicitly requested, as
      # it might contain sensitive data (tokens, user names, ...).
      #
      # @param include_suffix [Boolean] also append the unmatched suffix
      # @return [String] the summary
      def message(include_suffix: false)
        return format('%p matches %p', @pattern.to_s, @string) if matched?

        expected = @expectations.map(&:description).join(' or ')
        message  = format('%p does not match: expected %s at byte %d (after %p)',
                          @pattern.to_s, expected, @position, prefix)
        message += format(', unmatched suffix %p', suffix) if include_suffix
        message += ' (search budget exhausted)' if exhausted?
        message
      end

      alias to_s message

      # @return [String]
      def inspect
        state = matched? ? "matched, params: #{params.inspect}" :
          "no match, expected: #{expectations.inspect} at byte #{position}"
        "#<#{self.class.name} #{pattern.to_s.inspect} vs #{string.inspect}: #{state}>"
      end
    end

    # Diagnostic matcher walking the AST directly instead of compiling to a
    # single regular expression. Used by {Pattern#explain_match} to figure out
    # how far matching got and what could have come next.
    #
    # The search is bounded by a budget of candidate attempts, so pathological
    # patterns or inputs cannot trigger exponential backtracking.
    # @!visibility private
    class Explainer
      # @!visibility private
      DEFAULT_BUDGET = 1_000

      # @return [Array<Integer>] byte offset for every character offset
      # @!visibility private
      def self.byte_offsets(string)
        offsets = [0]
        string.each_char { |char| offsets << offsets.last + char.bytesize }
        offsets
      end

      def initialize(pattern, string, budget: DEFAULT_BUDGET)
        @pattern      = pattern
        @string       = string
        @budget       = budget
        @length       = string.length
        @furthest     = -1
        @expectations = []
        @sources      = {}
        @compiler     = Compiler.new
      end

      # Walks the pattern AST and builds a failure Explanation.
      # @return [Mustermann::AST::Explanation]
      # @!visibility private
      def explain
        walk(@pattern.to_ast.payload, 0, compile_options) do |end_pos|
          if end_pos == @length
            @excluded = true
          else
            record(end_pos, 'end of input')
          end
        end
        build
      rescue BudgetExhausted
        build(exhausted: true)
      end

      # @!visibility private
      class BudgetExhausted < StandardError; end

      private

      def build(exhausted: false)
        offsets  = Explainer.byte_offsets(@string)
        position = @furthest.negative? ? 0 : offsets[@furthest]
        if @excluded
          # The AST walk consumed the whole string, yet the pattern did not
          # match: the string is rejected by the :except option.
          position     = offsets.last
          expectations = [Explanation::Expectation.new(
            description: 'a string not excluded by the :except option')]
        else
          expectations = @expectations
        end
        Explanation.new(pattern: @pattern, string: @string, matched: false,
                        position: position, expectations: expectations,
                        exhausted: exhausted)
      end

      def compile_options
        @compile_options ||= begin
          options = @pattern.options.dup
          options[:uri_decode] = @pattern.uri_decode unless options.key?(:uri_decode)
          options.delete(:except)
          options
        end
      end

      def spend!
        raise BudgetExhausted if (@budget -= 1).negative?
      end

      # Records an expectation at the given character position. Expectations
      # from shorter candidates are discarded, so optional branches can never
      # move the report back to a shorter prefix.
      def record(pos, description, node = nil)
        return if pos < @furthest
        @expectations.clear if pos > @furthest
        @furthest = pos
        range = node.start...node.stop if node&.start
        key   = [description, range]
        return if @expectations.any? { |e| [e.description, e.pattern_range] == key }
        @expectations << Explanation::Expectation.new(description: description, pattern_range: range)
      end

      def walk(node, pos, options, &continuation)
        spend!
        if node.is_a? Array
          walk_sequence(node, pos, options, &continuation)
        else
          walk_node(node, pos, options, &continuation)
        end
      end

      def walk_sequence(nodes, pos, options, &continuation)
        return continuation.call(pos) if nodes.empty?
        head, *tail = nodes
        walk(head, pos, options) { |next_pos| walk_sequence(tail, next_pos, options, &continuation) }
      end

      def walk_node(node, pos, options, &continuation)
        case node.type
        when :separator   then walk_literal(node.payload, node, pos, &continuation)
        when :char        then walk_char(node, pos, options, &continuation)
        when :capture, :variable
          walk_capture(node, pos, options, greedy: options.fetch(:greedy, true), &continuation)
        when :splat, :named_splat
          walk_capture(node, pos, options, greedy: false, &continuation)
        when :optional
          walk(node.payload, pos, options, &continuation)
          continuation.call(pos)
        when :union
          node.payload.each { |alternative| walk(alternative, pos, options, &continuation) }
        when :group
          walk(node.payload, pos, options, &continuation)
        when :expression
          walk_expression(node, pos, options, &continuation)
        when :with_look_ahead
          # The look-ahead is a compile time optimization. Walking the head
          # capture followed by the remaining elements and letting the
          # bounded backtracking sort out the split is equivalent.
          walk_sequence([node.head, *node.payload], pos, options, &continuation)
        else
          walk_compiled(node, pos, options, &continuation)
        end
      end

      def walk_expression(node, pos, options, &continuation)
        operator = node.operator
        options  = options.merge(
          allow_reserved: operator.allow_reserved,
          greedy:         options.fetch(:greedy, true) && !operator.allow_reserved,
          parametric:     operator.parametric,
          separator:      operator.separator)
        walk(node.payload, pos, options, &continuation)
      end

      def walk_literal(literal, node, pos, &continuation)
        if @string[pos, literal.length] == literal
          continuation.call(pos + literal.length)
        else
          record(pos, literal.inspect, node)
        end
      end

      def walk_char(node, pos, options, &continuation)
        matched = false
        representations(node, options).each do |representation|
          next unless @string[pos, representation.length] == representation
          matched = true
          continuation.call(pos + representation.length)
        end
        record(pos, node.payload.inspect, node) unless matched
      end

      def representations(node, options)
        return [node.payload] unless options.fetch(:uri_decode, true)
        Compiler.char_representations(node.payload,
          space_matches_plus: options.fetch(:space_matches_plus, true))
      end

      # Matches a capture node by enumerating candidate end positions, longest
      # first for greedy captures, shortest first for splats, and letting the
      # continuation decide which split allows the rest to match.
      def walk_capture(node, pos, options, greedy:, &continuation)
        source = source_for(node, options)
        ends   = candidate_ends(source, pos, greedy: greedy)
        if ends.empty?
          record(pos, describe_capture(node), node)
        else
          ends.each { |stop| continuation.call(stop) }
        end
      end

      # Fallback for node types without dedicated walking logic: match the
      # compiled subexpression once, without backtracking into it.
      def walk_compiled(node, pos, options, &continuation)
        source = source_for(node, options)
        match  = anchored_regexp(source).match(@string, pos)
        return record(pos, node.type.to_s.tr('_', ' '), node) unless match
        continuation.call(match.end(0))
      end

      def candidate_ends(source, pos, greedy:)
        full = full_regexp(source)
        min  = full.match?(EMPTY_STRING) ? pos : pos + 1
        max  = max_end(source, pos)
        return [] if max < min
        ends = greedy ? max.downto(min).to_a : (min..max).to_a
        return ends if source == '.*?'
        ends.select { |stop| spend!; full.match?(@string[pos...stop]) }
      end

      def max_end(source, pos)
        return @length if source == '.*?'
        match = anchored_regexp(source).match(@string, pos)
        match ? match.end(0) : -1
      end

      def source_for(node, options)
        @sources[node] ||= @compiler.translate(node, no_captures: true, **options)
      end

      def anchored_regexp(source)
        (@anchored ||= {})[source] ||= Regexp.new("\\G(?:#{source})")
      end

      def full_regexp(source)
        (@full ||= {})[source] ||= Regexp.new("\\A(?:#{source})\\z")
      end

      def describe_capture(node)
        node.type == :variable ? "variable {#{node.name}}" : "capture :#{node.name}"
      end
    end

    private_constant :Explainer
  end
end

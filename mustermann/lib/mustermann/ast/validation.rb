# frozen_string_literal: true
require 'mustermann/ast/translator'

module Mustermann
  module AST
    # Checks the AST for certain validations, like correct capture names.
    #
    # Internally a poor man's visitor (abusing translator to not have to implement a visitor).
    # @!visibility private
    class Validation < Translator
      # Runs validations.
      #
      # @param [Mustermann::AST::Node] ast to be validated
      # @param [Symbol, nil] repeated_capture how to treat repeated capture names (+nil+ or +:equal+)
      # @return [Mustermann::AST::Node] the validated ast
      # @raise [Mustermann::AST::CompileError] if validation fails
      # @!visibility private
      def self.validate(ast, repeated_capture: nil)
        new(repeated_capture: repeated_capture).translate(ast)
        ast
      end

      # @!visibility private
      def initialize(repeated_capture: nil)
        @repeated_capture = repeated_capture
        super()
      end

      translate(Object, :splat) {}
      translate(:node) { t(payload) }
      translate(Array) { each { |p| t(p)} }
      translate(:capture) { t.check_name(name, convert: convert, forbidden: ['captures', 'splat'])}
      translate(:variable, :named_splat) { t.check_name(name, convert: convert, forbidden: 'captures')}

      # @raise [Mustermann::CompileError] if name is not acceptable
      # @!visibility private
      def check_name(name, convert: nil, forbidden: EMPTY_ARRAY)
        raise CompileError, "capture name can't be empty" if name.nil? or name.empty?
        raise CompileError, "capture name must start with underscore or lower case letter" unless name =~ /^[a-z_]/
        raise CompileError, "capture name can't be #{name}" if Array(forbidden).include? name
        if names.include? name
          raise CompileError, "can't use the same capture name twice" unless repeated_capture_equal?
          raise CompileError, "can't use the same capture name with different converters" unless converters[name] == convert
        else
          names << name
          converters[name] = convert
        end
      end

      # @return [Array<String>] list of capture names in tree
      # @!visibility private
      def names
        @names ||= []
      end

      # @return [Hash{String => Object}] converter seen per capture name
      # @!visibility private
      def converters
        @converters ||= {}
      end

      private

      # @return [Boolean] whether repeated capture names are allowed and constrained to be equal
      # @!visibility private
      def repeated_capture_equal?
        @repeated_capture == :equal
      end
    end
  end
end

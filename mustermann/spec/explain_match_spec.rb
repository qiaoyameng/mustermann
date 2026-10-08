# frozen_string_literal: true
require 'support'
require 'mustermann'
require 'mustermann/sinatra'
require 'mustermann/rails'
require 'mustermann/regular'

describe Mustermann::AST::Pattern do
  describe :explain_match do
    subject(:pattern) { Mustermann.new('/users/:id', type: :sinatra) }

    it 'is available on AST patterns' do
      expect(pattern).to respond_to(:explain_match)
    end

    it 'is not available on non-AST patterns' do
      expect(Mustermann::Regular.new('/users/(?<id>.*)')).not_to respond_to(:explain_match)
    end

    describe 'successful matches' do
      it 'reports captures with their byte ranges in the original string' do
        explanation = pattern.explain_match('/users/42')
        expect(explanation.matched?).to be(true)

        expect(explanation.captures.size).to be == 1
        capture = explanation.captures.first
        expect(capture.name).to be == 'id'
        expect(capture.byte_range).to eq(7...9)
        expect(capture.raw).to be == '42'
        expect(capture.value).to be == '42'
      end

      it 'keeps raw bytes and decoded value in separate fields' do
        pattern = Mustermann.new('/:name', type: :sinatra)
        capture = pattern.explain_match('/hello%20world').captures.first
        expect(capture.raw).to be == 'hello%20world'
        expect(capture.value).to be == 'hello%20world'.gsub('%20', ' ')
        expect(capture.byte_range).to eq(1...14)
      end

      it 'uses byte offsets for multibyte characters' do
        pattern = Mustermann.new('/:name', type: :sinatra)
        string  = '/héllo'
        capture = pattern.explain_match(string).captures.first
        expect(capture.byte_range).to eq(1...7)
        expect(capture.raw).to be == 'héllo'
        expect(string.byteslice(capture.byte_range)).to be == capture.raw
      end

      it 'exposes the same params as #match' do
        explanation = pattern.explain_match('/users/42')
        expect(explanation.params).to be == pattern.params('/users/42')
      end

      it 'does not report a failure position or expectations' do
        explanation = pattern.explain_match('/users/42')
        expect(explanation.position).to be_nil
        expect(explanation.expected).to be_empty
        expect(explanation.truncated?).to be(false)
        expect(explanation.message).to be == 'matched'
      end
    end

    describe 'failed matches' do
      it 'reports the furthest position and the expectation there' do
        explanation = pattern.explain_match('/users')
        expect(explanation.matched?).to be(false)
        expect(explanation.position).to be == 6
        expect(explanation.expected.size).to be == 1
        expect(explanation.expected.first.expected).to be == '/'
        expect(explanation.expected.first.node_type).to be == :separator
      end

      it 'traces expectations back to the pattern source' do
        explanation = pattern.explain_match('/users')
        expectation = explanation.expected.first
        expect(expectation.pattern_range).to eq(6...7)
        expect(pattern.to_s.byteslice(expectation.pattern_range)).to be == '/'
      end

      it 'expects a capture when input ends before it' do
        explanation = pattern.explain_match('/users/')
        expect(explanation.position).to be == 7
        expect(explanation.expected.first.expected).to be == ':id'
        expect(explanation.expected.first.node_type).to be == :capture
        expect(explanation.expected.first.pattern_range).to eq(7...10)
      end

      it 'expects the end of the string for trailing garbage' do
        explanation = pattern.explain_match('/users/42/extra')
        expect(explanation.position).to be == 9
        expect(explanation.expected.first.expected).to be_nil
        expect(explanation.expected.first.node_type).to be == :end
      end

      it 'does not include the unmatched remainder in the report' do
        explanation = pattern.explain_match('/users/42/secret-token')
        expect(explanation.message).not_to include('secret')
        expect(explanation.expected.map(&:to_s).join).not_to include('secret')
      end

      it 'merges expectations of parallel alternatives' do
        pattern = Mustermann.new('/(foo|bar)', type: :sinatra)
        explanation = pattern.explain_match('/xaz')
        expect(explanation.position).to be == 1
        expect(explanation.expected.map(&:expected)).to contain_exactly('f', 'b')
      end

      it 'keeps the pattern ranges of merged expectations traceable' do
        pattern = Mustermann.new('/(foo|bar)', type: :sinatra)
        explanation = pattern.explain_match('/xaz')
        ranges = explanation.expected.map(&:pattern_range)
        expect(ranges).to contain_exactly(2...3, 6...7)
        slices = explanation.expected.map { |e| pattern.to_s.byteslice(e.pattern_range) }
        expect(slices).to contain_exactly('f', 'b')
      end

      it 'does not let optional branches move the report back to a shorter prefix' do
        pattern = Mustermann.new('/a(/b)?/c', type: :sinatra)
        explanation = pattern.explain_match('/a/x')
        # the optional group got as far as byte 3 before failing on "b",
        # skipping it only reaches byte 3 expecting "c" as well
        expect(explanation.position).to be == 3
        expect(explanation.expected.map(&:expected)).to contain_exactly('b', 'c')
      end

      it 'handles the except option' do
        pattern = Mustermann.new('/:name', type: :sinatra, except: '/admin')
        explanation = pattern.explain_match('/admin')
        expect(explanation.matched?).to be(false)
        expect(explanation.expected.first.node_type).to be == :except
      end

      it 'reports byte positions correctly with URI-escaped characters' do
        pattern = Mustermann.new('/café/menu', type: :sinatra)
        explanation = pattern.explain_match('/caf%C3%A9/xenu')
        expect(explanation.position).to be == 11
        expect(explanation.expected.first.expected).to be == 'm'
      end

      it 'matches literals byte for byte when uri_decode is disabled' do
        pattern = Mustermann.new('/café/menu', type: :sinatra, uri_decode: false)
        explanation = pattern.explain_match('/caf%C3%A9/menu')
        expect(explanation.matched?).to be(false)
        expect(explanation.position).to be == 4
        expect(pattern.explain_match('/café/menu').matched?).to be(true)
      end
    end

    describe 'result objects' do
      it 'compares captures by value' do
        pattern = Mustermann.new('/users/:id', type: :sinatra)
        one, two = 2.times.map { pattern.explain_match('/users/42').captures.first }
        expect(one).to eq(two)
        expect(one.hash).to eq(two.hash)
        expect(one).not_to eq(pattern.explain_match('/users/43').captures.first)
        expect(one.inspect).to include('id', '7...9', '42')
      end

      it 'compares expectations by value' do
        pattern = Mustermann.new('/users/:id', type: :sinatra)
        one, two = 2.times.map { pattern.explain_match('/users').expected.first }
        expect(one).to eq(two)
        expect(one.hash).to eq(two.hash)
        expect(one).not_to eq(pattern.explain_match('/us').expected.first)
        expect(one.inspect).to include('/')
      end

      it 'has a readable inspection' do
        expect(pattern.explain_match('/users/42').inspect).to include('matched')
        expect(pattern.explain_match('/users').inspect).to include('byte 6')
      end
    end

    describe 'search budget' do
      it 'returns a truncated result instead of searching forever' do
        pattern = Mustermann.new('/' + '(a)?' * 12, type: :sinatra)
        explanation = pattern.explain_match('/' + 'b' * 20, budget: 5)
        expect(explanation.matched?).to be(false)
        expect(explanation.truncated?).to be(true)
        expect(explanation.message).to include('budget')
      end

      it 'does not truncate within the default budget' do
        pattern = Mustermann.new('/dl/*/meta', type: :sinatra)
        explanation = pattern.explain_match('/dl/' + 'x' * 500)
        expect(explanation.truncated?).to be(false)
        expect(explanation.position).to be == 504
      end

      it 'does not affect the normal match behavior' do
        pattern = Mustermann.new('/users/:id', type: :sinatra)
        expect(pattern.match('/users/42')).not_to be_nil
        expect(pattern.match('/users')).to be_nil
      end
    end

    describe 'consistency with #match' do
      patterns = [
        Mustermann.new('/users/:id', type: :sinatra),
        Mustermann.new('/:a/:b/:c', type: :sinatra),
        Mustermann.new('/foo/*', type: :sinatra),
        Mustermann.new('/:name(.:ext)?', type: :sinatra),
        Mustermann.new('/(foo|bar)/:id', type: :sinatra),
        Mustermann.new('/x/:y', type: :sinatra, greedy: false),
        Mustermann.new('/:n', type: :sinatra, capture: /\d+/),
        Mustermann.new('/a b', type: :sinatra),
        Mustermann.new('/:name', type: :sinatra, uri_decode: false),
        Mustermann.new('/:id', type: :rails),
        Mustermann.new('{/segments*}', type: :template),
      ]
      paths = [
        '/users/42', '/users', '/users/', '/a/b/c', '/a/b', '/foo/x/y', '/foo',
        '/bar.png', '/bar', '/foo/1', '/baz/1', '/5', '/abc', '/x/y', '/123',
        '/12a', '/a+b', '/a%20b', '/a b', '/héllo', '/%68ello', '/a/b/c/d', '/',
      ]

      patterns.each do |pattern|
        context "for #{pattern.to_s.inspect}" do
          paths.each do |path|
            it "agrees with #match for #{path.inspect}" do
              explanation = pattern.explain_match(path)
              expect(explanation.matched?).to be == !pattern.match(path).nil?
              next unless explanation.matched?
              expect(explanation.params).to be == pattern.params(path)
              explanation.captures.each do |capture|
                expect(path.byteslice(capture.byte_range)).to be == capture.raw
              end
            end
          end
        end
      end
    end
  end
end
